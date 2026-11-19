//! libm.zig - the math functions of the Zig SWMM6 engine: glibc's own, called through `extern "m"`, as the C++
//! engine calls them (the build passes -fno-builtin so LLVM keeps every call, and -fno-compiler-rt so no copy in
//! Zig's compiler-rt captures one; lessons/19 of the SWMM5 ports). The exact operations (sqrt, fabs, floor, ceil,
//! trunc, copysign) are Zig builtins, which IEEE fixes; floor, ceil and trunc on the baseline x86-64 target are
//! calls to glibc as well.
//! Written by Claude (Anthropic) for the SWMM6 ports; see AI-USE.md.
const std = @import("std");
const E = @import("rt.zig").E;

// set 1
pub extern "m" fn exp(x: f64) f64;
pub extern "m" fn log(x: f64) f64;
pub extern "m" fn pow(x: f64, y: f64) f64;
pub extern "m" fn sin(x: f64) f64;
pub extern "m" fn cos(x: f64) f64;
pub extern "m" fn tan(x: f64) f64;
pub extern "m" fn asin(x: f64) f64;
pub extern "m" fn acos(x: f64) f64;
pub extern "m" fn atan(x: f64) f64;
pub extern "m" fn log10(x: f64) f64;
// set 2
pub extern "m" fn atan2(y: f64, x: f64) f64;
pub extern "m" fn log2(x: f64) f64;
pub extern "m" fn sinh(x: f64) f64;
pub extern "m" fn tanh(x: f64) f64;
pub extern "m" fn cosh(x: f64) f64;
pub extern "m" fn expm1(x: f64) f64;
pub extern "m" fn log1p(x: f64) f64;
pub extern "m" fn cbrt(x: f64) f64;
pub extern "m" fn hypot(x: f64, y: f64) f64;
// exact operations glibc implements (called, so the result is glibc's in every case, NaNs included)
pub extern "m" fn fmod(x: f64, y: f64) f64;
pub extern "m" fn remainder(x: f64, y: f64) f64;
pub extern "m" fn round(x: f64) f64;
pub extern "m" fn nextafter(x: f64, y: f64) f64;
pub extern "m" fn floor(x: f64) f64;
pub extern "m" fn ceil(x: f64) f64;
pub extern "m" fn trunc(x: f64) f64;

/// System.Math as the engine calls it (the C# Math routes these to the C library too).
pub const Math = struct {
    pub inline fn Abs_d(x: f64) f64 {
        return @abs(x);
    }
    pub inline fn Sqrt_d(x: f64) f64 {
        return @sqrt(x);
    }
    pub inline fn Floor_d(x: f64) f64 {
        return floor(x);
    }
    pub inline fn Ceiling_d(x: f64) f64 {
        return ceil(x);
    }
    pub inline fn Truncate_d(x: f64) f64 {
        return trunc(x);
    }
    pub inline fn CopySign_d(x: f64, y: f64) f64 {
        return std.math.copysign(x, y);
    }
    pub inline fn Exp_d(x: f64) f64 {
        return exp(x);
    }
    pub inline fn Log_d(x: f64) f64 {
        return log(x);
    }
    pub inline fn Log10_d(x: f64) f64 {
        return log10(x);
    }
    pub inline fn Log2_d(x: f64) f64 {
        return log2(x);
    }
    pub inline fn Pow_d(x: f64, y: f64) f64 {
        return pow(x, y);
    }
    pub inline fn Sin_d(x: f64) f64 {
        return sin(x);
    }
    pub inline fn Cos_d(x: f64) f64 {
        return cos(x);
    }
    pub inline fn Tan_d(x: f64) f64 {
        return tan(x);
    }
    pub inline fn Asin_d(x: f64) f64 {
        return asin(x);
    }
    pub inline fn Acos_d(x: f64) f64 {
        return acos(x);
    }
    pub inline fn Atan_d(x: f64) f64 {
        return atan(x);
    }
    pub inline fn Atan2_d(y: f64, x: f64) f64 {
        return atan2(y, x);
    }
    pub inline fn Sinh_d(x: f64) f64 {
        return sinh(x);
    }
    pub inline fn Cosh_d(x: f64) f64 {
        return cosh(x);
    }
    pub inline fn Tanh_d(x: f64) f64 {
        return tanh(x);
    }
    pub inline fn Cbrt_d(x: f64) f64 {
        return cbrt(x);
    }
    /// C#'s % on doubles (IEEE remainder by truncation, as fmod)
    pub inline fn fmod(x: f64, y: f64) f64 {
        return @This().fmodC(x, y);
    }
    fn fmodC(x: f64, y: f64) f64 {
        return @import("libm.zig").fmod(x, y);
    }
};

/// The C# runtime's LibM: the C library functions .NET does not route to glibc.
pub const LibM = struct {
    pub fn hypot(x: f64, y: f64) E!f64 {
        return @import("libm.zig").hypot(x, y);
    }
    pub fn fmod(x: f64, y: f64) E!f64 {
        return @import("libm.zig").fmod(x, y);
    }
    pub fn round(x: f64) E!f64 {
        return @import("libm.zig").round(x);
    }
    pub fn expm1(x: f64) E!f64 {
        return @import("libm.zig").expm1(x);
    }
    pub fn log1p(x: f64) E!f64 {
        return @import("libm.zig").log1p(x);
    }
    pub fn remainder(x: f64, y: f64) E!f64 {
        return @import("libm.zig").remainder(x, y);
    }
    pub fn nextafter(x: f64, y: f64) E!f64 {
        return @import("libm.zig").nextafter(x, y);
    }
    pub fn log(x: f64) E!f64 {
        return @import("libm.zig").log(x);
    }
};
