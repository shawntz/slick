//! A minimal JSON writer for the statistics the settings inspector reads.

use std::fmt::Write;

/// Appends JSON values to a string. The caller places commas and brackets.
pub(crate) struct Json(pub(crate) String);

impl Json {
    /// A JSON string literal, escaped.
    pub(crate) fn string(&mut self, s: &str) {
        self.0.push('"');
        for c in s.chars() {
            match c {
                '"' => self.0.push_str("\\\""),
                '\\' => self.0.push_str("\\\\"),
                '\n' => self.0.push_str("\\n"),
                '\r' => self.0.push_str("\\r"),
                '\t' => self.0.push_str("\\t"),
                c if (c as u32) < 0x20 => {
                    // Writing to a String cannot fail.
                    let _ = write!(self.0, "\\u{:04x}", c as u32);
                }
                c => self.0.push(c),
            }
        }
        self.0.push('"');
    }

    /// `"name":` followed by nothing.
    pub(crate) fn key(&mut self, name: &str) {
        self.string(name);
        self.0.push(':');
    }

    /// A finite number, or null.
    pub(crate) fn number(&mut self, v: f64) {
        if v.is_finite() {
            let _ = write!(self.0, "{}", (v * 10_000.0).round() / 10_000.0);
        } else {
            self.0.push_str("null");
        }
    }

    /// An integer.
    pub(crate) fn int(&mut self, v: u64) {
        let _ = write!(self.0, "{v}");
    }

    /// `true` or `false`.
    pub(crate) fn bool(&mut self, v: bool) {
        self.0.push_str(if v { "true" } else { "false" });
    }

    /// Raw punctuation.
    pub(crate) fn raw(&mut self, s: &str) {
        self.0.push_str(s);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strings_are_escaped() {
        let mut j = Json(String::new());
        j.string("a\"b\\c\n\u{1}é");
        assert_eq!(j.0, "\"a\\\"b\\\\c\\n\\u0001é\"");
        let mut j = Json(String::new());
        j.number(f64::NAN);
        j.raw(",");
        j.number(0.123456);
        assert_eq!(j.0, "null,0.1235");
    }
}
