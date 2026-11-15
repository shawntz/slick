//! One column of a chunk: either owned memory or a view into a mapped index file.
//!
//! A chunk loaded from disk starts as views. The writer turns a column into owned memory the first
//! time it changes it, copy on write, so opening an index never copies the columns.

use crate::mmap::{Map, Pod};
use std::sync::Arc;

/// Where a mapped column lives in its file.
#[derive(Clone)]
struct Mapped {
    map: Arc<Map>,
    off: usize,
    len: usize,
}

/// A column of plain integers.
#[derive(Clone, Default)]
pub(crate) struct Col<T: Pod> {
    owned: Vec<T>,
    mapped: Option<Mapped>,
}

impl<T: Pod> Col<T> {
    /// An owned column.
    pub(crate) fn owned(v: Vec<T>) -> Self {
        Col { owned: v, mapped: None }
    }

    /// A view of `len` values at byte offset `off` of `map`. The caller has checked that the range
    /// is inside the file and aligned; a view that fails those checks reads as empty.
    pub(crate) fn mapped(map: Arc<Map>, off: usize, len: usize) -> Self {
        Col {
            owned: Vec::new(),
            mapped: Some(Mapped { map, off, len }),
        }
    }

    /// The values.
    #[inline(always)]
    pub(crate) fn as_slice(&self) -> &[T] {
        match &self.mapped {
            None => &self.owned,
            Some(m) => m.map.typed(m.off, m.len).unwrap_or(&[]),
        }
    }

    /// Owned values, copying a mapped view first.
    pub(crate) fn to_mut(&mut self) -> &mut Vec<T> {
        if let Some(m) = self.mapped.take() {
            self.owned = m.map.typed(m.off, m.len).unwrap_or(&[]).to_vec();
        }
        &mut self.owned
    }

    /// True when the values live in a mapped file.
    pub(crate) fn is_mapped(&self) -> bool {
        self.mapped.is_some()
    }

    /// Heap bytes held by the owned part.
    pub(crate) fn heap_bytes(&self) -> usize {
        self.owned.capacity() * size_of::<T>()
    }

    /// Number of values.
    #[inline(always)]
    pub(crate) fn len(&self) -> usize {
        match &self.mapped {
            None => self.owned.len(),
            Some(m) => m.len,
        }
    }
}
