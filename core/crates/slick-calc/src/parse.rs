//! A Pratt parser that evaluates as it reads. Phrase forms such as "days until christmas" and
//! "30 is what % of 120" are tried before the general expression grammar.
//!
//! Precedence, loosest first: conversion with "in", "to" and "as", addition, multiplication with
//! "of", "off" and "on" for percentages, unary minus, implicit multiplication such as 2pi and 2(3+4),
//! power, which is right associative, then postfix factorial, percent, squares and units.

use crate::answer::Problem;
use crate::cal;
use crate::context::AngleUnit;
use crate::currency::{self, CURRENCIES, Code};
use crate::lex::{self, K, Lexed, Tok};
use crate::lexicon::{self, Const, Func, Hits, Holiday, Meaning};
use crate::num::{Num, Rounding};
use crate::units::{self, ANGLE, TIME, UnitRef};
use crate::value::{self, Env, MulOp, Qty, VResult, Val, ZoneSel};
use core::cell::Cell;

pub(crate) const MAX_DEPTH: u32 = 24;

const ADD_BP: u8 = 10;
const MUL_BP: u8 = 20;
const UNARY_BP: u8 = 30;
const IMPLICIT_BP: u8 = 40;
const POW_BP: u8 = 50;

/// How an answer is written, when the query asks for a form rather than a unit.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Display {
    Base(u32),
    Words,
    Fraction(bool),
    Sci,
    Percent,
    Unix,
}

/// What the parser saw, for the confidence that the query is a calculation.
#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct Score {
    /// Explicit operators and function calls.
    pub ops: u8,
    pub implicit: u8,
    pub conv: bool,
    /// Set by a phrase form or keyword: its own confidence.
    pub form: u8,
    pub based: bool,
    pub sci: bool,
    pub scaled: bool,
    pub glued_symbol: bool,
    pub compound: bool,
    pub constant: Option<Const>,
    pub unix: bool,
    pub implied_year: bool,
    pub signed_pct: bool,
    pub literals: u8,
    /// The currency money was converted from, for the rate line.
    pub from_currency: Option<Code>,
}

pub(crate) struct Outcome {
    pub val: Val,
    pub display: Option<Display>,
    pub score: Score,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Op {
    Add,
    Sub,
    Mul,
    Div,
    Mod,
    Pow,
    Of,
    Off,
    On,
    Implicit,
}

pub(crate) struct Parser<'a> {
    src: &'a str,
    lx: &'a Lexed,
    pos: usize,
    env: &'a Env<'a>,
    depth: u32,
    score: Score,
    /// A time unit appeared earlier, so a bare "m" means minutes: "2h 30m + 45m".
    time_context: bool,
    /// The holiday the last date came from, so "days until easter" finds next year's date.
    holiday: Option<Holiday>,
    /// Recent lexicon lookups by byte range: the parser often asks about the same words twice.
    memo: [Cell<(u16, u16, Hits)>; 8],
    memo_next: Cell<usize>,
}

type P<T> = Option<T>;

const END: Tok = Tok {
    k: K::End,
    sym: '\0',
    start: 0,
    end: 0,
    space: false,
    flags: 0,
    aux: 0,
};

fn time_unit(u: UnitRef) -> bool {
    u.dim() == TIME
}

pub(crate) fn parse<'a>(src: &'a str, lx: &'a Lexed, env: &'a Env<'a>) -> Option<Outcome> {
    let mut p = Parser {
        src,
        lx,
        pos: 0,
        env,
        depth: 0,
        score: Score::default(),
        time_context: false,
        holiday: None,
        memo: Default::default(),
        memo_next: Cell::new(0),
    };
    p.query()
}

impl<'a> Parser<'a> {
    // Token access.

    fn tok(&self, i: usize) -> Tok {
        if i >= self.lx.len {
            return self.lx.toks.get(self.lx.len).copied().unwrap_or(END);
        }
        self.lx.toks.get(i).copied().unwrap_or(END)
    }

    fn cur(&self) -> Tok {
        self.tok(self.pos)
    }

