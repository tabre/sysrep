const std = @import("std");
const Io = std.Io;

const time = @import("time.zig");

const util = @import("util.zig");

// SAFETY: io is set in the init function (called immediately at runtime)
var io: Io = undefined;
var log_file: ?std.Io.File = null;
var log_level: std.log.Level = .info;
var log_file_pos: u64 = 0;

const logger = std.log.scoped(.log);

pub fn init(_io: Io) void {
    io = _io;
}

pub fn setLogFile(path: []const u8) !void {
    if (log_file) |f| f.close(io);
    const file = try std.Io.Dir.cwd().createFile(
        io, path, .{ .truncate = false, .read = true }
    );
    log_file = file;
    log_file_pos = try file.length(io);
}

pub fn setLogLevel(l: []const u8) void {
    log_level = parseLevel(l) orelse {
        logger.warn("Invalid log level: {s}", .{ l });
        return;
    };
}

fn parseLevel(s: []const u8) ?std.log.Level {
    inline for (std.enums.values(std.log.Level)) |l|
        if(std.mem.eql(u8, @tagName(l), s) or std.mem.eql(u8, l.asText(), s))
            return l;

    return null;
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime fmt: []const u8,
    args: anytype
) void {
    if (@intFromEnum(level) > @intFromEnum(log_level)) return;
    var msg_buf: [2048]u8 = undefined;
    const message = std.fmt.bufPrint(&msg_buf, fmt, args) catch return;

    var ts_buf: [64]u8 = undefined;
    const timestamp: ?[]const u8 = time.format(
        std.Io.Clock.real.now(io).toMilliseconds(), &ts_buf
    ) orelse null;

    {
        var lock_buf: [64]u8 = undefined;
        const locked = std.debug.lockStderr(&lock_buf);
        defer std.debug.unlockStderr();

        const stderr = locked.terminal().writer;
        writeLine(stderr, level, scope, timestamp, message, true) catch {};
        stderr.flush() catch {};
    }

    if (log_file) |file| {
        var buf: [4096]u8 = undefined;
        var writer = file.writer(io, &buf);
        writer.pos = log_file_pos;
        defer log_file_pos = writer.pos;
        const interface = &writer.interface;
        writeLine(interface, level, scope, timestamp, message, false) catch {};
        interface.flush() catch {};
    }

}

fn writeLine(
    w: *std.Io.Writer,
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    timestamp: ?[]const u8,
    message: []const u8,
    comptime colored: bool
) std.Io.Writer.Error!void {
    const color = levelColor(level);
    if (colored) {
        if (timestamp) |ts| try w.print(
            "\x1b[{d}m{s} {s} [{s}]\x1b[0m {s}\n", 
            .{ color, ts, levelToStr(level), @tagName(scope), message }
        ) else try w.print(
            "\x1b[{d}m{s} [{s}]\x1b[0m {s}\n",
            .{ color, levelToStr(level), @tagName(scope), message }
        );
    } else {
        if (timestamp) |ts| try w.print(
            "{s} {s} [{s}] {s}\n",
            .{ts, levelToStr(level), @tagName(scope), message }
        ) else try w.print(
            "{s} [{s}] {s}\n",
            .{ levelToStr(level), @tagName(scope), message}
        );
    }
}

fn levelToStr(comptime level: std.log.Level) []const u8 {
    return util.caps(level.asText());
}

fn levelColor(comptime level: std.log.Level) u8 {
    return switch (level) {
        .info => 32,
        .warn => 33,
        .err => 31,
        .debug => 34
    };
}

pub fn deinit() void {
    if (log_file) |f| f.close(io);
    log_file = null;
}

