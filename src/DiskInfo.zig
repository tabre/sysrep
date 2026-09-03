const std = @import("std");
const Io = std.Io;

const FileReader = @import("util.zig").FileReader;

const mounts_max_size = 4096;

const Self = @This();

disks: []const Disk,

pub const Disk = struct {
    name: []const u8,
    partitions: []const Partition,
};

pub const Partition = struct {
    device: []const u8,
    mount: []const u8,
    fs_type: []const u8,
    total_bytes: u64,
    used_bytes: u64,
    available_bytes: u64,
    used_pct: f64,
    inode_total: u64,
    inode_used: u64,
    inode_used_pct: f64
};

const DiskBuilder = struct {
    name: []u8,
    parts: std.ArrayList(Partition),
};

const StatFs = extern struct {
    f_type: i64,
    f_bsize: i64,
    f_blocks: i64,
    f_bfree: i64,
    f_bavail: i64,
    f_files: i64,
    f_ffree: i64,
    f_fsid: [2]i32,
    f_namelen: i64,
    f_frsize: i64,
    f_flags: i64,
    f_spare: [4]i64,
};

pub fn init(io: Io, alloc: std.mem.Allocator) Self {
    var builders: std.ArrayList(DiskBuilder) = .empty;
    
    // SAFETY: file is initialized on the next line
    var file: FileReader(mounts_max_size) = undefined;
    file.open(io, "/proc/mounts") catch return .{ .disks = &.{} };
    defer file.close();

    while (true) {
        const line = file.nextLineSilent(false) catch |e| switch (e) {
            error.EndOfStream => break,
            else => break,
        };

        var tok = std.mem.tokenizeAny(u8, line, " \t");
        const device = tok.next() orelse continue;
        const mount = tok.next() orelse continue;
        const fs_type = tok.next() orelse continue;

        if (!std.mem.startsWith(u8, device, "/dev/")) continue;
        if (isBootMount(mount)) continue;

        const disk_name = baseDisk(std.fs.path.basename(device));
        if (isRemovable(io, disk_name)) continue;

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{mount}) catch continue;
        const stat = statFs(path_z.ptr) catch continue;

        const frsize: u64 = @intCast(
            if (stat.f_frsize > 0) stat.f_frsize else stat.f_bsize
        );
        const total: u64 = @as(u64, @intCast(stat.f_blocks)) * frsize;
        const available: u64 = @as(u64, @intCast(stat.f_bavail)) * frsize;
        const used: u64 = total -| available;
        const used_pct: f64 = if (used + available > 0) (
            @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(used + available))
        ) * 100.0 else 0.0;

        const inode_total: u64 = @intCast(stat.f_files);
        const inode_used: u64 = inode_total -| @as(u64, @intCast(stat.f_ffree));
        const inode_used_pct: f64 = if (inode_total > 0) (
            @as(f64, @floatFromInt(inode_used)) / @as(f64, @floatFromInt(inode_total))
        ) * 100.0 else 0.0;

        var disk_idx: usize = builders.items.len;
        for (builders.items, 0..) |b, i| {
            if (std.mem.eql(u8, b.name, disk_name)) {
                disk_idx = i;
                break;
            }
        }
        if (disk_idx == builders.items.len) {
            const name_dup = alloc.dupe(u8, disk_name) catch continue;
            builders.append(alloc, .{ .name = name_dup, .parts = .empty }) catch {
                alloc.free(name_dup);
                continue;
            };
        }

        const dev = alloc.dupe(u8, device) catch continue;
        const mnt = alloc.dupe(u8, mount) catch {
            alloc.free(dev);
            continue;
        };
        const fst = alloc.dupe(u8, fs_type) catch {
            alloc.free(dev);
            alloc.free(mnt);
            continue;
        };

        builders.items[disk_idx].parts.append(alloc, .{
            .device = dev,
            .mount = mnt,
            .fs_type = fst,
            .total_bytes = total,
            .used_bytes = used,
            .available_bytes = available,
            .used_pct = used_pct,
            .inode_total = inode_total,
            .inode_used = inode_used,
            .inode_used_pct = inode_used_pct
        }) catch {
            alloc.free(dev);
            alloc.free(mnt);
            alloc.free(fst);
            continue;
        };
    }

    const disks = alloc.alloc(Disk, builders.items.len) catch {
        for (builders.items) |*b| freeBuilder(alloc, b);
        builders.deinit(alloc);

        return .{ .disks = &.{} };
    };

    var converted: usize = 0;
    var failed = false;
    for (builders.items) |*b| {
        const parts = b.parts.toOwnedSlice(alloc) catch {
            failed = true;
            break;
        };
        disks[converted] = .{ .name = b.name, .partitions = parts };
        converted += 1;
    }

    if (failed) {
        for (disks[0..converted]) |d| freeDisk(alloc, d);
        for (builders.items[converted..]) |*b| freeBuilder(alloc, b);
        alloc.free(disks);
        builders.deinit(alloc);

        return .{ .disks = &.{} };
    }

    builders.deinit(alloc);

    return .{ .disks = disks };
}

pub fn deinit(self: Self, alloc: std.mem.Allocator) void {
    for (self.disks) |d| freeDisk(alloc, d);
    alloc.free(self.disks);
}

fn freeDisk(alloc: std.mem.Allocator, disk: Disk) void {
    alloc.free(disk.name);
    for (disk.partitions) |p| freePartitionStrings(alloc, p);
    alloc.free(disk.partitions);
}

fn freeBuilder(alloc: std.mem.Allocator, b: *DiskBuilder) void {
    alloc.free(b.name);
    for (b.parts.items) |p| freePartitionStrings(alloc, p);
    b.parts.deinit(alloc);
}

fn freePartitionStrings(alloc: std.mem.Allocator, p: Partition) void {
    alloc.free(p.device);
    alloc.free(p.mount);
    alloc.free(p.fs_type);
}

fn statFs(path: [*:0]const u8) !StatFs {
    var buf: StatFs = std.mem.zeroes(StatFs);
    const rc = std.os.linux.syscall2(.statfs, @intFromPtr(path), @intFromPtr(&buf));
    if (rc != 0) return error.StatFsFailed;

    return buf;
}

fn isBootMount(mount: []const u8) bool {
    if (std.mem.eql(u8, mount, "/boot")) return true;
    if (std.mem.startsWith(u8, mount, "/boot/")) return true;
    if (std.mem.eql(u8, mount, "/efi")) return true;

    return std.mem.startsWith(u8, mount, "/efi/");
}

fn isRemovable(io: Io, base: []const u8) bool {
    var buf: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "/sys/block/{s}/removable", .{base}) catch return false;

    std.Io.Dir.cwd().access(io, path, .{}) catch return false;

    //SAFETY: f is initialized on the next line
    var f: FileReader(8) = undefined;
    f.open(io, path) catch return false;
    defer f.close();
    const val = std.mem.trim(u8, f.allSilent() catch return false, " \n\r");

    return std.mem.eql(u8, val, "1");
}

fn baseDisk(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, 'p')) |p| {
        if (p + 1 < name.len and allDigits(name[p + 1 ..])) return name[0..p];
    }
    var end = name.len;
    while (end > 0 and std.ascii.isDigit(name[end - 1])) end -= 1;

    return name[0..end];
}

fn allDigits(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}
