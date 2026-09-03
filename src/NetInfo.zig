const std = @import("std");
const Io = std.Io;

const netlink = @import("netlink");
const FileReader = @import("util.zig").FileReader;

const dev_max_size = 4096;
const sock_max_size = 4096;
const if_name_max = 16;
const max_interfaces = 128;

const Self = @This();

interfaces: []const Interface,
sockets: []const Socket,

pub const IpAddr = struct {
    addr: []const u8,
    prefix_len: u8,
};

pub const Interface = struct {
    name: []const u8,
    rx_rate_bytes: ?u64,
    tx_rate_bytes: ?u64,
    ipv4: []const IpAddr,
    ipv6: []const IpAddr,
};

pub const Socket = struct {
    protocol: []const u8,
    address: []const u8,
    port: u16,
};

const CounterEntry = struct {
    name: [if_name_max]u8,
    rx: u64,
    tx: u64,
};

const BaselineEntry = struct {
    name: [if_name_max]u8,
    rx: u64,
    tx: u64,
    ts_ms: i64,
};

const Rates = struct {
    rx: ?u64,
    tx: ?u64,
};

var baseline: [max_interfaces]BaselineEntry = undefined;
var baseline_len: usize = 0;

pub fn init(io: Io, alloc: std.mem.Allocator) Self {
    var nl = netlink.Socket.open(alloc) catch return .{ .interfaces = &.{}, .sockets = &.{} };
    defer nl.close();

    const links = nl.links() catch return .{ .interfaces = &.{}, .sockets = &.{} };
    defer alloc.free(links);

    const addresses = nl.addresses(.{}) catch return .{ .interfaces = &.{}, .sockets = &.{} };
    defer alloc.free(addresses);

    var counters: [max_interfaces]CounterEntry = undefined;
    const counters_len = readCounters(io, &counters);

    const now_ms = std.Io.Clock.real.now(io).toMilliseconds();

    var list: std.ArrayList(Interface) = .empty;

    for (links) |l| {
        if ((l.flags & netlink.IFF.UP) == 0) continue;
        if ((l.flags & netlink.IFF.RUNNING) == 0) continue;
        if ((l.flags & netlink.IFF.LOOPBACK) != 0) continue;

        const name = l.name();
        if (name.len == 0 or name.len >= if_name_max) continue;

        const counter = findCounter(counters[0..counters_len], name) orelse continue;
        const rates = updateBaseline(name, counter.rx, counter.tx, now_ms);

        var iface = buildInterface(alloc, name, l.index, addresses) catch continue;
        iface.rx_rate_bytes = rates.rx;
        iface.tx_rate_bytes = rates.tx;

        list.append(alloc, iface) catch {
            freeInterface(alloc, iface);
            continue;
        };
    }

    const ifaces = list.toOwnedSlice(alloc) catch {
        for (list.items) |i| freeInterface(alloc, i);
        list.deinit(alloc);
        return .{ .interfaces = &.{}, .sockets = &.{} };
    };

    const sockets = readSockets(io, alloc) catch &.{};

    return .{ .interfaces = ifaces, .sockets = sockets };
}

pub fn deinit(self: Self, alloc: std.mem.Allocator) void {
    for (self.interfaces) |iface| freeInterface(alloc, iface);
    alloc.free(self.interfaces);
    for (self.sockets) |s| freeSocket(alloc, s);
    alloc.free(self.sockets);
}

fn buildInterface(
    alloc: std.mem.Allocator,
    name: []const u8,
    ifindex: u32,
    addresses: []const netlink.Address,
) !Interface {
    var ipv4_list: std.ArrayList(IpAddr) = .empty;
    errdefer freeIpAddrList(alloc, &ipv4_list);

    var ipv6_list: std.ArrayList(IpAddr) = .empty;
    errdefer freeIpAddrList(alloc, &ipv6_list);

    for (addresses) |a| {
        if (a.ifindex != ifindex) continue;
        if ((@as(u32, a.flags) & netlink.IFA_F.TENTATIVE) != 0) continue;
        if (a.family == netlink.AF.INET) {
            const s = try formatIpv4(a.bytes(), alloc);
            try ipv4_list.append(alloc, .{ .addr = s, .prefix_len = a.prefixlen });
        } else if (a.family == netlink.AF.INET6) {
            const s = try formatIpv6(a.bytes(), alloc);
            try ipv6_list.append(alloc, .{ .addr = s, .prefix_len = a.prefixlen });
        }
    }

    const name_dup = try alloc.dupe(u8, name);
    errdefer alloc.free(name_dup);

    const ipv4 = try ipv4_list.toOwnedSlice(alloc);
    errdefer {
        freeAddrList(alloc, ipv4);
        alloc.free(ipv4);
    }

    const ipv6 = try ipv6_list.toOwnedSlice(alloc);
    errdefer {
        freeAddrList(alloc, ipv6);
        alloc.free(ipv6);
    }

    return .{
        .name = name_dup,
        .rx_rate_bytes = null,
        .tx_rate_bytes = null,
        .ipv4 = ipv4,
        .ipv6 = ipv6,
    };
}

