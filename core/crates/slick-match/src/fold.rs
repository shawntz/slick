//! Character folding (case + diacritics), character classes, presence masks, word starts.
//!
//! Folding is 1 char -> 1 char so that, for items whose folded form is pure ASCII, a folded byte
//! offset equals the original char offset (and the UTF-16 offset, since such items are BMP-only).

use unicode_normalization::char::decompose_canonical;

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
    /// true when every original char became exactly one ASCII byte (offsets are 1:1).
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
/// for non-ASCII text, `window_char` is given in *chars* of the original and converted here.
pub fn fold_str(s: &str, window_char: usize) -> (Folded, usize) {
    let mut bytes = Vec::with_capacity(s.len());
    let mut one_to_one = true;
    let mut mask = 0u64;
    let mut initials = 0u64;
    let mut initials2 = 0u64;
    let mut ws = 0u64;
    let mut window_byte = 0usize;
    let chars: Vec<char> = s.chars().collect();
    let mut prev = Class::Sep;
    for (ci, &c) in chars.iter().enumerate() {
        if ci == window_char {
            window_byte = bytes.len();
        }
        let cls = class_of(c);
        let next = chars.get(ci + 1).map(|&n| class_of(n)).unwrap_or(Class::Sep);
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
        if start && pos >= window_byte && pos - window_byte < 64 && ci >= window_char {
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
    if window_char >= chars.len() {
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
