//! sortcheck.zig - the cases of tests/stdcheck/sortcheck.cpp through the Zig runtime's StdAlgo (zig/rt/cont.zig, a
//! port of libstdc++'s introsort, merge sort and heap sort); output must equal sortcheck.cpp's byte for byte.
//! Mode O: an array of structs ordered by a key field. I, D: the same permutations over int / double ids ordered by
//! their keys (the engine sorts int arrays with a lambda). P: pointers to objects ordered by a key field (the
//! engine sorts its event list this way). After php/test/sortcheck.php.
//! Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see ../README.md.
const std = @import("std");
const rt = @import("rt");
const A = std.heap.page_allocator;

var S: u64 = 1729;
fn rnd() u64 {
    S ^= S << 13;
    S ^= S >> 7;
    S ^= S << 17;
    return S;
}
const El = struct { key: i32, id: i32 };
var keys: []i32 = &.{};

fn ltEl(_: ?*anyopaque, a: El, b: El) rt.E!bool {
    return a.key < b.key;
}
fn ltPtr(_: ?*anyopaque, a: ?*El, b: ?*El) rt.E!bool {
    return a.?.key < b.?.key;
}
fn ltI(_: ?*anyopaque, a: i32, b: i32) rt.E!bool {
    return keys[@intCast(a)] < keys[@intCast(b)];
}
fn ltD(_: ?*anyopaque, a: f64, b: f64) rt.E!bool {
    return keys[@intFromFloat(a)] < keys[@intFromFloat(b)];
}

fn run(comptime T: type, mode: u8, n: usize, which: u8, out: *std.ArrayListUnmanaged(u8)) !void {
    const a = try A.alloc(T, @max(n, 1));
    for (0..n) |i| a[i] = switch (T) {
        El => .{ .key = keys[i], .id = @intCast(i) },
        ?*El => blk: {
            const p = try A.create(El);
            p.* = .{ .key = keys[i], .id = @intCast(i) };
            break :blk p;
        },
        i32 => @intCast(i),
        f64 => @floatFromInt(i),
        else => unreachable,
    };
    const cmp = rt.Fn2(T, T, bool){ .f = switch (T) {
        El => &ltEl,
        ?*El => &ltPtr,
        i32 => &ltI,
        f64 => &ltD,
        else => unreachable,
    } };
    _ = mode;
    const arr: ?[]T = a[0..n];
    const ln: i64 = @intCast(n);
    switch (which) {
        0 => try rt.StdAlgo.Sort(T, arr, 0, ln, cmp),
        1 => try rt.StdAlgo.StableSort(T, arr, 0, ln, cmp),
        else => try rt.StdAlgo.PartialSort(T, arr, 0, ln, ln, cmp),
    }
    const w = out.writer(A);
    for (a[0..n]) |x| {
        const id: i64 = switch (T) {
            El => x.id,
            ?*El => x.?.id,
            i32 => x,
            f64 => @intFromFloat(x),
            else => unreachable,
        };
        try w.print(" {d}", .{id});
    }
}

pub fn main() !void {
    rt.init();
    var args = std.process.args();
    _ = args.next();
    const mode = (args.next() orelse "O")[0];
    var out: std.ArrayListUnmanaged(u8) = .{};
    var ns: std.ArrayListUnmanaged(usize) = .{};
    for (0..301) |n| try ns.append(A, n);
    for ([_]usize{ 511, 512, 513, 1000, 4096, 10007 }) |n| try ns.append(A, n);
    for (ns.items) |n| {
        for (0..7) |pat| {
            keys = try A.alloc(i32, @max(n, 1));
            for (0..n) |i| {
                const ii: i64 = @intCast(i);
                const nn: i64 = @intCast(n);
                keys[i] = @intCast(switch (pat) {
                    0 => @as(i64, @intCast(rnd() % 5)),
                    1 => @as(i64, @intCast(rnd() % 1000000)),
                    2 => @divTrunc(ii, 3),
                    3 => @divTrunc(nn - ii, 2),
                    4 => 7,
                    5 => if (ii < @divTrunc(nn, 2)) ii else nn - ii,
                    else => @mod(ii * 7919, 31),
                });
            }
            for ([_][]const u8{ "sort", "stable", "heap" }, 0..) |tag, which| {
                try out.writer(A).print("{s} {d} {d}:", .{ tag, n, pat });
                switch (mode) {
                    'O' => try run(El, mode, n, @intCast(which), &out),
                    'P' => try run(?*El, mode, n, @intCast(which), &out),
                    'I' => try run(i32, mode, n, @intCast(which), &out),
                    'D' => try run(f64, mode, n, @intCast(which), &out),
                    else => return error.Mode,
                }
                try out.append(A, '\n');
            }
        }
    }
    try std.fs.File.stdout().writeAll(out.items);
}
