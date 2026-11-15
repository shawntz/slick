//! Turning typed text into a search plan.
//!
//! - Text that starts with `/` or `~` browses a folder, as `browse` describes.
//! - Every other query is split on whitespace into tokens:
//!   - a token with a `/` is a path fragment: `proj/src` needs a folder that starts with `proj`
//!     right above one that starts with `src`, somewhere above the entry. When the last token has
//!     no trailing slash, its last part is matched against the name instead: `src/main` finds
//!     names starting with `main` below a folder starting with `src`;
//!   - a token like `.pdf` keeps only names whose extension starts with `pdf` and matches the other
//!     tokens against the name without its extension;
//!   - a token of ASCII punctuation alone is ignored;
//!   - a token of ASCII punctuation alone, such as a lone `.`, is ignored;
//!   - every other token is a word of the name query. With two or more of them, a token that does
//!     not fit the name may instead start a word of a folder above it ("docs readme"). When the
//!     last of them looks like an extension ("report pdf"), the others are also tried against the
//!     name without that extension.

use crate::names::compress_mask;
use slick_match::Query;
use slick_match::fold::mask_bit_byte;

/// Most plain tokens the folder tier considers. Later tokens must match the name.
pub(crate) const MAX_ANC_TOKENS: usize = 6;
/// Most path fragments per query. Later ones are ignored.
pub(crate) const MAX_CHAINS: usize = 4;

/// One plain token.
#[derive(Default)]
pub(crate) struct Token {
    pub(crate) q: Query,
    pub(crate) mask: u32,
    /// Compressed initials bit of the first char, 0 when no initials check applies.
    pub(crate) first_initial: u32,
    /// The token is one ASCII letter, so it matches a name at word-prefix or better exactly when
    /// the letter starts a word: the initials mask decides without scoring.
    pub(crate) letter: bool,
}

/// A path fragment: folder names, outermost first.
#[derive(Default)]
pub(crate) struct Chain {
    parts: Vec<Query>,
    used: usize,
}

impl Chain {
    /// The folder names, outermost first.
    pub(crate) fn parts(&self) -> &[Query] {
        &self.parts[..self.used]
    }
}

/// A query, folded once and shared by every worker. It keeps its buffers, so a plan that is
/// parsed again for the next keystroke allocates nothing once its buffers have grown.
#[derive(Default)]
pub(crate) struct Plan {
    /// The text the plan was built from, trimmed.
    pub(crate) raw: String,
    /// Number of whitespace-separated tokens, for narrowing.
    pub(crate) tokens_typed: usize,
    literal: Query,
    has_literal: bool,
    pub(crate) lit_mask: u32,
    tokens: Vec<Token>,
    n_tokens: usize,
    /// Queries over subsets of the plain tokens, indexed by token bitmask; slot 0 is unused.
    subsets: Vec<Query>,
    n_subsets: usize,
    bare_ext: Vec<u8>,
    bare_rest: Query,
    bare_mask: u32,
    has_bare_ext: bool,
    dot_ext: Vec<u8>,
    has_dot_ext: bool,
    pub(crate) dot_ext_mask: u32,
    chains: Vec<Chain>,
    n_chains: usize,
    /// Two or more plain tokens: the folder tier applies.
    pub(crate) ancestors: bool,
    /// One literal and nothing else: the typo pass applies.
    pub(crate) simple: bool,
    /// ASCII first char of the literal when it is a letter or digit: the prefix pass applies.
    pub(crate) first: Option<u8>,
    /// The text starts with `/` or `~`: a folder listing.
    browse: bool,
    browse_dir: Vec<u8>,
    browse_filter: String,
    /// Byte ranges of the whitespace-separated words of `raw`.
    words: Vec<(usize, usize)>,
    /// Byte ranges of the plain tokens in `raw`.
    plain: Vec<(usize, usize)>,
    joined: String,
}

impl Plan {
    /// A plan for `raw`. Allocates; searches reuse plans through [`Plan::parse`].
    pub(crate) fn new(raw: &str, home: Option<&[u8]>) -> Plan {
        let mut p = Plan::default();
        p.parse(raw, home);
        p
    }

    /// True when a hit needs the folder memo: path fragments or the folder tier.
    pub(crate) fn needs_memo(&self) -> bool {
        self.ancestors || self.n_chains > 0
    }

