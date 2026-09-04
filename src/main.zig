const std = @import("std");
const Io = std.Io;

const zerde = @import("zerde");

const mqtt = @import("mqttz");
const Client = mqtt.posix.Client311;
const Packet = mqtt.Packet;

const config = @import("config.zig");
const Config = config.Config;
const MqttServerConfig = config.MqttServerConfig;

const err = @import("err.zig");
const SysRep = @import("SysRep.zig");

const time = @import("time.zig");

const log = @import("log.zig");
pub const std_options: std.Options = .{
    .logFn = log.logFn, .log_level = .debug
};
const logger = std.log.scoped(.sysrep);

// SAFETY: io is defined on the first line of main()
var io: std.Io = undefined;

const PING_INTERVAL_SEC:i64 = 30;

pub fn main(init: std.process.Init) !void {
    io = init.io;
    const env = init.environ_map;
    const alloc = init.gpa;
    const arena = init.arena.allocator();
    
    time.init(io, alloc);
    log.init(io);

    const cfg = Config.load(io, alloc, arena, env);

    if (cfg.dtFormat) |fmt| time.setFormat(fmt);

    log.setLogLevel(cfg.logLevel);
    if (cfg.logFile) |lf| {
        log.setLogFile(lf) catch |e| {
            logger.err("Error opening logfile ({s}): {any}", .{ lf, e });
        };
    }

    var client = try Client.init(io, .{
        .ip = cfg.mqttServer.addr,
        .port = cfg.mqttServer.port,
        .default_retries = cfg.mqttServer.retries,
        .default_timeout = cfg.mqttServer.timeout * 1000,
        .allocator = alloc
    });
    defer {
        client.disconnect(.{ .timeout = 1000 }, .{ .reason = .normal }) catch |e| {
            logger.warn("Error disconnecting from MQTT client: {any}", .{ e });
        };
        client.deinit();
    }

    var last_ping = time.now_s();

    while (true) {
        if (client.socket == null) {
            logger.info("Connecting to {s}", .{ cfg.mqttServer.addr });
            clientConnect(&client, &cfg.mqttServer) catch { 
                Io.sleep(init.io, .fromSeconds(cfg.reconnectDelay), .awake) catch continue;
                continue; 
            };
            last_ping = time.now_s();
        }

        const ss = SysRep.init(io, alloc);
        defer ss.deinit(alloc);

        var out = Io.Writer.Allocating.init(alloc);
        defer out.deinit();
        
        zerde.serialize(zerde.json, &out.writer, ss) catch |e| {
            logger.err("Serialization error: {any}\n", .{ e });
            continue;
        };

        const topic = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ 
            cfg.mqttServer.topic, ss.hostname 
        });
        defer alloc.free(topic);
       
        logger.debug("Publishing to {s}", .{ topic });

        _ = client.publish(.{ .retries = 0 }, .{
            .topic = topic,
            .message = out.written()
        }) catch |e| {
            logger.err("Error publishing: {any}\n", .{ e });
            if (client.socket) |s| s.close(io);
            client.socket = null;
            continue;
        };

        logger.debug("Publish succeeded", .{});

        const now = time.now_s();
        if (now - last_ping >= PING_INTERVAL_SEC) {
            logger.debug("Pinging server", .{});
            client.ping(.{ .retries = 0, .timeout = 5000}) catch |e| {
                logger.warn("Ping failed, connection appears dead: {any}", .{ e });
                if (client.socket) |s| s.close(io);
                client.socket = null;
                continue;
            };
            last_ping = now;
            logger.debug("Ping succeeded", .{});
        }

        Io.sleep(init.io, .fromSeconds(cfg.pollInterval), .awake) catch continue;
    }
}

fn clientConnect(client: *Client, cfg: *const MqttServerConfig) !void {
    client.connect(.{ .retries = cfg.retries, .timeout = cfg.timeout * 1000 }, .{ 
        .client_id = cfg.clientId,
        .username = cfg.username,
        .password = cfg.password,
        .keepalive_sec = cfg.keepAlive
    }) catch |e| {
        logger.err("Error connecting to server: {any}\n", .{ e });
        return err.client.ConnectionError; 
    };

    const response: ?Packet = client.readPacket(.{ .retries = 0 }) catch {
        return err.client.PacketReadError;
    };

    if (response) |packet| switch (packet) {
        .connack => |c| { 
            logger.info(
                "Connected to server - CONNACK: {any}\n", .{ c }
            );
            return;
        },
        .disconnect => |d| {
            logger.warn(
                "Server disconnected: {s}\n", .{ @tagName(d.reason_code) 
            });
            return err.client.ServerDisconnect;
        },
        else => |p| {
            logger.warn(
                "Unexpected server response: {s}\n", .{ @tagName(p) }
            );
            return err.client.UnexpectedResponse;
        }
    } else {
        logger.warn("Server sent no response.\n", .{});
        return err.client.ServerNoResponse;
    }
}
