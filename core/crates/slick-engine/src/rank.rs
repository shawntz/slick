//! The ranking contract's formula and constants.
//!
//! Every ranked list is ordered by one `i32` rank in the layout of `slick_match::rank`:
//!
//! ```text
//! text hit       = 10,000 * tier + field bonus (title 2,000, alias 1,000, keyword 0)
//!                + text quality (0..=999) + lift
//! lift           = frecency (0..=4,000) + context (0..=2,000) + static prior (0..=1,000)
//! affinity hit   = text hit + 6,000 * w / (W + 1)          (query affinity outside the band)
//! learned band   = 80,000 + lift                           (the row's band holder, w >= 1.1)
//! alias prefix   = 90,000 + alias quality (0..=999) + lift
//! alias exact    = 100,000 + lift
//! ties           = shorter title, then smaller key
//! ```
//!
//! Field bonus, quality and lift add up to at most 9,999, so frecency, context and priors only
//! reorder items inside a tier (rule 3). Affinity outside the band adds less than 6,000, so with
//! everything else it can lift an item over the next tier but never over two (rule 3); even an
//! exact title with affinity stays below 76,000. The band sits above that (rule 2), user aliases
//! above everything (rule 1). Rule 4 comes from the band holder each affinity row keeps (see
//! `slick_predict::affinity`), rule 5 from the integer ranks and the index order. The band
//! threshold is `AffinityParams::band_weight`, because the affinity table decides who holds it.

use slick_match::rank::{MAX_LIFT, TIER_GAP};

/// The tier reported for a learned-band hit. Tier 7 is left free: an exact title lifted by
/// affinity can reach into its rank range.
pub const TIER_LEARNED: u8 = 8;
/// The tier reported for a hit whose user alias starts with the query.
pub const TIER_ALIAS_PREFIX: u8 = 9;
/// The tier reported for a hit whose user alias equals the query.
pub const TIER_ALIAS_EXACT: u8 = 10;

/// Item kinds the engine knows priors for. Other values are allowed and get no kind prior.
pub mod kind {
    /// Anything else.
    pub const OTHER: u8 = 0;
    /// An application.
    pub const APP: u8 = 1;
    /// A command of a feature or extension.
    pub const COMMAND: u8 = 2;
    /// A file or folder.
    pub const FILE: u8 = 3;
    /// A settings pane.
    pub const SETTING: u8 = 4;
    /// A contact.
    pub const CONTACT: u8 = 5;
}

/// The constants of the formula. `Default` holds the tuned values; the simulator varies them.
#[derive(Clone, Debug, PartialEq)]
pub struct RankParams {
    /// Lift at full typed frecency.
    pub frecency: i32,
    /// Lift at full context prior (the zero-query probability relative to the most likely item).
    pub context: i32,
    /// Lift at a full static prior (kind prior plus the item's own prior, capped at 1).
    pub prior: i32,
    /// Lift at a full affinity share `w / (W + kappa)`.
    pub affinity: i32,
    /// Smoothing of the affinity share.
    pub kappa: f64,
    /// Rank lead over the second hit from which the top hit is completed inline.
    pub completion_margin: i32,
    /// Static prior per kind, indexed by kind (see [`kind`]).
    pub kind_priors: [f32; 8],
}

impl Default for RankParams {
    fn default() -> Self {
        RankParams {
            frecency: 4_000,
            context: 2_000,
            prior: 1_000,
            affinity: 6_000,
            kappa: 1.0,
            completion_margin: 3_000,
            kind_priors: [0.0, 0.6, 0.2, 0.0, 0.1, 0.0, 0.0, 0.0],
        }
    }
}

impl RankParams {
    /// The static lift of an item: its kind prior plus its own prior, capped at 1.
    pub fn static_lift(&self, kind: u8, prior: f32) -> i32 {
        let k = self.kind_priors.get(kind as usize).copied().unwrap_or(0.0);
        let p = if prior.is_finite() { prior } else { 0.0 };
        (self.prior as f32 * (k + p).clamp(0.0, 1.0)).round() as i32
    }

    /// The learned part of the lift: typed frecency and context prior, both in [0, 1].
    pub fn learned_lift(&self, frecency: f64, context: f64) -> i32 {
        (self.frecency as f64 * frecency.clamp(0.0, 1.0) + self.context as f64 * context.clamp(0.0, 1.0)).round() as i32
    }

    /// The lift added for an affinity weight `w` in a row of total `total`.
    pub fn affinity_lift(&self, w: f64, total: f64) -> i32 {
        if w <= 0.0 || !w.is_finite() {
            return 0;
        }
        (self.affinity as f64 * w / (total + self.kappa)).round() as i32
    }

    /// True when the constants keep the contract: within-tier lifts never cross a tier, and
    /// affinity crosses at most one.
    pub fn keeps_the_contract(&self) -> bool {
        let within = self.frecency + self.context + self.prior;
        within <= MAX_LIFT && self.affinity < TIER_GAP && self.kappa > 0.0
    }
}

/// Rank of a learned-band hit with lift `lift`.
pub fn learned_band(lift: i32) -> i32 {
    TIER_GAP * TIER_LEARNED as i32 + lift.clamp(0, MAX_LIFT)
}

/// Rank of a user-alias hit: exact, or a prefix with `extra` chars of the alias not typed.
pub fn alias_band(exact: bool, extra: usize, lift: i32) -> i32 {
    let lift = lift.clamp(0, MAX_LIFT);
    if exact {
        TIER_GAP * TIER_ALIAS_EXACT as i32 + lift
    } else {
        TIER_GAP * TIER_ALIAS_PREFIX as i32 + (999 - 6 * extra.min(60) as i32) + lift
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_defaults_keep_the_contract() {
        let p = RankParams::default();
        assert!(p.keeps_the_contract());
        assert_eq!(p.learned_lift(1.0, 1.0) + p.static_lift(kind::APP, 1.0), MAX_LIFT);
        assert!(p.affinity_lift(1e9, 1e9) < TIER_GAP);
        assert!(alias_band(false, 0, MAX_LIFT) < alias_band(true, 0, 0));
        assert!(learned_band(MAX_LIFT) < alias_band(false, 60, 0));
        let exact_with_affinity = TIER_GAP * 6 + TIER_GAP - 1 + p.affinity_lift(1e9, 1e9);
        assert!(exact_with_affinity < learned_band(0));
    }

    /// Rule 4 in numbers: one pick (weight 1) stays out of the band, and a two-pick habit after
    /// one stray pick (gamma + gamma^2) stays in it.
    #[test]
    fn the_band_threshold_fits_the_affinity_decay() {
        let p = slick_predict::affinity::AffinityParams::default();
        let (gamma, band) = (p.gamma, p.band_weight);
        assert!(band.is_finite() && band > 0.0);
        assert!(band > 1.0, "one pick enters the band");
        assert!(band <= gamma + gamma * gamma, "one stray pick drops a two-pick habit");
    }
}
