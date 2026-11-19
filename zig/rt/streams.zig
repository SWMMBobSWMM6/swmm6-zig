//! streams.zig - the C++ streams the engine uses (std::istream, std::ostream, file and string streams), after
//! cs/runtime/Streams.cs: every input stream is one Zig type, IStream, and every output stream one, OStream; the
//! C++ class names are namespaces holding their constructors. Extraction follows libstdc++'s num_get and sentry
//! (lessons/23); formatting of doubles is printf's (%.*g, %.*f, %.*e, %a), as libstdc++'s num_put does it.
//! Written by Claude (Anthropic) for the SWMM6 ports; see AI-USE.md.
const std = @import("std");
const rt = @import("rt.zig");
const E = rt.E;
const Str = @import("str.zig").Str;
const crt = @import("crt.zig");
const FsPath = @import("fs.zig").FsPath;
const gpa = std.heap.smp_allocator;

pub const Ios = struct {
    pub const in_: i32 = 8;
    pub const out: i32 = 16;
    pub const binary: i32 = 4;
    pub const app: i32 = 1;
    pub const trunc: i32 = 32;
    pub const ate: i32 = 2;
    pub const boolalpha: i32 = 1;
    pub const fixed: i32 = 4;
    pub const left: i32 = 32;
    pub const right: i32 = 128;
    pub const scientific: i32 = 256;
    pub const showpoint: i32 = 1024;
};

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c;
}

