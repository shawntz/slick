//! The context the app reports whenever it changes: time, frontmost app and device state.

use slick_predict::Situation;

/// Where audio goes.
pub mod audio {
    /// Built-in speakers.
    pub const BUILT_IN: u8 = 0;
    /// Wired headphones.
    pub const HEADPHONES: u8 = 1;
    /// Bluetooth.
    pub const BLUETOOTH: u8 = 2;
    /// USB.
    pub const USB: u8 = 3;
    /// AirPlay or anything else.
    pub const OTHER: u8 = 4;
}

/// A small feature vector, set whenever one of its values changes. Suggestions and the context
/// prior are recomputed then, so the hotkey path never computes them.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Context {
    /// Unix time, seconds.
    pub now: f64,
    /// Local hour, 0..=23.
    pub hour: u8,
    /// Local weekday, 0 = Monday ..= 6 = Sunday.
    pub weekday: u8,
    /// Key of the frontmost app, 0 when unknown. It is never suggested.
    pub frontmost: u64,
    /// Key of the previously executed item, 0 to use the engine's own record.
    pub previous: u64,
    /// Seconds since `previous` ran (ignored when `previous` is 0).
    pub since_previous: f64,
    /// Running on battery.
    pub on_battery: bool,
    /// Connected displays.
    pub display_count: u8,
    /// See [`audio`].
    pub audio_route: u8,
    /// First summon after two hours idle, a wake or an unlock.
    pub session_start: bool,
    /// A Focus mode is on.
    pub focus: bool,
}

impl Context {
    /// The context as the learning code takes it.
    pub fn situation(&self) -> Situation {
        let headphones = matches!(self.audio_route, audio::HEADPHONES | audio::BLUETOOTH | audio::USB);
        let flags = (self.display_count > 1) as u16
            | (headphones as u16) << 1
            | (self.on_battery as u16) << 2
            | (self.focus as u16) << 3
            | (self.session_start as u16) << 4;
        Situation {
            hour: self.hour.min(23),
            weekday: self.weekday.min(6),
            frontmost: self.frontmost,
            flags,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use slick_predict::context::Ctx;

    #[test]
    fn device_state_maps_to_the_model_flags() {
        let c = Context {
            display_count: 2,
            audio_route: audio::BLUETOOTH,
            on_battery: true,
            ..Context::default()
        };
        let mut ctx = Ctx::default();
        ctx.set_flag_bits(c.situation().flags);
        assert!(ctx.ext_display && ctx.headphones && ctx.on_battery && !ctx.focus);
    }
}
