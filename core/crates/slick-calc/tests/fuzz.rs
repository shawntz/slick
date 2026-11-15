//! Fuzzing without a fuzzer: random bytes, random token sequences and hostile shapes. Every
//! query must return without a panic, and every answer must be well formed.

mod support;

use slick_calc::{AngleUnit, Answer, Context, HourCycle, Kind, MAX_QUERY_LEN, evaluate};
use support::Options;

/// xorshift64*: deterministic, so a failure reproduces.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_f491_4f6c_dd1d)
    }

    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
}

fn contexts() -> Vec<Context<'static>> {
    let comma = Options {
        decimal: ',',
        grouping: Some('.'),
        ..Options::default()
    };
    let bare = Options {
        rates: false,
        zones: false,
        angle: AngleUnit::Degrees,
        hours: HourCycle::H24,
        ..Options::default()
    };
    let mut v = vec![
        support::context(Options::default()),
        support::context(comma),
        support::context(bare),
    ];
    // Extreme clocks: the epoch, far past, far future.
    for now in [0, -62_000_000_000_000, 250_000_000_000_000, i64::MAX, i64::MIN] {
        let mut c = support::context(Options::default());
        c.now_ms = now;
        v.push(c);
    }
    v
}

fn check(q: &str, ctx: &Context, a: &mut Answer) -> bool {
    let got = evaluate(q, ctx, a);
    if got {
        assert_ne!(a.kind, Kind::None, "{q:?}");
        assert!(!a.main.is_empty(), "{q:?} gave an empty answer");
        assert!((1..=100).contains(&a.confidence), "{q:?} confidence {}", a.confidence);
    } else {
        assert_eq!(a.kind, Kind::None, "{q:?}");
        assert!(a.main.is_empty() && a.alternates().is_empty(), "{q:?} left text behind");
    }
    got
}

#[test]
fn random_bytes() {
    let ctxs = contexts();
    let mut rng = Rng(0x9e37_79b9_7f4a_7c15);
    let mut a = Answer::new();
    let extras = [
        "π", "€", "°", "²", "×", "√", "−", "é", "ß", "東", "😀", "\u{0}", "\u{feff}", "\u{202f}",
    ];
    for i in 0..60_000 {
        let len = rng.below(40);
        let mut s = String::new();
        for _ in 0..len {
            if rng.below(8) == 0 {
                s.push_str(extras[rng.below(extras.len())]);
            } else {
                s.push(char::from(32 + rng.below(95) as u8));
            }
        }
        let _ = check(&s, &ctxs[i % ctxs.len()], &mut a);
        // Raw bytes, lossily decoded, too.
        let bytes: Vec<u8> = (0..rng.below(24)).map(|_| rng.next() as u8).collect();
        let _ = check(&String::from_utf8_lossy(&bytes), &ctxs[i % ctxs.len()], &mut a);
    }
}

