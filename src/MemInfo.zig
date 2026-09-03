const std = @import("std");
const Io = std.Io;

const FileReader = @import("util.zig").FileReader;

const mem_info_max_size = 4096;

const Self = @This();

available_kb: ?u64,
total_kb: ?u64,
used_pct: ?f64,
swap_total_kb: ?u64,
swap_free_kb: ?u64,
swap_used_pct: ?f64,

pub fn init(io: Io) Self {
    // SAFETY: file is initialized on the next line
    var file: FileReader(mem_info_max_size) = undefined;
    file.open(io, "/proc/meminfo") catch { return nullValues(); };
    defer file.close();

    var available_kb: ?u64 = null;
    var total_kb: ?u64 = null;
    var swap_total_kb: ?u64 = null;
    var swap_free_kb: ?u64 = null;

    while (true) {
        const line = file.nextLine(false) catch |e| switch (e) {
            error.EndOfStream => break,
            else => { return nullValues(); }
        };

        if (std.mem.startsWith(u8, line, "MemAvailable:")) {
            available_kb = parseKbValue(line) catch null;
        } else if (std.mem.startsWith(u8, line, "MemTotal:")) {
            total_kb = parseKbValue(line) catch null;
        } else if (std.mem.startsWith(u8, line, "SwapTotal:")) {
            swap_total_kb = parseKbValue(line) catch null;
        } else if (std.mem.startsWith(u8, line, "SwapFree:")) {
            swap_free_kb = parseKbValue(line) catch null;
        }

        if (
            available_kb != null and
            total_kb != null and
            swap_total_kb != null and
            swap_free_kb != null
        ) break;
    }

    return Self {
        .available_kb = available_kb,
        .total_kb = total_kb,
        .used_pct = usedPercent(available_kb, total_kb),
        .swap_total_kb = swap_total_kb,
        .swap_free_kb = swap_free_kb,
        .swap_used_pct = usedPercent(swap_free_kb, swap_total_kb)
    };
}

fn nullValues() Self {
    return .{ 
        .available_kb = null,
        .total_kb = null,
        .used_pct = null,
        .swap_total_kb = null,
        .swap_free_kb = null,
        .swap_used_pct = null
    };
}

fn usedPercent(avail: ?u64, total: ?u64) ?f64 {
    if (avail == null or total == null) return null;
    const a = avail.?;
    const t = total.?;

    if (t == 0) return null;

    const used = t -| a;
    return (@as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(t))) * 100.0;
}

fn parseKbValue(line: []const u8) !u64 {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    _ = it.next();
    const value_str = it.next() orelse return error.ParseError;

    return try std.fmt.parseInt(u64, value_str, 10);
}
