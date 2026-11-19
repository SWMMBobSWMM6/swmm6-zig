//! cont.zig - the C++ containers and algorithms the engine uses, after cs/runtime (Std.cs, Containers.cs,
//! StdAlgo.cs, Misc.cs): std::vector (Vec), its iterators, std::pair, std::optional, std::unordered_map and
//! unordered_set with libstdc++'s exact node order (one singly linked list, a bucket array pointing at the node
//! before each bucket's first node, new nodes at the front of their bucket, the prime rehash policy), std::map and
//! std::set (sorted), std::stack and std::queue, <algorithm> with libstdc++'s introsort, and the C# runtime's
//! helpers for raw memory, moves and arrays. The engine iterates hashed containers, so their order reaches its
//! output; tests/stdcheck compares it with libstdc++'s.
//! Written by Claude (Anthropic) for the SWMM6 ports; see AI-USE.md.
const std = @import("std");
const rt = @import("rt.zig");
const E = rt.E;
const Str = @import("str.zig").Str;
const primes = @import("primes.zig");
const crt = @import("crt.zig");

// ================================================================ elements: make, copy, compare, hash
fn ClassOf(comptime T: type) ?type {
    switch (@typeInfo(T)) {
        .optional => |o| switch (@typeInfo(o.child)) {
            .pointer => |p| if (p.size == .one and @typeInfo(p.child) == .@"struct") return p.child,
            else => {},
        },
        else => {},
    }
    return null;
}

fn isSlice(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .optional => |o| switch (@typeInfo(o.child)) {
            .pointer => |p| p.size == .slice,
            else => false,
        },
        else => false,
    };
}

pub const Elem = struct {
    /// C#'s Elem<T>.IsClass: an engine or runtime class with copy semantics
    pub fn isClass(comptime T: type) bool {
        const C = ClassOf(T) orelse return false;
        return @hasDecl(C, "__clone");
    }
    pub fn needsCopy(comptime T: type) bool {
        return isClass(T) or isSlice(T);
    }
    /// Elem<T>.Make: a class's default constructor; a value's zero; null for anything else
    pub fn make(comptime T: type) E!T {
        if (ClassOf(T)) |C| {
            if (@hasDecl(C, "__new")) return C.__new();
            return null;
        }
        return std.mem.zeroes(T);
    }
    /// Elem<T>.Copy: a class is cloned, an array copied deeply, a value copied
    pub fn copy(comptime T: type, x: T) E!T {
        if (comptime isClass(T)) {
            const C = ClassOf(T).?;
            const v = x orelse return null;
            return C.__clone(v);
        }
        if (comptime isSlice(T)) {
            const a = x orelse return null;
            const U = @typeInfo(@typeInfo(T).optional.child).pointer.child;
            const b = rt.gcSlice(U, a.len);
            for (a, 0..) |e, i| b[i] = try copy(U, e);
            return b;
        }
        return x;
    }
    pub fn assign(comptime T: type, dst: T, src: T) E!void {
        const C = ClassOf(T).?;
        return C.__assign(dst, src);
    }
    /// EqualityComparer<T>.Default
    pub fn eq(comptime T: type, a: T, b: T) bool {
        if (T == ?*Str) {
            if (a == null or b == null) return a == null and b == null;
            return std.mem.eql(u8, a.?.bytes(), b.?.bytes());
        }
        if (T == ?*TupN) {
            if (a == null or b == null) return a == null and b == null;
            return TupN.cmp(a.?, b.?) == 0;
        }
        switch (@typeInfo(T)) {
            .float => return a == b or (std.math.isNan(a) and std.math.isNan(b)),
            .int, .bool, .@"enum" => return a == b,
            .optional => |o| switch (@typeInfo(o.child)) {
                .pointer => |p| if (p.size == .slice) {
                    if (a == null or b == null) return a == null and b == null;
                    return a.?.ptr == b.?.ptr and a.?.len == b.?.len;
                } else return a == b,
                else => return std.meta.eql(a, b),
            },
            else => return std.meta.eql(a, b),
        }
    }
    /// Comparer<T>.Default.Compare(a, b) < 0 (Less<T>.Fn)
    pub fn less(comptime T: type, a: T, b: T) bool {
        if (T == ?*Str) return Str.cmp(a.?.bytes(), b.?.bytes()) < 0;
        if (T == ?*TupN) return TupN.cmp(a.?, b.?) < 0;
        if (comptime ClassOf(T)) |C| {
            if (@hasDecl(C, "CompareTo")) return a.?.CompareTo(b) < 0;
            return @intFromPtr(a) < @intFromPtr(b);
        }
        switch (@typeInfo(T)) {
            .float => return a < b or (std.math.isNan(a) and !std.math.isNan(b)),
            .int => return a < b,
            .bool => return !a and b,
            else => return @intFromPtr(a) < @intFromPtr(b),
        }
    }
    /// std::hash as libstdc++ computes it (StdHash.For in Containers.cs)
    pub fn hash(comptime T: type, x: T) u64 {
        if (T == ?*Str) return hashBytes(x.?.bytes(), 0xc70f6907);
        switch (@typeInfo(T)) {
            .int => |i| return if (i.signedness == .signed) @bitCast(@as(i64, x)) else @as(u64, x),
            .bool => return @intFromBool(x),
            .float => {
                const d: f64 = x;
                if (d == 0.0) return 0;
                const bb: [8]u8 = @bitCast(d);
                return hashBytes(&bb, 0xc70f6907);
            },
            else => return @intFromPtr(x),
        }
    }
};

/// libstdc++'s std::_Hash_bytes (libsupc++/hash_bytes.cc, the 64-bit branch)
pub fn hashBytes(b: []const u8, seed: u64) u64 {
    const mul: u64 = (@as(u64, 0xc6a4a793) << 32) + 0x5bd1e995;
    const len = b.len;
    const aligned = len & ~@as(usize, 7);
    var h: u64 = seed ^ (@as(u64, len) *% mul);
    var p: usize = 0;
    while (p < aligned) : (p += 8) {
        const data = shiftMix(std.mem.readInt(u64, b[p..][0..8], .little) *% mul) *% mul;
        h ^= data;
        h *%= mul;
    }
    const rest = len & 7;
    if (rest != 0) {
        var data: u64 = 0;
        var n: usize = rest;
        while (n > 0) {
            n -= 1;
            data = (data << 8) + b[p + n];
        }
        h ^= data;
        h *%= mul;
    }
    h = shiftMix(h) *% mul;
    h = shiftMix(h);
    return h;
}

fn shiftMix(v: u64) u64 {
    return v ^ (v >> 47);
}

pub fn Less(comptime T: type) type {
    return struct {
        fn thunk(_: ?*anyopaque, a: T, b: T) E!bool {
            return Elem.less(T, a, b);
        }
        pub const Fn = rt.Fn2(T, T, bool){ .ctx = null, .f = &thunk };
    };
}

