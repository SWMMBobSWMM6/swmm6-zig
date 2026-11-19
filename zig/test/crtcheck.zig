//! crtcheck.zig - the Zig side of tests/crtcheck (as php/test/crtcheck.php is the PHP side):
//!   crtcheck libm N | printf | scanf | misc | units
//! reads what the C program of the same name (tests/crtcheck: libm.c, printf.c, scanf.c, misc.cpp, and
//! tests/crtcheck/pycheck/specs.c for every printf conversion the engine's format strings use) wrote on stdin and
//! reports where the Zig runtime (zig/rt: crt.zig, libm.zig, str.zig, fs.zig) differs from glibc. The case lines and
//! their checks are crtcheck.php's, one for one; the units are its unit checks in the Zig runtime's terms.
//! printf and scanf go through the same code the engine's calls reach: snprintf with a tuple of the argument kinds
//! the line names (R.snprintf_CPtr_ul_CPtr_oA), and sscanf's target list (crt.sscanfImpl, which R.sscanf calls
//! after turning its tuple into the same list).
//! Built by zig/test/run_crtcheck.sh against zig/rt with the engine's flags.
//! Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see ../README.md.
const std = @import("std");
const rt = @import("rt");
const crt = rt.crt;
const R = crt.R;

const A = std.heap.page_allocator;
var outbuf: std.ArrayListUnmanaged(u8) = .{};

fn say(comptime fmt: []const u8, args: anytype) void {
    outbuf.writer(A).print(fmt, args) catch unreachable;
    if (outbuf.items.len > 1 << 16) flush();
}
fn flush() void {
    std.fs.File.stdout().writeAll(outbuf.items) catch {};
    outbuf.clearRetainingCapacity();
}

fn bits(x: f64) u64 {
    return @bitCast(x);
}
fn frombits(b: u64) f64 {
    return @bitCast(b);
}
fn unhex(s: []const u8) []u8 {
    if (std.mem.eql(u8, s, "-")) return &[_]u8{};
    const o = A.alloc(u8, s.len / 2) catch unreachable;
    _ = std.fmt.hexToBytes(o, s) catch unreachable;
    return o;
}
fn lit(raw: []const u8) ?[*]u8 {
    return R.LitDyn(raw) catch unreachable;
}
fn hexOf(b: []const u8) []u8 {
    if (b.len == 0) return @constCast("-");
    const o = A.alloc(u8, b.len * 2) catch unreachable;
    const d = "0123456789abcdef";
    for (b, 0..) |c, i| {
        o[2 * i] = d[c >> 4];
        o[2 * i + 1] = d[c & 15];
    }
    return o;
}
fn cstr(p: ?[*]u8) []u8 {
    return p.?[0..crt.slen(p)];
}
fn hx(s: []const u8) u64 {
    return std.fmt.parseInt(u64, s, 16) catch unreachable;
}
fn readStdin() []u8 {
    return std.fs.File.stdin().readToEndAlloc(A, 1 << 34) catch unreachable;
}

fn lines(what: []const u8, comptime f: fn (fl: [][]const u8, want: *std.ArrayListUnmanaged(u8), got: *std.ArrayListUnmanaged(u8)) void) void {
    const data = readStdin();
    var it = std.mem.splitScalar(u8, data, '\n');
    var n: usize = 0;
    var bad: usize = 0;
    var fl: [16][]const u8 = undefined;
    var want: std.ArrayListUnmanaged(u8) = .{};
    var got: std.ArrayListUnmanaged(u8) = .{};
    while (it.next()) |ln| {
        if (ln.len == 0) continue;
        var m: usize = 0;
        var ft = std.mem.splitScalar(u8, ln, '\t');
        while (ft.next()) |x| : (m += 1) fl[m] = x;
        while (m < 8) : (m += 1) fl[m] = "";
        n += 1;
        want.clearRetainingCapacity();
        got.clearRetainingCapacity();
        f(fl[0..], &want, &got);
        if (std.mem.eql(u8, want.items, got.items)) continue;
        bad += 1;
        if (bad <= 15 or std.posix.getenv("ALLMIS") != null) say("MISMATCH {s} ({s})\n  glibc:  {s}\n  Zig:    {s}\n", .{ fl[0], fl[1], want.items, got.items });
    }
    say("{s} cases: {d}, mismatches: {d}\n", .{ what, n, bad });
}

