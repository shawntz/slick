//! The append-only event log: fixed 32-byte little-endian records, each with a CRC.
//!
//! The log is the source of truth the learning state is rebuilt from. Fixed-size records can be
//! scanned without parsing, and a torn last record fails its CRC, so recovery truncates there.
//!
//! Every record ends with the same 4 bytes: a CRC-24 of bytes 0..28 in the top 24 bits, and a
//! reserved byte (0). Byte 26 tells the kinds apart: values below 0x80 are the `Source` of an
//! execution, the others mark the bookkeeping records.
//!
//! ```text
//! Event (byte 26 = source 0..=4)
//!   0 u32 t_sec      seconds since 2026-01-01Z      16 u32 query id (NONE: empty query)
//!   4 u32 item id                                  20 u32 seconds since the previous execution
//!   8 u32 front      frontmost app feature value   24 u8  hour | weekday << 5
//!  12 u32 prev id    previous execution            25 u8  context flags (Ctx::flag_bits)
//!                                                   27 u8  displayed rank (255: none)
//! DefineItem (0x80): 0 u32 id, 4 u64 key
//! DefineQuery (0x81): 0 u32 id, 4..22 text, 22 u8 total length, 27 u8 part (0 or 1)
//! Undo (0x82): 0 u32 t_sec, 4 u32 item id of the execution it reverts
//! Forget (0x83): 4 u32 item id
//! Seed (0x84): 0 u32 t_sec, 4 u32 item id, 8 f32 weight
//! ForgetQuery (0x85): 4 u64 key of the affinity row (see `affinity::row_key`)
//! Base (0x86): 4 u64 number of the record that follows it
//! ```
//!
//! `Base` is not learning: it can only be a log file's first record, and says how many records
//! were compacted away before the rest of the file. A log without it starts at record 0. Code
//! older than these two kinds treats them as damage.

/// Bytes per record.
pub const RECORD_LEN: usize = 32;
/// Longest query the log stores, in bytes (two DefineQuery parts).
pub const MAX_QUERY_BYTES: usize = 2 * QUERY_PART;
const QUERY_PART: usize = 18;

/// How an item was reached when it ran.
#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Source {
    /// Picked from typed results.
    Typed = 0,
    /// Picked from the zero-query suggestions.
    Suggestion = 1,
    /// Run by its own hotkey.
    Hotkey = 2,
    /// Run through a user alias.
    Alias = 3,
    /// A fallback action for a query with no good result.
    Fallback = 4,
}

impl Source {
    /// Decodes a source byte.
    pub fn from_u8(b: u8) -> Option<Source> {
        Some(match b {
            0 => Source::Typed,
            1 => Source::Suggestion,
            2 => Source::Hotkey,
            3 => Source::Alias,
            4 => Source::Fallback,
            _ => return None,
        })
    }
}

/// One execution.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Event {
    /// Seconds since 2026-01-01Z.
    pub t_sec: u32,
    /// Learn id of the item.
    pub item: u32,
    /// Frontmost app feature value.
    pub front: u32,
    /// Learn id of the previous execution.
    pub prev: u32,
    /// Query id.
    pub query: u32,
    /// Seconds since the previous execution (saturating; `u32::MAX` when unknown).
    pub since_prev_s: u32,
    /// Local hour.
    pub hour: u8,
    /// Local weekday.
    pub weekday: u8,
    /// `Ctx::flag_bits`.
    pub flags: u8,
    /// How the item was reached.
    pub source: Source,
    /// Displayed rank, 255 when not shown in a list.
    pub rank: u8,
}

/// Any log record.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Record {
    /// An execution.
    Event(Event),
    /// Binds a learn id to an item key.
    DefineItem { id: u32, key: u64 },
    /// One part of a query string; `len` is the total length, `part` 0 or 1.
    DefineQuery {
        id: u32,
        part: u8,
        len: u8,
        text: [u8; QUERY_PART],
    },
    /// Reverts the execution of `item` at `t_sec`.
    Undo { t_sec: u32, item: u32 },
    /// Forgets an item.
    Forget { item: u32 },
    /// A first-run seed.
    Seed { t_sec: u32, item: u32, weight: f32 },
    /// Removes one query's affinity row.
    ForgetQuery { key: u64 },
    /// The first record of a compacted log file: the number of the record after it.
    Base { first: u64 },
}