// ================================================================ std::vector
pub fn Vec(comptime T: type) type {
    return struct {
        a: ?[]T,
        n: i32,
        mk: rt.Fn0(T),
        pub const __rt = true;
        const Self = @This();
        const empty_storage: [0]T = .{};

        fn raw() *Self {
            const v = rt.gcNew(Self);
            v.a = @constCast(&empty_storage);
            return v;
        }
        fn makeElem(self: *Self) E!T {
            if (self.mk.f != null) return self.mk.call();
            return Elem.make(T);
        }
        fn fill(self: *Self, from: usize, to: usize) E!void {
            if (self.mk.f != null) {
                for (from..to) |i| self.a.?[i] = try self.mk.call();
            } else if (comptime ClassOf(T) != null) {
                for (from..to) |i| self.a.?[i] = try Elem.make(T);
            }
        }
        pub fn new() E!?*Self {
            return raw();
        }
        pub const __new = new;
        pub fn new_FuncT(mk: rt.Fn0(T)) E!?*Self {
            const v = raw();
            v.mk = mk;
            return v;
        }
        pub fn new_ul_FuncT(count: u64, mk: rt.Fn0(T)) E!?*Self {
            const v = raw();
            v.mk = mk;
            v.a = rt.gcSlice(T, @intCast(count));
            v.n = @intCast(count);
            try v.fill(0, @intCast(count));
            return v;
        }
        pub fn new_ul(count: u64) E!?*Self {
            const v = raw();
            v.a = rt.gcSlice(T, @intCast(count));
            v.n = @intCast(count);
            try v.fill(0, @intCast(count));
            return v;
        }
        pub fn new_ul_T(count: u64, x0: T) E!?*Self {
            var x = x0; // a copy: Zig may pass an aggregate argument by reference (lessons/61)
            _ = &x;
            const v = raw();
            v.a = rt.gcSlice(T, @intCast(count));
            v.n = @intCast(count);
            for (v.a.?) |*e| e.* = try Elem.copy(T, x);
            return v;
        }
        pub fn new_TA(init: ?[]T) E!?*Self {
            const v = raw();
            const src = init.?;
            v.a = rt.gcSlice(T, src.len);
            v.n = @intCast(src.len);
            for (src, 0..) |x, i| v.a.?[i] = try Elem.copy(T, x);
            return v;
        }
        /// ~vector: each element in order, first to last
        pub fn DestroyElems(self: *Self) E!void {
            for (self.a.?[0..@intCast(self.n)]) |x| try rt.Dtor.Run(x);
        }
        inline fn items(self: *Self) []T {
            return self.a.?[0..@intCast(self.n)];
        }
        pub fn size(self: *Self) E!u64 {
            return @intCast(self.n);
        }
        pub fn empty(self: *Self) E!bool {
            return self.n == 0;
        }
        pub fn capacity(self: *Self) E!u64 {
            return self.a.?.len;
        }
        pub fn at(self: *Self, i: u64) E!*T {
            if (i >= @as(u64, @intCast(self.n))) {
                var buf: [160]u8 = undefined;
                const m = std.fmt.bufPrint(&buf, "vector::_M_range_check: __n (which is {d}) >= this->size() (which is {d})", .{ i, self.n }) catch unreachable;
                return rt.throwExc(try rt.CppException.makeLit(rt.K_out_of_range, m));
            }
            return &self.a.?[@intCast(i)];
        }
        pub fn front(self: *Self) E!*T {
            return &self.a.?[0];
        }
        pub fn back(self: *Self) E!*T {
            return &self.a.?[@intCast(self.n - 1)];
        }
        /// libstdc++'s data() is nullptr until the vector first allocates (lessons/27)
        pub fn data(self: *Self) E!?[*]T {
            if (self.a.?.len == 0) return null;
            return self.a.?.ptr;
        }
        fn resizeCap(self: *Self, cap: usize) void {
            const nb = rt.gcSlice(T, cap);
            const k = @min(cap, self.a.?.len);
            @memcpy(nb[0..k], self.a.?[0..k]);
            self.a = nb;
        }
        fn grow(self: *Self, need: usize) void {
            if (need <= self.a.?.len) return;
            const n: usize = @intCast(self.n);
            // libstdc++: new capacity = size + max(size, 1) when push_back runs out
            self.resizeCap(@max(need, n + @max(n, 1)));
        }
        pub fn reserve(self: *Self, c: u64) E!void {
            if (@as(usize, @intCast(c)) > self.a.?.len) self.resizeCap(@intCast(c));
        }
        pub fn push_back(self: *Self, x0: T) E!void {
            var x = x0;
            _ = &x;
            const n: usize = @intCast(self.n);
            self.grow(n + 1);
            self.a.?[n] = x;
            self.n += 1;
        }
        pub fn emplace_back(self: *Self, x: T) E!*T {
            try self.push_back(x);
            return &self.a.?[@intCast(self.n - 1)];
        }
        pub fn pop_back(self: *Self) E!void {
            self.n -= 1;
            self.a.?[@intCast(self.n)] = std.mem.zeroes(T);
        }
        pub fn clear(self: *Self) E!void {
            @memset(self.a.?[0..@intCast(self.n)], std.mem.zeroes(T));
            self.n = 0;
        }
        pub fn resize_ul(self: *Self, c: u64) E!void {
            const m: usize = @intCast(c);
            const n: usize = @intCast(self.n);
            if (m > n) {
                self.grow(m);
                try self.fill(n, m);
            } else @memset(self.a.?[m..n], std.mem.zeroes(T));
            self.n = @intCast(m);
        }
        pub fn resize_ul_T(self: *Self, c: u64, x0: T) E!void {
            var x = x0;
            _ = &x;
            const m: usize = @intCast(c);
            const n: usize = @intCast(self.n);
            if (m > n) {
                self.grow(m);
                for (n..m) |i| self.a.?[i] = try Elem.copy(T, x);
            } else @memset(self.a.?[m..n], std.mem.zeroes(T));
            self.n = @intCast(m);
        }
        pub fn assign_ul_T(self: *Self, c: u64, x0: T) E!void {
            var x = x0;
            _ = &x;
            const m: usize = @intCast(c);
            if (m > self.a.?.len) self.a = rt.gcSlice(T, m) else @memset(self.a.?, std.mem.zeroes(T));
            for (0..m) |i| self.a.?[i] = try Elem.copy(T, x);
            self.n = @intCast(m);
        }
        pub fn assign_IterT_IterT(self: *Self, b: Iter(T), e: Iter(T)) E!void {
            const m: usize = @intCast(e.i - b.i);
            const na = rt.gcSlice(T, m);
            for (0..m) |i| na[i] = try Elem.copy(T, b.a.?[@as(usize, @intCast(b.i)) + i]);
            self.a = na;
            self.n = @intCast(m);
        }
        pub fn assign_TA(self: *Self, il: ?[]T) E!void {
            const src = il.?;
            const na = rt.gcSlice(T, src.len);
            for (src, 0..) |x, i| na[i] = try Elem.copy(T, x);
            self.a = na;
            self.n = @intCast(src.len);
        }
        pub fn shrink_to_fit(self: *Self) E!void {
            if (self.a.?.len != @as(usize, @intCast(self.n))) self.resizeCap(@intCast(self.n));
        }
        pub fn swap(self: *Self, o: ?*Self) E!void {
            const ta = self.a;
            const tn = self.n;
            self.a = o.?.a;
            self.n = o.?.n;
            o.?.a = ta;
            o.?.n = tn;
        }
        pub fn begin(self: *Self) E!Iter(T) {
            return .{ .a = self.a.?.ptr, .i = 0 };
        }
        pub fn end(self: *Self) E!Iter(T) {
            return .{ .a = self.a.?.ptr, .i = self.n };
        }
        pub fn cbegin(self: *Self) E!Iter(T) {
            return self.begin();
        }
        pub fn cend(self: *Self) E!Iter(T) {
            return self.end();
        }
        pub fn rbegin(self: *Self) E!RevIter(T) {
            return .{ .v = self, .i = self.n };
        }
        pub fn rend(self: *Self) E!RevIter(T) {
            return .{ .v = self, .i = 0 };
        }
        fn openGap(self: *Self, p: usize, m: usize) void {
            const n: usize = @intCast(self.n);
            self.grow(n + m);
            std.mem.copyBackwards(T, self.a.?[p + m .. n + m], self.a.?[p..n]);
            self.n = @intCast(n + m);
        }
        pub fn insert_IterT_T(self: *Self, pos: Iter(T), x0: T) E!Iter(T) {
            var x = x0;
            _ = &x;
            const p: usize = @intCast(pos.i);
            self.openGap(p, 1);
            self.a.?[p] = x;
            return .{ .a = self.a.?.ptr, .i = pos.i };
        }
        pub fn insert_IterT_IterT_IterT(self: *Self, pos: Iter(T), b: Iter(T), e: Iter(T)) E!Iter(T) {
            const p: usize = @intCast(pos.i);
            const m: usize = @intCast(e.i - b.i);
            const tmp = rt.gcSlice(T, m);
            for (0..m) |i| tmp[i] = try Elem.copy(T, b.a.?[@as(usize, @intCast(b.i)) + i]);
            self.openGap(p, m);
            @memcpy(self.a.?[p .. p + m], tmp);
            return .{ .a = self.a.?.ptr, .i = pos.i };
        }
        pub fn insert_IterT_TA(self: *Self, pos: Iter(T), il: ?[]T) E!Iter(T) {
            const p: usize = @intCast(pos.i);
            const src = il.?;
            const m = src.len;
            const tmp = rt.gcSlice(T, m);
            for (0..m) |i| tmp[i] = try Elem.copy(T, src[i]);
            self.openGap(p, m);
            @memcpy(self.a.?[p .. p + m], tmp);
            return .{ .a = self.a.?.ptr, .i = pos.i };
        }
        pub fn insert_IterT_PtrT_PtrT(self: *Self, pos: Iter(T), b: ?[*]T, e: ?[*]T) E!Iter(T) {
            const p: usize = @intCast(pos.i);
            const m: usize = @intCast(rt.pdiff(e, b));
            const tmp = rt.gcSlice(T, m);
            for (0..m) |i| tmp[i] = try Elem.copy(T, b.?[i]);
            self.openGap(p, m);
            @memcpy(self.a.?[p .. p + m], tmp);
            return .{ .a = self.a.?.ptr, .i = pos.i };
        }
        pub fn insert_IterT_ul_T(self: *Self, pos: Iter(T), cnt: u64, x0: T) E!Iter(T) {
            var x = x0;
            _ = &x;
            const p: usize = @intCast(pos.i);
            const m: usize = @intCast(cnt);
            self.openGap(p, m);
            for (0..m) |i| self.a.?[p + i] = try Elem.copy(T, x);
            return .{ .a = self.a.?.ptr, .i = pos.i };
        }
        pub fn erase_IterT(self: *Self, pos: Iter(T)) E!Iter(T) {
            const p: usize = @intCast(pos.i);
            const n: usize = @intCast(self.n);
            std.mem.copyForwards(T, self.a.?[p .. n - 1], self.a.?[p + 1 .. n]);
            self.n -= 1;
            self.a.?[n - 1] = std.mem.zeroes(T);
            return .{ .a = self.a.?.ptr, .i = pos.i };
        }
        pub fn erase_IterT_IterT(self: *Self, b: Iter(T), e: Iter(T)) E!Iter(T) {
            const p: usize = @intCast(b.i);
            const q: usize = @intCast(e.i);
            const n: usize = @intCast(self.n);
            std.mem.copyForwards(T, self.a.?[p .. n - (q - p)], self.a.?[q..n]);
            const m = q - p;
            @memset(self.a.?[n - m .. n], std.mem.zeroes(T));
            self.n = @intCast(n - m);
            return .{ .a = self.a.?.ptr, .i = b.i };
        }
        pub fn Clone(self: *Self) E!?*Self {
            const v = raw();
            v.mk = self.mk;
            const n: usize = @intCast(self.n);
            v.a = rt.gcSlice(T, n);
            v.n = self.n;
            if (comptime Elem.needsCopy(T)) {
                for (0..n) |i| v.a.?[i] = try Elem.copy(T, self.a.?[i]);
            } else @memcpy(v.a.?[0..n], self.a.?[0..n]);
            return v;
        }
        pub fn __clone(x: ?*Self) E!?*Self {
            return x.?.Clone();
        }
        pub fn Assign_VecT(self: *Self, o: ?*Self) E!void {
            if (self == o.?) return;
            const n: usize = @intCast(o.?.n);
            const na = rt.gcSlice(T, n);
            if (comptime Elem.needsCopy(T)) {
                for (0..n) |i| na[i] = try Elem.copy(T, o.?.a.?[i]);
            } else @memcpy(na, o.?.a.?[0..n]);
            self.a = na;
            self.n = o.?.n;
            if (self.mk.f == null) self.mk = o.?.mk;
        }
        pub fn __assign(self: ?*Self, o: ?*Self) E!void {
            return self.?.Assign_VecT(o);
        }
        pub fn Assign_TA(self: *Self, il: ?[]T) E!void {
            return self.assign_TA(il);
        }
        /// move-assign: take o's storage and leave o empty, as libstdc++ does
        pub fn MoveFrom_VecT(self: *Self, o: ?*Self) E!void {
            if (self == o.?) return;
            self.a = o.?.a;
            self.n = o.?.n;
            if (self.mk.f == null) self.mk = o.?.mk;
            o.?.a = @constCast(&empty_storage);
            o.?.n = 0;
        }
        pub fn __moveFrom(self: ?*Self, o: ?*Self) E!void {
            return self.?.MoveFrom_VecT(o);
        }
        pub fn MoveFrom_TA(self: *Self, il: ?[]T) E!void {
            return self.assign_TA(il);
        }
        pub fn Eq(x: ?*Self, y: ?*Self) E!bool {
            if (x.?.n != y.?.n) return false;
            for (x.?.items(), y.?.items()) |p, q| {
                if (!Elem.eq(T, p, q)) return false;
            }
            return true;
        }
    };
}

/// A vector iterator: the storage and an index (contiguous, so it is also a pointer). Two iterators compare by
/// index, as the C# runtime's do.
pub fn Iter(comptime T: type) type {
    return struct {
        a: ?[*]T = null,
        i: i64 = 0,
        const Self = @This();
        pub fn new_TA_l(arr: ?[]T, i: i64) E!Self {
            return .{ .a = if (arr) |x| x.ptr else null, .i = i };
        }
        pub fn new_VecT_l(v: ?*Vec(T), i: i64) E!Self {
            return .{ .a = v.?.a.?.ptr, .i = i };
        }
        pub inline fn p_Deref(self: Self) *T {
            return &self.a.?[@intCast(self.i)];
        }
        pub inline fn p_At(self: Self, k: i64) *T {
            return &self.a.?[@intCast(self.i + k)];
        }
        pub fn op_add(x: Self, k: i64) Self {
            return .{ .a = x.a, .i = x.i + k };
        }
        pub fn op_sub_IterT_l(x: Self, k: i64) Self {
            return .{ .a = x.a, .i = x.i - k };
        }
        pub fn op_sub_IterT_IterT(x: Self, y: Self) i64 {
            return x.i - y.i;
        }
        pub fn op_inc(x: Self) Self {
            return .{ .a = x.a, .i = x.i + 1 };
        }
        pub fn op_dec(x: Self) Self {
            return .{ .a = x.a, .i = x.i - 1 };
        }
        pub fn op_eq(x: Self, y: Self) bool {
            return x.i == y.i;
        }
        pub fn op_ne(x: Self, y: Self) bool {
            return x.i != y.i;
        }
        pub fn op_lt(x: Self, y: Self) bool {
            return x.i < y.i;
        }
        pub fn op_gt(x: Self, y: Self) bool {
            return x.i > y.i;
        }
        pub fn op_le(x: Self, y: Self) bool {
            return x.i <= y.i;
        }
        pub fn op_ge(x: Self, y: Self) bool {
            return x.i >= y.i;
        }
    };
}

/// Ptr<T>(Iter<T>): the element's address
pub fn iterPtr(it: anytype) @TypeOf(it.a) {
    return rt.padd(it.a, it.i);
}

