//! libm_check.zig - check the Zig engine's math bit for bit against the system libm, on the vector files of
//! tools/libm/test (mkvectors.c, mkedge.c, mkvectors2.c) and ruby/test/mkexact.c: records of name\0, n:u32, then
//! n x (args..., result) as raw little-endian doubles. Each function is called the way the generated engine calls
//! it (rt.Math, rt.LibM), so the check covers the runtime's routing as well as the library. A NaN must match in sign
//! and payload. fma, frexp and ldexp are skipped: the engine does not call them.
//!   libm_check vectors.bin edge.bin vectors2.bin exact.bin
//! Built by zig/test/run_libm_tests.sh with the engine's flags. After php/test/libm_check.php.
//! Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see ../README.md.
const std = @import("std");
const rt = @import("rt");

const A = std.heap.page_allocator;

fn call(name: []const u8, a: []const f64) ?f64 {
    const M = rt.Math;
    const L = rt.LibM;
    const x = a[0];
    const eq = std.mem.eql;
    if (eq(u8, name, "exp")) return M.Exp_d(x);
    if (eq(u8, name, "log")) return M.Log_d(x);
    if (eq(u8, name, "log10")) return M.Log10_d(x);
    if (eq(u8, name, "pow")) return M.Pow_d(x, a[1]);
    if (eq(u8, name, "sin")) return M.Sin_d(x);
    if (eq(u8, name, "cos")) return M.Cos_d(x);
    if (eq(u8, name, "tan")) return M.Tan_d(x);
    if (eq(u8, name, "asin")) return M.Asin_d(x);
    if (eq(u8, name, "acos")) return M.Acos_d(x);
    if (eq(u8, name, "atan")) return M.Atan_d(x);
    if (eq(u8, name, "cbrt")) return M.Cbrt_d(x);
    if (eq(u8, name, "hypot")) return L.hypot(x, a[1]) catch unreachable;
    if (eq(u8, name, "atan2")) return M.Atan2_d(x, a[1]);
    if (eq(u8, name, "cosh")) return M.Cosh_d(x);
    if (eq(u8, name, "sinh")) return M.Sinh_d(x);
    if (eq(u8, name, "tanh")) return M.Tanh_d(x);
    if (eq(u8, name, "log2")) return M.Log2_d(x);
    if (eq(u8, name, "expm1")) return L.expm1(x) catch unreachable;
    if (eq(u8, name, "log1p")) return L.log1p(x) catch unreachable;
    if (eq(u8, name, "sqrt")) return M.Sqrt_d(x);
    if (eq(u8, name, "floor")) return M.Floor_d(x);
    if (eq(u8, name, "ceil")) return M.Ceiling_d(x);
    if (eq(u8, name, "trunc")) return M.Truncate_d(x);
    if (eq(u8, name, "fabs")) return M.Abs_d(x);
    if (eq(u8, name, "round")) return L.round(x) catch unreachable;
    if (eq(u8, name, "copysign")) return M.CopySign_d(x, a[1]);
    return null;
}

fn nargs(name: []const u8) ?usize {
    const two = [_][]const u8{ "pow", "hypot", "atan2", "copysign" };
    const one = [_][]const u8{ "exp", "log", "log10", "sin", "cos", "tan", "asin", "acos", "atan", "cbrt", "cosh", "sinh", "tanh", "log2", "expm1", "log1p", "sqrt", "floor", "ceil", "trunc", "fabs", "round" };
    for (two) |t| if (std.mem.eql(u8, t, name)) return 2;
    for (one) |t| if (std.mem.eql(u8, t, name)) return 1;
    return null;
}

fn skipped(name: []const u8) ?usize {
    if (std.mem.eql(u8, name, "fma")) return 4;
    if (std.mem.eql(u8, name, "frexp") or std.mem.eql(u8, name, "ldexp")) return 3;
    return null;
}

pub fn main() !void {
    rt.init();
    var out: std.ArrayListUnmanaged(u8) = .{};
    const w = out.writer(A);
    var total: usize = 0;
    var bad_all: usize = 0;
    var args = std.process.args();
    _ = args.next();
    while (args.next()) |path| {
        try w.print("== {s}\n", .{std.fs.path.basename(path)});
        const data = try std.fs.cwd().readFileAlloc(A, path, 1 << 34);
        defer A.free(data);
        var p: usize = 0;
        while (p < data.len) {
            const z = std.mem.indexOfScalarPos(u8, data, p, 0).?;
            const name = data[p..z];
            p = z + 1;
            const n: usize = std.mem.readInt(u32, data[p..][0..4], .little);
            p += 4;
            const na = nargs(name) orelse {
                const per = skipped(name) orelse return error.UnknownFunction;
                p += n * per * 8;
                try w.print("{s:<9} skipped ({d} records; the engine does not call it)\n", .{ name, n });
                continue;
            };
            const rec = na + 1;
            var bad: usize = 0;
            var nan_sign: usize = 0;
            var nan_pay: usize = 0;
            var shown: usize = 0;
            var a: [2]f64 = .{ 0, 0 };
            const t0: i64 = @intCast(std.time.nanoTimestamp());
            for (0..n) |r| {
                const o = p + r * rec * 8;
                for (0..na) |k| a[k] = @bitCast(std.mem.readInt(u64, data[o + 8 * k ..][0..8], .little));
                const wb = std.mem.readInt(u64, data[o + 8 * na ..][0..8], .little);
                const got = call(name, a[0..na]).?;
                const gb: u64 = @bitCast(got);
                if (gb == wb) continue;
                const wv: f64 = @bitCast(wb);
                if (std.math.isNan(got) and std.math.isNan(wv)) {
                    if ((gb >> 63) != (wb >> 63)) nan_sign += 1 else nan_pay += 1;
                } else {
                    bad += 1;
                    if (shown < 4) {
                        shown += 1;
                        try w.print("  {s}({x:0>16}{s}{x:0>16}) = {x:0>16}, libm {x:0>16}\n", .{ name, @as(u64, @bitCast(a[0])), if (na > 1) ", " else "", if (na > 1) @as(u64, @bitCast(a[1])) else 0, gb, wb });
                    }
                }
            }
            const dt: f64 = @floatFromInt(@as(i64, @intCast(std.time.nanoTimestamp())) - t0);
            p += n * rec * 8;
            total += n;
            bad_all += bad + nan_sign + nan_pay;
            try w.print("{s:<9} {d} of {d} differ, {d} NaN sign, {d} NaN payload   ({d:.3} us/call)\n", .{ name, bad, n, nan_sign, nan_pay, dt / 1e3 / @as(f64, @floatFromInt(@max(n, 1))) });
        }
    }
    try w.print("records checked: {d}\ntotal mismatches: {d}\n", .{ total, bad_all });
    try std.fs.File.stdout().writeAll(out.items);
    if (bad_all != 0) std.process.exit(1);
}