const DEFINE_ITEM: u8 = 0x80;
const DEFINE_QUERY: u8 = 0x81;
const UNDO: u8 = 0x82;
const FORGET: u8 = 0x83;
const SEED: u8 = 0x84;
const FORGET_QUERY: u8 = 0x85;
const BASE: u8 = 0x86;

/// CRC-24/OPENPGP.
fn crc24(bytes: &[u8]) -> u32 {
    let mut crc: u32 = 0xB7_04CE;
    for &x in bytes {
        crc ^= (x as u32) << 16;
        for _ in 0..8 {
            crc <<= 1;
            if crc & 0x100_0000 != 0 {
                crc ^= 0x186_4CFB;
            }
        }
    }
    crc & 0xFF_FFFF
}

fn put_u32(b: &mut [u8; RECORD_LEN], at: usize, v: u32) {
    b[at..at + 4].copy_from_slice(&v.to_le_bytes());
}

fn get_u32(b: &[u8; RECORD_LEN], at: usize) -> u32 {
    u32::from_le_bytes([b[at], b[at + 1], b[at + 2], b[at + 3]])
}

/// The two DefineQuery records for a query of at most `MAX_QUERY_BYTES` bytes (one when it fits).
pub fn define_query(id: u32, q: &[u8]) -> impl Iterator<Item = Record> {
    let q = &q[..q.len().min(MAX_QUERY_BYTES)];
    let len = q.len() as u8;
    let mut parts = [None, None];
    for (part, chunk) in q.chunks(QUERY_PART).enumerate().take(2) {
        let mut text = [0u8; QUERY_PART];
        text[..chunk.len()].copy_from_slice(chunk);
        parts[part] = Some(Record::DefineQuery {
            id,
            part: part as u8,
            len,
            text,
        });
    }
    if q.is_empty() {
        parts[0] = Some(Record::DefineQuery {
            id,
            part: 0,
            len: 0,
            text: [0; QUERY_PART],
        });
    }
    parts.into_iter().flatten()
}

impl Record {
    /// The 32 bytes of this record.
    pub fn encode(&self) -> [u8; RECORD_LEN] {
        let mut b = [0u8; RECORD_LEN];
        match *self {
            Record::Event(e) => {
                put_u32(&mut b, 0, e.t_sec);
                put_u32(&mut b, 4, e.item);
                put_u32(&mut b, 8, e.front);
                put_u32(&mut b, 12, e.prev);
                put_u32(&mut b, 16, e.query);
                put_u32(&mut b, 20, e.since_prev_s);
                b[24] = (e.hour & 31) | (e.weekday & 7) << 5;
                b[25] = e.flags;
                b[26] = e.source as u8;
                b[27] = e.rank;
            }
            Record::DefineItem { id, key } => {
                put_u32(&mut b, 0, id);
                b[4..12].copy_from_slice(&key.to_le_bytes());
                b[26] = DEFINE_ITEM;
            }
            Record::DefineQuery { id, part, len, text } => {
                put_u32(&mut b, 0, id);
                b[4..22].copy_from_slice(&text);
                b[22] = len;
                b[26] = DEFINE_QUERY;
                b[27] = part;
            }
            Record::Undo { t_sec, item } => {
                put_u32(&mut b, 0, t_sec);
                put_u32(&mut b, 4, item);
                b[26] = UNDO;
            }
            Record::Forget { item } => {
                put_u32(&mut b, 4, item);
                b[26] = FORGET;
            }
            Record::Seed { t_sec, item, weight } => {
                put_u32(&mut b, 0, t_sec);
                put_u32(&mut b, 4, item);
                put_u32(&mut b, 8, weight.to_bits());
                b[26] = SEED;
            }
            Record::ForgetQuery { key } => {
                b[4..12].copy_from_slice(&key.to_le_bytes());
                b[26] = FORGET_QUERY;
            }
            Record::Base { first } => {
                b[4..12].copy_from_slice(&first.to_le_bytes());
                b[26] = BASE;
            }
        }
        let crc = crc24(&b[..28]);
        put_u32(&mut b, 28, crc << 8);
        b
    }