    fn text(&self, t: Tok) -> &'a str {
        self.src.get(usize::from(t.start)..usize::from(t.end)).unwrap_or("")
    }

    fn word(&self, i: usize) -> Option<&'a str> {
        let t = self.tok(i);
        if t.k == K::Word { Some(self.text(t)) } else { None }
    }

    fn is_word(&self, i: usize, w: &str) -> bool {
        self.word(i).is_some_and(|s| s.eq_ignore_ascii_case(w))
    }

    fn is_any(&self, i: usize, ws: &[&str]) -> bool {
        self.word(i)
            .is_some_and(|s| ws.iter().any(|w| s.eq_ignore_ascii_case(w)))
    }

    fn is_sym(&self, i: usize, c: char) -> bool {
        let t = self.tok(i);
        t.k == K::Sym && t.sym == c
    }

    fn at_end(&self) -> bool {
        self.cur().k == K::End
    }

    fn num_at(&self, i: usize) -> Option<Num> {
        let t = self.tok(i);
        if t.k != K::Num {
            return None;
        }
        self.lx.nums.get(usize::try_from(t.aux).ok()?).copied()
    }

    fn eat_word(&mut self, w: &str) -> bool {
        if self.is_word(self.pos, w) {
            self.pos += 1;
            true
        } else {
            false
        }
    }

    fn eat_any(&mut self, ws: &[&str]) -> bool {
        if self.is_any(self.pos, ws) {
            self.pos += 1;
            true
        } else {
            false
        }
    }

    fn eat_sym(&mut self, c: char) -> bool {
        if self.is_sym(self.pos, c) {
            self.pos += 1;
            true
        } else {
            false
        }
    }

    fn enter(&mut self) -> P<()> {
        self.depth += 1;
        if self.depth > MAX_DEPTH { None } else { Some(()) }
    }

    fn leave(&mut self) {
        self.depth = self.depth.saturating_sub(1);
    }

    /// Every meaning of the source text between two byte offsets, memoized.
    fn lookup_range(&self, start: u16, end: u16) -> Hits {
        if end > 0
            && let Some(slot) = self.memo.iter().find(|c| {
                let (s, e, _) = c.get();
                s == start && e == end
            })
        {
            return slot.get().2;
        }
        let raw = self.src.get(usize::from(start)..usize::from(end)).unwrap_or("");
        let hits = lexicon::lookup(raw);
        let next = self.memo_next.get();
        if let Some(slot) = self.memo.get(next % self.memo.len()) {
            slot.set((start, end, hits));
        }
        self.memo_next.set(next.wrapping_add(1));
        hits
    }

    /// The longest run of tokens from `i` that names something, and how many tokens it took.
    fn span(&self, i: usize, max: usize) -> Option<(Hits, usize)> {
        let first = self.tok(i);
        let starts = first.k == K::Word || (first.k == K::Sym && first.sym == '°');
        if !starts {
            return None;
        }
        let mut n = 0;
        let mut j = i;
        while j < self.lx.len && n < max {
            let t = self.tok(j);
            let ok = match t.k {
                K::Word => true,
                K::Sym => matches!(t.sym, '/' | '°' | '²' | '³' | '.'),
                K::Num => n > 0 && self.is_sym(j - 1, '/'),
                _ => false,
            };
            if !ok {
                break;
            }
            n += 1;
            j += 1;
        }
        for k in (1..=n).rev() {
            let last = self.tok(i + k - 1);
            if last.k == K::Sym && matches!(last.sym, '/' | '.') {
                continue;
            }
            let hits = self.lookup_range(first.start, last.end);
            if !hits.is_empty() {
                return Some((hits, k));
            }
        }
        None
    }

    // The query.

    fn query(&mut self) -> Option<Outcome> {
        self.skip_lead();
        let start = self.pos;
        if let Some(val) = self.forms() {
            let display = self.conversions_onto(val);
            if let Some((val, display)) = display {
                self.skip_trailing();
                if self.at_end() {
                    return Some(Outcome {
                        val,
                        display,
                        score: self.score,
                    });
                }
            }
        }
        self.pos = start;
        self.depth = 0;
        self.score = Score::default();
        self.time_context = false;
        let v = self.expr(0)?;
        let v = self.post_forms(v)?;
        let (val, display) = self.conversions_onto(v)?;
        self.skip_trailing();
        if !self.at_end() {
            return None;
        }
        Some(Outcome {
            val,
            display,
            score: self.score,
        })
    }

    fn skip_lead(&mut self) {
        if self.eat_sym('=') {
            return;
        }
        if self.is_any(self.pos, &["what", "whats", "what's"]) && self.is_word(self.pos + 1, "is") {
            self.pos += 2;
        } else if self.is_any(self.pos, &["whats", "what's"]) && !self.is_word(self.pos + 1, "the") {
            self.pos += 1;
        } else if self.is_word(self.pos, "how")
            && self.is_word(self.pos + 1, "much")
            && self.is_word(self.pos + 2, "is")
        {
            self.pos += 3;
        } else if self.is_any(
            self.pos,
            &["calculate", "calc", "compute", "convert", "eval", "evaluate"],
        ) {
            self.pos += 1;
        }
    }

    fn skip_trailing(&mut self) {
        while self.is_sym(self.pos, '=') || self.is_sym(self.pos, '?') {
            self.pos += 1;
        }
    }

    // Expressions.

    fn expr(&mut self, min_bp: u8) -> P<Val> {
        self.enter()?;
        let mut lhs = self.unary()?;
        while let Some((op, lbp, rbp, len)) = self.infix(&lhs) {
            if lbp < min_bp {
                break;
            }
            self.pos += len;
            let rhs = self.expr(rbp)?;
            if op == Op::Implicit {
                self.score.implicit = self.score.implicit.saturating_add(1);
            } else {
                self.score.ops = self.score.ops.saturating_add(1);
            }
            lhs = self.apply(op, lhs, rhs);
        }
        self.leave();
        Some(lhs)
    }

    fn apply(&self, op: Op, a: Val, b: Val) -> Val {
        let env = self.env;
        let r: VResult<Val> = match op {
            Op::Add => value::add(env, a, b, 1),
            Op::Sub => value::add(env, a, b, -1),
            Op::Mul | Op::Implicit => value::mul(a, b, MulOp::Mul),
            Op::Div => value::mul(a, b, MulOp::Div),
            Op::Of => value::mul(a, b, MulOp::Mul),
            Op::Off | Op::On => match a {
                Val::Pct(p) => {
                    let k = if op == Op::Off {
                        Num::ONE.sub(p)
                    } else {
                        Num::ONE.add(p)
                    };
                    k.map_err(Problem::from)
                        .and_then(|k| value::mul(b, Val::Num(k), MulOp::Mul))
                }
                Val::Err(e) => Err(e),
                _ => Err(Problem::Unsupported),
            },
            Op::Mod => match (value::ok(a), value::ok(b)) {
                (Ok(Val::Num(x)), Ok(Val::Num(y))) => x.modulo(y).map(Val::Num).map_err(Problem::from),
                (Err(e), _) | (_, Err(e)) => Err(e),
                _ => Err(Problem::Unsupported),
            },
            Op::Pow => value::pow(a, b),
        };
        r.unwrap_or_else(Val::Err)
    }

    /// The infix operator at the cursor: the operator, its left and right binding powers, and its
    /// length in tokens.
    fn infix(&self, lhs: &Val) -> Option<(Op, u8, u8, usize)> {
        let i = self.pos;
        let t = self.cur();
        let mul = |op| Some((op, MUL_BP, MUL_BP + 1, 1));
        match t.k {
            K::Sym => match t.sym {
                '+' => Some((Op::Add, ADD_BP, ADD_BP + 1, 1)),
                '-' => Some((Op::Sub, ADD_BP, ADD_BP + 1, 1)),
                '*' => mul(Op::Mul),
                '/' => mul(Op::Div),
                '^' => Some((Op::Pow, POW_BP, POW_BP, 1)),
                '%' if self.starts_operand(i + 1) => mul(Op::Mod),
                '(' | 'π' | '√' if self.implicit_lhs(lhs) => Some((Op::Implicit, IMPLICIT_BP, IMPLICIT_BP + 1, 0)),
                _ => None,
            },
            K::Word => {
                let w = self.text(t);
                let lw = |s: &str| w.eq_ignore_ascii_case(s);
                if lw("plus") || lw("and") && matches!(lhs, Val::Qty(_)) && self.starts_operand(i + 1) {
                    return Some((Op::Add, ADD_BP, ADD_BP + 1, 1));
                }
                if lw("minus") {
                    return Some((Op::Sub, ADD_BP, ADD_BP + 1, 1));
                }
                if lw("times") || (lw("x") && self.starts_operand(i + 1)) {
                    return mul(Op::Mul);
                }
                if (lw("multiplied") || lw("divided")) && self.is_word(i + 1, "by") {
                    return Some((if lw("divided") { Op::Div } else { Op::Mul }, MUL_BP, MUL_BP + 1, 2));
                }
                if lw("over") && self.starts_operand(i + 1) {
                    return mul(Op::Div);
                }
                if lw("mod") || lw("modulo") {
                    return mul(Op::Mod);
                }
                // "15% tip on $80", "20% discount off $500": the noun is decoration.
                if matches!(lhs, Val::Pct(_))
                    && ["tip", "discount", "tax", "vat", "markup", "gratuity"]
                        .iter()
                        .any(|k| lw(k))
                    && self.is_any(i + 1, &["of", "off", "on"])
                {
                    let op = if self.is_word(i + 1, "of") {
                        Op::Of
                    } else if self.is_word(i + 1, "off") {
                        Op::Off
                    } else {
                        Op::On
                    };
                    return Some((op, MUL_BP, MUL_BP + 1, 2));
                }
                if lw("of") && matches!(lhs, Val::Pct(_)) {
                    return mul(Op::Of);
                }
                if lw("off") && matches!(lhs, Val::Pct(_)) {
                    return mul(Op::Off);
                }
                if lw("on") && matches!(lhs, Val::Pct(_)) {
                    return mul(Op::On);
                }
                if lw("to") && self.is_word(i + 1, "the") && self.is_word(i + 2, "power") && self.is_word(i + 3, "of") {
                    return Some((Op::Pow, POW_BP, POW_BP, 4));
                }
                if lw("raised") && self.is_word(i + 1, "to") {
                    let len = if self.is_word(i + 2, "the") && self.is_word(i + 3, "power") && self.is_word(i + 4, "of")
                    {
                        5
                    } else {
                        2
                    };
                    return Some((Op::Pow, POW_BP, POW_BP, len));
                }
                if lw("power") || lw("pow") {
                    let len = if self.is_word(i + 1, "of") { 2 } else { 1 };
                    return Some((Op::Pow, POW_BP, POW_BP, len));
                }
                if self.implicit_lhs(lhs) && self.const_or_func(i) {
                    return Some((Op::Implicit, IMPLICIT_BP, IMPLICIT_BP + 1, 0));
                }
                None
            }
            _ => None,
        }
    }

    fn implicit_lhs(&self, lhs: &Val) -> bool {
        matches!(lhs, Val::Num(_))
    }

    fn const_or_func(&self, i: usize) -> bool {
        let Some(w) = self.word(i) else { return false };
        if w.eq_ignore_ascii_case("square") || w.eq_ignore_ascii_case("cube") {
            return false;
        }
        let t = self.tok(i);
        self.lookup_range(t.start, t.end)
            .iter()
            .any(|m| matches!(m, Meaning::Const(_) | Meaning::Func(_)))
    }

    /// True when a value can start at token `i`.
    fn starts_operand(&self, i: usize) -> bool {
        let t = self.tok(i);
        match t.k {
            K::Num | K::Clock | K::Date => true,
            K::Sym => matches!(t.sym, '(' | '-' | 'π' | '√' | '$' | '€' | '£' | '¥' | '₹'),
            K::Word => self.const_or_func(i),
            K::End => false,
        }
    }

    fn unary(&mut self) -> P<Val> {
        if self.eat_sym('-') || self.eat_any(&["minus", "negative"]) {
            let v = self.expr(UNARY_BP)?;
            return Some(value::neg(v).unwrap_or_else(Val::Err));
        }
        if self.eat_sym('+') {
            return self.expr(UNARY_BP);
        }
        if self.eat_sym('√') {
            let v = self.expr(POW_BP)?;
            self.score.ops = self.score.ops.saturating_add(1);
            return Some(self.call_one(Func::Sqrt, v));
        }
        if self.eat_sym('∛') {
            let v = self.expr(POW_BP)?;
            self.score.ops = self.score.ops.saturating_add(1);
            return Some(self.call_one(Func::Cbrt, v));
        }
        let v = self.primary()?;
        self.postfix(v)
    }

    fn postfix(&mut self, mut v: Val) -> P<Val> {
        loop {
            let i = self.pos;
            if self.is_sym(i, '!') && !self.is_sym(i + 1, '=') {
                self.pos += 1;
                self.score.ops = self.score.ops.saturating_add(1);
                v = match value::number(v) {
                    Ok(n) => n.factorial().map(Val::Num).unwrap_or_else(|e| Val::Err(e.into())),
                    Err(e) => Val::Err(e),
                };
            } else if self.is_sym(i, '²') || self.is_sym(i, '³') || self.is_any(i, &["squared", "cubed"]) {
                let k = if self.is_sym(i, '²') || self.is_word(i, "squared") {
                    2
                } else {
                    3
                };
                self.pos += 1;
                self.score.ops = self.score.ops.saturating_add(1);
                v = value::pow(v, Val::Num(Num::int(k))).unwrap_or_else(Val::Err);
            } else if self.is_sym(i, '%') && !self.starts_operand(i + 1) && matches!(v, Val::Num(_) | Val::Err(_)) {
                self.pos += 1;
                v = match v {
                    Val::Num(n) => n
                        .div(Num::int(100))
                        .map(Val::Pct)
                        .unwrap_or_else(|e| Val::Err(e.into())),
                    other => other,
                };
            } else if self.is_any(i, &["percent", "pct", "percentage"]) && matches!(v, Val::Num(_)) {
                self.pos += 1;
                if let Val::Num(n) = v {
                    v = n
                        .div(Num::int(100))
                        .map(Val::Pct)
                        .unwrap_or_else(|e| Val::Err(e.into()));
                }
            } else if let Val::Qty(q) = v
                && q.dim == TIME
                && let Some(nv) = self.relative(q)?
            {
                v = nv;
            } else if let Val::Date(d) = v
                && let Some(nv) = self.date_at_time(d)
            {
                v = nv;
            } else {
                return Some(v);
            }
        }
    }

    /// A date followed by a time: "tomorrow 3pm", "dec 25 at noon", "2026-12-25 15:00".
    fn date_at_time(&mut self, d: i32) -> Option<Val> {
        let save = self.pos;
        self.eat_word("at");
        let t = self.cur();
        let clockish = t.k == K::Clock
            || (t.k == K::Num && self.is_any(self.pos + 1, &["am", "pm"]))
            || self.is_any(self.pos, &["noon", "midday", "midnight"]);
        if clockish && let Some(Val::Clock(secs, z)) = self.primary() {
            let local = i64::from(d) * cal::SECS_PER_DAY + i64::from(secs);
            return Some(match self.env.to_utc(z, local) {
                Ok(t) => Val::Moment(t, z),
                Err(e) => Val::Err(e),
            });
        }
        self.pos = save;
        None
    }

    /// "3 days ago", "2 hours from now", "1 week before christmas".
    fn relative(&mut self, q: Qty) -> P<Option<Val>> {
        let env = self.env;
        let i = self.pos;
        let whole_days = q.unit.months() > 0 || q.base.modulo(Num::int(86_400)).is_ok_and(Num::is_zero);
        let base = if whole_days {
            Val::Date(env.today())
        } else {
            Val::Moment(env.now, ZoneSel::Local)
        };
        let shifted = |p: &mut Self, from: Val, sign: i8| {
            p.score.form = p.score.form.max(85);
            Some(Some(value::add(env, from, Val::Qty(q), sign).unwrap_or_else(Val::Err)))
        };
        if self.is_word(i, "ago") || self.is_word(i, "earlier") {
            self.pos += 1;
            return shifted(self, base, -1);
        }
        if self.is_any(i, &["later", "hence"]) {
            self.pos += 1;
            return shifted(self, base, 1);
        }
        if self.is_any(i, &["from", "after"]) && self.is_any(i + 1, &["now", "today"]) {
            self.pos += 2;
            return shifted(self, base, 1);
        }
        if self.is_any(i, &["from", "after", "before"]) {
            let sign = if self.is_word(i, "before") { -1 } else { 1 };
            let save = self.pos;
            self.pos += 1;
            let target = self.unary();
            match target {
                Some(t @ (Val::Date(_) | Val::Moment(..) | Val::Clock(..))) => return shifted(self, t, sign),
                _ => self.pos = save,
            }
        }
        Some(None)
    }

    // Primaries.

    fn primary(&mut self) -> P<Val> {
        let t = self.cur();
        match t.k {
            K::Num => {
                let n = self.num_at(self.pos)?;
                self.pos += 1;
                self.score.literals = self.score.literals.saturating_add(1);
                if t.flags & lex::BASED != 0 {
                    self.score.based = true;
                }
                if t.flags & lex::SCI != 0 {
                    self.score.sci = true;
                }
                if t.flags & lex::SCALED != 0 {
                    self.score.scaled = true;
                }
                if t.flags & lex::BASED != 0 {
                    return Some(Val::Num(n));
                }
                self.suffix(n, t)
            }
            K::Clock => {
                self.pos += 1;
                let mut secs = t.aux;
                if let Some(pm) = self.ampm() {
                    let h = secs / 3600;
                    if !(1..=12).contains(&h) {
                        return None;
                    }
                    secs = (h % 12) * 3600 + secs % 3600 + if pm { 12 * 3600 } else { 0 };
                }
                if secs >= 24 * 3600 {
                    secs = 0;
                }
                Some(self.clock_zone(secs))
            }
            K::Date => {
                self.pos += 1;
                self.score.form = self.score.form.max(70);
                Some(Val::Date(t.aux))
            }
            K::Sym => self.primary_sym(t),
            K::Word => self.primary_word(),
            K::End => None,
        }
    }

    fn primary_sym(&mut self, t: Tok) -> P<Val> {
        match t.sym {
            '(' => {
                self.pos += 1;
                let v = self.expr(0)?;
                // A missing ")" at the end is fine: people type "sqrt(16".
                if !self.eat_sym(')') && !self.at_end() {
                    return None;
                }
                Some(match v {
                    Val::Num(n) => self.unit_suffix(n).unwrap_or(v),
                    other => other,
                })
            }
            'π' => {
                self.pos += 1;
                self.score.constant = Some(Const::Pi);
                Some(Val::Num(Num::Float(core::f64::consts::PI)))
            }
            '@' => {
                self.pos += 1;
                let n = self.num_at(self.pos)?;
                self.pos += 1;
                self.score.form = self.score.form.max(80);
                Some(timestamp(n))
            }
            c => {
                // Currency symbols before an amount: $20, €5.
                let code = if c == '$' {
                    self.env.ctx.dollar
                } else {
                    currency::by_symbol(c)?
                };
                self.pos += 1;
                let code = Code::parse(code)?;
                self.money_after_symbol(code)
            }
        }
    }

    fn money_after_symbol(&mut self, code: Code) -> P<Val> {
        let t = self.cur();
        if t.k != K::Num {
            return None;
        }
        let mut n = self.num_at(self.pos)?;
        self.pos += 1;
        if let Some(Meaning::Scale(k)) = self.span(self.pos, 1).and_then(|(h, _)| h.find(scale_of)) {
            self.pos += 1;
            n = n.mul(Num::int(10i128.pow(u32::from(k)))).ok()?;
        }
        Some(Val::Money(n, code))
    }

    fn primary_word(&mut self) -> P<Val> {
        let i = self.pos;
        let env = self.env;
        // "US$5", "C$20", "R$ 10".
        if self.is_sym(i + 1, '$')
            && !self.tok(i + 1).space
            && let Some(code) = self.word(i).and_then(currency::by_dollar_prefix)
        {
            self.pos += 2;
            return self.money_after_symbol(Code::parse(code)?);
        }
        if self.eat_word("now") {
            self.score.form = self.score.form.max(45);
            return Some(Val::Moment(env.now, ZoneSel::Local));
        }
        if self.is_word(i, "today") {
            self.pos += 1;
            self.score.form = self.score.form.max(50);
            return Some(Val::Date(env.today()));
        }
        if self.is_any(i, &["tomorrow", "tmrw", "tmr"]) {
            self.pos += 1;
            self.score.form = self.score.form.max(50);
            return Some(Val::Date(env.today() + 1));
        }
        if self.is_word(i, "yesterday") {
            self.pos += 1;
            self.score.form = self.score.form.max(50);
            return Some(Val::Date(env.today() - 1));
        }
        if self.is_any(i, &["noon", "midday"]) {
            self.pos += 1;
            return Some(self.clock_zone(12 * 3600));
        }
        if self.is_word(i, "midnight") {
            self.pos += 1;
            return Some(self.clock_zone(0));
        }
        if self.is_word(i, "what") && self.is_word(i + 1, "time") {
            self.pos += 2;
            if self.is_word(self.pos, "is") && self.is_word(self.pos + 1, "it") {
                self.pos += 2;
            }
            self.score.form = self.score.form.max(85);
            return Some(Val::Moment(env.now, ZoneSel::Local));
        }
        if self.is_any(i, &["time", "current"]) {
            if self.is_word(i, "current") && !self.is_word(i + 1, "time") {
                return None;
            }
            self.pos += if self.is_word(i, "current") { 2 } else { 1 };
            // "time tokyo" without "in".
            if let Some(z) = self.zone_at() {
                self.score.form = self.score.form.max(85);
                return Some(Val::Moment(env.now, z));
            }
            self.score.form = self.score.form.max(40);
            return Some(Val::Moment(env.now, ZoneSel::Local));
        }
        if self.is_any(i, &["next", "last", "this", "coming", "previous", "past"]) {
            return self.relative_day();
        }
        if self.is_word(i, "in") {
            // "in 3 days".
            self.pos += 1;
            let v = self.operand_value()?;
            let Val::Qty(q) = v else { return None };
            if q.dim != TIME {
                return None;
            }
            self.score.form = self.score.form.max(85);
            let whole_days = q.unit.months() > 0 || q.base.modulo(Num::int(86_400)).is_ok_and(Num::is_zero);
            let from = if whole_days {
                Val::Date(env.today())
            } else {
                Val::Moment(env.now, ZoneSel::Local)
            };
            return Some(value::add(env, from, v, 1).unwrap_or_else(Val::Err));
        }
        if self.is_word(i, "half") {
            self.pos += 1;
            return Some(Val::Pct(Num::ratio(1, 2)?));
        }
        if self.is_any(i, &["a", "an"]) {
            // "an hour ago", "a week from today".
            let (hits, len) = self.span(i + 1, 4)?;
            let u = hits.unit()?;
            self.pos += 1 + len;
            return Some(Val::Qty(Qty::new(Num::ONE, u).ok()?));
        }
        if self.is_any(i, &["square", "cube"]) && self.is_word(i + 1, "root") {
            let f = if self.is_word(i, "square") {
                Func::Sqrt
            } else {
                Func::Cbrt
            };
            self.pos += 2;
            self.score.ops = self.score.ops.saturating_add(1);
            return self.call(f);
        }
        let (hits, len) = self.span(i, 4)?;
        // A place followed by "time": "tokyo time".
        if let Some(z) = place_or_zone(&hits)
            && self.is_any(i + len, &["time", "now"])
        {
            self.pos += len + 1;
            self.score.form = self.score.form.max(85);
            return Some(Val::Moment(env.now, z));
        }
        if let Some(f) = hits.find(|m| if let Meaning::Func(f) = m { Some(f) } else { None }) {
            self.pos += len;
            self.score.ops = self.score.ops.saturating_add(1);
            return self.call(f);
        }
        if let Some(c) = hits.find(|m| if let Meaning::Const(c) = m { Some(c) } else { None }) {
            self.pos += len;
            self.score.constant = Some(c);
            let n = constant(c);
            // "pi rad in deg", but not "pi day".
            if self.target_ahead(self.pos).is_some() {
                return Some(self.unit_suffix(n).unwrap_or(Val::Num(n)));
            }
            return Some(Val::Num(n));
        }
        if let Some(m) = hits.find(|m| if let Meaning::Month(m) = m { Some(m) } else { None }) {
            self.pos += len;
            return self.month_date(m, None);
        }
        if let Some(h) = hits.find(|m| if let Meaning::Holiday(h) = m { Some(h) } else { None }) {
            self.pos += len;
            return self.holiday(h);
        }
        if let Some(d) = hits.find(|m| if let Meaning::Weekday(d) = m { Some(d) } else { None }) {
            // A bare weekday is its next occurrence: "days until friday".
            self.pos += len;
            self.score.implied_year = true;
            let today = env.today();
            let ahead = (i32::from(d) - cal::weekday(today)).rem_euclid(7);
            return Some(Val::Date(today + ahead));
        }
        // A unit or currency with no number before a conversion: "km to miles", "usd in eur".
        if self.is_any(i + len, &["in", "to", "as", "into"]) || self.is_sym(i + len, '→') {
            if let Some(u) = hits.unit() {
                self.pos += len;
                self.score.form = self.score.form.max(70);
                return Some(Val::Qty(Qty::new(Num::ONE, u).ok()?));
            }
            if let Some(code) = currency_of(&hits, self.env) {
                self.pos += len;
                self.score.form = self.score.form.max(70);
                return Some(Val::Money(Num::ONE, code));
            }
        }
        None
    }

    /// An operand for "in 3 days" and "3 days after": a number with its unit.
    fn operand_value(&mut self) -> P<Val> {
        let v = self.primary()?;
        Some(v)
    }

    fn relative_day(&mut self) -> P<Val> {
        let env = self.env;
        let which = which_of(self.word(self.pos)?);
        self.pos += 1;
        let today = env.today();
        self.score.form = self.score.form.max(75);
        if let Some((hits, len)) = self.span(self.pos, 1) {
            if let Some(d) = hits.find(|m| if let Meaning::Weekday(d) = m { Some(d) } else { None }) {
                self.pos += len;
                let d = i32::from(d);
                let wd = cal::weekday(today);
                let day = match which {
                    Which::Next => today + (d - wd - 1).rem_euclid(7) + 1,
                    Which::Last => today - (wd - d - 1).rem_euclid(7) - 1,
                    Which::This => today + (d - wd).rem_euclid(7),
                };
                return Some(Val::Date(day));
            }
            if let Some(u) = hits.unit()
                && time_unit(u)
                && u.prefix == 0
                && matches!(u.def().map(|d| d.sym), Some("d" | "wk" | "mo" | "yr"))
            {
                self.pos += len;
                let q = Qty::new(Num::ONE, u).ok()?;
                let sign = match which {
                    Which::Next => 1,
                    Which::Last => -1,
                    Which::This => return Some(Val::Date(today)),
                };
                return Some(value::add(env, Val::Date(today), Val::Qty(q), sign).unwrap_or_else(Val::Err));
            }
        }
        None
    }

    fn holiday(&mut self, h: Holiday) -> P<Val> {
        self.holiday = Some(h);
        let today = self.env.today();
        let year = self.year_after().unwrap_or_else(|| {
            self.score.implied_year = true;
            cal::ymd(today).0
        });
        self.score.form = self.score.form.max(60);
        let day = holiday_date(h, year)?;
        Some(Val::Date(day))
    }

    /// An explicit year after a date: "dec 25 2026", "dec 25, 2026".
    fn year_after(&mut self) -> Option<i32> {
        let save = self.pos;
        self.eat_sym(',');
        let t = self.cur();
        if t.k == K::Num
            && t.flags == 0
            && let Some(y) = self.num_at(self.pos).and_then(Num::as_exact_int)
            && (1000..=9999).contains(&y)
        {
            self.pos += 1;
            return i32::try_from(y).ok();
        }
        self.pos = save;
        None
    }

    /// "dec 25", "december 25th 2026", "dec 2026", or the month alone.
    fn month_date(&mut self, month: u8, day: Option<i32>) -> P<Val> {
        let m = i32::from(month);
        let mut day = day;
        if day.is_none() {
            let t = self.cur();
            if t.k == K::Num
                && t.flags & !lex::ORDINAL == 0
                && let Some(d) = self.num_at(self.pos).and_then(Num::as_exact_int)
                && (1..=31).contains(&d)
            {
                self.pos += 1;
                day = i32::try_from(d).ok();
            }
        }
        let year = self.year_after();
        if year.is_none() {
            self.score.implied_year = true;
        }
        let y = year.unwrap_or_else(|| cal::ymd(self.env.today()).0);
        self.score.form = self.score.form.max(60);
        let d = day.unwrap_or(1);
        match cal::days_from_ymd(y, m, d) {
            Some(days) => Some(Val::Date(days)),
            None => Some(Val::Err(Problem::InvalidDate)),
        }
    }

    /// "am" or "pm" at the cursor: Some(true) for pm.
    fn ampm(&mut self) -> Option<bool> {
        let i = self.pos;
        if self.is_any(i, &["am", "pm"]) {
            self.pos += 1;
            return Some(self.is_word(i, "pm"));
        }
        if self.is_any(i, &["a", "p"]) && self.is_sym(i + 1, '.') && self.is_word(i + 2, "m") {
            self.pos += 3;
            self.eat_sym('.');
            return Some(self.is_word(i, "p"));
        }
        None
    }

    /// A zone or place at the cursor, with "utc+3" offsets.
    fn zone_at(&mut self) -> Option<ZoneSel> {
        let i = self.pos;
        if self.is_any(i, &["local", "here"]) {
            self.pos += 1;
            self.eat_word("time");
            return Some(ZoneSel::Local);
        }
        if self.is_any(i, &["utc", "gmt"])
            && (self.is_sym(i + 1, '+') || self.is_sym(i + 1, '-'))
            && !self.tok(i + 1).space
            && self.tok(i + 2).k == K::Num
        {
            let sign = if self.is_sym(i + 1, '-') { -1 } else { 1 };
            let h = self.num_at(i + 2)?.as_exact_int()?;
            if !(0..=14).contains(&h) {
                return None;
            }
            let mut off = i32::try_from(h).ok()? * 3600;
            self.pos += 3;
            if self.tok(self.pos).k == K::Clock {
                return None;
            }
            if self.eat_sym(':') {
                let m = self.num_at(self.pos)?.as_exact_int()?;
                if !(0..60).contains(&m) {
                    return None;
                }
                self.pos += 1;
                off += i32::try_from(m).ok()? * 60;
            }
            return Some(ZoneSel::Fixed(sign * off, None));
        }
        let t = self.tok(i);
        if t.k == K::Clock && (self.is_sym(i.wrapping_sub(1), '+') || self.is_sym(i.wrapping_sub(1), '-')) {
            return None;
        }
        let (hits, len) = self.span(i, 4)?;
        let z = place_or_zone(&hits)?;
        self.pos += len;
        Some(z)
    }

    /// A wall-clock time, with the zone or place that follows it.
    fn clock_zone(&mut self, secs: i32) -> Val {
        self.score.form = self.score.form.max(40);
        let save = self.pos;
        if self.is_any(self.pos, &["in", "to"]) {
            return Val::Clock(secs, ZoneSel::Local);
        }
        match self.zone_at() {
            Some(z) => {
                self.score.form = self.score.form.max(60);
                Val::Clock(secs, z)
            }
            None => {
                self.pos = save;
                Val::Clock(secs, ZoneSel::Local)
            }
        }
    }

    /// What follows a number: am or pm, a month, a scale word, a unit or a currency.
    fn suffix(&mut self, n: Num, t: Tok) -> P<Val> {
        let i = self.pos;
        // 3pm, 3 p.m.
        if t.flags & (lex::FRACTION | lex::SCI | lex::SCALED | lex::GROUPED) == 0 {
            let save = self.pos;
            if let Some(pm) = self.ampm() {
                let h = n.as_exact_int()?;
                if !(1..=12).contains(&h) {
                    return None;
                }
                let h = i32::try_from(h).ok()?;
                let secs = (h % 12) * 3600 + if pm { 12 * 3600 } else { 0 };
                return Some(self.clock_zone(secs));
            }
            self.pos = save;
        }
        if t.flags & lex::ORDINAL != 0 {
            // "25th december", "25th of december".
            let d = i32::try_from(n.as_exact_int()?).ok()?;
            let of = usize::from(self.is_word(i, "of"));
            let (hits, len) = self.span(i + of, 1)?;
            let m = hits.find(|m| if let Meaning::Month(m) = m { Some(m) } else { None })?;
            self.pos = i + of + len;
            return self.month_date(m, Some(d));
        }
        // "25 dec 2026".
        if let Some((hits, len)) = self.span(i, 1)
            && let Some(m) = hits.find(|m| if let Meaning::Month(m) = m { Some(m) } else { None })
            && hits.unit().is_none()
            && let Some(d) = n.as_exact_int()
            && (1..=31).contains(&d)
        {
            self.pos = i + len;
            return self.month_date(m, i32::try_from(d).ok());
        }
        let mut n = n;
        // "5 million", "2.5 thousand".
        while let Some((hits, len)) = self.span(self.pos, 1) {
            let Some(Meaning::Scale(k)) = hits.find(scale_of) else {
                break;
            };
            n = n.mul(Num::int(10i128.checked_pow(u32::from(k))?)).ok()?;
            self.pos += len;
            self.score.scaled = true;
        }
        Some(self.unit_suffix(n).unwrap_or(Val::Num(n)))
    }

    /// A unit, currency or symbol after a number, then compound parts such as "5 ft 11 in".
    fn unit_suffix(&mut self, n: Num) -> Option<Val> {
        let i = self.pos;
        let t = self.cur();
        // Feet and inches: 5'11".
        if t.k == K::Sym && (t.sym == '\'' || t.sym == '"') {
            let u = units::by_sym(if t.sym == '\'' { "ft" } else { "in" })?;
            self.pos += 1;
            let q = Qty::new(n, u).ok()?;
            return Some(self.compound(q));
        }
        // 20$, 5€.
        if t.k == K::Sym && (t.sym == '$' || currency::by_symbol(t.sym).is_some()) {
            let code = if t.sym == '$' {
                self.env.ctx.dollar
            } else {
                currency::by_symbol(t.sym)?
            };
            self.pos += 1;
            return Some(Val::Money(n, Code::parse(code)?));
        }
        let (hits, len) = self.span(i, 5)?;
        let raw = self.text(t);
        // "in" after a number is inches unless a conversion target follows.
        if raw.eq_ignore_ascii_case("in") && len == 1 {
            if !self.inch_here(i) {
                return None;
            }
            // "5 in cm": the inch, and "in cm" stays for the conversion.
            if self.tok(i + 1).k == K::Word
                && !self.is_any(i + 1, &["in", "to", "as", "into", "and", "plus", "minus", "times"])
            {
                let u = hits.unit()?;
                return Some(Val::Qty(Qty::new(n, u).ok()?));
            }
        }
        if let Some(mut u) = hits.unit() {
            if raw == "m" && len == 1 && self.time_context {
                u = units::by_sym("min")?;
            }
            if u.dim() == TIME {
                self.time_context = true;
            }
            // "50 pounds in euros": pounds sterling when the target is a currency.
            if let Some(code) = currency_of(&hits, self.env)
                && matches!(self.target_ahead(i + len), Some(Meaning::Currency(_) | Meaning::Dollar))
            {
                self.pos += len;
                return Some(Val::Money(n, code));
            }
            // "8 oz in ml": fluid ounces when the target is a volume.
            if u.def().is_some_and(|d| d.sym == "oz")
                && let Some(Meaning::Unit(target)) = self.target_ahead(i + len)
                && target.dim() == units::by_sym("L").map(|l| l.dim()).unwrap_or_default()
            {
                u = units::by_sym("fl oz")?;
            }
            if len == 1 && !t.space && raw.chars().count() == 1 {
                self.score.glued_symbol = true;
            }
            self.pos += len;
            let q = Qty::new(n, u).ok()?;
            return Some(self.compound(q));
        }
        if let Some(code) = currency_of(&hits, self.env) {
            self.pos += len;
            return Some(Val::Money(n, code));
        }
        None
    }

    /// True when "in" at `i` is the inch, not a conversion keyword.
    fn inch_here(&self, i: usize) -> bool {
        let next = self.tok(i + 1);
        match next.k {
            K::End | K::Num | K::Clock | K::Date => true,
            K::Sym => !matches!(next.sym, '%' | '$' | '€' | '£' | '¥' | '°'),
            K::Word => {
                let w = self.text(next);
                if ["in", "to", "as", "into", "and", "plus", "minus", "times"]
                    .iter()
                    .any(|k| w.eq_ignore_ascii_case(k))
                {
                    return true;
                }
                if is_display_word(w) {
                    return false;
                }
                // "5 in cm": inches when a length follows.
                let len_dim = units::by_sym("m").map(|m| m.dim());
                match self.span(i + 1, 4) {
                    Some((hits, _)) => hits.unit().is_some_and(|u| Some(u.dim()) == len_dim),
                    None => false,
                }
            }
        }
    }

    /// The meaning of the conversion target after `from`, if the query has one.
    fn target_ahead(&self, from: usize) -> Option<Meaning> {
        let mut i = from;
        while i < self.lx.len {
            if self.is_any(i, &["in", "to", "as", "into"]) || self.is_sym(i, '→') {
                let (hits, _) = self.span(i + 1, 4)?;
                return hits.iter().next();
            }
            i += 1;
        }
        None
    }

    /// Adds parts that follow a quantity in the same dimension: "5 ft 11 in", "2h 30m".
    fn compound(&mut self, mut q: Qty) -> Val {
        loop {
            let i = self.pos;
            let t = self.tok(i);
            if t.k != K::Num || t.flags & (lex::BASED | lex::SCI | lex::ORDINAL) != 0 {
                break;
            }
            let Some(n) = self.num_at(i) else { break };
            let next = self.tok(i + 1);
            let unit = if next.k == K::Sym
                && next.sym == '"'
                && q.dim == units::by_sym("in").map(|u| u.dim()).unwrap_or_default()
            {
                units::by_sym("in").map(|u| (u, 1))
            } else if next.k == K::Word && self.text(next) == "m" && q.dim == TIME {
                units::by_sym("min").map(|u| (u, 1))
            } else if next.k == K::Word && self.text(next).eq_ignore_ascii_case("in") && !self.inch_here(i + 1) {
                None
            } else {
                self.span(i + 1, 4).and_then(|(h, len)| h.unit().map(|u| (u, len)))
            };
            let Some((u, len)) = unit else { break };
            if u.dim() != q.dim || u.is_temperature() {
                break;
            }
            let Ok(part) = Qty::new(n, u) else { break };
            let Ok(base) = q.base.add(part.base) else { break };
            self.pos = i + 1 + len;
            self.score.compound = true;
            self.score.glued_symbol = false;
            q.base = base;
            q.mixed = Some(u);
        }
        Val::Qty(q)
    }

    // Functions.

    fn call(&mut self, f: Func) -> P<Val> {
        self.eat_word("of");
        let mut args = [Val::Num(Num::ZERO); 16];
        let mut n = 0usize;
        if self.eat_sym('(') {
            if !self.eat_sym(')') {
                loop {
                    let v = self.expr(0)?;
                    *args.get_mut(n)? = v;
                    n += 1;
                    if self.eat_sym(',') || self.eat_sym(';') {
                        continue;
                    }
                    if self.eat_sym(')') || self.at_end() {
                        break;
                    }
                    return None;
                }
            }
        } else {
            let v = self.expr(IMPLICIT_BP)?;
            *args.get_mut(0)? = v;
            n = 1;
        }
        let args = args.get(..n)?;
        Some(self.call_with(f, args))
    }

    fn call_one(&self, f: Func, v: Val) -> Val {
        self.call_with(f, &[v])
    }

    fn call_with(&self, f: Func, args: &[Val]) -> Val {
        self.eval_func(f, args).unwrap_or_else(Val::Err)
    }

    fn eval_func(&self, f: Func, args: &[Val]) -> VResult<Val> {
        let env = self.env;
        let first = *args.first().ok_or(Problem::Unsupported)?;
        let second = args.get(1).copied();
        let one = || {
            if args.len() == 1 {
                Ok(first)
            } else {
                Err(Problem::Unsupported)
            }
        };
        let float = |x: f64| -> VResult<Num> { Ok(Num::float(x)?) };
        Ok(match f {
            Func::Sqrt => match value::ok(one()?)? {
                Val::Qty(q) => {
                    let dim = q.dim.half().ok_or(Problem::IncompatibleUnits)?;
                    let factor = q.unit.factor()?.sqrt()?;
                    let unit = units::with_factor(dim, factor)
                        .or_else(|| units::default_for(dim))
                        .ok_or(Problem::Unsupported)?;
                    Val::Qty(Qty {
                        base: q.base.sqrt()?,
                        dim,
                        unit,
                        mixed: None,
                    })
                }
                v => Val::Num(value::number(v)?.sqrt()?),
            },
            Func::Cbrt => Val::Num(value::number(one()?)?.cbrt()?),
            Func::Abs => value::map_num(one()?, |n| Ok(n.abs()))?,
            Func::Round | Func::Floor | Func::Ceil | Func::Trunc => {
                let places = match second {
                    Some(p) => {
                        let p = value::number(p)?.as_exact_int().ok_or(Problem::NotWhole)?;
                        i32::try_from(p).map_err(|_| Problem::Overflow)?
                    }
                    None => 0,
                };
                if args.len() > 2 {
                    return Err(Problem::Unsupported);
                }
                let mode = match f {
                    Func::Floor => Rounding::Floor,
                    Func::Ceil => Rounding::Ceil,
                    Func::Trunc => Rounding::Trunc,
                    _ => Rounding::HalfAway,
                };
                value::map_num(first, |n| Ok(n.round_with(places, mode)?))?
            }
            Func::Min | Func::Max => {
                let mut best = value::ok(first)?;
                for &a in args.iter().skip(1) {
                    let ord = value::compare(env, a, best)?;
                    let take = if f == Func::Min { ord.is_lt() } else { ord.is_gt() };
                    if take {
                        best = a;
                    }
                }
                best
            }
            Func::Sum | Func::Avg => {
                let mut total = value::ok(first)?;
                for &a in args.iter().skip(1) {
                    total = value::add(env, total, a, 1)?;
                }
                if f == Func::Avg {
                    let count = Num::int(args.len() as i128);
                    total = value::mul(total, Val::Num(count), MulOp::Div)?;
                }
                total
            }
            Func::Log => {
                let x = value::number(first)?;
                if x.is_zero() || x.is_negative() {
                    return Err(Problem::Undefined);
                }
                match second {
                    Some(b) => {
                        let b = value::number(b)?.to_f64();
                        if b <= 0.0 || b == 1.0 {
                            return Err(Problem::Undefined);
                        }
                        Val::Num(exact_log(x, b).map_or_else(|| float(x.to_f64().ln() / b.ln()), Ok)?)
                    }
                    None => Val::Num(exact_log(x, 10.0).map_or_else(|| float(x.to_f64().log10()), Ok)?),
                }
            }
            Func::Log2 | Func::Ln => {
                let x = value::number(one()?)?;
                if x.is_zero() || x.is_negative() {
                    return Err(Problem::Undefined);
                }
                if f == Func::Log2 {
                    Val::Num(exact_log(x, 2.0).map_or_else(|| float(x.to_f64().log2()), Ok)?)
                } else if x.cmp(Num::ONE).is_eq() {
                    Val::Num(Num::ZERO)
                } else {
                    Val::Num(float(x.to_f64().ln())?)
                }
            }
            Func::Exp => {
                let x = value::number(one()?)?;
                if x.is_zero() {
                    Val::Num(Num::ONE)
                } else {
                    Val::Num(float(x.to_f64().exp())?)
                }
            }
            Func::Sin | Func::Cos | Func::Tan | Func::Sind | Func::Cosd | Func::Tand => {
                let degrees_mode = matches!(f, Func::Sind | Func::Cosd | Func::Tand);
                let deg: Num = match value::ok(one()?)? {
                    Val::Qty(q) if q.dim == ANGLE => q.base,
                    Val::Num(n) if degrees_mode || env.ctx.angle == AngleUnit::Degrees => n,
                    Val::Num(n) => {
                        return Ok(Val::Num(trig_radians(f, n.to_f64())?));
                    }
                    _ => return Err(Problem::IncompatibleUnits),
                };
                Val::Num(trig_degrees(f, deg)?)
            }
            Func::Asin | Func::Acos | Func::Atan => {
                let x = value::number(one()?)?.to_f64();
                let r = match f {
                    Func::Asin => x.asin(),
                    Func::Acos => x.acos(),
                    _ => x.atan(),
                };
                if r.is_nan() {
                    return Err(Problem::NotReal);
                }
                if env.ctx.angle == AngleUnit::Degrees {
                    let deg = units::by_sym("°").ok_or(Problem::Unsupported)?;
                    let d = r.to_degrees();
                    let snapped = if (d - d.round()).abs() < 1e-9 {
                        Num::int(d.round() as i128)
                    } else {
                        float(d)?
                    };
                    Val::Qty(Qty::new(snapped, deg)?)
                } else {
                    Val::Num(float(r)?)
                }
            }
            Func::Sinh | Func::Cosh | Func::Tanh => {
                let x = value::number(one()?)?.to_f64();
                Val::Num(float(match f {
                    Func::Sinh => x.sinh(),
                    Func::Cosh => x.cosh(),
                    _ => x.tanh(),
                })?)
            }
            Func::Gcd | Func::Lcm => {
                let mut acc: Option<i128> = None;
                for &a in args {
                    let v = value::number(a)?.as_exact_int().ok_or(Problem::NotWhole)?;
                    acc = Some(match acc {
                        None => v.checked_abs().ok_or(Problem::Overflow)?,
                        Some(x) => {
                            let g = gcd_i(x, v);
                            if f == Func::Gcd {
                                g
                            } else if g == 0 {
                                0
                            } else {
                                (x / g)
                                    .checked_mul(v.checked_abs().ok_or(Problem::Overflow)?)
                                    .ok_or(Problem::Overflow)?
                            }
                        }
                    });
                }
                Val::Num(Num::int(acc.ok_or(Problem::Unsupported)?))
            }
            Func::Fact => Val::Num(value::number(one()?)?.factorial()?),
        })
    }

    // Phrase forms.

    fn forms(&mut self) -> Option<Val> {
        let start = self.pos;
        let attempts: [fn(&mut Self) -> Option<Val>; 7] = [
            Self::form_percent_change,
            Self::form_what_percent,
            Self::form_duration,
            Self::form_weekday,
            Self::form_time_diff,
            Self::form_unix,
            Self::form_range,
        ];
        for f in attempts {
            self.pos = start;
            self.depth = 0;
            self.score = Score::default();
            self.holiday = None;
            self.time_context = false;
            if let Some(v) = f(self) {
                return Some(v);
            }
        }
        self.pos = start;
        None
    }

    /// "% change from 40 to 50", "percentage increase from 40 to 50".
    fn form_percent_change(&mut self) -> Option<Val> {
        let lead = self.eat_sym('%') || self.eat_any(&["percent", "percentage", "pct"]);
        let kind = self.eat_any(&["change", "increase", "decrease", "difference", "diff"]);
        if !lead && !kind {
            return None;
        }
        if !kind && !self.is_any(self.pos, &["from", "between"]) {
            return None;
        }
        self.eat_any(&["from", "between"]);
        let a = self.expr(ADD_BP)?;
        if !self.eat_any(&["to", "and", "vs"]) {
            return None;
        }
        let b = self.expr(ADD_BP)?;
        self.score.form = 90;
        self.score.signed_pct = true;
        let a = value::number(a).ok()?;
        let b = value::number(b).ok()?;
        Some(match b.sub(a).and_then(|d| d.div(a.abs())) {
            Ok(r) => Val::Pct(r),
            Err(e) => Val::Err(e.into()),
        })
    }

    /// "what % of 120 is 30".
    fn form_what_percent(&mut self) -> Option<Val> {
        if !self.eat_word("what") {
            return None;
        }
        if !(self.eat_sym('%') || self.eat_any(&["percent", "percentage"])) {
            return None;
        }
        self.eat_word("of");
        let whole = self.expr(ADD_BP)?;
        if !self.eat_word("is") {
            return None;
        }
        let part = self.expr(ADD_BP)?;
        self.score.form = 90;
        Some(ratio_pct(part, whole))
    }

    /// "days until christmas", "how many weeks since jan 1", "hours between 9am and 5pm".
    fn form_duration(&mut self) -> Option<Val> {
        let env = self.env;
        if self.is_word(self.pos, "how") && self.is_any(self.pos + 1, &["many", "long"]) {
            self.pos += if self.is_word(self.pos + 1, "many") { 2 } else { 1 };
        }
        let (unit, mixed) = if self.eat_any(&["time", "long"]) {
            (None, true)
        } else {
            let (hits, len) = self.span(self.pos, 1)?;
            let u = hits.unit().filter(|u| time_unit(*u))?;
            self.pos += len;
            (Some(u), false)
        };
        self.eat_any(&["left", "remaining"]);
        let (dir, a, b) = if self.eat_any(&["until", "till", "til", "to", "before"]) {
            (1, None, self.date_operand()?)
        } else if self.eat_any(&["since", "after"]) {
            (-1, None, self.date_operand()?)
        } else if self.eat_word("from") {
            let a = self.date_operand()?;
            if self.eat_any(&["to", "until", "till"]) {
                (0, Some(a), self.date_operand()?)
            } else {
                (-1, None, a)
            }
        } else if self.eat_word("between") {
            let a = self.date_operand()?;
            if !self.eat_any(&["and", "to"]) {
                return None;
            }
            (0, Some(a), self.date_operand()?)
        } else {
            return None;
        };
        self.score.form = 90;
        let implied = self.score.implied_year;
        let diff = match a {
            Some(a) => value::add(env, b, a, -1),
            None => {
                let now = match b {
                    Val::Date(_) => Val::Date(env.today()),
                    _ => Val::Moment(env.now, ZoneSel::Local),
                };
                let mut target = b;
                // A date with no year means the next one ("until") or the last one ("since").
                if let Val::Date(d) = b
                    && implied
                {
                    let today = env.today();
                    let shift = if dir > 0 && d < today {
                        1
                    } else if dir < 0 && d > today {
                        -1
                    } else {
                        0
                    };
                    if shift != 0 {
                        // A holiday moves: next Easter is not this Easter plus a year.
                        let moved = match self.holiday {
                            Some(h) => holiday_date(h, cal::ymd(d).0 + shift),
                            None => cal::add_months(d, 12 * i64::from(shift)),
                        };
                        target = Val::Date(moved?);
                    }
                }
                if let Val::Clock(s, z) = b {
                    // The next time the clock shows that time.
                    let t = env.anchor_clock(s, z).ok()?;
                    let t = if dir > 0 && t < env.now {
                        t + 86_400
                    } else if dir < 0 && t > env.now {
                        t - 86_400
                    } else {
                        t
                    };
                    target = Val::Moment(t, z);
                }
                if dir > 0 {
                    value::add(env, target, now, -1)
                } else {
                    value::add(env, now, target, -1)
                }
            }
        };
        let diff = match diff {
            Ok(v) => v,
            Err(e) => return Some(Val::Err(e)),
        };
        let Val::Qty(mut q) = diff else { return Some(diff) };
        match unit {
            Some(u) => {
                q.unit = u;
                q.mixed = None;
            }
            None if mixed && q.mixed.is_none() => q.mixed = units::by_sym("s"),
            None => {}
        }
        Some(Val::Qty(q))
    }

    /// A date, moment or clock for the duration forms.
    fn date_operand(&mut self) -> Option<Val> {
        let v = self.expr(ADD_BP)?;
        match v {
            Val::Date(_) | Val::Moment(..) | Val::Clock(..) | Val::Err(_) => Some(v),
            _ => None,
        }
    }

    /// "weekday of 2026-12-25", "what day is christmas", "day of week dec 25".
    fn form_weekday(&mut self) -> Option<Val> {
        let i = self.pos;
        let lead = if self.is_word(i, "weekday") && self.is_any(i + 1, &["of", "for", "on"]) {
            2
        } else if self.is_word(i, "day") && self.is_word(i + 1, "of") && self.is_word(i + 2, "week") {
            3
        } else if self.is_word(i, "day")
            && self.is_word(i + 1, "of")
            && self.is_word(i + 2, "the")
            && self.is_word(i + 3, "week")
        {
            4
        } else if self.is_any(i, &["what", "which"]) && self.is_word(i + 1, "day") {
            2
        } else {
            0
        };
        if lead > 0 {
            self.pos += lead;
            if self.is_word(self.pos, "of") && self.is_word(self.pos + 1, "the") && self.is_word(self.pos + 2, "week") {
                self.pos += 3;
            }
            self.eat_any(&["of", "for", "on"]);
            if self.eat_word("will") {
                self.eat_word("be");
            } else {
                self.eat_any(&["is", "was"]);
            }
            let v = self.expr(ADD_BP)?;
            self.eat_word("fall");
            self.eat_word("on");
            self.score.form = 90;
            return match v {
                Val::Date(d) => Some(Val::Weekday(d)),
                Val::Err(_) => Some(v),
                _ => None,
            };
        }
        None
    }

    /// "time difference tokyo", "time diff between london and new york".
    fn form_time_diff(&mut self) -> Option<Val> {
        let i = self.pos;
        let lead = if self.is_any(i, &["time", "timezone", "tz"]) && self.is_any(i + 1, &["difference", "diff"]) {
            2
        } else if self.is_word(i, "time") && self.is_word(i + 1, "zone") && self.is_any(i + 2, &["difference", "diff"])
        {
            3
        } else if self.is_word(i, "diff") {
            1
        } else {
            0
        };
        if lead == 0 {
            return None;
        }
        self.pos += lead;
        self.eat_any(&["between", "with", "to", "for", "in"]);
        let a = self.zone_at()?;
        let b = if self.eat_any(&["and", "to", "vs", "from"]) {
            self.zone_at()?
        } else {
            ZoneSel::Local
        };
        self.score.form = 90;
        Some(Val::ZoneDiff(a, b))
    }

    /// "unix 1700000000", "unix time", "epoch now", "@1700000000".
    fn form_unix(&mut self) -> Option<Val> {
        if !self.eat_any(&["unix", "epoch", "timestamp", "posix"]) {
            return None;
        }
        self.eat_any(&["time", "timestamp"]);
        self.score.form = 85;
        if self.at_end() || self.eat_word("now") {
            self.score.unix = true;
            return Some(Val::Num(Num::int(i128::from(self.env.now))));
        }
        let n = self.num_at(self.pos)?;
        self.pos += 1;
        Some(timestamp(n))
    }

    /// "from jan 1 to mar 1", "between 9am and 5pm".
    fn form_range(&mut self) -> Option<Val> {
        let between = if self.eat_word("from") {
            false
        } else if self.eat_word("between") {
            true
        } else {
            return None;
        };
        let a = self.date_operand()?;
        let ok = if between {
            self.eat_any(&["and", "to"])
        } else {
            self.eat_any(&["to", "until", "till"])
        };
        if !ok {
            return None;
        }
        let b = self.date_operand()?;
        self.score.form = 90;
        Some(self.span_between(a, b))
    }

    fn span_between(&self, a: Val, b: Val) -> Val {
        let env = self.env;
        let r = value::add(env, b, a, -1);
        // "10pm to 2am" wraps past midnight.
        match (a, b, r) {
            (Val::Clock(..), Val::Clock(..), Ok(Val::Qty(q))) if q.base.is_negative() => {
                let day = Num::int(86_400);
                match q.base.add(day) {
                    Ok(base) => Val::Qty(Qty { base, ..q }),
                    Err(e) => Val::Err(e.into()),
                }
            }
            (_, _, Ok(v)) => v,
            (_, _, Err(e)) => Val::Err(e),
        }
    }

    /// Phrases after a whole expression: "30 is what % of 120", "8am to 4pm".
    fn post_forms(&mut self, v: Val) -> P<Val> {
        let i = self.pos;
        if self.is_word(i, "is")
            && self.is_word(i + 1, "what")
            && (self.is_sym(i + 2, '%') || self.is_any(i + 2, &["percent", "percentage"]))
            && self.is_word(i + 3, "of")
        {
            self.pos += 4;
            let whole = self.expr(ADD_BP)?;
            self.score.form = 90;
            return Some(ratio_pct(v, whole));
        }
        if self.is_word(i, "is") {
            // "50 is 20% of what".
            self.pos += 1;
            let p = self.expr(MUL_BP + 1)?;
            if let Val::Pct(p) = p
                && self.eat_word("of")
                && self.eat_word("what")
            {
                self.score.form = 90;
                return Some(value::mul(v, Val::Num(p), MulOp::Div).unwrap_or_else(Val::Err));
            }
            return None;
        }
        if self.is_word(i, "as")
            && (self.is_any(i + 1, &["a", "%", "percent", "percentage"]) || self.is_sym(i + 1, '%'))
        {
            let mut j = i + 1;
            if self.is_word(j, "a") {
                j += 1;
            }
            if (self.is_sym(j, '%') || self.is_any(j, &["percent", "percentage"])) && self.is_word(j + 1, "of") {
                self.pos = j + 2;
                let whole = self.expr(ADD_BP)?;
                self.score.form = 90;
                return Some(ratio_pct(v, whole));
            }
        }
        if self.is_word(i, "out") && self.is_word(i + 1, "of") {
            self.pos += 2;
            let whole = self.expr(ADD_BP)?;
            self.score.form = 85;
            return Some(ratio_pct(v, whole));
        }
        if matches!(v, Val::Date(_)) && self.is_any(i, &["weekday"]) {
            self.pos += 1;
            self.score.form = 90;
            if let Val::Date(d) = v {
                return Some(Val::Weekday(d));
            }
        }
        if matches!(v, Val::Date(_) | Val::Moment(..) | Val::Clock(..))
            && self.is_any(i, &["to", "until", "till", "through"])
        {
            let save = self.pos;
            self.pos += 1;
            // A zone after "to" is a conversion, not a range.
            let zone_next = self.span(self.pos, 4).is_some_and(|(h, _)| place_or_zone(&h).is_some())
                || self.is_any(self.pos, &["local", "utc", "gmt", "unix", "epoch", "timestamp"]);
            if !zone_next && let Some(b) = self.date_operand() {
                self.score.form = 90;
                return Some(self.span_between(v, b));
            }
            self.pos = save;
        }
        Some(v)
    }

    // Conversions.

    fn conversions_onto(&mut self, mut v: Val) -> Option<(Val, Option<Display>)> {
        let mut display = None;
        while self.is_any(self.pos, &["in", "to", "as", "into"])
            || self.is_sym(self.pos, '→')
            || self.is_sym(self.pos, '=') && self.tok(self.pos + 1).k != K::End
        {
            let save = self.pos;
            self.pos += 1;
            self.eat_any(&["a", "an"]);
            match self.target(v) {
                Some((nv, d)) => {
                    v = nv;
                    if d.is_some() {
                        display = d;
                    }
                    self.score.conv = true;
                }
                None => {
                    self.pos = save;
                    break;
                }
            }
        }
        Some((v, display))
    }

    /// Reads a conversion target and applies it.
    fn target(&mut self, v: Val) -> Option<(Val, Option<Display>)> {
        let env = self.env;
        let i = self.pos;
        let t = self.cur();
        let display = |p: &mut Self, len: usize, d: Display| {
            p.pos += len;
            Some((v, Some(d)))
        };
        if t.k == K::Sym {
            if t.sym == '%' {
                return display(self, 1, Display::Percent);
            }
            let code = if t.sym == '$' {
                Some(env.ctx.dollar)
            } else {
                currency::by_symbol(t.sym)
            };
            if let Some(code) = code.and_then(Code::parse) {
                self.pos += 1;
                return Some((self.exchange_into(v, code), None));
            }
            if t.sym == '°' {
                // "°F", handled by the unit lookup below.
            } else {
                return None;
            }
        }
        if let Some(w) = self.word(i) {
            let lw = |s: &str| w.eq_ignore_ascii_case(s);
            let base = if lw("hex") || lw("hexadecimal") {
                Some(16)
            } else if lw("binary") || lw("bin") {
                Some(2)
            } else if lw("octal") || (lw("oct") && matches!(v, Val::Num(_))) {
                Some(8)
            } else if lw("decimal") || (lw("dec") && matches!(v, Val::Num(_))) {
                Some(10)
            } else {
                None
            };
            if let Some(b) = base {
                return display(self, 1, Display::Base(b));
            }
            if lw("base") {
                let b = self.num_at(i + 1)?.as_exact_int()?;
                if !(2..=36).contains(&b) {
                    return None;
                }
                return display(self, 2, Display::Base(b as u32));
            }
            if lw("words") || lw("word") || lw("english") || lw("text") {
                return display(self, 1, Display::Words);
            }
            if lw("fraction") || lw("fractions") || lw("frac") {
                return display(self, 1, Display::Fraction(false));
            }
            if lw("mixed") {
                let len = if self.is_any(i + 1, &["fraction", "number"]) {
                    2
                } else {
                    1
                };
                return display(self, len, Display::Fraction(true));
            }
            if lw("scientific") || lw("sci") || lw("exponential") {
                let len = if self.is_word(i + 1, "notation") { 2 } else { 1 };
                return display(self, len, Display::Sci);
            }
            if lw("percent") || lw("percentage") || lw("pct") {
                return display(self, 1, Display::Percent);
            }
            if lw("unix") || lw("epoch") || lw("timestamp") || lw("posix") {
                let len = if self.is_any(i + 1, &["time", "timestamp"]) {
                    2
                } else {
                    1
                };
                let secs = match v {
                    Val::Moment(t, _) => t,
                    Val::Date(d) => env.midnight(d).ok()?,
                    Val::Clock(s, z) => env.anchor_clock(s, z).ok()?,
                    _ => return None,
                };
                self.pos += len;
                self.score.unix = true;
                return Some((Val::Num(Num::int(i128::from(secs))), Some(Display::Unix)));
            }
            if lw("date") || lw("datetime") {
                if let Val::Num(n) = v {
                    self.pos += 1;
                    return Some((timestamp(n), None));
                }
                return None;
            }
            if let Val::Qty(mut q) = v
                && q.dim == TIME
                && (lw("timespan") || lw("duration"))
            {
                q.mixed = units::by_sym("s");
                self.pos += 1;
                return Some((Val::Qty(q), None));
            }
        }
        // Zones for times, units for quantities, currencies for money.
        match v {
            Val::Moment(..) | Val::Clock(..) | Val::Date(_) | Val::Num(_) => {
                if let Some(z) = self.zone_at() {
                    let t = match v {
                        Val::Moment(t, _) => t,
                        Val::Clock(s, from) => match env.anchor_clock(s, from) {
                            Ok(t) => t,
                            Err(e) => return Some((Val::Err(e), None)),
                        },
                        Val::Date(d) => env.midnight(d).ok()?,
                        Val::Num(n) => {
                            let Val::Moment(t, _) = timestamp(n) else { return None };
                            t
                        }
                        _ => return None,
                    };
                    return Some((Val::Moment(t, z), None));
                }
                None
            }
            Val::Qty(q) => {
                let (hits, len) = self.span(i, 5)?;
                let u = hits.unit()?;
                self.pos += len;
                // "ft in", "feet and inches", "h min".
                let mut second = None;
                let save = self.pos;
                let and = usize::from(self.is_word(self.pos, "and"));
                // "in cm" after the first unit is another conversion, not inches.
                let next_conversion = self.is_any(self.pos, &["in", "to"]) && self.tok(self.pos + 1).k == K::Word;
                if !next_conversion
                    && let Some((h2, l2)) = self.span(self.pos + and, 4)
                    && let Some(u2) = h2.unit()
                    && u2.dim() == u.dim()
                    && u2 != u
                {
                    self.pos += and + l2;
                    second = Some(u2);
                } else {
                    self.pos = save;
                }
                let r = value::convert(q, u).map(|mut c| {
                    c.mixed = second;
                    Val::Qty(c)
                });
                Some((r.unwrap_or_else(Val::Err), None))
            }
            Val::Money(..) => {
                let (hits, len) = self.span(i, 5)?;
                let code = currency_of(&hits, env)?;
                self.pos += len;
                Some((self.exchange_into(v, code), None))
            }
            Val::Pct(_) => None,
            Val::Err(_) => {
                // Skip a target the error makes moot, so the query still reads as math.
                let (_, len) = self.span(i, 5)?;
                self.pos += len;
                Some((v, None))
            }
            Val::Weekday(_) | Val::ZoneDiff(..) => None,
        }
    }

    fn exchange_into(&mut self, v: Val, code: Code) -> Val {
        match v {
            Val::Money(n, from) => match value::exchange(self.env, n, from, code) {
                Ok(n) => {
                    self.score.from_currency = Some(from);
                    Val::Money(n, code)
                }
                Err(e) => Val::Err(e),
            },
            Val::Err(_) => v,
            _ => Val::Err(Problem::IncompatibleUnits),
        }
    }
}

