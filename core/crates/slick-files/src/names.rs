//! What the store keeps per name for search, and the folding it is computed with.
//!
//! Folding is `slick_match::fold::fold_str` with window 0, reimplemented here over reusable
//! buffers so a search never allocates. A test pins the two together.

use slick_match::fold::{self, Class};

/// The search fields of one name.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct NameInfo {
    /// Compressed presence mask of the folded name, packed by [`compress_mask`].
    pub mask: u32,
    /// Compressed presence mask of the folded chars that start words.
    pub initials: u32,
    /// Word-start bits for folded bytes 0..64.
    pub ws: u64,
    /// The folded char at the first word start when it is ASCII, else 0.
    pub first: u8,
    /// Folding is not one ASCII byte per byte.
    pub multibyte: bool,
}

/// Folds `name` into `out`: lowercase, diacritics stripped, one char to one char. Returns the
/// word-start bits and the 64-bit presence mask, exactly as `fold::fold_str(name, 0)` would.
/// Invalid UTF-8 folds like `String::from_utf8_lossy`. `chars` is scratch space.
pub(crate) fn fold_into(name: &[u8], out: &mut Vec<u8>, chars: &mut Vec<char>) -> (u64, u64, u64) {
    out.clear();
    chars.clear();
    for chunk in name.utf8_chunks() {
        chars.extend(chunk.valid().chars());
        if !chunk.invalid().is_empty() {
            chars.push(char::REPLACEMENT_CHARACTER);
        }
    }
    let mut ws = 0u64;
    let mut mask = 0u64;
    let mut initials = 0u64;
    let mut prev = Class::Sep;
    for (ci, &c) in chars.iter().enumerate() {
        let cls = fold::class_of(c);
        let next = chars.get(ci + 1).map(|&n| fold::class_of(n)).unwrap_or(Class::Sep);
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
        let f = fold::fold_char(c);
        let pos = out.len();
        if start && pos < 64 {
            ws |= 1u64 << pos;
        }
        let bit = fold::mask_bit(f);
        mask |= bit;
        if start {
            initials |= bit;
        }
        let mut buf = [0u8; 4];
        out.extend_from_slice(f.encode_utf8(&mut buf).as_bytes());
        prev = cls;
    }
    (ws, mask, initials)
}

/// The search fields of `name` and its folded form. Allocates; used when a name enters the store.
pub(crate) fn analyze(name: &[u8]) -> (NameInfo, Vec<u8>) {
    let mut folded = Vec::with_capacity(name.len());
    let mut chars = Vec::new();
    let (ws, mask, initials) = fold_into(name, &mut folded, &mut chars);
    let multibyte = !(name.is_ascii() && folded.len() == name.len());
    let first = if ws == 0 {
        0
    } else {
        match folded.get(ws.trailing_zeros() as usize) {
            Some(&b) if b.is_ascii() => b,
            _ => 0,
        }
    };
    (
        NameInfo {
            mask: compress_mask(mask),
            initials: compress_mask(initials),
            ws,
            first,
            multibyte,
        },
        folded,
    )
}

/// Packs a `slick_match` presence mask into 32 bits. Letters keep a bit each; digits share three
/// bits; `.` keeps one; other ASCII punctuation shares one; non-ASCII chars share one. The packing
/// is applied to both sides of `query & !entry`, so it can only let more entries through, never
/// fewer.
pub(crate) fn compress_mask(m: u64) -> u32 {
    let letters = (m & ((1 << 26) - 1)) as u32;
    let digits = (m >> 26) & 0x3FF;
    let mut out = letters;
    if digits & 0b10_0100_1001 != 0 {
        out |= 1 << 26;
    }
    if digits & 0b00_1001_0010 != 0 {
        out |= 1 << 27;
    }
    if digits & 0b01_0010_0100 != 0 {
        out |= 1 << 28;
    }
    if m & (1 << 36) != 0 {
        out |= 1 << 29;
    }
    if m & (0xF << 37) != 0 {
        out |= 1 << 30;
    }
    if m >> 41 != 0 {
        out |= 1 << 31;
    }
    out
}

/// ASCII lowercase of eight bytes at once. Bytes outside `A..=Z` stay as they are.
#[inline(always)]
fn lower_word(x: u64) -> u64 {
    const ONES: u64 = 0x0101_0101_0101_0101;
    let low7 = x & (0x7F * ONES);
    let ge_a = low7.wrapping_add((0x80 - b'A' as u64) * ONES);
    let gt_z = low7.wrapping_add((0x80 - b'Z' as u64 - 1) * ONES);
    let upper = ge_a & !gt_z & !x & (0x80 * ONES);
    x | (upper >> 2)
}

/// Loads the 64 bytes at `src` into `block` and lowercases the first `n`, rounded up to 8. The
/// bytes past `n` are whatever follows in the arena; the scorer masks them out.
#[inline(always)]
pub(crate) fn lower_block(src: &[u8; 64], n: usize, block: &mut [u8; 64]) {
    *block = *src;
    let words = n.div_ceil(8).min(8);
    for w in 0..words {
        let i = w * 8;
        let mut b = [0u8; 8];
        b.copy_from_slice(&block[i..i + 8]);
        let x = lower_word(u64::from_le_bytes(b));
        block[i..i + 8].copy_from_slice(&x.to_le_bytes());
    }
}

/// Byte length of the stem when `name` has an extension: the part before the last `.`, which
/// must not be the first or the last byte. Dotfiles such as `.profile` have no extension.
#[inline]
pub(crate) fn stem_len(name: &[u8]) -> Option<usize> {
    let dot = name.iter().rposition(|&b| b == b'.')?;
    if dot == 0 || dot + 1 == name.len() {
        None
    } else {
        Some(dot)
    }
}

