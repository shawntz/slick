//! The NEON bit path at the edges of the arena buffer: windows that end exactly at the padding,
//! every window length from 1 to 64, and an arena whose public `text` was shrunk by safe code.

use super::*;

/// The bit path reads a whole 64-byte block from each window start. For windows that end at the
/// padding, and for every length up to 64, it must agree with the scalar reference.
#[test]
fn windows_at_the_end_of_the_buffer_match_the_scalar_path() {
    for len in 1..=64usize {
        // The last entry is the one whose block reaches furthest into the padding.
        let last: String = (0..len).map(|i| (b'a' + (i % 26) as u8) as char).collect();
        let a = Arena::from_titles(["zz top", "y", last.as_str()]);
        let e = a.entries() - 1;
        let st = a.start[e] as usize;
        assert_eq!(
            a.text.len() - st,
            len + PAD,
            "the last window is followed by the padding only"
        );
        for q in [&last[..1], &last[..len.min(3)], &last[len - 1..], last.as_str()] {
            let query = Query::new(q);
            if !query.bn.ok {
                continue; // longer than the bit path takes; the search scores it with the scalar path
            }
            let block: &[u8; 64] = a.text[st..st + 64].try_into().expect("padded arena");
            let reference = score::score::<u8, false>(&query.needle(), a.window(e), a.ws[e], false, None);
            match bits::score_bits(&query.needle(), &query.bn, block, len, a.ws[e], 0, Bound::NONE) {
                Sc::Yes(t) => assert_eq!(Some(t), reference, "len {len} q {q:?}"),
                Sc::No => assert_eq!(None, reference, "len {len} q {q:?}"),
                Sc::Below => panic!("floor 0 never skips: len {len} q {q:?}"),
            }
        }
    }
}

/// `Arena::text` is public, so safe code can drop the padding. A search must then take the scalar
/// path instead of loading 64 bytes past the end of the buffer.
#[test]
fn an_arena_without_its_padding_falls_back_to_the_scalar_path() {
    let mut a = Arena::from_titles(["Notes", "Safari"]);
    let padded = run(&a, "saf", None);
    let keep = a.text.len() - PAD;
    a.text.truncate(keep);
    a.text.shrink_to_fit();
    assert_eq!(run(&a, "saf", None), padded);
    assert_eq!(run(&a, "s", None).len(), 2);
}