    /// The plain tokens joined, matched against the name. `None` without plain tokens.
    pub(crate) fn literal(&self) -> Option<&Query> {
        self.has_literal.then_some(&self.literal)
    }

    /// The plain tokens, for the folder tier.
    pub(crate) fn tokens(&self) -> &[Token] {
        &self.tokens[..self.n_tokens]
    }

    /// The path fragments.
    pub(crate) fn chains(&self) -> &[Chain] {
        &self.chains[..self.n_chains]
    }

    /// A `.ext` filter: the extension must start with these folded bytes.
    pub(crate) fn dot_ext(&self) -> Option<&[u8]> {
        self.has_dot_ext.then_some(self.dot_ext.as_slice())
    }

    /// The last plain token when it looks like an extension, with a query of the other tokens and
    /// that query's compressed mask.
    pub(crate) fn bare_ext(&self) -> Option<(&[u8], &Query, u32)> {
        self.has_bare_ext
            .then_some((self.bare_ext.as_slice(), &self.bare_rest, self.bare_mask))
    }

    /// The query for the basename part of a folder-tier match.
    pub(crate) fn subset(&self, bits: u32) -> Option<&Query> {
        let i = bits as usize;
        (i > 0 && i < self.n_subsets).then(|| &self.subsets[i])
    }

    /// The folder and the filter of a folder listing, when the text asks for one.
    pub(crate) fn browse(&self) -> Option<(&[u8], &str)> {
        self.browse
            .then_some((self.browse_dir.as_slice(), self.browse_filter.as_str()))
    }

