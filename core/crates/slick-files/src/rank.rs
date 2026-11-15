//! The rank layout of file hits.
//!
//! A rank is one `i32`: `TIER_GAP * tier + quality (0..=999) + lift (0..=MAX_LIFT)`. Tiers never
//! mix: the lift only reorders hits inside a tier. File tiers, weakest first:
//!
//! | tier | name | from |
//! |---|---|---|
//! | 0 | subsequence | `slick_match` subsequence on the name |
//! | 1 | typo | `slick_match` typo pass on the name |
//! | 2 | ancestor | some tokens match the name, the others start words of folders above it |
//! | 3 | substring | `slick_match` substring |
//! | 4 | unordered | `slick_match` unordered words |
//! | 5 | word-prefix | `slick_match` word-prefix |
//! | 6 | prefix | `slick_match` prefix |
//! | 7 | exact | `slick_match` exact |
//!
//! The ancestor tier sits below every contiguous match on the name and above scattered ones, so
//! "docs readme" puts `docs/README.md` above a name that only scatters those letters.

use slick_match::score::{EXACT, PREFIX, WORD_PREFIX};
use slick_match::{TextScore, bits::Bound};

/// Distance between two adjacent tiers.
pub const TIER_GAP: i32 = 10_000;
/// Largest lift. Quality and lift together stay below `TIER_GAP`.
pub const MAX_LIFT: i32 = 8_000;
/// Highest quality inside a tier.
pub const MAX_QUALITY: i32 = 999;

/// File tier constants.
pub mod tier {
    pub const SUBSEQUENCE: u8 = 0;
    pub const TYPO: u8 = 1;
    pub const ANCESTOR: u8 = 2;
    pub const SUBSTRING: u8 = 3;
    pub const UNORDERED: u8 = 4;
    pub const WORD_PREFIX: u8 = 5;
    pub const PREFIX: u8 = 6;
    pub const EXACT: u8 = 7;
    /// Names for reports, indexed by tier.
    pub const NAMES: [&str; 8] = [
        "subsequence",
        "typo",
        "ancestor",
        "substring",
        "unordered",
        "word-prefix",
        "prefix",
        "exact",
    ];
}

/// The file tier of a `slick_match` text tier.
#[inline(always)]
pub fn file_tier(text_tier: u8) -> u8 {
    if text_tier <= 1 { text_tier } else { text_tier + 1 }
}

/// The rank of a text match on a name.
#[inline(always)]
pub fn name_rank(t: TextScore, lift: i32) -> i32 {
    TIER_GAP * file_tier(t.tier) as i32 + t.quality as i32 + lift.clamp(0, MAX_LIFT)
}

/// The rank of an ancestor match whose name part scored `t`.
#[inline(always)]
pub fn ancestor_rank(t: TextScore, lift: i32) -> i32 {
    let q = ((t.tier as i32).min(EXACT as i32) * 1_000 + t.quality as i32) * MAX_QUALITY / (EXACT as i32 * 1_000 + 999);
    TIER_GAP * tier::ANCESTOR as i32 + q + lift.clamp(0, MAX_LIFT)
}

/// The best rank any match of file tier `t` can reach with this lift.
#[inline(always)]
pub(crate) fn best_in_tier(t: u8, lift: i32) -> i32 {
    TIER_GAP * t as i32 + MAX_QUALITY + lift.clamp(0, MAX_LIFT)
}

/// The tier of a rank.
#[inline(always)]
pub fn tier_of(rank: i32) -> u8 {
    (rank.max(0) / TIER_GAP).min(u8::MAX as i32) as u8
}

/// The lowest `slick_match` text tier that can still reach `thresh`, and the rank bound the bit
/// path uses to skip segmentation. Returns a floor of 7 when nothing can reach it.
#[inline(always)]
pub(crate) fn floor_and_bound(thresh: i32, lift: i32) -> (u8, Bound) {
    if thresh == i32::MIN {
        return (0, Bound::NONE);
    }
    let lift = lift.clamp(0, MAX_LIFT);
    // Lowest file tier whose best rank reaches the threshold.
    let need = thresh - MAX_QUALITY - lift;
    let ft = if need <= 0 { 0 } else { (need + TIER_GAP - 1) / TIER_GAP };
    // File tiers 0 and 1 are text tiers 0 and 1; file tier t >= 3 is text tier t - 1; file tier
    // 2, the ancestor tier, has no text tier, so the next one up is text tier 2.
    let floor = match ft {
        0 | 1 => ft,
        2 => 2,
        t => t - 1,
    };
    (
        floor.min(7) as u8,
        Bound {
            thresh,
            word_prefix_base: TIER_GAP * file_tier(WORD_PREFIX) as i32 + lift,
        },
    )
}

/// True for a hit in the prefix or exact tier, which only a name that starts with the query's
/// first char can reach.
#[inline(always)]
pub(crate) fn is_prefix_tier(rank: i32) -> bool {
    tier_of(rank) >= file_tier(PREFIX)
}