#[test]
fn random_token_sequences() {
    const VOCAB: &[&str] = &[
        "1",
        "2",
        "0",
        "12",
        "3.5",
        "1e9",
        "1e-9",
        "0xff",
        "0b101",
        "1,000",
        "5k",
        "25th",
        "999999999999999999999",
        "+",
        "-",
        "*",
        "/",
        "^",
        "(",
        ")",
        "%",
        "!",
        "²",
        ",",
        ";",
        "=",
        "$",
        "€",
        "'",
        "\"",
        "°",
        "√",
        "@",
        ":",
        "km",
        "m",
        "in",
        "ft",
        "kg",
        "lb",
        "C",
        "F",
        "K",
        "h",
        "min",
        "s",
        "d",
        "days",
        "weeks",
        "months",
        "years",
        "GB",
        "MiB",
        "mpg",
        "l/100km",
        "cups",
        "oz",
        "pounds",
        "usd",
        "eur",
        "yen",
        "btc",
        "dollars",
        "to",
        "as",
        "into",
        "of",
        "off",
        "on",
        "is",
        "what",
        "and",
        "from",
        "until",
        "since",
        "between",
        "ago",
        "a",
        "pi",
        "e",
        "sqrt",
        "sin",
        "log",
        "max",
        "round",
        "sum",
        "hex",
        "binary",
        "words",
        "fraction",
        "base",
        "time",
        "now",
        "today",
        "tomorrow",
        "next",
        "last",
        "friday",
        "dec",
        "25",
        "christmas",
        "easter",
        "tokyo",
        "new",
        "york",
        "london",
        "pst",
        "utc",
        "utc+3",
        "3pm",
        "15:00",
        "noon",
        "2026-12-25",
        "unix",
        "1700000000",
        "weekday",
        "day",
        "of",
        "week",
        "change",
        "percent",
        "diff",
        "difference",
    ];
    const NUMS: &[&str] = &[
        "1", "2", "0", "7", "12", "3.5", "0.1", "1e9", "1e-9", "0xff", "5k", "-3", "(2+3)", "pi", "1,000",
    ];
    const UNITS: &[&str] = &[
        "", "", "", "km", "m", "ft", "in", "kg", "lb", "C", "F", "h", "min", "days", "GB", "cups", "usd", "eur", "%",
        "mph", "°",
    ];
    const OPS: &[&str] = &["+", "-", "*", "/", "^", "mod", "of", "x", "plus", "times"];
    const TARGETS: &[&str] = &[
        "",
        "",
        " in miles",
        " in m",
        " to cm",
        " in kg",
        " in F",
        " in hours",
        " in eur",
        " in hex",
        " in words",
        " in %",
        " in tokyo",
        " in unix",
        " to MB",
    ];
    let ctxs = contexts();
    let mut rng = Rng(0x0123_4567_89ab_cdef);
    let mut a = Answer::new();
    let (mut accepted, mut errors) = (0usize, 0usize);
    let total = 300_000;
    for i in 0..total {
        let mut s = String::new();
        if i % 2 == 0 {
            // Token soup.
            let n = 1 + rng.below(9);
            for k in 0..n {
                if k > 0 && rng.below(3) != 0 {
                    s.push(' ');
                }
                s.push_str(VOCAB[rng.below(VOCAB.len())]);
            }
        } else {
            // Operand, operator, operand, ... and maybe a conversion.
            let terms = 1 + rng.below(4);
            for k in 0..terms {
                if k > 0 {
                    s.push(' ');
                    s.push_str(OPS[rng.below(OPS.len())]);
                    s.push(' ');
                }
                s.push_str(NUMS[rng.below(NUMS.len())]);
                let u = UNITS[rng.below(UNITS.len())];
                if !u.is_empty() {
                    if rng.below(2) == 0 {
                        s.push(' ');
                    }
                    s.push_str(u);
                }
            }
            s.push_str(TARGETS[rng.below(TARGETS.len())]);
        }
        if check(&s, &ctxs[i % ctxs.len()], &mut a) {
            accepted += 1;
            errors += usize::from(a.kind == Kind::Error);
        }
    }
    println!("token fuzz: {total} queries, {accepted} answered, {errors} of them errors");
    // The generator must reach the evaluator, not only the first gate.
    assert!(accepted * 5 > total, "only {accepted} of {total} answered");
}

#[test]
fn hostile_shapes() {
    let ctxs = contexts();
    let mut a = Answer::new();
    let long_digits = "9".repeat(MAX_QUERY_LEN);
    let cases = [
        "(".repeat(200),
        ")".repeat(200),
        format!("{}1{}", "(".repeat(100), ")".repeat(100)),
        format!("{}1", "-".repeat(100)),
        format!("{}2", "√".repeat(60)),
        format!("{}16{}", "sqrt(".repeat(30), ")".repeat(30)),
        "1+".repeat(200),
        "2^".repeat(40) + "2",
        "10^10^10^10".to_owned(),
        "9^9^9".to_owned(),
        "999999999!".to_owned(),
        "170!".to_owned(),
        "1e999999".to_owned(),
        "1e-999999".to_owned(),
        "0x".to_owned() + &"f".repeat(60),
        "0b".to_owned() + &"1".repeat(200),
        long_digits.clone(),
        long_digits.clone() + "0",
        format!("{long_digits} in hex"),
        "99999999999999999999999999999999999999999 * 99999999999999999999999999999999999999999".to_owned(),
        "1/3^200".to_owned(),
        "0.000000000000000000000000000000000000001 / 7".to_owned(),
        "in in in in in in in in in in in in in in in in in in in in 3 days".to_owned(),
        "a a a a a a a a a a a a a a".to_owned(),
        "utc+3:99999999".to_owned(),
        "utc+99".to_owned(),
        "unix 99999999999999999999".to_owned(),
        "1e300 days ago".to_owned(),
        "99999999 years from now".to_owned(),
        "today + 9999999999 months".to_owned(),
        "dec 99999999".to_owned(),
        "25:99".to_owned(),
        "99:00 utc in tokyo".to_owned(),
        "max()".to_owned(),
        "round(1, 99999)".to_owned(),
        "log(8, 1)".to_owned(),
        "1 mod 0".to_owned(),
        "0^-1".to_owned(),
        "(-8)^(1/3)".to_owned(),
        "1e308 km in mm".to_owned(),
        "1e-308 km in ly".to_owned(),
        "5 km^100".to_owned(),
        "(5 km)^-128".to_owned(),
        "1 yocto".to_owned(),
        "%%%%".to_owned(),
        "$$$$1".to_owned(),
        "🙂 + 1".to_owned(),
    ];
    for c in &ctxs {
        for q in &cases {
            let _ = check(q, c, &mut a);
        }
    }
}