pub fn RevIter(comptime T: type) type {
    return struct {
        v: ?*Vec(T) = null,
        i: i64 = 0, // one past the element it designates, as std::reverse_iterator
        const Self = @This();
        pub inline fn p_Deref(self: Self) *T {
            return &self.v.?.a.?[@intCast(self.i - 1)];
        }
        pub fn op_inc(x: Self) Self {
            return .{ .v = x.v, .i = x.i - 1 };
        }
        pub fn op_eq(x: Self, y: Self) bool {
            return x.i == y.i;
        }
        pub fn op_ne(x: Self, y: Self) bool {
            return x.i != y.i;
        }
    };
}

/// std::span<T>: a view of n elements of an array starting at o.
pub fn CSpan(comptime T: type) type {
    return struct {
        a: ?[]T = null,
        o: i64 = 0,
        n: i64 = 0,
        const Self = @This();
        pub fn empty(self: Self) E!bool {
            return self.n == 0;
        }
        pub fn size(self: Self) E!u64 {
            return @intCast(self.n);
        }
        pub fn p_At(self: Self, i: i64) *T {
            return &self.a.?[@intCast(self.o + i)];
        }
    };
}

// ================================================================ std::pair, std::optional and small classes
pub fn Pair(comptime A: type, comptime B: type) type {
    return struct {
        first: A,
        second: B,
        pub const __rt = true;
        pub const First = A;
        pub const Second = B;
        const Self = @This();
        pub fn new() E!?*Self {
            const p = rt.gcNew(Self);
            p.first = try Elem.make(A);
            p.second = try Elem.make(B);
            return p;
        }
        pub const __new = new;
        pub fn new_A_B(a: A, b: B) E!?*Self {
            const p = rt.gcNew(Self);
            p.first = a;
            p.second = b;
            return p;
        }
        pub fn Clone(self: *Self) E!?*Self {
            return new_A_B(try Elem.copy(A, self.first), try Elem.copy(B, self.second));
        }
        pub fn __clone(x: ?*Self) E!?*Self {
            return x.?.Clone();
        }
        pub fn Assign(self: *Self, o: ?*Self) E!void {
            self.first = try Elem.copy(A, o.?.first);
            self.second = try Elem.copy(B, o.?.second);
        }
        pub fn __assign(self: ?*Self, o: ?*Self) E!void {
            return self.?.Assign(o);
        }
        /// std::pair's operator<: first, then second
        pub fn CompareTo(self: *Self, o: ?*Self) i32 {
            if (Elem.less(A, self.first, o.?.first)) return -1;
            if (Elem.less(A, o.?.first, self.first)) return 1;
            if (Elem.less(B, self.second, o.?.second)) return -1;
            if (Elem.less(B, o.?.second, self.second)) return 1;
            return 0;
        }
        pub fn op_lt(x: ?*Self, y: ?*Self) bool {
            return x.?.CompareTo(y) < 0;
        }
        pub fn op_gt(x: ?*Self, y: ?*Self) bool {
            return x.?.CompareTo(y) > 0;
        }
        pub fn Eq(x: ?*Self, y: ?*Self) E!bool {
            return Elem.eq(A, x.?.first, y.?.first) and Elem.eq(B, x.?.second, y.?.second);
        }
    };
}

pub fn Opt(comptime T: type) type {
    return struct {
        has: bool,
        val: T,
        pub const __rt = true;
        const Self = @This();
        pub fn new() E!?*Self {
            return rt.gcNew(Self);
        }
        pub const __new = new;
        pub fn new_T(v: T) E!?*Self {
            const o = rt.gcNew(Self);
            o.has = true;
            o.val = v;
            return o;
        }
        pub fn DestroyElems(self: *Self) E!void {
            if (self.has) try rt.Dtor.Run(self.val);
        }
        pub fn has_value(self: *Self) E!bool {
            return self.has;
        }
        pub fn value(self: *Self) E!*T {
            if (!self.has) return rt.throwExc(try rt.CppException.make(rt.K_bad_optional_access, null));
            return &self.val;
        }
        pub inline fn p_Deref(self: *Self) *T {
            return &self.val;
        }
        pub fn value_or(self: *Self, d: T) E!T {
            return if (self.has) self.val else d;
        }
        pub fn reset(self: *Self) E!void {
            self.has = false;
            self.val = std.mem.zeroes(T);
        }
        pub fn MoveFrom(self: *Self, o: ?*Self) E!void {
            if (self == o.?) return;
            self.has = o.?.has;
            self.val = o.?.val;
        }
        pub fn __moveFrom(self: ?*Self, o: ?*Self) E!void {
            return self.?.MoveFrom(o);
        }
        pub fn emplace(self: *Self, v: T) E!*T {
            self.has = true;
            self.val = v;
            return &self.val;
        }
        pub fn Clone(self: *Self) E!?*Self {
            return if (self.has) new_T(try Elem.copy(T, self.val)) else new();
        }
        pub fn __clone(x: ?*Self) E!?*Self {
            return x.?.Clone();
        }
        pub fn Assign(self: *Self, o: ?*Self) E!void {
            self.has = o.?.has;
            self.val = if (o.?.has) try Elem.copy(T, o.?.val) else std.mem.zeroes(T);
        }
        pub fn __assign(self: ?*Self, o: ?*Self) E!void {
            return self.?.Assign(o);
        }
        pub fn Set(self: *Self, v: T) E!void {
            self.has = true;
            self.val = v;
        }
    };
}

pub fn Atomic(comptime T: type) type {
    return struct {
        v: T,
        pub const __rt = true;
        const Self = @This();
        pub fn new() E!?*Self {
            return rt.gcNew(Self);
        }
        pub const __new = new;
        pub fn new_T(x: T) E!?*Self {
            const a = rt.gcNew(Self);
            a.v = x;
            return a;
        }
        pub fn exchange(self: *Self, x: T) E!T {
            var o = self.v;
            _ = &o;
            self.v = x;
            return o;
        }
        pub fn load(self: *Self, order: i32) E!T {
            _ = order;
            return self.v;
        }
        pub fn store(self: *Self, x: T, order: i32) E!void {
            _ = order;
            self.v = x;
        }
        pub fn fetch_add(self: *Self, d: T, order: i32) E!T {
            _ = order;
            const o = self.v;
            self.v = if (@typeInfo(T) == .float) self.v + d else self.v +% d;
            return o;
        }
        pub fn fetch_sub(self: *Self, d: T, order: i32) E!T {
            _ = order;
            const o = self.v;
            self.v = if (@typeInfo(T) == .float) self.v - d else self.v -% d;
            return o;
        }
        /// compare_exchange on one thread: never fails spuriously
        pub fn compare_exchange(self: *Self, expected: *T, desired: T) E!bool {
            if (Elem.eq(T, self.v, expected.*)) {
                self.v = desired;
                return true;
            }
            expected.* = self.v;
            return false;
        }
        pub fn Clone(self: *Self) E!?*Self {
            return new_T(self.v);
        }
        pub fn __clone(x: ?*Self) E!?*Self {
            return x.?.Clone();
        }
        pub fn Assign(self: *Self, o: ?*Self) E!void {
            self.v = o.?.v;
        }
        pub fn __assign(self: ?*Self, o: ?*Self) E!void {
            return self.?.Assign(o);
        }
    };
}

/// A reference member of a class: the place it refers to.
pub fn Box(comptime T: type) type {
    return struct {
        p: *T,
        pub const __rt = true;
        const Self = @This();
        pub fn of(p: *T) E!?*Self {
            const b = rt.gcNew(Self);
            b.p = p;
            return b;
        }
        pub inline fn p_V(self: *Self) *T {
            return self.p;
        }
    };
}

/// std::variant<bool, int, double, std::string> (the engine's user-flag value)
pub const Variant = struct {
    b: bool,
    i: i32,
    d: f64,
    s: ?*Str,
    idx: i32,
    pub const __rt = true;
    pub fn new() E!?*Variant {
        return rt.gcNew(Variant);
    }
    pub const __new = new;
    pub fn Set_b(self: *Variant, x: bool) E!void {
        self.* = .{ .b = x, .i = 0, .d = 0, .s = null, .idx = 0 };
    }
    pub fn Set_i(self: *Variant, x: i32) E!void {
        self.* = .{ .b = false, .i = x, .d = 0, .s = null, .idx = 1 };
    }
    pub fn Set_d(self: *Variant, x: f64) E!void {
        self.* = .{ .b = false, .i = 0, .d = x, .s = null, .idx = 2 };
    }
    pub fn Set_Str(self: *Variant, x: ?*Str) E!void {
        self.* = .{ .b = false, .i = 0, .d = 0, .s = try x.?.Clone(), .idx = 3 };
    }
    pub fn index(self: *Variant) E!u64 {
        return @intCast(self.idx);
    }
    pub fn Clone(self: *Variant) E!?*Variant {
        const c = rt.gcNew(Variant);
        try c.Assign(self);
        return c;
    }
    pub fn __clone(x: ?*Variant) E!?*Variant {
        return x.?.Clone();
    }
    pub fn Assign(self: *Variant, o: ?*Variant) E!void {
        const src = o.?.*;
        self.* = src;
        if (src.s) |s| self.s = try s.Clone();
    }
    pub fn __assign(self: ?*Variant, o: ?*Variant) E!void {
        return self.?.Assign(o);
    }
    pub fn MoveFrom(self: *Variant, o: ?*Variant) E!void {
        self.* = o.?.*;
    }
    pub fn __moveFrom(self: ?*Variant, o: ?*Variant) E!void {
        return self.?.MoveFrom(o);
    }
};

/// std::tuple of more than three elements (a map key compared element by element, as std::tuple's operator<)
pub const TupN = struct {
    v: []Item,
    pub const __rt = true;
    pub const Item = union(enum) { int: i64, uint: u64, dbl: f64, bln: bool, ptr: usize, str: ?*Str };
    fn item(x: anytype) Item {
        const T = @TypeOf(x);
        if (T == ?*Str) return .{ .str = x };
        return switch (@typeInfo(T)) {
            .int => |i| if (i.signedness == .signed) .{ .int = x } else .{ .uint = x },
            .comptime_int => .{ .int = x },
            .float => .{ .dbl = x },
            .bool => .{ .bln = x },
            .optional, .pointer => .{ .ptr = @intFromPtr(x) },
            else => @compileError("tuple element " ++ @typeName(T)),
        };
    }
    pub fn new() E!?*TupN {
        const t = rt.gcNew(TupN);
        t.v = &.{};
        return t;
    }
    pub const __new = new;
    pub fn new_oA(items: anytype) E!?*TupN {
        const fields = @typeInfo(@TypeOf(items)).@"struct".fields;
        const t = rt.gcNew(TupN);
        t.v = rt.gcSlice(Item, fields.len);
        inline for (fields, 0..) |f, i| t.v[i] = item(@field(items, f.name));
        return t;
    }
    pub fn Clone(self: *TupN) E!?*TupN {
        const t = rt.gcNew(TupN);
        t.v = rt.gcSlice(Item, self.v.len);
        @memcpy(t.v, self.v);
        return t;
    }
    pub fn __clone(x: ?*TupN) E!?*TupN {
        return x.?.Clone();
    }
    pub fn Assign(self: *TupN, o: ?*TupN) E!void {
        self.v = (try o.?.Clone()).?.v;
    }
    pub fn __assign(self: ?*TupN, o: ?*TupN) E!void {
        return self.?.Assign(o);
    }
    pub fn MoveFrom(self: *TupN, o: ?*TupN) E!void {
        self.v = o.?.v;
    }
    fn cmpItem(a: Item, b: Item) i32 {
        return switch (a) {
            .int => |x| if (x < b.int) -1 else if (x > b.int) @as(i32, 1) else 0,
            .uint => |x| if (x < b.uint) -1 else if (x > b.uint) @as(i32, 1) else 0,
            .dbl => |x| if (x < b.dbl) -1 else if (b.dbl < x) @as(i32, 1) else 0,
            .bln => |x| if (x == b.bln) 0 else if (!x) @as(i32, -1) else 1,
            .ptr => |x| if (x < b.ptr) -1 else if (x > b.ptr) @as(i32, 1) else 0,
            .str => |x| Str.cmp(x.?.bytes(), b.str.?.bytes()),
        };
    }
    pub fn cmp(a: *TupN, b: *TupN) i32 {
        for (a.v, 0..) |x, i| {
            const c = cmpItem(x, b.v[i]);
            if (c != 0) return c;
        }
        return 0;
    }
    pub fn CompareTo(self: *TupN, o: ?*TupN) i32 {
        return cmp(self, o.?);
    }
};

