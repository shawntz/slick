//! Hashes: FNV-1a for small fingerprints, and a fast 64-bit checksum for index files.
//!
//! The checksum is there to catch damage such as a torn write, a flipped bit or a truncated copy, not an
//! attacker. It reads four 64-bit lanes per 32 bytes with a multiply-rotate mix, which runs at
//! memory speed, so checking a million-entry file costs a few milliseconds.

/// FNV-1a, 64 bits.
pub(crate) struct Fnv(u64);

impl Fnv {
    pub(crate) fn new() -> Fnv {
        Fnv(0xcbf2_9ce4_8422_2325)
    }

    pub(crate) fn write(&mut self, bytes: &[u8]) {
        for &b in bytes {
            self.0 ^= b as u64;
            self.0 = self.0.wrapping_mul(0x0000_0100_0000_01b3);
        }
    }

    pub(crate) fn finish(&self) -> u64 {
        self.0
    }
}

const P1: u64 = 0x9E37_79B1_85EB_CA87;
const P2: u64 = 0xC2B2_AE3D_27D4_EB4F;
const P3: u64 = 0x1656_67B1_9E37_79F9;

#[inline(always)]
fn round(acc: u64, x: u64) -> u64 {
    acc.wrapping_add(x.wrapping_mul(P2)).rotate_left(31).wrapping_mul(P1)
}

/// A streaming checksum. Feeding the same bytes in any split gives the same result.
pub(crate) struct Checksum {
    lanes: [u64; 4],
    tail: [u8; 32],
    tail_len: usize,
    total: u64,
}

impl Checksum {
    pub(crate) fn new() -> Checksum {
        Checksum {
            lanes: [P1.wrapping_add(P2), P2, 0, P1.wrapping_neg()],
            tail: [0; 32],
            tail_len: 0,
            total: 0,
        }
    }

    #[inline(always)]
    fn block(&mut self, b: &[u8]) {
        for (i, lane) in self.lanes.iter_mut().enumerate() {
            let mut w = [0u8; 8];
            w.copy_from_slice(&b[i * 8..i * 8 + 8]);
            *lane = round(*lane, u64::from_le_bytes(w));
        }
    }

    pub(crate) fn write(&mut self, mut bytes: &[u8]) {
        self.total += bytes.len() as u64;
        if self.tail_len > 0 {
            let take = (32 - self.tail_len).min(bytes.len());
            self.tail[self.tail_len..self.tail_len + take].copy_from_slice(&bytes[..take]);
            self.tail_len += take;
            bytes = &bytes[take..];
            if self.tail_len < 32 {
                return;
            }
            let t = self.tail;
            self.block(&t);
            self.tail_len = 0;
        }
        let (blocks, rest) = bytes.as_chunks::<32>();
        for c in blocks {
            self.block(c);
        }
        self.tail[..rest.len()].copy_from_slice(rest);
        self.tail_len = rest.len();
    }

    pub(crate) fn finish(&self) -> u64 {
        let [a, b, c, d] = self.lanes;
        let mut h = a
            .rotate_left(1)
            .wrapping_add(b.rotate_left(7))
            .wrapping_add(c.rotate_left(12))
            .wrapping_add(d.rotate_left(18));
        h ^= self.total.wrapping_mul(P3);
        for &x in &self.tail[..self.tail_len] {
            h = (h ^ (x as u64).wrapping_mul(P3)).rotate_left(11).wrapping_mul(P1);
        }
        h ^= h >> 33;
        h = h.wrapping_mul(P2);
        h ^= h >> 29;
        h = h.wrapping_mul(P3);
        h ^ (h >> 32)
    }
}

/// The checksum of one byte slice.
#[cfg(test)]
pub(crate) fn checksum(bytes: &[u8]) -> u64 {
    let mut c = Checksum::new();
    c.write(bytes);
    c.finish()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn streaming_equals_one_shot_for_any_split() {
        let data: Vec<u8> = (0..1_000u32).map(|i| (i * 31 % 251) as u8).collect();
        let whole = checksum(&data);
        for split in [0, 1, 7, 31, 32, 33, 500, 999, 1_000] {
            let mut c = Checksum::new();
            c.write(&data[..split]);
            c.write(&data[split..]);
            assert_eq!(c.finish(), whole, "split {split}");
        }
    }

    #[test]
    fn detects_every_single_bit_flip_in_a_sample() {
        let data: Vec<u8> = (0..300u32).map(|i| (i * 7 % 256) as u8).collect();
        let base = checksum(&data);
        for byte in 0..data.len() {
            for bit in 0..8 {
                let mut d = data.clone();
                d[byte] ^= 1 << bit;
                assert_ne!(checksum(&d), base, "byte {byte} bit {bit}");
            }
        }
        assert_ne!(checksum(&data[..299]), base, "truncation");
        let mut longer = data.clone();
        longer.push(0);
        assert_ne!(checksum(&longer), base, "a trailing zero");
    }
}
