//! rt.zig - the runtime of the Zig SWMM6 engine: the small part of the C++ standard library and of glibc that the
//! engine calls, written in Zig after the C# runtime (cs/runtime), which is its specification. The generated engine
//! (zig/gen/engine.zig) imports it as `rt`.
//!
//! Conventions the translator relies on (tools/cs2x/ZIG.md):
//!   * every runtime method, static function and constructor returns `E!T` (a C# exception is the error Throw with
//!     the thrown object in `cur_exc`); operators and the p_* property getters cannot fail;
//!   * a C# class is a Zig struct held by an optional pointer (`?*Vec(f64)`), a C# struct a Zig value;
//!   * char* is `?[*]u8`, T* is `?[*]T`, a C# array `?[]T`, object `Obj`;
//!   * memory comes from the system's Boehm collector (libgc), as the C# relies on .NET's collector.
//! Written by Claude (Anthropic) for the SWMM6 ports; see AI-USE.md.
const std = @import("std");
pub const crt = @import("crt.zig");
pub const cont = @import("cont.zig");
pub const strm = @import("streams.zig");
pub const fsm = @import("fs.zig");
pub const libm = @import("libm.zig");

pub const E = error{Throw};
pub const Obj = ?*anyopaque;

// ================================================================ memory (the Boehm collector)
extern "gc" fn GC_malloc(n: usize) ?*anyopaque;
extern "gc" fn GC_malloc_atomic(n: usize) ?*anyopaque;
extern "gc" fn GC_init() void;
extern "gc" fn GC_set_all_interior_pointers(v: c_int) void;
extern "gc" fn GC_expand_hp(n: usize) c_int;

pub fn gcInit() void {
    GC_set_all_interior_pointers(1);
    GC_init();
    _ = GC_expand_hp(64 << 20);
}

/// Whether a value of T can hold a pointer the collector must follow.
pub fn hasPointers(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .float, .bool, .void, .@"enum", .comptime_int, .comptime_float => false,
        .array => |a| hasPointers(a.child),
        .@"struct" => |s| blk: {
            inline for (s.fields) |f| {
                if (hasPointers(f.type)) break :blk true;
            }
            break :blk false;
        },
        .optional => |o| hasPointers(o.child),
        else => true,
    };
}

fn rawAlloc(comptime T: type, bytes: usize) [*]u8 {
    const n = if (bytes == 0) 1 else bytes;
    const p = if (comptime hasPointers(T)) GC_malloc(n) else GC_malloc_atomic(n);
    const q: [*]u8 = @ptrCast(p orelse oom());
    if (!comptime hasPointers(T)) @memset(q[0..n], 0);
    return q;
}

fn oom() noreturn {
    @panic("out of memory");
}

/// A new zeroed T (zero is C#'s default for every field type the engine uses).
pub fn gcNew(comptime T: type) *T {
    return @ptrCast(@alignCast(rawAlloc(T, @sizeOf(T))));
}

/// n zeroed elements.
pub fn gcSlice(comptime T: type, n: usize) []T {
    const p: [*]T = @ptrCast(@alignCast(rawAlloc(T, n * @sizeOf(T))));
    return p[0..n];
}

pub fn cell(comptime T: type, v: T) *T {
    const p = gcNew(T);
    p.* = v;
    return p;
}

pub fn ctxOf(comptime T: type, v: T) ?*anyopaque {
    return @ptrCast(cell(T, v));
}

pub fn box(comptime T: type, v: T) Obj {
    return @ptrCast(cell(T, v));
}

pub fn unbox(comptime T: type, o: Obj) T {
    return @as(*T, @ptrCast(@alignCast(o.?))).*;
}

pub inline fn toObj(p: anytype) Obj {
    return @ptrCast(p);
}

pub inline fn fromObj(comptime T: type, o: Obj) ?*T {
    return @ptrCast(@alignCast(o));
}

// ================================================================ arrays (C# T[]: ?[]T)
pub fn newArr(comptime T: type, n: anytype) ?[]T {
    return gcSlice(T, @intCast(n));
}

pub fn arrOf(comptime T: type, vals: []const T) ?[]T {
    const a = gcSlice(T, vals.len);
    @memcpy(a, vals);
    return a;
}