// ================================================================ hashed containers (libstdc++'s _Hashtable)
pub fn HNode(comptime Ev: type) type {
    return struct {
        next: ?*@This(),
        val: Ev,
        code: u64,
    };
}

/// The prime rehash policy (libstdc++ src/c++11/hashtable_c++0x.cc and hashtable-aux.cc).
const RehashPolicy = struct {
    max_load: f64 = 1.0,
    next_resize: u64 = 0,
    const fast_bkt = [_]u8{ 2, 2, 2, 3, 5, 5, 7, 7, 11, 11, 11, 11, 13, 13 };

    fn floorU(x: f64) u64 {
        return rt.f2u64(@import("libm.zig").floor(x));
    }
    fn nextBkt(self: *RehashPolicy, n: u64) u64 {
        if (n < fast_bkt.len) {
            if (n == 0) return 1;
            self.next_resize = floorU(@as(f64, @floatFromInt(fast_bkt[@intCast(n)])) * self.max_load);
            return fast_bkt[@intCast(n)];
        }
        const p = &primes.P;
        const last: usize = p.len - 1; // __prime_list + __n_primes - 1 (the sentinel is excluded)
        var lo: usize = 6;
        var hi: usize = last;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (p[mid] < n) lo = mid + 1 else hi = mid;
        }
        if (lo == last) self.next_resize = std.math.maxInt(u64) else self.next_resize = floorU(@as(f64, @floatFromInt(p[lo])) * self.max_load);
        return p[lo];
    }
    fn bktForElements(self: *RehashPolicy, n: u64) u64 {
        return rt.f2u64(@import("libm.zig").ceil(@as(f64, @floatFromInt(n)) / self.max_load));
    }
    fn needRehash(self: *RehashPolicy, n_bkt: u64, n_elt: u64, n_ins: u64) ?u64 {
        if (n_elt + n_ins > self.next_resize) {
            const min_bkts = @as(f64, @floatFromInt(@max(n_elt + n_ins, if (self.next_resize != 0) @as(u64, 0) else 11))) / self.max_load;
            if (min_bkts >= @as(f64, @floatFromInt(n_bkt)))
                return self.nextBkt(@max(floorU(min_bkts) + 1, n_bkt * 2));
            self.next_resize = floorU(@as(f64, @floatFromInt(n_bkt)) * self.max_load);
            return null;
        }
        return null;
    }
};

/// An iterator over a hashed or sorted container: a node (null at end) or a position in a sorted list.
pub fn MIt(comptime Ev: type) type {
    return struct {
        node: ?*HNode(Ev) = null,
        list: ?*List(Ev) = null,
        pos: i32 = 0,
        const Self = @This();
        pub inline fn p_Deref(self: Self) Ev {
            return if (self.list) |l| l.items[@intCast(self.pos)] else self.node.?.val;
        }
        pub fn op_inc(x: Self) Self {
            if (x.list != null) return .{ .list = x.list, .pos = x.pos + 1 };
            return .{ .node = x.node.?.next };
        }
        pub fn op_dec(x: Self) Self {
            return .{ .list = x.list, .pos = x.pos - 1 };
        }
        fn posOf(x: Self) i32 {
            return if (x.list != null) x.pos else std.math.maxInt(i32);
        }
        pub fn op_eq(a: Self, b: Self) bool {
            if (a.list != null or b.list != null) return posOf(a) == posOf(b);
            return a.node == b.node;
        }
        pub fn op_ne(a: Self, b: Self) bool {
            return !op_eq(a, b);
        }
    };
}

/// An enumeration of a container's elements (C#'s Items()), for a foreach.
pub fn ItemIter(comptime Ev: type) type {
    return struct {
        node: ?*HNode(Ev) = null,
        list: ?*List(Ev) = null,
        pos: usize = 0,
        pub fn next(self: *@This()) ?Ev {
            if (self.list) |l| {
                if (self.pos >= l.items.len) return null;
                self.pos += 1;
                return l.items[self.pos - 1];
            }
            const n = self.node orelse return null;
            self.node = n.next;
            return n.val;
        }
    };
}

/// The hashed container: E is the stored element (a Pair(K, V) pointer for a map, K for a set); H and Q are an
/// engine hasher and key-equal (std::unordered_map<K, V, H, E>), or void.
pub fn HashTable(comptime K: type, comptime Ev: type, comptime is_map: bool, comptime H: type, comptime Q: type) type {
    return struct {
        hashf: rt.Fn1(K, u64),
        eqf: rt.Fn2(K, K, bool),
        mk: rt.Fn0(V),
        buckets: []?*Node,
        before_begin: *Node,
        nelem: u64,
        pol: RehashPolicy,
        pub const __rt = true;
        const Self = @This();
        const Node = HNode(Ev);
        const V = if (is_map) PairOf(Ev).Second else void;

        fn init(h: rt.Fn1(K, u64), q: rt.Fn2(K, K, bool), mk: rt.Fn0(V)) *Self {
            const t = rt.gcNew(Self);
            t.hashf = h;
            t.eqf = q;
            t.mk = mk;
            t.buckets = rt.gcSlice(?*Node, 1);
            t.before_begin = rt.gcNew(Node);
            t.pol = .{};
            return t;
        }
        inline fn key(e: Ev) K {
            return if (is_map) e.?.first else e;
        }
        fn hashOf(self: *Self, k: K) E!u64 {
            if (self.hashf.f != null) return self.hashf.call(k);
            return Elem.hash(K, k);
        }
        fn eqOf(self: *Self, a: K, b: K) E!bool {
            if (self.eqf.f != null) return self.eqf.call(a, b);
            return Elem.eq(K, a, b);
        }
        inline fn bkt(self: *Self, code: u64) usize {
            return @intCast(code % self.buckets.len);
        }
        fn findNode(self: *Self, k: K) E!?*Node {
            const code = try self.hashOf(k);
            const b = self.bkt(code);
            const before = self.buckets[b] orelse return null;
            var p = before.next;
            while (p) |n| : (p = n.next) {
                if (n.code == code and try self.eqOf(k, key(n.val))) return n;
                if (n.next == null or self.bkt(n.next.?.code) != b) break;
            }
            return null;
        }
        const Ins = struct { node: *Node, added: bool };
        fn insertElem(self: *Self, e: Ev) E!Ins {
            const k = key(e);
            if (try self.findNode(k)) |f| return .{ .node = f, .added = false };
            const code = try self.hashOf(k);
            if (self.pol.needRehash(self.buckets.len, self.nelem, 1)) |n| self.rehashTo(n);
            const node = rt.gcNew(Node);
            node.val = e;
            node.code = code;
            self.insertBucketBegin(self.bkt(code), node);
            self.nelem += 1;
            return .{ .node = node, .added = true };
        }
        fn insertBucketBegin(self: *Self, b: usize, node: *Node) void {
            if (self.buckets[b]) |first| {
                node.next = first.next;
                first.next = node;
            } else {
                node.next = self.before_begin.next;
                self.before_begin.next = node;
                if (node.next) |nx| self.buckets[self.bkt(nx.code)] = node;
                self.buckets[b] = self.before_begin;
            }
        }
        fn rehashTo(self: *Self, n: u64) void {
            const nb = rt.gcSlice(?*Node, @intCast(n));
            var p = self.before_begin.next;
            self.before_begin.next = null;
            var bbegin_bkt: usize = 0;
            while (p) |node| {
                const next = node.next;
                const b: usize = @intCast(node.code % n);
                if (nb[b] == null) {
                    node.next = self.before_begin.next;
                    self.before_begin.next = node;
                    nb[b] = self.before_begin;
                    if (node.next != null) nb[bbegin_bkt] = node;
                    bbegin_bkt = b;
                } else {
                    node.next = nb[b].?.next;
                    nb[b].?.next = node;
                }
                p = next;
            }
            self.buckets = nb;
        }
        fn eraseKey(self: *Self, k: K) E!bool {
            const code = try self.hashOf(k);
            const b = self.bkt(code);
            var prev = self.buckets[b] orelse return false;
            var p = prev.next;
            while (p) |n| {
                if (n.code == code and try self.eqOf(k, key(n.val))) break;
                if (n.next == null or self.bkt(n.next.?.code) != b) return false;
                prev = n;
                p = n.next;
            }
            const n = p orelse return false;
            self.eraseNode(b, prev, n);
            return true;
        }
        fn eraseNode(self: *Self, b: usize, prev: *Node, n: *Node) void {
            if (prev == self.buckets[b].?) {
                // removing the bucket's first node (_M_remove_bucket_begin)
                const next = n.next;
                const next_bkt: usize = if (next) |x| self.bkt(x.code) else 0;
                if (next == null or next_bkt != b) {
                    if (next != null) self.buckets[next_bkt] = self.buckets[b];
                    if (self.buckets[b].? == self.before_begin) self.before_begin.next = next;
                    self.buckets[b] = null;
                }
            } else if (n.next) |nx| {
                const next_bkt = self.bkt(nx.code);
                if (next_bkt != b) self.buckets[next_bkt] = prev;
            }
            prev.next = n.next;
            self.nelem -= 1;
        }
        fn eraseAt(self: *Self, n: *Node) void {
            const b = self.bkt(n.code);
            var prev = self.buckets[b].?;
            while (prev.next != n) prev = prev.next.?;
            self.eraseNode(b, prev, n);
        }
        fn copyFrom(self: *Self, o: *Self, deep: bool) E!void {
            // _M_assign: same bucket count, same node order
            self.buckets = rt.gcSlice(?*Node, o.buckets.len);
            self.before_begin.next = null;
            self.nelem = 0;
            self.pol.next_resize = o.pol.next_resize;
            var prev = self.before_begin;
            var p = o.before_begin.next;
            while (p) |src| : (p = src.next) {
                const n = rt.gcNew(Node);
                n.val = if (deep) try Elem.copy(Ev, src.val) else src.val;
                n.code = src.code;
                prev.next = n;
                const b = self.bkt(n.code);
                if (self.buckets[b] == null) self.buckets[b] = prev;
                prev = n;
                self.nelem += 1;
            }
        }

        // ---- the public interface
        pub fn size(self: *Self) E!u64 {
            return self.nelem;
        }
        pub fn empty(self: *Self) E!bool {
            return self.nelem == 0;
        }
        pub fn clear(self: *Self) E!void {
            self.buckets = rt.gcSlice(?*Node, self.buckets.len);
            self.before_begin.next = null;
            self.nelem = 0;
        }
        pub fn bucket_count(self: *Self) E!u64 {
            return self.buckets.len;
        }
        pub fn reserve(self: *Self, n: u64) E!void {
            return self.rehash(self.pol.bktForElements(n));
        }
        pub fn rehash(self: *Self, n: u64) E!void {
            const want = self.pol.nextBkt(@max(n, self.pol.bktForElements(self.nelem + 1)));
            if (want != self.buckets.len) self.rehashTo(want);
        }
        pub fn Items(self: *Self) E!ItemIter(Ev) {
            return .{ .node = self.before_begin.next };
        }
        pub fn begin(self: *Self) E!MIt(Ev) {
            return .{ .node = self.before_begin.next };
        }
        pub fn end(self: *Self) E!MIt(Ev) {
            _ = self;
            return .{};
        }
        pub fn find(self: *Self, k: K) E!MIt(Ev) {
            return .{ .node = try self.findNode(k) };
        }
        pub fn count(self: *Self, k: K) E!u64 {
            return if (try self.findNode(k) != null) 1 else 0;
        }
        pub fn contains(self: *Self, k: K) E!bool {
            return try self.findNode(k) != null;
        }
        pub fn erase_K(self: *Self, k: K) E!u64 {
            return if (try self.eraseKey(k)) 1 else 0;
        }
        pub fn erase_MItE(self: *Self, it: MIt(Ev)) E!MIt(Ev) {
            const nx = it.node.?.next;
            self.eraseAt(it.node.?);
            return .{ .node = nx };
        }

        // ---- maps
        fn makeV(self: *Self) E!V {
            if (self.mk.f != null) return self.mk.call();
            return Elem.make(V);
        }
        pub fn new_FuncKul_FuncKKb_FuncV(h: rt.Fn1(K, u64), q: rt.Fn2(K, K, bool), mk: rt.Fn0(V)) E!?*Self {
            return init(h, q, mk);
        }
        pub fn new_PairKVA_FuncKul_FuncKKb(il: ?[]Ev, h: rt.Fn1(K, u64), q: rt.Fn2(K, K, bool)) E!?*Self {
            const t = init(h, q, .{});
            for (il.?) |p| _ = try t.insertElem(try p.?.Clone());
            return t;
        }
        /// operator[]: the value, inserted default-constructed if absent (the map owns a copy of the key)
        pub fn Index(self: *Self, k: K) E!*V {
            var f = try self.findNode(k);
            if (f == null) f = (try self.insertElem(try PairOf(Ev).new_A_B(try keyCopy(K, k), try self.makeV()))).node;
            return &f.?.val.?.second;
        }
        pub fn at(self: *Self, k: K) E!*V {
            const f = try self.findNode(k) orelse return rt.throwExc(try rt.CppException.makeLit(rt.K_out_of_range, "_Map_base::at"));
            return &f.val.?.second;
        }
        const PairIt = Pair(MIt(Ev), bool);
        fn insertPair(self: *Self, k: K, v: V) E!?*PairIt {
            const r = try self.insertElem(try PairOf(Ev).new_A_B(try keyCopy(K, k), v));
            return PairIt.new_A_B(.{ .node = r.node }, r.added);
        }
        /// insert(pair) of a map, insert(key) of a set
        pub fn insert(self: *Self, x: Ev) E!?*Pair(MIt(Ev), bool) {
            if (is_map) return self.insertPair(x.?.first, x.?.second);
            const r = try self.insertElem(try keyCopy(K, x));
            return Pair(MIt(Ev), bool).new_A_B(.{ .node = r.node }, r.added);
        }
        pub fn emplace(self: *Self, x: Ev) E!?*Pair(MIt(Ev), bool) {
            return self.insert(x);
        }
        pub fn emplace_K_V(self: *Self, k: K, v: V) E!?*PairIt {
            return self.insertPair(k, v);
        }
        pub fn try_emplace_K_V(self: *Self, k: K, v: V) E!?*PairIt {
            return self.insertPair(k, v);
        }
        pub fn insert_or_assign(self: *Self, k: K, v: V) E!?*PairIt {
            if (try self.findNode(k)) |f| {
                f.val.?.second = v;
                return PairIt.new_A_B(.{ .node = f }, false);
            }
            return self.insertPair(k, v);
        }
        pub fn Clone(self: *Self) E!?*Self {
            const m = init(self.hashf, self.eqf, self.mk);
            try m.copyFrom(self, true);
            return m;
        }
        pub fn __clone(x: ?*Self) E!?*Self {
            return x.?.Clone();
        }
        pub fn Assign(self: *Self, o: ?*Self) E!void {
            if (self != o.?) try self.copyFrom(o.?, true);
        }
        pub fn __assign(self: ?*Self, o: ?*Self) E!void {
            return self.?.Assign(o);
        }
        pub fn MoveFrom(self: *Self, o: ?*Self) E!void {
            if (self != o.?) {
                try self.copyFrom(o.?, false);
                try o.?.clear();
            }
        }
        pub fn __moveFrom(self: ?*Self, o: ?*Self) E!void {
            return self.?.MoveFrom(o);
        }

        // ---- sets
        pub fn new_FuncTul_FuncTTb(h: rt.Fn1(K, u64), q: rt.Fn2(K, K, bool)) E!?*Self {
            return init(h, q, .{});
        }

        // ---- std::unordered_map<K, V, H, E> with the engine's hasher and key-equal
        fn hThunk(_: ?*anyopaque, k: K) E!u64 {
            return ClassOf(H).?.__hashOf(hInst, k);
        }
        fn qThunk(_: ?*anyopaque, a: K, b: K) E!bool {
            return ClassOf(Q).?.__call2(qInst, a, b);
        }
        var hInst: H = undefined;
        var qInst: Q = undefined;
        var instDone = false;
        pub fn new_FuncV(mk: rt.Fn0(V)) E!?*Self {
            if (!instDone) {
                hInst = try ClassOf(H).?.__new();
                qInst = try ClassOf(Q).?.__new();
                instDone = true;
            }
            return init(.{ .f = &hThunk }, .{ .f = &qThunk }, mk);
        }
    };
}