    /// Decodes a record, or `None` when its CRC fails or its kind is unknown.
    pub fn decode(b: &[u8; RECORD_LEN]) -> Option<Record> {
        let tail = get_u32(b, 28);
        if tail & 0xFF != 0 || crc24(&b[..28]) != tail >> 8 {
            return None;
        }
        let u64_at_4 = || {
            let mut v = [0u8; 8];
            v.copy_from_slice(&b[4..12]);
            u64::from_le_bytes(v)
        };
        Some(match b[26] {
            DEFINE_ITEM => Record::DefineItem {
                id: get_u32(b, 0),
                key: u64_at_4(),
            },
            FORGET_QUERY => Record::ForgetQuery { key: u64_at_4() },
            BASE => Record::Base { first: u64_at_4() },
            DEFINE_QUERY => {
                let mut text = [0u8; QUERY_PART];
                text.copy_from_slice(&b[4..22]);
                Record::DefineQuery {
                    id: get_u32(b, 0),
                    part: b[27],
                    len: b[22],
                    text,
                }
            }
            UNDO => Record::Undo {
                t_sec: get_u32(b, 0),
                item: get_u32(b, 4),
            },
            FORGET => Record::Forget { item: get_u32(b, 4) },
            SEED => Record::Seed {
                t_sec: get_u32(b, 0),
                item: get_u32(b, 4),
                weight: f32::from_bits(get_u32(b, 8)),
            },
            source => Record::Event(Event {
                t_sec: get_u32(b, 0),
                item: get_u32(b, 4),
                front: get_u32(b, 8),
                prev: get_u32(b, 12),
                query: get_u32(b, 16),
                since_prev_s: get_u32(b, 20),
                hour: b[24] & 31,
                weekday: b[24] >> 5,
                flags: b[25],
                source: Source::from_u8(source)?,
                rank: b[27],
            }),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_kind_round_trips() {
        let event = Record::Event(Event {
            t_sec: 1_000_000,
            item: 7,
            front: 0xDEAD_BEEF,
            prev: u32::MAX,
            query: 3,
            since_prev_s: 42,
            hour: 23,
            weekday: 6,
            flags: 0b10101,
            source: Source::Fallback,
            rank: 255,
        });
        let mut records = vec![
            event,
            Record::DefineItem {
                id: 9,
                key: 0xcbf2_9ce4_8422_2325,
            },
            Record::Undo { t_sec: 5, item: 7 },
            Record::Forget { item: 7 },
            Record::Seed {
                t_sec: 1,
                item: 2,
                weight: 0.25,
            },
            Record::ForgetQuery {
                key: 0xaf63_dc4c_8601_ec8c,
            },
            Record::Base { first: 1 << 40 },
        ];
        records.extend(define_query(4, "a query longer than one part".as_bytes()));
        for r in records {
            assert_eq!(Record::decode(&r.encode()), Some(r));
        }
    }

    #[test]
    fn a_flipped_bit_fails_the_crc() {
        let r = Record::Forget { item: 1 };
        for bit in 0..RECORD_LEN * 8 {
            let mut b = r.encode();
            b[bit / 8] ^= 1 << (bit % 8);
            assert_ne!(Record::decode(&b), Some(r), "bit {bit}");
        }
    }

    #[test]
    fn queries_split_into_at_most_two_parts() {
        assert_eq!(define_query(1, b"").count(), 1);
        assert_eq!(define_query(1, b"short").count(), 1);
        assert_eq!(define_query(1, &[b'x'; 18]).count(), 1);
        assert_eq!(define_query(1, &[b'x'; 19]).count(), 2);
        assert_eq!(define_query(1, &[b'x'; 50]).count(), 2);
    }
}
