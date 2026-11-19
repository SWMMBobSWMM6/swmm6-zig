//! str.zig - std::string (and std::string_view, which the engine only reads) as a mutable byte sequence, so
//! lengths, comparisons and printf padding count bytes as libstdc++ does. c_str() hands out a NUL-terminated
//! char* over the same buffer; npos is the largest u64, as in C++. After cs/runtime/Str.cs.
//! Written by Claude (Anthropic) for the SWMM6 ports; see AI-USE.md.
const std = @import("std");
const rt = @import("rt.zig");
const E = rt.E;
const crt = @import("crt.zig");

pub const Str = struct {
    b: ?[]u8, // capacity >= n + 1; b[n] == 0 whenever c_str() is taken
    n: i32,
    pub const __rt = true;
    pub const npos: u64 = std.math.maxInt(u64);
    const Self = @This();

    fn alloc(cap: usize) []u8 {
        return rt.gcSlice(u8, if (cap < 1) 1 else cap);
    }

    pub fn newSlice(s: []const u8) E!?*Str {
        const o = rt.gcNew(Str);
        const b = alloc(s.len + 1);
        @memcpy(b[0..s.len], s);
        o.b = b;
        o.n = @intCast(s.len);
        return o;
    }
    pub fn newLit(comptime s: []const u8) E!?*Str {
        return newSlice(s);
    }
    pub fn bytes(self: *const Str) []u8 {
        return self.b.?[0..@intCast(self.n)];
    }

    pub fn new() E!?*Str {
        const o = rt.gcNew(Str);
        o.b = alloc(16);
        o.n = 0;
        return o;
    }
    pub const __new = new;
    pub fn new_Str(s: ?*Str) E!?*Str {
        return newSlice(s.?.bytes());
    }
    pub fn new_CPtr(p: ?[*]u8) E!?*Str {
        return newSlice(p.?[0..crt.slen(p)]);
    }
    pub fn fromCPtr(p: ?[*]u8) E!?*Str {
        return new_CPtr(p);
    }
    pub fn new_CPtr_ul(p: ?[*]u8, len: u64) E!?*Str {
        if (len == 0) return newSlice("");
        return newSlice(p.?[0..@intCast(len)]);
    }
    pub fn new_ul_i(count: u64, ch: i32) E!?*Str {
        const o = rt.gcNew(Str);
        const m: usize = @intCast(count);
        o.b = alloc(m + 1);
        @memset(o.b.?[0..m], @truncate(@as(u32, @bitCast(ch))));
        o.n = @intCast(m);
        return o;
    }

    fn reserveCap(self: *Str, need: usize) void {
        if (need + 1 <= self.b.?.len) return;
        const cap = @max(need + 1, self.b.?.len * 2);
        const nb = alloc(cap);
        @memcpy(nb[0..@intCast(self.n)], self.b.?[0..@intCast(self.n)]);
        self.b = nb;
    }

    pub fn size(self: *Str) E!u64 {
        return @intCast(self.n);
    }
    pub fn length(self: *Str) E!u64 {
        return @intCast(self.n);
    }
    pub fn empty(self: *Str) E!bool {
        return self.n == 0;
    }
    pub fn clear(self: *Str) E!void {
        self.n = 0;
    }
    pub fn cstr(self: *Str) ?[*]u8 {
        self.reserveCap(@intCast(self.n));
        self.b.?[@intCast(self.n)] = 0;
        return self.b.?.ptr;
    }
    pub fn c_str(self: *Str) E!?[*]u8 {
        return self.cstr();
    }
    pub fn data(self: *Str) E!?[*]u8 {
        return self.cstr();
    }
    pub fn front(self: *Str) E!*u8 {
        return &self.b.?[0];
    }
    pub fn back(self: *Str) E!*u8 {
        return &self.b.?[@intCast(self.n - 1)];
    }
    pub fn at(self: *Str, i: u64) E!u8 {
        if (i >= @as(u64, @intCast(self.n))) {
            var buf: [160]u8 = undefined;
            const m = std.fmt.bufPrint(&buf, "basic_string::at: __n (which is {d}) >= this->size() (which is {d})", .{ i, self.n }) catch unreachable;
            return rt.throwExc(try rt.CppException.makeLit(rt.K_out_of_range, m));
        }
        return self.b.?[@intCast(i)];
    }

    pub fn Clone(self: *Str) E!?*Str {
        return newSlice(self.bytes());
    }
    pub fn __clone(x: ?*Str) E!?*Str {
        return x.?.Clone();
    }
    pub fn Assign_Str(self: *Str, o: ?*Str) E!void {
        if (self == o.?) return;
        const src = o.?.bytes();
        self.reserveCap(src.len);
        @memcpy(self.b.?[0..src.len], src);
        self.n = @intCast(src.len);
    }
    pub fn __assign(self: ?*Str, o: ?*Str) E!void {
        return self.?.Assign_Str(o);
    }
    pub fn Assign_CPtr(self: *Str, p: ?[*]u8) E!void {
        const m = crt.slen(p);
        const t = alloc(m + 1);
        @memcpy(t[0..m], p.?[0..m]);
        self.b = t;
        self.n = @intCast(m);
    }
    pub fn Assign_i(self: *Str, ch: i32) E!void {
        self.reserveCap(1);
        self.b.?[0] = @truncate(@as(u32, @bitCast(ch)));
        self.n = 1;
    }
    pub fn MoveFrom(self: *Str, o: ?*Str) E!void {
        if (self == o.?) return;
        self.b = o.?.b;
        self.n = o.?.n;
        o.?.b = alloc(16);
        o.?.n = 0;
    }
    pub fn __moveFrom(self: ?*Str, o: ?*Str) E!void {
        return self.?.MoveFrom(o);
    }
    pub fn assign_Str(self: *Str, o: ?*Str) E!?*Str {
        try self.Assign_Str(o);
        return self;
    }
    pub fn assign_CPtr(self: *Str, p: ?[*]u8) E!?*Str {
        try self.Assign_CPtr(p);
        return self;
    }
    pub fn assign_CPtr_ul(self: *Str, p: ?[*]u8, len: u64) E!?*Str {
        const m: usize = @intCast(len);
        const t = alloc(m + 1);
        if (m != 0) @memcpy(t[0..m], p.?[0..m]);
        self.b = t;
        self.n = @intCast(m);
        return self;
    }
    pub fn assign_CPtr_CPtr(self: *Str, b0: ?[*]u8, e0: ?[*]u8) E!?*Str {
        return self.assign_CPtr_ul(b0, @intCast(rt.pdiff(e0, b0)));
    }
    pub fn assign_Ptrc_Ptrc(self: *Str, b0: ?[*]i8, e0: ?[*]i8) E!?*Str {
        return self.assign_CPtr_ul(@ptrCast(b0), @intCast(rt.pdiff(e0, b0)));
    }
    pub fn assign_ul_i(self: *Str, count: u64, ch: i32) E!?*Str {
        const m: usize = @intCast(count);
        self.reserveCap(m);
        @memset(self.b.?[0..m], @truncate(@as(u32, @bitCast(ch))));
        self.n = @intCast(m);
        return self;
    }

    fn appendBytes(self: *Str, src: []const u8) void {
        const n: usize = @intCast(self.n);
        self.reserveCap(n + src.len);
        @memcpy(self.b.?[n .. n + src.len], src);
        self.n = @intCast(n + src.len);
    }
    pub fn append_Str(self: *Str, o: ?*Str) E!?*Str {
        self.appendBytes(o.?.bytes());
        return self;
    }
    pub fn append_Str_ul_ul(self: *Str, o: ?*Str, pos: u64, len: u64) E!?*Str {
        const p: usize = @intCast(pos);
        const m = @min(len, @as(u64, @intCast(o.?.n)) - pos);
        self.appendBytes(o.?.b.?[p .. p + @as(usize, @intCast(m))]);
        return self;
    }
    pub fn append_CPtr(self: *Str, p: ?[*]u8) E!?*Str {
        self.appendBytes(p.?[0..crt.slen(p)]);
        return self;
    }
    pub fn append_CPtr_ul(self: *Str, p: ?[*]u8, len: u64) E!?*Str {
        if (len == 0) return self;
        self.appendBytes(p.?[0..@intCast(len)]);
        return self;
    }
    pub fn append_ul_i(self: *Str, count: u64, ch: i32) E!?*Str {
        const n: usize = @intCast(self.n);
        const m: usize = @intCast(count);
        self.reserveCap(n + m);
        @memset(self.b.?[n .. n + m], @truncate(@as(u32, @bitCast(ch))));
        self.n = @intCast(n + m);
        return self;
    }
    pub fn append_i(self: *Str, ch: i32) E!?*Str {
        return self.append_ul_i(1, ch);
    }
    pub fn push_back(self: *Str, ch: i32) E!void {
        const n: usize = @intCast(self.n);
        self.reserveCap(n + 1);
        self.b.?[n] = @truncate(@as(u32, @bitCast(ch)));
        self.n += 1;
    }
    pub fn pop_back(self: *Str) E!void {
        self.n -= 1;
    }
    pub fn resize(self: *Str, m: u64, ch: i32) E!void {
        const k: usize = @intCast(m);
        self.reserveCap(k);
        var i: usize = @intCast(self.n);
        while (i < k) : (i += 1) self.b.?[i] = @truncate(@as(u32, @bitCast(ch)));
        self.n = @intCast(k);
    }
    pub fn reserve(self: *Str, m: u64) E!void {
        self.reserveCap(@intCast(m));
    }
    pub fn shrink_to_fit(self: *Str) E!void {
        _ = self;
    }
    pub fn remove_prefix(self: *Str, k: u64) E!void {
        const m: usize = @intCast(k);
        const n: usize = @intCast(self.n);
        std.mem.copyForwards(u8, self.b.?[0 .. n - m], self.b.?[m..n]);
        self.n = @intCast(n - m);
        self.b.?[n - m] = 0;
    }
    pub fn remove_suffix(self: *Str, k: u64) E!void {
        self.n -= @intCast(k);
        self.b.?[@intCast(self.n)] = 0;
    }

    pub fn substr(self: *Str, pos: u64, len: u64) E!?*Str {
        const n: u64 = @intCast(self.n);
        if (pos > n) {
            var buf: [160]u8 = undefined;
            const m = std.fmt.bufPrint(&buf, "basic_string::substr: __pos (which is {d}) > this->size() (which is {d})", .{ pos, n }) catch unreachable;
            return rt.throwExc(try rt.CppException.makeLit(rt.K_out_of_range, m));
        }
        const m = @min(len, n - pos);
        const p: usize = @intCast(pos);
        return newSlice(self.b.?[p .. p + @as(usize, @intCast(m))]);
    }
    pub fn erase(self: *Str, pos: u64, len: u64) E!?*Str {
        const n: usize = @intCast(self.n);
        const p: usize = @intCast(pos);
        const m: usize = @intCast(@min(len, @as(u64, n - p)));
        std.mem.copyForwards(u8, self.b.?[p .. n - m], self.b.?[p + m .. n]);
        self.n = @intCast(n - m);
        return self;
    }
    pub fn insert_ul_Str(self: *Str, pos: u64, s: ?*Str) E!?*Str {
        const n: usize = @intCast(self.n);
        const p: usize = @intCast(pos);
        const src = try s.?.Clone();
        const k: usize = @intCast(src.?.n);
        self.reserveCap(n + k);
        std.mem.copyBackwards(u8, self.b.?[p + k .. n + k], self.b.?[p..n]);
        @memcpy(self.b.?[p .. p + k], src.?.bytes());
        self.n = @intCast(n + k);
        return self;
    }

    fn inSet(c: u8, set: []const u8) bool {
        for (set) |x| {
            if (x == c) return true;
        }
        return false;
    }
    fn findBytes(self: *Str, s: []const u8, pos: u64) u64 {
        const n: u64 = @intCast(self.n);
        if (s.len == 0) return if (pos <= n) pos else npos;
        var i: u64 = pos;
        while (i + s.len <= n) : (i += 1) {
            if (std.mem.eql(u8, self.b.?[@intCast(i)..@intCast(i + s.len)], s)) return i;
        }
        return npos;
    }
    fn rfindBytes(self: *Str, s: []const u8, pos: u64) u64 {
        const n: u64 = @intCast(self.n);
        if (s.len > n) return npos;
        var i: i64 = @intCast(@min(pos, n - s.len));
        while (i >= 0) : (i -= 1) {
            const k: usize = @intCast(i);
            if (std.mem.eql(u8, self.b.?[k .. k + s.len], s)) return @intCast(i);
        }
        return npos;
    }
    pub fn find_Str_ul(self: *Str, s: ?*Str, pos: u64) E!u64 {
        return self.findBytes(s.?.bytes(), pos);
    }
    pub fn find_CPtr_ul(self: *Str, s: ?[*]u8, pos: u64) E!u64 {
        return self.findBytes(s.?[0..crt.slen(s)], pos);
    }
    pub fn find_i_ul(self: *Str, ch: i32, pos: u64) E!u64 {
        const c: u8 = @truncate(@as(u32, @bitCast(ch)));
        var i: u64 = pos;
        while (i < @as(u64, @intCast(self.n))) : (i += 1) {
            if (self.b.?[@intCast(i)] == c) return i;
        }
        return npos;
    }
    pub fn rfind_Str_ul(self: *Str, s: ?*Str, pos: u64) E!u64 {
        return self.rfindBytes(s.?.bytes(), pos);
    }
    pub fn rfind_CPtr_ul(self: *Str, s: ?[*]u8, pos: u64) E!u64 {
        return self.rfindBytes(s.?[0..crt.slen(s)], pos);
    }
    pub fn rfind_i_ul(self: *Str, ch: i32, pos: u64) E!u64 {
        if (self.n == 0) return npos;
        const c: u8 = @truncate(@as(u32, @bitCast(ch)));
        var i: i64 = @intCast(@min(pos, @as(u64, @intCast(self.n - 1))));
        while (i >= 0) : (i -= 1) {
            if (self.b.?[@intCast(i)] == c) return @intCast(i);
        }
        return npos;
    }
    fn firstOf(self: *Str, set: []const u8, pos: u64, want: bool) u64 {
        var i: u64 = pos;
        while (i < @as(u64, @intCast(self.n))) : (i += 1) {
            if (inSet(self.b.?[@intCast(i)], set) == want) return i;
        }
        return npos;
    }
    fn lastOf(self: *Str, set: []const u8, pos: u64, want: bool) u64 {
        if (self.n == 0) return npos;
        var i: i64 = @intCast(@min(pos, @as(u64, @intCast(self.n - 1))));
        while (i >= 0) : (i -= 1) {
            if (inSet(self.b.?[@intCast(i)], set) == want) return @intCast(i);
        }
        return npos;
    }
    pub fn find_first_of_Str_ul(self: *Str, set: ?*Str, pos: u64) E!u64 {
        return self.firstOf(set.?.bytes(), pos, true);
    }
    pub fn find_first_of_CPtr_ul(self: *Str, set: ?[*]u8, pos: u64) E!u64 {
        return self.firstOf(set.?[0..crt.slen(set)], pos, true);
    }
    pub fn find_first_of_i_ul(self: *Str, ch: i32, pos: u64) E!u64 {
        return self.find_i_ul(ch, pos);
    }
    pub fn find_first_not_of_Str_ul(self: *Str, set: ?*Str, pos: u64) E!u64 {
        return self.firstOf(set.?.bytes(), pos, false);
    }
    pub fn find_first_not_of_CPtr_ul(self: *Str, set: ?[*]u8, pos: u64) E!u64 {
        return self.firstOf(set.?[0..crt.slen(set)], pos, false);
    }
    pub fn find_first_not_of_i_ul(self: *Str, ch: i32, pos: u64) E!u64 {
        const c = [1]u8{@truncate(@as(u32, @bitCast(ch)))};
        return self.firstOf(&c, pos, false);
    }
    pub fn find_last_of_Str_ul(self: *Str, set: ?*Str, pos: u64) E!u64 {
        return self.lastOf(set.?.bytes(), pos, true);
    }
    pub fn find_last_of_CPtr_ul(self: *Str, set: ?[*]u8, pos: u64) E!u64 {
        return self.lastOf(set.?[0..crt.slen(set)], pos, true);
    }
    pub fn find_last_of_i_ul(self: *Str, ch: i32, pos: u64) E!u64 {
        return self.rfind_i_ul(ch, pos);
    }
    pub fn find_last_not_of_Str_ul(self: *Str, set: ?*Str, pos: u64) E!u64 {
        return self.lastOf(set.?.bytes(), pos, false);
    }
    pub fn find_last_not_of_CPtr_ul(self: *Str, set: ?[*]u8, pos: u64) E!u64 {
        return self.lastOf(set.?[0..crt.slen(set)], pos, false);
    }
    pub fn find_last_not_of_i_ul(self: *Str, ch: i32, pos: u64) E!u64 {
        const c = [1]u8{@truncate(@as(u32, @bitCast(ch)))};
        return self.lastOf(&c, pos, false);
    }

    pub fn starts_with_Str(self: *Str, s: ?*Str) E!bool {
        return std.mem.startsWith(u8, self.bytes(), s.?.bytes());
    }
    pub fn starts_with_CPtr(self: *Str, s: ?[*]u8) E!bool {
        return std.mem.startsWith(u8, self.bytes(), s.?[0..crt.slen(s)]);
    }
    pub fn starts_with_i(self: *Str, ch: i32) E!bool {
        return self.n > 0 and self.b.?[0] == @as(u8, @truncate(@as(u32, @bitCast(ch))));
    }
    pub fn ends_with_Str(self: *Str, s: ?*Str) E!bool {
        return std.mem.endsWith(u8, self.bytes(), s.?.bytes());
    }
    pub fn ends_with_CPtr(self: *Str, s: ?[*]u8) E!bool {
        return std.mem.endsWith(u8, self.bytes(), s.?[0..crt.slen(s)]);
    }

    /// char_traits<char>::compare is memcmp: unsigned bytes, then length
    pub fn cmp(a: []const u8, b: []const u8) i32 {
        const m = @min(a.len, b.len);
        for (0..m) |i| {
            if (a[i] != b[i]) return if (a[i] < b[i]) -1 else 1;
        }
        const d: i64 = @as(i64, @intCast(a.len)) - @as(i64, @intCast(b.len));
        return if (d > std.math.maxInt(i32)) std.math.maxInt(i32) else if (d < std.math.minInt(i32)) std.math.minInt(i32) else @intCast(d);
    }
    pub fn compare_Str(self: *Str, o: ?*Str) E!i32 {
        return cmp(self.bytes(), o.?.bytes());
    }
    pub fn compare_CPtr(self: *Str, o: ?[*]u8) E!i32 {
        return cmp(self.bytes(), o.?[0..crt.slen(o)]);
    }
    pub fn compare_ul_ul_Str(self: *Str, pos: u64, len: u64, o: ?*Str) E!i32 {
        const s = try self.substr(pos, len);
        return cmp(s.?.bytes(), o.?.bytes());
    }
    pub fn Equals_Str(self: *Str, o: ?*Str) E!bool {
        const x = o orelse return false;
        return std.mem.eql(u8, self.bytes(), x.bytes());
    }
    pub fn EqLit(self: *Str, p: ?[*]u8) E!bool {
        return std.mem.eql(u8, self.bytes(), p.?[0..crt.slen(p)]);
    }
    pub fn ToString(self: *Str) E!?[]const u8 {
        return self.bytes();
    }

    pub fn begin(self: *Str) E!rt.Iter(u8) {
        return .{ .a = self.b.?.ptr, .i = 0 };
    }
    pub fn end(self: *Str) E!rt.Iter(u8) {
        return .{ .a = self.b.?.ptr, .i = self.n };
    }

    pub fn Cat_Str_Str(x: ?*Str, y: ?*Str) E!?*Str {
        const r = try newSlice(x.?.bytes());
        _ = try r.?.append_Str(y);
        return r;
    }
    pub fn Cat_Str_CPtr(x: ?*Str, y: ?[*]u8) E!?*Str {
        const r = try newSlice(x.?.bytes());
        _ = try r.?.append_CPtr(y);
        return r;
    }
    pub fn Cat_CPtr_Str(x: ?[*]u8, y: ?*Str) E!?*Str {
        const r = try new_CPtr(x);
        _ = try r.?.append_Str(y);
        return r;
    }
    pub fn Cat_Str_i(x: ?*Str, ch: i32) E!?*Str {
        const r = try newSlice(x.?.bytes());
        try r.?.push_back(ch);
        return r;
    }

    // ---- std::to_string / std::stod (libstdc++: to_string(double) is "%f")
    pub fn to_string_i(v: i32) E!?*Str {
        var buf: [32]u8 = undefined;
        return newSlice(std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable);
    }
    pub fn to_string_l(v: i64) E!?*Str {
        var buf: [32]u8 = undefined;
        return newSlice(std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable);
    }
    pub fn to_string_u(v: u32) E!?*Str {
        var buf: [32]u8 = undefined;
        return newSlice(std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable);
    }
    pub fn to_string_ul(v: u64) E!?*Str {
        var buf: [32]u8 = undefined;
        return newSlice(std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable);
    }
    pub fn to_string_d(v: f64) E!?*Str {
        var buf: [400]u8 = undefined;
        const n = crt.formatInto(&buf, "%f", .{v});
        return newSlice(buf[0..n]);
    }

    /// std::stod (libstdc++'s __stoa over strtod): invalid_argument("stod") when nothing converts,
    /// out_of_range("stod") when strtod sets ERANGE (overflow, or an underflow).
    pub fn stod(s: ?*Str, idx: ?[*]u64) E!f64 {
        const p = s.?.cstr();
        var endp: ?[*]u8 = p;
        const v = crt.strtodRange(p, &endp);
        if (endp == p) return rt.throwExc(try rt.CppException.makeLit(rt.K_invalid_argument, "stod"));
        if (crt.erange) return rt.throwExc(try rt.CppException.makeLit(rt.K_out_of_range, "stod"));
        if (idx != null) idx.?[0] = @intCast(rt.pdiff(endp, p));
        return v;
    }
};
