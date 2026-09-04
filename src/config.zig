const std = @import("std");
const Io = std.Io;
const EnvironMap = std.process.Environ.Map;

const Yaml = @import("yaml").Yaml;

const FileReader = @import("util.zig").FileReader;

const logger = std.log.scoped(.config);

const appName = "sysrep";
const cfgName = "cfg.yml";
const maxCfgBytes = 4096;

pub const MqttServerConfig = struct {
    addr: []const u8 = "127.0.0.1",
    port: u16 = 1883,
    clientId: []const u8 = "sysrep",
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    keepAlive: u16 = 30,
    timeout: i32 = 5,
    retries: u16 = 3,
    topic: []const u8 = "Systems"
};

pub const Config = struct {
    mqttServer: MqttServerConfig = .{},
    logFile: ?[]const u8 = null,
    logLevel: []const u8 = "info",
    pollInterval: i64 = 5,
    reconnectDelay: i64 = 30,
    dtFormat: ?[]const u8 = null,

    pub fn load(
        io: std.Io,
        alloc: std.mem.Allocator,
        arena: std.mem.Allocator,
        env: *EnvironMap
    ) Config {
        const configPath = if (resolveConfigPath(io, alloc, env)) |p| p else {
            return .{};
        };
        defer alloc.free(configPath); 
        
        // SAFETY: file is initialized on the next line
        var file: FileReader(maxCfgBytes) = undefined;
        file.open(io, configPath) catch |e| {
            logger.warn("Using default config due to error: {any}", .{ e });
            return .{};
        };
        defer file.close();

        const source = file.all() catch |e| {
            logger.warn("Using default config due to error: {any}", .{ e });
            return .{};
        };

        var yaml: Yaml = .{ .source = source };
        defer yaml.deinit(alloc);

        yaml.load(alloc) catch |e| {
            logger.err("Error parsing config ({s}): {any}", .{ configPath, e });
            if (yaml.parse_errors.errorMessageCount() > 0) {
                yaml.parse_errors.renderToStderr(
                    io, .{ .include_reference_trace = true }, .auto
                ) catch {};
            }
            logger.warn("Using default config due to error: {any}", .{ e });
            return .{};
        };

        const config = yaml.parse(arena, Config) catch |e| {
            logger.err("Error parsing config ({s}): {any}", .{ configPath, e });
            logger.warn("Using default config due to error: {any}", .{ e });
            return .{};
        };

        return config;
    }

    fn resolveConfigPath(io: Io, alloc: std.mem.Allocator, env: *EnvironMap) ?[]u8 {
        if (env.get("XDG_CONFIG_HOME")) |path| {
            if (path.len > 0) blk: {
                const filePath = std.fs.path.join(
                    alloc, &.{ path, appName, cfgName }
                ) catch { break :blk; };
                if (fileExists(io, filePath)) return filePath;
                alloc.free(filePath);
            }
        }

        if (env.get("HOME")) |path| {
            if (path.len > 0) blk: {
                const filePath = std.fs.path.join(
                    alloc, &.{ path, ".config", appName, cfgName }
                ) catch { break :blk; };
                if (fileExists(io, filePath)) return filePath;
                alloc.free(filePath);
            }
        }
        
        const filePath: []u8 = std.fs.path.join(
            alloc, &.{ ".", cfgName }
        ) catch return null;
        if (fileExists(io, filePath)) return filePath;
        alloc.free(filePath);
        return null;
    }

    fn fileExists(io: Io, path: []const u8) bool {
        std.Io.Dir.cwd().access(io, path, .{}) catch return false;
        return true;
    }
};
