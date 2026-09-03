const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");

const FileReader = @import("util.zig").FileReader;

const os_release_max = 4096;
const kernel_max = 64;

const Self = @This();

os: ?[]const u8,
kernel: ?[]const u8,
arch: []const u8,

var cached_os: ?[]u8 = null;
var cached_kernel: ?[]u8 = null;
var attempted: bool = false;

pub fn init(io: Io, alloc: std.mem.Allocator) Self {
    if (!attempted) {
        attempted = true;
        cached_os = readOsName(io, alloc);
        cached_kernel = readKernel(io, alloc);
    }

    return .{
        .os = cached_os,
        .kernel = cached_kernel,
        .arch = @tagName(builtin.target.cpu.arch),
    };
}

fn readOsName(io: Io, alloc: std.mem.Allocator) ?[]u8 {
    // SAFETY: file is initialized on the next line
    var file: FileReader(os_release_max) = undefined;
    file.openSilent(io, "/etc/os-release") catch return null;
    defer file.close();

    const line = file.nextLineStartingWith("PRETTY_NAME=") catch return null;
    var value: []const u8 = line["PRETTY_NAME=".len..];
    value = std.mem.trim(u8, value, " \t\n\r");

    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        value = value[1 .. value.len - 1];
    }

    if (value.len == 0) return null;

    return alloc.dupe(u8, value) catch null;
}

fn readKernel(io: Io, alloc: std.mem.Allocator) ?[]u8 {
    // SAFETY: file is initialized on the next line
    var file: FileReader(kernel_max) = undefined;
    file.openSilent(io, "/proc/sys/kernel/osrelease") catch return null;
    defer file.close();

    const raw = file.allSilent() catch return null;
    const value = std.mem.trim(u8, raw, " \t\n\r");

    if (value.len == 0) return null;

    return alloc.dupe(u8, value) catch null;
}