/// Which kinds of entries get a lift.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum Prefer {
    #[default]
    Neither,
    Files,
    Folders,
}

/// The within-tier ranking signals. Each part is a lift, so none of them crosses a tier.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct RankParams {
    /// Lift of an entry modified within `recent_secs`. It falls linearly in log time to 0 at
    /// `stale_secs`.
    pub recency: i32,
    pub recent_secs: u32,
    pub stale_secs: u32,
    /// Lift of an entry right below a root. Each level deeper loses `depth_step`.
    pub shallow: i32,
    pub depth_step: i32,
    /// Lift of the kind [`Prefer`] names.
    pub kind: i32,
}

impl Default for RankParams {
    fn default() -> Self {
        RankParams {
            recency: 1_200,
            recent_secs: 3_600,
            stale_secs: 1 << 29,
            shallow: 800,
            depth_step: 80,
            kind: 400,
        }
    }
}

/// Computes lifts for one search.
#[derive(Clone, Debug)]
pub(crate) struct Lifter {
    by_age_bucket: [i32; 33],
    now: u32,
    shallow: i32,
    depth_step: i32,
    kind: i32,
    prefer: Prefer,
}

impl Lifter {
    pub(crate) fn new(p: &RankParams, now: u32, prefer: Prefer) -> Lifter {
        let bucket = |s: u32| 32 - s.leading_zeros() as i32;
        let full = bucket(p.recent_secs.max(1));
        let zero = bucket(p.stale_secs.max(p.recent_secs.max(1) * 2)).max(full + 1);
        let mut by_age_bucket = [0i32; 33];
        for (b, slot) in by_age_bucket.iter_mut().enumerate() {
            let b = b as i32;
            *slot = if b <= full {
                p.recency
            } else if b >= zero {
                0
            } else {
                p.recency * (zero - b) / (zero - full)
            };
        }
        Lifter {
            by_age_bucket,
            now,
            shallow: p.shallow,
            depth_step: p.depth_step,
            kind: p.kind,
            prefer,
        }
    }

    /// The lift of an entry.
    #[inline(always)]
    pub(crate) fn lift(&self, mtime: u32, depth: u8, is_dir: bool) -> i32 {
        let age = self.now.saturating_sub(mtime);
        let recency = self.by_age_bucket[(32 - age.leading_zeros()) as usize];
        let shallow = (self.shallow - self.depth_step * (depth as i32 - 1).max(0)).max(0);
        let kind = match self.prefer {
            Prefer::Folders if is_dir => self.kind,
            Prefer::Files if !is_dir => self.kind,
            _ => 0,
        };
        (recency + shallow + kind).clamp(0, MAX_LIFT)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_lifts_stay_inside_a_tier() {
        let p = RankParams::default();
        assert!(p.recency + p.shallow + p.kind <= MAX_LIFT);
        const { assert!(MAX_QUALITY + MAX_LIFT < TIER_GAP) };
    }

    #[test]
    fn floor_is_the_lowest_text_tier_that_can_reach_the_threshold() {
        for lift in [0, 500, MAX_LIFT] {
            for thresh in [-1, 0, 15_000, 25_000, 41_234, 66_000, 79_999, 90_000] {
                let (floor, _) = floor_and_bound(thresh, lift);
                for t in 0..=EXACT {
                    let reach = name_rank(TextScore::new(t, 999), lift) >= thresh;
                    assert_eq!(reach, t >= floor, "lift {lift} thresh {thresh} tier {t}");
                }
            }
        }
    }

    #[test]
    fn ancestor_tier_sits_between_scattered_and_contiguous_name_matches() {
        let best_anc = ancestor_rank(TextScore::new(EXACT, 999), MAX_LIFT);
        let worst_anc = ancestor_rank(TextScore::new(0, 0), 0);
        assert_eq!(tier_of(best_anc), tier::ANCESTOR);
        assert_eq!(tier_of(worst_anc), tier::ANCESTOR);
        assert!(best_anc < name_rank(TextScore::new(slick_match::score::SUBSTRING, 0), 0));
        assert!(worst_anc > name_rank(TextScore::new(slick_match::score::TYPO, 999), MAX_LIFT));
    }

    #[test]
    fn newer_and_shallower_entries_lift_more() {
        let l = Lifter::new(&RankParams::default(), 1_000_000_000, Prefer::Folders);
        let now = 1_000_000_000;
        assert!(l.lift(now, 1, false) > l.lift(now - 86_400 * 30, 1, false));
        assert!(l.lift(now - 86_400 * 30, 1, false) > l.lift(now - 86_400 * 3_000, 1, false));
        assert!(l.lift(now, 1, false) > l.lift(now, 6, false));
        assert!(l.lift(now, 3, true) > l.lift(now, 3, false));
        assert_eq!(
            l.lift(now + 50, 1, false),
            l.lift(now, 1, false),
            "future times count as now"
        );
    }
}
