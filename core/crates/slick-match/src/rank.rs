//! The rank layout that every ranked list shares.
//!
//! A rank is one `i32`. Text tiers sit `TIER_GAP` apart, and everything added inside a tier stays
//! below the next tier:
//!
//! ```text
//! rank = TIER_GAP * effective tier + FIELD_BONUS[field] + quality (0..=999) + lift (0..=MAX_LIFT)
//! ```
//!
//! - The effective tier is the text tier, one lower for keyword matches. Keywords never produce
//!   subsequence or typo hits.
//! - At equal tier, quality and lift, a title match outranks an alias match, which outranks a
//!   keyword match.
//! - `lift` carries the within-tier signals a caller computes, such as frecency, context and kind
//!   priors. It is clamped to `MAX_LIFT`, so no lift moves an item into another tier.
//!
//! Callers that rank bands above the text tiers (user aliases, learned picks) place them at
//! `TIER_GAP * 7` and up. [`tier_of`] recovers the tier of any rank.

use crate::score::{SUBSTRING, TextScore, WORD_PREFIX};

/// Distance between two adjacent tiers.
pub const TIER_GAP: i32 = 10_000;
/// Highest quality the scorer reports inside a tier.
pub const MAX_QUALITY: i32 = 999;
/// Rank bonus per field, indexed by `Field as usize`.
pub const FIELD_BONUS: [i32; 3] = [2_000, 1_000, 0];
/// Largest within-tier lift. Bonus, quality and lift together stay below `TIER_GAP`.
pub const MAX_LIFT: i32 = TIER_GAP - 1 - FIELD_BONUS[0] - MAX_QUALITY;

/// Which of an item's match strings a hit came from.
#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Field {
    /// The display title.
    Title = 0,
    /// An alternate name that counts almost like the title.
    Alias = 1,
    /// A weaker search term, ranked one tier lower than the same match on a title.
    Keyword = 2,
}

impl Field {
    /// Decodes the two low bits written by `Field as u8`.
    #[inline(always)]
    pub fn from_bits(bits: u8) -> Field {
        match bits & 3 {
            0 => Field::Title,
            1 => Field::Alias,
            _ => Field::Keyword,
        }
    }
}

/// The tier a match of `tier` on `field` ranks in, or `None` when that field cannot produce a hit
/// at that tier (keyword subsequence and typo matches).
#[inline(always)]
pub fn effective_tier(tier: u8, field: Field) -> Option<u8> {
    match field {
        Field::Keyword if tier >= SUBSTRING => Some(tier - 1),
        Field::Keyword => None,
        Field::Title | Field::Alias => Some(tier),
    }
}

/// The rank of a text match, or `None` when the field cannot produce a hit at that tier.
#[inline(always)]
pub fn rank(t: TextScore, field: Field, lift: i32) -> Option<i32> {
    let tier = effective_tier(t.tier, field)?;
    Some(TIER_GAP * tier as i32 + FIELD_BONUS[field as usize] + t.quality as i32 + lift.clamp(0, MAX_LIFT))
}

/// The tier a rank belongs to. Ranks of 7 and up are bands above every text tier.
#[inline(always)]
pub fn tier_of(rank: i32) -> u8 {
    (rank.max(0) / TIER_GAP).min(u8::MAX as i32) as u8
}

/// The lowest raw text tier an entry of `field` with `lift` needs to reach `thresh`. Returns 7
/// when no tier can reach it.
#[inline(always)]
pub(crate) fn floor_tier(thresh: i32, field: Field, lift: i32) -> u8 {
    if thresh == i32::MIN {
        return 0;
    }
    let need = thresh - FIELD_BONUS[field as usize] - MAX_QUALITY - lift.clamp(0, MAX_LIFT);
    let effective = if need <= 0 { 0 } else { (need + TIER_GAP - 1) / TIER_GAP };
    let raw = match field {
        Field::Keyword => (effective + 1).max(SUBSTRING as i32),
        Field::Title | Field::Alias => effective,
    };
    raw.min(7) as u8
}

/// The rank of a word-prefix match with quality 0 on this entry. The bit path adds a quality
/// bound to it to skip segmentation for items that cannot enter the top k.
#[inline(always)]
pub(crate) fn word_prefix_base(field: Field, lift: i32) -> i32 {
    let tier = effective_tier(WORD_PREFIX, field).unwrap_or(WORD_PREFIX);
    TIER_GAP * tier as i32 + FIELD_BONUS[field as usize] + lift.clamp(0, MAX_LIFT)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::score::{EXACT, PREFIX, SUBSEQUENCE, TYPO, UNORDERED};

    fn best(tier: u8, field: Field) -> i32 {
        rank(TextScore::new(tier, MAX_QUALITY), field, MAX_LIFT).unwrap_or(i32::MIN)
    }

    fn worst(tier: u8, field: Field) -> i32 {
        rank(TextScore::new(tier, 0), field, 0).unwrap_or(i32::MAX)
    }

    #[test]
    fn no_lift_crosses_a_tier() {
        for tier in [SUBSEQUENCE, TYPO, SUBSTRING, UNORDERED, WORD_PREFIX, PREFIX, EXACT] {
            for field in [Field::Title, Field::Alias, Field::Keyword] {
                let Some(effective) = effective_tier(tier, field) else {
                    continue;
                };
                assert_eq!(tier_of(best(tier, field)), effective, "{tier} {field:?}");
                assert_eq!(tier_of(worst(tier, field)), effective, "{tier} {field:?}");
            }
        }
    }

    #[test]
    fn title_beats_alias_beats_keyword_at_equal_tier() {
        let t = TextScore::new(PREFIX, 500);
        let title = rank(t, Field::Title, 0);
        let alias = rank(t, Field::Alias, 0);
        let keyword = rank(t, Field::Keyword, 0);
        assert!(title > alias && alias > keyword);
        assert_eq!(tier_of(keyword.unwrap_or(0)), WORD_PREFIX);
    }

    #[test]
    fn keywords_never_hit_at_typo_or_subsequence() {
        assert_eq!(rank(TextScore::new(TYPO, 999), Field::Keyword, 0), None);
        assert_eq!(rank(TextScore::new(SUBSEQUENCE, 999), Field::Keyword, 0), None);
    }

    #[test]
    fn floor_is_the_lowest_tier_that_can_reach_the_threshold() {
        for field in [Field::Title, Field::Alias, Field::Keyword] {
            for lift in [0, 1_234, MAX_LIFT] {
                for thresh in [-5, 0, 9_999, 25_000, 41_000, 66_000, 80_000] {
                    let floor = floor_tier(thresh, field, lift);
                    for tier in 0u8..7 {
                        let reach = rank(TextScore::new(tier, MAX_QUALITY), field, lift).is_some_and(|r| r >= thresh);
                        assert_eq!(
                            reach,
                            tier >= floor,
                            "field {field:?} lift {lift} thresh {thresh} tier {tier}"
                        );
                    }
                }
            }
        }
    }
}
