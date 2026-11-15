//! Units: dimensions, conversion factors, names and SI prefixes.
//!
//! A quantity is stored as its value in the SI base unit of its dimension, as an exact number
//! when the factors allow it. Every factor in the table is exact except the ones that involve
//! pi: the radian and the parsec.

use crate::num::{Num, NumError, NumResult};

/// Exponents of length, mass, time, temperature, information and angle.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub(crate) struct Dim(pub [i8; 6]);

impl Dim {
    pub(crate) const NONE: Dim = Dim([0; 6]);

    pub(crate) fn add(self, o: Dim) -> Option<Dim> {
        let mut r = [0i8; 6];
        for (k, slot) in r.iter_mut().enumerate() {
            *slot = self.0.get(k)?.checked_add(*o.0.get(k)?)?;
        }
        Some(Dim(r))
    }

    pub(crate) fn sub(self, o: Dim) -> Option<Dim> {
        self.add(o.neg()?)
    }

    pub(crate) fn neg(self) -> Option<Dim> {
        let mut r = [0i8; 6];
        for (k, slot) in r.iter_mut().enumerate() {
            *slot = self.0.get(k)?.checked_neg()?;
        }
        Some(Dim(r))
    }

    pub(crate) fn scale(self, n: i8) -> Option<Dim> {
        let mut r = [0i8; 6];
        for (k, slot) in r.iter_mut().enumerate() {
            *slot = self.0.get(k)?.checked_mul(n)?;
        }
        Some(Dim(r))
    }

    /// Half of every exponent, when all are even: the dimension of a square root.
    pub(crate) fn half(self) -> Option<Dim> {
        let mut r = [0i8; 6];
        for (k, slot) in r.iter_mut().enumerate() {
            let e = *self.0.get(k)?;
            if e % 2 != 0 {
                return None;
            }
            *slot = e / 2;
        }
        Some(Dim(r))
    }
}

const LEN: Dim = Dim([1, 0, 0, 0, 0, 0]);
const MASS: Dim = Dim([0, 1, 0, 0, 0, 0]);
pub(crate) const TIME: Dim = Dim([0, 0, 1, 0, 0, 0]);
pub(crate) const TEMP: Dim = Dim([0, 0, 0, 1, 0, 0]);
const DATA: Dim = Dim([0, 0, 0, 0, 1, 0]);
pub(crate) const ANGLE: Dim = Dim([0, 0, 0, 0, 0, 1]);
const AREA: Dim = Dim([2, 0, 0, 0, 0, 0]);
const VOLUME: Dim = Dim([3, 0, 0, 0, 0, 0]);
const SPEED: Dim = Dim([1, 0, -1, 0, 0, 0]);
const ENERGY: Dim = Dim([2, 1, -2, 0, 0, 0]);
const POWER: Dim = Dim([2, 1, -3, 0, 0, 0]);
const PRESSURE: Dim = Dim([-1, 1, -2, 0, 0, 0]);
const FORCE: Dim = Dim([1, 1, -2, 0, 0, 0]);
const FREQ: Dim = Dim([0, 0, -1, 0, 0, 0]);
/// Volume per distance, such as L/100 km. Dimensionally an area.
const FUEL_VOL: Dim = AREA;
/// Distance per volume, such as mpg.
const FUEL_DIST: Dim = Dim([-2, 0, 0, 0, 0, 0]);
const DATA_RATE: Dim = Dim([0, 0, -1, 0, 1, 0]);

/// A conversion factor: an exact ratio or, for pi-based units, a float.
#[derive(Clone, Copy, Debug)]
pub(crate) enum Factor {
    R(i128, i128),
    F(f64),
}

impl Factor {
    pub(crate) fn num(self) -> Num {
        match self {
            Factor::R(n, d) => Num::ratio(n, d).unwrap_or(Num::Float(n as f64 / d as f64)),
            Factor::F(x) => Num::Float(x),
        }
    }
}

const fn r(n: i128, d: i128) -> Factor {
    Factor::R(n, d)
}

const ONE: Factor = Factor::R(1, 1);
const ZERO: Factor = Factor::R(0, 1);

/// Display names instead of the symbol: "3 hours", "2 cups".
pub(crate) const NAMED: u16 = 1;
/// Takes SI prefixes: "km", "kilometre".
pub(crate) const PFX: u16 = 2;
/// Takes decimal and binary prefixes: "GB", "GiB".
pub(crate) const PFX_DATA: u16 = 4;
pub(crate) const METRIC: u16 = 8;
pub(crate) const IMPERIAL: u16 = 16;
/// A distance-per-volume or volume-per-distance fuel unit, converted by reciprocal.
pub(crate) const FUEL: u16 = 32;
/// The symbol sits on the number: "30°".
pub(crate) const TIGHT: u16 = 64;
/// Prefixes only below one: ms, µs, ns. Seconds take no kilo.
pub(crate) const PFX_SMALL: u16 = 128;

pub(crate) struct UnitDef {
    pub sym: &'static str,
    pub one: &'static str,
    pub many: &'static str,
    pub dim: Dim,
    pub factor: Factor,
    pub offset: Factor,
    /// Lookup keys, matched ignoring case.
    pub keys: &'static [&'static str],
    /// Lookup keys matched with exact case.
    pub exact: &'static [&'static str],
    pub flags: u16,
    /// Months per unit for calendar arithmetic: 1 for a month, 12 for a year. Zero otherwise.
    pub months: u16,
}

