//! Small deterministic RNG (xoshiro256**), so the crate needs no external dependencies.

pub struct Rng {
    s: [u64; 4],
}

impl Rng {
    pub fn new(seed: u64) -> Self {
        let mut sm = seed;
        let mut s = [0u64; 4];
        for x in s.iter_mut() {
            sm = sm.wrapping_add(0x9E37_79B9_7F4A_7C15);
            let mut z = sm;
            z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
            z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
            *x = z ^ (z >> 31);
        }
        Rng { s }
    }
    #[inline]
    pub fn next_u64(&mut self) -> u64 {
        let r = self.s[1].wrapping_mul(5).rotate_left(7).wrapping_mul(9);
        let t = self.s[1] << 17;
        self.s[2] ^= self.s[0];
        self.s[3] ^= self.s[1];
        self.s[1] ^= self.s[2];
        self.s[0] ^= self.s[3];
        self.s[2] ^= t;
        self.s[3] = self.s[3].rotate_left(45);
        r
    }
    #[inline]
    pub fn f64(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 * (1.0 / (1u64 << 53) as f64)
    }
    pub fn below(&mut self, n: usize) -> usize {
        if n == 0 {
            return 0;
        }
        ((self.f64() * n as f64) as usize).min(n - 1)
    }
    pub fn range(&mut self, a: f64, b: f64) -> f64 {
        a + (b - a) * self.f64()
    }
    pub fn chance(&mut self, p: f64) -> bool {
        self.f64() < p
    }
    pub fn exp(&mut self, mean: f64) -> f64 {
        -mean * (1.0 - self.f64()).ln()
    }
    pub fn normal(&mut self) -> f64 {
        let u1 = self.f64().max(1e-12);
        let u2 = self.f64();
        (-2.0 * u1.ln()).sqrt() * (2.0 * std::f64::consts::PI * u2).cos()
    }
    pub fn poisson(&mut self, lambda: f64) -> usize {
        if lambda <= 0.0 {
            return 0;
        }
        if lambda < 30.0 {
            let l = (-lambda).exp();
            let mut k = 0;
            let mut p = 1.0;
            loop {
                p *= self.f64();
                if p <= l {
                    return k;
                }
                k += 1;
            }
        }
        (self.normal() * lambda.sqrt() + lambda).max(0.0).round() as usize
    }
    /// Marsaglia-Tsang gamma sampler (shape > 0, scale 1).
    pub fn gamma(&mut self, shape: f64) -> f64 {
        if shape < 1.0 {
            let u = self.f64().max(1e-12);
            return self.gamma(shape + 1.0) * u.powf(1.0 / shape);
        }
        let d = shape - 1.0 / 3.0;
        let c = 1.0 / (9.0 * d).sqrt();
        loop {
            let x = self.normal();
            let v = (1.0 + c * x).powi(3);
            if v <= 0.0 {
                continue;
            }
            let u = self.f64();
            if u < 1.0 - 0.0331 * x.powi(4) || u.ln() < 0.5 * x * x + d * (1.0 - v + v.ln()) {
                return d * v;
            }
        }
    }
    pub fn dirichlet(&mut self, n: usize, alpha: f64) -> Vec<f64> {
        let mut v: Vec<f64> = (0..n).map(|_| self.gamma(alpha).max(1e-9)).collect();
        let s: f64 = v.iter().sum();
        for x in v.iter_mut() {
            *x /= s;
        }
        v
    }
    pub fn weighted(&mut self, w: &[f64]) -> usize {
        let s: f64 = w.iter().sum();
        let mut r = self.f64() * s;
        for (i, &x) in w.iter().enumerate() {
            r -= x;
            if r <= 0.0 {
                return i;
            }
        }
        w.len() - 1
    }
    pub fn shuffle<T>(&mut self, v: &mut [T]) {
        for i in (1..v.len()).rev() {
            let j = self.below(i + 1);
            v.swap(i, j);
        }
    }
}
