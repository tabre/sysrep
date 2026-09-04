const std = @import("std");
const Io = std.Io;

const zeit = @import("zeit");

const logger = std.log.scoped(.time);

// SAFETY: io is initialized in init() (called immediately at runtime)
var io: Io = undefined;
var tz: ?zeit.TimeZone = null;
const default_dt_fmt = "%Y-%m-%d %I:%M:%S %p";
var dt_fmt: ?[]const u8 = null;

pub fn init(_io: Io, alloc: std.mem.Allocator) void {
    io = _io;
    tz = zeit.local(alloc, io, .{}) catch null;
}

pub fn setFormat(fmt: []const u8) void {
    dt_fmt = fmt;
}

pub fn deinit() void {
    if (tz) |z| z.deinit();
    tz = null;
}

pub fn now(buf: []u8) ?[]u8 {
    return format(std.Io.Clock.real.now(io).toMilliseconds(), buf);
}

pub fn now_s() i64 {
    return std.Io.Clock.real.now(io).toSeconds();
}

pub fn format(ms: i64, buf: []u8) ?[]u8 {
    const zone = tz orelse return null;
    const instant = zeit.instant(io, .{
        .source = .{ .unix_timestamp = @divTrunc(ms, 1000) },
        .timezone = &zeit.utc
    }) catch return null;

    const t = instant.in(&zone).time();
    var writer = std.Io.Writer.fixed(buf);
    t.strftime(&writer, dt_fmt orelse default_dt_fmt) catch return null;

    return writer.buffered();
}
