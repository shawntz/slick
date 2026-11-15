//! Splits a query into tokens on the stack. No allocation.

use crate::cal;
use crate::num::{self, Num};

/// The most tokens one query may have.
pub(crate) const MAX_TOKENS: usize = 48;
/// The most number literals one query may have.
pub(crate) const MAX_NUMS: usize = 16;

/// Token kinds.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum K {
    /// A number literal; `aux` indexes [`Lexed::nums`].
    Num,
    /// A run of letters with at most one glued digit, such as "log2" or "m2".
    Word,
    /// `H:MM` or `H:MM:SS`; `aux` is the second of the day.
    Clock,
    /// `YYYY-MM-DD`; `aux` is the day number since 1970-01-01.
    Date,
    /// One symbol, normalized: `−` is '-', `×` is '*', `**` is '^', `->` is '→'.
    Sym,
    End,
}

/// Number literal flags.
pub(crate) const HEX: u8 = 1;
pub(crate) const BIN: u8 = 2;
pub(crate) const OCT: u8 = 4;
pub(crate) const SCI: u8 = 8;
pub(crate) const ORDINAL: u8 = 16;
pub(crate) const SCALED: u8 = 32;
pub(crate) const FRACTION: u8 = 64;
pub(crate) const GROUPED: u8 = 128;
pub(crate) const BASED: u8 = HEX | BIN | OCT;

#[derive(Clone, Copy, Debug)]
pub(crate) struct Tok {
    pub k: K,
    pub sym: char,
    pub start: u16,
    pub end: u16,
    /// Whitespace comes right before the token.
    pub space: bool,
    pub flags: u8,
    pub aux: i32,
}

impl Tok {
    const END: Tok = Tok {
        k: K::End,
        sym: '\0',
        start: 0,
        end: 0,
        space: false,
        flags: 0,
        aux: 0,
    };
}

pub(crate) struct Lexed {
    pub toks: [Tok; MAX_TOKENS + 1],
    pub nums: [Num; MAX_NUMS],
    pub len: usize,
    nnum: usize,
}

impl Lexed {
    pub(crate) fn new() -> Lexed {
        Lexed {
            toks: [Tok::END; MAX_TOKENS + 1],
            nums: [Num::ZERO; MAX_NUMS],
            len: 0,
            nnum: 0,
        }
    }

    fn push(&mut self, t: Tok) -> bool {
        match self.toks.get_mut(self.len) {
            Some(slot) if self.len < MAX_TOKENS => {
                *slot = t;
                self.len += 1;
                true
            }
            _ => false,
        }
    }

    fn push_num(&mut self, v: Num) -> Option<i32> {
        let slot = self.nums.get_mut(self.nnum)?;
        *slot = v;
        self.nnum += 1;
        i32::try_from(self.nnum - 1).ok()
    }
}

fn sym_of(c: char) -> Option<char> {
    Some(match c {
        '+' | '＋' => '+',
        '-' | '−' | '–' | '—' => '-',
        '*' | '×' | '·' | '⋅' | '∙' | '✕' => '*',
        '/' | '÷' | '∕' => '/',
        '^' => '^',
        '(' | '[' | '{' => '(',
        ')' | ']' | '}' => ')',
        ',' => ',',
        ';' => ';',
        '!' => '!',
        '%' => '%',
        '=' => '=',
        '²' => '²',
        '³' => '³',
        '\'' | '′' | '’' => '\'',
        '"' | '″' | '”' | '“' => '"',
        '°' | 'º' => '°',
        '$' | '€' | '£' | '¥' | '₹' | '₩' | '₽' | '₺' | '₪' | '₫' | '₱' | '฿' | '₴' | '₦' | '₿' | '¢' | '元' => {
            c
        }
        '√' => '√',
        '∛' => '∛',
        '@' => '@',
        '.' => '.',
        ':' => ':',
        '?' => '?',
        '&' => '&',
        '→' | '⇒' => '→',
        'π' => 'π',
        _ => return None,
    })
}

fn is_digit(b: Option<&u8>) -> bool {
    matches!(b, Some(c) if c.is_ascii_digit())
}

fn is_alpha_at(src: &str, i: usize) -> bool {
    src.get(i..)
        .and_then(|s| s.chars().next())
        .is_some_and(|c| c.is_alphabetic())
}