fn PairOf(comptime Ev: type) type {
    return @typeInfo(@typeInfo(Ev).optional.child).pointer.child;
}

/// A key stored in a map or set is the container's own copy, as in C++, when the key is a library value (a string,
/// a vector, a pair); an engine class as key is a pointer in C++, so it is stored as it is.
fn keyCopy(comptime K: type, x: K) E!K {
    if (comptime Elem.isClass(K)) {
        if (@hasDecl(ClassOf(K).?, "__rt")) return Elem.copy(K, x);
    }
    return x;
}

pub fn UMap(comptime K: type, comptime V: type) type {
    return HashTable(K, ?*Pair(K, V), true, void, void);
}
pub fn UMapC(comptime K: type, comptime V: type, comptime H: type, comptime Q: type) type {
    return HashTable(K, ?*Pair(K, V), true, H, Q);
}
pub fn USet(comptime T: type) type {
    return HashTable(T, T, false, void, void);
}

// ================================================================ sorted containers
/// A growable list of elements (the C# List<E> under std::map and std::set)
pub fn List(comptime Ev: type) type {
    return struct {
        items: []Ev,
        cap: []Ev,
        const Self = @This();
        fn make() *Self {
            const l = rt.gcNew(Self);
            l.cap = rt.gcSlice(Ev, 4);
            l.items = l.cap[0..0];
            return l;
        }
        fn insertAt(self: *Self, i: usize, x: Ev) void {
            const n = self.items.len;
            if (n + 1 > self.cap.len) {
                const nc = rt.gcSlice(Ev, self.cap.len * 2);
                @memcpy(nc[0..n], self.items);
                self.cap = nc;
            }
            self.items = self.cap[0 .. n + 1];
            std.mem.copyBackwards(Ev, self.items[i + 1 .. n + 1], self.items[i..n]);
            self.items[i] = x;
        }
        fn removeAt(self: *Self, i: usize) void {
            const n = self.items.len;
            std.mem.copyForwards(Ev, self.items[i .. n - 1], self.items[i + 1 .. n]);
            self.items = self.cap[0 .. n - 1];
        }
    };
}

/// std::map: keys kept sorted by the comparator (a red-black tree's order is the sorted order).
pub fn Map(comptime K: type, comptime V: type) type {
    return struct {
        lt: rt.Fn2(K, K, bool),
        mk: rt.Fn0(V),
        l: *List(Ev),
        pub const __rt = true;
        const Self = @This();
        const Ev = ?*Pair(K, V);
        const PairIt = Pair(MIt(Ev), bool);

        fn less(self: *Self, a: K, b: K) E!bool {
            if (self.lt.f != null) return self.lt.call(a, b);
            return Elem.less(K, a, b);
        }
        pub fn new_FuncKKb_FuncV(lt: rt.Fn2(K, K, bool), mk: rt.Fn0(V)) E!?*Self {
            const m = rt.gcNew(Self);
            m.lt = lt;
            m.mk = mk;
            m.l = List(Ev).make();
            return m;
        }
        fn lower(self: *Self, k: K) E!usize {
            var lo: usize = 0;
            var hi: usize = self.l.items.len;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                if (try self.less(self.l.items[mid].?.first, k)) lo = mid + 1 else hi = mid;
            }
            return lo;
        }
        fn findIdx(self: *Self, k: K) E!?usize {
            const i = try self.lower(k);
            if (i < self.l.items.len and !try self.less(k, self.l.items[i].?.first)) return i;
            return null;
        }
        fn it(self: *Self, i: usize) MIt(Ev) {
            return .{ .list = self.l, .pos = @intCast(i) };
        }
        pub fn Index(self: *Self, k: K) E!*V {
            const i = try self.lower(k);
            if (i == self.l.items.len or try self.less(k, self.l.items[i].?.first)) {
                const v = if (self.mk.f != null) try self.mk.call() else try Elem.make(V);
                self.l.insertAt(i, try Pair(K, V).new_A_B(try keyCopy(K, k), v));
            }
            return &self.l.items[i].?.second;
        }
        pub fn at(self: *Self, k: K) E!*V {
            const i = try self.findIdx(k) orelse return rt.throwExc(try rt.CppException.makeLit(rt.K_out_of_range, "map::at"));
            return &self.l.items[i].?.second;
        }
        pub fn insert(self: *Self, p: Ev) E!?*PairIt {
            const i = try self.lower(p.?.first);
            if (i < self.l.items.len and !try self.less(p.?.first, self.l.items[i].?.first)) return PairIt.new_A_B(self.it(i), false);
            self.l.insertAt(i, try Pair(K, V).new_A_B(try keyCopy(K, p.?.first), p.?.second));
            return PairIt.new_A_B(self.it(i), true);
        }
        pub fn emplace_K_V(self: *Self, k: K, v: V) E!?*PairIt {
            return self.insert(try Pair(K, V).new_A_B(k, v));
        }
        pub fn try_emplace(self: *Self, k: K, v: V) E!?*PairIt {
            return self.emplace_K_V(k, v);
        }
        pub fn insert_or_assign(self: *Self, k: K, v: V) E!?*PairIt {
            if (try self.findIdx(k)) |i| {
                self.l.items[i].?.second = v;
                return PairIt.new_A_B(self.it(i), false);
            }
            return self.emplace_K_V(k, v);
        }
        pub fn find(self: *Self, k: K) E!MIt(Ev) {
            return self.it((try self.findIdx(k)) orelse self.l.items.len);
        }
        pub fn lower_bound(self: *Self, k: K) E!MIt(Ev) {
            return self.it(try self.lower(k));
        }
        pub fn count(self: *Self, k: K) E!u64 {
            return if (try self.findIdx(k) != null) 1 else 0;
        }
        pub fn contains(self: *Self, k: K) E!bool {
            return try self.findIdx(k) != null;
        }
        pub fn erase_K(self: *Self, k: K) E!u64 {
            const i = try self.findIdx(k) orelse return 0;
            self.l.removeAt(i);
            return 1;
        }
        pub fn erase_MItPairKV(self: *Self, x: MIt(Ev)) E!MIt(Ev) {
            self.l.removeAt(@intCast(x.pos));
            return self.it(@intCast(x.pos));
        }
        pub fn size(self: *Self) E!u64 {
            return self.l.items.len;
        }
        pub fn empty(self: *Self) E!bool {
            return self.l.items.len == 0;
        }
        pub fn clear(self: *Self) E!void {
            self.l = List(Ev).make();
        }
        pub fn begin(self: *Self) E!MIt(Ev) {
            return self.it(0);
        }
        pub fn end(self: *Self) E!MIt(Ev) {
            return self.it(self.l.items.len);
        }
        pub fn Items(self: *Self) E!ItemIter(Ev) {
            return .{ .list = self.l };
        }
        pub fn Clone(self: *Self) E!?*Self {
            const m = (try new_FuncKKb_FuncV(self.lt, self.mk)).?;
            for (self.l.items) |p| m.l.insertAt(m.l.items.len, try p.?.Clone());
            return m;
        }
        pub fn __clone(x: ?*Self) E!?*Self {
            return x.?.Clone();
        }
        pub fn Assign(self: *Self, o: ?*Self) E!void {
            if (self == o.?) return;
            const nl = List(Ev).make();
            for (o.?.l.items) |p| nl.insertAt(nl.items.len, try p.?.Clone());
            self.l = nl;
        }
        pub fn __assign(self: ?*Self, o: ?*Self) E!void {
            return self.?.Assign(o);
        }
        pub fn MoveFrom(self: *Self, o: ?*Self) E!void {
            if (self == o.?) return;
            self.l = o.?.l;
            o.?.l = List(Ev).make();
        }
        pub fn __moveFrom(self: ?*Self, o: ?*Self) E!void {
            return self.?.MoveFrom(o);
        }
    };
}