pub const IStream = struct {
    failbit: bool,
    eofbit: bool,
    badbit: bool,
    prec: i64,
    flagsv: i32,
    buf: []u8, // the whole input (a file is read at open)
    pos: usize,
    gcountv: i64,
    is_file: bool,
    opened: bool,
    dir: bool,
    pub const __rt = true;
    const Self = @This();

    fn make() *Self {
        const s = rt.gcNew(Self);
        s.buf = &.{};
        s.prec = 6;
        return s;
    }
    // ---- ios_base
    pub fn good(self: *Self) E!bool {
        return !self.failbit and !self.eofbit and !self.badbit;
    }
    pub fn fail(self: *Self) E!bool {
        return self.failbit or self.badbit;
    }
    pub fn bad(self: *Self) E!bool {
        return self.badbit;
    }
    pub fn eof(self: *Self) E!bool {
        return self.eofbit;
    }
    pub fn ok(self: *Self) E!bool {
        return !(self.failbit or self.badbit);
    }
    pub fn notok(self: *Self) E!bool {
        return self.failbit or self.badbit;
    }
    pub fn clear(self: *Self, s: i32) E!void {
        _ = s;
        self.failbit = false;
        self.eofbit = false;
        self.badbit = false;
    }
    pub fn imbue(self: *Self, l: anytype) E!void {
        _ = self;
        _ = l;
    }
    pub fn exceptions(self: *Self, m: i32) E!void {
        _ = self;
        _ = m;
    }

    // ---- reading
    fn fill(self: *Self) bool {
        if (self.pos < self.buf.len) return true;
        if (self.dir) {
            self.badbit = true;
            self.failbit = true;
        }
        return false;
    }
    fn atEnd(self: *Self) void {
        if (!self.dir) self.eofbit = true;
    }
    pub fn peek(self: *Self) E!i32 {
        if (!self.fill()) {
            self.atEnd();
            return -1;
        }
        return self.buf[self.pos];
    }
    pub fn get(self: *Self) E!i32 {
        if (!self.fill()) {
            self.atEnd();
            self.failbit = true;
            return -1;
        }
        self.gcountv = 1;
        self.pos += 1;
        return self.buf[self.pos - 1];
    }
    pub fn gcount(self: *Self) E!i64 {
        return self.gcountv;
    }
    pub fn read_CPtr_l(self: *Self, p: ?[*]u8, n: i64) E!?*Self {
        const avail = self.buf.len - @min(self.pos, self.buf.len);
        const k: usize = @min(@as(usize, @intCast(n)), avail);
        if (k > 0) @memcpy(p.?[0..k], self.buf[self.pos .. self.pos + k]);
        self.pos += k;
        self.gcountv = @intCast(k);
        if (k < @as(usize, @intCast(n))) {
            if (self.dir) {
                self.badbit = true;
            }
            self.atEnd();
            self.failbit = true;
        }
        return self;
    }
    pub fn read_PtrT_l(self: *Self, comptime T: type, p: ?[*]T, n: i64) E!?*Self {
        return self.read_CPtr_l(@ptrCast(p), n);
    }
    pub fn readLine(self: *Self, s: ?*Str, delim: u8) E!bool {
        try s.?.clear();
        var any = false;
        while (true) {
            if (!self.fill()) {
                self.atEnd();
                if (!any) self.failbit = true;
                return any;
            }
            const c = self.buf[self.pos];
            self.pos += 1;
            any = true;
            if (c == delim) return true;
            try s.?.push_back(c);
        }
    }
    fn skipWs(self: *Self) void {
        while (self.fill() and isWs(self.buf[self.pos])) self.pos += 1;
    }
    fn token(self: *Self) E!?*Str {
        self.skipWs();
        const t = try Str.new();
        while (self.fill() and !isWs(self.buf[self.pos])) {
            try t.?.push_back(self.buf[self.pos]);
            self.pos += 1;
        }
        if (t.?.n == 0) {
            self.failbit = true;
            if (!self.fill()) self.atEnd();
        } else if (!self.fill()) self.atEnd();
        return t;
    }
    pub fn Get_Str(self: *Self, s: ?*Str) E!?*Self {
        const t = try self.token();
        if (t.?.n > 0) try s.?.Assign_Str(t);
        return self;
    }
    /// is >> std::ws: skip white space (eof if the input ends there, not fail)
    pub fn Manip_ws(self: *Self) E!?*Self {
        while (true) {
            if (!self.fill()) {
                self.atEnd();
                break;
            }
            const c = self.buf[self.pos];
            if (c == ' ' or (c >= 9 and c <= 13)) self.pos += 1 else break;
        }
        return self;
    }
    /// is >> v for a double, as libstdc++ does it (Streams.cs Get(ref double))
    pub fn Get_dr(self: *Self, v: *f64) E!?*Self {
        if (!try self.good()) {
            self.failbit = true;
            return self;
        }
        self.skipWs();
        if (!self.fill()) {
            self.atEnd();
            self.failbit = true;
            return self;
        }
        var acc: std.ArrayListUnmanaged(u8) = .{};
        defer acc.deinit(gpa);
        var more = true;
        var c: i32 = self.buf[self.pos];
        const S = struct {
            fn next(st: *Self, m: *bool, ch: *i32) void {
                st.pos += 1;
                m.* = st.fill();
                ch.* = if (m.*) st.buf[st.pos] else -1;
            }
        };
        if (c == '+' or c == '-') {
            acc.append(gpa, @intCast(c)) catch unreachable;
            S.next(self, &more, &c);
        }
        var mantissa = false;
        var dec = false;
        var sci = false;
        while (more and c == '0') {
            if (!mantissa) {
                acc.append(gpa, '0') catch unreachable;
                mantissa = true;
            }
            S.next(self, &more, &c);
        }
        while (more) {
            if (c >= '0' and c <= '9') {
                acc.append(gpa, @intCast(c)) catch unreachable;
                mantissa = true;
            } else if (c == '.' and !dec and !sci) {
                acc.append(gpa, '.') catch unreachable;
                dec = true;
            } else if ((c == 'e' or c == 'E') and !sci and mantissa) {
                acc.append(gpa, 'e') catch unreachable;
                sci = true;
                S.next(self, &more, &c);
                if (!more) break;
                if (c == '+' or c == '-') acc.append(gpa, @intCast(c)) catch unreachable else continue;
            } else break;
            S.next(self, &more, &c);
        }
        if (!more) self.atEnd();
        acc.append(gpa, 0) catch unreachable;
        const r = crt.scanNumber(acc.items.ptr);
        if (r.n == 0 or acc.items[r.n] != 0) {
            v.* = 0;
            self.failbit = true;
        } else if (std.math.isPositiveInf(r.v)) {
            v.* = std.math.floatMax(f64);
            self.failbit = true;
        } else if (std.math.isNegativeInf(r.v)) {
            v.* = -std.math.floatMax(f64);
            self.failbit = true;
        } else v.* = r.v;
        return self;
    }
    pub fn Get_fr(self: *Self, v: *f32) E!?*Self {
        var d: f64 = 0;
        _ = try self.Get_dr(&d);
        v.* = @floatCast(d);
        return self;
    }
    pub fn Get_ir(self: *Self, v: *i32) E!?*Self {
        const t = try self.token();
        if (t.?.n == 0) {
            v.* = 0;
            return self;
        }
        const p = t.?.cstr();
        var end: ?[*]u8 = p;
        const r = crt.strtolText(p, &end);
        if (rt.pdiff(end, p) != t.?.n or r < std.math.minInt(i32) or r > std.math.maxInt(i32)) {
            self.failbit = true;
            v.* = if (r < std.math.minInt(i32)) std.math.minInt(i32) else if (r > std.math.maxInt(i32)) std.math.maxInt(i32) else 0;
            return self;
        }
        v.* = @intCast(r);
        return self;
    }
    pub fn Get_lr(self: *Self, v: *i64) E!?*Self {
        const t = try self.token();
        if (t.?.n == 0) {
            v.* = 0;
            return self;
        }
        const p = t.?.cstr();
        var end: ?[*]u8 = p;
        const r = crt.strtolText(p, &end);
        if (rt.pdiff(end, p) != t.?.n) {
            self.failbit = true;
            v.* = 0;
            return self;
        }
        v.* = r;
        return self;
    }
    pub fn Get_ulr(self: *Self, v: *u64) E!?*Self {
        var x: i64 = 0;
        _ = try self.Get_lr(&x);
        v.* = @bitCast(x);
        return self;
    }
    pub fn Get_ur(self: *Self, v: *u32) E!?*Self {
        var x: i64 = 0;
        _ = try self.Get_lr(&x);
        v.* = @truncate(@as(u64, @bitCast(x)));
        return self;
    }
    pub fn tellg(self: *Self) E!i64 {
        return @intCast(self.pos);
    }
    pub fn seekg(self: *Self, off: i64, dir: i32) E!?*Self {
        self.eofbit = false;
        const base: i64 = if (dir == 0) 0 else if (dir == 1) @intCast(self.pos) else @intCast(self.buf.len);
        const np = base + off;
        if (np < 0) {
            self.failbit = true;
            return self;
        }
        self.pos = @intCast(np);
        return self;
    }
    // ---- string and file streams
    pub fn str_(self: *Self) E!?*Str {
        return Str.newSlice(self.buf);
    }
    pub fn str_Str(self: *Self, s: ?*Str) E!void {
        self.buf = (try s.?.Clone()).?.bytes();
        self.pos = 0;
        self.failbit = false;
        self.eofbit = false;
    }
    fn openPath(self: *Self, path: []const u8) void {
        var dir = false;
        const d = crt.readWholeFile(path, &dir);
        self.pos = 0;
        if (d) |data| {
            self.buf = data;
            self.dir = dir;
            self.opened = true;
            self.failbit = false;
        } else {
            self.buf = &.{};
            self.opened = false;
            self.failbit = true;
        }
    }
    pub fn open_Str_i(self: *Self, path: ?*Str, mode: i32) E!void {
        _ = mode;
        self.openPath(path.?.bytes());
    }
    pub fn is_open(self: *Self) E!bool {
        return self.opened;
    }
    pub fn close(self: *Self) E!void {
        self.opened = false;
        self.dir = false;
    }
    pub fn Dispose(self: *Self) E!void {
        if (self.is_file) try self.close();
    }
    pub fn MoveFrom(self: *Self, o: ?*Self) E!void {
        self.* = o.?.*;
        o.?.opened = false;
        o.?.dir = false;
    }
};

