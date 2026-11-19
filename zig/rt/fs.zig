//! fs.zig - std::filesystem::path and the filesystem functions the engine calls (POSIX paths, as libstdc++ on
//! Linux), after cs/runtime/Fs.cs.
//! Written by Claude (Anthropic) for the SWMM6 ports; see AI-USE.md.
const std = @import("std");
const rt = @import("rt.zig");
const E = rt.E;
const Str = @import("str.zig").Str;
const gpa = std.heap.smp_allocator;

pub const ErrorCode = struct {
    v: i32,
    pub const __rt = true;
    pub fn new() E!?*ErrorCode {
        return rt.gcNew(ErrorCode);
    }
    pub fn Bool(self: *ErrorCode) E!bool {
        return self.v != 0;
    }
    pub fn value(self: *ErrorCode) E!i32 {
        return self.v;
    }
    pub fn clear(self: *ErrorCode) E!void {
        self.v = 0;
    }
};

pub const FileStatus = struct {
    kind: i32,
    pub const __rt = true;
    pub const NotFound: i32 = -1;
    pub const Regular: i32 = 1;
    pub const Directory: i32 = 2;
    fn of(path: []const u8) ?*FileStatus {
        const s = rt.gcNew(FileStatus);
        s.kind = kindOf(path);
        return s;
    }
    pub fn type_(self: *FileStatus) E!i32 {
        return self.kind;
    }
    pub fn Clone(self: *FileStatus) E!?*FileStatus {
        const s = rt.gcNew(FileStatus);
        s.kind = self.kind;
        return s;
    }
};

fn kindOf(path: []const u8) i32 {
    const st = std.fs.cwd().statFile(path) catch return FileStatus.NotFound;
    return switch (st.kind) {
        .directory => FileStatus.Directory,
        .file => FileStatus.Regular,
        else => 3,
    };
}

fn str(s: []const u8) E!?*Str {
    return Str.newSlice(s);
}