macro_rules! unit {
    ($sym:expr, $one:expr, $many:expr, $dim:expr, $factor:expr, $keys:expr, $exact:expr, $flags:expr) => {
        UnitDef {
            sym: $sym,
            one: $one,
            many: $many,
            dim: $dim,
            factor: $factor,
            offset: ZERO,
            keys: $keys,
            exact: $exact,
            flags: $flags,
            months: 0,
        }
    };
}

pub(crate) static UNITS: &[UnitDef] = &[
    // Length.
    unit!(
        "m",
        "metre",
        "metres",
        LEN,
        ONE,
        &["m", "meter", "meters", "metre", "metres"],
        &[],
        PFX | METRIC
    ),
    unit!(
        "in",
        "inch",
        "inches",
        LEN,
        r(254, 10_000),
        &["in", "inch", "inches"],
        &[],
        IMPERIAL
    ),
    unit!(
        "ft",
        "foot",
        "feet",
        LEN,
        r(3048, 10_000),
        &["ft", "foot", "feet"],
        &[],
        IMPERIAL
    ),
    unit!(
        "yd",
        "yard",
        "yards",
        LEN,
        r(9144, 10_000),
        &["yd", "yds", "yard", "yards"],
        &[],
        IMPERIAL
    ),
    unit!(
        "mi",
        "mile",
        "miles",
        LEN,
        r(1_609_344, 1000),
        &["mi", "mile", "miles"],
        &[],
        IMPERIAL
    ),
    unit!(
        "nmi",
        "nautical mile",
        "nautical miles",
        LEN,
        r(1852, 1),
        &["nmi", "nautical mile", "nautical miles"],
        &["NM"],
        0
    ),
    unit!(
        "au",
        "astronomical unit",
        "astronomical units",
        LEN,
        r(149_597_870_700, 1),
        &["au", "astronomical unit", "astronomical units"],
        &[],
        0
    ),
    unit!(
        "ly",
        "light year",
        "light years",
        LEN,
        r(9_460_730_472_580_800, 1),
        &[
            "ly",
            "light year",
            "light years",
            "lightyear",
            "lightyears",
            "light-year",
            "light-years"
        ],
        &[],
        0
    ),
    unit!(
        "pc",
        "parsec",
        "parsecs",
        LEN,
        Factor::F(3.085_677_581_491_367e16),
        &["pc", "parsec", "parsecs"],
        &[],
        0
    ),
    unit!(
        "Å",
        "angstrom",
        "angstroms",
        LEN,
        r(1, 10_000_000_000),
        &["angstrom", "angstroms", "ångström"],
        &[],
        0
    ),
    unit!(
        "µm",
        "micron",
        "microns",
        LEN,
        r(1, 1_000_000),
        &["micron", "microns"],
        &[],
        METRIC
    ),
    unit!(
        "fathom",
        "fathom",
        "fathoms",
        LEN,
        r(18_288, 10_000),
        &["fathom", "fathoms"],
        &[],
        NAMED
    ),
    unit!(
        "furlong",
        "furlong",
        "furlongs",
        LEN,
        r(201_168, 1000),
        &["furlong", "furlongs"],
        &[],
        NAMED
    ),
    // Mass.
    unit!(
        "g",
        "gram",
        "grams",
        MASS,
        r(1, 1000),
        &["g", "gram", "grams", "gramme", "grammes"],
        &[],
        PFX | METRIC
    ),
    unit!(
        "t",
        "tonne",
        "tonnes",
        MASS,
        r(1000, 1),
        &["t", "tonne", "tonnes", "metric ton", "metric tons"],
        &[],
        METRIC
    ),
    unit!(
        "lb",
        "pound",
        "pounds",
        MASS,
        r(45_359_237, 100_000_000),
        &["lb", "lbs", "pound", "pounds"],
        &[],
        IMPERIAL
    ),
    unit!(
        "oz",
        "ounce",
        "ounces",
        MASS,
        r(28_349_523_125, 1_000_000_000_000),
        &["oz", "ounce", "ounces"],
        &[],
        IMPERIAL
    ),
    unit!(
        "st",
        "stone",
        "stone",
        MASS,
        r(635_029_318, 100_000_000),
        &["st", "stone", "stones"],
        &[],
        IMPERIAL | NAMED
    ),
    unit!(
        "ton",
        "ton",
        "tons",
        MASS,
        r(90_718_474, 100_000),
        &["ton", "tons", "short ton", "short tons", "us ton", "us tons"],
        &[],
        IMPERIAL | NAMED
    ),
    unit!(
        "long ton",
        "long ton",
        "long tons",
        MASS,
        r(10_160_469_088, 10_000_000),
        &["long ton", "long tons", "imperial ton", "imperial tons"],
        &[],
        IMPERIAL | NAMED
    ),
    unit!(
        "ct",
        "carat",
        "carats",
        MASS,
        r(2, 10_000),
        &["ct", "carat", "carats"],
        &[],
        0
    ),
    unit!(
        "grain",
        "grain",
        "grains",
        MASS,
        r(6_479_891, 100_000_000_000),
        &["grain", "grains"],
        &[],
        NAMED
    ),
    // Time.
    unit!(
        "s",
        "second",
        "seconds",
        TIME,
        ONE,
        &["s", "sec", "secs", "second", "seconds"],
        &[],
        NAMED | PFX | PFX_SMALL | METRIC
    ),
    unit!(
        "min",
        "minute",
        "minutes",
        TIME,
        r(60, 1),
        &["min", "mins", "minute", "minutes"],
        &[],
        NAMED
    ),
    unit!(
        "h",
        "hour",
        "hours",
        TIME,
        r(3600, 1),
        &["h", "hr", "hrs", "hour", "hours"],
        &[],
        NAMED
    ),
    unit!(
        "d",
        "day",
        "days",
        TIME,
        r(86_400, 1),
        &["d", "day", "days"],
        &[],
        NAMED
    ),
    unit!(
        "wk",
        "week",
        "weeks",
        TIME,
        r(604_800, 1),
        &["wk", "wks", "week", "weeks"],
        &[],
        NAMED
    ),
    unit!(
        "fortnight",
        "fortnight",
        "fortnights",
        TIME,
        r(1_209_600, 1),
        &["fortnight", "fortnights"],
        &[],
        NAMED
    ),
    UnitDef {
        months: 1,
        ..unit!(
            "mo",
            "month",
            "months",
            TIME,
            r(2_629_746, 1),
            &["mo", "mos", "month", "months"],
            &[],
            NAMED
        )
    },
    UnitDef {
        months: 12,
        ..unit!(
            "yr",
            "year",
            "years",
            TIME,
            r(31_556_952, 1),
            &["y", "yr", "yrs", "year", "years"],
            &[],
            NAMED
        )
    },
    UnitDef {
        months: 120,
        ..unit!(
            "decade",
            "decade",
            "decades",
            TIME,
            r(315_569_520, 1),
            &["decade", "decades"],
            &[],
            NAMED
        )
    },
    UnitDef {
        months: 1200,
        ..unit!(
            "century",
            "century",
            "centuries",
            TIME,
            r(3_155_695_200, 1),
            &["century", "centuries"],
            &[],
            NAMED
        )
    },
    // Temperature.
    UnitDef {
        offset: r(27_315, 100),
        ..unit!(
            "°C",
            "degree Celsius",
            "degrees Celsius",
            TEMP,
            ONE,
            &[
                "c",
                "°c",
                "celsius",
                "centigrade",
                "degc",
                "deg c",
                "degree c",
                "degrees c",
                "degree celsius",
                "degrees celsius"
            ],
            &[],
            METRIC
        )
    },
    UnitDef {
        offset: r(45_967, 180),
        ..unit!(
            "°F",
            "degree Fahrenheit",
            "degrees Fahrenheit",
            TEMP,
            r(5, 9),
            &[
                "f",
                "°f",
                "fahrenheit",
                "degf",
                "deg f",
                "degree f",
                "degrees f",
                "degree fahrenheit",
                "degrees fahrenheit"
            ],
            &[],
            IMPERIAL
        )
    },
    unit!("K", "kelvin", "kelvins", TEMP, ONE, &["kelvin", "kelvins"], &["K"], 0),
    unit!(
        "°R",
        "degree Rankine",
        "degrees Rankine",
        TEMP,
        r(5, 9),
        &["°r", "rankine"],
        &[],
        0
    ),
    // Area.
    unit!(
        "m²",
        "square metre",
        "square metres",
        AREA,
        ONE,
        &[
            "m²",
            "m2",
            "sq m",
            "sqm",
            "square meter",
            "square meters",
            "square metre",
            "square metres"
        ],
        &[],
        METRIC
    ),
    unit!(
        "km²",
        "square kilometre",
        "square kilometres",
        AREA,
        r(1_000_000, 1),
        &[
            "km²",
            "km2",
            "sq km",
            "sqkm",
            "square kilometer",
            "square kilometers",
            "square kilometre",
            "square kilometres"
        ],
        &[],
        METRIC
    ),
    unit!(
        "cm²",
        "square centimetre",
        "square centimetres",
        AREA,
        r(1, 10_000),
        &[
            "cm²",
            "cm2",
            "sq cm",
            "square centimeter",
            "square centimeters",
            "square centimetre",
            "square centimetres"
        ],
        &[],
        METRIC
    ),
    unit!(
        "mm²",
        "square millimetre",
        "square millimetres",
        AREA,
        r(1, 1_000_000),
        &[
            "mm²",
            "mm2",
            "sq mm",
            "square millimeter",
            "square millimeters",
            "square millimetre",
            "square millimetres"
        ],
        &[],
        METRIC
    ),
    unit!(
        "ha",
        "hectare",
        "hectares",
        AREA,
        r(10_000, 1),
        &["ha", "hectare", "hectares"],
        &[],
        METRIC
    ),
    unit!(
        "ft²",
        "square foot",
        "square feet",
        AREA,
        r(9_290_304, 100_000_000),
        &["ft²", "ft2", "sq ft", "sqft", "square foot", "square feet"],
        &[],
        IMPERIAL
    ),
    unit!(
        "in²",
        "square inch",
        "square inches",
        AREA,
        r(64_516, 100_000_000),
        &["in²", "in2", "sq in", "square inch", "square inches"],
        &[],
        IMPERIAL
    ),
    unit!(
        "yd²",
        "square yard",
        "square yards",
        AREA,
        r(83_612_736, 100_000_000),
        &["yd²", "yd2", "sq yd", "square yard", "square yards"],
        &[],
        IMPERIAL
    ),
    unit!(
        "mi²",
        "square mile",
        "square miles",
        AREA,
        r(2_589_988_110_336, 1_000_000),
        &["mi²", "mi2", "sq mi", "square mile", "square miles"],
        &[],
        IMPERIAL
    ),
    unit!(
        "acre",
        "acre",
        "acres",
        AREA,
        r(40_468_564_224, 10_000_000),
        &["ac", "acre", "acres"],
        &[],
        IMPERIAL | NAMED
    ),
    // Volume.
    unit!(
        "L",
        "litre",
        "litres",
        VOLUME,
        r(1, 1000),
        &["l", "liter", "liters", "litre", "litres", "ltr"],
        &[],
        PFX | METRIC
    ),
    unit!(
        "m³",
        "cubic metre",
        "cubic metres",
        VOLUME,
        ONE,
        &[
            "m³",
            "m3",
            "cu m",
            "cubic meter",
            "cubic meters",
            "cubic metre",
            "cubic metres"
        ],
        &[],
        METRIC
    ),
    unit!(
        "cm³",
        "cubic centimetre",
        "cubic centimetres",
        VOLUME,
        r(1, 1_000_000),
        &[
            "cm³",
            "cm3",
            "cc",
            "cubic centimeter",
            "cubic centimeters",
            "cubic centimetre",
            "cubic centimetres"
        ],
        &[],
        METRIC
    ),
    unit!(
        "ft³",
        "cubic foot",
        "cubic feet",
        VOLUME,
        r(28_316_846_592, 1_000_000_000_000),
        &["ft³", "ft3", "cu ft", "cubic foot", "cubic feet"],
        &[],
        IMPERIAL
    ),
    unit!(
        "in³",
        "cubic inch",
        "cubic inches",
        VOLUME,
        r(16_387_064, 1_000_000_000_000),
        &["in³", "in3", "cu in", "cubic inch", "cubic inches"],
        &[],
        IMPERIAL
    ),
    unit!(
        "gal",
        "gallon",
        "gallons",
        VOLUME,
        r(3_785_411_784, 1_000_000_000_000),
        &["gal", "gals", "gallon", "gallons", "us gallon", "us gallons"],
        &[],
        IMPERIAL
    ),
    unit!(
        "imp gal",
        "imperial gallon",
        "imperial gallons",
        VOLUME,
        r(454_609, 100_000_000),
        &[
            "imp gal",
            "imperial gallon",
            "imperial gallons",
            "uk gallon",
            "uk gallons"
        ],
        &[],
        IMPERIAL
    ),
    unit!(
        "qt",
        "quart",
        "quarts",
        VOLUME,
        r(946_352_946, 1_000_000_000_000),
        &["qt", "qts", "quart", "quarts"],
        &[],
        IMPERIAL
    ),
    unit!(
        "pt",
        "pint",
        "pints",
        VOLUME,
        r(473_176_473, 1_000_000_000_000),
        &["pt", "pts", "pint", "pints", "us pint", "us pints"],
        &[],
        IMPERIAL
    ),
    unit!(
        "imp pt",
        "imperial pint",
        "imperial pints",
        VOLUME,
        r(56_826_125, 100_000_000_000),
        &["imp pt", "imperial pint", "imperial pints", "uk pint", "uk pints"],
        &[],
        IMPERIAL
    ),
    unit!(
        "cup",
        "cup",
        "cups",
        VOLUME,
        r(2_365_882_365, 10_000_000_000_000),
        &["cup", "cups"],
        &[],
        IMPERIAL | NAMED
    ),
    unit!(
        "metric cup",
        "metric cup",
        "metric cups",
        VOLUME,
        r(25, 100_000),
        &["metric cup", "metric cups"],
        &[],
        NAMED
    ),
    unit!(
        "fl oz",
        "fluid ounce",
        "fluid ounces",
        VOLUME,
        r(295_735_295_625, 10_000_000_000_000_000),
        &["fl oz", "floz", "fl. oz", "fluid ounce", "fluid ounces", "us fl oz"],
        &[],
        IMPERIAL
    ),
    unit!(
        "imp fl oz",
        "imperial fluid ounce",
        "imperial fluid ounces",
        VOLUME,
        r(284_130_625, 10_000_000_000_000),
        &["imp fl oz", "imperial fluid ounce", "imperial fluid ounces", "uk fl oz"],
        &[],
        IMPERIAL
    ),
    unit!(
        "tbsp",
        "tablespoon",
        "tablespoons",
        VOLUME,
        r(1_478_676_478_125, 100_000_000_000_000_000),
        &["tbsp", "tbsps", "tbs", "tbl", "tablespoon", "tablespoons"],
        &["T"],
        IMPERIAL | NAMED
    ),
    unit!(
        "tsp",
        "teaspoon",
        "teaspoons",
        VOLUME,
        r(492_892_159_375, 100_000_000_000_000_000),
        &["tsp", "tsps", "teaspoon", "teaspoons"],
        &[],
        IMPERIAL | NAMED
    ),
    unit!(
        "bbl",
        "barrel",
        "barrels",
        VOLUME,
        r(158_987_294_928, 1_000_000_000_000),
        &["bbl", "barrel", "barrels"],
        &[],
        IMPERIAL
    ),
    // Speed.
    unit!(
        "m/s",
        "metre per second",
        "metres per second",
        SPEED,
        ONE,
        &[
            "m/s",
            "mps",
            "meter per second",
            "meters per second",
            "metre per second",
            "metres per second"
        ],
        &[],
        METRIC
    ),
    unit!(
        "km/h",
        "kilometre per hour",
        "kilometres per hour",
        SPEED,
        r(5, 18),
        &[
            "km/h",
            "km/hr",
            "kmh",
            "kph",
            "kmph",
            "kilometer per hour",
            "kilometers per hour",
            "kilometre per hour",
            "kilometres per hour"
        ],
        &[],
        METRIC
    ),
    unit!(
        "mph",
        "mile per hour",
        "miles per hour",
        SPEED,
        r(44_704, 100_000),
        &["mph", "mi/h", "mile per hour", "miles per hour"],
        &[],
        IMPERIAL
    ),
    unit!(
        "kn",
        "knot",
        "knots",
        SPEED,
        r(463, 900),
        &["kn", "kt", "kts", "knot", "knots"],
        &[],
        0
    ),
    unit!(
        "ft/s",
        "foot per second",
        "feet per second",
        SPEED,
        r(3048, 10_000),
        &["ft/s", "fps", "foot per second", "feet per second"],
        &[],
        IMPERIAL
    ),
    // Information.
    unit!(
        "bit",
        "bit",
        "bits",
        DATA,
        ONE,
        &["bit", "bits"],
        &["b"],
        PFX_DATA | NAMED
    ),
    unit!(
        "B",
        "byte",
        "bytes",
        DATA,
        r(8, 1),
        &["byte", "bytes"],
        &["B"],
        PFX_DATA
    ),
    unit!(
        "nibble",
        "nibble",
        "nibbles",
        DATA,
        r(4, 1),
        &["nibble", "nibbles"],
        &[],
        NAMED
    ),
    unit!(
        "bit/s",
        "bit per second",
        "bits per second",
        DATA_RATE,
        ONE,
        &["bps", "bit/s", "bits per second"],
        &[],
        PFX_DATA
    ),
    unit!(
        "B/s",
        "byte per second",
        "bytes per second",
        DATA_RATE,
        r(8, 1),
        &["byte/s", "bytes per second"],
        &["B/s"],
        PFX_DATA
    ),
    // Energy.
    unit!(
        "J",
        "joule",
        "joules",
        ENERGY,
        ONE,
        &["j", "joule", "joules"],
        &[],
        PFX | METRIC
    ),
    unit!(
        "cal",
        "calorie",
        "calories",
        ENERGY,
        r(4184, 1000),
        &["cal", "calorie", "calories"],
        &[],
        PFX | METRIC
    ),
    unit!(
        "Wh",
        "watt hour",
        "watt hours",
        ENERGY,
        r(3600, 1),
        &["wh", "watt hour", "watt hours", "watt-hour", "watt-hours"],
        &[],
        PFX | METRIC
    ),
    unit!(
        "eV",
        "electronvolt",
        "electronvolts",
        ENERGY,
        r(1_602_176_634, 10_000_000_000_000_000_000_000_000_000),
        &["electronvolt", "electronvolts", "electron volt", "electron volts"],
        &["eV"],
        PFX
    ),
    unit!(
        "BTU",
        "BTU",
        "BTU",
        ENERGY,
        r(105_505_585_262, 100_000_000),
        &["btu", "btus", "british thermal unit", "british thermal units"],
        &[],
        IMPERIAL
    ),
    unit!(
        "therm",
        "therm",
        "therms",
        ENERGY,
        r(105_480_400, 1),
        &["therm", "therms"],
        &[],
        IMPERIAL | NAMED
    ),
    // Power.
    unit!(
        "W",
        "watt",
        "watts",
        POWER,
        ONE,
        &["w", "watt", "watts"],
        &[],
        PFX | METRIC
    ),
    unit!(
        "hp",
        "horsepower",
        "horsepower",
        POWER,
        r(74_569_987_158_227_022, 100_000_000_000_000),
        &["hp", "bhp", "horsepower"],
        &[],
        IMPERIAL
    ),
    unit!(
        "metric hp",
        "metric horsepower",
        "metric horsepower",
        POWER,
        r(73_549_875, 100_000),
        &["metric hp", "metric horsepower"],
        &[],
        METRIC
    ),
    unit!(
        "BTU/h",
        "BTU per hour",
        "BTU per hour",
        POWER,
        r(105_505_585_262, 360_000_000_000),
        &["btu/h", "btu/hr", "btuh", "btu per hour"],
        &[],
        IMPERIAL
    ),
    // Pressure.
    unit!(
        "Pa",
        "pascal",
        "pascals",
        PRESSURE,
        ONE,
        &["pa", "pascal", "pascals"],
        &[],
        PFX | METRIC
    ),
    unit!(
        "bar",
        "bar",
        "bar",
        PRESSURE,
        r(100_000, 1),
        &["bar", "bars"],
        &[],
        PFX | METRIC
    ),
    unit!(
        "atm",
        "atmosphere",
        "atmospheres",
        PRESSURE,
        r(101_325, 1),
        &["atm", "atmosphere", "atmospheres"],
        &[],
        0
    ),
    unit!(
        "psi",
        "psi",
        "psi",
        PRESSURE,
        r(44_482_216_152_605, 6_451_600_000),
        &["psi"],
        &[],
        IMPERIAL
    ),
    unit!(
        "mmHg",
        "millimetre of mercury",
        "millimetres of mercury",
        PRESSURE,
        r(133_322_387_415, 1_000_000_000),
        &["mmhg", "mm hg", "millimeters of mercury", "millimetres of mercury"],
        &[],
        0
    ),
    unit!(
        "inHg",
        "inch of mercury",
        "inches of mercury",
        PRESSURE,
        r(3_386_388_640_341, 1_000_000_000),
        &["inhg", "in hg", "inches of mercury"],
        &[],
        IMPERIAL
    ),
    unit!("torr", "torr", "torr", PRESSURE, r(101_325, 760), &["torr"], &[], 0),
    // Angle. The base is the degree, so degrees, gradians and turns stay exact.
    unit!(
        "°",
        "degree",
        "degrees",
        ANGLE,
        ONE,
        &["°", "deg", "degs", "degree", "degrees"],
        &[],
        TIGHT
    ),
    unit!(
        "rad",
        "radian",
        "radians",
        ANGLE,
        Factor::F(180.0 / core::f64::consts::PI),
        &["rad", "rads", "radian", "radians"],
        &[],
        0
    ),
    unit!(
        "grad",
        "gradian",
        "gradians",
        ANGLE,
        r(9, 10),
        &["grad", "grads", "gradian", "gradians", "gon"],
        &[],
        0
    ),
    unit!(
        "turn",
        "turn",
        "turns",
        ANGLE,
        r(360, 1),
        &["turn", "turns", "rev", "revs", "revolution", "revolutions"],
        &[],
        NAMED
    ),
    unit!(
        "arcmin",
        "arcminute",
        "arcminutes",
        ANGLE,
        r(1, 60),
        &["arcmin", "arcminute", "arcminutes"],
        &[],
        0
    ),
    unit!(
        "arcsec",
        "arcsecond",
        "arcseconds",
        ANGLE,
        r(1, 3600),
        &["arcsec", "arcsecond", "arcseconds"],
        &[],
        0
    ),
    // Frequency.
    unit!("Hz", "hertz", "hertz", FREQ, ONE, &["hz", "hertz"], &[], PFX | METRIC),
    unit!("rpm", "rpm", "rpm", FREQ, r(1, 60), &["rpm"], &[], 0),
    // Force.
    unit!(
        "N",
        "newton",
        "newtons",
        FORCE,
        ONE,
        &["newton", "newtons"],
        &["N"],
        PFX | METRIC
    ),
    unit!(
        "lbf",
        "pound-force",
        "pounds-force",
        FORCE,
        r(44_482_216_152_605, 10_000_000_000_000),
        &["lbf", "pound-force", "pound force", "pounds-force", "pounds force"],
        &[],
        IMPERIAL
    ),
    unit!(
        "kgf",
        "kilogram-force",
        "kilograms-force",
        FORCE,
        r(980_665, 100_000),
        &["kgf", "kilogram-force"],
        &[],
        METRIC
    ),
    // Fuel economy.
    unit!(
        "L/100 km",
        "litre per 100 km",
        "litres per 100 km",
        FUEL_VOL,
        r(1, 100_000_000),
        &[
            "l/100km",
            "l/100 km",
            "l per 100km",
            "l per 100 km",
            "liters per 100 km",
            "litres per 100 km",
            "liters per 100km",
            "litres per 100km"
        ],
        &[],
        METRIC | FUEL
    ),
    unit!(
        "mpg",
        "mile per gallon",
        "miles per gallon",
        FUEL_DIST,
        r(1_609_344_000_000_000, 3_785_411_784),
        &["mpg", "mpg us", "us mpg", "miles per gallon", "mile per gallon"],
        &[],
        IMPERIAL | FUEL
    ),
    unit!(
        "mpg (imp)",
        "mile per imperial gallon",
        "miles per imperial gallon",
        FUEL_DIST,
        r(160_934_400_000, 454_609),
        &[
            "mpg uk",
            "uk mpg",
            "mpg imperial",
            "imperial mpg",
            "miles per imperial gallon"
        ],
        &[],
        IMPERIAL | FUEL
    ),
    unit!(
        "km/L",
        "kilometre per litre",
        "kilometres per litre",
        FUEL_DIST,
        r(1_000_000, 1),
        &[
            "km/l",
            "kmpl",
            "km per liter",
            "km per litre",
            "kilometers per liter",
            "kilometres per litre"
        ],
        &[],
        METRIC | FUEL
    ),
];