// ------------------------------------------------------------------------------------------------ printf
// hex(format) types args size ret hex(output)
fn ArgT(comptime c: u8) type {
    return switch (c) {
        'd' => f64,
        'i' => i32,
        'l' => i64,
        's', 'S' => ?[*]u8,
        else => @compileError("printf kind"),
    };
}
fn argOf(comptime c: u8, v: []const u8) ArgT(c) {
    return switch (c) {
        'd' => frombits(hx(v)),
        'i' => @bitCast(@as(u32, @truncate(hx(v)))),
        'l' => @bitCast(hx(v)),
        's' => lit(unhex(v)),
        'S' => null,
        else => unreachable,
    };
}
const PATS = [_][]const u8{ "d", "i", "l", "s", "S", "id", "ii", "iid", "dd" };

fn printfCase(f: [][]const u8, want: *std.ArrayListUnmanaged(u8), got: *std.ArrayListUnmanaged(u8)) void {
    const fmt = lit(unhex(f[0]));
    var vals: [8][]const u8 = .{""} ** 8;
    var vi: usize = 0;
    var vt = std.mem.splitScalar(u8, f[2], ',');
    while (vt.next()) |x| : (vi += 1) vals[vi] = x;
    const size: u64 = std.fmt.parseInt(u64, f[3], 10) catch unreachable;
    const buf = R.Buf_i(1024) catch unreachable;
    @memset(buf.?[0..1024], 0x55);
    buf.?[0] = 0;
    var r: i32 = 0;
    var done = false;
    inline for (PATS) |pat| {
        if (!done and std.mem.eql(u8, f[1], pat)) {
            done = true;
            const Ts = comptime blk: {
                var ts: [pat.len]type = undefined;
                for (pat, 0..) |c, j| ts[j] = ArgT(c);
                break :blk ts;
            };
            var tup: std.meta.Tuple(&Ts) = undefined;
            inline for (pat, 0..) |c, j| tup[j] = argOf(c, vals[j]);
            r = R.snprintf_CPtr_ul_CPtr_oA(buf, size, fmt, tup) catch unreachable;
        }
    }
    if (!done) std.debug.panic("printf argument kinds {s}", .{f[1]});
    var o: []const u8 = "-";
    if (size > 0) {
        const k = std.mem.indexOfScalar(u8, buf.?[0..1024], 0).?;
        if (k > 0) o = hexOf(buf.?[0..k]);
    }
    want.writer(A).print("{s}\t{s}", .{ f[4], f[5] }) catch unreachable;
    got.writer(A).print("{d}\t{s}", .{ r, o }) catch unreachable;
}

// ------------------------------------------------------------------------------------------------ scanf
// hex(format) hex(input) types ret values; the targets are the kinds the engine passes
fn scanfCase(f: [][]const u8, want: *std.ArrayListUnmanaged(u8), got: *std.ArrayListUnmanaged(u8)) void {
    const fmt = lit(unhex(f[0]));
    const inp = lit(unhex(f[1]));
    const types = f[2];
    const m = types.len;
    var ints: [8]i32 = .{@as(i32, @bitCast(@as(u32, 0x55555555)))} ** 8;
    var uns: [8]u32 = .{0x55555555} ** 8;
    var longs: [8]i64 = .{0x5555555555555555} ** 8;
    var floats: [8]f32 = .{@as(f32, @bitCast(@as(u32, 0x55555555)))} ** 8;
    var doubles: [8]f64 = .{frombits(0x5555555555555555)} ** 8;
    var chars: [8]i8 = .{0x55} ** 8;
    var bufs: [8]?[*]u8 = .{null} ** 8;
    var args: [8]crt.SArg = undefined;
    for (0..m) |k| {
        args[k] = switch (types[k]) {
            'i', 'n' => crt.sarg(&ints[k]),
            'u' => crt.sarg(&uns[k]),
            'l' => crt.sarg(&longs[k]),
            'f' => crt.sarg(&floats[k]),
            'd' => crt.sarg(&doubles[k]),
            'k' => crt.sarg(&chars[k]),
            's', 'c' => blk: {
                bufs[k] = R.Buf_i(64) catch unreachable;
                @memset(bufs[k].?[0..64], 0x55);
                break :blk crt.sarg(bufs[k]);
            },
            else => std.debug.panic("scanf target kind {c}", .{types[k]}),
        };
    }
    const r = crt.sscanfImpl(inp, fmt, args[0..m]);
    var w = got.writer(A);
    w.print("{d}\t", .{r}) catch unreachable;
    for (0..m) |k| {
        switch (types[k]) {
            'i', 'n' => w.print("{d}", .{ints[k]}) catch unreachable,
            'u' => w.print("{d}", .{@as(i32, @bitCast(uns[k]))}) catch unreachable,
            'k' => w.print("{d}", .{chars[k]}) catch unreachable,
            'l' => w.print("{d}", .{longs[k]}) catch unreachable,
            'f' => w.print("{x:0>8}", .{@as(u32, @bitCast(floats[k]))}) catch unreachable,
            'd' => w.print("{x:0>16}", .{bits(doubles[k])}) catch unreachable,
            else => w.print("{s}", .{hexOf(bufs[k].?[0..12])}) catch unreachable,
        }
        w.writeByte(' ') catch unreachable;
    }
    want.writer(A).print("{s}\t{s}", .{ f[3], f[4] }) catch unreachable;
}

