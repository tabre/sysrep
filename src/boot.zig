const std = @import("std");
const Io = std.Io;

const FileReader = @import("util.zig").FileReader;
const time = @import("time.zig");

var cached: ?[]const u8 = null;
var attempted: bool = false;
var boot_time_buf: [64] u8 = undefined;

const stat_max_size = 8192;

pub fn getBootTime(io: Io) ?[]const u8 {
    if (!attempted) {
        attempted = true;
        cached = readBootTime(io);
    }

    return cached;
}

fn readBootTime(io: Io) ?[]const u8 {
    // SAFETY: file is initialized on the next line
    var file: FileReader(stat_max_size) = undefined;
    file.open(io, "/proc/stat") catch return null;
    defer file.close();
    
    const line = file.nextLineStartingWith("btime") catch return null;
    var tok = std.mem.tokenizeAny(u8, line, " \t");
    _ = tok.next();

    const btime_str = tok.next() orelse return null;
    const btime_secs = std.fmt.parseInt(i64, btime_str, 10) catch return null;

    return time.format(btime_secs * 1000, &boot_time_buf) orelse null;
}
