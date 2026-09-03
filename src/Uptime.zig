const std = @import("std");
const Io = std.Io;

const FileReader = @import("util.zig").FileReader;

const max_uptime_size = 64;

const Self = @This();

days: ?u16,
hours: ?u8,
minutes: ?u8,
seconds: ?u8,

pub fn init(io: Io) Self {
    // SAFETY: file is initialized on the next line
    var file: FileReader(max_uptime_size) = undefined;
    file.open(io, "/proc/uptime") catch return nullValues();
    defer file.close();

    const uptime_str = file.take(' ', true) catch return nullValues();
    const uptime_float = parseUptimeValue(uptime_str) catch return nullValues();
    
    return fromFloat(uptime_float);
}

fn fromFloat(uptime_float: f64) Self {
    const uptime_int: u64 = @intFromFloat(uptime_float);

    return .{
        .days = @intCast(uptime_int / 86400),
        .hours = @intCast((uptime_int % 86400) / 3600),
        .minutes = @intCast((uptime_int % 3600) / 60),
        .seconds = @intCast(uptime_int % 60)
    };
}

fn parseUptimeValue(line: []const u8) !f64 {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const value_str = it.next() orelse return error.ParseError;

    return try std.fmt.parseFloat(f64, value_str);
}

fn nullValues() Self {
    return .{
        .days = null,
        .hours = null,
        .minutes = null,
        .seconds = null
    };
}