// ------------------------------------------------------------------------------------------------ misc
// kind hex(input) result
fn miscCase(f: [][]const u8, want: *std.ArrayListUnmanaged(u8), got: *std.ArrayListUnmanaged(u8)) void {
    const raw = unhex(f[1]);
    const s = lit(raw);
    const e = rt.padd(s, @as(i64, @intCast(raw.len)));
    const k = f[0];
    var w = got.writer(A);
    if (std.mem.eql(u8, k, "fci")) {
        var v: i32 = 0x55555555;
        const r = rt.Std.from_chars_CPtr_CPtr_ir(s, e, &v) catch unreachable;
        w.print("{d} {d} {d}", .{ r.ec, rt.pdiff(r.ptr, s), v }) catch unreachable;
    } else if (std.mem.eql(u8, k, "fcu")) {
        var v: u32 = 0x55555555;
        const r = rt.Std.from_chars_CPtr_CPtr_ur(s, e, &v) catch unreachable;
        w.print("{d} {d} {d}", .{ r.ec, rt.pdiff(r.ptr, s), v }) catch unreachable;
    } else if (std.mem.eql(u8, k, "fcl")) {
        var v: i64 = 0x5555555555555555;
        const r = rt.Std.from_chars_CPtr_CPtr_lr(s, e, &v) catch unreachable;
        w.print("{d} {d} {d}", .{ r.ec, rt.pdiff(r.ptr, s), v }) catch unreachable;
    } else if (std.mem.eql(u8, k, "fcd")) {
        var v: f64 = 0.25;
        const r = rt.Std.from_chars_CPtr_CPtr_dr(s, e, &v) catch unreachable;
        w.print("{d} {d} {x:0>16}", .{ r.ec, rt.pdiff(r.ptr, s), bits(v) }) catch unreachable;
    } else if (std.mem.eql(u8, k, "strtol")) {
        var en: ?[*]u8 = s;
        const v = crt.strtolText(s, &en);
        w.print("{d} {d}", .{ v, rt.pdiff(en, s) }) catch unreachable;
    } else if (std.mem.eql(u8, k, "atoi")) {
        w.print("{d}", .{R.atoi(s) catch unreachable}) catch unreachable;
    } else if (std.mem.eql(u8, k, "atol")) {
        w.print("{d}", .{R.atol(s) catch unreachable}) catch unreachable;
    } else if (std.mem.eql(u8, k, "strtod")) {
        var en: ?[*]u8 = s;
        const v = R.strtod_CPtr_CPtrr(s, &en) catch unreachable;
        w.print("{x:0>16} {d}", .{ bits(v), rt.pdiff(en, s) }) catch unreachable;
    } else if (std.mem.eql(u8, k, "ctime")) {
        var t = [1]i64{std.fmt.parseInt(i64, raw, 10) catch unreachable};
        const p = R.ctime_Ptrl(&t) catch unreachable;
        w.print("{s}", .{hexOf(cstr(p))}) catch unreachable;
    } else if (std.mem.eql(u8, k, "nprocs")) {
        w.print("{d}", .{rt.Sys.hardware_concurrency() catch unreachable}) catch unreachable;
    } else if (std.mem.eql(u8, k, "ctype")) {
        const c = std.fmt.parseInt(i32, raw, 10) catch unreachable;
        w.print("{d}{d}{d}{d}{d}{d}{d}{d}{d} {d} {d}", .{
            R.isdigit(c) catch unreachable,  R.isalpha(c) catch unreachable,  R.isalnum(c) catch unreachable,
            R.isspace(c) catch unreachable,  R.isupper(c) catch unreachable,  R.islower(c) catch unreachable,
            R.ispunct(c) catch unreachable,  R.isprint(c) catch unreachable,  R.isxdigit(c) catch unreachable,
            R.toupper(c) catch unreachable,  R.tolower(c) catch unreachable,
        }) catch unreachable;
    } else std.debug.panic("misc kind {s}", .{k});
    if (!std.mem.eql(u8, got.items, f[2])) w.print("  ({s} \"{s}\")", .{ k, raw }) catch unreachable;
    want.appendSlice(A, f[2]) catch unreachable;
}