pub const IStringStream = struct {
    pub fn new() E!?*IStream {
        return IStream.make();
    }
    pub fn new_Str(s: ?*Str) E!?*IStream {
        const x = IStream.make();
        try x.str_Str(s);
        return x;
    }
    pub fn new_Str_i(s: ?*Str, mode: i32) E!?*IStream {
        _ = mode;
        return new_Str(s);
    }
};

pub const IFStream = struct {
    pub fn new() E!?*IStream {
        const x = IStream.make();
        x.is_file = true;
        return x;
    }
    pub fn new_Str_i(path: ?*Str, mode: i32) E!?*IStream {
        const x = (try new()).?;
        try x.open_Str_i(path, mode);
        return x;
    }
    pub fn new_CPtr_i(path: ?[*]u8, mode: i32) E!?*IStream {
        return new_Str_i(try Str.new_CPtr(path), mode);
    }
    pub fn new_FsPath_i(path: ?*FsPath, mode: i32) E!?*IStream {
        return new_Str_i(path.?.p, mode);
    }
};

/// a growable byte buffer in collected memory (a string stream's contents)
const ByteBuf = struct {
    buf: []u8 = &.{},
    len: usize = 0,
    fn append(self: *ByteBuf, b: []const u8) void {
        if (self.len + b.len > self.buf.len) {
            const nb = rt.gcSlice(u8, @max(self.len + b.len, self.buf.len * 2, 64));
            @memcpy(nb[0..self.len], self.buf[0..self.len]);
            self.buf = nb;
        }
        @memcpy(self.buf[self.len .. self.len + b.len], b);
        self.len += b.len;
    }
    fn items(self: *ByteBuf) []u8 {
        return self.buf[0..self.len];
    }
};

