const std = @import("std");
const Io = std.Io;

const boot = @import("boot.zig");

const OsInfo = @import("OsInfo.zig");
const Uptime = @import("Uptime.zig");
const CpuInfo = @import("CpuInfo.zig");
const MemInfo = @import("MemInfo.zig");
const DiskInfo = @import("DiskInfo.zig");
const ProcessInfo = @import("ProcessInfo.zig");
const NetInfo = @import("NetInfo.zig");

const hostnameMax = std.os.linux.HOST_NAME_MAX;

// SAFETY: disk_info is initialized in init() (called before disk_info is accessed)
var disk_info: DiskInfo = undefined;

const Self = @This();

hostname: []const u8,
os: OsInfo,
uptime: Uptime,
boot_time: ?[]const u8,
cpu: CpuInfo,
memory: MemInfo,
disks: []const DiskInfo.Disk,
processes: ProcessInfo,
network: NetInfo,

pub fn init(io: Io, alloc: std.mem.Allocator) Self {
    var hn_buf: [hostnameMax]u8 = std.mem.zeroes([hostnameMax]u8);
    const hostname = std.posix.gethostname(&hn_buf) catch "";
    
    disk_info = DiskInfo.init(io, alloc);

    return .{ 
        .hostname = alloc.dupe(u8, hostname) catch "",
        .os = OsInfo.init(io, alloc),
        .uptime = Uptime.init(io),
        .boot_time = boot.getBootTime(io),
        .cpu = CpuInfo.init(io, alloc),
        .memory = MemInfo.init(io), 
        .disks = disk_info.disks,
        .processes = ProcessInfo.init(io),
        .network = NetInfo.init(io, alloc)
    };
}


pub fn deinit(self: Self, alloc: std.mem.Allocator) void {
    alloc.free(self.hostname);
    self.cpu.deinit(alloc);
    self.network.deinit(alloc);
    disk_info.deinit(alloc);
}