/// SI and binary prefixes. Index 0 is "no prefix".
pub(crate) struct Prefix {
    pub sym: &'static str,
    pub name: &'static str,
    pub factor: Factor,
    pub binary: bool,
}

const fn p(sym: &'static str, name: &'static str, factor: Factor) -> Prefix {
    Prefix {
        sym,
        name,
        factor,
        binary: false,
    }
}

pub(crate) static PREFIXES: &[Prefix] = &[
    p("", "", ONE),
    p("n", "nano", r(1, 1_000_000_000)),
    p("µ", "micro", r(1, 1_000_000)),
    p("m", "milli", r(1, 1000)),
    p("c", "centi", r(1, 100)),
    p("d", "deci", r(1, 10)),
    p("da", "deca", r(10, 1)),
    p("h", "hecto", r(100, 1)),
    p("k", "kilo", r(1000, 1)),
    p("M", "mega", r(1_000_000, 1)),
    p("G", "giga", r(1_000_000_000, 1)),
    p("T", "tera", r(1_000_000_000_000, 1)),
    p("P", "peta", r(1_000_000_000_000_000, 1)),
    p("E", "exa", r(1_000_000_000_000_000_000, 1)),
    p("p", "pico", r(1, 1_000_000_000_000)),
    p("f", "femto", r(1, 1_000_000_000_000_000)),
    Prefix {
        sym: "Ki",
        name: "kibi",
        factor: r(1 << 10, 1),
        binary: true,
    },
    Prefix {
        sym: "Mi",
        name: "mebi",
        factor: r(1 << 20, 1),
        binary: true,
    },
    Prefix {
        sym: "Gi",
        name: "gibi",
        factor: r(1 << 30, 1),
        binary: true,
    },
    Prefix {
        sym: "Ti",
        name: "tebi",
        factor: r(1 << 40, 1),
        binary: true,
    },
    Prefix {
        sym: "Pi",
        name: "pebi",
        factor: r(1 << 50, 1),
        binary: true,
    },
    Prefix {
        sym: "Ei",
        name: "exbi",
        factor: r(1 << 60, 1),
        binary: true,
    },
];

