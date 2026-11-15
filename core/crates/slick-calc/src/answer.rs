//! The structured result of one evaluation, built to be reused across keystrokes.

/// What an answer is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
#[repr(u8)]
pub enum Kind {
    /// Not a calculation. Nothing else in the answer is meaningful.
    #[default]
    None = 0,
    Number = 1,
    Percent = 2,
    /// A number with a unit, such as a length or a temperature.
    Quantity = 3,
    /// A length of time, such as "3 h 15 min" or "40 days".
    Duration = 4,
    Currency = 5,
    Date = 6,
    /// A moment or a time of day, possibly in another time zone.
    Time = 7,
    /// Text, such as a number in words or a weekday.
    Text = 8,
    /// The query is a calculation that has no answer. `main` says why.
    Error = 9,
}

/// Why a calculation has no answer.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
#[repr(u8)]
pub enum Problem {
    #[default]
    None = 0,
    DivisionByZero = 1,
    Overflow = 2,
    Undefined = 3,
    NotReal = 4,
    NotWhole = 5,
    IncompatibleUnits = 6,
    NoRates = 7,
    NoRate = 8,
    NoTimeZones = 9,
    UnknownZone = 10,
    InvalidDate = 11,
    Unsupported = 12,
}

impl Problem {
    /// A short sentence for the user.
    pub fn message(self) -> &'static str {
        match self {
            Problem::None => "",
            Problem::DivisionByZero => "Division by zero",
            Problem::Overflow => "Number too large",
            Problem::Undefined => "Undefined",
            Problem::NotReal => "Not a real number",
            Problem::NotWhole => "Needs a whole number",
            Problem::IncompatibleUnits => "These units do not convert",
            Problem::NoRates => "Exchange rates are not loaded",
            Problem::NoRate => "No exchange rate for this currency",
            Problem::NoTimeZones => "Time zone data is not loaded",
            Problem::UnknownZone => "Unknown time zone",
            Problem::InvalidDate => "Not a valid date",
            Problem::Unsupported => "Not supported",
        }
    }
}

/// The most alternate forms an answer carries.
pub const MAX_ALTERNATES: usize = 4;

/// Another way to write the answer, such as the value in hex or in the other unit system.
#[derive(Clone, Debug, Default)]
pub struct Alternate {
    /// A short label such as "Hex", "Fraction" or "Imperial".
    pub label: &'static str,
    pub text: String,
}

/// The result of [`crate::evaluate`]. Reuse one value across calls: its strings keep their
/// capacity, and a rejected query leaves them untouched.
#[derive(Clone, Debug, Default)]
pub struct Answer {
    pub kind: Kind,
    /// How sure the engine is that the query was meant as a calculation, from 0 to 100. At
    /// [`CLAIMS_TOP`](crate::CLAIMS_TOP) or more the answer should claim the top of the list.
    pub confidence: u8,
    /// Set when `kind` is [`Kind::Error`].
    pub problem: Problem,
    /// The formatted answer, with grouping separators and unit names, such as "3.10686 mi".
    pub main: String,
    /// The value to copy: no grouping, no unit, the caller's decimal separator. Dates are ISO
    /// 8601. Equal to `main` for text.
    pub copy: String,
    /// Context for the answer, such as the rate date or the zone name. May be empty.
    pub note: String,
    alternates: [Alternate; MAX_ALTERNATES],
    alternate_count: usize,
}

impl Answer {
    pub fn new() -> Answer {
        Answer::default()
    }

    /// The alternate forms, best first.
    pub fn alternates(&self) -> &[Alternate] {
        self.alternates.get(..self.alternate_count).unwrap_or(&[])
    }

    /// True when the evaluation produced an answer or an error.
    pub fn is_some(&self) -> bool {
        self.kind != Kind::None
    }

    /// Empties the answer, keeping string capacity. Touches only `kind` when already empty.
    pub(crate) fn clear(&mut self) {
        if self.kind == Kind::None && self.alternate_count == 0 && self.main.is_empty() {
            return;
        }
        self.kind = Kind::None;
        self.confidence = 0;
        self.problem = Problem::None;
        self.main.clear();
        self.copy.clear();
        self.note.clear();
        for alt in &mut self.alternates {
            alt.label = "";
            alt.text.clear();
        }
        self.alternate_count = 0;
    }

    /// The next alternate slot to fill, or None when all are used. Call [`Answer::commit_alternate`]
    /// once its text is written.
    pub(crate) fn next_alternate(&mut self, label: &'static str) -> Option<&mut String> {
        let alt = self.alternates.get_mut(self.alternate_count)?;
        alt.label = label;
        alt.text.clear();
        Some(&mut alt.text)
    }

    pub(crate) fn commit_alternate(&mut self) {
        let Some(alt) = self.alternates.get(self.alternate_count) else {
            return;
        };
        if alt.text.is_empty() || alt.text == self.main {
            return;
        }
        let duplicate = self.alternates().iter().any(|a| a.text == alt.text);
        if !duplicate {
            self.alternate_count += 1;
        }
    }
}
