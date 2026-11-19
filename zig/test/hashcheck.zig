//! hashcheck.zig - the operations of tests/stdcheck/hashcheck.cpp through the Zig runtime's unordered_map and
//! unordered_set (zig/rt/cont.zig HashTable, a port of libstdc++'s _Hashtable with its prime rehash policy) and
//! std::hash of strings; output must equal hashcheck.cpp's byte for byte. The maps are made as the generated engine
//! makes them (rt.UMap(K, V).new_FuncKul_FuncKKb_FuncV with the default hash and equality). After
//! php/test/hashcheck.php.
//! Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see ../README.md.
const std = @import("std");
const rt = @import("rt");
const A = std.heap.page_allocator;

var S: u64 = 52024;
fn rnd() u64 {
    S ^= S << 13;
    S ^= S >> 7;
    S ^= S << 17;
    return S;
}
const PRE = [_][]const u8{ "J", "C", "N", "OF", "P", "RG", "SUB_", "Link-", "node.", "W" };
fn name(r: u64) !?*rt.Str {
    var b: [64]u8 = undefined;
    var x = try std.fmt.bufPrint(&b, "{s}{d}", .{ PRE[r % 10], (r >> 8) % 5000 });
    if ((r >> 20) % 3 == 0) x = try std.fmt.bufPrint(&b, "{s}_{d}", .{ x, (r >> 24) % 97 });
    return rt.Str.newSlice(x);
}
fn text(s: ?*rt.Str) []u8 {
    return s.?.bytes();
}

pub fn main() !void {
    rt.init();
    var out: std.ArrayListUnmanaged(u8) = .{};
    const w = out.writer(A);
    const SM = rt.UMap(?*rt.Str, i32);
    const IM = rt.UMap(i32, i32);
    const SS = rt.USet(?*rt.Str);
    for (0..40) |round| {
        const m = (try SM.new_FuncKul_FuncKKb_FuncV(std.mem.zeroes(rt.Fn1(?*rt.Str, u64)), std.mem.zeroes(rt.Fn2(?*rt.Str, ?*rt.Str, bool)), std.mem.zeroes(rt.Fn0(i32)))).?;
        const mi = (try IM.new_FuncKul_FuncKKb_FuncV(std.mem.zeroes(rt.Fn1(i32, u64)), std.mem.zeroes(rt.Fn2(i32, i32, bool)), std.mem.zeroes(rt.Fn0(i32)))).?;
        const st = (try SS.new_FuncTul_FuncTTb(std.mem.zeroes(rt.Fn1(?*rt.Str, u64)), std.mem.zeroes(rt.Fn2(?*rt.Str, ?*rt.Str, bool)))).?;
        const n: u64 = 1 + rnd() % @as(u64, if (round < 20) 60 else 3000);
        if (round % 7 == 3) try m.reserve(n);
        for (0..n) |ii| {
            const i: i32 = @intCast(ii);
            const r = rnd();
            const k = try name(r);
            if (r % 5 == 0) {
                const v = try m.Index(k);
                v.* += i;
            } else _ = try m.emplace_K_V(k, i);
            _ = try mi.emplace_K_V(@as(i32, @intCast(r % 20000)) - 10000, i);
            _ = try st.insert(k);
            if (r % 11 == 0 and !(try m.empty())) _ = try m.erase_K(try name(rnd()));
            if (r % 13 == 0) _ = try mi.erase_K(@as(i32, @intCast(rnd() % 20000)) - 10000);
            if (r % 17 == 0 and !(try m.empty())) _ = try m.erase_MItE(try m.begin());
        }
        const c = (try m.Clone()).?;
        try w.print("map {d}: {d} buckets {d}:", .{ round, try m.bucket_count(), try m.size() });
        var it = try m.Items();
        while (it.next()) |kv| try w.print(" {s}={d}", .{ text(kv.?.first), kv.?.second });
        try w.writeAll("\ncopy:");
        var ic = try c.Items();
        while (ic.next()) |kv| try w.print(" {s}", .{text(kv.?.first)});
        try w.print("\nimap {d} {d}:", .{ try mi.bucket_count(), try mi.size() });
        var ii2 = try mi.Items();
        while (ii2.next()) |kv| try w.print(" {d}={d}", .{ kv.?.first, kv.?.second });
        try w.print("\nset {d}:", .{try st.bucket_count()});
        var is = try st.Items();
        while (is.next()) |k| try w.print(" {s}", .{text(k)});
        try w.writeAll("\n");
    }
    for ([_][]const u8{ "", "a", "abcdefg", "abcdefgh", "abcdefghi", "Junction_17", "OUTFALL-1" }) |s| {
        try w.print("hash {s} {d}\n", .{ s, rt.cont.Elem.hash(?*rt.Str, try rt.Str.newSlice(s)) });
    }
    try std.fs.File.stdout().writeAll(out.items);
}
