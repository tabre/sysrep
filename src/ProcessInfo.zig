const std = @import("std");
const Io = std.Io;

const FileReader = @import("util.zig").FileReader;

const logger = std.log.scoped(.process_info);

const stat_max_size = 512;

const Self = @This();

running: ?u64,
sleeping: ?u64,
blocked: ?u64,
zombie: ?u64,
stopped: ?u64,
idle: ?u64,
other: ?u64,
total: ?u64,

pub fn init(io: Io) Self {
    var dir = std.Io.Dir.openDirAbsolute(io, "/proc", .{ .iterate = true }) catch |e| {
        logger.err("Error opening /proc: {any}", .{e});
        return nullValues();
    };
    defer dir.close(io);

    var running: u64 = 0;
    var sleeping: u64 = 0;
    var blocked: u64 = 0;
    var zombie: u64 = 0;
    var stopped: u64 = 0;
    var idle: u64 = 0;
    var other: u64 = 0;
    var total: u64 = 0;

    var it = dir.iterate();
    while (it.next(io) catch return nullValues()) |entry| {
        if (entry.name.len == 0 or !std.ascii.isDigit(entry.name[0])) continue;

        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/proc/{s}/stat", .{entry.name}) catch continue;
        
        // SAFETY: file is initialized on next line
        var file: FileReader(stat_max_size) = undefined;
        file.openSilent(io, path) catch continue;
        defer file.close();

        const line = file.allSilent() catch continue;
        const last_paren = std.mem.lastIndexOfScalar(u8, line, ')') orelse continue;
        if (last_paren + 2 >= line.len) continue;

        total += 1;
        switch (line[last_paren + 2]) {
            'R' => running += 1,
            'S' => sleeping += 1,
            'D' => blocked += 1,
            'Z' => zombie += 1,
            'T', 't' => stopped += 1,
            'I' => idle += 1,
            else => other += 1,
        }
    }

    return .{
        .running = running,
        .sleeping = sleeping,
        .blocked = blocked,
        .zombie = zombie,
        .stopped = stopped,
        .idle = idle,
        .other = other,
        .total = total,
    };
}

fn nullValues() Self {
    return .{
        .running = null,
        .sleeping = null,
        .blocked = null,
        .zombie = null,
        .stopped = null,
        .idle = null,
        .other = null,
        .total = null,
    };
}