fn readCounters(io: Io, counters: []CounterEntry) usize {
    // SAFETY: file is initialized on the next line
    var file: FileReader(dev_max_size) = undefined;
    file.openSilent(io, "/proc/net/dev") catch return 0;
    defer file.close();

    var n: usize = 0;
    while (true) {
        const line = file.nextLine(false) catch |e| switch (e) {
            error.EndOfStream => break,
            else => break,
        };

        const trimmed = std.mem.trim(u8, line, " \t");
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const name = trimmed[0..colon];
        if (name.len == 0 or name.len >= if_name_max) continue;

        var nums = std.mem.tokenizeAny(u8, trimmed[colon + 1 ..], " \t");
        var rx: u64 = 0;
        var tx: u64 = 0;
        var idx: usize = 0;
        while (nums.next()) |s| : (idx += 1) {
            const v = std.fmt.parseInt(u64, s, 10) catch break;
            if (idx == 0) rx = v;
            if (idx == 8) tx = v;
        }
        if (idx < 9) continue;
        if (n >= counters.len) break;

        @memset(counters[n].name[0..], 0);
        @memcpy(counters[n].name[0..name.len], name);
        counters[n].rx = rx;
        counters[n].tx = tx;
        n += 1;
    }

    return n;
}

fn findCounter(counters: []const CounterEntry, name: []const u8) ?CounterEntry {
    for (counters) |c| {
        if (std.mem.eql(u8, std.mem.sliceTo(c.name[0..], 0), name)) return c;
    }
    return null;
}

fn formatIpv4(bytes: []const u8, alloc: std.mem.Allocator) ![]u8 {
    var buf: [16]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3] });
    return try alloc.dupe(u8, s);
}

fn formatIpv6(bytes: []const u8, alloc: std.mem.Allocator) ![]u8 {
    var buf: [40]u8 = undefined;
    return try alloc.dupe(u8, ipv6ToString(bytes, &buf));
}

fn ipv6ToString(bytes: []const u8, buf: []u8) []u8 {
    var groups: [8]u16 = undefined;
    for (0..8) |i| {
        groups[i] = (@as(u16, bytes[i * 2]) << 8) | bytes[i * 2 + 1];
    }

    var best_start: usize = 0;
    var best_len: usize = 0;
    var i: usize = 0;
    while (i < 8) {
        if (groups[i] == 0) {
            var j = i;
            while (j < 8 and groups[j] == 0) : (j += 1) {}
            if (j - i >= 2 and j - i > best_len) {
                best_start = i;
                best_len = j - i;
            }
            i = j;
        } else {
            i += 1;
        }
    }

    var w = std.Io.Writer.fixed(buf);
    var k: usize = 0;
    while (k < 8) {
        if (best_len >= 2 and k == best_start) {
            w.writeAll("::") catch unreachable;
            k += best_len;
            continue;
        }
        const follows_compression = best_len >= 2 and k == best_start + best_len;
        if (k != 0 and !follows_compression) {
            w.writeByte(':') catch unreachable;
        }
        w.print("{x}", .{groups[k]}) catch unreachable;
        k += 1;
    }
    return w.buffered();
}

fn freeAddrList(alloc: std.mem.Allocator, list: []const IpAddr) void {
    for (list) |a| alloc.free(a.addr);
}

fn freeIpAddrList(alloc: std.mem.Allocator, list: *std.ArrayList(IpAddr)) void {
    freeAddrList(alloc, list.items);
    list.deinit(alloc);
}

fn freeInterface(alloc: std.mem.Allocator, iface: Interface) void {
    alloc.free(iface.name);
    freeAddrList(alloc, iface.ipv4);
    alloc.free(iface.ipv4);
    freeAddrList(alloc, iface.ipv6);
    alloc.free(iface.ipv6);
}