/// True when the extension of `name` starts with `ext` (ASCII case-insensitive). With `exact`, it
/// must equal it.
#[inline]
pub(crate) fn ext_matches(name: &[u8], ext: &[u8], exact: bool) -> bool {
    let Some(stem) = stem_len(name) else {
        return false;
    };
    let e = &name[stem + 1..];
    if e.len() < ext.len() || (exact && e.len() != ext.len()) {
        return false;
    }
    e.iter().zip(ext).all(|(a, b)| a.to_ascii_lowercase() == *b)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLES: &[&str] = &[
        "",
        "a",
        "README.md",
        "Screenshot 2024-03-15 at 10.23.45.png",
        "camelCaseName.swift",
        "HTMLParser",
        "IMG_1234.JPG",
        "__init__.py",
        ".profile",
        "Café Crème.txt",
        "Ålesund Ørsta.pdf",
        "日本語のファイル.txt",
        "🎉 party plan.key",
        "mixedÜMLAUTTest",
        "a-b_c.d e",
        "x\u{301}y",
        "ﬁle ligature",
        "ΣΊΣΥΦΟΣ",
        "tab\tname",
        "UPPER lower Title",
    ];

    #[test]
    fn folding_equals_slick_match() {
        let mut out = Vec::new();
        let mut chars = Vec::new();
        for s in SAMPLES {
            let (ws, mask, initials) = fold_into(s.as_bytes(), &mut out, &mut chars);
            let (f, win) = fold::fold_str(s, 0);
            assert_eq!(win, 0, "{s}");
            assert_eq!(out, f.bytes, "{s}");
            assert_eq!(ws, f.ws, "{s}");
            assert_eq!(mask, f.mask, "{s}");
            assert_eq!(initials, f.initials, "{s}");
        }
    }

    #[test]
    fn folding_equals_slick_match_on_random_strings() {
        let alphabet: Vec<char> = "aZ09 ._-/éÉøß日🎉ΣxY\u{301}".chars().collect();
        let mut rng = fastrand::Rng::with_seed(7);
        let mut out = Vec::new();
        let mut chars = Vec::new();
        for _ in 0..2_000 {
            let n = rng.usize(0..80);
            let s: String = (0..n).map(|_| alphabet[rng.usize(..alphabet.len())]).collect();
            let (ws, mask, _) = fold_into(s.as_bytes(), &mut out, &mut chars);
            let (f, _) = fold::fold_str(&s, 0);
            assert_eq!((out.as_slice(), ws, mask), (f.bytes.as_slice(), f.ws, f.mask), "{s:?}");
        }
    }

    #[test]
    fn invalid_utf8_folds_like_lossy_decoding() {
        let raw = b"ab\xffC\xe2\x82";
        let mut out = Vec::new();
        let mut chars = Vec::new();
        let (ws, _, _) = fold_into(raw, &mut out, &mut chars);
        let lossy = String::from_utf8_lossy(raw);
        let (f, _) = fold::fold_str(&lossy, 0);
        assert_eq!((out, ws), (f.bytes, f.ws));
    }

    #[test]
    fn lowercasing_eight_bytes_at_a_time_matches_ascii_lowercase() {
        let mut rng = fastrand::Rng::with_seed(3);
        for _ in 0..10_000 {
            let mut src = [0u8; 64];
            for b in src.iter_mut() {
                *b = rng.u8(..);
            }
            let mut block = [0u8; 64];
            lower_block(&src, 64, &mut block);
            for i in 0..64 {
                assert_eq!(block[i], src[i].to_ascii_lowercase(), "byte {:#x}", src[i]);
            }
        }
    }

    #[test]
    fn analysis_reports_first_word_char_and_width() {
        let (a, _) = analyze(b"README.md");
        assert_eq!((a.first, a.multibyte), (b'r', false));
        assert_eq!(analyze(b"__init__.py").0.first, b'i');
        assert_eq!(analyze(b"---").0.first, 0);
        let (c, folded) = analyze("Café".as_bytes());
        assert_eq!((c.first, c.multibyte, folded.as_slice()), (b'c', true, &b"cafe"[..]));
        assert_eq!(analyze("Éclair".as_bytes()).0.first, b'e');
        assert_eq!(analyze("日本".as_bytes()).0.first, 0);
    }

    #[test]
    fn compressed_masks_never_reject_a_match() {
        let mut out = Vec::new();
        let mut chars = Vec::new();
        for a in SAMPLES {
            for b in SAMPLES {
                let (_, ma, _) = fold_into(a.as_bytes(), &mut out, &mut chars);
                let (_, mb, _) = fold_into(b.as_bytes(), &mut out, &mut chars);
                if ma & !mb == 0 {
                    assert_eq!(compress_mask(ma) & !compress_mask(mb), 0, "{a} in {b}");
                }
            }
        }
    }

    #[test]
    fn extensions() {
        assert_eq!(stem_len(b"report.pdf"), Some(6));
        assert_eq!(stem_len(b".profile"), None);
        assert_eq!(stem_len(b"trailing."), None);
        assert_eq!(stem_len(b"noext"), None);
        assert!(ext_matches(b"Report.PDF", b"pdf", true));
        assert!(ext_matches(b"report.pdf", b"pd", false));
        assert!(!ext_matches(b"report.pdf", b"pd", true));
        assert!(!ext_matches(b"report.pdfx", b"pdf", true));
        assert!(!ext_matches(b"pdf", b"pdf", false));
    }
}