#[derive(Clone, Copy)]
enum Which {
    Next,
    Last,
    This,
}

fn which_of(w: &str) -> Which {
    if w.eq_ignore_ascii_case("next") || w.eq_ignore_ascii_case("coming") {
        Which::Next
    } else if w.eq_ignore_ascii_case("this") {
        Which::This
    } else {
        Which::Last
    }
}

fn scale_of(m: Meaning) -> Option<Meaning> {
    if let Meaning::Scale(_) = m { Some(m) } else { None }
}

fn is_display_word(w: &str) -> bool {
    [
        "hex",
        "hexadecimal",
        "binary",
        "bin",
        "octal",
        "decimal",
        "base",
        "words",
        "fraction",
        "scientific",
        "sci",
        "percent",
        "percentage",
        "unix",
        "date",
    ]
    .iter()
    .any(|k| w.eq_ignore_ascii_case(k))
}

fn place_or_zone(hits: &Hits) -> Option<ZoneSel> {
    hits.find(|m| match m {
        Meaning::Place(p) => value::zone_of_place(p),
        Meaning::Zone(z) => value::zone_of_word(z),
        _ => None,
    })
}

fn currency_of(hits: &Hits, env: &Env) -> Option<Code> {
    hits.find(|m| match m {
        Meaning::Currency(i) => CURRENCIES.get(usize::from(i)).and_then(|c| Code::parse(c.code)),
        Meaning::Dollar => Code::parse(env.ctx.dollar),
        _ => None,
    })
}

