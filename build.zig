const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zeit  = b.dependency("zeit", .{}).module("zeit");
    const yaml  = b.dependency("zig_yaml", .{}).module("yaml");
    const zerde = b.dependency("zerde", .{}).module("zerde");
    const mqttz = b.dependency("mqttz", .{}).module("mqttz");
    const netlink = b.dependency("zig_libs", .{}).module("netlink");

    const exe = b.addExecutable(.{
        .name = "sysrep",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zeit",  .module = zeit },
                .{ .name = "yaml",  .module = yaml },
                .{ .name = "zerde", .module = zerde },
                .{ .name = "mqttz", .module = mqttz },
                .{ .name = "netlink", .module = netlink }
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