pub const FsPath = struct {
    p: ?*Str,
    pub const __rt = true;
    const Self = @This();
    fn of(s: []const u8) E!?*Self {
        const x = rt.gcNew(Self);
        x.p = try str(s);
        return x;
    }
    fn S(self: *Self) []u8 {
        return self.p.?.bytes();
    }
    pub fn new() E!?*Self {
        return of("");
    }
    pub const __new = new;
    pub fn new_Str(s: ?*Str) E!?*Self {
        return of(s.?.bytes());
    }
    pub fn new_CPtr(s: ?[*]u8) E!?*Self {
        return of(s.?[0..@import("crt.zig").slen(s)]);
    }
    pub fn Clone(self: *Self) E!?*Self {
        return of(self.S());
    }
    pub fn __clone(x: ?*Self) E!?*Self {
        return x.?.Clone();
    }
    pub fn clear(self: *Self) E!void {
        self.p = try str("");
    }
    pub fn Assign_FsPath(self: *Self, o: ?*Self) E!void {
        self.p = try o.?.p.?.Clone();
    }
    pub fn __assign(self: ?*Self, o: ?*Self) E!void {
        return self.?.Assign_FsPath(o);
    }
    pub fn Assign_Str(self: *Self, s: ?*Str) E!void {
        self.p = try s.?.Clone();
    }
    pub fn MoveFrom(self: *Self, o: ?*Self) E!void {
        self.p = o.?.p;
        o.?.p = try str("");
    }
    pub fn compare(self: *Self, o: ?*Self) E!i32 {
        return Str.cmp(self.S(), o.?.S());
    }
    pub fn CompareTo(self: *Self, o: ?*Self) i32 {
        return Str.cmp(self.S(), o.?.S());
    }
    pub fn string(self: *Self) E!?*Str {
        return self.p.?.Clone();
    }
    pub fn generic_string(self: *Self) E!?*Str {
        return self.p.?.Clone();
    }
    pub fn native(self: *Self) E!?*Str {
        return self.p.?.Clone();
    }
    pub fn c_str(self: *Self) E!?[*]u8 {
        return self.p.?.cstr();
    }
    pub fn empty(self: *Self) E!bool {
        return self.p.?.n == 0;
    }
    pub fn is_absolute(self: *Self) E!bool {
        return self.p.?.n > 0 and self.S()[0] == '/';
    }
    pub fn is_relative(self: *Self) E!bool {
        return !try self.is_absolute();
    }
    fn lastSlash(s: []const u8) ?usize {
        return std.mem.lastIndexOfScalar(u8, s, '/');
    }
    /// the last element (libstdc++: the part after the last '/'; "" when the path ends in '/')
    pub fn filename(self: *Self) E!?*Self {
        const s = self.S();
        const i = lastSlash(s);
        return of(if (i) |k| s[k + 1 ..] else s);
    }
    pub fn parent_path(self: *Self) E!?*Self {
        const s = self.S();
        const i = lastSlash(s) orelse return of("");
        if (i == 0) return of("/");
        var j = i;
        while (j > 0 and s[j - 1] == '/') j -= 1;
        return of(s[0..if (j == 0) 1 else j]);
    }
    pub fn stem(self: *Self) E!?*Self {
        const f = (try self.filename()).?.S();
        if (std.mem.eql(u8, f, ".") or std.mem.eql(u8, f, "..")) return of(f);
        const i = std.mem.lastIndexOfScalar(u8, f, '.');
        return of(if (i == null or i.? == 0) f else f[0..i.?]);
    }
    pub fn extension(self: *Self) E!?*Self {
        const f = (try self.filename()).?.S();
        if (std.mem.eql(u8, f, ".") or std.mem.eql(u8, f, "..")) return of("");
        const i = std.mem.lastIndexOfScalar(u8, f, '.');
        return of(if (i == null or i.? == 0) "" else f[i.?..]);
    }
    pub fn replace_extension_FsPath(self: *Self, ext: ?*Self) E!?*Self {
        const e = (try self.extension()).?.S();
        const s = self.S();
        var out: std.ArrayListUnmanaged(u8) = .{};
        defer out.deinit(gpa);
        out.appendSlice(gpa, s[0 .. s.len - e.len]) catch unreachable;
        if (ext) |x| {
            if (x.p.?.n > 0) {
                if (x.S()[0] != '.') out.append(gpa, '.') catch unreachable;
                out.appendSlice(gpa, x.S()) catch unreachable;
            }
        }
        self.p = try str(out.items);
        return self;
    }
    pub fn replace_extension_Str(self: *Self, ext: ?*Str) E!?*Self {
        return self.replace_extension_FsPath(try new_Str(ext));
    }
    /// operator/ : an absolute right side replaces the path; otherwise a separator is added
    pub fn Join_FsPath(self: *Self, o: ?*Self) E!?*Self {
        if (try o.?.is_absolute()) return o.?.Clone();
        const s = self.S();
        if (s.len == 0) return o.?.Clone();
        var out: std.ArrayListUnmanaged(u8) = .{};
        defer out.deinit(gpa);
        out.appendSlice(gpa, s) catch unreachable;
        if (s[s.len - 1] != '/' and o.?.p.?.n > 0) out.append(gpa, '/') catch unreachable;
        out.appendSlice(gpa, o.?.S()) catch unreachable;
        return of(out.items);
    }
    pub fn Join_Str(self: *Self, o: ?*Str) E!?*Self {
        return self.Join_FsPath(try new_Str(o));
    }
    pub fn Join_CPtr(self: *Self, o: ?[*]u8) E!?*Self {
        return self.Join_FsPath(try new_CPtr(o));
    }
    pub fn lexically_normal(self: *Self) E!?*Self {
        return of(normal(self.S()));
    }
    fn normal(s: []const u8) []const u8 {
        if (s.len == 0) return "";
        const abs = s[0] == '/';
        var parts: std.ArrayListUnmanaged([]const u8) = .{};
        defer parts.deinit(gpa);
        var it = std.mem.splitScalar(u8, s, '/');
        while (it.next()) |x| {
            if (x.len == 0 or std.mem.eql(u8, x, ".")) continue;
            if (std.mem.eql(u8, x, "..") and parts.items.len > 0 and !std.mem.eql(u8, parts.items[parts.items.len - 1], "..")) {
                _ = parts.pop();
                continue;
            }
            if (std.mem.eql(u8, x, "..") and abs) continue;
            parts.append(gpa, x) catch unreachable;
        }
        var out: std.ArrayListUnmanaged(u8) = .{};
        if (abs) out.append(gpa, '/') catch unreachable;
        for (parts.items, 0..) |x, k| {
            if (k > 0) out.append(gpa, '/') catch unreachable;
            out.appendSlice(gpa, x) catch unreachable;
        }
        if (s[s.len - 1] == '/' and parts.items.len > 0) out.append(gpa, '/') catch unreachable;
        if (out.items.len == 0) out.append(gpa, '.') catch unreachable;
        return out.items;
    }
};

fn pathOf(p: ?*FsPath) []const u8 {
    return p.?.p.?.bytes();
}

/// Path.GetFullPath: the absolute path, "." and ".." removed (no symbolic link resolved)
fn fullPath(p: []const u8) E![]const u8 {
    if (p.len > 0 and p[0] == '/') return FsPath.normal(p);
    var cwd: [4096]u8 = undefined;
    const c = std.posix.getcwd(&cwd) catch return FsPath.normal(p);
    var out: std.ArrayListUnmanaged(u8) = .{};
    out.appendSlice(gpa, c) catch unreachable;
    out.append(gpa, '/') catch unreachable;
    out.appendSlice(gpa, p) catch unreachable;
    return FsPath.normal(out.items);
}