pub(crate) const P_MICRO: u8 = 2;
pub(crate) const P_MILLI: u8 = 3;
pub(crate) const P_CENTI: u8 = 4;
pub(crate) const P_KILO: u8 = 8;
pub(crate) const P_MEGA: u8 = 9;
pub(crate) const P_GIGA: u8 = 10;
pub(crate) const P_TERA: u8 = 11;
pub(crate) const P_PETA: u8 = 12;
pub(crate) const P_KIBI: u8 = 16;

/// A unit with an optional prefix.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct UnitRef {
    pub id: u16,
    pub prefix: u8,
}

impl UnitRef {
    pub(crate) const fn new(id: u16) -> UnitRef {
        UnitRef { id, prefix: 0 }
    }

    pub(crate) fn def(self) -> Option<&'static UnitDef> {
        UNITS.get(usize::from(self.id))
    }

    pub(crate) fn prefix_def(self) -> Option<&'static Prefix> {
        PREFIXES.get(usize::from(self.prefix))
    }

    pub(crate) fn dim(self) -> Dim {
        self.def().map_or(Dim::NONE, |d| d.dim)
    }

    pub(crate) fn flags(self) -> u16 {
        self.def().map_or(0, |d| d.flags)
    }

    /// Base units per one of this unit.
    pub(crate) fn factor(self) -> NumResult {
        let d = self.def().ok_or(NumError::Undefined)?;
        let p = self.prefix_def().ok_or(NumError::Undefined)?;
        d.factor.num().mul(p.factor.num())
    }

    pub(crate) fn offset(self) -> Num {
        self.def().map_or(Num::ZERO, |d| d.offset.num())
    }

    /// Value in this unit to base units.
    pub(crate) fn to_base(self, v: Num) -> NumResult {
        v.mul(self.factor()?)?.add(self.offset())
    }

    /// Base units to a value in this unit.
    pub(crate) fn of_base(self, base: Num) -> NumResult {
        base.sub(self.offset())?.div(self.factor()?)
    }

    pub(crate) fn months(self) -> u16 {
        if self.prefix != 0 {
            return 0;
        }
        self.def().map_or(0, |d| d.months)
    }

    pub(crate) fn is_temperature(self) -> bool {
        self.dim() == TEMP
    }
}