// ------------------------------------------------------------------------------------------------ libm
const LIBM_FN = [_][]const u8{ "atan2", "cbrt", "cosh", "sinh", "tanh", "log2", "expm1", "log1p", "hypot", "fmod", "remainder", "round", "nextafter", "exp", "log", "pow", "sin", "cos", "tan", "asin", "acos", "atan", "log10", "floor", "ceil", "trunc", "sqrt" };
const NSPEC = 24;

/// the engine's route to each function: rt.Math (System.Math in the C# the engine was generated from) and rt.LibM
fn libmCall(fi: usize, x: f64, y: f64) f64 {
    const M = rt.Math;
    const LM = rt.LibM;
    return switch (fi) {
        0 => M.Atan2_d(x, y),
        1 => M.Cbrt_d(x),
        2 => M.Cosh_d(x),
        3 => M.Sinh_d(x),
        4 => M.Tanh_d(x),
        5 => M.Log2_d(x),
        6 => LM.expm1(x) catch unreachable,
        7 => LM.log1p(x) catch unreachable,
        8 => LM.hypot(x, y) catch unreachable,
        9 => LM.fmod(x, y) catch unreachable,
        10 => LM.remainder(x, y) catch unreachable,
        11 => LM.round(x) catch unreachable,
        12 => LM.nextafter(x, y) catch unreachable,
        13 => M.Exp_d(x),
        14 => M.Log_d(x),
        15 => M.Pow_d(x, y),
        16 => M.Sin_d(x),
        17 => M.Cos_d(x),
        18 => M.Tan_d(x),
        19 => M.Asin_d(x),
        20 => M.Acos_d(x),
        21 => M.Atan_d(x),
        22 => M.Log10_d(x),
        23 => M.Floor_d(x),
        24 => M.Ceiling_d(x),
        25 => M.Truncate_d(x),
        26 => M.Sqrt_d(x),
        else => unreachable,
    };
}

fn ulps(a: f64, b: f64) u64 {
    var ia: i64 = @bitCast(a);
    var ib: i64 = @bitCast(b);
    if (ia < 0) ia = std.math.minInt(i64) -% ia;
    if (ib < 0) ib = std.math.minInt(i64) -% ib;
    return @abs(ia -% ib);
}

fn libm(n: usize) void {
    const per = n + NSPEC * NSPEC;
    const data = readStdin();
    if (data.len < per * 24 * LIBM_FN.len) {
        say("short input\n", .{});
        flush();
        std.process.exit(1);
    }
    say("{s:<10} {s:>8} {s:>10} {s:>9} {s:>8} {s:>10}  {s}\n", .{ "function", "cases", "mismatch", "NaN-sign", "max ulp", "special", "first mismatch (x, y: glibc vs Zig, bits)" });
    var total: usize = 0;
    for (LIBM_FN, 0..) |name, fi| {
        var bad: usize = 0;
        var nan_sign: usize = 0;
        var maxu: u64 = 0;
        var sbad: usize = 0;
        var nan_num = false;
        var first: []const u8 = "";
        const base = fi * per * 24;
        for (0..per) |k| {
            const o = base + 24 * k;
            const x = frombits(std.mem.readInt(u64, data[o..][0..8], .little));
            const y = frombits(std.mem.readInt(u64, data[o + 8 ..][0..8], .little));
            const wb = std.mem.readInt(u64, data[o + 16 ..][0..8], .little);
            const g = libmCall(fi, x, y);
            if (bits(g) == wb) continue;
            bad += 1;
            if (k >= n) sbad += 1;
            const wv = frombits(wb);
            if (std.math.isNan(wv) and std.math.isNan(g)) nan_sign += 1 else if (!std.math.isNan(wv) and !std.math.isNan(g)) maxu = @max(maxu, ulps(wv, g)) else nan_num = true;
            if (first.len == 0) first = std.fmt.allocPrint(A, "{x:0>16}, {x:0>16}: {x:0>16} vs {x:0>16}", .{ bits(x), bits(y), wb, bits(g) }) catch unreachable;
        }
        total += bad;
        var mu: [24]u8 = undefined;
        const mus = if (nan_num) "NaN/num" else std.fmt.bufPrint(&mu, "{d}", .{maxu}) catch unreachable;
        say("{s:<10} {d:>8} {d:>10} {d:>9} {s:>8} {d:>10}  {s}\n", .{ name, per, bad, nan_sign, mus, sbad, first });
    }
    say("total mismatches: {d}\n", .{total});
}

