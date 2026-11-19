//! crt.zig - the C library pieces the SWMM6 engine calls, reproducing glibc 2.39 on x86-64 where the output depends
//! on it: printf/snprintf with glibc's exact decimal rounding, strtod/atof/sscanf with glibc's syntax and correct
//! rounding, stdio files with C's position, end-of-file flag and buffering, strings, ctype in the C locale, time.
//! The number scanner, the formatter and the stdio layer are those of the Zig port of EPA SWMM 5.2.4
//! (swmm5-ports/zig/src/rt.zig, checked against glibc there with 1,394,252 cases); sscanf, the char-array helpers and
//! the engine-facing namespace R follow the C# runtime of the SWMM6 ports (cs/runtime/CRuntime.cs, Fs.cs), which is
//! their specification. Internally strings are C pointers ([*c]i8); the engine's char* is ?[*]u8 (the R wrappers
//! cast between the two, which changes no bit).
//! Written by Claude (Anthropic) for the SWMM6 ports; see AI-USE.md.
const std = @import("std");
const rt = @import("rt.zig");
const E = rt.E;
const Str = @import("str.zig").Str;

extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn pread(fd: c_int, buf: [*]u8, n: usize, off: i64) isize;
extern "c" fn pwrite(fd: c_int, buf: [*]const u8, n: usize, off: i64) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn lseek(fd: c_int, off: i64, whence: c_int) i64;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn getcwd(buf: [*]u8, size: usize) ?[*]u8;
extern "c" fn getpid() c_int;
const c_time = @extern(*const fn (?*i64) callconv(.c) i64, .{ .name = "time", .library_name = "c" });

const O_RDONLY: c_int = 0;
const O_WRONLY: c_int = 1;
const O_RDWR: c_int = 2;
const O_CREAT: c_int = 0o100;
const O_EXCL: c_int = 0o200;
const O_TRUNC: c_int = 0o1000;
const O_APPEND: c_int = 0o2000;

pub const nan64: f64 = @bitCast(@as(u64, 0x7ff8000000000000)); // C's NAN
pub const inf64: f64 = std.math.inf(f64);

const gpa = std.heap.smp_allocator;

fn d2i(comptime T: type, x: anytype) T {
    return switch (T) {
        i64 => rt.f2i64(x),
        i32 => rt.f2i32(x),
        else => @compileError("d2i"),
    };
}

fn isSpace(c: i32) bool {
    return c == ' ' or (c >= 9 and c <= 13);
}

fn low(c: i32) i32 {
    return if (c >= 'A' and c <= 'Z') c | 0x20 else c;
}

fn isHex(c: i32) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}


const Scan = struct { v: f64, end: isize, text_ok: bool, text: [512]u8 = undefined, tlen: usize = 0 };

