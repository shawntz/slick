//! Character folding (case + diacritics), character classes, presence masks, word starts.
//!
//! Text is composed first: a base char followed by combining marks that compose becomes the
//! precomposed char, as Unicode normalization form C would make it, and a combining mark after a
//! char that folds to ASCII is dropped as the diacritic it is. So a name stored decomposed, as
//! older Mac volumes and Foundation's file URLs store it, folds exactly like the same name
//! composed. Each composed char ([`Glyph`]) then folds 1 char -> 1 char, so for items whose folded
//! form is pure ASCII and nothing was composed, a folded byte offset equals the original char
//! offset. Otherwise [`composed`] gives the original UTF-16 units each folded char covers.

use unicode_normalization::char::{compose, decompose_canonical, is_combining_mark};

/// One char of composed text and what it covers of the original.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Glyph {
    /// The composed char, not yet folded.
    pub c: char,
    /// UTF-16 units of the original it covers.
    pub units: u32,
    /// UTF-8 bytes of the original it covers.
    pub bytes: u32,
    /// Chars of the original it covers: 1, or more when marks were composed or dropped.
    pub chars: u32,
}

/// When `next` joins the char before it, the char they make together: their canonical
/// composition, or `last` itself when `next` is a combining mark on a char that folds to ASCII.
#[inline]
pub fn absorb(last: char, next: char) -> Option<char> {
    if next.is_ascii() {
        return None;
    }
    if let Some(c) = compose(last, next) {
        return Some(c);
    }
    (is_combining_mark(next) && fold_char(last).is_ascii()).then_some(last)
}

/// The composed chars of `chars`. Allocates nothing.
pub fn composed<I: IntoIterator<Item = char>>(chars: I) -> Composed<I::IntoIter> {
    Composed {
        it: chars.into_iter().peekable(),
    }
}

/// Iterator returned by [`composed`].
pub struct Composed<I: Iterator<Item = char>> {
    it: std::iter::Peekable<I>,
}

impl<I: Iterator<Item = char>> Iterator for Composed<I> {
    type Item = Glyph;

    #[inline]
    fn next(&mut self) -> Option<Glyph> {
        let first = self.it.next()?;
        let mut g = Glyph {
            c: first,
            units: first.len_utf16() as u32,
            bytes: first.len_utf8() as u32,
            chars: 1,
        };
        while let Some(&d) = self.it.peek() {
            let Some(c) = absorb(g.c, d) else { break };
            g.c = c;
            g.units += d.len_utf16() as u32;
            g.bytes += d.len_utf8() as u32;
            g.chars += 1;
            self.it.next();
        }
        Some(g)
    }
}

/// Composes `chars` in place, as [`composed`] would.
pub fn compose_in_place(chars: &mut Vec<char>) {
    let mut w = 0usize;
    for r in 0..chars.len() {
        let d = chars[r];
        if w > 0
            && let Some(c) = absorb(chars[w - 1], d)
        {
            chars[w - 1] = c;
            continue;
        }
        chars[w] = d;
        w += 1;
    }
    chars.truncate(w);
}

