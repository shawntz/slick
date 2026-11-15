//! Hashing for the learning tables: a fast map hasher and the FNV-1a hash used for query keys.

use std::collections::HashMap;
use std::hash::{BuildHasherDefault, Hasher};

/// The Fx hash (rustc's), fast for small integer keys. Not resistant to adversarial keys, which is
/// fine for tables keyed by our own ids and hashes.
#[derive(Default, Clone, Copy)]
pub struct FxHasher(u64);

const FX_SEED: u64 = 0x51_7c_c1_b7_27_22_0a_95;

impl Hasher for FxHasher {
    #[inline]
    fn write(&mut self, bytes: &[u8]) {
        for &b in bytes {
            self.0 = (self.0.rotate_left(5) ^ b as u64).wrapping_mul(FX_SEED);
        }
    }

    #[inline]
    fn write_u32(&mut self, i: u32) {
        self.0 = (self.0.rotate_left(5) ^ i as u64).wrapping_mul(FX_SEED);
    }

    #[inline]
    fn write_u64(&mut self, i: u64) {
        self.0 = (self.0.rotate_left(5) ^ i).wrapping_mul(FX_SEED);
    }

    #[inline]
    fn finish(&self) -> u64 {
        self.0
    }
}

/// A `HashMap` with the Fx hasher.
pub type FxMap<K, V> = HashMap<K, V, BuildHasherDefault<FxHasher>>;

/// 64-bit FNV-1a (offset basis 0xcbf29ce484222325, prime 0x100000001b3). Item keys and query keys
/// both use it; Swift computes item keys with the same function.
#[inline]
pub fn fnv1a(bytes: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for &b in bytes {
        h ^= b as u64;
        h = h.wrapping_mul(0x0100_0000_01b3);
    }
    h
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fnv1a_matches_the_reference_vectors() {
        assert_eq!(fnv1a(b""), 0xcbf2_9ce4_8422_2325);
        assert_eq!(fnv1a(b"a"), 0xaf63_dc4c_8601_ec8c);
        assert_eq!(fnv1a(b"foobar"), 0x8594_4171_f739_67e8);
    }
}