pub const OStream = struct {
    failbit: bool,
    eofbit: bool,
    badbit: bool,
    prec: i64,
    flagsv: i32,
    widthv: i64,
    fillc: i32,
    file: ?*crt.CFile, // a file stream, or
    mem: ByteBuf, // a string stream's bytes
    is_mem: bool,
    pub const __rt = true;
    const Self = @This();

    fn make() *Self {
        const s = rt.gcNew(Self);
        s.prec = 6;
        s.fillc = ' ';
        return s;
    }
    pub fn good(self: *Self) E!bool {
        return !self.failbit and !self.eofbit and !self.badbit;
    }
    pub fn fail(self: *Self) E!bool {
        return self.failbit or self.badbit;
    }
    pub fn bad(self: *Self) E!bool {
        return self.badbit;
    }
    pub fn eof(self: *Self) E!bool {
        return self.eofbit;
    }
    pub fn ok(self: *Self) E!bool {
        return !(self.failbit or self.badbit);
    }
    pub fn notok(self: *Self) E!bool {
        return self.failbit or self.badbit;
    }
    pub fn clear(self: *Self, s: i32) E!void {
        _ = s;
        self.failbit = false;
        self.eofbit = false;
        self.badbit = false;
    }
    pub fn imbue(self: *Self, l: anytype) E!void {
        _ = self;
        _ = l;
    }

    fn raw(self: *Self, b: []const u8) E!void {
        if (self.file) |f| return f.writeBytes(b);
        if (self.is_mem) self.mem.append(b);
    }
    fn pad(self: *Self, body: []const u8) E!void {
        const w = self.widthv;
        self.widthv = 0;
        if (@as(i64, @intCast(body.len)) >= w) return self.raw(body);
        const n: usize = @intCast(w - @as(i64, @intCast(body.len)));
        const p = gpa.alloc(u8, n) catch unreachable;
        defer gpa.free(p);
        @memset(p, @truncate(@as(u32, @bitCast(self.fillc))));
        if ((self.flagsv & Ios.left) != 0) {
            try self.raw(body);
            try self.raw(p);
        } else {
            try self.raw(p);
            try self.raw(body);
        }
    }
    pub fn Put_Str(self: *Self, x: ?*Str) E!?*Self {
        try self.pad(x.?.bytes());
        return self;
    }
    pub fn Put_CPtr(self: *Self, x: ?[*]u8) E!?*Self {
        try self.pad(x.?[0..crt.slen(x)]);
        return self;
    }
    pub fn Put_c(self: *Self, c: i8) E!?*Self {
        const b = [1]u8{@bitCast(c)};
        try self.pad(&b);
        return self;
    }
    pub fn Put_uc(self: *Self, c: u8) E!?*Self {
        const b = [1]u8{c};
        try self.pad(&b);
        return self;
    }
    fn putInt(self: *Self, v: anytype) E!?*Self {
        var b: [40]u8 = undefined;
        try self.pad(std.fmt.bufPrint(&b, "{d}", .{v}) catch unreachable);
        return self;
    }
    pub fn Put_i(self: *Self, v: i32) E!?*Self {
        return self.putInt(v);
    }
    pub fn Put_l(self: *Self, v: i64) E!?*Self {
        return self.putInt(v);
    }
    pub fn Put_u(self: *Self, v: u32) E!?*Self {
        return self.putInt(v);
    }
    pub fn Put_ul(self: *Self, v: u64) E!?*Self {
        return self.putInt(v);
    }
    pub fn Put_s(self: *Self, v: i16) E!?*Self {
        return self.putInt(v);
    }
    pub fn Put_b(self: *Self, v: bool) E!?*Self {
        try self.pad(if ((self.flagsv & Ios.boolalpha) != 0) (if (v) "true" else "false") else (if (v) "1" else "0"));
        return self;
    }
    pub fn Put_f(self: *Self, v: f32) E!?*Self {
        return self.Put_d(v);
    }
    /// libstdc++ __num_base::_S_format_float: the conversion letter from the floatfield, '#' for showpoint
    pub fn Put_d(self: *Self, v: f64) E!?*Self {
        const fx = (self.flagsv & Ios.fixed) != 0;
        const sci = (self.flagsv & Ios.scientific) != 0;
        const sp = (self.flagsv & Ios.showpoint) != 0;
        var out: std.ArrayListUnmanaged(u8) = .{};
        defer out.deinit(gpa);
        const p: i32 = @truncate(self.prec);
        if (fx and sci) {
            crt.formatList(&out, if (sp) "%#a" else "%a", .{v});
        } else {
            const conv: []const u8 = if (fx) "f" else if (sci) "e" else "g";
            var fb: [8]u8 = undefined;
            const f = std.fmt.bufPrint(&fb, "{s}.*{s}", .{ if (sp) "%#" else "%", conv }) catch unreachable;
            crt.formatList(&out, f, .{ p, v });
        }
        try self.pad(out.items);
        return self;
    }
    pub fn Manip_endl(self: *Self) E!?*Self {
        try self.raw("\n");
        _ = try self.flush();
        return self;
    }
    pub fn Manip_flush(self: *Self) E!?*Self {
        _ = try self.flush();
        return self;
    }
    pub fn Manip_setprecision(self: *Self, n: i64) E!?*Self {
        self.prec = n;
        return self;
    }
    pub fn Manip_setw(self: *Self, n: i64) E!?*Self {
        self.widthv = n;
        return self;
    }
    pub fn Manip_setfill(self: *Self, c: i32) E!?*Self {
        self.fillc = c;
        return self;
    }
    /// std::quoted(s): s between double quotes, every '"' and '\\' escaped; the width applies to the whole
    pub fn Manip_quoted_Str(self: *Self, x: ?*Str) E!?*Self {
        var b: std.ArrayListUnmanaged(u8) = .{};
        defer b.deinit(gpa);
        b.append(gpa, '"') catch unreachable;
        for (x.?.bytes()) |c| {
            if (c == '"' or c == '\\') b.append(gpa, '\\') catch unreachable;
            b.append(gpa, c) catch unreachable;
        }
        b.append(gpa, '"') catch unreachable;
        try self.pad(b.items);
        return self;
    }
    pub fn Manip_quoted_CPtr(self: *Self, x: ?[*]u8) E!?*Self {
        return self.Manip_quoted_Str(try Str.new_CPtr(x));
    }
    pub fn Manip_fixed(self: *Self) E!?*Self {
        self.flagsv = (self.flagsv & ~(Ios.fixed | Ios.scientific)) | Ios.fixed;
        return self;
    }
    pub fn Manip_scientific(self: *Self) E!?*Self {
        self.flagsv = (self.flagsv & ~(Ios.fixed | Ios.scientific)) | Ios.scientific;
        return self;
    }
    pub fn Manip_defaultfloat(self: *Self) E!?*Self {
        self.flagsv &= ~(Ios.fixed | Ios.scientific);
        return self;
    }
    pub fn Manip_left(self: *Self) E!?*Self {
        self.flagsv = (self.flagsv & ~(Ios.left | Ios.right)) | Ios.left;
        return self;
    }
    pub fn Manip_right(self: *Self) E!?*Self {
        self.flagsv = (self.flagsv & ~(Ios.left | Ios.right)) | Ios.right;
        return self;
    }
    pub fn Manip_boolalpha(self: *Self) E!?*Self {
        self.flagsv |= Ios.boolalpha;
        return self;
    }
    pub fn write_CPtr_l(self: *Self, p: ?[*]u8, n: i64) E!?*Self {
        if (n != 0) try self.raw(p.?[0..@intCast(n)]);
        return self;
    }
    pub fn write_PtrT_l(self: *Self, comptime T: type, p: ?[*]T, n: i64) E!?*Self {
        if (n == 0) return self;
        return self.write_CPtr_l(@ptrCast(p), n);
    }
    pub fn flush(self: *Self) E!?*Self {
        if (self.file) |f| _ = try crt.R.fflush(f);
        return self;
    }
    pub fn tellp(self: *Self) E!i64 {
        if (self.file) |f| return f.pos;
        return @intCast(self.mem.len);
    }
    pub fn precision(self: *Self) E!i64 {
        return self.prec;
    }
    // ---- string and file streams
    pub fn str_(self: *Self) E!?*Str {
        return Str.newSlice(self.mem.items());
    }
    pub fn str_Str(self: *Self, x: ?*Str) E!void {
        self.mem = .{};
        self.mem.append(x.?.bytes());
    }
    pub fn open_Str_i(self: *Self, path: ?*Str, mode: i32) E!void {
        const p = path.?.cstr();
        const f = try crt.R.fopen(p, if ((mode & Ios.app) != 0) rt.lit("ab") else rt.lit("wb"));
        self.file = f;
        self.failbit = f == null;
    }
    pub fn open_FsPath_i(self: *Self, path: ?*FsPath, mode: i32) E!void {
        return self.open_Str_i(path.?.p, mode);
    }
    pub fn is_open(self: *Self) E!bool {
        return self.file != null;
    }
    pub fn close(self: *Self) E!void {
        if (self.file) |f| _ = try crt.R.fclose(f);
        self.file = null;
    }
    pub fn Dispose(self: *Self) E!void {
        if (!self.is_mem) try self.close();
    }
    pub fn MoveFrom(self: *Self, o: ?*Self) E!void {
        self.* = o.?.*;
        o.?.file = null;
        o.?.mem = .{};
    }
};