    /// Parses `raw` into this plan, reusing its buffers. `home` expands a leading `~`.
    pub(crate) fn parse(&mut self, raw: &str, home: Option<&[u8]>) {
        let text = raw.trim();
        self.raw.clear();
        self.raw.push_str(text);
        self.has_literal = false;
        self.lit_mask = 0;
        self.n_tokens = 0;
        self.n_subsets = 0;
        self.has_bare_ext = false;
        self.bare_mask = 0;
        self.has_dot_ext = false;
        self.dot_ext_mask = 0;
        self.n_chains = 0;
        self.ancestors = false;
        self.simple = false;
        self.first = None;
        self.browse = false;
        self.tokens_typed = 0;
        if text.starts_with('/') || text.starts_with('~') {
            self.parse_browse(home);
            return;
        }
        let Plan {
            raw,
            words,
            plain,
            chains,
            n_chains,
            dot_ext,
            has_dot_ext,
            ..
        } = self;
        words.clear();
        plain.clear();
        let base = raw.as_ptr() as usize;
        words.extend(raw.split_whitespace().map(|w| {
            let at = w.as_ptr() as usize - base;
            (at, at + w.len())
        }));
        let last = words.len().saturating_sub(1);
        let mut bare_candidate = false;
        for (i, &(ws, we)) in words.iter().enumerate() {
            let w = &raw[ws..we];
            if w.contains('/') {
                let open_end = w.ends_with('/');
                let n_parts = w.split('/').filter(|p| !p.is_empty()).count();
                // The last part of the last token names the entry when no slash ends it.
                let tail = i == last && !open_end && n_parts >= 2;
                let folder_parts = if tail { n_parts - 1 } else { n_parts };
                if tail && let Some(t) = w.rsplit('/').find(|p| !p.is_empty()) {
                    let at = ws + (t.as_ptr() as usize - w.as_ptr() as usize);
                    plain.push((at, at + t.len()));
                }
                if folder_parts > 0 && *n_chains < MAX_CHAINS {
                    if chains.len() == *n_chains {
                        chains.push(Chain::default());
                    }
                    let chain = &mut chains[*n_chains];
                    chain.used = 0;
                    for part in w.split('/').filter(|p| !p.is_empty()).take(folder_parts) {
                        if chain.parts.len() == chain.used {
                            chain.parts.push(Query::default());
                        }
                        chain.parts[chain.used].set(part);
                        chain.used += 1;
                    }
                    *n_chains += 1;
                }
                continue;
            }
            let b = w.as_bytes();
            if b.len() >= 2 && b[0] == b'.' && b[1..].iter().all(u8::is_ascii_alphanumeric) {
                dot_ext.clear();
                dot_ext.extend(b[1..].iter().map(u8::to_ascii_lowercase));
                *has_dot_ext = true;
                continue;
            }
            // A token of ASCII punctuation alone, such as the "." typed before "pdf", would match
            // nearly every name; it adds nothing.
            if b.iter().all(u8::is_ascii_punctuation) {
                continue;
            }
            plain.push((ws, we));
            bare_candidate = i == last;
        }
        self.tokens_typed = self.words.len();

        // The literal: every plain token, joined by single spaces.
        join(&mut self.joined, &self.raw, self.plain.iter());
        if !self.plain.is_empty() {
            self.literal.set(&self.joined);
            self.has_literal = !self.literal.is_empty();
        }
        self.lit_mask = if self.has_literal { mask_of(&self.literal) } else { 0 };

        let n = self.plain.len();
        while self.tokens.len() < n {
            self.tokens.push(Token::default());
        }
        for (t, &(s, e)) in self.tokens.iter_mut().zip(&self.plain) {
            t.q.set(&self.raw[s..e]);
            t.mask = mask_of(&t.q);
            t.first_initial = crate::search::first_initial(&t.q);
            t.letter = t.q.ascii && t.q.full.len() == 1 && t.q.full[0].is_ascii_alphabetic();
        }
        self.n_tokens = n;
        self.ancestors = n >= 2;
        if self.ancestors {
            let m = n.min(MAX_ANC_TOKENS);
            self.n_subsets = 1 << m;
            while self.subsets.len() < self.n_subsets {
                self.subsets.push(Query::default());
            }
            for bits in 1..self.n_subsets {
                // Tokens past the folder-tier limit always stay on the name.
                let picked = self
                    .plain
                    .iter()
                    .enumerate()
                    .filter(|&(i, _)| i >= m || bits >> i & 1 == 1)
                    .map(|(_, r)| r);
                join(&mut self.joined, &self.raw, picked);
                self.subsets[bits].set(&self.joined);
            }
        }
        if let Some(&(s, e)) = self.plain.last() {
            let t = &self.raw[s..e];
            if bare_candidate && n >= 2 && t.len() <= 8 && t.bytes().all(|b| b.is_ascii_alphanumeric()) {
                join(&mut self.joined, &self.raw, self.plain[..n - 1].iter());
                self.bare_rest.set(&self.joined);
                self.bare_mask = mask_of(&self.bare_rest);
                self.bare_ext.clear();
                self.bare_ext.extend(t.bytes().map(|b| b.to_ascii_lowercase()));
                self.has_bare_ext = true;
            }
        }
        if self.has_dot_ext {
            // The mask of the query ".<ext>": the dot and every folded byte of the extension.
            let m = self
                .dot_ext
                .iter()
                .fold(mask_bit_byte(b'.'), |m, &b| m | mask_bit_byte(b));
            self.dot_ext_mask = compress_mask(m);
        }
        self.first = self
            .literal()
            .filter(|q| q.ascii)
            .and_then(|q| q.full.first().copied())
            .filter(u8::is_ascii_alphanumeric);
        self.simple =
            self.has_literal && self.n_chains == 0 && !self.has_dot_ext && !self.ancestors && !self.has_bare_ext;
    }

    fn parse_browse(&mut self, home: Option<&[u8]>) {
        self.browse = true;
        let path = &mut self.browse_dir;
        path.clear();
        if let Some(rest) = self.raw.strip_prefix('~') {
            if let Some(h) = home {
                path.extend_from_slice(h);
            }
            if !rest.starts_with('/') {
                path.push(b'/');
            }
            path.extend_from_slice(rest.as_bytes());
        } else {
            path.extend_from_slice(self.raw.as_bytes());
        }
        let cut = path.iter().rposition(|&b| b == b'/').map_or(0, |p| p + 1);
        self.browse_filter.clear();
        for chunk in path[cut..].utf8_chunks() {
            self.browse_filter.push_str(chunk.valid());
            if !chunk.invalid().is_empty() {
                self.browse_filter.push(char::REPLACEMENT_CHARACTER);
            }
        }
        path.truncate(cut);
    }
}

/// Writes the byte ranges of `raw` into `out`, separated by single spaces.
fn join<'a>(out: &mut String, raw: &str, ranges: impl Iterator<Item = &'a (usize, usize)>) {
    out.clear();
    for (i, &(s, e)) in ranges.enumerate() {
        if i > 0 {
            out.push(' ');
        }
        out.push_str(&raw[s..e]);
    }
}