pub fn Set(comptime T: type) type {
    return struct {
        lt: rt.Fn2(T, T, bool),
        l: *List(T),
        pub const __rt = true;
        const Self = @This();
        const PairIt = Pair(MIt(T), bool);
        fn less(self: *Self, a: T, b: T) E!bool {
            if (self.lt.f != null) return self.lt.call(a, b);
            return Elem.less(T, a, b);
        }
        pub fn new_FuncTTb(lt: rt.Fn2(T, T, bool)) E!?*Self {
            const s = rt.gcNew(Self);
            s.lt = lt;
            s.l = List(T).make();
            return s;
        }
        fn lower(self: *Self, k: T) E!usize {
            var lo: usize = 0;
            var hi: usize = self.l.items.len;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                if (try self.less(self.l.items[mid], k)) lo = mid + 1 else hi = mid;
            }
            return lo;
        }
        fn it(self: *Self, i: usize) MIt(T) {
            return .{ .list = self.l, .pos = @intCast(i) };
        }
        pub fn insert(self: *Self, x: T) E!?*PairIt {
            const i = try self.lower(x);
            if (i < self.l.items.len and !try self.less(x, self.l.items[i])) return PairIt.new_A_B(self.it(i), false);
            self.l.insertAt(i, try keyCopy(T, x));
            return PairIt.new_A_B(self.it(i), true);
        }
        pub fn emplace(self: *Self, x: T) E!?*PairIt {
            return self.insert(x);
        }
        pub fn find(self: *Self, k: T) E!MIt(T) {
            const i = try self.lower(k);
            return self.it(if (i < self.l.items.len and !try self.less(k, self.l.items[i])) i else self.l.items.len);
        }
        pub fn count(self: *Self, k: T) E!u64 {
            const i = try self.lower(k);
            return if (i < self.l.items.len and !try self.less(k, self.l.items[i])) 1 else 0;
        }
        pub fn contains(self: *Self, k: T) E!bool {
            return (try self.count(k)) > 0;
        }
        pub fn erase_MItT(self: *Self, x: MIt(T)) E!MIt(T) {
            self.l.removeAt(@intCast(x.pos));
            return self.it(@intCast(x.pos));
        }
        pub fn erase_T(self: *Self, k: T) E!u64 {
            const i = try self.lower(k);
            if (i < self.l.items.len and !try self.less(k, self.l.items[i])) {
                self.l.removeAt(i);
                return 1;
            }
            return 0;
        }
        pub fn size(self: *Self) E!u64 {
            return self.l.items.len;
        }
        pub fn empty(self: *Self) E!bool {
            return self.l.items.len == 0;
        }
        pub fn clear(self: *Self) E!void {
            self.l = List(T).make();
        }
        pub fn begin(self: *Self) E!MIt(T) {
            return self.it(0);
        }
        pub fn end(self: *Self) E!MIt(T) {
            return self.it(self.l.items.len);
        }
        pub fn Items(self: *Self) E!ItemIter(T) {
            return .{ .list = self.l };
        }
        pub fn Clone(self: *Self) E!?*Self {
            const m = (try new_FuncTTb(self.lt)).?;
            for (self.l.items) |x| m.l.insertAt(m.l.items.len, try Elem.copy(T, x));
            return m;
        }
        pub fn __clone(x: ?*Self) E!?*Self {
            return x.?.Clone();
        }
        pub fn Assign(self: *Self, o: ?*Self) E!void {
            if (self == o.?) return;
            const nl = List(T).make();
            for (o.?.l.items) |x| nl.insertAt(nl.items.len, try Elem.copy(T, x));
            self.l = nl;
        }
        pub fn __assign(self: ?*Self, o: ?*Self) E!void {
            return self.?.Assign(o);
        }
        pub fn MoveFrom(self: *Self, o: ?*Self) E!void {
            if (self == o.?) return;
            self.l = o.?.l;
            o.?.l = List(T).make();
        }
    };
}

/// std::stack over std::deque
pub fn Stk(comptime T: type) type {
    return struct {
        l: *List(T),
        pub const __rt = true;
        const Self = @This();
        pub fn new() E!?*Self {
            const s = rt.gcNew(Self);
            s.l = List(T).make();
            return s;
        }
        pub const __new = new;
        pub fn push(self: *Self, x: T) E!void {
            self.l.insertAt(self.l.items.len, x);
        }
        pub fn pop(self: *Self) E!void {
            self.l.items = self.l.cap[0 .. self.l.items.len - 1];
        }
        pub fn top(self: *Self) E!*T {
            return &self.l.items[self.l.items.len - 1];
        }
        pub fn empty(self: *Self) E!bool {
            return self.l.items.len == 0;
        }
        pub fn size(self: *Self) E!u64 {
            return self.l.items.len;
        }
        pub fn Clone(self: *Self) E!?*Self {
            const s = (try new()).?;
            for (self.l.items) |x| try s.push(try Elem.copy(T, x));
            return s;
        }
        pub fn __clone(x: ?*Self) E!?*Self {
            return x.?.Clone();
        }
        pub fn Assign(self: *Self, o: ?*Self) E!void {
            if (self == o.?) return;
            self.l = List(T).make();
            for (o.?.l.items) |x| try self.push(try Elem.copy(T, x));
        }
        pub fn __assign(self: ?*Self, o: ?*Self) E!void {
            return self.?.Assign(o);
        }
    };
}

/// std::queue over std::deque: first in, first out
pub fn Que(comptime T: type) type {
    return struct {
        l: *List(T),
        head: usize,
        pub const __rt = true;
        const Self = @This();
        pub fn new() E!?*Self {
            const s = rt.gcNew(Self);
            s.l = List(T).make();
            return s;
        }
        pub const __new = new;
        pub fn push(self: *Self, x: T) E!void {
            self.l.insertAt(self.l.items.len, x);
        }
        pub fn pop(self: *Self) E!void {
            self.l.items[self.head] = std.mem.zeroes(T);
            self.head += 1;
        }
        pub fn front(self: *Self) E!*T {
            return &self.l.items[self.head];
        }
        pub fn back(self: *Self) E!*T {
            return &self.l.items[self.l.items.len - 1];
        }
        pub fn empty(self: *Self) E!bool {
            return self.l.items.len == self.head;
        }
        pub fn size(self: *Self) E!u64 {
            return self.l.items.len - self.head;
        }
        pub fn Clone(self: *Self) E!?*Self {
            const s = (try new()).?;
            for (self.l.items[self.head..]) |x| try s.push(try Elem.copy(T, x));
            return s;
        }
        pub fn __clone(x: ?*Self) E!?*Self {
            return x.?.Clone();
        }
        pub fn Assign(self: *Self, o: ?*Self) E!void {
            if (self == o.?) return;
            self.l = List(T).make();
            self.head = 0;
            for (o.?.l.items[o.?.head..]) |x| try self.push(try Elem.copy(T, x));
        }
        pub fn __assign(self: ?*Self, o: ?*Self) E!void {
            return self.?.Assign(o);
        }
    };
}

// ================================================================ arrays, memory, moves
pub const Arr = struct {
    /// T a[n][m]: n rows of m
    pub fn Make2(comptime T: type, n: i32, m: i32) E!?[]?[]T {
        const a = rt.gcSlice(?[]T, @intCast(n));
        for (a) |*r| r.* = try Make(T, m);
        return a;
    }
    pub fn MakeWith(comptime T: type, n: i32, mk: rt.Fn0(T)) E!?[]T {
        const a = rt.gcSlice(T, @intCast(n));
        for (a) |*x| x.* = try mk.call();
        return a;
    }
    pub fn Make(comptime T: type, n: i32) E!?[]T {
        const a = rt.gcSlice(T, @intCast(n));
        if (comptime ClassOf(T) != null) {
            for (a) |*x| x.* = try Elem.make(T);
        }
        return a;
    }
    pub fn Clone(comptime T: type, a: ?[]T) E!?[]T {
        const s = a orelse return null;
        const b = rt.gcSlice(T, s.len);
        if (comptime Elem.isClass(T)) {
            for (s, 0..) |x, i| b[i] = try Elem.copy(T, x);
        } else @memcpy(b, s);
        return b;
    }
    pub fn Assign(comptime T: type, dst: ?[]T, src: ?[]T) E!void {
        if (comptime Elem.isClass(T)) {
            for (src.?, 0..) |x, i| try Elem.assign(T, dst.?[i], x);
        } else @memcpy(dst.?[0..src.?.len], src.?);
    }
    pub fn Eq(comptime T: type, x: ?[]T, y: ?[]T) E!bool {
        if (x.?.len != y.?.len) return false;
        for (x.?, y.?) |p, q| {
            if (!Elem.eq(T, p, q)) return false;
        }
        return true;
    }
};