pub const OStringStream = struct {
    pub fn new() E!?*OStream {
        const s = OStream.make();
        s.is_mem = true;
        return s;
    }
    pub fn new_i(mode: i32) E!?*OStream {
        _ = mode;
        return new();
    }
    pub fn new_Str(init: ?*Str) E!?*OStream {
        const s = (try new()).?;
        try s.str_Str(init);
        return s;
    }
};

pub const OFStream = struct {
    pub fn new() E!?*OStream {
        return OStream.make();
    }
    pub fn new_Str_i(path: ?*Str, mode: i32) E!?*OStream {
        const s = OStream.make();
        try s.open_Str_i(path, mode);
        return s;
    }
    pub fn new_CPtr_i(path: ?[*]u8, mode: i32) E!?*OStream {
        return new_Str_i(try Str.new_CPtr(path), mode);
    }
    pub fn new_FsPath_i(path: ?*FsPath, mode: i32) E!?*OStream {
        return new_Str_i(path.?.p, mode);
    }
};

pub const Streams = struct {
    pub fn getline_IStream_Str(s: ?*IStream, line: ?*Str) E!?*IStream {
        _ = try s.?.readLine(line, '\n');
        return s;
    }
    pub fn getline_IStream_Str_c(s: ?*IStream, line: ?*Str, delim: i8) E!?*IStream {
        _ = try s.?.readLine(line, @bitCast(delim));
        return s;
    }
    pub fn getline_IStream_Str_i(s: ?*IStream, line: ?*Str, delim: i32) E!?*IStream {
        _ = try s.?.readLine(line, @truncate(@as(u32, @bitCast(delim))));
        return s;
    }
};