/// Tokenizes `src`. False when the query holds something no calculation uses.
pub(crate) fn lex(src: &str, decimal: char, grouping: Option<char>, out: &mut Lexed) -> bool {
    out.len = 0;
    out.nnum = 0;
    let b = src.as_bytes();
    let mut i = 0;
    let mut space = false;
    // Paren depth and whether each open paren follows a word, so commas inside calls separate
    // arguments instead of grouping digits.
    let mut call_parens: u32 = 0;
    let mut depth: u32 = 0;
    while i < b.len() {
        let Some(c) = src.get(i..).and_then(|s| s.chars().next()) else {
            return false;
        };
        let clen = c.len_utf8();
        if c.is_whitespace() {
            space = true;
            i += clen;
            continue;
        }
        let start = i;
        let starts_number = c.is_ascii_digit() || (c == decimal && is_digit(b.get(i + 1)));
        if starts_number {
            let in_call = depth > 0 && (call_parens >> (depth.min(31) - 1)) & 1 == 1;
            let Some((tok, end)) = lex_number(src, i, decimal, grouping, in_call, out) else {
                return false;
            };
            let tok = Tok {
                start: start as u16,
                end: end as u16,
                space,
                ..tok
            };
            if !out.push(tok) {
                return false;
            }
            i = end;
        } else if c.is_alphabetic() && c != 'π' {
            let mut j = i;
            while let Some(ch) = src.get(j..).and_then(|s| s.chars().next()) {
                if ch.is_alphabetic() && ch != 'π' {
                    j += ch.len_utf8();
                } else {
                    break;
                }
            }
            let word = src.get(i..j).unwrap_or("");
            // "valentine's"
            if b.get(j) == Some(&b'\'') && b.get(j + 1) == Some(&b's') && !is_alpha_at(src, j + 2) {
                j += 2;
            }
            // One glued digit: "log2", "m2", "km3". "log10" too. Not after "x", which multiplies.
            if !word.eq_ignore_ascii_case("x") && is_digit(b.get(j)) {
                if word.eq_ignore_ascii_case("log") && b.get(j..j + 2) == Some(b"10") && !is_digit(b.get(j + 2)) {
                    j += 2;
                } else if !is_digit(b.get(j + 1)) && !is_alpha_at(src, j + 1) && b.get(j + 1) != Some(&(decimal as u8))
                {
                    j += 1;
                }
            }
            let tok = Tok {
                k: K::Word,
                sym: '\0',
                start: start as u16,
                end: j as u16,
                space,
                flags: 0,
                aux: 0,
            };
            if !out.push(tok) {
                return false;
            }
            i = j;
        } else {
            let mut s = sym_of(c);
            let mut end = i + clen;
            if c == '*' && b.get(i + 1) == Some(&b'*') {
                s = Some('^');
                end += 1;
            } else if (c == '-' || c == '=') && b.get(i + 1) == Some(&b'>') {
                s = Some('→');
                end += 1;
            }
            let Some(s) = s else { return false };
            if s == '(' {
                depth += 1;
                let after_word = out.len > 0 && out.toks.get(out.len - 1).is_some_and(|t| t.k == K::Word && !space);
                if depth <= 31 {
                    let bit = 1u32 << (depth - 1);
                    if after_word {
                        call_parens |= bit;
                    } else {
                        call_parens &= !bit;
                    }
                }
            } else if s == ')' {
                depth = depth.saturating_sub(1);
            }
            let tok = Tok {
                k: K::Sym,
                sym: s,
                start: start as u16,
                end: end as u16,
                space,
                flags: 0,
                aux: 0,
            };
            if !out.push(tok) {
                return false;
            }
            i = end;
        }
        space = false;
    }
    let end = Tok {
        start: b.len() as u16,
        end: b.len() as u16,
        space,
        ..Tok::END
    };
    if let Some(slot) = out.toks.get_mut(out.len) {
        *slot = end;
    }
    true
}

fn digits_end(b: &[u8], mut i: usize, ok: impl Fn(u8) -> bool) -> usize {
    while let Some(&c) = b.get(i) {
        if ok(c) || (c == b'_' && b.get(i + 1).is_some_and(|&d| ok(d))) {
            i += 1;
        } else {
            break;
        }
    }
    i
}

fn parse_radix(digits: &[u8], radix: u32) -> Num {
    let mut exact: Option<i128> = Some(0);
    let mut approx = 0f64;
    for &c in digits {
        if c == b'_' {
            continue;
        }
        let d = (c as char).to_digit(radix).unwrap_or(0);
        exact = exact
            .and_then(|v| v.checked_mul(i128::from(radix)))
            .and_then(|v| v.checked_add(i128::from(d)));
        approx = approx * f64::from(radix) + f64::from(d);
    }
    match exact {
        Some(v) => Num::int(v),
        None => Num::Float(if approx.is_finite() { approx } else { f64::MAX }),
    }
}