fn freeSocket(alloc: std.mem.Allocator, sock: Socket) void {
    // protocol is a comptime string literal; only address is heap-allocated.
    alloc.free(sock.address);
}

const SockFile = struct {
    path: []const u8,
    protocol: []const u8,
    state: []const u8,
};

const sock_files = [_]SockFile{
    .{ .path = "/proc/net/tcp", .protocol = "tcp4", .state = "0A" },
    .{ .path = "/proc/net/tcp6", .protocol = "tcp6", .state = "0A" },
    .{ .path = "/proc/net/udp", .protocol = "udp4", .state = "07" },
    .{ .path = "/proc/net/udp6", .protocol = "udp6", .state = "07" },
};

fn readSockets(io: Io, alloc: std.mem.Allocator) ![]Socket {
    var list: std.ArrayList(Socket) = .empty;
    errdefer {
        for (list.items) |s| freeSocket(alloc, s);
        list.deinit(alloc);
    }

    for (sock_files) |sf| {
        // SAFETY: file is initialized on the next line
        var file: FileReader(sock_max_size) = undefined;
        file.openSilent(io, sf.path) catch continue;
        defer file.close();

        while (true) {
            const line = file.nextLine(false) catch |e| switch (e) {
                error.EndOfStream => break,
                else => break,
            };

            var tok = std.mem.tokenizeAny(u8, line, " \t");
            _ = tok.next();
            const local = tok.next() orelse continue;
            _ = tok.next();
            const state = tok.next() orelse continue;
            if (!std.mem.eql(u8, state, sf.state)) continue;

            const colon = std.mem.indexOfScalar(u8, local, ':') orelse continue;
            const addr_hex = local[0..colon];
            const port_hex = local[colon + 1 ..];
            if (port_hex.len == 0) continue;
            const port = std.fmt.parseInt(u16, port_hex, 16) catch continue;

            const addr = formatSockAddr(addr_hex, alloc) catch continue;
            list.append(alloc, .{ .protocol = sf.protocol, .address = addr, .port = port }) catch {
                alloc.free(addr);
                continue;
            };
        }
    }

    return try list.toOwnedSlice(alloc);
}

fn formatSockAddr(addr_hex: []const u8, alloc: std.mem.Allocator) ![]u8 {
    if (addr_hex.len == 8) {
        const v = try std.fmt.parseInt(u32, addr_hex, 16);
        var buf: [16]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}", .{
            v & 0xff,
            (v >> 8) & 0xff,
            (v >> 16) & 0xff,
            (v >> 24) & 0xff,
        });
        return try alloc.dupe(u8, s);
    }

    if (addr_hex.len == 32) {
        var bytes: [16]u8 = undefined;
        for (0..4) |g| {
            const v = try std.fmt.parseInt(u32, addr_hex[g * 8 .. (g + 1) * 8], 16);
            bytes[g * 4] = @intCast(v & 0xff);
            bytes[g * 4 + 1] = @intCast((v >> 8) & 0xff);
            bytes[g * 4 + 2] = @intCast((v >> 16) & 0xff);
            bytes[g * 4 + 3] = @intCast((v >> 24) & 0xff);
        }
        var buf: [40]u8 = undefined;
        return try alloc.dupe(u8, ipv6ToString(&bytes, &buf));
    }

    return error.InvalidAddress;
}

fn updateBaseline(name: []const u8, rx: u64, tx: u64, now_ms: i64) Rates {
    for (baseline[0..baseline_len]) |*e| {
        if (std.mem.eql(u8, std.mem.sliceTo(e.name[0..], 0), name)) {
            const dt_ms = now_ms - e.ts_ms;
            var rates = Rates{ .rx = null, .tx = null };
            if (dt_ms > 0) {
                const dt: u64 = @intCast(dt_ms);
                rates.rx = (rx -| e.rx) * 1000 / dt;
                rates.tx = (tx -| e.tx) * 1000 / dt;
            }
            e.rx = rx;
            e.tx = tx;
            e.ts_ms = now_ms;
            return rates;
        }
    }

    if (baseline_len < max_interfaces) {
        const e = &baseline[baseline_len];
        @memset(e.name[0..], 0);
        @memcpy(e.name[0..name.len], name);
        e.rx = rx;
        e.tx = tx;
        e.ts_ms = now_ms;
        baseline_len += 1;
    }

    return .{ .rx = null, .tx = null };
}
