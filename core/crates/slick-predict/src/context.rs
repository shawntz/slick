//! The context a prediction is made in, and the feature values the zero-query model conditions on.

/// Marks an absent id or feature value.
pub const NONE: u32 = u32::MAX;

/// Context at summon time.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Ctx {
    /// Minutes since the epoch (see `time`).
    pub t: f64,
    /// Local hour, 0..=23.
    pub hour: u8,
    /// Local weekday, 0 = Monday ..= 6 = Sunday.
    pub weekday: u8,
    /// Feature value of the frontmost app (see `front_value`), or `NONE`.
    pub front: u32,
    /// Learn id of the previously executed item, or `NONE`.
    pub prev: u32,
    /// Minutes since the previous execution; infinite when unknown.
    pub since_prev: f64,
    /// First summon after two hours idle, a wake or an unlock.
    pub session_start: bool,
    /// More than one display is connected.
    pub ext_display: bool,
    /// Audio goes to headphones, Bluetooth or USB rather than the built-in speakers.
    pub headphones: bool,
    /// Running on battery.
    pub on_battery: bool,
    /// A Focus mode is on.
    pub focus: bool,
}

impl Default for Ctx {
    fn default() -> Self {
        Ctx {
            t: 0.0,
            hour: 0,
            weekday: 0,
            front: NONE,
            prev: NONE,
            since_prev: f64::INFINITY,
            session_start: false,
            ext_display: false,
            headphones: false,
            on_battery: false,
            focus: false,
        }
    }
}

impl Ctx {
    /// Saturday or Sunday.
    pub fn weekend(&self) -> bool {
        self.weekday >= 5
    }

    /// The device and session flags packed as the event log stores them.
    pub fn flag_bits(&self) -> u16 {
        (self.ext_display as u16)
            | (self.headphones as u16) << 1
            | (self.on_battery as u16) << 2
            | (self.focus as u16) << 3
            | (self.session_start as u16) << 4
    }

    /// Restores the flags packed by `flag_bits`.
    pub fn set_flag_bits(&mut self, bits: u16) {
        self.ext_display = bits & 1 != 0;
        self.headphones = bits & 2 != 0;
        self.on_battery = bits & 4 != 0;
        self.focus = bits & 8 != 0;
        self.session_start = bits & 16 != 0;
    }
}

/// The feature value for a frontmost app key: a 32-bit fold of the key that is never `NONE`.
/// The frontmost app is a context, not a learned item, so it needs no learn id.
pub fn front_value(key: u64) -> u32 {
    if key == 0 {
        return NONE;
    }
    let v = (key ^ (key >> 32)) as u32;
    if v == NONE { v - 1 } else { v }
}

/// Number of context features.
pub const NF: usize = 11;
/// Index of the hour feature.
pub const F_HOUR: usize = 0;
/// Index of the hour-by-day-type feature.
pub const F_HOURDT: usize = 1;
/// Feature names, for the inspector and simulator reports.
pub const FEATURE_NAMES: [&str; NF] = [
    "hour",
    "hour x daytype",
    "daytype",
    "frontmost",
    "previous < 10 min",
    "previous < 2 h",
    "external display",
    "headphones",
    "battery",
    "focus",
    "session start",
];

/// The value of every feature in this context; `NONE` marks an absent feature.
pub fn feature_values(c: &Ctx) -> [u32; NF] {
    let daytype = c.weekend() as u32;
    let hour = c.hour.min(23) as u32;
    [
        hour,
        daytype * 24 + hour,
        daytype,
        c.front,
        if c.since_prev < 10.0 { c.prev } else { NONE },
        if c.since_prev < 120.0 { c.prev } else { NONE },
        c.ext_display as u32,
        c.headphones as u32,
        c.on_battery as u32,
        c.focus as u32,
        c.session_start as u32,
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flags_round_trip_and_front_values_avoid_none() {
        let mut c = Ctx {
            headphones: true,
            session_start: true,
            ..Ctx::default()
        };
        let bits = c.flag_bits();
        c.set_flag_bits(0);
        assert!(!c.headphones);
        c.set_flag_bits(bits);
        assert!(c.headphones && c.session_start && !c.focus);
        assert_eq!(front_value(0), NONE);
        assert_ne!(front_value(u32::MAX as u64), NONE);
    }
}