fn constant(c: Const) -> Num {
    Num::Float(match c {
        Const::Pi => core::f64::consts::PI,
        Const::E => core::f64::consts::E,
        Const::Tau => core::f64::consts::TAU,
        Const::Phi => core::f64::consts::GOLDEN_RATIO,
    })
}

/// A Unix timestamp in seconds, or in milliseconds when it is too large for seconds.
fn timestamp(n: Num) -> Val {
    let Some(v) = n.as_int() else {
        return Val::Err(Problem::NotWhole);
    };
    let secs = if v.abs() >= 100_000_000_000 { v / 1000 } else { v };
    match i64::try_from(secs) {
        Ok(s) if value::day_of(s).is_ok() => Val::Moment(s, ZoneSel::Local),
        _ => Val::Err(Problem::InvalidDate),
    }
}

fn ratio_pct(part: Val, whole: Val) -> Val {
    let r = match (value::ok(part), value::ok(whole)) {
        (Ok(Val::Qty(a)), Ok(Val::Qty(b))) if a.dim == b.dim => a.base.div(b.base).map_err(Problem::from),
        (Ok(a), Ok(b)) => match (value::number(a), value::number(b)) {
            (Ok(x), Ok(y)) => x.div(y).map_err(Problem::from),
            (Err(e), _) | (_, Err(e)) => Err(e),
        },
        (Err(e), _) | (_, Err(e)) => Err(e),
    };
    match r {
        Ok(n) => Val::Pct(n),
        Err(e) => Val::Err(e),
    }
}