/// Finds a unit by its display symbol, for tests and fixed references.
pub(crate) fn by_sym(sym: &str) -> Option<UnitRef> {
    UNITS
        .iter()
        .position(|u| u.sym == sym)
        .and_then(|i| u16::try_from(i).ok())
        .map(UnitRef::new)
}

/// The unit a derived dimension is shown in when no conversion names one.
pub(crate) fn default_for(dim: Dim) -> Option<UnitRef> {
    let sym = match dim {
        d if d == LEN => "m",
        d if d == MASS => "g",
        d if d == TIME => "s",
        d if d == TEMP => "K",
        d if d == DATA => "B",
        d if d == ANGLE => "°",
        d if d == AREA => "m²",
        d if d == VOLUME => "L",
        d if d == SPEED => "m/s",
        d if d == ENERGY => "J",
        d if d == POWER => "W",
        d if d == PRESSURE => "Pa",
        d if d == FORCE => "N",
        d if d == FREQ => "Hz",
        d if d == FUEL_DIST => "km/L",
        d if d == DATA_RATE => "bit/s",
        _ => return None,
    };
    let mut u = by_sym(sym)?;
    if sym == "g" {
        u.prefix = P_KILO;
    }
    Some(u)
}

/// A unit whose factor is exactly `factor` for `dim`, such as km/h for km divided by h.
pub(crate) fn with_factor(dim: Dim, factor: Num) -> Option<UnitRef> {
    UNITS.iter().enumerate().find_map(|(i, u)| {
        if u.dim != dim || u.offset.num().is_exact() && !u.offset.num().is_zero() {
            return None;
        }
        let f = u.factor.num();
        if f.is_exact() && f.cmp(factor).is_eq() {
            u16::try_from(i).ok().map(UnitRef::new)
        } else {
            None
        }
    })
}

