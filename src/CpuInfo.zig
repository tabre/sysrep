const std = @import("std");
const Io = std.Io;

const FileReader = @import("util.zig").FileReader;
const fileReader = FileReader(stat_max_size);

const stat_max_size = 8192;
const cpuinfo_max_size = 4096;
const max_cores = 256;

var prev: ?StatSample = null;
var cached_model: ?[]u8 = null;
var model_attempted: bool = false;

const CoreSample = struct { total: u64, idle: u64 };

const StatSample = struct {
    total: u64,
    idle: u64,
    cores: [max_cores]CoreSample,
    core_count: u32,
};

model: ?[]const u8,
overall_pct: ?f64,
core_count: u32,
core_pcts: []const ?f64,
temp_f: ?f64,

const Self = @This();

pub fn init(io: Io, alloc: std.mem.Allocator) Self {
    const now = readStat(io) orelse return nullValues();
    const previous = prev;
    prev = now;

    const pcts = alloc.alloc(?f64, now.core_count) catch return nullValues();
    for (0..now.core_count) |i| { 
        pcts[i] = if (previous) |p| utilization(
            p.cores[i].total, 
            p.cores[i].idle,
            now.cores[i].total,
            now.cores[i].idle
        ) else null; 
    }

    if (!model_attempted) {
        model_attempted = true;
        cached_model = readModel(io, alloc);
    }

    return .{
        .model = cached_model,
        .overall_pct = if (previous) |p| utilization(
            p.total, p.idle, now.total, now.idle
        ) else null,
        .core_count = now.core_count,
        .core_pcts = pcts,
        .temp_f = readCpuTemp(io),
    };
}

pub fn deinit(self: Self, alloc: std.mem.Allocator) void {
    alloc.free(self.core_pcts);
}

fn nullValues() Self {
    return .{ 
        .model = null,
        .overall_pct = null,
        .core_count = 0,
        .core_pcts = &.{},
        .temp_f = null
    };
}

fn utilization(prev_total: u64, prev_idle: u64, now_total: u64, now_idle: u64) ?f64 {
    const dt = now_total -| prev_total;
    const di = now_idle -| prev_idle;
    
    if (dt == 0) return null;

    const busy = dt -| di;

    return (
        @as(f64, @floatFromInt(busy)) / @as(f64, @floatFromInt(dt))
    ) * 100.0;
}

fn readStat(io: Io) ?StatSample {
    // SAFETY: file is initialized on the next line
    var file: fileReader = undefined;
    file.open(io, "/proc/stat") catch return null;
    defer file.close();

    var sample = std.mem.zeroes(StatSample);
    while (true) {
        const line = file.nextLineStartingWith("cpu") catch |e| switch (e) {
            error.EndOfStream => break,
            else => return null
        };
        var tok = std.mem.tokenizeAny(u8, line, " \t");
        const label = tok.next() orelse continue;

        const cs = parseCoreSample(&tok) orelse continue;

        if (label.len == 3) {
            sample.total = cs.total;
            sample.idle = cs.idle;
        } else {
            const idx = std.fmt.parseInt(u32, label[3..], 10) catch continue;
            if (idx >= max_cores) continue;
            sample.cores[idx] = cs;
            sample.core_count = @max(sample.core_count, idx + 1);
        }
    }

    if (sample.total == 0 or sample.core_count == 0) return null;
    return sample;
}

fn parseCoreSample(tok: anytype) ?CoreSample {
    var total: u64 = 0;
    var idle: u64 = 0;
    var idx: usize = 0;

    while (tok.next()) |s| : (idx += 1) {
        const v = std.fmt.parseInt(u64, s, 10) catch return null;
        total += v;
        if (idx == 3 or idx == 4) idle += v;
    }

    if (idx < 4) return null;

    return .{ .total = total, .idle = idle };
}

fn readCpuTemp(io: Io) ?f64 {
    var dir = std.Io.Dir.openDirAbsolute(
        io, "/sys/class/hwmon", .{ .iterate = true }
    ) catch return null;
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch return null) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "hwmon")) continue;

        var name_buf: [128]u8 = undefined;
        const name_path = std.fmt.bufPrint(
            &name_buf, "/sys/class/hwmon/{s}/name", .{entry.name}
        ) catch continue;
        
        // SAFETY: nf is initialized on the next line
        var nf: FileReader(32) = undefined;
        nf.open(io, name_path) catch continue;

        const driver = std.mem.trim(u8, nf.allSilent() catch {
            nf.close();
            continue;
        }, " \n\r");

        nf.close();

        if (
            !std.mem.eql(u8, driver, "coretemp") and
            !std.mem.eql(u8, driver, "k10temp")
        ) continue;

        var temp_buf: [128]u8 = undefined;
        const temp_path = std.fmt.bufPrint(
            &temp_buf, "/sys/class/hwmon/{s}/temp1_input", .{entry.name}
        ) catch return null;
        
        // SAFETY: tf is initialized on the next line
        var tf: FileReader(32) = undefined;
        tf.open(io, temp_path) catch return null;
        defer tf.close();

        const raw = std.mem.trim(u8, tf.allSilent() catch return null, " \n\r");
        const milli_c = std.fmt.parseInt(i32, raw, 10) catch return null;

        return (@as(f64, @floatFromInt(milli_c)) / 1000.0) * 1.8 + 32.0;
    }
    return null;
}

fn readModel(io: Io, alloc: std.mem.Allocator) ?[]u8 {
    // SAFETY: file is initialized on the next line
    var file: FileReader(cpuinfo_max_size) = undefined;
    file.open(io, "/proc/cpuinfo") catch return null;
    defer file.close();

    const line = file.nextLineStartingWith("model name") catch return null;

    var it = std.mem.tokenizeScalar(u8, line, ':');
    _ = it.next();

    const value = std.mem.trim(u8, it.rest(), " \t");
    if (value.len == 0) return null;

    return alloc.dupe(u8, value) catch null;
}
