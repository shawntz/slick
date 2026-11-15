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

/// Most plain tokens the folder tier considers. Later tokens must match the name.
pub(crate) const MAX_ANC_TOKENS: usize = 6;
/// Most path fragments per query. Later ones are ignored.
pub(crate) const MAX_CHAINS: usize = 4;

/// One plain token.
pub(crate) struct Token {
    pub(crate) q: Query,
    pub(crate) mask: u32,
    /// Compressed initials bit of the first char, 0 when no initials check applies.
    pub(crate) first_initial: u32,
}

/// A path fragment: folder names, outermost first.
pub(crate) struct Chain {
    pub(crate) parts: Vec<Query>,
}

/// What a query asks for.
pub(crate) enum Parsed {
    Search(Box<Plan>),
    Browse { dir: Vec<u8>, filter: String },
}

/// A search query, folded once and shared by every worker.
pub(crate) struct Plan {
    /// The text the plan was built from, trimmed.
    pub(crate) raw: String,
    /// Number of whitespace-separated tokens, for narrowing.
    pub(crate) tokens_typed: usize,
    /// The plain tokens joined, matched against the name. `None` without plain tokens.
    pub(crate) literal: Option<Query>,
    pub(crate) lit_mask: u32,
    /// The plain tokens, for the folder tier.
    pub(crate) tokens: Vec<Token>,
    /// Queries over subsets of the plain tokens, indexed by token bitmask.
    pub(crate) subsets: Vec<Option<Query>>,
    /// The last plain token when it looks like an extension, with a query of the other tokens.
    pub(crate) bare_ext: Option<(Vec<u8>, Query, u32)>,
    /// A `.ext` filter: the extension must start with these folded bytes.
    pub(crate) dot_ext: Option<Vec<u8>>,
    pub(crate) dot_ext_mask: u32,
    pub(crate) chains: Vec<Chain>,
    /// Two or more plain tokens: the folder tier applies.
    pub(crate) ancestors: bool,
    /// One literal and nothing else: the typo pass applies.
    pub(crate) simple: bool,
    /// ASCII first char of the literal when it is a letter or digit: the prefix pass applies.
    pub(crate) first: Option<u8>,
}

impl Plan {
    /// True when a hit needs the folder memo: path fragments or the folder tier.
    pub(crate) fn needs_memo(&self) -> bool {
        self.ancestors || !self.chains.is_empty()
    }

    /// The query for the basename part of a folder-tier match.
    pub(crate) fn subset(&self, bits: u32) -> Option<&Query> {
        self.subsets.get(bits as usize).and_then(Option::as_ref)
    }
}

fn mask_of(q: &Query) -> u32 {
    compress_mask(q.mask)
}

/// Parses `raw`. `home` expands a leading `~`.
pub(crate) fn parse(raw: &str, home: Option<&[u8]>) -> Parsed {
    let text = raw.trim();
    if text.starts_with('/') || text.starts_with('~') {
        return parse_browse(text, home);
    }
    let words: Vec<&str> = text.split_whitespace().collect();
    let mut plain: Vec<&str> = Vec::new();
    let mut chains = Vec::new();
    let mut dot_ext: Option<Vec<u8>> = None;
    let last = words.len().saturating_sub(1);
    let mut bare_candidate = false;
    for (i, w) in words.iter().enumerate() {
        if w.contains('/') {
            let open_end = w.ends_with('/');
            let mut parts: Vec<&str> = w.split('/').filter(|p| !p.is_empty()).collect();
            if i == last
                && !open_end
                && parts.len() >= 2
                && let Some(tail) = parts.pop()
            {
                plain.push(tail);
            }
            if !parts.is_empty() && chains.len() < MAX_CHAINS {
                chains.push(Chain {
                    parts: parts.iter().map(|p| Query::new(p)).collect(),
                });
            }
            continue;
        }
        let b = w.as_bytes();
        if b.len() >= 2 && b[0] == b'.' && b[1..].iter().all(u8::is_ascii_alphanumeric) {
            dot_ext = Some(b[1..].to_ascii_lowercase());
            continue;
        }
        // A token of ASCII punctuation alone, such as the "." typed before "pdf", would match
        // nearly every name; it adds nothing.
        if b.iter().all(u8::is_ascii_punctuation) {
            continue;
        }
        plain.push(w);
        bare_candidate = i == last;
    }

    let joined = plain.join(" ");
    let literal = (!plain.is_empty())
        .then(|| Query::new(&joined))
        .filter(|q| !q.is_empty());
    let lit_mask = literal.as_ref().map_or(0, mask_of);
    let tokens: Vec<Token> = plain
        .iter()
        .map(|t| {
            let q = Query::new(t);
            let mask = mask_of(&q);
            let first_initial = crate::search::first_initial(&q);
            Token { q, mask, first_initial }
        })
        .collect();
    let ancestors = tokens.len() >= 2;
    let mut subsets = Vec::new();
    if ancestors {
        let n = tokens.len().min(MAX_ANC_TOKENS);
        subsets.resize_with(1 << n, || None);
        for (bits, slot) in subsets.iter_mut().enumerate().skip(1) {
            let mut parts: Vec<&str> = (0..n).filter(|i| bits >> i & 1 == 1).map(|i| plain[i]).collect();
            // Tokens past the folder-tier limit always stay on the name.
            parts.extend(plain.iter().skip(n));
            *slot = Some(Query::new(&parts.join(" ")));
        }
    }
    let bare_ext = match plain.last() {
        Some(t)
            if bare_candidate && plain.len() >= 2 && t.len() <= 8 && t.bytes().all(|b| b.is_ascii_alphanumeric()) =>
        {
            let rest = Query::new(&plain[..plain.len() - 1].join(" "));
            let m = mask_of(&rest);
            Some((t.to_ascii_lowercase().into_bytes(), rest, m))
        }
        _ => None,
    };
    let dot_ext_mask = dot_ext
        .as_ref()
        .map_or(0, |e| mask_of(&Query::new(&format!(".{}", String::from_utf8_lossy(e)))));
    let first = literal
        .as_ref()
        .filter(|q| q.ascii)
        .and_then(|q| q.full.first().copied())
        .filter(u8::is_ascii_alphanumeric);
    let simple = literal.is_some() && chains.is_empty() && dot_ext.is_none() && !ancestors && bare_ext.is_none();
    Parsed::Search(Box::new(Plan {
        raw: text.to_string(),
        tokens_typed: words.len(),
        literal,
        lit_mask,
        tokens,
        subsets,
        bare_ext,
        dot_ext,
        dot_ext_mask,
        chains,
        ancestors,
        simple,
        first,
    }))
}

