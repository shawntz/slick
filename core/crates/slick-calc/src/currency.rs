//! Currencies: ISO 4217 codes, names, symbols, and the rate table the caller supplies.

/// A currency code of 2 to 6 ASCII letters, stored uppercase.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct Code {
    bytes: [u8; 6],
    len: u8,
}

impl Code {
    pub(crate) fn parse(s: &str) -> Option<Code> {
        let b = s.as_bytes();
        if !(2..=6).contains(&b.len()) || !b.iter().all(u8::is_ascii_alphabetic) {
            return None;
        }
        let mut bytes = [0u8; 6];
        for (slot, c) in bytes.iter_mut().zip(b) {
            *slot = c.to_ascii_uppercase();
        }
        Some(Code {
            bytes,
            len: b.len() as u8,
        })
    }

    pub(crate) fn as_str(&self) -> &str {
        core::str::from_utf8(self.bytes.get(..usize::from(self.len)).unwrap_or(&[])).unwrap_or("")
    }
}

pub(crate) struct CurDef {
    pub code: &'static str,
    /// Digits after the decimal point in normal use.
    pub digits: u8,
    /// Names and abbreviations, matched ignoring case. Multi-word names are allowed.
    pub names: &'static [&'static str],
    /// True when the code is also an English word or a unit, so it only counts in capitals.
    pub code_needs_caps: bool,
}

macro_rules! cur {
    ($code:expr, $digits:expr, [$($name:expr),*]) => {
        CurDef { code: $code, digits: $digits, names: &[$($name),*], code_needs_caps: false }
    };
    ($code:expr, $digits:expr, [$($name:expr),*], caps) => {
        CurDef { code: $code, digits: $digits, names: &[$($name),*], code_needs_caps: true }
    };
}