// ------------------------------------------------------------------------------------------------ units
var un: usize = 0;
var ubad: usize = 0;

fn check(name: []const u8, ok: bool) void {
    un += 1;
    if (ok) return;
    ubad += 1;
    say("FAIL {s}\n", .{name});
}

fn L(comptime s: []const u8) ?[*]u8 {
    return lit(s);
}

fn units() !void {
    // sscanf through R.sscanf with the engine's kinds of targets (the generated code passes the addresses)
    {
        var v: i64 = -9;
        var flag: i8 = 'q';
        var r = try R.sscanf(L("123 Y"), L("%ld %c"), .{ &v, &flag });
        check("sscanf %ld %c", r == 2 and v == 123 and flag == 'Y');
        v = -9;
        flag = 'q';
        r = try R.sscanf(L("77"), L("%ld %c"), .{ &v, &flag });
        check("sscanf partial", r == 1 and v == 77 and flag == 'q');
        var x: f32 = 99.99;
        r = try R.sscanf(L("1.5 X"), L("%f %c"), .{ &x, &flag });
        check("sscanf float + char", r == 2 and x == 1.5 and flag == 'X');
        var h: i32 = 0;
        r = try R.sscanf(L("-12"), L("%d"), .{&h});
        check("sscanf int", r == 1 and h == -12);
        var d: f64 = 0;
        r = try R.sscanf(L("2.5"), L("%lf"), .{&d});
        check("sscanf double", r == 1 and d == 2.5);
        const s1 = try R.Buf_i(80);
        r = try R.sscanf(L("  SWMM5 x"), L("%s"), .{s1});
        check("sscanf %s", r == 1 and (try R.strcmp(s1, L("SWMM5"))) == 0);
    }

    // strtod details: hex floats, NaN payloads, the end pointer, ERANGE
    {
        var en: ?[*]u8 = null;
        var s = L("  0x1.8p1rest");
        check("strtod hex", (try R.strtod_CPtr_CPtrr(s, &en)) == 3.0 and rt.pdiff(en, s) == 9);
        check("strtod nan payload", bits(try R.strtod_CPtr(L("nan(0x5)"))) == 0x7ff8000000000005);
        check("strtod -nan", bits(try R.strtod_CPtr(L("-nan"))) == 0xFFF8000000000000);
        s = L("abc");
        check("strtod no number", (try R.strtod_CPtr_CPtrr(s, &en)) == 0.0 and en == s);
        check("strtod huge exponent", (try R.strtod_CPtr(L("1e99999999999"))) == std.math.inf(f64) and (try R.strtod_CPtr(L("1e-99999999999"))) == 0.0);
        // 5^1074 e-1074 = 2^-1074 exactly: the smallest subnormal, exact, so no ERANGE
        var big = std.math.big.int.Managed.initSet(A, 1) catch unreachable;
        for (0..1074) |_| big.mul(&big, &(std.math.big.int.Managed.initSet(A, 5) catch unreachable)) catch unreachable;
        const bigs = big.toString(A, 10, .lower) catch unreachable;
        const cases = [_]struct { t: []const u8, w: bool }{
            .{ .t = "1e999", .w = true },                                      .{ .t = "-1e999", .w = true },
            .{ .t = "1e-400", .w = true },                                     .{ .t = "2.2250738585072011e-308", .w = true },
            .{ .t = "2.22507385850720138e-308", .w = false },                  .{ .t = "2.2250738585072014e-308", .w = false },
            .{ .t = "4.9e-324", .w = true },                                   .{ .t = "1.5", .w = false },
            .{ .t = "0", .w = false },                                         .{ .t = "0e-999", .w = false },
            .{ .t = "0x1p-1080", .w = true },                                  .{ .t = "0x1p99999", .w = true },
            .{ .t = "inf", .w = false },                                       .{ .t = "abc", .w = false },
            .{ .t = "4.940656458412465441765687928682213723651e-324", .w = true }, .{ .t = "4.940656458412465441248710587739e-324", .w = true },
            .{ .t = "0x3p-1074", .w = false },                                 .{ .t = std.fmt.allocPrint(A, "{s}e-1074", .{bigs}) catch unreachable, .w = false },
        };
        var all = true;
        for (cases) |c| {
            var e2: ?[*]u8 = null;
            _ = crt.strtodRange(lit(c.t), &e2);
            if (crt.erange != c.w) {
                all = false;
                say("  ERANGE {s}: {}\n", .{ c.t[0..@min(c.t.len, 40)], crt.erange });
            }
        }
        check("strtod ERANGE", all);
        check("atof", (try R.atof(L(" -2.5e1x"))) == -25.0);
    }

    // binary and text files
    {
        var dbuf: [256]u8 = undefined;
        const dr = std.fmt.bufPrint(&dbuf, "/dev/shm/zig6_crtcheck_{d}", .{std.c.getpid()}) catch unreachable;
        std.fs.cwd().makePath(dr) catch unreachable;
        const P = struct {
            fn p(d: []const u8, comptime n: []const u8) ?[*]u8 {
                return lit(std.fmt.allocPrint(A, "{s}/" ++ n, .{d}) catch unreachable);
            }
        };
        const name = P.p(dr, "t.bin");
        var fp = try R.fopen(name, L("w+b"));
        _ = try rt.Mem.fwrite_CPtr_ul_ul_CFile(L("STAMP"), 1, 5, fp);
        _ = try R.fwriteI1(42, fp);
        const pos = try R.ftell(fp);
        _ = try R.fwriteD1(3.5, fp);
        _ = try R.fwriteF1(0.25, fp);
        var three = [_]i32{ 7, -8, 9 };
        _ = try rt.Mem.fwrite_PtrT_ul_ul_CFile(i32, &three, 4, 3, fp);
        _ = try R.fseek_CFile_l_i(fp, pos, 0);
        _ = try R.fwriteD1(4.5, fp);
        try R.rewind(fp);
        const stamp = try R.Buf_i(16);
        const got = try rt.Mem.fread_CPtr_ul_ul_CFile(stamp, 1, 5, fp);
        var i: i32 = 0;
        var d: f64 = 0;
        var fl: f32 = 0;
        const ok = got == 5 and (try R.strncmp(stamp, L("STAMP"), 5)) == 0 and (try R.freadI1(&i, fp)) == 1 and i == 42 and
            (try R.freadD1(&d, fp)) == 1 and d == 4.5 and (try R.freadF1(&fl, fp)) == 1 and fl == 0.25;
        check("binary round trip", ok);
        var ints = [_]i32{ 0, 0, 0, 0 };
        const k = try rt.Mem.fread_PtrT_ul_ul_CFile(i32, &ints, 4, 4, fp);
        check("short fread", k == 3 and ints[0] == 7 and ints[1] == -8 and ints[2] == 9 and (try R.feof(fp)) == 1);
        check("fgetc at end", (try R.fgetc(fp)) == -1);
        check("ftell at end", (try R.ftell(fp)) == 5 + 4 + 8 + 4 + 12);
        check("fseek negative", (try R.fseek_CFile_l_i(fp, -1, 0)) == -1);
        check("fseek end", (try R.fseek_CFile_l_i(fp, -4, 2)) == 0 and (try R.ftell(fp)) == 29 and (try R.feof(fp)) == 0);
        var last: i32 = 0;
        check("fread after seek", (try R.freadI1(&last, fp)) == 1 and last == 9);
        check("fclose", (try R.fclose(fp)) == 0);
        fp = try R.fopen(name, L("r"));
        const line = try R.Buf_i(8);
        check("fgets", (try R.fgets(line, 4, fp)) != null and (try R.strcmp(line, L("STA"))) == 0);
        _ = try R.fclose(fp);
        check("fopen missing", (try R.fopen(P.p(dr, "none"), L("r"))) == null);
        check("fopen bad mode", (try R.fopen(name, L("x"))) == null);
        const an = P.p(dr, "a.txt");
        fp = try R.fopen(an, L("w"));
        _ = try R.fprintf(fp, L("one\n"), .{});
        _ = try R.fclose(fp);
        fp = try R.fopen(an, L("a"));
        check("append position", (try R.ftell(fp)) == 4);
        _ = try R.fprintf(fp, L("two\n"), .{});
        _ = try R.fclose(fp);
        var rb: [64]u8 = undefined;
        const at = std.fs.cwd().readFile(cstr(an), &rb) catch "";
        check("append content", std.mem.eql(u8, at, "one\ntwo\n"));
        const ln = P.p(dr, "l.txt");
        std.fs.cwd().writeFile(.{ .sub_path = cstr(ln), .data = "ab\ncdef\ng" }) catch unreachable;
        fp = try R.fopen(ln, L("r"));
        const lb = try R.Buf_i(16);
        var acc: std.ArrayListUnmanaged(u8) = .{};
        while ((try R.fgets(lb, 4, fp)) != null) acc.writer(A).print("[{s}|{d}]", .{ cstr(lb), try R.feof(fp) }) catch unreachable;
        check("fgets lines", std.mem.eql(u8, acc.items, "[ab\n|0][cde|0][f\n|0][g|1]") and (try R.feof(fp)) == 1);
        _ = try R.fclose(fp);
        const tn = P.p(dr, "t.txt");
        fp = try R.fopen(tn, L("w"));
        const ab = L("ab");
        const strobj = try rt.Str.new_CPtr(L("str"));
        _ = try R.fprintf(fp, L("%-6s|%3d|%5.2f|%c|%zu|%s|%d|%hu|%u|%c|%d|%x|%ld|%lld|%.3f\n"), .{
            ab, @as(i8, -5), @as(f32, 1.25), @as(u8, 'Z'), @as(u64, std.math.maxInt(u64)), strobj.?.cstr(), @as(i32, 7),
            @as(u16, 65535), @as(u32, 0xFFFFFFFF), @as(u8, 'q'), true, @as(i16, -1), @as(i64, std.math.minInt(i64)),
            @as(i64, std.math.minInt(i64)), @as(i32, 2),
        });
        crt.flushAll();
        _ = try R.fclose(fp);
        var tb: [256]u8 = undefined;
        const tt = std.fs.cwd().readFile(cstr(tn), &tb) catch "";
        check("fprintf argument kinds", std.mem.eql(u8, tt, "ab    | -5| 1.25|Z|18446744073709551615|str|7|65535|4294967295|q|1|ffffffff|-9223372036854775808|-9223372036854775808|2.000\n"));
        if (!std.mem.eql(u8, tt, "ab    | -5| 1.25|Z|18446744073709551615|str|7|65535|4294967295|q|1|ffffffff|-9223372036854775808|-9223372036854775808|2.000\n")) say("  got {s}", .{tt});
        const sb = try R.Buf_i(8);
        check("snprintf truncation", (try R.snprintf_CPtr_ul_CPtr_oA(sb, 4, L("%d"), .{@as(i32, 123456)})) == 6 and (try R.strcmp(sb, L("123"))) == 0);
        check("snprintf size 0", (try R.snprintf_CPtr_ul_CPtr_oA(sb, 0, L("%s"), .{L("abc")})) == 3 and (try R.strcmp(sb, L("123"))) == 0);
        check("remove", (try R.remove(an)) == 0 and (try R.remove(an)) == -1);
        check("File.Exists", (try rt.File.Exists(cstr(tn))) and !(try rt.File.Exists(dr)));
        std.fs.cwd().deleteTree(dr) catch {};
        const fb = try R.Buf_i(64);
        _ = try R.snprintf_CPtr_ul_CPtr_oA(fb, 64, L("%f %+.2e %5.1f %G %a"), .{ frombits(0xFFF8000000000000), std.math.inf(f64), -std.math.inf(f64), frombits(0x7FF8000000000000), @as(f64, -0.0) });
        check("printf nan/inf", std.mem.eql(u8, cstr(fb), "-nan +inf  -inf NAN -0x0p+0"));
    }

    // math corners
    {
        const M = rt.Math;
        const inf = std.math.inf(f64);
        const nz: u64 = 0x8000000000000000;
        check("CopySign NaN sign", M.CopySign_d(1.0, frombits(0xFFF8000000000000)) == -1.0);
        check("Truncate", M.Truncate_d(-2.7) == -2.0 and bits(M.Truncate_d(-0.5)) == nz);
        check("Ceiling -0", bits(M.Ceiling_d(-0.5)) == nz and M.Ceiling_d(0.2) == 1.0);
        check("Floor", bits(M.Floor_d(-0.0)) == nz and M.Floor_d(-0.5) == -1.0 and M.Floor_d(inf) == inf and M.Floor_d(1e300) == 1e300);
        check("round", (try rt.LibM.round(2.5)) == 3.0 and (try rt.LibM.round(-2.5)) == -3.0 and (try rt.LibM.round(0.49999999999999994)) == 0.0 and
            bits(try rt.LibM.round(-0.4)) == nz);
        check("pow errors", M.Pow_d(0.0, -1.0) == inf and M.Pow_d(-0.0, -3.0) == -inf and
            bits(M.Pow_d(-8.0, 1.0 / 3.0)) == 0xFFF8000000000000 and M.Pow_d(10.0, 400.0) == inf and M.Pow_d(-10.0, 401.0) == -inf);
        check("log errors", M.Log_d(0.0) == -inf and std.math.isNan(M.Log_d(-1.0)) and M.Log10_d(-0.0) == -inf);
        check("exp overflow", M.Exp_d(1000.0) == inf and M.Cosh_d(1000.0) == inf and M.Sinh_d(-1000.0) == -inf);
        check("sqrt", bits(M.Sqrt_d(-1.0)) == 0xFFF8000000000000 and M.Sqrt_d(4.0) == 2.0 and
            bits(M.Sqrt_d(frombits(0x7FF8000000000000))) == 0x7FF8000000000000 and bits(M.Sqrt_d(-0.0)) == nz);
        check("Log2 powers", M.Log2_d(1024.0) == 10.0 and M.Log2_d(5e-324) == -1074.0 and M.Log2_d(1.0) == 0.0);
        // std::max / std::min (the engine's), not C#'s Math.Max: the first argument unless the second compares greater
        check("std::max/min", bits(try rt.M.max_d_d(-0.0, 0.0)) == nz and bits(try rt.M.min_d_d(0.0, -0.0)) == 0 and
            std.math.isNan(try rt.M.max_d_d(frombits(0x7FF8000000000000), 1.0)) and (try rt.M.max_d_d(1.0, frombits(0x7FF8000000000000))) == 1.0);
        check("Abs", bits(M.Abs_d(-0.0)) == 0 and bits(M.Abs_d(frombits(0xFFF8000000000001))) == 0x7FF8000000000001);
    }

    // char arrays and strings
    {
        const p = try R.LitN("OPENSWMM_HS_V1", 16);
        check("LitN", crt.bufLen(p) == 16 and p.?[14] == 0 and p.?[15] == 0);
        const q = try R.CopyBuf(p);
        q.?[0] = 'X';
        check("CopyBuf", p.?[0] == 'O' and crt.bufLen(q) == 16);
        const e9 = try R.LitDyn(&[_]u8{0xE9});
        check("strcmp unsigned", (try R.strcmp(e9, L("e"))) > 0 and (try R.strcmp(L("ab"), L("abc"))) < 0 and (try R.strcmp(L("a"), L("a"))) == 0);
        const hay = L("a,b,,c");
        check("strchr", rt.pdiff(try R.strchr(hay, ','), hay) == 1 and rt.pdiff(try R.strchr(hay, 0), hay) == 6 and (try R.strchr(hay, 'z')) == null);
        check("strrchr", rt.pdiff(try R.strrchr(hay, ','), hay) == 4 and (try R.strrchr(hay, 'z')) == null);
        check("strstr", rt.pdiff(try R.strstr(hay, L(",,")), hay) == 3 and (try R.strstr(hay, L("x"))) == null and (try R.strstr(hay, L(""))) == hay);
        var acc: std.ArrayListUnmanaged(u8) = .{};
        var tk = try R.strtok(hay, L(","));
        while (tk != null) {
            acc.writer(A).print("[{s}]", .{cstr(tk)}) catch unreachable;
            tk = try R.strtok(null, L(","));
        }
        check("strtok", std.mem.eql(u8, acc.items, "[a][b][c]"));
        check("toupper", (try R.toupper('a')) == 'A' and (try R.toupper('{')) == '{');
        check("atoi wrap", (try R.atoi(L("4294967297"))) == 1 and (try R.atoi(L("99999999999999999999"))) == -1);
        const t1 = try rt.Str.to_string_d(1.0 / 3.0);
        const t2 = try rt.Str.to_string_d(-2.5e-7);
        check("to_string(double)", std.mem.eql(u8, t1.?.b.?[0..@intCast(t1.?.n)], "0.333333") and std.mem.eql(u8, t2.?.b.?[0..@intCast(t2.?.n)], "-0.000000"));
        const st = try rt.Str.new_CPtr(L("1e999"));
        var threw = false;
        _ = rt.Str.stod(st, null) catch {
            threw = true;
        };
        check("stod out of range throws", threw and rt.excGet() != null);
    }
    say("units cases: {d}, failures: {d}\n", .{ un, ubad });
}

pub fn main() !void {
    rt.init();
    var args = std.process.args();
    _ = args.next();
    const mode = args.next() orelse "";
    if (std.mem.eql(u8, mode, "libm")) {
        const n = std.fmt.parseInt(usize, args.next() orelse "300000", 10) catch 300000;
        libm(n);
    } else if (std.mem.eql(u8, mode, "printf")) {
        lines("printf", printfCase);
    } else if (std.mem.eql(u8, mode, "scanf")) {
        lines("scanf", scanfCase);
    } else if (std.mem.eql(u8, mode, "misc")) {
        lines("misc", miscCase);
    } else if (std.mem.eql(u8, mode, "units")) {
        try units();
    } else {
        std.debug.print("crtcheck: libm N | printf | scanf | misc | units\n", .{});
        std.process.exit(2);
    }
    flush();
    crt.flushAll();
}
