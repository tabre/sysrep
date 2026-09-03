const std = @import("std");
const Io = std.Io;

const logger = std.log.scoped(.util);

pub inline fn caps(comptime s: []const u8) *const [s.len]u8 {
    comptime {
        var out: [s.len]u8 = undefined;
        for (s, 0..) |c, i| out[i] = std.ascii.toUpper(c);
        const final = out;
        return &final;
    }
}

pub fn FileReader(max_size: usize) type {
    return struct {
        io: Io,
        filename: []const u8,
        file: Io.File,
        file_reader: Io.File.Reader,
        buf: [max_size]u8,

        const Self = @This();

        pub fn _open(self: *Self, io: Io, filename: []const u8, silent: bool) !void {
            self.io = io;
            self.filename = filename;
            self.file = std.Io.Dir.cwd().openFile(
                io, filename, .{ .mode = .read_only }
            ) catch |e| {
                if (!silent) {
                    logger.err("Error opening file ({s}): {any}", .{ self.filename, e });
                }
                return  e;
            };
            // SAFETY: buf is initialized on next line
            self.buf = undefined;
            self.file_reader = self.file.reader(io, &self.buf);
        }

        pub fn open(self: *Self, io: Io, filename: []const u8) !void {
            return self._open(io, filename, false);
        }
        
        pub fn openSilent(self: *Self, io: Io, filename: []const u8) !void {
            return self._open(io, filename, true);
        }
        
        pub fn reader(self: *Self) *std.Io.Reader {
            return &self.file_reader.interface;
        }

        fn _take(self: *Self, until: u8, inclusive: bool, silent: bool) ![]u8 {
            if (inclusive) {
                return self.reader().takeDelimiterInclusive(until) catch |e| {
                    if (!silent) logger.err(
                        "Error reading file ({s}): {any}", .{ self.filename, e }
                    );
                    return e;
                };
            }
            return self.reader().takeDelimiter(until) catch |e| {
                if (!silent) logger.err(
                    "Error reading file ({s}): {any}", .{ self.filename, e }
                );
                return e;
            } orelse error.EndOfStream;
        }

        pub fn take(self: *Self, until: u8, inclusive:bool) ![]u8 {
            return _take(self, until, inclusive, false);
        }

        pub fn takeSilent(self: *Self, until: u8, inclusive:bool) ![]u8 {
            return _take(self, until, inclusive, true);
        }

        pub fn nextLine(self: *Self, inclusive: bool) ![]u8 {
            return self.take('\n', inclusive);
        }

        pub fn nextLineSilent(self: *Self, inclusive: bool) ![]u8 {
            return self.takeSilent('\n', inclusive);
        }

        pub fn all(self: *Self) ![]u8 {
            return self.take(0, false);
        }
        
        pub fn allSilent(self: *Self) ![]u8 {
            return self.takeSilent(0, false);
        }

        pub fn nextLineStartingWith(self: *Self, starts_with: []const u8) ![]u8 {
            while (true) {
                const line = try self.nextLine(false);
                if (std.mem.startsWith(u8, line, starts_with)) {
                    return line;
                }
            } 
        }
        
        pub fn close(self: Self) void {
            self.file.close(self.io);
        }
    };
}