/// glibc's strtod syntax at b (at most maxw characters when maxw >= 0): the value, the end offset
/// (-1: no number), and for a decimal or hexadecimal number its text (for %f into a float)
fn scanDouble(b: [*c]const i8, maxw: isize, skip_space: bool, sc: *Scan) void {
    var i: usize = 0;
    if (skip_space) {
        while (b[i] != 0 and isSpace(b[i])) i += 1;
    }
    const lim: usize = if (maxw >= 0) i + @as(usize, @intCast(maxw)) else std.math.maxInt(usize);
    const G = struct {
        b: [*c]const i8,
        lim: usize,
        fn g(self: @This(), k: usize) i32 {
            if (k >= self.lim) return 0;
            return self.b[k];
        }
    };
    const g = G{ .b = b, .lim = lim };
    sc.text_ok = false;
    sc.tlen = 0;
    var neg = false;
    if (g.g(i) == '+' or g.g(i) == '-') {
        neg = g.g(i) == '-';
        i += 1;
    }
    if (low(g.g(i)) == 'i' and low(g.g(i + 1)) == 'n' and low(g.g(i + 2)) == 'f') {
        i += 3;
        if (low(g.g(i)) == 'i' and low(g.g(i + 1)) == 'n' and low(g.g(i + 2)) == 'i' and low(g.g(i + 3)) == 't' and low(g.g(i + 4)) == 'y') i += 5;
        sc.v = if (neg) -inf64 else inf64;
        sc.end = @intCast(i);
        return;
    }
    if (low(g.g(i)) == 'n' and low(g.g(i + 1)) == 'a' and low(g.g(i + 2)) == 'n') {
        i += 3;
        if (g.g(i) == '(') {
            var k = i + 1;
            while (true) {
                const c = g.g(k);
                if ((c >= '0' and c <= '9') or (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '_') {
                    k += 1;
                    continue;
                }
                break;
            }
            if (g.g(k) == ')') {
                // glibc reads the n-char-sequence with strtoull(seq, 0) and keeps it as the payload
                var pl: u64 = 0;
                const ok = if (k == i + 1) true else parsePayload(b + i + 1, k - i - 1, &pl);
                if (ok) {
                    var v: f64 = @bitCast(@as(u64, 0x7ff8000000000000) | (pl & ((@as(u64, 1) << 51) - 1)));
                    if (neg) v = -v;
                    sc.v = v;
                    sc.end = @intCast(k + 1);
                    return;
                }
                i = k + 1;
            }
        }
        sc.v = if (neg) @as(f64, @bitCast(@as(u64, 0xfff8000000000000))) else nan64;
        sc.end = @intCast(i);
        return;
    }
    if (g.g(i) == '0' and low(g.g(i + 1)) == 'x') { // hexadecimal float (C99), as glibc reads it
        var j = i + 2;
        var nh: usize = 0;
        while (isHex(g.g(j))) {
            j += 1;
            nh += 1;
        }
        if (g.g(j) == '.') {
            j += 1;
            while (isHex(g.g(j))) {
                j += 1;
                nh += 1;
            }
        }
        if (nh > 0) {
            var t: usize = 0;
            if (neg) {
                sc.text[t] = '-';
                t += 1;
            }
            sc.text[t] = '0';
            sc.text[t + 1] = 'x';
            t += 2;
            var k = i + 2;
            if (g.g(k) == '.') {
                sc.text[t] = '0';
                t += 1;
            }
            while (k < j and t < 480) : (k += 1) {
                sc.text[t] = @intCast(g.g(k));
                t += 1;
            }
            sc.text[t] = 'p';
            t += 1;
            if (low(g.g(j)) == 'p') {
                var e = j + 1;
                if (g.g(e) == '+' or g.g(e) == '-') e += 1;
                if (g.g(e) >= '0' and g.g(e) <= '9') {
                    while (g.g(e) >= '0' and g.g(e) <= '9') e += 1;
                    var q = j + 1;
                    while (q < e and t < 510) : (q += 1) {
                        sc.text[t] = @intCast(g.g(q));
                        t += 1;
                    }
                    j = e;
                } else {
                    sc.text[t] = '0';
                    t += 1;
                }
            } else {
                sc.text[t] = '0';
                t += 1;
            }
            sc.tlen = t;
            sc.text_ok = true;
            sc.v = std.fmt.parseFloat(f64, sc.text[0..t]) catch 0;
            sc.end = @intCast(j);
            return;
        }
    }
    const ms = i;
    var nd: usize = 0;
    while (g.g(i) >= '0' and g.g(i) <= '9') {
        i += 1;
        nd += 1;
    }
    if (g.g(i) == '.') {
        i += 1;
        while (g.g(i) >= '0' and g.g(i) <= '9') {
            i += 1;
            nd += 1;
        }
    }
    if (nd == 0) {
        sc.v = 0;
        sc.end = -1;
        return;
    }
    if (low(g.g(i)) == 'e') {
        var k = i + 1;
        if (g.g(k) == '+' or g.g(k) == '-') k += 1;
        if (g.g(k) >= '0' and g.g(k) <= '9') {
            while (g.g(k) >= '0' and g.g(k) <= '9') k += 1;
            i = k;
        }
    }
    sc.end = @intCast(i);
    sc.v = parseDec(b + ms, i - ms, neg, f64);
    if (i - ms < 500) {
        var t: usize = 0;
        if (neg) {
            sc.text[0] = '-';
            t = 1;
        }
        for (0..i - ms) |q| sc.text[t + q] = @intCast(b[ms + q]);
        sc.tlen = t + i - ms;
        sc.text_ok = true;
    }
}

fn parsePayload(p: [*c]const i8, n: usize, res: *u64) bool {
    // strtoull(seq, &end, 0) must consume the whole sequence
    var i: usize = 0;
    var base: u64 = 10;
    if (n >= 2 and p[0] == '0' and low(p[1]) == 'x') {
        base = 16;
        i = 2;
    } else if (n >= 1 and p[0] == '0') base = 8;
    var v: u64 = 0;
    if (i >= n) return base != 16;
    while (i < n) : (i += 1) {
        const c = low(p[i]);
        const d: u64 = if (c >= '0' and c <= '9') @intCast(c - '0') else if (c >= 'a' and c <= 'z') @intCast(c - 'a' + 10) else 99;
        if (d >= base) return false;
        v = v *% base +% d;
    }
    res.* = v;
    return true;
}

/// a decimal number's text (digits, optional point, optional exponent), correctly rounded
fn parseDec(p: [*c]const i8, n: usize, neg: bool, comptime F: type) F {
    var buf: [128]u8 = undefined;
    var big: ?[]u8 = null;
    defer if (big) |x| gpa.free(x);
    var dst: []u8 = &buf;
    if (n + 3 > buf.len) {
        big = gpa.alloc(u8, n + 3) catch unreachable;
        dst = big.?;
    }
    var t: usize = 0;
    var k: usize = 0;
    // parseFloat wants a digit before an exponent and no trailing point: "5." -> "5.0", ".5" -> "0.5"
    if (p[0] == '.') {
        dst[t] = '0';
        t += 1;
    }
    while (k < n) : (k += 1) {
        const c: u8 = @bitCast(p[k]);
        dst[t] = c;
        t += 1;
        if (c == '.' and (k + 1 >= n or !(p[k + 1] >= '0' and p[k + 1] <= '9'))) {
            dst[t] = '0';
            t += 1;
        }
    }
    const v = std.fmt.parseFloat(F, dst[0..t]) catch unreachable;
    return if (neg) -v else v;
}


pub const Arg = union(enum) { i: i64, u: u64, is_int: i32, d: f64, str: [*c]i8 };

fn parg(a: anytype) Arg {
    const T = @TypeOf(a);
    switch (T) {
        i32 => return .{ .is_int = a },
        i8, i16, u8, u16 => return .{ .is_int = a },
        bool => return .{ .is_int = @intFromBool(a) },
        i64 => return .{ .i = a },
        u32 => return .{ .u = a },
        u64 => return .{ .u = a },
        f64 => return .{ .d = a },
        f32 => return .{ .d = a },
        [*c]i8 => return .{ .str = a },
        ?[*]u8 => return .{ .str = @ptrCast(a) },
        comptime_int => return .{ .i = a },
        else => @compileError("printf argument " ++ @typeName(T)),
    }
}

fn argLong(a: Arg) struct { v: i64, int32: bool } {
    return switch (a) {
        .is_int => |x| .{ .v = x, .int32 = true },
        .i => |x| .{ .v = x, .int32 = false },
        .u => |x| .{ .v = @bitCast(x), .int32 = false },
        .d => |x| .{ .v = d2i(i64, x), .int32 = false },
        .str => |x| .{ .v = @bitCast(@intFromPtr(x)), .int32 = false },
    };
}

fn argDouble(a: Arg) f64 {
    return switch (a) {
        .d => |x| x,
        .is_int => |x| @floatFromInt(x),
        .i => |x| @floatFromInt(x),
        .u => |x| @floatFromInt(x),
        .str => 0,
    };
}

/// an output buffer that grows
const Out = struct {
    buf: []u8,
    n: usize = 0,
    heap: bool = false,
    fn put(o: *Out, c: u8) void {
        if (o.n == o.buf.len) o.grow(o.n + 1);
        o.buf[o.n] = c;
        o.n += 1;
    }
    fn puts(o: *Out, x: []const u8) void {
        if (o.n + x.len > o.buf.len) o.grow(o.n + x.len);
        @memcpy(o.buf[o.n .. o.n + x.len], x);
        o.n += x.len;
    }
    fn pad(o: *Out, c: u8, k: usize) void {
        for (0..k) |_| o.put(c);
    }
    fn grow(o: *Out, need: usize) void {
        var m = o.buf.len * 2;
        while (m < need) m *= 2;
        const nb = gpa.alloc(u8, m) catch unreachable;
        @memcpy(nb[0..o.n], o.buf[0..o.n]);
        if (o.heap) gpa.free(o.buf);
        o.buf = nb;
        o.heap = true;
    }
    fn deinit(o: *Out) void {
        if (o.heap) gpa.free(o.buf);
    }
};

// ---------------------------------------------------------------- exact decimal digits of a double
const Big = struct {
    w: [96]u32 = undefined,
    n: usize = 0,
    fn set(b: *Big, v: u64) void {
        b.w[0] = @truncate(v);
        b.w[1] = @truncate(v >> 32);
        b.n = 2;
        b.trim();
    }
    fn trim(b: *Big) void {
        while (b.n > 0 and b.w[b.n - 1] == 0) b.n -= 1;
    }
    fn mulSmall(b: *Big, m: u32) void {
        var carry: u64 = 0;
        for (0..b.n) |k| {
            const t = @as(u64, b.w[k]) * m + carry;
            b.w[k] = @truncate(t);
            carry = t >> 32;
        }
        if (carry != 0) {
            b.w[b.n] = @truncate(carry);
            b.n += 1;
        }
    }
    fn shl(b: *Big, k: usize) void {
        const ws = k / 32;
        const bs: u5 = @intCast(k % 32);
        if (b.n == 0) return;
        var i: usize = b.n + ws + 1;
        while (i > 0) {
            i -= 1;
            var v: u32 = 0;
            if (i >= ws) {
                const src = i - ws;
                const hi: u64 = if (src < b.n) b.w[src] else 0;
                const lo: u64 = if (src >= 1 and src - 1 < b.n) b.w[src - 1] else 0;
                v = @truncate(((hi << 32 | lo) << bs) >> 32);
            }
            b.w[i] = v;
        }
        b.n = b.n + ws + 1;
        b.trim();
    }
    /// divide by 10^9, returning the remainder
    fn divBillion(b: *Big) u32 {
        var r: u64 = 0;
        var i = b.n;
        while (i > 0) {
            i -= 1;
            const t = (r << 32) | b.w[i];
            b.w[i] = @truncate(t / 1000000000);
            r = t % 1000000000;
        }
        b.trim();
        return @truncate(r);
    }
    /// decimal digits (most significant first) into out; returns the count ("" for zero)
    fn toDec(b: *Big, dst: []u8) usize {
        var tmp: [1200]u8 = undefined;
        var t: usize = 0;
        while (b.n > 0) {
            var r = b.divBillion();
            var k: usize = 0;
            while (k < 9) : (k += 1) {
                tmp[t] = @intCast('0' + r % 10);
                r /= 10;
                t += 1;
            }
        }
        while (t > 0 and tmp[t - 1] == '0') t -= 1;
        for (0..t) |k| dst[k] = tmp[t - 1 - k];
        return t;
    }
};

/// the exact decimal expansion of a positive finite double: digits d[0..n] with the decimal point after
/// d[0..p] (p >= 1; the integer part is "0" when it is zero)
const Digits = struct { d: [1500]u8 = undefined, n: usize = 0, p: usize = 0 };

fn exactDigits(v: f64, dg: *Digits) void {
    const bits: u64 = @bitCast(v);
    const ex: i32 = @intCast((bits >> 52) & 0x7ff);
    var m: u64 = bits & ((@as(u64, 1) << 52) - 1);
    var e: i32 = undefined;
    if (ex == 0) {
        e = -1074;
    } else {
        e = ex - 1075;
        m |= @as(u64, 1) << 52;
    }
    var b: Big = .{};
    if (e >= 0) {
        b.set(m);
        b.shl(@intCast(e));
        const k = b.toDec(dg.d[0..]);
        dg.n = k;
        dg.p = k;
        if (k == 0) {
            dg.d[0] = '0';
            dg.n = 1;
            dg.p = 1;
        }
        return;
    }
    const k: u32 = @intCast(-e);
    const ip: u64 = if (k < 64) m >> @intCast(k) else 0;
    const fp: u64 = if (k < 64) m & ((@as(u64, 1) << @intCast(k)) - 1) else m;
    // integer part
    var ib: Big = .{};
    ib.set(ip);
    var ilen = ib.toDec(dg.d[0..]);
    if (ilen == 0) {
        dg.d[0] = '0';
        ilen = 1;
    }
    dg.p = ilen;
    // fraction: fp / 2^k = fp * 5^k / 10^k: k digits
    b.set(fp);
    var r = k;
    while (r >= 13) : (r -= 13) b.mulSmall(1220703125);
    var f5: u32 = 1;
    while (r > 0) : (r -= 1) f5 *= 5;
    b.mulSmall(f5);
    var fd: [1200]u8 = undefined;
    const fl = b.toDec(fd[0..]);
    const lead = k - @as(u32, @intCast(fl));
    var t = ilen;
    for (0..lead) |_| {
        dg.d[t] = '0';
        t += 1;
    }
    for (0..fl) |q| {
        dg.d[t] = fd[q];
        t += 1;
    }
    // drop trailing zeros (they never affect rounding)
    while (t > ilen and dg.d[t - 1] == '0') t -= 1;
    dg.n = t;
}

/// round d[0..n] to its first keep digits, half to even on the exact value; returns true if the carry
/// ran off the front (all nines: the caller prepends a 1). The kept digits are left in d[0..keep].
fn roundDigits(d: []u8, n: usize, keep: usize) bool {
    if (keep >= n) {
        for (n..keep) |k| d[k] = '0';
        return false;
    }
    const next = d[keep];
    var up = false;
    if (next > '5') {
        up = true;
    } else if (next == '5') {
        var rest = false;
        for (keep + 1..n) |k| {
            if (d[k] != '0') {
                rest = true;
                break;
            }
        }
        if (rest) {
            up = true;
        } else {
            up = keep > 0 and (d[keep - 1] - '0') % 2 == 1;
        }
    }
    if (!up) return false;
    var k = keep;
    while (k > 0) {
        k -= 1;
        if (d[k] == '9') {
            d[k] = '0';
        } else {
            d[k] += 1;
            return false;
        }
    }
    return true;
}

/// %.{prec}f of a positive finite value
fn fixedDigits(o: *Out, a: f64, prec: usize, alt: bool) void {
    var dg: Digits = .{};
    exactDigits(a, &dg);
    var keep = dg.p + prec;
    var w: [1700]u8 = undefined;
    @memcpy(w[0..dg.n], dg.d[0..dg.n]);
    var start: usize = 0;
    if (keep > w.len - 2) keep = w.len - 2;
    var buf2: [1701]u8 = undefined;
    var dd: []u8 = w[0..];
    var p = dg.p;
    if (roundDigits(&w, dg.n, keep)) {
        buf2[0] = '1';
        @memcpy(buf2[1 .. keep + 1], w[0..keep]);
        dd = buf2[0..];
        p += 1;
        keep += 1;
    }
    // strip a leading zero of the integer part only if it is the "0" placeholder and more digits exist
    _ = &start;
    o.puts(dd[0..p]);
    if (prec > 0 or alt) o.put('.');
    o.puts(dd[p..keep]);
}

/// the digits of a positive finite value rounded to sig significant digits, and its decimal exponent
fn expRaw(a: f64, sig: usize, res: []u8) i32 {
    var dg: Digits = .{};
    exactDigits(a, &dg);
    var f: usize = 0;
    while (f < dg.n and dg.d[f] == '0') f += 1;
    var x: i32 = @as(i32, @intCast(dg.p)) - 1 - @as(i32, @intCast(f));
    const n = dg.n - f;
    var w: [1700]u8 = undefined;
    @memcpy(w[0..n], dg.d[f..dg.n]);
    if (roundDigits(&w, n, sig)) {
        res[0] = '1';
        for (1..sig) |k| res[k] = '0';
        x += 1;
    } else {
        @memcpy(res[0..sig], w[0..sig]);
    }
    return x;
}

fn expDigits(o: *Out, a: f64, prec: usize, alt: bool, upper: bool) void {
    var d: [1700]u8 = undefined;
    var x: i32 = 0;
    if (a == 0) {
        for (0..prec + 1) |k| d[k] = '0';
    } else {
        x = expRaw(a, prec + 1, &d);
    }
    o.put(d[0]);
    if (prec > 0) {
        o.put('.');
        o.puts(d[1 .. prec + 1]);
    } else if (alt) o.put('.');
    o.put(if (upper) 'E' else 'e');
    if (x < 0) {
        o.put('-');
        x = -x;
    } else o.put('+');
    var tmp: [12]u8 = undefined;
    const xs = std.fmt.bufPrint(&tmp, "{d}", .{x}) catch unreachable;
    if (x < 10) o.put('0');
    o.puts(xs);
}

fn formatFloat(o: *Out, a: f64, conv: u8, prec: usize, alt: bool) void {
    const lc = conv | 0x20;
    if (lc == 'f') return fixedDigits(o, a, prec, alt);
    if (lc == 'e') return expDigits(o, a, prec, alt, conv == 'E');
    const P: usize = if (prec == 0) 1 else prec;
    var X: i32 = 0;
    if (a != 0) {
        var d: [1700]u8 = undefined;
        X = expRaw(a, P, &d);
    }
    var sub: Out = .{ .buf = &([_]u8{0} ** 0) };
    var sb: [512]u8 = undefined;
    sub.buf = &sb;
    defer sub.deinit();
    if (alt and X == @as(i32, @intCast(P)) and P <= 22 and @floor(a) < std.math.pow(f64, 10, @floatFromInt(P))) {
        // glibc's %#g when the number has P digits before the point and rounding carries into a new one (999999.5
        // with %#g): it chooses the fixed style from the exponent before rounding, then on the carry switches to
        // the exponential style without fraction digits, so "1.e+06" where the C standard asks for "1.00000e+06"
        sub.puts("1.");
        sub.put(if (conv == 'G') 'E' else 'e');
        var eb: [8]u8 = undefined;
        sub.puts(std.fmt.bufPrint(&eb, "+{d:0>2}", .{@as(u32, @intCast(X))}) catch unreachable);
    } else if (@as(i32, @intCast(P)) > X and X >= -4) {
        fixedDigits(&sub, a, @intCast(@as(i32, @intCast(P)) - 1 - X), alt);
    } else {
        expDigits(&sub, a, P - 1, alt, conv == 'G');
    }
    var r = sub.buf[0..sub.n];
    if (!alt) {
        var ep: usize = r.len;
        for (r, 0..) |c, k| {
            if (c == 'e' or c == 'E') {
                ep = k;
                break;
            }
        }
        var mant = r[0..ep];
        const ex = r[ep..];
        var has_point = false;
        for (mant) |c| {
            if (c == '.') has_point = true;
        }
        if (has_point) {
            var e = mant.len;
            while (e > 0 and mant[e - 1] == '0') e -= 1;
            if (e > 0 and mant[e - 1] == '.') e -= 1;
            mant = mant[0..e];
        }
        o.puts(mant);
        o.puts(ex);
        return;
    }
    r = sub.buf[0..sub.n];
    o.puts(r);
}

fn format(o: *Out, fmt: [*c]i8, args: []const Arg) void {
    var k: usize = 0;
    var ai: usize = 0;
    const f: [*c]u8 = @ptrCast(fmt);
    while (f[k] != 0) {
        if (f[k] != '%') {
            o.put(f[k]);
            k += 1;
            continue;
        }
        k += 1;
        if (f[k] == '%') {
            o.put('%');
            k += 1;
            continue;
        }
        var left = false;
        var plus = false;
        var space = false;
        var alt = false;
        var zero = false;
        while (true) : (k += 1) {
            switch (f[k]) {
                '-' => left = true,
                '+' => plus = true,
                ' ' => space = true,
                '#' => alt = true,
                '0' => zero = true,
                else => break,
            }
        }
        var width: usize = 0;
        var prec: isize = -1;
        if (f[k] == '*') {
            const w = argLong(args[ai]).v;
            ai += 1;
            if (w < 0) {
                left = true;
                width = @intCast(-w);
            } else width = @intCast(w);
            k += 1;
        } else {
            while (f[k] >= '0' and f[k] <= '9') : (k += 1) width = width * 10 + (f[k] - '0');
        }
        if (f[k] == '.') {
            k += 1;
            prec = 0;
            if (f[k] == '*') {
                const pv = argLong(args[ai]).v;
                ai += 1;
                prec = if (pv < 0) -1 else @intCast(pv);
                k += 1;
            } else {
                while (f[k] >= '0' and f[k] <= '9') : (k += 1) prec = prec * 10 + (f[k] - '0');
            }
        }
        var hmod: u8 = 0;
        while (f[k] == 'l' or f[k] == 'h' or f[k] == 'L' or f[k] == 'z' or f[k] == 'j' or f[k] == 't' or f[k] == 'q') : (k += 1) {
            if (f[k] == 'h') hmod += 1;
        }
        const conv = f[k];
        k += 1;
        var sign: []const u8 = "";
        var prefix: []const u8 = "";
        var bodybuf: [1800]u8 = undefined;
        var body: Out = .{ .buf = &bodybuf };
        defer body.deinit();
        var numeric = true;
        switch (conv) {
            'd', 'i' => {
                var v = argLong(args[ai]).v;
                ai += 1;
                // %hd and %hhd print the argument converted to short or signed char, as glibc does
                if (hmod == 1) v = @as(i16, @truncate(v)) else if (hmod >= 2) v = @as(i8, @truncate(v));
                if (v < 0) sign = "-" else if (plus) sign = "+" else if (space) sign = " ";
                const u: u64 = if (v < 0) @as(u64, @bitCast(-%v)) else @intCast(v);
                intBody(&body, u, 10, false, prec);
                if (prec >= 0) zero = false;
            },
            'u', 'x', 'X', 'o' => {
                const a = argLong(args[ai]);
                ai += 1;
                var u: u64 = @bitCast(a.v);
                if (a.int32) u &= 0xFFFFFFFF;
                if (hmod == 1) u &= 0xFFFF else if (hmod >= 2) u &= 0xFF;
                const base: u64 = switch (conv) {
                    'u' => 10,
                    'o' => 8,
                    else => 16,
                };
                intBody(&body, u, base, conv == 'X', prec);
                if (prec >= 0) zero = false;
                // the # flag: 0x / 0X before a nonzero hexadecimal number, a leading 0 on an octal one
                if (alt and conv == 'o' and (body.n == 0 or body.buf[0] != '0')) {
                    body.put('0');
                    std.mem.rotate(u8, body.buf[0..body.n], body.n - 1);
                } else if (alt and u != 0 and (conv == 'x' or conv == 'X')) prefix = if (conv == 'x') "0x" else "0X";
            },
            'c' => {
                numeric = false;
                const v = argLong(args[ai]).v;
                ai += 1;
                body.put(@truncate(@as(u64, @bitCast(v))));
            },
            's' => {
                numeric = false;
                const p = args[ai].str;
                ai += 1;
                // a null pointer prints as (null), or as nothing when the precision is less than 6 (glibc)
                var x: []const u8 = if (prec >= 0 and prec < 6) "" else "(null)";
                if (p != null) x = bytes(p);
                if (prec >= 0 and x.len > @as(usize, @intCast(prec))) x = x[0..@intCast(prec)];
                body.puts(x);
            },
            'f', 'F', 'e', 'E', 'g', 'G' => {
                const v = argDouble(args[ai]);
                ai += 1;
                const pr: usize = if (prec < 0) 6 else @intCast(prec);
                if (std.math.signbit(v)) sign = "-" else if (plus) sign = "+" else if (space) sign = " ";
                if (std.math.isNan(v) or std.math.isInf(v)) {
                    const upper = conv == 'F' or conv == 'E' or conv == 'G';
                    if (std.math.isNan(v)) body.puts(if (upper) "NAN" else "nan") else body.puts(if (upper) "INF" else "inf");
                    zero = false;
                } else {
                    formatFloat(&body, @abs(v), conv, pr, alt);
                }
            },
            'a', 'A' => {
                const v = argDouble(args[ai]);
                ai += 1;
                if (std.math.signbit(v)) sign = "-" else if (plus) sign = "+" else if (space) sign = " ";
                if (std.math.isNan(v) or std.math.isInf(v)) {
                    body.puts(if (std.math.isNan(v)) "nan" else "inf");
                    zero = false;
                } else {
                    hexFloat(&body, @abs(v), prec, alt);
                    prefix = if (conv == 'A') "0X" else "0x";
                }
                if (conv == 'A') {
                    for (body.buf[0..body.n]) |*ch| ch.* = std.ascii.toUpper(ch.*);
                }
            },
            else => @panic("printf conversion"),
        }
        const n = sign.len + prefix.len + body.n;
        if (n >= width) {
            o.puts(sign);
            o.puts(prefix);
            o.puts(body.buf[0..body.n]);
        } else if (left) {
            o.puts(sign);
            o.puts(prefix);
            o.puts(body.buf[0..body.n]);
            o.pad(' ', width - n);
        } else if (zero and numeric) {
            o.puts(sign);
            o.puts(prefix);
            o.pad('0', width - n);
            o.puts(body.buf[0..body.n]);
        } else {
            o.pad(' ', width - n);
            o.puts(sign);
            o.puts(prefix);
            o.puts(body.buf[0..body.n]);
        }
    }
}

fn intBody(o: *Out, uval: u64, base: u64, upper: bool, prec: isize) void {
    var tmp: [70]u8 = undefined;
    var t: usize = 0;
    var u = uval;
    const digs = if (upper) "0123456789ABCDEF" else "0123456789abcdef";
    while (u != 0) {
        tmp[t] = digs[@intCast(u % base)];
        u /= base;
        t += 1;
    }
    if (prec < 0) {
        if (t == 0) {
            tmp[0] = '0';
            t = 1;
        }
    } else {
        while (t < @as(usize, @intCast(prec))) {
            tmp[t] = '0';
            t += 1;
        }
    }
    var k = t;
    while (k > 0) {
        k -= 1;
        o.put(tmp[k]);
    }
}

fn packArgs(args: anytype, dst: []Arg) []Arg {
    const n = @typeInfo(@TypeOf(args)).@"struct".fields.len;
    inline for (0..n) |k| dst[k] = parg(args[k]);
    return dst[0..n];
}


const BUFSZ = 1 << 16;

pub const FILE = extern struct {
    fd: i32 = -1,
    std: i32 = 0,
    eof: i32 = 0,
    append: i32 = 0,
    pos: i64 = 0,
    wpos: i64 = 0,
    wlen: i64 = 0,
    rstart: i64 = 0,
    rlen: i64 = 0,
    wbuf: [*c]u8 = null,
    rbuf: [*c]u8 = null,
    err: i32 = 0,
    rerr: i32 = 0,
    /// a read found no more data: end-of-file, or after a failed read (a directory) an error
    pub fn readFailed(self: *FILE) void {
        if (self.rerr != 0) self.err = 1 else self.eof = 1;
    }
    pub fn writeBytes(self: *FILE, b: []const u8) E!void {
        fwriteBytes(@ptrCast(self), b);
    }
    pub fn readBytes(self: *FILE, dst: []u8) usize {
        return readBytesF(self, dst);
    }
};

var stdout_file: FILE = .{ .fd = 1, .std = 1 };
pub var stdout: [*c]FILE = &stdout_file;
pub var stderr: [*c]FILE = &stdout_file;

fn die(msg: []const u8) noreturn {
    _ = write(2, msg.ptr, msg.len);
    std.process.exit(3);
}

fn writeAll(f: *FILE, b: []const u8, at: i64) void {
    var done: usize = 0;
    while (done < b.len) {
        const r = if (f.std != 0) write(f.fd, b.ptr + done, b.len - done) else pwrite(f.fd, b.ptr + done, b.len - done, at + @as(i64, @intCast(done)));
        if (r <= 0) die("write error\n");
        done += @intCast(r);
    }
}

fn flushW(f: *FILE) void {
    if (f.wlen == 0) return;
    writeAll(f, f.wbuf[0..@intCast(f.wlen)], f.wpos);
    f.wlen = 0;
}

fn fwriteBytes(fp: [*c]FILE, src: []const u8) void {
    const f: *FILE = @ptrCast(fp);
    const n: i64 = @intCast(src.len);
    f.rlen = 0;
    if (f.wbuf == null) {
        const b = gpa.alloc(u8, BUFSZ) catch die("out of memory\n");
        f.wbuf = b.ptr;
    }
    if (f.append != 0 and f.std == 0) {
        flushW(f);
        f.pos = fsize(f);
    }
    if (f.wlen > 0 and f.pos != f.wpos + f.wlen) flushW(f);
    if (f.wlen == 0) f.wpos = f.pos;
    if (f.wlen + n > BUFSZ) {
        flushW(f);
        if (n > BUFSZ) {
            writeAll(f, src, f.pos);
            f.pos += n;
            return;
        }
        f.wpos = f.pos;
    }
    @memcpy(f.wbuf[@intCast(f.wlen)..@intCast(f.wlen + n)], src);
    f.wlen += n;
    f.pos += n;
}

fn readBytesF(f: *FILE, dst: []u8) usize {
    flushW(f);
    var got: usize = 0;
    while (got < dst.len) {
        if (f.rlen > 0 and f.pos >= f.rstart and f.pos < f.rstart + f.rlen) {
            const a: usize = @intCast(f.pos - f.rstart);
            const m = @min(dst.len - got, @as(usize, @intCast(f.rlen)) - a);
            @memcpy(dst[got .. got + m], f.rbuf[a .. a + m]);
            got += m;
            f.pos += @intCast(m);
            continue;
        }
        if (f.rbuf == null) {
            const b = gpa.alloc(u8, BUFSZ) catch die("out of memory\n");
            f.rbuf = b.ptr;
        }
        f.rstart = f.pos;
        const r = pread(f.fd, f.rbuf, BUFSZ, f.pos);
        if (r < 0) f.rerr = 1;
        f.rlen = if (r > 0) r else 0;
        if (r <= 0) break;
    }
    return got;
}

fn getc(f: *FILE) i32 {
    if (f.wlen == 0 and f.rlen > 0 and f.pos >= f.rstart and f.pos < f.rstart + f.rlen) {
        const c = f.rbuf[@intCast(f.pos - f.rstart)];
        f.pos += 1;
        return c;
    }
    var t: [1]u8 = undefined;
    if (readBytesF(f, &t) == 1) return t[0];
    return -1;
}

fn fsize(f: *FILE) i64 {
    flushW(f);
    return lseek(f.fd, 0, 2);
}

fn crtFopen(name: [*c]i8, mode: [*c]i8) [*c]FILE {
    var m: [8]u8 = undefined;
    var ml: usize = 0;
    var k: usize = 0;
    while (mode[k] != 0 and ml < 8) : (k += 1) {
        const c: u8 = @bitCast(mode[k]);
        if (c != 'b' and c != 't') {
            m[ml] = c;
            ml += 1;
        }
    }
    if (ml == 0) return null;
    const plus = ml > 1 and m[1] == '+';
    var flags: c_int = 0;
    switch (m[0]) {
        'r' => flags = if (plus) O_RDWR else O_RDONLY,
        'w' => flags = (if (plus) O_RDWR else O_WRONLY) | O_CREAT | O_TRUNC,
        'a' => flags = (if (plus) O_RDWR else O_WRONLY) | O_CREAT | O_APPEND,
        else => return null,
    }
    const fd = open(@ptrCast(name), flags, @as(c_uint, 0o666));
    if (fd < 0) return null;
    const f = gpa.create(FILE) catch die("out of memory\n");
    f.* = .{ .fd = fd };
    if (m[0] == 'a') {
        f.append = 1;
        f.pos = lseek(fd, 0, 2);
    }
    return f;
}

fn crtFclose(fp: [*c]FILE) i32 {
    if (fp == null) return -1;
    const f: *FILE = @ptrCast(fp);
    flushW(f);
    if (f.std != 0) return 0;
    const r = close(f.fd);
    if (f.wbuf != null) gpa.free(f.wbuf[0..BUFSZ]);
    if (f.rbuf != null) gpa.free(f.rbuf[0..BUFSZ]);
    gpa.destroy(f);
    return if (r == 0) 0 else -1;
}

pub fn fflush(fp: [*c]FILE) i32 {
    if (fp != null) flushW(@ptrCast(fp));
    return 0;
}

pub fn feof(fp: [*c]FILE) i32 {
    return if (fp.*.eof != 0) 1 else 0;
}

fn crtRewind(fp: [*c]FILE) void {
    const f: *FILE = @ptrCast(fp);
    flushW(f);
    f.pos = 0;
    f.eof = 0;
}

fn crtFseek(fp: [*c]FILE, off: i64, whence: i32) i32 {
    const f: *FILE = @ptrCast(fp);
    flushW(f);
    var p = off;
    if (whence == 1) p = f.pos + off else if (whence == 2) p = fsize(f) + off;
    if (p < 0) return -1;
    f.pos = p;
    f.eof = 0;
    return 0;
}

pub fn fseeko(fp: [*c]FILE, off: i64, whence: i32) i32 {
    return crtFseek(fp, off, whence);
}

pub fn ftell(fp: [*c]FILE) i64 {
    return fp.*.pos;
}

fn crtFgets(b: [*c]i8, n: i32, fp: [*c]FILE) [*c]i8 {
    const f: *FILE = @ptrCast(fp);
    var m: usize = 0;
    while (@as(i64, @intCast(m)) < @as(i64, n) - 1) {
        const c = getc(f);
        if (c < 0) {
            f.readFailed();
            break;
        }
        b[m] = @bitCast(@as(u8, @intCast(c)));
        m += 1;
        if (c == '\n') break;
    }
    if (m == 0) return null;
    b[m] = 0;
    return b;
}

/// fread: the bytes go straight into the caller's memory, as C's do (a short read fills part of an item)
pub fn fread(p: ?*anyopaque, size: u64, n: u64, fp: [*c]FILE) u64 {
    const f: *FILE = @ptrCast(fp);
    const total: usize = @intCast(size * n);
    if (total == 0) return 0;
    const dst: [*]u8 = @ptrCast(p.?);
    const got = readBytesF(f, dst[0..total]);
    if (got < total) f.readFailed();
    return got / size;
}

pub fn fwrite(p: ?*anyopaque, size: u64, n: u64, fp: [*c]FILE) u64 {
    const total: usize = @intCast(size * n);
    if (total == 0) return 0;
    const src: [*]const u8 = @ptrCast(p.?);
    fwriteBytes(fp, src[0..total]);
    return n;
}

fn crtRemove(name: [*c]i8) i32 {
    return if (unlink(@ptrCast(name)) == 0) 0 else -1;
}

var rnd_state: u64 = 0;

/// mkstemp: six random characters, created exclusively (the descriptor is left open, as EPA leaves it)
pub fn mkstemp(tmpl: [*c]i8) i32 {
    const chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    if (rnd_state == 0) rnd_state = (@as(u64, @bitCast(c_time(null))) << 20) ^ @as(u64, @intCast(getpid())) | 1;
    const n = slen(tmpl);
    if (n < 6) return -1;
    var t: usize = 0;
    while (t < 1000) : (t += 1) {
        for (n - 6..n) |i| {
            rnd_state ^= rnd_state << 13;
            rnd_state ^= rnd_state >> 7;
            rnd_state ^= rnd_state << 17;
            tmpl[i] = @intCast(chars[@intCast(rnd_state % chars.len)]);
        }
        const fd = open(@ptrCast(tmpl), O_RDWR | O_CREAT | O_EXCL, @as(c_uint, 0o600));
        if (fd >= 0) return fd;
    }
    return -1;
}

/// realpath: the current directory joined to a relative path, with "." and ".." removed
pub fn realpath(path: [*c]i8, resolved: [*c]i8) [*c]i8 {
    var buf: [8192]u8 = undefined;
    var n: usize = 0;
    const p = bytes(path);
    if (p.len == 0 or p[0] != '/') {
        const cwd = getcwd(&buf, buf.len) orelse return null;
        _ = cwd;
        n = std.mem.indexOfScalar(u8, &buf, 0) orelse return null;
    }
    // components
    var res: [8192]u8 = undefined;
    var on: usize = 0;
    var src: [16384]u8 = undefined;
    var sl: usize = 0;
    @memcpy(src[0..n], buf[0..n]);
    sl = n;
    src[sl] = '/';
    sl += 1;
    @memcpy(src[sl .. sl + p.len], p);
    sl += p.len;
    var it = std.mem.splitScalar(u8, src[0..sl], '/');
    while (it.next()) |comp| {
        if (comp.len == 0 or std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) {
            while (on > 0 and res[on - 1] != '/') on -= 1;
            if (on > 0) on -= 1;
            continue;
        }
        res[on] = '/';
        on += 1;
        @memcpy(res[on .. on + comp.len], comp);
        on += comp.len;
    }
    if (on == 0) {
        res[0] = '/';
        on = 1;
    }
    for (0..on) |k| resolved[k] = @bitCast(res[k]);
    resolved[on] = 0;
    return resolved;
}

// ================================================================ time
pub fn time(t: [*c]i64) i64 {
    const v = c_time(null);
    if (t != null) t.* = v;
    return v;
}

pub fn difftime(a: i64, b: i64) f64 {
    return @as(f64, @floatFromInt(a)) - @as(f64, @floatFromInt(b));
}

var ctime_buf: [32]i8 = undefined;

/// ctime: "Www Mmm dd hh:mm:ss yyyy\n" (UTC; only the report's clock lines use it)
const Tm = extern struct { sec: c_int, min: c_int, hour: c_int, mday: c_int, mon: c_int, year: c_int, wday: c_int, yday: c_int, isdst: c_int, gmtoff: c_long, zone: ?[*:0]const u8 };
extern "c" fn localtime_r(t: *const i64, tm: *Tm) ?*Tm;

/// ctime: the local time (glibc's localtime_r, which reads TZ and the zone files) in ctime's fixed layout
fn crtCtime(t: [*c]i64) [*c]i8 {
    var tm: Tm = undefined;
    if (localtime_r(@ptrCast(t), &tm) == null) return null;
    const wn = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const mn = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    var b: [64]u8 = undefined;
    const r = std.fmt.bufPrint(&b, "{s} {s} {d:>2} {d:0>2}:{d:0>2}:{d:0>2} {d}\n", .{
        wn[@intCast(tm.wday)], mn[@intCast(tm.mon)], @as(u32, @intCast(tm.mday)), @as(u32, @intCast(tm.hour)),
        @as(u32, @intCast(tm.min)), @as(u32, @intCast(tm.sec)), @as(i64, tm.year) + 1900,
    }) catch unreachable;
    for (r, 0..) |c, k| ctime_buf[k] = @bitCast(c);
    ctime_buf[r.len] = 0;
    return &ctime_buf;
}

/// write a Zig string to standard output at once (for the runner)
pub fn conout(x: []const u8) void {
    fwriteBytes(stdout, x);
    flushW(@ptrCast(stdout));
}

// ================================================================ additions for the SWMM6 engine
fn bytes(p: [*c]const i8) []const u8 {
    const q: [*]const u8 = @ptrCast(p);
    return q[0..slenC(p)];
}

fn slenC(p: [*c]const i8) usize {
    var n: usize = 0;
    while (p[n] != 0) n += 1;
    return n;
}

/// strlen of the engine's char*
pub fn slen(p: ?[*]u8) usize {
    var n: usize = 0;
    while (p.?[n] != 0) n += 1;
    return n;
}

inline fn cp(p: ?[*]u8) [*c]i8 {
    return @ptrCast(p);
}

/// glibc's %a of a non-negative finite double: 0x1.hhhp+e with trailing zero digits dropped (0x0p+0 for zero,
/// 0x0.hhhp-1022 for a subnormal); with a precision, rounded half to even (cs/runtime/CRuntime.cs HexFloat).
fn hexFloat(o: *Out, a: f64, prec: isize, alt: bool) void {
    const bits: u64 = @bitCast(a);
    const ex: i32 = @intCast((bits >> 52) & 0x7FF);
    const man: u64 = bits & 0xFFFFFFFFFFFFF;
    var lead: u64 = 1;
    var e: i32 = undefined;
    if (ex == 0) {
        lead = 0;
        e = if (man == 0) 0 else -1022;
    } else e = ex - 1023;
    var digits: [32]u8 = undefined;
    var nd: usize = 0;
    const hx = "0123456789abcdef";
    if (prec < 0) {
        var k: usize = 0;
        while (k < 13) : (k += 1) digits[k] = hx[@intCast((man >> @intCast(48 - 4 * k)) & 15)];
        nd = 13;
        while (nd > 0 and digits[nd - 1] == '0') nd -= 1;
    } else if (prec < 13) {
        const p: u6 = @intCast(prec);
        const drop: u6 = @intCast((13 - @as(u32, p)) * 4);
        var keep = man >> drop;
        const rem = man & ((@as(u64, 1) << drop) - 1);
        const half = @as(u64, 1) << (drop - 1);
        if (rem > half or (rem == half and (keep & 1) == 1)) keep += 1;
        if (p == 0) {
            // no hexadecimal digits kept: the leading digit itself is rounded, half to even (0x1.8p+0 -> 0x2p+0)
            keep = 0;
            if (rem > half or (rem == half and (lead & 1) == 1)) lead += 1;
        } else if ((keep >> (@as(u6, p) * 4)) != 0) {
            keep &= (@as(u64, 1) << (@as(u6, p) * 4)) - 1;
            lead += 1;
        }
        var k: usize = 0;
        while (k < p) : (k += 1) digits[k] = hx[@intCast((keep >> @intCast(4 * (p - 1 - k))) & 15)];
        nd = p;
    } else {
        var k: usize = 0;
        while (k < 13) : (k += 1) digits[k] = hx[@intCast((man >> @intCast(48 - 4 * k)) & 15)];
        nd = 13;
        while (nd < @as(usize, @intCast(prec)) and nd < 32) : (nd += 1) digits[nd] = '0';
    }
    o.put(@intCast('0' + lead));
    if (nd > 0 or alt) o.put('.');
    o.puts(digits[0..nd]);
    o.put('p');
    o.put(if (e >= 0) '+' else '-');
    var eb: [8]u8 = undefined;
    const es = std.fmt.bufPrint(&eb, "{d}", .{@abs(e)}) catch unreachable;
    o.puts(es);
}

/// printf into buf (at most buf.len bytes are kept); returns the formatted length
pub fn formatInto(buf: []u8, comptime fmt: []const u8, args: anytype) usize {
    var a: [@typeInfo(@TypeOf(args)).@"struct".fields.len + 1]Arg = undefined;
    const as = packArgs(args, &a);
    var sb: [1024]u8 = undefined;
    var o: Out = .{ .buf = &sb };
    defer o.deinit();
    format(&o, @ptrCast(@constCast(fmt.ptr)), as);
    const m = @min(o.n, buf.len);
    @memcpy(buf[0..m], o.buf[0..m]);
    return o.n;
}

fn formatOut(o: *Out, fmt: ?[*]u8, args: anytype) void {
    var a: [@typeInfo(@TypeOf(args)).@"struct".fields.len + 1]Arg = undefined;
    const as = packArgs(args, &a);
    format(o, cp(fmt), as);
}

// ---------------------------------------------------------------- strtod's ERANGE
/// Whether the last strtodRange would have set errno to ERANGE in glibc: an overflow to +-inf, a nonzero number
/// that became zero, or a result that is tiny (below DBL_MIN after rounding to 53 bits) and inexact.
pub var erange: bool = false;

/// strtod with glibc's ERANGE (std::stod throws out_of_range on it).
pub fn strtodRange(p: ?[*]u8, end: *?[*]u8) f64 {
    var sc: Scan = .{ .v = 0, .end = 0, .text_ok = false };
    scanDouble(cp(p), -1, true, &sc);
    erange = false;
    if (sc.end < 0) {
        end.* = p;
        return 0;
    }
    end.* = rt.padd(p, sc.end);
    erange = rangeOf(cp(p), sc);
    return sc.v;
}

fn rangeOf(p: [*c]const i8, sc: Scan) bool {
    const v = sc.v;
    if (std.math.isNan(v)) return false;
    if (std.math.isInf(v)) {
        // an "inf" spelled out is no overflow
        var i: usize = 0;
        while (isSpace(p[i])) i += 1;
        if (p[i] == '+' or p[i] == '-') i += 1;
        return low(p[i]) != 'i';
    }
    if (@abs(v) > 2.2250738585072014e-308) return false;
    if (!sc.text_ok) return false;
    var t = sc.text[0..sc.tlen];
    if (t.len > 0 and t[0] == '-') t = t[1..];
    if (t.len > 1 and t[0] == '0' and (t[1] == 'x' or t[1] == 'X')) {
        // a hexadecimal number: zero or infinite from a nonzero mantissa
        var nz = false;
        for (t[2..]) |c| {
            if (c == 'p' or c == 'P') break;
            if (c != '0' and c != '.') nz = true;
        }
        return nz and v == 0;
    }
    return decRange(t, @abs(v));
}

/// glibc strtod's ERANGE for a decimal text whose correctly rounded value is av (cs/runtime/CRuntime.cs DecRange)
fn decRange(txt: []const u8, av: f64) bool {
    const BigI = std.math.big.int.Managed;
    var d = BigI.init(gpa) catch unreachable;
    defer d.deinit();
    var e10: i64 = 0;
    var k: usize = 0;
    var nd: i64 = 0;
    var lead = true;
    while (k < txt.len and txt[k] >= '0' and txt[k] <= '9') : (k += 1) {
        d.mul(&d, &(BigI.initSet(gpa, 10) catch unreachable)) catch unreachable;
        d.addScalar(&d, txt[k] - '0') catch unreachable;
        if (!(lead and txt[k] == '0')) {
            lead = false;
            nd += 1;
        }
    }
    if (k < txt.len and txt[k] == '.') {
        k += 1;
        while (k < txt.len and txt[k] >= '0' and txt[k] <= '9') : (k += 1) {
            d.mul(&d, &(BigI.initSet(gpa, 10) catch unreachable)) catch unreachable;
            d.addScalar(&d, txt[k] - '0') catch unreachable;
            e10 -= 1;
            if (!(lead and txt[k] == '0')) {
                lead = false;
                nd += 1;
            }
        }
    }
    if (d.eqlZero()) return false; // a zero is exact
    if (k < txt.len and (txt[k] == 'e' or txt[k] == 'E')) {
        k += 1;
        var en = false;
        if (k < txt.len and (txt[k] == '+' or txt[k] == '-')) {
            en = txt[k] == '-';
            k += 1;
        }
        var ex: i64 = 0;
        while (k < txt.len and txt[k] >= '0' and txt[k] <= '9') : (k += 1) ex = @min(ex * 10 + (txt[k] - '0'), 1000000000);
        e10 += if (en) -ex else ex;
    }
    // the number of digits of d (without leading zeros) plus e10
    const ndig: i64 = @intCast(d.toConst().sizeInBaseUpperBound(10));
    _ = ndig;
    if (nd + e10 < -340) return true; // below 1e-340: zero, and not exact
    if (e10 >= 0) return false;
    var p10 = BigI.initSet(gpa, 1) catch unreachable;
    defer p10.deinit();
    var ten = BigI.initSet(gpa, 10) catch unreachable;
    defer ten.deinit();
    var i: i64 = 0;
    while (i < -e10) : (i += 1) p10.mul(&p10, &ten) catch unreachable;
    // tiny after rounding: below 2^-1022 - 2^-1076, the midpoint under DBL_MIN of the 53-bit grid
    var lhs = BigI.init(gpa) catch unreachable;
    defer lhs.deinit();
    lhs.shiftLeft(&d, 1076) catch unreachable;
    var rhs = BigI.initSet(gpa, (@as(u64, 1) << 54) - 1) catch unreachable;
    defer rhs.deinit();
    rhs.mul(&rhs, &p10) catch unreachable;
    if (lhs.order(rhs) != .lt) return false;
    // inexact: not av itself, which is m * 2^-1074 for a subnormal (or DBL_MIN, or zero)
    var l2 = BigI.init(gpa) catch unreachable;
    defer l2.deinit();
    l2.shiftLeft(&d, 1074) catch unreachable;
    const m: u64 = @bitCast(av);
    var r2 = BigI.initSet(gpa, m) catch unreachable;
    defer r2.deinit();
    r2.mul(&r2, &p10) catch unreachable;
    return l2.order(r2) != .eq;
}

/// strtof of a number text, rounded once from the text as glibc's strtof does
fn strtofText(t: []const u8, v: f64) f32 {
    if (std.math.isNan(v) or std.math.isInf(v)) return @floatCast(v);
    var buf: [600]u8 = undefined;
    if (t.len + 3 > buf.len) return @floatCast(v);
    var n: usize = 0;
    var k: usize = 0;
    var neg = false;
    if (k < t.len and (t[k] == '-' or t[k] == '+')) {
        neg = t[k] == '-';
        k += 1;
    }
    if (k + 1 < t.len and t[k] == '0' and (t[k + 1] == 'x' or t[k + 1] == 'X')) return @floatCast(v);
    if (k < t.len and t[k] == '.') {
        buf[n] = '0';
        n += 1;
    }
    while (k < t.len) : (k += 1) {
        const c = t[k];
        if ((c == 'e' or c == 'E') and (k + 1 >= t.len or !(t[k + 1] >= '0' and t[k + 1] <= '9') and !((t[k + 1] == '+' or t[k + 1] == '-') and k + 2 < t.len and t[k + 2] >= '0' and t[k + 2] <= '9'))) break;
        buf[n] = c;
        n += 1;
        if (c == '.' and (k + 1 >= t.len or !(t[k + 1] >= '0' and t[k + 1] <= '9'))) {
            buf[n] = '0';
            n += 1;
        }
    }
    const f = std.fmt.parseFloat(f32, buf[0..n]) catch return @floatCast(v);
    return if (neg) -f else f;
}

// ---------------------------------------------------------------- sscanf (cs/runtime/CRuntime.cs sscanf)
pub const SArg = union(enum) { i32_: *i32, i64_: *i64, u32_: *u32, u64_: *u64, i8_: *i8, f64_: *f64, f32_: *f32, str: ?[*]u8, none: void };

pub fn sarg(a: anytype) SArg {
    const P = @TypeOf(a);
    return switch (P) {
        *i32 => .{ .i32_ = a },
        *i64 => .{ .i64_ = a },
        *u32 => .{ .u32_ = a },
        *u64 => .{ .u64_ = a },
        *i8 => .{ .i8_ = a },
        *f64 => .{ .f64_ = a },
        *f32 => .{ .f32_ = a },
        ?[*]u8 => .{ .str = a },
        else => @compileError("sscanf target " ++ @typeName(P)),
    };
}

fn storeInt(a: SArg, v: i64) void {
    switch (a) {
        .i32_ => |p| p.* = @truncate(v),
        .i64_ => |p| p.* = v,
        .u32_ => |p| p.* = @truncate(@as(u64, @bitCast(v))),
        .u64_ => |p| p.* = @bitCast(v),
        .i8_ => |p| p.* = @truncate(v),
        else => @panic("sscanf integer target"),
    }
}

/// glibc's sscanf for the directives the engine uses: %d %i %u, %f %e %g %a (and capitals), %s, %c, %[...], %n
/// and %%, with * and widths and the h/l/L/z/j/t/q modifiers. It returns the number of assignments, or EOF (-1)
/// when the input ends before the first assignment.
pub fn sscanfImpl(s: ?[*]u8, fmt: ?[*]u8, args: []const SArg) i32 {
    const b = s.?;
    const f = fmt.?;
    var i: usize = 0;
    var k: usize = 0;
    var ai: usize = 0;
    var count: i32 = 0;
    while (f[k] != 0) {
        const fc = f[k];
        if (isSpace(fc)) {
            while (isSpace(f[k])) k += 1;
            while (isSpace(b[i])) i += 1;
            continue;
        }
        if (fc != '%') {
            if (b[i] == 0) return if (count == 0) -1 else count;
            if (b[i] != fc) return count;
            i += 1;
            k += 1;
            continue;
        }
        k += 1;
        var suppress = false;
        if (f[k] == '*') {
            suppress = true;
            k += 1;
        }
        var width: usize = 0;
        while (f[k] >= '0' and f[k] <= '9') : (k += 1) width = width * 10 + (f[k] - '0');
        var lmod: usize = 0;
        while (f[k] == 'l' or f[k] == 'h' or f[k] == 'L' or f[k] == 'z' or f[k] == 'j' or f[k] == 't' or f[k] == 'q') : (k += 1) {
            if (f[k] != 'h') lmod += 1;
        }
        const conv = f[k];
        k += 1;
        var set: [256]bool = [_]bool{false} ** 256;
        if (conv == '[') {
            var neg = false;
            if (f[k] == '^') {
                neg = true;
                k += 1;
            }
            var first = true;
            while (f[k] != 0 and (first or f[k] != ']')) {
                const c = f[k];
                if (c == '-' and !first and f[k + 1] != ']' and f[k + 1] != 0 and f[k - 1] <= f[k + 1]) {
                    var x: usize = f[k - 1];
                    while (x <= f[k + 1]) : (x += 1) set[x] = true;
                    k += 2;
                    first = false;
                    continue;
                }
                set[c] = true;
                k += 1;
                first = false;
            }
            if (f[k] == ']') k += 1;
            if (neg) {
                for (&set) |*x| x.* = !x.*;
                set[0] = false;
            }
        }
        if (conv != 'c' and conv != '[' and conv != 'n') {
            while (isSpace(b[i])) i += 1;
        }
        if (conv == 'n') {
            if (!suppress) {
                storeInt(args[ai], @intCast(i));
                ai += 1;
            }
            continue;
        }
        if (b[i] == 0) return if (count == 0) -1 else count;
        const w: usize = if (width > 0) width else 1 << 30;
        switch (conv) {
            '%' => {
                if (b[i] != '%') return count;
                i += 1;
            },
            'd', 'i', 'u' => {
                var j = i;
                const lim = i + w;
                var neg = false;
                if (j < lim and (b[j] == '+' or b[j] == '-')) {
                    neg = b[j] == '-';
                    j += 1;
                }
                const ds = j;
                var u: u64 = 0;
                var over = false;
                while (j < lim and b[j] >= '0' and b[j] <= '9') : (j += 1) {
                    const dd: u64 = b[j] - '0';
                    if (u > (std.math.maxInt(u64) - dd) / 10) over = true else u = u * 10 + dd;
                }
                if (j == ds) return count;
                i = j;
                var v: i64 = undefined;
                if (conv == 'u') {
                    // strtoul: the magnitude (ULONG_MAX when it does not fit), negated as an unsigned number
                    var m: u64 = if (over) std.math.maxInt(u64) else u;
                    if (neg and !over) m = 0 -% m;
                    v = @bitCast(if (lmod == 0) (m & 0xFFFFFFFF) else m);
                } else {
                    // strtol: clamped to long
                    if (over or u > @as(u64, std.math.maxInt(i64)) + @intFromBool(neg)) {
                        v = if (neg) std.math.minInt(i64) else std.math.maxInt(i64);
                    } else v = if (neg) -%@as(i64, @bitCast(u)) else @bitCast(u);
                }
                if (!suppress) {
                    storeInt(args[ai], if (lmod == 0) @as(i64, @as(i32, @truncate(v))) else v);
                    ai += 1;
                    count += 1;
                }
            },
            'f', 'e', 'g', 'E', 'G', 'a', 'A', 'F' => {
                var num: [512]u8 = undefined;
                var nlen: usize = 0;
                const e = scanFloat(b, i, width, &num, &nlen);
                if (e < 0) return count;
                i = @intCast(e);
                num[nlen] = 0;
                var sc: Scan = .{ .v = 0, .end = 0, .text_ok = false };
                scanDouble(@ptrCast(&num), -1, false, &sc);
                if (sc.end <= 0) return count;
                if (!suppress) {
                    switch (args[ai]) {
                        .f64_ => |p| p.* = sc.v,
                        .f32_ => |p| p.* = strtofText(num[0..@intCast(sc.end)], sc.v),
                        else => @panic("sscanf float target"),
                    }
                    ai += 1;
                    count += 1;
                }
            },
            's', '[' => {
                var j = i;
                var m: usize = 0;
                while (b[j] != 0 and m < w) {
                    const c = b[j];
                    if (if (conv == 's') isSpace(c) else !set[c]) break;
                    j += 1;
                    m += 1;
                }
                if (m == 0) return count;
                if (!suppress) {
                    const d = args[ai].str.?;
                    ai += 1;
                    @memcpy(d[0..m], b[i .. i + m]);
                    d[m] = 0;
                    count += 1;
                }
                i = j;
            },
            'c' => {
                const n: usize = if (width > 0) width else 1;
                var t: usize = 0;
                const a = if (suppress) SArg{ .none = {} } else args[ai];
                if (!suppress) ai += 1;
                while (t < n and b[i] != 0) : (t += 1) {
                    switch (a) {
                        .str => |d| d.?[t] = b[i],
                        .none => {},
                        else => if (t == 0) storeInt(a, @as(i8, @bitCast(b[i]))),
                    }
                    i += 1;
                }
                if (!suppress) count += 1;
            },
            else => @panic("sscanf conversion"),
        }
    }
    return count;
}

/// The scanner of glibc's vfscanf for a floating conversion at b[i]: the characters it takes (at most width, 0
/// for no limit) go to num; it returns the index after them, -1 for a matching failure. Like glibc, it reads one
/// character ahead and pushes back only that one ("1e" and "1e+" are taken), and a partial "infinity" or a bare
/// "0x" fails.
fn scanFloat(b: [*]u8, start: usize, width: usize, num: *[512]u8, nlen: *usize) isize {
    var left: isize = if (width == 0) -1 else @intCast(width);
    var p: usize = start;
    var n: usize = 0;
    const S = struct {
        fn inchar(bb: [*]u8, pp: *usize) i32 {
            if (bb[pp.*] != 0) {
                pp.* += 1;
                return bb[pp.* - 1];
            }
            return -1;
        }
    };
    var c = S.inchar(b, &p);
    if (left > 0) left -= 1;
    var got_sign: usize = 0;
    if (c == '-' or c == '+') {
        got_sign = 1;
        num[n] = @intCast(c);
        n += 1;
        if (left == 0) return -1;
        c = S.inchar(b, &p);
        if (c < 0) return -1;
        if (left > 0) left -= 1;
    }
    const expectFn = struct {
        fn f(bb: [*]u8, pp: *usize, lf: *isize, nm: *[512]u8, nn: *usize, ch: u8) bool {
            if (lf.* == 0) return false;
            const c2 = inchar2(bb, pp);
            if (c2 < 0 or low(c2) != ch) return false;
            if (lf.* > 0) lf.* -= 1;
            nm[nn.*] = @intCast(c2);
            nn.* += 1;
            return true;
        }
        fn inchar2(bb: [*]u8, pp: *usize) i32 {
            if (bb[pp.*] != 0) {
                pp.* += 1;
                return bb[pp.* - 1];
            }
            return -1;
        }
    }.f;
    if (low(c) == 'n') {
        num[n] = @intCast(c);
        n += 1;
        if (!expectFn(b, &p, &left, num, &n, 'a') or !expectFn(b, &p, &left, num, &n, 'n')) return -1;
        nlen.* = n;
        return @intCast(p);
    }
    if (low(c) == 'i') {
        num[n] = @intCast(c);
        n += 1;
        if (!expectFn(b, &p, &left, num, &n, 'n') or !expectFn(b, &p, &left, num, &n, 'f')) return -1;
        if (left != 0) {
            c = S.inchar(b, &p);
            if (c >= 0) {
                if (low(c) == 'i') {
                    if (left > 0) left -= 1;
                    num[n] = @intCast(c);
                    n += 1;
                    if (!expectFn(b, &p, &left, num, &n, 'n') or !expectFn(b, &p, &left, num, &n, 'i') or !expectFn(b, &p, &left, num, &n, 't') or !expectFn(b, &p, &left, num, &n, 'y')) return -1;
                } else p -= 1;
            }
        }
        nlen.* = n;
        return @intCast(p);
    }
    var exp_char: i32 = 'e';
    var hexa = false;
    var got_digit = false;
    var got_dot = false;
    var got_e = false;
    if (left != 0 and c == '0') {
        num[n] = @intCast(c);
        n += 1;
        c = S.inchar(b, &p);
        if (left > 0) left -= 1;
        if (left != 0 and low(c) == 'x') {
            num[n] = @intCast(c);
            n += 1;
            hexa = true;
            exp_char = 'p';
            c = S.inchar(b, &p);
            if (left > 0) left -= 1;
        } else got_digit = true;
    }
    while (n < 500) {
        if (c >= '0' and c <= '9') {
            num[n] = @intCast(c);
            n += 1;
            got_digit = true;
        } else if (!got_e and hexa and isHex(c)) {
            num[n] = @intCast(c);
            n += 1;
            got_digit = true;
        } else if (got_e and num[n - 1] == exp_char and (c == '-' or c == '+')) {
            num[n] = @intCast(c);
            n += 1;
        } else if (got_digit and !got_e and low(c) == exp_char) {
            num[n] = @intCast(exp_char);
            n += 1;
            got_e = true;
            got_dot = true;
        } else if (!got_dot and c == '.') {
            num[n] = @intCast(c);
            n += 1;
            got_dot = true;
        } else {
            if (c >= 0) p -= 1;
            break;
        }
        if (left == 0) break;
        c = S.inchar(b, &p);
        if (c < 0) break;
        if (left > 0) left -= 1;
    }
    if (n == got_sign or (hexa and n == 2 + got_sign)) return -1;
    nlen.* = n;
    return @intCast(p);
}

// ---------------------------------------------------------------- from_chars (libstdc++), strtol
fn fcResult(p: ?[*]u8, ec: i32) rt.FromCharsResult {
    return .{ .ptr = p, .ec = ec };
}

/// std::from_chars for double (chars_format::general), as libstdc++ has it: the value strtod reads from the same
/// characters, except that a sign other than '-', leading white space and a hexadecimal prefix are not read, and a
/// value too large or too small for a double is result_out_of_range (34) with the value left unchanged.
pub fn from_chars_d(first: ?[*]u8, last: ?[*]u8, v: *f64) E!rt.FromCharsResult {
    const n: usize = @intCast(rt.pdiff(last, first));
    var tmp = rt.gcSlice(u8, n + 2);
    if (n > 0) @memcpy(tmp[0..n], first.?[0..n]);
    const k: usize = if (tmp[0] == '-') 1 else 0;
    const c = tmp[k];
    const lc = if (c >= 'A' and c <= 'Z') c + 32 else c;
    if (!((c >= '0' and c <= '9') or c == '.' or lc == 'i' or lc == 'n')) return fcResult(first, 22);
    if (c == '0' and (tmp[k + 1] == 'x' or tmp[k + 1] == 'X')) tmp[k + 1] = 0;
    var sc: Scan = .{ .v = 0, .end = 0, .text_ok = false };
    scanDouble(@ptrCast(tmp.ptr), -1, false, &sc);
    if (sc.end <= 0) return fcResult(first, 22);
    const r = sc.v;
    const res = fcResult(rt.padd(first, sc.end), 0);
    if (std.math.isInf(r) and lc != 'i') return fcResult(res.ptr, 34);
    if (r == 0) {
        var j = k;
        while (j < @as(usize, @intCast(sc.end))) : (j += 1) {
            const d = tmp[j];
            if (d == 'e' or d == 'E') break;
            if (d >= '1' and d <= '9') return fcResult(res.ptr, 34);
        }
    }
    v.* = r;
    return res;
}

fn intChars(first: ?[*]u8, last: ?[*]u8, signed: bool, min: i128, max: i128, out: *i128) rt.FromCharsResult {
    const end: usize = @intCast(rt.pdiff(last, first));
    var i: usize = 0;
    var neg = false;
    const b = first.?;
    if (signed and i < end and b[i] == '-') {
        neg = true;
        i += 1;
    }
    const start = i;
    var r: i128 = 0;
    var big = false;
    while (i < end and b[i] >= '0' and b[i] <= '9') : (i += 1) {
        if (r > (std.math.maxInt(i128) / 20)) big = true else r = r * 10 + (b[i] - '0');
    }
    if (i == start) return fcResult(first, 22);
    if (neg) r = -r;
    if (big or r < min or r > max) return fcResult(rt.padd(first, i), 34);
    out.* = r;
    return fcResult(rt.padd(first, i), 0);
}

pub fn from_chars_i(first: ?[*]u8, last: ?[*]u8, v: *i32) E!rt.FromCharsResult {
    var r: i128 = 0;
    const res = intChars(first, last, true, std.math.minInt(i32), std.math.maxInt(i32), &r);
    if (res.ec == 0) v.* = @intCast(r);
    return res;
}

pub fn from_chars_l(first: ?[*]u8, last: ?[*]u8, v: *i64) E!rt.FromCharsResult {
    var r: i128 = 0;
    const res = intChars(first, last, true, std.math.minInt(i64), std.math.maxInt(i64), &r);
    if (res.ec == 0) v.* = @intCast(r);
    return res;
}

pub fn from_chars_u(first: ?[*]u8, last: ?[*]u8, v: *u32) E!rt.FromCharsResult {
    var r: i128 = 0;
    const res = intChars(first, last, false, 0, std.math.maxInt(u32), &r);
    if (res.ec == 0) v.* = @intCast(r);
    return res;
}

/// strtol(s, &end, base) for base 10 (the engine's only base): saturating at the long range
fn strtol(p: ?[*]u8, end: ?*?[*]u8) i64 {
    const b = p.?;
    var i: usize = 0;
    while (isSpace(b[i])) i += 1;
    var neg = false;
    if (b[i] == '+' or b[i] == '-') {
        neg = b[i] == '-';
        i += 1;
    }
    const st = i;
    var v: i64 = 0;
    var over = false;
    while (b[i] >= '0' and b[i] <= '9') : (i += 1) {
        const d: i64 = b[i] - '0';
        if (v > @divTrunc(std.math.maxInt(i64) - d, 10)) over = true else v = v * 10 + d;
    }
    if (i == st) {
        if (end) |e| e.* = p;
        return 0;
    }
    if (end) |e| e.* = rt.padd(p, i);
    if (over) return if (neg) std.math.minInt(i64) else std.math.maxInt(i64);
    return if (neg) -v else v;
}

// ---------------------------------------------------------------- char arrays with their length
/// A char array (char a[n]) is n bytes with its length in the 8 bytes before it, so that copying a whole member
/// array (memcpyBuf, CopyBuf) knows how many bytes it has, as the C# array does.
pub fn bufAlloc(n0: usize) ?[*]u8 {
    const n = @max(n0, 1);
    const m = rt.gcSlice(u8, n + 8);
    std.mem.writeInt(u64, m[0..8], n, .little);
    return m.ptr + 8;
}

pub fn bufLen(p: ?[*]u8) usize {
    const h: [*]u8 = p.? - 8;
    return @intCast(std.mem.readInt(u64, h[0..8], .little));
}

// ---------------------------------------------------------------- the C library as the engine calls it
pub const CFile = FILE;

var open_files: std.ArrayListUnmanaged(*FILE) = .{};
var stderr_file: FILE = .{ .fd = 2, .std = 1 };

pub fn initStd() void {
    R.stdout_ = @ptrCast(stdout);
    R.stderr_ = &stderr_file;
}

/// What C's exit() does to open streams: flush every one (stdout and stderr too).
pub fn flushAll() void {
    for (open_files.items) |f| flushW(f);
    flushW(@ptrCast(stdout));
    flushW(&stderr_file);
}

pub const R = struct {
    pub var stdout_: ?*CFile = null;
    pub var stderr_: ?*CFile = null;
    pub const Slot: u8 = 0;

    pub fn LitDyn(s: ?[]const u8) E!?[*]u8 {
        const x = s orelse return null;
        const b = bufAlloc(x.len + 1);
        @memcpy(b.?[0..x.len], x);
        return b;
    }
    /// char a[n] = "literal": n bytes, the literal's first, the rest zero
    pub fn LitN(s: ?[]const u8, n: i32) E!?[*]u8 {
        const x = s.?;
        const b = bufAlloc(@max(@as(usize, @intCast(n)), x.len + 1));
        @memcpy(b.?[0..x.len], x);
        return b;
    }
    pub fn Buf_i(n: i32) E!?[*]u8 {
        return bufAlloc(@intCast(@max(n, 1)));
    }
    pub fn Buf_l(n: i64) E!?[*]u8 {
        return bufAlloc(@intCast(@max(n, 1)));
    }
    pub fn Buf_ul(n: u64) E!?[*]u8 {
        return bufAlloc(@intCast(@max(n, 1)));
    }
    /// char buf[n] = { ... }: n bytes, the given ones first, the rest zero
    pub fn BufOf(n: i32, vals: ?[]i32) E!?[*]u8 {
        const b = bufAlloc(@intCast(@max(n, 1)));
        const len = bufLen(b);
        for (vals.?, 0..) |v, i| {
            if (i < len) b.?[i] = @truncate(@as(u32, @bitCast(v)));
        }
        return b;
    }
    /// char a[n][m]: n zeroed rows of m bytes
    pub fn Bufs(n: i32, m: i32) E!?[]?[*]u8 {
        const r = rt.gcSlice(?[*]u8, @intCast(n));
        for (r) |*x| x.* = try Buf_i(m);
        return r;
    }
    pub fn CopyBuf(p: ?[*]u8) E!?[*]u8 {
        if (p == null) return null;
        const n = bufLen(p);
        const b = bufAlloc(n);
        @memcpy(b.?[0..n], p.?[0..n]);
        return b;
    }
    /// copy-assigning a char array member: all its bytes
    pub fn memcpyBuf(d: ?[*]u8, s: ?[*]u8) E!void {
        const n = @min(bufLen(d), bufLen(s));
        @memcpy(d.?[0..n], s.?[0..n]);
    }

    pub fn strlen(p: ?[*]u8) E!u64 {
        return slen(p);
    }
    pub fn strcmp(a: ?[*]u8, b: ?[*]u8) E!i32 {
        var i: usize = 0;
        while (true) : (i += 1) {
            const x = a.?[i];
            const y = b.?[i];
            if (x != y) return @as(i32, x) - @as(i32, y);
            if (x == 0) return 0;
        }
    }
    pub fn strncmp(a: ?[*]u8, b: ?[*]u8, n: u64) E!i32 {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const x = a.?[i];
            const y = b.?[i];
            if (x != y) return @as(i32, x) - @as(i32, y);
            if (x == 0) return 0;
        }
        return 0;
    }
    pub fn memcmp(a: ?[*]u8, b: ?[*]u8, n: u64) E!i32 {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const x = a.?[i];
            const y = b.?[i];
            if (x != y) return @as(i32, x) - @as(i32, y);
        }
        return 0;
    }
    pub fn strncpy(d: ?[*]u8, s: ?[*]u8, n: u64) E!?[*]u8 {
        var i: usize = 0;
        while (i < n and s.?[i] != 0) : (i += 1) d.?[i] = s.?[i];
        while (i < n) : (i += 1) d.?[i] = 0;
        return d;
    }
    pub fn strchr(p: ?[*]u8, c: i32) E!?[*]u8 {
        const ch: u8 = @truncate(@as(u32, @bitCast(c)));
        var i: usize = 0;
        while (true) : (i += 1) {
            if (p.?[i] == ch) return p.? + i;
            if (p.?[i] == 0) return null;
        }
    }
    pub fn strrchr(p: ?[*]u8, c: i32) E!?[*]u8 {
        const ch: u8 = @truncate(@as(u32, @bitCast(c)));
        var r: ?[*]u8 = null;
        var i: usize = 0;
        while (true) : (i += 1) {
            if (p.?[i] == ch) r = p.? + i;
            if (p.?[i] == 0) return r;
        }
    }
    pub fn strstr(h: ?[*]u8, n: ?[*]u8) E!?[*]u8 {
        const hs = h.?[0..slen(h)];
        const ns = n.?[0..slen(n)];
        const at = std.mem.indexOf(u8, hs, ns) orelse return null;
        return h.? + at;
    }
    var tok_next: ?[*]u8 = null;
    pub fn strtok(p: ?[*]u8, delim: ?[*]u8) E!?[*]u8 {
        var s = if (p != null) p else tok_next;
        if (s == null) return null;
        const d = delim.?[0..slen(delim)];
        while (s.?[0] != 0 and std.mem.indexOfScalar(u8, d, s.?[0]) != null) s = s.? + 1;
        if (s.?[0] == 0) {
            tok_next = null;
            return null;
        }
        const start = s;
        while (s.?[0] != 0 and std.mem.indexOfScalar(u8, d, s.?[0]) == null) s = s.? + 1;
        if (s.?[0] != 0) {
            s.?[0] = 0;
            tok_next = s.? + 1;
        } else tok_next = null;
        return start;
    }
    pub fn toupper(c: i32) E!i32 {
        return if (c >= 'a' and c <= 'z') c - 32 else c;
    }
    pub fn tolower(c: i32) E!i32 {
        return if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    pub fn isdigit(c: i32) E!i32 {
        return if (c >= '0' and c <= '9') 1 else 0;
    }
    pub fn isalpha(c: i32) E!i32 {
        return if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')) 1 else 0;
    }
    pub fn isalnum(c: i32) E!i32 {
        return if ((try isdigit(c)) != 0 or (try isalpha(c)) != 0) 1 else 0;
    }
    pub fn isspace(c: i32) E!i32 {
        return if (c == ' ' or (c >= 9 and c <= 13)) 1 else 0;
    }
    pub fn isupper(c: i32) E!i32 {
        return if (c >= 'A' and c <= 'Z') 1 else 0;
    }
    pub fn islower(c: i32) E!i32 {
        return if (c >= 'a' and c <= 'z') 1 else 0;
    }
    pub fn ispunct(c: i32) E!i32 {
        return if (c > 32 and c < 127 and (try isalnum(c)) == 0) 1 else 0;
    }
    pub fn isprint(c: i32) E!i32 {
        return if (c >= 32 and c < 127) 1 else 0;
    }
    pub fn isxdigit(c: i32) E!i32 {
        return if ((try isdigit(c)) != 0 or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')) 1 else 0;
    }

    pub fn strtod_CPtr(p: ?[*]u8) E!f64 {
        var e: ?[*]u8 = null;
        return strtodRange(p, &e);
    }
    pub fn strtod_CPtr_CPtrr(p: ?[*]u8, end: *?[*]u8) E!f64 {
        return strtodRange(p, end);
    }
    pub fn atof(p: ?[*]u8) E!f64 {
        return strtod_CPtr(p);
    }
    pub fn atoi(p: ?[*]u8) E!i32 {
        return @truncate(strtol(p, null));
    }
    pub fn atol(p: ?[*]u8) E!i64 {
        return strtol(p, null);
    }
    pub fn strtol0(p: ?[*]u8, b: i32) E!i64 {
        _ = b;
        return strtol(p, null);
    }
    pub fn getenv(name: ?[*]u8) E!?[*]u8 {
        const v = std.posix.getenv(name.?[0..slen(name)]) orelse return null;
        return LitDyn(v);
    }

    pub fn sscanf(s: ?[*]u8, fmt: ?[*]u8, args: anytype) E!i32 {
        const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
        var a: [fields.len + 1]SArg = undefined;
        inline for (fields, 0..) |fl, k| a[k] = sarg(@field(args, fl.name));
        return sscanfImpl(s, fmt, a[0..fields.len]);
    }
    pub fn fprintf(f: ?*CFile, fmt: ?[*]u8, args: anytype) E!i32 {
        var sb: [1024]u8 = undefined;
        var o: Out = .{ .buf = &sb };
        defer o.deinit();
        formatOut(&o, fmt, args);
        const ff = f orelse return -1;
        fwriteBytes(@ptrCast(ff), o.buf[0..o.n]);
        return @intCast(o.n);
    }
    pub fn snprintf_CPtr_ul_CPtr_oA(d: ?[*]u8, n: u64, fmt: ?[*]u8, args: anytype) E!i32 {
        var sb: [1024]u8 = undefined;
        var o: Out = .{ .buf = &sb };
        defer o.deinit();
        formatOut(&o, fmt, args);
        if (n > 0) {
            const m: usize = @min(o.n, @as(usize, @intCast(n - 1)));
            @memcpy(d.?[0..m], o.buf[0..m]);
            d.?[m] = 0;
        }
        return @intCast(o.n);
    }
    pub fn snprintf_CPtr_l_CPtr_oA(d: ?[*]u8, n: i64, fmt: ?[*]u8, args: anytype) E!i32 {
        return snprintf_CPtr_ul_CPtr_oA(d, @bitCast(n), fmt, args);
    }
    pub fn snprintf_CPtr_i_CPtr_oA(d: ?[*]u8, n: i32, fmt: ?[*]u8, args: anytype) E!i32 {
        return snprintf_CPtr_ul_CPtr_oA(d, @bitCast(@as(i64, n)), fmt, args);
    }

    pub fn fopen(name: ?[*]u8, mode: ?[*]u8) E!?*CFile {
        const f = crtFopen(cp(name), cp(mode));
        if (f == null) return null;
        const p: *FILE = @ptrCast(f);
        open_files.append(gpa, p) catch die("out of memory\n");
        return p;
    }
    pub fn fclose(f: ?*CFile) E!i32 {
        const p = f orelse return -1;
        for (open_files.items, 0..) |x, k| {
            if (x == p) {
                _ = open_files.swapRemove(k);
                break;
            }
        }
        return crtFclose(@ptrCast(p));
    }
    pub fn fflush(f: ?*CFile) E!i32 {
        if (f) |p| flushW(p);
        return 0;
    }
    pub fn feof(f: ?*CFile) E!i32 {
        return if (f.?.eof != 0) 1 else 0;
    }
    pub fn ferror(f: ?*CFile) E!i32 {
        return if (f != null and f.?.err != 0) 1 else 0;
    }
    pub fn fileno(f: ?*CFile) E!i32 {
        _ = f;
        return 3;
    }
    pub fn setvbuf(f: ?*CFile, b: ?[*]u8, mode: i32, size: u64) E!i32 {
        _ = f;
        _ = b;
        _ = mode;
        _ = size;
        return 0;
    }
    pub fn rewind(f: ?*CFile) E!void {
        crtRewind(@ptrCast(f.?));
    }
    pub fn fseek_CFile_l_i(f: ?*CFile, off: i64, whence: i32) E!i32 {
        return crtFseek(@ptrCast(f.?), off, whence);
    }
    pub fn fseek_CFile_i_i(f: ?*CFile, off: i32, whence: i32) E!i32 {
        return crtFseek(@ptrCast(f.?), off, whence);
    }
    pub fn ftell(f: ?*CFile) E!i64 {
        return f.?.pos;
    }
    pub fn fgets(b: ?[*]u8, n: i32, f: ?*CFile) E!?[*]u8 {
        const r = crtFgets(cp(b), n, @ptrCast(f.?));
        return @ptrCast(r);
    }
    pub fn fgetc(f: ?*CFile) E!i32 {
        const c = getc(f.?);
        if (c < 0) f.?.readFailed();
        return c;
    }
    fn readExact(f: *CFile, dst: []u8) bool {
        if (readBytesF(f, dst) < dst.len) {
            f.readFailed();
            return false;
        }
        return true;
    }
    pub fn freadD1(v: *f64, f: ?*CFile) E!u64 {
        var b: [8]u8 = undefined;
        if (!readExact(f.?, &b)) return 0;
        v.* = @bitCast(b);
        return 1;
    }
    pub fn freadF1(v: *f32, f: ?*CFile) E!u64 {
        var b: [4]u8 = undefined;
        if (!readExact(f.?, &b)) return 0;
        v.* = @bitCast(b);
        return 1;
    }
    pub fn freadI1(v: *i32, f: ?*CFile) E!u64 {
        var b: [4]u8 = undefined;
        if (!readExact(f.?, &b)) return 0;
        v.* = @bitCast(b);
        return 1;
    }
    pub fn freadL1(v: *i64, f: ?*CFile) E!u64 {
        var b: [8]u8 = undefined;
        if (!readExact(f.?, &b)) return 0;
        v.* = @bitCast(b);
        return 1;
    }
    pub fn fwriteD1(v: f64, f: ?*CFile) E!u64 {
        const b: [8]u8 = @bitCast(v);
        fwriteBytes(@ptrCast(f.?), &b);
        return 1;
    }
    pub fn fwriteF1(v: f32, f: ?*CFile) E!u64 {
        const b: [4]u8 = @bitCast(v);
        fwriteBytes(@ptrCast(f.?), &b);
        return 1;
    }
    pub fn fwriteI1(v: i32, f: ?*CFile) E!u64 {
        const b: [4]u8 = @bitCast(v);
        fwriteBytes(@ptrCast(f.?), &b);
        return 1;
    }
    pub fn fwriteL1(v: i64, f: ?*CFile) E!u64 {
        const b: [8]u8 = @bitCast(v);
        fwriteBytes(@ptrCast(f.?), &b);
        return 1;
    }
    pub fn remove(name: ?[*]u8) E!i32 {
        return crtRemove(cp(name));
    }
    pub fn time_Ptrl(p: ?[*]i64) E!i64 {
        const t = c_time(null);
        if (p != null) p.?[0] = t;
        return t;
    }
    pub fn difftime(a: i64, b: i64) E!f64 {
        return @floatFromInt(a - b);
    }
    pub fn ctime_Ptrl(p: ?[*]i64) E!?[*]u8 {
        var t = p.?[0];
        const r = crtCtime(&t);
        return LitDyn(bytes(r));
    }
};

/// printf with a format known only at run time, into a growable list
pub fn formatList(out: *std.ArrayListUnmanaged(u8), fmt: []const u8, args: anytype) void {
    var fb: [64]u8 = undefined;
    @memcpy(fb[0..fmt.len], fmt);
    fb[fmt.len] = 0;
    var sb: [1024]u8 = undefined;
    var o: Out = .{ .buf = &sb };
    defer o.deinit();
    formatOut(&o, @ptrCast(&fb), args);
    out.appendSlice(gpa, o.buf[0..o.n]) catch die("out of memory\n");
}

/// strtod of a NUL-terminated text without leading white space: the value and the characters taken (0: none)
pub fn scanNumber(text: [*]u8) struct { v: f64, n: usize } {
    var sc: Scan = .{ .v = 0, .end = 0, .text_ok = false };
    scanDouble(@ptrCast(text), -1, false, &sc);
    if (sc.end <= 0) return .{ .v = 0, .n = 0 };
    return .{ .v = sc.v, .n = @intCast(sc.end) };
}

pub fn strtolText(p: ?[*]u8, end: *?[*]u8) i64 {
    return strtol(p, end);
}

/// the whole of a file, or null when it cannot be opened; a directory opens and reads nothing (dir = true)
pub fn readWholeFile(path: []const u8, dir: *bool) ?[]u8 {
    dir.* = false;
    var pb = gpa.alloc(u8, path.len + 1) catch die("out of memory\n");
    defer gpa.free(pb);
    @memcpy(pb[0..path.len], path);
    pb[path.len] = 0;
    const fd = open(@ptrCast(pb.ptr), O_RDONLY);
    if (fd < 0) return null;
    defer _ = close(fd);
    // a directory opens (as an ifstream on one does) and reads nothing; its lseek end is no size (on ext4 it is
    // 2^63 - 1, which the allocation below would take literally)
    const st = std.posix.fstat(fd) catch return null;
    if (std.posix.S.ISDIR(st.mode)) {
        dir.* = true;
        return rt.gcSlice(u8, 0);
    }
    const size = lseek(fd, 0, 2);
    if (size < 0) return null;
    var data = rt.gcSlice(u8, @intCast(size));
    var got: usize = 0;
    while (got < data.len) {
        const r = pread(fd, data.ptr + got, data.len - got, @intCast(got));
        if (r < 0) {
            dir.* = true;
            return data[0..0];
        }
        if (r == 0) break;
        got += @intCast(r);
    }
    if (size == 0) {
        var t: [1]u8 = undefined;
        if (pread(fd, &t, 1, 0) < 0) dir.* = true;
    }
    return data[0..got];
}