fn mask_of(q: &Query) -> u32 {
    compress_mask(q.mask)
}

/// True when results for `new` can be found among the matches for `old`: `new` extends `old` by
/// characters that are not whitespace or `/`, and every token keeps its kind. Every gate in the
/// search is monotone under such an extension.
pub(crate) fn narrows(old: &Plan, new: &Plan) -> bool {
    if old.raw.is_empty() || old.tokens_typed != new.tokens_typed || !new.raw.starts_with(&old.raw) {
        return false;
    }
    let same_shape = old.n_tokens == new.n_tokens
        && old.has_dot_ext == new.has_dot_ext
        && old.n_chains == new.n_chains
        && old.chains().iter().zip(new.chains()).all(|(a, b)| a.used == b.used);
    let added = &new.raw[old.raw.len()..];
    same_shape && !added.is_empty() && !added.chars().any(|c| c.is_whitespace() || c == '/')
}

#[cfg(test)]
mod tests {
    use super::*;

    fn plan(s: &str) -> Plan {
        let p = Plan::new(s, Some(b"/home/someone"));
        assert!(p.browse().is_none(), "expected a search for {s:?}");
        p
    }

    #[test]
    fn plain_tokens_and_folder_tier() {
        let p = plan("docs readme");
        assert_eq!(p.tokens().len(), 2);
        assert!(p.ancestors);
        assert!(!p.simple);
        assert_eq!(p.n_subsets, 4);
        assert_eq!(p.subset(0b10).map(|q| q.full.clone()), Some(b"readme".to_vec()));
        assert_eq!(p.first, Some(b'd'));
        let s = plan("readme");
        assert!(s.simple && !s.ancestors);
    }

    #[test]
    fn extensions() {
        let p = plan("report .pdf");
        assert_eq!(p.dot_ext(), Some(&b"pdf"[..]));
        assert_eq!(p.literal().map(|q| q.full.clone()), Some(b"report".to_vec()));
        let p = plan(".PDF");
        assert!(p.literal().is_none());
        assert_eq!(p.dot_ext(), Some(&b"pdf"[..]));
        let p = plan("report pdf");
        assert_eq!(p.bare_ext().map(|b| b.0.to_vec()), Some(b"pdf".to_vec()));
        assert!(plan("report final-version").bare_ext().is_none());
        assert!(
            plan(".").dot_ext().is_none() && plan(".").literal().is_none(),
            "a lone dot is ignored"
        );
        assert_eq!(plan("x . -").tokens().len(), 1);
    }

    #[test]
    fn path_fragments() {
        let p = plan("proj/src main");
        assert_eq!(p.chains().len(), 1);
        assert_eq!(p.chains()[0].parts().len(), 2);
        assert_eq!(p.tokens().len(), 1);
        let p = plan("src/main");
        assert_eq!(p.chains().len(), 1);
        assert_eq!(p.chains()[0].parts().len(), 1);
        assert_eq!(p.literal().map(|q| q.full.clone()), Some(b"main".to_vec()));
        let p = plan("proj/");
        assert!(p.literal().is_none());
        assert_eq!(p.chains().len(), 1);
    }

    #[test]
    fn browse() {
        let p = Plan::new("~/Docu", Some(b"/home/someone"));
        assert_eq!(p.browse(), Some((&b"/home/someone/"[..], "Docu")));
        let p = Plan::new("/tmp/a/", None);
        assert_eq!(p.browse(), Some((&b"/tmp/a/"[..], "")));
    }

    #[test]
    fn narrowing_rules() {
        assert!(narrows(&plan("rea"), &plan("read")));
        assert!(!narrows(&plan("read"), &plan("read me")), "a new token");
        assert!(!narrows(&plan("src"), &plan("src/")), "a slash");
        assert!(narrows(&plan("src/m"), &plan("src/ma")));
        assert!(narrows(&plan("docs re"), &plan("docs rea")));
        assert!(!narrows(&plan("read"), &plan("read")), "same text");
        assert!(!narrows(&plan("x ."), &plan("x .p")), "a token changes kind");
        assert!(!narrows(&plan(".p"), &plan(".p-")), "a token changes kind");
        assert!(narrows(&plan("x .p"), &plan("x .pd")));
    }
}