fn holiday_date(h: Holiday, y: i32) -> Option<i32> {
    match h {
        Holiday::Christmas => cal::days_from_ymd(y, 12, 25),
        Holiday::ChristmasEve => cal::days_from_ymd(y, 12, 24),
        Holiday::BoxingDay => cal::days_from_ymd(y, 12, 26),
        Holiday::NewYear => cal::days_from_ymd(y, 1, 1),
        Holiday::NewYearsEve => cal::days_from_ymd(y, 12, 31),
        Holiday::Halloween => cal::days_from_ymd(y, 10, 31),
        Holiday::Valentines => cal::days_from_ymd(y, 2, 14),
        Holiday::StPatricks => cal::days_from_ymd(y, 3, 17),
        Holiday::IndependenceDay => cal::days_from_ymd(y, 7, 4),
        Holiday::Easter => cal::easter(y),
        Holiday::Thanksgiving => cal::nth_weekday(y, 11, 3, 4),
    }
}

fn gcd_i(a: i128, b: i128) -> i128 {
    let (mut a, mut b) = (a.unsigned_abs(), b.unsigned_abs());
    while b != 0 {
        let t = a % b;
        a = b;
        b = t;
    }
    i128::try_from(a).unwrap_or(i128::MAX)
}

/// An exact logarithm when `x` is a whole power of `base`: log(1000) is 3.
fn exact_log(x: Num, base: f64) -> Option<Num> {
    let b = base as i128;
    if b as f64 != base || b < 2 {
        return None;
    }
    let (n, d) = match x {
        Num::Ratio(n, d) => (n, d),
        Num::Float(_) => return None,
    };
    let (mut v, inverse) = if d == 1 {
        (n, false)
    } else if n == 1 {
        (d, true)
    } else {
        return None;
    };
    let mut k = 0i128;
    while v > 1 && v % b == 0 {
        v /= b;
        k += 1;
    }
    if v != 1 {
        return None;
    }
    Some(Num::int(if inverse { -k } else { k }))
}

fn trig_degrees(f: Func, deg: Num) -> VResult<Num> {
    // Exact answers on multiples of 90 degrees, where floats leave crumbs.
    if let Num::Ratio(n, 1) = deg.modulo(Num::int(360))? {
        let q = n / 90;
        if n % 90 == 0 {
            let (s, c) = match q {
                0 => (0, 1),
                1 => (1, 0),
                2 => (0, -1),
                _ => (-1, 0),
            };
            return match f {
                Func::Sin | Func::Sind => Ok(Num::int(s)),
                Func::Cos | Func::Cosd => Ok(Num::int(c)),
                _ if c == 0 => Err(Problem::Undefined),
                _ => Ok(Num::int(s / c)),
            };
        }
    }
    trig_radians(f, deg.to_f64().to_radians())
}

fn trig_radians(f: Func, x: f64) -> VResult<Num> {
    let r = match f {
        Func::Sin | Func::Sind => x.sin(),
        Func::Cos | Func::Cosd => x.cos(),
        _ => x.tan(),
    };
    // sin(pi) is 1.2e-16 in floats; show 0.
    let r = if r.abs() < 1e-14 * x.abs().max(1.0) { 0.0 } else { r };
    Ok(Num::float(r)?)
}