pub const Mem = struct {
    /// &obj - p: the index of an object of an array of objects (pointers to objects are references)
    pub fn Diff_T_PtrT(comptime T: type, obj: T, p: ?[*]T) E!i64 {
        var i: usize = 0;
        while (p.?[i] != obj) i += 1;
        return @intCast(i);
    }
    /// calloc(n, size) cast to T*: n*size bytes of zeroed T
    pub fn Calloc(comptime T: type, n: u64, size: u64) E!?[*]T {
        return rt.gcSlice(T, @intCast(n * size / @sizeOf(T))).ptr;
    }
    pub fn Free(p: anytype) E!void {
        _ = p;
    }
    fn bytesOf(p: anytype, n: usize) []u8 {
        if (n == 0) return &.{};
        return @as([*]u8, @ptrCast(p.?))[0..n];
    }
    pub fn memcpy_PtrT_PtrU_ul(comptime T: type, comptime U: type, d: ?[*]T, s: ?[*]U, n: u64) E!?[*]T {
        if (n != 0) @memcpy(bytesOf(d, @intCast(n)), bytesOf(s, @intCast(n)));
        return d;
    }
    pub fn memcpy_PtrT_CPtr_ul(comptime T: type, d: ?[*]T, s: ?[*]u8, n: u64) E!?[*]T {
        if (n != 0) @memcpy(bytesOf(d, @intCast(n)), bytesOf(s, @intCast(n)));
        return d;
    }
    pub fn memcpy_CPtr_PtrU_ul(comptime U: type, d: ?[*]u8, s: ?[*]U, n: u64) E!?[*]u8 {
        if (n != 0) @memcpy(bytesOf(d, @intCast(n)), bytesOf(s, @intCast(n)));
        return d;
    }
    pub fn memcpy_CPtr_CPtr_ul(d: ?[*]u8, s: ?[*]u8, n: u64) E!?[*]u8 {
        if (n != 0) @memcpy(bytesOf(d, @intCast(n)), bytesOf(s, @intCast(n)));
        return d;
    }
    pub fn memset_PtrT_i_ul(comptime T: type, d: ?[*]T, c: i32, n: u64) E!?[*]T {
        @memset(bytesOf(d, @intCast(n)), @truncate(@as(u32, @bitCast(c))));
        return d;
    }
    pub fn memset_CPtr_i_ul(d: ?[*]u8, c: i32, n: u64) E!?[*]u8 {
        @memset(bytesOf(d, @intCast(n)), @truncate(@as(u32, @bitCast(c))));
        return d;
    }
    pub fn fwrite_PtrT_ul_ul_CFile(comptime T: type, p: ?[*]T, size: u64, count: u64, f: ?*crt.CFile) E!u64 {
        try f.?.writeBytes(bytesOf(p, @intCast(size * count)));
        return count;
    }
    pub fn fwrite_CPtr_ul_ul_CFile(p: ?[*]u8, size: u64, count: u64, f: ?*crt.CFile) E!u64 {
        if (size * count != 0) try f.?.writeBytes(bytesOf(p, @intCast(size * count)));
        return count;
    }
    pub fn fread_PtrT_ul_ul_CFile(comptime T: type, p: ?[*]T, size: u64, count: u64, f: ?*crt.CFile) E!u64 {
        const want: usize = @intCast(size * count);
        const got = f.?.readBytes(bytesOf(p, want));
        if (got < want) f.?.readFailed();
        return if (size == 0) 0 else got / size;
    }
    pub fn fread_CPtr_ul_ul_CFile(p: ?[*]u8, size: u64, count: u64, f: ?*crt.CFile) E!u64 {
        const want: usize = @intCast(size * count);
        const got = f.?.readBytes(bytesOf(p, want));
        if (got < want) f.?.readFailed();
        return if (size == 0) 0 else got / size;
    }
};

pub const Bytes = struct {
    /// the bytes of the numbers p points at, as a char* for reading
    pub fn View_PtrT(comptime T: type, p: ?[*]T) E!?[*]u8 {
        return @ptrCast(p);
    }
    pub fn View_CPtr(p: ?[*]u8) E!?[*]u8 {
        return p;
    }
};

pub const Mv = struct {
    /// unique_ptr::reset(p) and unique_ptr assignment: store the new pointer, then delete the old one
    pub fn Reset(comptime T: type, p: *T, q: T) E!void {
        const old = p.*;
        p.* = q;
        if (old != null and old != q) try rt.Dtor.Run(old);
    }
    /// std::move of a container or class into a new owner: the source is left empty
    pub fn Take(comptime T: type, x: *T) E!T {
        const r = x.*;
        x.* = try Elem.make(T);
        return r;
    }
    /// std::move of a unique_ptr or std::function: the source is left null
    pub fn TakeRef(comptime T: type, x: *T) E!T {
        const r = x.*;
        x.* = std.mem.zeroes(T);
        return r;
    }
    pub fn PostStep_PtrTr_i(comptime T: type, p: *?[*]T, d: i32) E!?[*]T {
        const r = p.*;
        p.* = rt.padd(p.*, d);
        return r;
    }
    pub fn PostStep_IterTr_i(comptime T: type, p: *Iter(T), d: i32) E!Iter(T) {
        const r = p.*;
        p.* = .{ .a = r.a, .i = r.i + d };
        return r;
    }
};

// ================================================================ <algorithm> and <numeric>
pub const Algo = struct {
    inline fn at(comptime T: type, it: Iter(T), k: i64) *T {
        return &it.a.?[@intCast(k)];
    }
    pub fn fill_IterT_IterT_T(comptime T: type, b: Iter(T), e: Iter(T), v: T) E!void {
        var i = b.i;
        while (i < e.i) : (i += 1) at(T, b, i).* = try Elem.copy(T, v);
    }
    pub fn fill_PtrT_PtrT_T(comptime T: type, b: ?[*]T, e: ?[*]T, v: T) E!void {
        const n = rt.pdiff(e, b);
        var i: i64 = 0;
        while (i < n) : (i += 1) rt.pat(b, i).* = try Elem.copy(T, v);
    }
    pub fn fill_n_PtrT_ul_T(comptime T: type, b: ?[*]T, n: u64, v: T) E!?[*]T {
        var i: u64 = 0;
        while (i < n) : (i += 1) b.?[@intCast(i)] = try Elem.copy(T, v);
        return rt.padd(b, n);
    }
    pub fn any_of(comptime T: type, b: Iter(T), e: Iter(T), f: rt.Fn1(T, bool)) E!bool {
        var i = b.i;
        while (i < e.i) : (i += 1) {
            if (try f.call(at(T, b, i).*)) return true;
        }
        return false;
    }
    pub fn all_of(comptime T: type, b: Iter(T), e: Iter(T), f: rt.Fn1(T, bool)) E!bool {
        var i = b.i;
        while (i < e.i) : (i += 1) {
            if (!try f.call(at(T, b, i).*)) return false;
        }
        return true;
    }
    pub fn none_of(comptime T: type, b: Iter(T), e: Iter(T), f: rt.Fn1(T, bool)) E!bool {
        return !try any_of(T, b, e, f);
    }
    pub fn find(comptime T: type, b: Iter(T), e: Iter(T), v: T) E!Iter(T) {
        var i = b.i;
        while (i < e.i) : (i += 1) {
            if (Elem.eq(T, at(T, b, i).*, v)) return .{ .a = b.a, .i = i };
        }
        return e;
    }
    pub fn find_if(comptime T: type, b: Iter(T), e: Iter(T), f: rt.Fn1(T, bool)) E!Iter(T) {
        var i = b.i;
        while (i < e.i) : (i += 1) {
            if (try f.call(at(T, b, i).*)) return .{ .a = b.a, .i = i };
        }
        return e;
    }
    pub fn count(comptime T: type, b: Iter(T), e: Iter(T), v: T) E!i64 {
        var n: i64 = 0;
        var i = b.i;
        while (i < e.i) : (i += 1) {
            if (Elem.eq(T, at(T, b, i).*, v)) n += 1;
        }
        return n;
    }
    pub fn accumulate_Iterd_Iterd_d(b: Iter(f64), e: Iter(f64), init0: f64) E!f64 {
        var acc = init0;
        var i = b.i;
        while (i < e.i) : (i += 1) acc = acc + at(f64, b, i).*;
        return acc;
    }
    pub fn lower_bound_IterT_IterT_T(comptime T: type, b: Iter(T), e: Iter(T), v: T) E!Iter(T) {
        var first = b.i;
        var len = e.i - b.i;
        while (len > 0) {
            const half = len >> 1;
            const mid = first + half;
            if (Elem.less(T, at(T, b, mid).*, v)) {
                first = mid + 1;
                len = len - half - 1;
            } else len = half;
        }
        return .{ .a = b.a, .i = first };
    }
    pub fn lower_bound_IterT_IterT_V_FuncTVb(comptime T: type, comptime V: type, b: Iter(T), e: Iter(T), v: V, lt: rt.Fn2(T, V, bool)) E!Iter(T) {
        var first = b.i;
        var len = e.i - b.i;
        while (len > 0) {
            const half = len >> 1;
            const mid = first + half;
            if (try lt.call(at(T, b, mid).*, v)) {
                first = mid + 1;
                len = len - half - 1;
            } else len = half;
        }
        return .{ .a = b.a, .i = first };
    }
    pub fn upper_bound_IterT_IterT_T(comptime T: type, b: Iter(T), e: Iter(T), v: T) E!Iter(T) {
        var first = b.i;
        var len = e.i - b.i;
        while (len > 0) {
            const half = len >> 1;
            const mid = first + half;
            if (Elem.less(T, v, at(T, b, mid).*)) len = half else {
                first = mid + 1;
                len = len - half - 1;
            }
        }
        return .{ .a = b.a, .i = first };
    }
    pub fn is_sorted_IterT_IterT(comptime T: type, b: Iter(T), e: Iter(T)) E!bool {
        var i = b.i + 1;
        while (i < e.i) : (i += 1) {
            if (Elem.less(T, at(T, b, i).*, at(T, b, i - 1).*)) return false;
        }
        return true;
    }
    /// std::unique: keeps the first of each run of equal elements (libstdc++'s order of moves)
    pub fn unique_IterT_IterT(comptime T: type, b: Iter(T), e: Iter(T)) E!Iter(T) {
        if (b.i == e.i) return e;
        var first = b.i;
        const last = e.i;
        var nxt = first;
        while (true) {
            nxt += 1;
            if (nxt == last) break;
            if (Elem.eq(T, at(T, b, first).*, at(T, b, nxt).*)) break;
            first = nxt;
        }
        if (nxt == last) return e;
        var dest = first;
        first = nxt;
        while (true) {
            first += 1;
            if (first == last) break;
            if (!Elem.eq(T, at(T, b, dest).*, at(T, b, first).*)) {
                dest += 1;
                at(T, b, dest).* = at(T, b, first).*;
            }
        }
        return .{ .a = b.a, .i = dest + 1 };
    }
    pub fn max_element_IterT_IterT(comptime T: type, b: Iter(T), e: Iter(T)) E!Iter(T) {
        if (b.i == e.i) return e;
        var best = b.i;
        var i = b.i + 1;
        while (i < e.i) : (i += 1) {
            if (Elem.less(T, at(T, b, best).*, at(T, b, i).*)) best = i;
        }
        return .{ .a = b.a, .i = best };
    }
    pub fn min_element_IterT_IterT(comptime T: type, b: Iter(T), e: Iter(T)) E!Iter(T) {
        if (b.i == e.i) return e;
        var best = b.i;
        var i = b.i + 1;
        while (i < e.i) : (i += 1) {
            if (Elem.less(T, at(T, b, i).*, at(T, b, best).*)) best = i;
        }
        return .{ .a = b.a, .i = best };
    }
    pub fn copy_IterT_IterT_IterT(comptime T: type, b: Iter(T), e: Iter(T), o: Iter(T)) E!Iter(T) {
        var i = b.i;
        while (i < e.i) : (i += 1) at(T, o, o.i + (i - b.i)).* = try Elem.copy(T, at(T, b, i).*);
        return .{ .a = o.a, .i = o.i + (e.i - b.i) };
    }
    pub fn copy_n_PtrT_ul_PtrT(comptime T: type, b: ?[*]T, n: u64, o: ?[*]T) E!?[*]T {
        var i: usize = 0;
        while (i < n) : (i += 1) o.?[i] = try Elem.copy(T, b.?[i]);
        return rt.padd(o, n);
    }
    pub fn transform_Iteruc_Iteruc_Iteruc_Funcucc(b: Iter(u8), e: Iter(u8), o: Iter(u8), f: rt.Fn1(u8, i8)) E!Iter(u8) {
        var i = b.i;
        while (i < e.i) : (i += 1) at(u8, o, o.i + (i - b.i)).* = @bitCast(try f.call(at(u8, b, i).*));
        return .{ .a = o.a, .i = o.i + (e.i - b.i) };
    }
    pub fn transform_IterT_IterT_IterU_FuncTU(comptime T: type, comptime U: type, b: Iter(T), e: Iter(T), o: Iter(U), f: rt.Fn1(T, U)) E!Iter(U) {
        var i = b.i;
        while (i < e.i) : (i += 1) at(U, o, o.i + (i - b.i)).* = try f.call(at(T, b, i).*);
        return .{ .a = o.a, .i = o.i + (e.i - b.i) };
    }
    pub fn replace(comptime T: type, b: Iter(T), e: Iter(T), old: T, nw: T) E!void {
        var i = b.i;
        while (i < e.i) : (i += 1) {
            if (Elem.eq(T, at(T, b, i).*, old)) at(T, b, i).* = nw;
        }
    }
    pub fn iota_Iterul_Iterul_ul(b: Iter(u64), e: Iter(u64), v0: u64) E!void {
        var v = v0;
        var i = b.i;
        while (i < e.i) : (i += 1) {
            at(u64, b, i).* = v;
            v +%= 1;
        }
    }
    pub fn iota_Iteri_Iteri_i(b: Iter(i32), e: Iter(i32), v0: i32) E!void {
        var v = v0;
        var i = b.i;
        while (i < e.i) : (i += 1) {
            at(i32, b, i).* = v;
            v +%= 1;
        }
    }
    pub fn VecFrom(comptime T: type, b: Iter(T), e: Iter(T)) E!?*Vec(T) {
        const v = (try Vec(T).new()).?;
        const n: usize = @intCast(e.i - b.i);
        v.a = rt.gcSlice(T, n);
        v.n = @intCast(n);
        for (0..n) |k| v.a.?[k] = try Elem.copy(T, b.a.?[@as(usize, @intCast(b.i)) + k]);
        return v;
    }
    pub fn begin_TA(comptime T: type, a: ?[]T) E!Iter(T) {
        return .{ .a = a.?.ptr, .i = 0 };
    }
    pub fn end_TA(comptime T: type, a: ?[]T) E!Iter(T) {
        return .{ .a = a.?.ptr, .i = @intCast(a.?.len) };
    }
};