pub const Fs = struct {
    pub fn exists_FsPath(p: ?*FsPath) E!bool {
        return kindOf(pathOf(p)) != FileStatus.NotFound;
    }
    pub fn exists_FsPath_ErrorCode(p: ?*FsPath, ec: ?*ErrorCode) E!bool {
        _ = ec;
        return exists_FsPath(p);
    }
    pub fn exists_FileStatus(s: ?*FileStatus) E!bool {
        return s.?.kind != FileStatus.NotFound;
    }
    pub fn is_regular_file_FsPath(p: ?*FsPath) E!bool {
        return kindOf(pathOf(p)) == FileStatus.Regular;
    }
    pub fn is_regular_file_FileStatus(s: ?*FileStatus) E!bool {
        return s.?.kind == FileStatus.Regular;
    }
    pub fn is_directory_FsPath(p: ?*FsPath) E!bool {
        return kindOf(pathOf(p)) == FileStatus.Directory;
    }
    pub fn is_directory_FileStatus(s: ?*FileStatus) E!bool {
        return s.?.kind == FileStatus.Directory;
    }
    fn size(path: []const u8) ?u64 {
        const st = std.fs.cwd().statFile(path) catch return null;
        if (st.kind != .file) return null;
        return st.size;
    }
    pub fn file_size_FsPath(p: ?*FsPath) E!u64 {
        return size(pathOf(p)) orelse 0;
    }
    /// file_size(p, ec): ENOENT for a missing file, EISDIR for a directory, and static_cast<uintmax_t>(-1)
    pub fn file_size_FsPath_ErrorCode(p: ?*FsPath, ec: ?*ErrorCode) E!u64 {
        const s = pathOf(p);
        if (size(s)) |n| {
            ec.?.v = 0;
            return n;
        }
        ec.?.v = if (kindOf(s) == FileStatus.Directory) 21 else 2;
        return std.math.maxInt(u64);
    }
    pub fn remove_FsPath_ErrorCode(p: ?*FsPath, ec: ?*ErrorCode) E!bool {
        ec.?.v = 0;
        const s = pathOf(p);
        const k = kindOf(s);
        if (k == FileStatus.Regular or k == 3) {
            std.fs.cwd().deleteFile(s) catch {
                ec.?.v = 13;
                return false;
            };
            return true;
        }
        if (k == FileStatus.Directory) {
            std.fs.cwd().deleteDir(s) catch {
                ec.?.v = 13;
                return false;
            };
            return true;
        }
        return false;
    }
    pub fn remove_FsPath(p: ?*FsPath) E!bool {
        const s = pathOf(p);
        if (kindOf(s) != FileStatus.Regular) return false;
        std.fs.cwd().deleteFile(s) catch return false;
        return true;
    }
    pub fn rename_FsPath_FsPath_ErrorCode(a: ?*FsPath, b: ?*FsPath, ec: ?*ErrorCode) E!void {
        std.fs.cwd().rename(pathOf(a), pathOf(b)) catch |e| {
            ec.?.v = if (e == error.FileNotFound) 2 else 13;
            return;
        };
        ec.?.v = 0;
    }
    pub fn create_hard_link(target: ?*FsPath, link: ?*FsPath, ec: ?*ErrorCode) E!void {
        if (kindOf(pathOf(link)) == FileStatus.Regular) {
            ec.?.v = 17;
            return;
        }
        std.fs.cwd().copyFile(pathOf(target), std.fs.cwd(), pathOf(link), .{}) catch {
            ec.?.v = 2;
            return;
        };
        ec.?.v = 0;
    }
    pub fn weakly_canonical_FsPath(p: ?*FsPath) E!?*FsPath {
        return FsPath.of(try fullPath(pathOf(p)));
    }
    pub fn weakly_canonical_FsPath_ErrorCode(p: ?*FsPath, ec: ?*ErrorCode) E!?*FsPath {
        ec.?.v = 0;
        return weakly_canonical_FsPath(p);
    }
    pub fn equivalent_FsPath_FsPath(a: ?*FsPath, b: ?*FsPath) E!bool {
        return std.mem.eql(u8, try fullPath(pathOf(a)), try fullPath(pathOf(b)));
    }
    pub fn symlink_status_FsPath(p: ?*FsPath) E!?*FileStatus {
        return FileStatus.of(pathOf(p));
    }
    pub fn symlink_status_FsPath_ErrorCode(p: ?*FsPath, ec: ?*ErrorCode) E!?*FileStatus {
        ec.?.v = 0;
        return FileStatus.of(pathOf(p));
    }
    pub fn status_FsPath(p: ?*FsPath) E!?*FileStatus {
        return FileStatus.of(pathOf(p));
    }
};

/// System.IO.File.Exists (the hand-written plugin loader's error text)
pub const File = struct {
    pub fn Exists(s: ?[]const u8) E!bool {
        return kindOf(s.?) == FileStatus.Regular;
    }
};