/// &arr[off] (a null array gives a null pointer)
pub inline fn arrPtr(arr: anytype, off: anytype) ?[*]@typeInfo(@typeInfo(@TypeOf(arr)).optional.child).pointer.child {
    const a = arr orelse return null;
    return padd(@as(?[*]@typeInfo(@typeInfo(@TypeOf(arr)).optional.child).pointer.child, a.ptr), off);
}

// ================================================================ pointers (char* ?[*]u8, T* ?[*]T)
fn PElem(comptime P: type) type {
    return switch (@typeInfo(P)) {
        .optional => |o| @typeInfo(o.child).pointer.child,
        .pointer => |p| p.child,
        else => @compileError("not a pointer"),
    };
}

inline fn soff(n: anytype) isize {
    return switch (@typeInfo(@TypeOf(n))) {
        .comptime_int => n,
        .int => |i| if (i.signedness == .signed) @intCast(n) else @bitCast(@as(usize, @intCast(n))),
        else => @compileError("offset"),
    };
}

/// p + n for any integer n (a null pointer stays null)
pub inline fn padd(p: anytype, n: anytype) @TypeOf(p) {
    const P = @TypeOf(p);
    const q = p orelse return null;
    const sz: isize = @sizeOf(PElem(P));
    const a: usize = @intFromPtr(q) +% @as(usize, @bitCast(soff(n) *% sz));
    return @ptrFromInt(a);
}

pub inline fn psub(p: anytype, n: anytype) @TypeOf(p) {
    return padd(p, -%soff(n));
}

/// p - q in elements
pub inline fn pdiff(p: anytype, q: anytype) i64 {
    const sz: i64 = @sizeOf(PElem(@TypeOf(p)));
    const a: i64 = @bitCast(@intFromPtr(p) -% @intFromPtr(q));
    return @divTrunc(a, sz);
}

pub inline fn plt(p: anytype, q: anytype) bool {
    return @intFromPtr(p) < @intFromPtr(q);
}

/// &p[i] for any integer i
pub inline fn pat(p: anytype, i: anytype) *PElem(@TypeOf(p)) {
    return @ptrCast(padd(p, i).?);
}

/// char* element as C# reads it: a signed char widened to int
pub inline fn cget(p: ?[*]u8, i: anytype) i32 {
    return @as(i8, @bitCast(pat(p, i).*));
}

pub inline fn cset(p: ?[*]u8, i: anytype, v: anytype) void {
    pat(p, i).* = @truncate(@as(u64, @bitCast(@as(i64, v))));
}

pub inline fn toCPtr(p: anytype) ?[*]u8 {
    return @ptrCast(p);
}

/// A char* literal: a pointer to a static NUL-terminated copy.
pub fn lit(comptime s: [:0]const u8) ?[*]u8 {
    const S = struct {
        var buf: [s.len:0]u8 = s[0..s.len :0].*;
    };
    return &S.buf;
}

