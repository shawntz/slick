//! The first gate: decides in tens of nanoseconds that most queries are not math.
//!
//! A query with a digit or a math symbol goes on to the parser. A query of letters only goes on
//! when it is one word that is an answer by itself, such as "pi" or "today", or when its first
//! word can start a calculation, as in "time in tokyo", "km to miles" and "next friday".

use crate::lexicon;

/// Single words that are a calculation on their own.
pub(crate) const STANDALONE: &[&str] = &[
    "pi",
    "tau",
    "phi",
    "now",
    "today",
    "tomorrow",
    "yesterday",
    "time",
    "unix",
    "epoch",
];

/// First words that start a phrase form even though no table names them.
pub(crate) const STARTERS: &[&str] = &[
    "a",
    "an",
    "between",
    "calc",
    "calculate",
    "change",
    "compute",
    "convert",
    "coming",
    "cube",
    "current",
    "day",
    "decrease",
    "diff",
    "epoch",
    "eval",
    "evaluate",
    "from",
    "half",
    "how",
    "in",
    "increase",
    "last",
    "midnight",
    "midday",
    "minus",
    "negative",
    "next",
    "noon",
    "now",
    "past",
    "pct",
    "percent",
    "percentage",
    "posix",
    "previous",
    "square",
    "this",
    "time",
    "timestamp",
    "timezone",
    "today",
    "tomorrow",
    "tz",
    "unix",
    "weekday",
    "what",
    "what's",
    "whats",
    "which",
    "yesterday",
];

fn in_list(word: &str, list: &[&str]) -> bool {
    word.len() <= 12 && list.iter().any(|w| w.eq_ignore_ascii_case(word))
}

/// True when `word` can begin a calculation: a starter, or a name in the lexicon.
fn starts_math(word: &str) -> bool {
    in_list(word, STARTERS) || in_list(word, STANDALONE) || lexicon::may_start(word)
}

/// False when the query cannot be a calculation.
pub(crate) fn might_be_math(q: &str) -> bool {
    let b = q.as_bytes();
    let mut symbolic = false;
    let mut ascii = true;
    let mut words = 0usize;
    let mut in_word = false;
    let mut first_end = b.len();
    let mut last_start = 0usize;
    for (i, &c) in b.iter().enumerate() {
        if c >= 0x80 {
            ascii = false;
            continue;
        }
        if c.is_ascii_digit()
            || matches!(
                c,
                b'+' | b'-' | b'*' | b'/' | b'^' | b'(' | b')' | b'%' | b'$' | b'=' | b'!' | b'@' | b'"' | b'['
            )
        {
            symbolic = true;
            break;
        }
        if c == b' ' || c == b'\t' {
            if in_word && words == 1 {
                first_end = i;
            }
            in_word = false;
        } else if !in_word {
            in_word = true;
            words += 1;
            last_start = i;
        }
    }
    // Symbols such as π, €, ², °, √ and × mean math; letters with accents do not.
    if !symbolic && !ascii {
        symbolic = q
            .chars()
            .any(|c| !c.is_ascii() && !c.is_alphabetic() && !c.is_whitespace())
            || q.contains('π');
    }
    if symbolic {
        // A query that opens with a word must open with one that can start a calculation:
        // "notes 2024" and "iphone 15 pro" stop here. "US$5" and "C$20" open with a currency.
        if b.first().is_some_and(u8::is_ascii_alphabetic) {
            let end = q
                .char_indices()
                .find(|(_, c)| !c.is_alphabetic())
                .map_or(q.len(), |(i, _)| i);
            let word = q.get(..end).unwrap_or(q);
            if b.get(end) != Some(&b'$') && !starts_math(word) {
                return false;
            }
        }
        return true;
    }
    // Letters only.
    let first = q.get(..first_end).unwrap_or(q).trim();
    if words <= 1 {
        return in_list(first, STANDALONE);
    }
    let last = q.get(last_start..).unwrap_or("").trim();
    if last.eq_ignore_ascii_case("time") || last.eq_ignore_ascii_case("now") {
        return true;
    }
    starts_math(first)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn letters_only() {
        assert!(!might_be_math("safari"));
        assert!(!might_be_math("visual studio code"));
        assert!(!might_be_math("google chrome"));
        assert!(might_be_math("pi"));
        assert!(might_be_math("time in tokyo"));
        assert!(might_be_math("tokyo time"));
        assert!(might_be_math("km to miles"));
        assert!(might_be_math("next friday"));
        assert!(might_be_math("new york time"));
        assert!(might_be_math("days until christmas"));
        assert!(might_be_math("2+2"));
        assert!(!might_be_math("v2"));
        assert!(!might_be_math("notes 2024"));
        assert!(!might_be_math("iphone 15 pro"));
        assert!(might_be_math("log2(8)"));
        assert!(might_be_math("US$5 in eur"));
        assert!(might_be_math("e^2"));
        assert!(might_be_math("malmö time"));
    }
}