fn two_digits(b: &[u8], i: usize) -> Option<i32> {
    let (a, c) = (*b.get(i)?, *b.get(i + 1)?);
    if a.is_ascii_digit() && c.is_ascii_digit() {
        Some(i32::from(a - b'0') * 10 + i32::from(c - b'0'))
    } else {
        None
    }
}

fn lex_number(
    src: &str,
    i: usize,
    decimal: char,
    grouping: Option<char>,
    in_call: bool,
    out: &mut Lexed,
) -> Option<(Tok, usize)> {
    let b = src.as_bytes();
    let base_tok = Tok {
        k: K::Num,
        sym: '\0',
        start: 0,
        end: 0,
        space: false,
        flags: 0,
        aux: 0,
    };

    // 0x, 0b, 0o literals.
    if b.get(i) == Some(&b'0')
        && let Some(&p) = b.get(i + 1)
    {
        let (radix, flag) = match p {
            b'x' | b'X' => (16, HEX),
            b'b' | b'B' => (2, BIN),
            b'o' | b'O' => (8, OCT),
            _ => (0, 0),
        };
        if radix != 0 {
            let ok = |c: u8| (c as char).is_digit(radix);
            let end = digits_end(b, i + 2, ok);
            if end > i + 2 && !is_alpha_at(src, end) && !is_digit(b.get(end)) {
                let v = parse_radix(b.get(i + 2..end)?, radix);
                let aux = out.push_num(v)?;
                return Some((
                    Tok {
                        flags: flag,
                        aux,
                        ..base_tok
                    },
                    end,
                ));
            }
        }
    }

    let int_end = digits_end(b, i, |c| c.is_ascii_digit());
    let int_len = int_end - i;

    // YYYY-MM-DD
    if int_len == 4
        && b.get(int_end) == Some(&b'-')
        && let Some(m) = two_digits(b, int_end + 1)
        && b.get(int_end + 3) == Some(&b'-')
        && let Some(d) = two_digits(b, int_end + 4)
        && !is_digit(b.get(int_end + 6))
    {
        let y = src.get(i..int_end)?.parse::<i32>().ok()?;
        if let Some(days) = cal::days_from_ymd(y, m, d) {
            return Some((
                Tok {
                    k: K::Date,
                    aux: days,
                    ..base_tok
                },
                int_end + 6,
            ));
        }
    }

    // H:MM or H:MM:SS
    if (1..=2).contains(&int_len)
        && b.get(int_end) == Some(&b':')
        && let Some(m) = two_digits(b, int_end + 1)
        && !is_digit(b.get(int_end + 3))
    {
        let h = src.get(i..int_end)?.parse::<i32>().ok()?;
        let mut end = int_end + 3;
        let mut s = 0;
        if b.get(end) == Some(&b':')
            && let Some(sec) = two_digits(b, end + 1)
            && !is_digit(b.get(end + 3))
        {
            s = sec;
            end += 3;
        }
        if h <= 24 && m < 60 && s < 60 {
            return Some((
                Tok {
                    k: K::Clock,
                    aux: h * 3600 + m * 60 + s,
                    ..base_tok
                },
                end,
            ));
        }
        return None;
    }

    // Integer digits with grouping separators.
    let mut digits = [0u8; 64];
    let mut nd = 0usize;
    let mut push = |c: u8, nd: &mut usize| {
        if let Some(slot) = digits.get_mut(*nd) {
            *slot = c;
            *nd += 1;
            true
        } else {
            false
        }
    };
    let mut flags = 0u8;
    let mut j = i;
    let mut group_len = 0usize;
    while let Some(&c) = b.get(j) {
        if c.is_ascii_digit() {
            if !push(c, &mut nd) {
                return None;
            }
            group_len += 1;
            j += 1;
            continue;
        }
        // A grouping separator counts when exactly three digits follow it.
        if let Some(g) = grouping
            && g != decimal
            && !(g == ',' && in_call)
            && src.get(j..).is_some_and(|s| s.starts_with(g))
        {
            let gl = g.len_utf8();
            let k = j + gl;
            let three = (0..3).all(|o| is_digit(b.get(k + o))) && !is_digit(b.get(k + 3));
            let first_ok = flags & GROUPED != 0 || (1..=3).contains(&group_len);
            if three && first_ok && (flags & GROUPED == 0 || group_len == 3) {
                flags |= GROUPED;
                group_len = 0;
                j = k;
                continue;
            }
        }
        break;
    }
    if flags & GROUPED != 0 && group_len != 3 {
        return None;
    }
    let int_digits_len = nd;

    // Fraction. The caller's decimal separator, or '.' when it is not the grouping separator.
    let dec_here = |j: usize| -> usize {
        if src.get(j..).is_some_and(|s| s.starts_with(decimal)) && is_digit(b.get(j + decimal.len_utf8())) {
            return decimal.len_utf8();
        }
        if decimal != '.' && grouping != Some('.') && b.get(j) == Some(&b'.') && is_digit(b.get(j + 1)) {
            return 1;
        }
        0
    };
    let dl = dec_here(j);
    if dl > 0 {
        flags |= FRACTION;
        j += dl;
        while let Some(&c) = b.get(j) {
            if !c.is_ascii_digit() {
                break;
            }
            if !push(c, &mut nd) {
                return None;
            }
            j += 1;
        }
    }

    // Scientific notation: 1e3, 2.5E-4. Not "2e" alone, which is 2 times e.
    let mut exp = 0i32;
    if matches!(b.get(j), Some(b'e' | b'E')) {
        let (sign, k) = match b.get(j + 1) {
            Some(b'+') => (1, j + 2),
            Some(b'-') => (-1, j + 2),
            _ => (1, j + 1),
        };
        let e_end = digits_end(b, k, |c| c.is_ascii_digit());
        if e_end > k && e_end - k <= 4 && !is_alpha_at(src, e_end) {
            let e: i32 = src.get(k..e_end)?.parse().ok()?;
            exp = sign * e;
            flags |= SCI;
            j = e_end;
        }
    }

    let (int_part, frac_part) = digits.get(..nd)?.split_at(int_digits_len);
    let mut v = num::from_decimal(int_part, frac_part, exp).ok()?;

    // Ordinals: 1st, 2nd, 3rd, 25th.
    if flags & (FRACTION | SCI) == 0 {
        let suffix = src.get(j..j + 2).unwrap_or("");
        let ord = ["st", "nd", "rd", "th"].iter().any(|s| suffix.eq_ignore_ascii_case(s));
        if ord && !is_alpha_at(src, j + 2) {
            flags |= ORDINAL;
            j += 2;
        }
    }

    // Glued scale suffixes: 5k is 5,000 and 2.5M is 2,500,000.
    if flags & ORDINAL == 0
        && let Some(&c) = b.get(j)
        && matches!(c, b'k' | b'K' | b'M')
        && !is_alpha_at(src, j + 1)
        && !is_digit(b.get(j + 1))
    {
        let scale = if c == b'M' { 1_000_000 } else { 1_000 };
        v = v.mul(Num::int(scale)).ok()?;
        flags |= SCALED;
        j += 1;
    }

    let aux = out.push_num(v)?;
    Some((Tok { flags, aux, ..base_tok }, j))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kinds(src: &str) -> Vec<K> {
        let mut l = Lexed::new();
        assert!(lex(src, '.', Some(','), &mut l), "{src}");
        l.toks[..l.len].iter().map(|t| t.k).collect()
    }

    #[test]
    fn splits_numbers_words_and_symbols() {
        assert_eq!(kinds("2+2"), [K::Num, K::Sym, K::Num]);
        assert_eq!(kinds("5 km in miles"), [K::Num, K::Word, K::Word, K::Word]);
        assert_eq!(kinds("3:30pm"), [K::Clock, K::Word]);
        assert_eq!(kinds("2026-12-25"), [K::Date]);
        assert_eq!(kinds("log2(8)"), [K::Word, K::Sym, K::Num, K::Sym]);
        assert_eq!(kinds("5x3"), [K::Num, K::Word, K::Num]);
    }

    #[test]
    fn grouping_needs_three_digits() {
        let mut l = Lexed::new();
        assert!(lex("1,000,000", '.', Some(','), &mut l));
        assert_eq!(l.len, 1);
        assert!(matches!(l.nums[0], Num::Ratio(1_000_000, 1)));
        assert!(lex("max(1,000)", '.', Some(','), &mut l));
        assert_eq!(l.len, 6, "a comma inside a call separates arguments");
    }

    #[test]
    fn decimal_comma() {
        let mut l = Lexed::new();
        assert!(lex("1.234,5", ',', Some('.'), &mut l));
        assert_eq!(l.len, 1);
        assert!(matches!(l.nums[0], Num::Ratio(2469, 2)));
    }

    #[test]
    fn rejects_unknown_symbols_and_long_input() {
        let mut l = Lexed::new();
        assert!(!lex("a#b", '.', Some(','), &mut l));
        let long = "1+".repeat(40);
        assert!(!lex(&long, '.', Some(','), &mut l));
    }
}