/// Fold one char: lowercase, then strip diacritics when the base letter is ASCII.
#[inline]
pub fn fold_char(c: char) -> char {
    if c.is_ascii() {
        return c.to_ascii_lowercase();
    }
    let lc = c.to_lowercase().next().unwrap_or(c);
    if lc.is_ascii() {
        return lc;
    }
    let mut base = None;
    decompose_canonical(lc, |d| {
        if base.is_none() {
            base = Some(d);
        }
    });
    match base {
        Some(b) if b.is_ascii() => b.to_ascii_lowercase(),
        _ => match lc {
            'ø' => 'o',
            'æ' => 'a',
            'œ' => 'o',
            'ł' => 'l',
            'đ' => 'd',
            'ı' => 'i',
            'ŧ' => 't',
            'ß' => 's',
            'þ' => 't',
            _ => lc,
        },
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Class {
    Sep,
    Lower,
    Upper,
    Digit,
    /// Non-ASCII letter with spaces between words (Latin-ext, Cyrillic, Greek, ...).
    OtherLetter,
    /// CJK ideograph / kana / hangul: every char starts a word.
    Ideo,
    /// Emoji and other symbols.
    Symbol,
}

#[inline]
pub fn class_of(c: char) -> Class {
    if c.is_ascii() {
        let b = c as u8;
        return match b {
            b'a'..=b'z' => Class::Lower,
            b'A'..=b'Z' => Class::Upper,
            b'0'..=b'9' => Class::Digit,
            _ => Class::Sep,
        };
    }
    let u = c as u32;
    if (0x3040..=0x30FF).contains(&u)      // hiragana, katakana
        || (0x3400..=0x4DBF).contains(&u)  // CJK ext A
        || (0x4E00..=0x9FFF).contains(&u)  // CJK unified
        || (0xAC00..=0xD7AF).contains(&u)  // hangul syllables
        || (0xF900..=0xFAFF).contains(&u)
    {
        return Class::Ideo;
    }
    if c.is_alphabetic() {
        if c.is_uppercase() {
            Class::Upper
        } else if c.is_lowercase() {
            Class::Lower
        } else {
            Class::OtherLetter
        }
    } else if c.is_numeric() {
        Class::Digit
    } else if c.is_whitespace() || (0x2000..=0x206F).contains(&u) {
        Class::Sep
    } else {
        Class::Symbol
    }
}

/// Bit for a folded char in the 64-bit presence mask.
/// a-z: 0..25, 0-9: 26..35, '.':36 '-':37 '_':38 '/':39, other ASCII punct: 40,
/// non-ASCII: 41 + (code point % 23). Space is never in a mask.
#[inline]
pub fn mask_bit(c: char) -> u64 {
    if c.is_ascii() {
        let b = c as u8;
        let i = match b {
            b'a'..=b'z' => (b - b'a') as u32,
            b'A'..=b'Z' => (b - b'A') as u32,
            b'0'..=b'9' => 26 + (b - b'0') as u32,
            b'.' => 36,
            b'-' => 37,
            b'_' => 38,
            b'/' => 39,
            b' ' | b'\t' => return 0,
            _ => 40,
        };
        1u64 << i
    } else {
        1u64 << (41 + (c as u32 % 23))
    }
}

/// Byte-level bit (for already-folded ASCII bytes). Non-ASCII bytes are handled by `mask_bit`.
#[inline(always)]
pub fn mask_bit_byte(b: u8) -> u64 {
    mask_bit(b as char)
}

/// Is ASCII byte a separator for on-the-fly word-boundary detection (folded text, no case info)?
#[inline(always)]
pub fn is_sep_byte(b: u8) -> bool {
    b < 0x80 && !(b.is_ascii_alphanumeric())
}

/// Result of folding one string.
pub struct Folded {
    pub bytes: Vec<u8>,
    /// true when every original char became exactly one ASCII byte (offsets are 1:1): no char was
    /// non-ASCII after folding, and nothing was composed or dropped.
    pub one_to_one: bool,
    pub mask: u64,
    /// Mask of folded chars that start a word.
    pub initials: u64,
    /// Mask of folded chars that start two words or more.
    pub initials2: u64,
    /// Word-start bits for folded byte offsets [window, window+64).
    pub ws: u64,
}

/// Fold `s`; `window` is the byte offset (in the folded output) where the 64-bit word-start window
/// begins (0 for titles; the basename offset for paths). Because folding can change byte lengths
/// for non-ASCII text, `window_char` is given in *chars* of the original and converted here. When
/// a composed char covers the original char `window_char`, the window starts at that char.
pub fn fold_str(s: &str, window_char: usize) -> (Folded, usize) {
    let mut bytes = Vec::with_capacity(s.len());
    let mut one_to_one = true;
    let mut mask = 0u64;
    let mut initials = 0u64;
    let mut initials2 = 0u64;
    let mut ws = 0u64;
    let mut window_byte = 0usize;
    let glyphs: Vec<Glyph> = composed(s.chars()).collect();
    let mut prev = Class::Sep;
    // Original chars before the current glyph, and whether the window has begun.
    let mut orig = 0usize;
    let mut in_window = window_char == 0;
    for (gi, g) in glyphs.iter().enumerate() {
        let c = g.c;
        if !in_window && orig + g.chars as usize > window_char {
            window_byte = bytes.len();
            in_window = true;
        }
        orig += g.chars as usize;
        if g.chars > 1 {
            one_to_one = false;
        }
        let cls = class_of(c);
        let next = glyphs.get(gi + 1).map(|n| class_of(n.c)).unwrap_or(Class::Sep);
        let start = match cls {
            Class::Sep => false,
            Class::Ideo => true,
            _ => {
                prev == Class::Sep
                    || prev == Class::Ideo
                    || prev == Class::Symbol && cls != Class::Symbol
                    || (prev == Class::Lower && cls == Class::Upper)
                    || (prev == Class::Upper && cls == Class::Upper && next == Class::Lower)
            }
        };
        let f = fold_char(c);
        let pos = bytes.len();
        if start && in_window && pos >= window_byte && pos - window_byte < 64 {
            ws |= 1u64 << (pos - window_byte);
        }
        let bit = mask_bit(f);
        mask |= bit;
        if start {
            initials2 |= initials & bit;
            initials |= bit;
        }
        if f.is_ascii() {
            bytes.push(f as u8);
        } else {
            one_to_one = false;
            let mut buf = [0u8; 4];
            bytes.extend_from_slice(f.encode_utf8(&mut buf).as_bytes());
        }
        prev = cls;
    }
    if window_char >= orig {
        window_byte = bytes.len();
    }
    (
        Folded {
            bytes,
            one_to_one,
            mask,
            initials,
            initials2,
            ws,
        },
        window_byte,
    )
}
