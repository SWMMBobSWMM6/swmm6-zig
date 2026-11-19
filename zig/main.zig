//! main.zig - the SWMM6 command line (src/cli/main.cpp), translated by hand after cs/runtime/Program.cs: the same
//! calls into the engine's C API in the same order, the same messages on stdout and the same exit code.
//!   runswmm6 model.inp model.rpt [model.out]
//! Written by Claude (Anthropic) for the SWMM6 ports; see AI-USE.md.
const std = @import("std");
const rt = @import("rt/rt.zig");
const eng = @import("gen/engine.zig");

const VERSION = "6.0.0-alpha.4";

fn out(s: []const u8) void {
    rt.R.stdout_.?.writeBytes(s) catch {};
}

fn outf(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    out(s);
}

fn cstr(s: []const u8) ?[*]u8 {
    const b = rt.gcSlice(u8, s.len + 1);
    @memcpy(b[0..s.len], s);
    return b.ptr;
}

fn msg(engine: rt.Obj) []const u8 {
    const p = eng.F___swmm_get_last_error_msg(engine) catch return "";
    if (p == null) return "(null)";
    return p.?[0..rt.crt.slen(p)];
}

pub fn main() u8 {
    rt.init();
    const rc = run() catch blk: {
        const e = rt.cur_exc;
        if (e) |x| {
            const w = x.what() catch null;
            outf("\nterminate called after throwing an exception: {s}\n", .{if (w) |p| p[0..rt.crt.slen(p)] else ""});
        }
        break :blk 134;
    };
    rt.crt.flushAll(); // returning from main calls exit(), which flushes every open FILE
    return @truncate(@as(u32, @bitCast(rc)));
}

fn run() rt.E!i32 {
    try eng.__static_init();
    var it = std.process.args();
    _ = it.next();
    var argv: [3][]const u8 = undefined;
    var argc: usize = 0;
    while (it.next()) |a| {
        if (argc < 3) argv[argc] = a;
        argc += 1;
    }
    if (argc < 1) {
        out("\nError: not enough arguments. Use --help for usage.\n\n");
        return 1;
    }
    if (std.mem.eql(u8, argv[0], "--version") or std.mem.eql(u8, argv[0], "-v")) {
        out("openswmm.engine " ++ VERSION ++ "\n");
        return 0;
    }
    if (argc < 2) {
        out("\nError: need at least input and report file paths.\n");
        out("Usage: openswmm <input.inp> <report.rpt> [output.out]\n\n");
        return 1;
    }
    const inp = argv[0];
    const rpt = argv[1];
    const outfile: []const u8 = if (argc > 2) argv[2] else "";
    outf("\n... OpenSWMM Engine " ++ VERSION ++ "\n... Input: {s}\n... Report: {s}\n... Output: {s}\n", .{ inp, rpt, outfile });
    _ = try rt.R.fflush(rt.R.stdout_);
    const t0 = (rt.TimePoint.now() catch rt.TimePoint{}).ns;
    const engine = try eng.F___swmm_engine_create();
    if (engine == null) {
        out("Error: failed to create engine instance.\n");
        return 1;
    }
    var err = try eng.F___swmm_engine_open(engine, cstr(inp), cstr(rpt), cstr(outfile), null);
    if (err != 0) {
        outf("Error opening input file: {s}\n", .{msg(engine)});
        try eng.F___swmm_engine_destroy(engine);
        return err;
    }
    err = try eng.F___swmm_engine_initialize(engine);
    if (err != 0) {
        outf("Error initializing: {s}\n", .{msg(engine)});
        _ = try eng.F___swmm_engine_close(engine);
        try eng.F___swmm_engine_destroy(engine);
        return err;
    }
    const save: i32 = if (outfile.len > 0) 1 else 0;
    err = try eng.F___swmm_engine_start(engine, save);
    if (err != 0) {
        outf("Error starting simulation: {s}\n", .{msg(engine)});
        _ = try eng.F___swmm_engine_close(engine);
        try eng.F___swmm_engine_destroy(engine);
        return err;
    }
    const elapsed = rt.gcSlice(f64, 1);
    var steps: i64 = 0;
    while (true) {
        err = try eng.F___swmm_engine_step(engine, elapsed.ptr);
        if (err != 0) {
            outf("\nError at step {d}: {s}\n", .{ steps, msg(engine) });
            break;
        }
        if (elapsed[0] <= 0.0) break;
        steps += 1;
    }
    outf("\n... {d} steps completed.\n", .{steps});
    var result = err;
    const phases = [_][]const u8{ "ending simulation", "writing report", "closing simulation" };
    for (phases, 0..) |phase, k| {
        const status = switch (k) {
            0 => try eng.F___swmm_engine_end(engine),
            1 => try eng.F___swmm_engine_report(engine),
            else => try eng.F___swmm_engine_close(engine),
        };
        if (status != 0) {
            outf("Error {s}: {s}\n", .{ phase, msg(engine) });
            if (result == 0) result = status;
        }
    }
    try eng.F___swmm_engine_destroy(engine);
    const secs = @as(f64, @floatFromInt((rt.TimePoint.now() catch rt.TimePoint{}).ns - t0)) / 1e9;
    outf("... OpenSWMM Engine {s} in {d:.2} seconds.\n\n", .{ if (result == 0) "completed" else "failed", secs });
    return result;
}