/// libstdc++'s std::sort (introsort with the median-of-three pivot and the final insertion sort, the same
/// comparisons and the same swaps) and std::stable_sort (a merge sort taking the right element only if strictly
/// less), after StdAlgo.cs; tests/stdcheck holds them to libstdc++.
pub const StdAlgo = struct {
    const threshold = 16;
    fn lg(n: i64) i64 {
        return 63 - @as(i64, @clz(@as(u64, @intCast(n))));
    }
    fn Cmp(comptime T: type) type {
        return rt.Fn2(T, T, bool);
    }
    fn swap(comptime T: type, a: [*]T, i: i64, j: i64) void {
        var t = a[@intCast(i)];
        _ = &t;
        a[@intCast(i)] = a[@intCast(j)];
        a[@intCast(j)] = t;
    }
    fn baseOf(arr: anytype) [*]@typeInfo(@typeInfo(@TypeOf(arr)).optional.child).pointer.child {
        const A = @typeInfo(@TypeOf(arr)).optional.child;
        if (@typeInfo(A).pointer.size == .slice) return arr.?.ptr;
        return arr.?;
    }
    pub fn Sort(comptime T: type, arr: anytype, first: i64, last: i64, comp: Cmp(T)) E!void {
        if (first == last) return;
        const a = baseOf(arr);
        try introsortLoop(T, a, first, last, lg(last - first) * 2, comp);
        try finalInsertionSort(T, a, first, last, comp);
    }
    fn introsortLoop(comptime T: type, a: [*]T, first: i64, last0: i64, depth0: i64, comp: Cmp(T)) E!void {
        var last = last0;
        var depth = depth0;
        while (last - first > threshold) {
            if (depth == 0) {
                try partialSort(T, a, first, last, last, comp);
                return;
            }
            depth -= 1;
            const cut = try unguardedPartitionPivot(T, a, first, last, comp);
            try introsortLoop(T, a, cut, last, depth, comp);
            last = cut;
        }
    }
    inline fn ix(i: i64) usize {
        return @intCast(i);
    }
    fn unguardedPartitionPivot(comptime T: type, a: [*]T, first: i64, last: i64, comp: Cmp(T)) E!i64 {
        const mid = first + @divTrunc(last - first, 2);
        try moveMedianToFirst(T, a, first, first + 1, mid, last - 1, comp);
        return unguardedPartition(T, a, first + 1, last, first, comp);
    }
    fn moveMedianToFirst(comptime T: type, x: [*]T, result: i64, a: i64, b: i64, c: i64, comp: Cmp(T)) E!void {
        if (try comp.call(x[ix(a)], x[ix(b)])) {
            if (try comp.call(x[ix(b)], x[ix(c)])) swap(T, x, result, b) else if (try comp.call(x[ix(a)], x[ix(c)])) swap(T, x, result, c) else swap(T, x, result, a);
        } else if (try comp.call(x[ix(a)], x[ix(c)])) swap(T, x, result, a) else if (try comp.call(x[ix(b)], x[ix(c)])) swap(T, x, result, c) else swap(T, x, result, b);
    }
    fn unguardedPartition(comptime T: type, a: [*]T, first0: i64, last0: i64, pivot: i64, comp: Cmp(T)) E!i64 {
        var first = first0;
        var last = last0;
        while (true) {
            while (try comp.call(a[ix(first)], a[ix(pivot)])) first += 1;
            last -= 1;
            while (try comp.call(a[ix(pivot)], a[ix(last)])) last -= 1;
            if (!(first < last)) return first;
            swap(T, a, first, last);
            first += 1;
        }
    }
    fn finalInsertionSort(comptime T: type, a: [*]T, first: i64, last: i64, comp: Cmp(T)) E!void {
        if (last - first > threshold) {
            try insertionSort(T, a, first, first + threshold, comp);
            var i = first + threshold;
            while (i != last) : (i += 1) try unguardedLinearInsert(T, a, i, comp);
        } else try insertionSort(T, a, first, last, comp);
    }
    fn insertionSort(comptime T: type, a: [*]T, first: i64, last: i64, comp: Cmp(T)) E!void {
        if (first == last) return;
        var i = first + 1;
        while (i != last) : (i += 1) {
            if (try comp.call(a[ix(i)], a[ix(first)])) {
                var val = a[ix(i)];
                _ = &val;
                std.mem.copyBackwards(T, a[ix(first + 1)..ix(i + 1)], a[ix(first)..ix(i)]);
                a[ix(first)] = val;
            } else try unguardedLinearInsert(T, a, i, comp);
        }
    }
    fn unguardedLinearInsert(comptime T: type, a: [*]T, last0: i64, comp: Cmp(T)) E!void {
        var last = last0;
        var val = a[ix(last)];
        _ = &val;
        var next = last - 1;
        while (try comp.call(val, a[ix(next)])) {
            a[ix(last)] = a[ix(next)];
            last = next;
            next -= 1;
        }
        a[ix(last)] = val;
    }
    fn partialSort(comptime T: type, a: [*]T, first: i64, middle: i64, last: i64, comp: Cmp(T)) E!void {
        try heapSelect(T, a, first, middle, last, comp);
        try sortHeap(T, a, first, middle, comp);
    }
    fn heapSelect(comptime T: type, a: [*]T, first: i64, middle: i64, last: i64, comp: Cmp(T)) E!void {
        try makeHeap(T, a, first, middle, comp);
        var i = middle;
        while (i < last) : (i += 1) {
            if (try comp.call(a[ix(i)], a[ix(first)])) try popHeap(T, a, first, middle, i, comp);
        }
    }
    fn makeHeap(comptime T: type, a: [*]T, first: i64, last: i64, comp: Cmp(T)) E!void {
        if (last - first < 2) return;
        const len = last - first;
        var parent = @divTrunc(len - 2, 2);
        while (true) {
            var value = a[ix(first + parent)];
            _ = &value;
            try adjustHeap(T, a, first, parent, len, value, comp);
            if (parent == 0) return;
            parent -= 1;
        }
    }
    fn popHeap(comptime T: type, a: [*]T, first: i64, last: i64, result: i64, comp: Cmp(T)) E!void {
        var value = a[ix(result)];
        _ = &value;
        a[ix(result)] = a[ix(first)];
        try adjustHeap(T, a, first, 0, last - first, value, comp);
    }
    fn sortHeap(comptime T: type, a: [*]T, first: i64, last0: i64, comp: Cmp(T)) E!void {
        var last = last0;
        while (last - first > 1) {
            last -= 1;
            try popHeap(T, a, first, last, last, comp);
        }
    }
    fn adjustHeap(comptime T: type, a: [*]T, first: i64, hole0: i64, len: i64, value0: T, comp: Cmp(T)) E!void {
        // a copy before the first store: Zig may pass an aggregate argument by reference, and the callers pass an
        // element of a (lessons/61; the struct case of tests/stdcheck/sortcheck.cpp caught it)
        var value = value0;
        _ = &value;
        var hole = hole0;
        const top = hole;
        var second = hole;
        while (second < @divTrunc(len - 1, 2)) {
            second = 2 * (second + 1);
            if (try comp.call(a[ix(first + second)], a[ix(first + (second - 1))])) second -= 1;
            a[ix(first + hole)] = a[ix(first + second)];
            hole = second;
        }
        if ((len & 1) == 0 and second == @divTrunc(len - 2, 2)) {
            second = 2 * (second + 1);
            a[ix(first + hole)] = a[ix(first + (second - 1))];
            hole = second - 1;
        }
        var parent = @divTrunc(hole - 1, 2);
        while (hole > top and try comp.call(a[ix(first + parent)], value)) {
            a[ix(first + hole)] = a[ix(first + parent)];
            hole = parent;
            parent = @divTrunc(hole - 1, 2);
        }
        a[ix(first + hole)] = value;
    }
    /// std::partial_sort (the engine reaches it only through Sort's heap-sort fallback; public for the checks)
    pub fn PartialSort(comptime T: type, arr: anytype, first: i64, middle: i64, last: i64, comp: Cmp(T)) E!void {
        try partialSort(T, baseOf(arr), first, middle, last, comp);
    }
    pub fn StableSort(comptime T: type, arr: anytype, first: i64, last: i64, comp: Cmp(T)) E!void {
        const n = last - first;
        if (n < 2) return;
        const buf = rt.gcSlice(T, @intCast(n));
        try mergeSort(T, baseOf(arr), first, last, buf, comp);
    }
    fn mergeSort(comptime T: type, a: [*]T, lo: i64, hi: i64, buf: []T, comp: Cmp(T)) E!void {
        if (hi - lo < 2) return;
        const mid = lo + @divTrunc(hi - lo, 2);
        try mergeSort(T, a, lo, mid, buf, comp);
        try mergeSort(T, a, mid, hi, buf, comp);
        var i = lo;
        var j = mid;
        var k: usize = 0;
        while (i < mid and j < hi) {
            if (try comp.call(a[ix(j)], a[ix(i)])) {
                buf[k] = a[ix(j)];
                j += 1;
            } else {
                buf[k] = a[ix(i)];
                i += 1;
            }
            k += 1;
        }
        while (i < mid) : (i += 1) {
            buf[k] = a[ix(i)];
            k += 1;
        }
        while (j < hi) : (j += 1) {
            buf[k] = a[ix(j)];
            k += 1;
        }
        @memcpy(a[ix(lo) .. ix(lo) + k], buf[0..k]);
    }
};