pub(crate) static CURRENCIES: &[CurDef] = &[
    cur!(
        "USD",
        2,
        ["us dollar", "us dollars", "american dollar", "american dollars", "usd$"]
    ),
    cur!("EUR", 2, ["euro", "euros"]),
    cur!(
        "GBP",
        2,
        [
            "british pound",
            "british pounds",
            "pound sterling",
            "pounds sterling",
            "sterling",
            "quid"
        ]
    ),
    cur!("JPY", 0, ["yen", "japanese yen"]),
    cur!("CNY", 2, ["yuan", "renminbi", "rmb", "chinese yuan"]),
    cur!("INR", 2, ["rupee", "rupees", "indian rupee", "indian rupees", "rs"]),
    cur!("KRW", 0, ["won", "korean won", "south korean won"]),
    cur!(
        "RUB",
        2,
        [
            "ruble",
            "rubles",
            "rouble",
            "roubles",
            "russian ruble",
            "russian rubles"
        ]
    ),
    cur!("CHF", 2, ["franc", "francs", "swiss franc", "swiss francs"]),
    cur!("CAD", 2, ["canadian dollar", "canadian dollars"]),
    cur!(
        "AUD",
        2,
        [
            "australian dollar",
            "australian dollars",
            "aussie dollar",
            "aussie dollars"
        ]
    ),
    cur!("NZD", 2, ["new zealand dollar", "new zealand dollars", "kiwi dollar"]),
    cur!("HKD", 2, ["hong kong dollar", "hong kong dollars"]),
    cur!("SGD", 2, ["singapore dollar", "singapore dollars"]),
    cur!(
        "TWD",
        2,
        [
            "taiwan dollar",
            "taiwan dollars",
            "new taiwan dollar",
            "new taiwan dollars"
        ]
    ),
    cur!("MXN", 2, ["peso", "pesos", "mexican peso", "mexican pesos"]),
    cur!("BRL", 2, ["real", "reais", "brazilian real", "brazilian reais"]),
    cur!("ARS", 2, ["argentine peso", "argentine pesos"]),
    cur!("CLP", 0, ["chilean peso", "chilean pesos"]),
    cur!("COP", 2, ["colombian peso", "colombian pesos"]),
    cur!("PEN", 2, ["sol", "soles", "peruvian sol"], caps),
    cur!("ZAR", 2, ["rand", "south african rand"]),
    cur!("SEK", 2, ["krona", "kronor", "swedish krona", "swedish kronor"]),
    cur!("NOK", 2, ["krone", "kroner", "norwegian krone", "norwegian kroner"]),
    cur!("DKK", 2, ["danish krone", "danish kroner"]),
    cur!("ISK", 0, ["icelandic krona", "icelandic kronur"]),
    cur!("PLN", 2, ["zloty", "zlotys", "zlotych", "zł", "polish zloty"]),
    cur!("CZK", 2, ["koruna", "czech koruna", "kč"]),
    cur!("HUF", 2, ["forint", "forints", "hungarian forint"]),
    cur!("RON", 2, ["leu", "lei", "romanian leu"]),
    cur!("BGN", 2, ["lev", "bulgarian lev"]),
    cur!("TRY", 2, ["lira", "turkish lira", "lire"], caps),
    cur!(
        "ILS",
        2,
        ["shekel", "shekels", "sheqel", "new shekel", "new shekels", "nis"]
    ),
    cur!("THB", 2, ["baht", "thai baht"]),
    cur!("MYR", 2, ["ringgit", "malaysian ringgit", "rm"]),
    cur!("IDR", 2, ["rupiah", "indonesian rupiah", "rp"]),
    cur!("PHP", 2, ["philippine peso", "philippine pesos", "piso"], caps),
    cur!("VND", 0, ["dong", "vietnamese dong"]),
    cur!("AED", 2, ["dirham", "dirhams", "uae dirham"]),
    cur!("SAR", 2, ["riyal", "riyals", "saudi riyal"]),
    cur!("QAR", 2, ["qatari riyal"]),
    cur!("KWD", 3, ["kuwaiti dinar"]),
    cur!("BHD", 3, ["bahraini dinar"]),
    cur!("OMR", 3, ["omani rial"]),
    cur!("JOD", 3, ["jordanian dinar"]),
    cur!("EGP", 2, ["egyptian pound", "egyptian pounds"]),
    cur!("NGN", 2, ["naira", "nigerian naira"]),
    cur!("KES", 2, ["kenyan shilling", "kenyan shillings"]),
    cur!("GHS", 2, ["cedi", "cedis", "ghanaian cedi"]),
    cur!("MAD", 2, ["moroccan dirham"], caps),
    cur!("TND", 3, ["tunisian dinar"]),
    cur!("DZD", 2, ["algerian dinar"]),
    cur!("ETB", 2, ["birr", "ethiopian birr"]),
    cur!("TZS", 2, ["tanzanian shilling"]),
    cur!("UGX", 0, ["ugandan shilling"]),
    cur!("XOF", 0, ["cfa franc", "west african cfa franc"]),
    cur!("XAF", 0, ["central african cfa franc"]),
    cur!("PKR", 2, ["pakistani rupee", "pakistani rupees"]),
    cur!("BDT", 2, ["taka", "bangladeshi taka"]),
    cur!("LKR", 2, ["sri lankan rupee", "sri lankan rupees"]),
    cur!("NPR", 2, ["nepalese rupee", "nepalese rupees"]),
    cur!("UAH", 2, ["hryvnia", "hryvnias", "ukrainian hryvnia"]),
    cur!("KZT", 2, ["tenge", "kazakhstani tenge"]),
    cur!("GEL", 2, ["lari", "georgian lari"], caps),
    cur!("AMD", 2, ["dram", "armenian dram"], caps),
    cur!("AZN", 2, ["manat", "azerbaijani manat"]),
    cur!("RSD", 2, ["serbian dinar"]),
    cur!("BAM", 2, ["convertible mark"], caps),
    cur!("MKD", 2, ["denar", "macedonian denar"]),
    cur!("ALL", 2, ["lek", "albanian lek"], caps),
    cur!("MDL", 2, ["moldovan leu"]),
    cur!("BYN", 2, ["belarusian ruble"]),
    cur!("IRR", 2, ["iranian rial"]),
    cur!("IQD", 3, ["iraqi dinar"]),
    cur!("LBP", 2, ["lebanese pound"]),
    cur!("JMD", 2, ["jamaican dollar", "jamaican dollars"]),
    cur!("TTD", 2, ["trinidad and tobago dollar"]),
    cur!("DOP", 2, ["dominican peso"]),
    cur!("CRC", 2, ["colon", "colones", "costa rican colon"]),
    cur!("GTQ", 2, ["quetzal", "quetzales"]),
    cur!("UYU", 2, ["uruguayan peso"]),
    cur!("PYG", 0, ["guarani", "guaranies"]),
    cur!("BOB", 2, ["boliviano", "bolivianos"], caps),
    cur!("VES", 2, ["bolivar", "bolivares"]),
    cur!("MNT", 2, ["tugrik", "togrog"]),
    cur!("KHR", 2, ["riel", "cambodian riel"]),
    cur!("LAK", 2, ["kip", "lao kip"]),
    cur!("MMK", 2, ["kyat", "myanmar kyat"]),
    cur!("BND", 2, ["brunei dollar"]),
    cur!("FJD", 2, ["fijian dollar"]),
    cur!("XPF", 0, ["cfp franc"]),
    cur!("MUR", 2, ["mauritian rupee"]),
    cur!("MOP", 2, ["pataca", "macanese pataca"], caps),
    cur!("TOP", 2, ["paanga", "pa'anga"], caps),
    cur!("CUP", 2, ["cuban peso"], caps),
    cur!("BTC", 8, ["bitcoin", "bitcoins", "xbt"]),
    cur!("ETH", 8, ["ether", "ethereum"]),
];

