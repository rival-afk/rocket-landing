//! Deterministic cave generator — line-by-line port of `game/cave.gd`.
//!
//! Same nodes (knots) every KNOT px: offset = hash(k) * 2 - 1 (times MAX_SHIFT),
//! half-width = MIN_HALF + hash(k + 1000) * HALF_VAR; points between knots are
//! linear interpolations -> sharp corners at knots. Everything is a pure
//! function of y; identical on every run, no RNG state.

pub const SEG_H: f64 = 256.0;
pub const KNOT: f64 = 256.0;
pub const STEP: f64 = 16.0;
pub const FAR: f64 = 1100.0;
pub const LOOKAHEAD: f64 = 1600.0;
pub const BEHIND: f64 = 700.0;

pub const MAX_SHIFT: f64 = 175.0;
pub const MIN_HALF: f64 = 60.0;
pub const HALF_VAR: f64 = 55.0;

/// cave_hash(n) — GDScript: s = sin(n * 127.1 + 311.7) * 43758.5453; return s - floor(s)
/// NOTE: sin() is libm/MSVC-dependent at sub-ULP scale; deterministic per platform.
#[inline]
pub fn cave_hash(n: f64) -> f64 {
    let s = (n * 127.1 + 311.7).sin() * 43758.5453;
    s - s.floor()
}

/// knot_offset — GDScript: if k == 0.0 { return 0.0 } (start strictly at center)
#[inline]
pub fn knot_offset(k: f64) -> f64 {
    if k == 0.0 {
        return 0.0;
    }
    (cave_hash(k) * 2.0 - 1.0) * MAX_SHIFT
}

#[inline]
pub fn knot_half(k: f64) -> f64 {
    MIN_HALF + cave_hash(k + 1000.0) * HALF_VAR
}

/// center_at(y) — GDScript identical: lerp between knots, spawn-safety ramp |y|/768
#[inline]
pub fn center_at(y: f64) -> f64 {
    let k = (y / KNOT).floor();
    let t = (y - k * KNOT) / KNOT;
    let a = knot_offset(k);
    let b = knot_offset(k + 1.0);
    // v = lerpf(knot_offset(k), knot_offset(k + 1.0), t)
    let v = a + (b - a) * t;
    // плавный выход из стартовой точки, чтобы ракета не упёрлась в стену на старте
    let ramp = (y.abs() / (3.0 * KNOT)).clamp(0.0, 1.0);
    v * ramp
}

/// half_at(y) — linear interpolation of knot halves between knots
#[inline]
pub fn half_at(y: f64) -> f64 {
    let k = (y / KNOT).floor();
    let t = (y - k * KNOT) / KNOT;
    let a = knot_half(k);
    let b = knot_half(k + 1.0);
    a + (b - a) * t
}

#[inline]
pub fn left_x(y: f64) -> f64 {
    center_at(y) - half_at(y)
}

#[inline]
pub fn right_x(y: f64) -> f64 {
    center_at(y) + half_at(y)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cave_is_deterministic() {
        // same y -> same values, every time
        assert_eq!(center_at(-500.0), center_at(-500.0));
        assert_eq!(half_at(1234.0), half_at(1234.0));
    }

    #[test]
    fn corridor_never_collapses() {
        for i in -50..200 {
            let y = i as f64 * 7.0;
            let h = half_at(y);
            assert!(h >= MIN_HALF - 1e-6, "half collapsed to {} at y={}", h, y);
            assert!(left_x(y) < right_x(y));
        }
    }

    #[test]
    fn cave_hash_in_range() {
        for k in -20..2000 {
            let h = cave_hash(k as f64);
            assert!((0.0..=1.0).contains(&h), "hash({}) = {}", k, h);
        }
    }

    #[test]
    fn spawn_area_is_centered() {
        // at y=0 the corridor is centered (spawn ramp is zero there)
        assert_eq!(center_at(0.0), 0.0);
    }
}