pub fn strEq(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

pub const iterPtr = cont.iterPtr;

/// the C# runtime's CPtr statics
pub const CPtr = struct {
    pub fn Diff(a: ?[*]u8, b: ?[*]u8) E!i64 {
        return pdiff(a, b);
    }
};

/// System.Array.Fill(T[] a, T v)
pub const Array = struct {
    pub fn Fill(a: anytype, v: anytype) E!void {
        for (a.?) |*x| x.* = v;
    }
};

pub const File = fsm.File;

// ================================================================ integers
/// C#'s unchecked conversion between integer types: truncation, or extension by the source's signedness.
pub inline fn cv(comptime T: type, x: anytype) T {
    const S = @TypeOf(x);
    if (S == comptime_int) return @as(T, @truncate(@as(i128, x)));
    if (S == bool) return @intFromBool(x);
    const sb = @bitSizeOf(S);
    const tb = @bitSizeOf(T);
    if (tb <= sb) {
        const U = std.meta.Int(.unsigned, sb);
        const V = std.meta.Int(.unsigned, tb);
        const t: V = @truncate(@as(U, @bitCast(x)));
        return @bitCast(t);
    }
    const W = std.meta.Int(@typeInfo(S).int.signedness, tb);
    return @bitCast(@as(W, x));
}

fn Unsigned(comptime T: type) type {
    return std.meta.Int(.unsigned, @bitSizeOf(T));
}

inline fn shiftCount(comptime T: type, b: anytype) std.math.Log2Int(T) {
    const m: u64 = @bitSizeOf(T) - 1;
    const v: u64 = @truncate(@as(u128, @bitCast(@as(i128, b))));
    return @intCast(v & m);
}

/// a << b with C#'s count masking
pub inline fn shl(a: anytype, b: anytype) @TypeOf(a) {
    const T = @TypeOf(a);
    return @bitCast(@as(Unsigned(T), @bitCast(a)) << shiftCount(T, b));
}

/// a >> b: arithmetic for signed a, logical for unsigned
pub inline fn shr(a: anytype, b: anytype) @TypeOf(a) {
    return a >> shiftCount(@TypeOf(a), b);
}

pub inline fn ushr(a: anytype, b: anytype) @TypeOf(a) {
    const T = @TypeOf(a);
    return @bitCast(@as(Unsigned(T), @bitCast(a)) >> shiftCount(T, b));
}

pub inline fn band(a: bool, b: bool) bool {
    return a and b;
}

pub inline fn bor(a: bool, b: bool) bool {
    return a or b;
}

/// x86-64 cvttsd2si: NaN and out-of-range values give the minimum (the C# runtime's Conv)
pub inline fn f2i32(x: anytype) i32 {
    const d: f64 = x;
    if (!(d > -2147483649.0 and d < 2147483648.0)) return std.math.minInt(i32);
    return @intFromFloat(d);
}
pub inline fn f2i64(x: anytype) i64 {
    const d: f64 = x;
    if (!(d >= -9223372036854775808.0 and d < 9223372036854775808.0)) return std.math.minInt(i64);
    return @intFromFloat(d);
}
pub inline fn f2u32(x: anytype) u32 {
    return @truncate(@as(u64, @bitCast(f2i64(x))));
}
pub inline fn f2u64(x: anytype) u64 {
    const d: f64 = x;
    if (d < 9223372036854775808.0) return @bitCast(f2i64(d));
    return @as(u64, @bitCast(f2i64(d - 9223372036854775808.0))) ^ 0x8000000000000000;
}
pub inline fn f2i16(x: anytype) i16 {
    return @truncate(f2i32(x));
}
pub inline fn f2u16(x: anytype) u16 {
    return @truncate(@as(u32, @bitCast(f2i32(x))));
}
pub inline fn f2i8(x: anytype) i8 {
    return @truncate(f2i32(x));
}
pub inline fn f2u8(x: anytype) u8 {
    return @truncate(@as(u32, @bitCast(f2i32(x))));
}

pub const Conv = struct {
    pub fn D2I(x: f64) E!i32 {
        return f2i32(x);
    }
    pub fn D2L(x: f64) E!i64 {
        return f2i64(x);
    }
    pub fn D2UL(x: f64) E!u64 {
        return f2u64(x);
    }
    pub fn D2SB(x: f64) E!i8 {
        return f2i8(x);
    }
    pub fn D2U(x: f64) E!u32 {
        return f2u32(x);
    }
};

// ================================================================ delegates: a context and a function
pub fn Fn0(comptime Ret: type) type {
    return struct {
        ctx: ?*anyopaque = null,
        f: ?*const fn (?*anyopaque) E!Ret = null,
        pub inline fn call(self: @This()) E!Ret {
            return self.f.?(self.ctx);
        }
    };
}
pub fn Fn1(comptime A: type, comptime Ret: type) type {
    return struct {
        ctx: ?*anyopaque = null,
        f: ?*const fn (?*anyopaque, A) E!Ret = null,
        pub inline fn call(self: @This(), a: A) E!Ret {
            return self.f.?(self.ctx, a);
        }
    };
}
pub fn Fn2(comptime A: type, comptime B: type, comptime Ret: type) type {
    return struct {
        ctx: ?*anyopaque = null,
        f: ?*const fn (?*anyopaque, A, B) E!Ret = null,
        pub inline fn call(self: @This(), a: A, b: B) E!Ret {
            return self.f.?(self.ctx, a, b);
        }
    };
}
pub fn Fn3(comptime A: type, comptime B: type, comptime C: type, comptime Ret: type) type {
    return struct {
        ctx: ?*anyopaque = null,
        f: ?*const fn (?*anyopaque, A, B, C) E!Ret = null,
        pub inline fn call(self: @This(), a: A, b: B, c: C) E!Ret {
            return self.f.?(self.ctx, a, b, c);
        }
    };
}
pub fn Fn4(comptime A: type, comptime B: type, comptime C: type, comptime D: type, comptime Ret: type) type {
    return struct {
        ctx: ?*anyopaque = null,
        f: ?*const fn (?*anyopaque, A, B, C, D) E!Ret = null,
        pub inline fn call(self: @This(), a: A, b: B, c: C, d: D) E!Ret {
            return self.f.?(self.ctx, a, b, c, d);
        }
    };
}
pub fn Fn5(comptime A: type, comptime B: type, comptime C: type, comptime D: type, comptime F: type, comptime Ret: type) type {
    return struct {
        ctx: ?*anyopaque = null,
        f: ?*const fn (?*anyopaque, A, B, C, D, F) E!Ret = null,
        pub inline fn call(self: @This(), a: A, b: B, c: C, d: D, e: F) E!Ret {
            return self.f.?(self.ctx, a, b, c, d, e);
        }
    };
}
pub fn Fn6(comptime A: type, comptime B: type, comptime C: type, comptime D: type, comptime F: type, comptime G: type, comptime Ret: type) type {
    return struct {
        ctx: ?*anyopaque = null,
        f: ?*const fn (?*anyopaque, A, B, C, D, F, G) E!Ret = null,
        pub inline fn call(self: @This(), a: A, b: B, c: C, d: D, e: F, g: G) E!Ret {
            return self.f.?(self.ctx, a, b, c, d, e, g);
        }
    };
}
pub fn Fn7(comptime A: type, comptime B: type, comptime C: type, comptime D: type, comptime F: type, comptime G: type, comptime H: type, comptime Ret: type) type {
    return struct {
        ctx: ?*anyopaque = null,
        f: ?*const fn (?*anyopaque, A, B, C, D, F, G, H) E!Ret = null,
        pub inline fn call(self: @This(), a: A, b: B, c: C, d: D, e: F, g: G, h: H) E!Ret {
            return self.f.?(self.ctx, a, b, c, d, e, g, h);
        }
    };
}
pub fn Fn8(comptime A: type, comptime B: type, comptime C: type, comptime D: type, comptime F: type, comptime G: type, comptime H: type, comptime I: type, comptime Ret: type) type {
    return struct {
        ctx: ?*anyopaque = null,
        f: ?*const fn (?*anyopaque, A, B, C, D, F, G, H, I) E!Ret = null,
        pub inline fn call(self: @This(), a: A, b: B, c: C, d: D, e: F, g: G, h: H, i: I) E!Ret {
            return self.f.?(self.ctx, a, b, c, d, e, g, h, i);
        }
    };
}
pub fn Fn9(comptime A: type, comptime B: type, comptime C: type, comptime D: type, comptime F: type, comptime G: type, comptime H: type, comptime I: type, comptime J: type, comptime Ret: type) type {
    return struct {
        ctx: ?*anyopaque = null,
        f: ?*const fn (?*anyopaque, A, B, C, D, F, G, H, I, J) E!Ret = null,
        pub inline fn call(self: @This(), a: A, b: B, c: C, d: D, e: F, g: G, h: H, i: I, j: J) E!Ret {
            return self.f.?(self.ctx, a, b, c, d, e, g, h, i, j);
        }
    };
}

// ================================================================ exceptions
/// std::exception and its standard subclasses, as one struct with a kind (the C# runtime's classes); an engine
/// exception class embeds it as its base. tid is the dynamic type: a runtime kind below 1000, an engine class from
/// 1000 (the generated __tid_parent knows both).
pub const CppException = struct {
    tid: u32,
    msg: ?*Str,
    pub const __rt = true;
    pub fn initDefault(self: *CppException) E!void {
        if (self.tid == 0) self.tid = K_exception;
        self.msg = try Str.newLit("std::exception");
    }
    pub fn make(kind: u32, m: ?*Str) E!?*CppException {
        const e = gcNew(CppException);
        e.tid = kind;
        e.msg = if (m) |s| try s.Clone() else try Str.newSlice(kindName(kind));
        return e;
    }
    pub fn makeLit(kind: u32, m: ?[]const u8) E!?*CppException {
        const e = gcNew(CppException);
        e.tid = kind;
        e.msg = try Str.newSlice(m orelse "");
        return e;
    }
    pub fn what(self: *CppException) E!?[*]u8 {
        return self.msg.?.c_str();
    }
    fn kindName(k: u32) []const u8 {
        return switch (k) {
            K_bad_alloc => "std::bad_alloc",
            K_bad_optional_access => "bad optional access",
            K_bad_function_call => "bad_function_call",
            K_bad_variant_access => "std::get: wrong index for variant",
            else => "std::exception",
        };
    }
};

pub const K_exception: u32 = 1;
pub const K_logic_error: u32 = 2;
pub const K_runtime_error: u32 = 3;
pub const K_invalid_argument: u32 = 4;
pub const K_out_of_range: u32 = 5;
pub const K_length_error: u32 = 6;
pub const K_domain_error: u32 = 7;
pub const K_range_error: u32 = 8;
pub const K_overflow_error: u32 = 9;
pub const K_bad_alloc: u32 = 10;
pub const K_bad_optional_access: u32 = 11;
pub const K_bad_function_call: u32 = 12;
pub const K_bad_variant_access: u32 = 13;
pub const K_sys_exception: u32 = 100;
pub const K_not_implemented: u32 = 101;
pub const K_invalid_operation: u32 = 102;
pub const K_not_supported: u32 = 103;

/// the parent of a runtime exception kind (0 at the root)
pub fn excParent(t: u32) u32 {
    return switch (t) {
        2, 3, 10, 11, 12, 13 => 1,
        4, 5, 6, 7 => 2,
        8, 9 => 3,
        101, 102, 103, 104, 105 => 100,
        else => 0,
    };
}

pub var cur_exc: ?*CppException = null;

pub fn setExc(e: ?*CppException) void {
    cur_exc = e;
}

pub fn excGet() ?*CppException {
    return cur_exc;
}

/// throw e: the pending exception and the error that carries it
pub fn throwExc(e: ?*CppException) E {
    cur_exc = e;
    return error.Throw;
}

pub fn throwKind(kind: u32, msg: []const u8) E {
    cur_exc = CppException.makeLit(kind, msg) catch null;
    return error.Throw;
}

// ================================================================ re-exports
pub const Str = @import("str.zig").Str;
pub const R = crt.R;
pub const CFile = crt.CFile;
pub const Vec = cont.Vec;
pub const Iter = cont.Iter;
pub const RevIter = cont.RevIter;
pub const Pair = cont.Pair;
pub const Opt = cont.Opt;
pub const UMap = cont.UMap;
pub const USet = cont.USet;
pub const UMapC = cont.UMapC;
pub const HashTable = cont.HashTable;
pub const MIt = cont.MIt;
pub const Map = cont.Map;
pub const Set = cont.Set;
pub const Stk = cont.Stk;
pub const Que = cont.Que;
pub const CSpan = cont.CSpan;
pub const Less = cont.Less;
pub const Algo = cont.Algo;
pub const StdAlgo = cont.StdAlgo;
pub const Arr = cont.Arr;
pub const Mem = cont.Mem;
pub const Bytes = cont.Bytes;
pub const Mv = cont.Mv;
pub const Elem = cont.Elem;
pub const Atomic = cont.Atomic;
pub const Box = cont.Box;
pub const Variant = cont.Variant;
pub const TupN = cont.TupN;
pub const IStream = strm.IStream;
pub const OStream = strm.OStream;
pub const IStringStream = strm.IStringStream;
pub const OStringStream = strm.OStringStream;
pub const IFStream = strm.IFStream;
pub const OFStream = strm.OFStream;
pub const Streams = strm.Streams;
pub const IosBase = strm.IStream;
pub const FsPath = fsm.FsPath;
pub const Fs = fsm.Fs;
pub const FileStatus = fsm.FileStatus;
pub const ErrorCode = fsm.ErrorCode;
pub const Math = libm.Math;
pub const LibM = libm.LibM;

// ================================================================ small types
pub const M = struct {
    pub fn min_d_d(a: f64, b: f64) E!f64 {
        return if (b < a) b else a;
    }
    pub fn max_d_d(a: f64, b: f64) E!f64 {
        return if (a < b) b else a;
    }
    pub fn min_i_i(a: i32, b: i32) E!i32 {
        return if (b < a) b else a;
    }
    pub fn max_i_i(a: i32, b: i32) E!i32 {
        return if (a < b) b else a;
    }
    pub fn min_l_l(a: i64, b: i64) E!i64 {
        return if (b < a) b else a;
    }
    pub fn max_l_l(a: i64, b: i64) E!i64 {
        return if (a < b) b else a;
    }
    pub fn min_ul_ul(a: u64, b: u64) E!u64 {
        return if (b < a) b else a;
    }
    pub fn max_ul_ul(a: u64, b: u64) E!u64 {
        return if (a < b) b else a;
    }
    pub fn min_u_u(a: u32, b: u32) E!u32 {
        return if (b < a) b else a;
    }
    pub fn max_u_u(a: u32, b: u32) E!u32 {
        return if (a < b) b else a;
    }
    pub fn min_uc_uc(a: u8, b: u8) E!u8 {
        return if (b < a) b else a;
    }
    pub fn max_uc_uc(a: u8, b: u8) E!u8 {
        return if (a < b) b else a;
    }
    pub fn min_f_f(a: f32, b: f32) E!f32 {
        return if (b < a) b else a;
    }
    pub fn max_f_f(a: f32, b: f32) E!f32 {
        return if (a < b) b else a;
    }
    pub fn clamp_d_d_d(v: f64, lo: f64, hi: f64) E!f64 {
        return if (v < lo) lo else if (hi < v) hi else v;
    }
    pub fn clamp_i_i_i(v: i32, lo: i32, hi: i32) E!i32 {
        return if (v < lo) lo else if (hi < v) hi else v;
    }
    pub fn clamp_l_l_l(v: i64, lo: i64, hi: i64) E!i64 {
        return if (v < lo) lo else if (hi < v) hi else v;
    }
    pub fn min_dA(il: ?[]f64) E!f64 {
        const a = il.?;
        var r = a[0];
        for (a[1..]) |x| {
            if (x < r) r = x;
        }
        return r;
    }
    pub fn max_dA(il: ?[]f64) E!f64 {
        const a = il.?;
        var r = a[0];
        for (a[1..]) |x| {
            if (r < x) r = x;
        }
        return r;
    }
    pub fn min_iA(il: ?[]i32) E!i32 {
        const a = il.?;
        var r = a[0];
        for (a[1..]) |x| {
            if (x < r) r = x;
        }
        return r;
    }
    pub fn max_iA(il: ?[]i32) E!i32 {
        const a = il.?;
        var r = a[0];
        for (a[1..]) |x| {
            if (r < x) r = x;
        }
        return r;
    }
};

pub const Std = struct {
    pub const QNaN: f64 = @bitCast(@as(u64, 0x7FF8000000000000));
    pub fn Rethrow(e: ?*CppException) E!void {
        return throwExc(e);
    }
    pub fn call_once(flag: ?*OnceFlag, f: Fn0(void)) E!void {
        if (flag.?.done) return;
        try f.call();
        flag.?.done = true;
    }
    pub fn get0_PairAB(comptime A: type, comptime B: type, p: ?*Pair(A, B)) E!*A {
        return &p.?.first;
    }
    pub fn get1_PairAB(comptime A: type, comptime B: type, p: ?*Pair(A, B)) E!*B {
        return &p.?.second;
    }
    pub fn swap(comptime T: type, a: *T, b: *T) E!void {
        const t = a.*;
        a.* = b.*;
        b.* = t;
    }
    pub const from_chars_CPtr_CPtr_dr = crt.from_chars_d;
    pub const from_chars_CPtr_CPtr_ir = crt.from_chars_i;
    pub const from_chars_CPtr_CPtr_ur = crt.from_chars_u;
    pub const from_chars_CPtr_CPtr_lr = crt.from_chars_l;
};

pub const FromCharsResult = struct {
    ptr: ?[*]u8 = null,
    ec: i32 = 0,
};

pub const OnceFlag = struct {
    done: bool,
    pub const __rt = true;
    pub fn new() E!?*OnceFlag {
        return gcNew(OnceFlag);
    }
};
pub const Mutex = struct {
    x: u8,
    pub const __rt = true;
    pub fn new() E!?*Mutex {
        return gcNew(Mutex);
    }
};
pub const CondVar = struct {
    x: u8,
    pub const __rt = true;
    pub fn new() E!?*CondVar {
        return gcNew(CondVar);
    }
};
pub const Lock = struct {
    x: u8,
    pub const __rt = true;
    pub fn new() E!?*Lock {
        return gcNew(Lock);
    }
};
pub const Thread = struct {
    x: u8,
    pub const __rt = true;
    pub fn new() E!?*Thread {
        return gcNew(Thread);
    }
    pub fn joinable(self: *Thread) E!bool {
        _ = self;
        return false;
    }
    pub fn join(self: *Thread) E!void {
        _ = self;
    }
};

/// A destructor deferred to the end of the enclosing block (a using declaration), unless cancelled.
pub const Defer = struct {
    a: Fn0(void),
    pub const __rt = true;
    pub fn new(a: Fn0(void)) E!?*Defer {
        const d = gcNew(Defer);
        d.a = a;
        return d;
    }
    pub fn Cancel(self: *Defer) E!void {
        self.a = .{};
    }
    pub fn Dispose(self: *Defer) E!void {
        const x = self.a;
        self.a = .{};
        if (x.f != null) try x.call();
    }
};

/// Dispose at the end of a using declaration (the runtime's types)
pub fn dispose(x: anytype) E!void {
    const T = @TypeOf(x);
    if (T == ?*Defer) return if (x) |d| d.Dispose() else {};
    return Dtor.Run(x);
}

/// Runs a C++ destructor: an engine class's Dispose (its __dispose), a file stream's close, a container's elements.
pub const Dtor = struct {
    pub fn Run(x: anytype) E!void {
        const T = @TypeOf(x);
        if (T == @TypeOf(null)) return;
        switch (@typeInfo(T)) {
            .optional => |o| {
                const v = x orelse return;
                switch (@typeInfo(o.child)) {
                    .pointer => |p| {
                        const S = p.child;
                        if (@typeInfo(S) == .@"struct") {
                            if (@hasDecl(S, "__dispose")) return S.__dispose(v);
                            if (@hasDecl(S, "DestroyElems")) return v.DestroyElems();
                            if (@hasDecl(S, "Dispose")) return v.Dispose();
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
};

pub const Sys = struct {
    extern "c" fn get_nprocs() c_int;
    pub fn hardware_concurrency() E!u32 {
        const n = get_nprocs();
        return if (n > 0) @intCast(n) else 0;
    }
};

pub const Duration = struct {
    ns: i64 = 0,
    pub fn count(self: Duration) E!f64 {
        return @as(f64, @floatFromInt(self.ns)) * 1e-9;
    }
    pub fn op_add(a: Duration, b: Duration) Duration {
        return .{ .ns = a.ns +% b.ns };
    }
    pub fn op_sub(a: Duration, b: Duration) Duration {
        return .{ .ns = a.ns -% b.ns };
    }
};

pub const TimePoint = struct {
    ns: i64 = 0,
    extern "c" fn clock_gettime(clk: c_int, ts: *[2]i64) c_int;
    pub fn now() E!TimePoint {
        var ts: [2]i64 = .{ 0, 0 };
        _ = clock_gettime(1, &ts);
        return .{ .ns = ts[0] *% 1000000000 +% ts[1] };
    }
    pub fn op_sub(a: TimePoint, b: TimePoint) Duration {
        return .{ .ns = a.ns -% b.ns };
    }
    pub fn time_since_epoch(self: TimePoint) E!Duration {
        return .{ .ns = self.ns };
    }
};

pub const BitConverter = struct {
    pub fn DoubleToInt64Bits(d: f64) i64 {
        return @bitCast(d);
    }
    pub fn Int64BitsToDouble(l: i64) f64 {
        return @bitCast(l);
    }
};

/// The startup the C# runtime does in its static constructors.
pub fn init() void {
    gcInit();
    crt.initStd();
}