pub(crate) fn def(code: Code) -> Option<&'static CurDef> {
    CURRENCIES.iter().find(|c| c.code == code.as_str())
}

/// Digits after the decimal point for amounts in this currency.
pub(crate) fn digits(code: Code) -> u8 {
    def(code).map_or(2, |d| d.digits)
}

/// The currency a symbol stands for. `$` is the caller's dollar.
pub(crate) fn by_symbol(c: char) -> Option<&'static str> {
    Some(match c {
        '€' => "EUR",
        '£' => "GBP",
        '¥' => "JPY",
        '₹' => "INR",
        '₩' => "KRW",
        '₽' => "RUB",
        '₺' => "TRY",
        '₪' => "ILS",
        '₫' => "VND",
        '₱' => "PHP",
        '฿' => "THB",
        '₴' => "UAH",
        '₦' => "NGN",
        '₿' => "BTC",
        '元' => "CNY",
        _ => return None,
    })
}

/// The currency of a "<prefix>$" symbol such as "C$" or "R$".
pub(crate) fn by_dollar_prefix(prefix: &str) -> Option<&'static str> {
    const TABLE: &[(&str, &str)] = &[
        ("us", "USD"),
        ("c", "CAD"),
        ("ca", "CAD"),
        ("can", "CAD"),
        ("a", "AUD"),
        ("au", "AUD"),
        ("nz", "NZD"),
        ("hk", "HKD"),
        ("s", "SGD"),
        ("sg", "SGD"),
        ("r", "BRL"),
        ("mx", "MXN"),
        ("nt", "TWD"),
    ];
    TABLE
        .iter()
        .find(|(p, _)| p.eq_ignore_ascii_case(prefix))
        .map(|(_, c)| *c)
}

/// Exchange rates against one base currency, with the time they were fetched.
///
/// The caller builds this off the main thread whenever it refreshes rates. The engine never
/// fetches rates and never guesses one that is missing.
#[derive(Clone, Debug)]
pub struct Rates {
    base: Code,
    timestamp_ms: i64,
    /// Sorted by code: units of the currency per one unit of the base.
    entries: Vec<(Code, f64)>,
}

impl Rates {
    /// An empty table. None when `base` is not a currency code.
    pub fn new(base: &str, timestamp_ms: i64) -> Option<Rates> {
        let base = Code::parse(base)?;
        Some(Rates {
            base,
            timestamp_ms,
            entries: vec![(base, 1.0)],
        })
    }

    /// Sets how many units of `code` one unit of the base buys. False for a bad code or rate.
    pub fn insert(&mut self, code: &str, per_base: f64) -> bool {
        let Some(code) = Code::parse(code) else { return false };
        if !per_base.is_finite() || per_base <= 0.0 {
            return false;
        }
        match self.entries.binary_search_by(|e| e.0.cmp(&code)) {
            Ok(i) => {
                if let Some(e) = self.entries.get_mut(i) {
                    e.1 = per_base;
                }
            }
            Err(i) => self.entries.insert(i, (code, per_base)),
        }
        true
    }

    /// When the rates were fetched, in milliseconds since the Unix epoch.
    pub fn timestamp_ms(&self) -> i64 {
        self.timestamp_ms
    }

    pub fn base(&self) -> &str {
        self.base.as_str()
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub(crate) fn rate(&self, code: Code) -> Option<f64> {
        let i = self.entries.binary_search_by(|e| e.0.cmp(&code)).ok()?;
        self.entries.get(i).map(|e| e.1)
    }

    /// The factor that turns an amount in `from` into `to`.
    pub(crate) fn factor(&self, from: Code, to: Code) -> Option<f64> {
        if from == to {
            return Some(1.0);
        }
        Some(self.rate(to)? / self.rate(from)?)
    }
}