fn parse_browse(text: &str, home: Option<&[u8]>) -> Parsed {
    let mut path: Vec<u8> = Vec::with_capacity(text.len() + 32);
    if let Some(rest) = text.strip_prefix('~') {
        if let Some(h) = home {
            path.extend_from_slice(h);
        }
        if !rest.starts_with('/') {
            path.push(b'/');
        }
        path.extend_from_slice(rest.as_bytes());
    } else {
        path.extend_from_slice(text.as_bytes());
    }
    let cut = path.iter().rposition(|&b| b == b'/').map_or(0, |p| p + 1);
    let filter = String::from_utf8_lossy(&path[cut..]).into_owned();
    path.truncate(cut);
    Parsed::Browse { dir: path, filter }
}

/// True when results for `new` can be found among the matches for `old`: `new` extends `old` by
/// characters that are not whitespace or `/`, and every token keeps its kind. Every gate in the
/// search is monotone under such an extension.
pub(crate) fn narrows(old: &Plan, new: &Plan) -> bool {
    if old.raw.is_empty() || old.tokens_typed != new.tokens_typed || !new.raw.starts_with(&old.raw) {
        return false;
    }
    let same_shape = old.tokens.len() == new.tokens.len()
        && old.dot_ext.is_some() == new.dot_ext.is_some()
        && old.chains.len() == new.chains.len()
        && old
            .chains
            .iter()
            .zip(&new.chains)
            .all(|(a, b)| a.parts.len() == b.parts.len());
    let added = &new.raw[old.raw.len()..];
    same_shape && !added.is_empty() && !added.chars().any(|c| c.is_whitespace() || c == '/')
}

#[cfg(test)]
mod tests {
    use super::*;

    fn plan(s: &str) -> Box<Plan> {
        match parse(s, Some(b"/home/someone")) {
            Parsed::Search(p) => p,
            Parsed::Browse { .. } => panic!("expected a search for {s:?}"),
        }
    }

    #[test]
    fn plain_tokens_and_folder_tier() {
        let p = plan("docs readme");
        assert_eq!(p.tokens.len(), 2);
        assert!(p.ancestors);
        assert!(!p.simple);
        assert_eq!(p.subsets.len(), 4);
        assert_eq!(p.subset(0b10).map(|q| q.full.clone()), Some(b"readme".to_vec()));
        assert_eq!(p.first, Some(b'd'));
        let s = plan("readme");
        assert!(s.simple && !s.ancestors);
    }

    #[test]
    fn extensions() {
        let p = plan("report .pdf");
        assert_eq!(p.dot_ext.as_deref(), Some(&b"pdf"[..]));
        assert_eq!(p.literal.as_ref().map(|q| q.full.clone()), Some(b"report".to_vec()));
        let p = plan(".PDF");
        assert!(p.literal.is_none());
        assert_eq!(p.dot_ext.as_deref(), Some(&b"pdf"[..]));
        let p = plan("report pdf");
        assert_eq!(p.bare_ext.as_ref().map(|b| b.0.clone()), Some(b"pdf".to_vec()));
        assert!(plan("report final-version").bare_ext.is_none());
        assert!(
            plan(".").dot_ext.is_none() && plan(".").literal.is_none(),
            "a lone dot is ignored"
        );
        assert_eq!(plan("x . -").tokens.len(), 1);
    }

    #[test]
    fn path_fragments() {
        let p = plan("proj/src main");
        assert_eq!(p.chains.len(), 1);
        assert_eq!(p.chains[0].parts.len(), 2);
        assert_eq!(p.tokens.len(), 1);
        let p = plan("src/main");
        assert_eq!(p.chains.len(), 1);
        assert_eq!(p.chains[0].parts.len(), 1);
        assert_eq!(p.literal.as_ref().map(|q| q.full.clone()), Some(b"main".to_vec()));
        let p = plan("proj/");
        assert!(p.literal.is_none());
        assert_eq!(p.chains.len(), 1);
    }

    #[test]
    fn browse() {
        match parse("~/Docu", Some(b"/home/someone")) {
            Parsed::Browse { dir, filter } => {
                assert_eq!(dir, b"/home/someone/".to_vec());
                assert_eq!(filter, "Docu");
            }
            Parsed::Search(_) => panic!("browse"),
        }
        match parse("/tmp/a/", None) {
            Parsed::Browse { dir, filter } => {
                assert_eq!(dir, b"/tmp/a/".to_vec());
                assert_eq!(filter, "");
            }
            Parsed::Search(_) => panic!("browse"),
        }
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