/// The unit in the other measurement system, shown as an alternate form.
pub(crate) fn counterpart(u: UnitRef) -> Option<UnitRef> {
    let d = u.def()?;
    let sym = d.sym;
    let to = |s: &str| by_sym(s);
    let with_prefix = |s: &str, prefix: u8| {
        by_sym(s).map(|mut r| {
            r.prefix = prefix;
            r
        })
    };
    match sym {
        "m" => match u.prefix {
            P_KILO => to("mi"),
            P_CENTI | P_MILLI => to("in"),
            0 => to("ft"),
            _ => None,
        },
        "in" => with_prefix("m", P_CENTI),
        "ft" | "yd" => to("m"),
        "mi" => with_prefix("m", P_KILO),
        "g" => match u.prefix {
            P_KILO => to("lb"),
            0 | P_MILLI => to("oz"),
            _ => None,
        },
        "lb" | "st" => with_prefix("g", P_KILO),
        "oz" => to("g"),
        "t" => to("ton"),
        "ton" | "long ton" => to("t"),
        "L" => match u.prefix {
            0 => to("gal"),
            P_MILLI => to("fl oz"),
            _ => None,
        },
        "gal" | "imp gal" | "qt" | "pt" | "imp pt" => to("L"),
        "fl oz" | "imp fl oz" | "cup" | "tbsp" | "tsp" | "metric cup" => with_prefix("L", P_MILLI),
        "°C" => to("°F"),
        "°F" | "K" | "°R" => to("°C"),
        "km/h" => to("mph"),
        "mph" | "kn" | "m/s" | "ft/s" => to("km/h"),
        "m²" => to("ft²"),
        "ft²" | "yd²" | "in²" => to("m²"),
        "km²" => to("mi²"),
        "mi²" => to("km²"),
        "ha" => to("acre"),
        "acre" => to("ha"),
        "L/100 km" => to("mpg"),
        "mpg" | "mpg (imp)" | "km/L" => to("L/100 km"),
        "J" => with_prefix("cal", P_KILO),
        "cal" => with_prefix("J", P_KILO),
        "Wh" => with_prefix("J", P_MEGA),
        "W" => to("hp"),
        "hp" | "metric hp" => with_prefix("W", P_KILO),
        "Pa" | "bar" | "atm" | "mmHg" | "inHg" | "torr" => to("psi"),
        "psi" => to("bar"),
        "°" => to("rad"),
        "rad" | "grad" | "turn" => to("°"),
        "B" | "bit" | "bit/s" | "B/s" if u.prefix != 0 => {
            // GB <-> GiB at the same order of magnitude.
            let order = |i: u8| -> Option<(bool, u8)> {
                match i {
                    P_KILO => Some((false, 1)),
                    P_MEGA => Some((false, 2)),
                    P_GIGA => Some((false, 3)),
                    P_TERA => Some((false, 4)),
                    P_PETA => Some((false, 5)),
                    i if (P_KIBI..P_KIBI + 6).contains(&i) => Some((true, i - P_KIBI + 1)),
                    _ => None,
                }
            };
            let (binary, n) = order(u.prefix)?;
            let other = if binary {
                [P_KILO, P_MEGA, P_GIGA, P_TERA, P_PETA]
                    .get(usize::from(n) - 1)
                    .copied()?
            } else {
                P_KIBI + n - 1
            };
            Some(UnitRef {
                id: u.id,
                prefix: other,
            })
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_unit_converts_both_ways() {
        for (i, u) in UNITS.iter().enumerate() {
            let r = UnitRef::new(i as u16);
            let base = r.to_base(Num::int(3));
            assert!(base.is_ok(), "{}", u.sym);
            let back = base.and_then(|b| r.of_base(b));
            let back = back.map(Num::to_f64).unwrap_or(f64::NAN);
            assert!((back - 3.0).abs() < 1e-9, "{} round trip gave {back}", u.sym);
        }
    }

    #[test]
    fn symbols_are_unique() {
        for (i, a) in UNITS.iter().enumerate() {
            for b in UNITS.iter().skip(i + 1) {
                assert_ne!(a.sym, b.sym);
            }
        }
    }

    #[test]
    fn counterparts_share_a_dimension() {
        for (i, _) in UNITS.iter().enumerate() {
            let u = UnitRef::new(i as u16);
            if let Some(c) = counterpart(u) {
                let fuel = u.flags() & FUEL != 0;
                assert!(fuel || c.dim() == u.dim(), "{:?}", u);
            }
        }
    }
}
