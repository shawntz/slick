//! The expectation suite. Every line of `cases.txt` is a query and the answer it must give.
//!
//! Run with `CALC_DUMP=1` to print what every query gives instead of checking it, and with
//! `CALC_CASES=<file>` to run another case file in the same format.

mod support;

use slick_calc::{AngleUnit, Answer, CLAIMS_TOP, DateOrder, HourCycle, Kind, evaluate};
use support::Options;

static CASES: &str = include_str!("cases.txt");

enum Expect {
    NotMath,
    Error(String),
    Main(String),
}

struct Case {
    line: usize,
    query: String,
    expect: Expect,
    tags: Vec<String>,
}

fn kind_name(k: Kind) -> &'static str {
    match k {
        Kind::None => "None",
        Kind::Number => "Number",
        Kind::Percent => "Percent",
        Kind::Quantity => "Quantity",
        Kind::Duration => "Duration",
        Kind::Currency => "Currency",
        Kind::Date => "Date",
        Kind::Time => "Time",
        Kind::Text => "Text",
        Kind::Error => "Error",
    }
}

fn apply_directive(o: &mut Options, d: &str) {
    let mut parts = d.split_whitespace();
    let key = parts.next().unwrap_or("");
    let value = parts.next().unwrap_or("");
    match key {
        "reset" => *o = Options::default(),
        "decimal" => o.decimal = value.chars().next().unwrap_or('.'),
        "grouping" => {
            o.grouping = match value {
                "none" => None,
                "space" => Some(' '),
                v => v.chars().next(),
            }
        }
        "rates" => o.rates = value == "on",
        "zones" => o.zones = value == "on",
        "angle" => {
            o.angle = if value == "degrees" {
                AngleUnit::Degrees
            } else {
                AngleUnit::Radians
            }
        }
        "hours" => o.hours = if value == "24" { HourCycle::H24 } else { HourCycle::H12 },
        "order" => {
            o.order = match value {
                "mdy" => DateOrder::MonthDayYear,
                "ymd" => DateOrder::YearMonthDay,
                _ => DateOrder::DayMonthYear,
            }
        }
        other => panic!("unknown directive {other}"),
    }
}

fn parse_case(line: usize, text: &str) -> Case {
    let (query, rest) = text.split_once("=>").unwrap_or_else(|| panic!("line {line}: no =>"));
    let mut rest = rest.trim().to_owned();
    let mut tags = Vec::new();
    while rest.ends_with(']') {
        let Some(open) = rest.rfind(" [") else { break };
        tags.push(rest[open + 2..rest.len() - 1].to_owned());
        rest.truncate(open);
        rest = rest.trim_end().to_owned();
    }
    let expect = if rest == "!" {
        Expect::NotMath
    } else if let Some(e) = rest.strip_prefix("error:") {
        Expect::Error(e.trim().to_owned())
    } else {
        Expect::Main(rest)
    };
    Case {
        line,
        query: query.trim().to_owned(),
        expect,
        tags,
    }
}

fn check(case: &Case, a: &Answer, got: bool) -> Option<String> {
    let actual = || {
        if !got {
            "!".to_owned()
        } else if a.kind == Kind::Error {
            format!("error: {}", a.main)
        } else {
            a.main.clone()
        }
    };
    let ok = match &case.expect {
        Expect::NotMath => !got,
        Expect::Error(e) => got && a.kind == Kind::Error && &a.main == e,
        Expect::Main(m) => got && a.kind != Kind::Error && &a.main == m,
    };
    if !ok {
        return Some(format!("got {:?}", actual()));
    }
    for tag in &case.tags {
        let pass = if tag == "top" {
            a.confidence >= CLAIMS_TOP
        } else if tag == "low" {
            a.confidence < CLAIMS_TOP
        } else if let Some(k) = tag.strip_prefix("kind=") {
            kind_name(a.kind) == k
        } else if let Some(c) = tag.strip_prefix("copy=") {
            a.copy == c
        } else if let Some(t) = tag.strip_prefix("alt=") {
            a.alternates().iter().any(|x| x.text == t)
        } else if let Some(t) = tag.strip_prefix("note=") {
            a.note.contains(t)
        } else {
            panic!("line {}: unknown tag {tag}", case.line)
        };
        if !pass {
            let alts: Vec<&str> = a.alternates().iter().map(|x| x.text.as_str()).collect();
            return Some(format!(
                "tag [{tag}] failed: kind {} confidence {} copy {:?} note {:?} alternates {:?}",
                kind_name(a.kind),
                a.confidence,
                a.copy,
                a.note,
                alts
            ));
        }
    }
    None
}

#[test]
fn expectations() {
    let dump = std::env::var_os("CALC_DUMP").is_some();
    let mut options = Options::default();
    let mut answer = Answer::new();
    let mut failures = Vec::new();
    let mut count = 0;
    let extra = std::env::var_os("CALC_CASES").map(|p| std::fs::read_to_string(p).expect("CALC_CASES is readable"));
    let text = extra.as_deref().unwrap_or(CASES);
    for (i, raw) in text.lines().enumerate() {
        let line = i + 1;
        let text = raw.trim();
        if text.is_empty() || text.starts_with('#') {
            continue;
        }
        if let Some(d) = text.strip_prefix("::") {
            apply_directive(&mut options, d);
            continue;
        }
        let case = parse_case(line, text);
        let ctx = support::context(options);
        let got = evaluate(&case.query, &ctx, &mut answer);
        count += 1;
        if dump {
            let shown = if !got {
                "!".to_owned()
            } else if answer.kind == Kind::Error {
                format!("error: {}", answer.main)
            } else {
                answer.main.clone()
            };
            let alts: Vec<String> = answer
                .alternates()
                .iter()
                .map(|a| format!("{}: {}", a.label, a.text))
                .collect();
            println!(
                "{:<40} => {:<36} | {} {} copy={:?} note={:?} {:?}",
                case.query,
                shown,
                kind_name(answer.kind),
                answer.confidence,
                answer.copy,
                answer.note,
                alts
            );
            continue;
        }
        if let Some(why) = check(&case, &answer, got) {
            failures.push(format!("line {line}: {:?}: {why}", case.query));
        }
    }
    assert!(
        extra.is_some() || count >= 400,
        "the suite needs at least 400 cases, has {count}"
    );
    assert!(
        failures.is_empty(),
        "{} of {count} cases failed:\n{}",
        failures.len(),
        failures.join("\n")
    );
}
