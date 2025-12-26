const std = @import("std");
const protobuf = @import("protobuf");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dependencies
    const protobuf_dep = b.dependency("protobuf", .{
        .target = target,
        .optimize = optimize,
    });
    const grpc_dep = b.dependency("grpc_zig", .{
        .target = target,
        .optimize = optimize,
    });

    const protobuf_mod = protobuf_dep.module("protobuf");
    const grpc_mod = grpc_dep.module("grpc");

    // Generate Zig code from Proto
    const gen_proto_step = b.step("gen-proto", "Generate Zig code from Proto files");
    const protoc_step = protobuf.RunProtocStep.create(protobuf_dep.builder, target, .{
        .destination_directory = b.path("src/proto"),
        .source_files = &.{"proto/log.proto"},
        .include_directories = &.{},
    });
    gen_proto_step.dependOn(&protoc_step.step);

    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("coleman", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
    });

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "coleman",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                // Here "coleman" is the name you will use in your source code to
                // import this module (e.g. `@import("coleman")`). The name is
                // repeated because you are allowed to rename your imports, which
                // can be extremely useful in case of collisions (which can happen
                // importing modules from different packages).
                .{ .name = "coleman", .module = mod },
            },
        }),
    });

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // Create modules for source files that main needs to import
    const schema_mod_main = b.addModule("schema", .{
        .root_source_file = b.path("src/schema.zig"),
        .target = target,
    });

    const table_mod_main = b.addModule("table", .{
        .root_source_file = b.path("src/table.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "schema", .module = schema_mod_main },
        },
    });

    const config_mod_main = b.addModule("config", .{
        .root_source_file = b.path("src/config.zig"),
        .target = target,
    });

    const wal_mod_main = b.addModule("wal", .{
        .root_source_file = b.path("src/wal.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "schema", .module = schema_mod_main },
            .{ .name = "table", .module = table_mod_main },
        },
    });

    const snapshot_mod_main = b.addModule("snapshot", .{
        .root_source_file = b.path("src/snapshot.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "schema", .module = schema_mod_main },
            .{ .name = "table", .module = table_mod_main },
        },
    });

    const proto_mod_main = b.addModule("proto", .{
        .root_source_file = b.path("src/proto/log.pb.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "protobuf", .module = protobuf_mod },
        },
    });

    const filter_mod_main = b.addModule("filter", .{
        .root_source_file = b.path("src/query/filter.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "schema", .module = schema_mod_main },
            .{ .name = "table", .module = table_mod_main },
            .{ .name = "proto", .module = proto_mod_main },
        },
    });

    const aggregate_mod_main = b.addModule("aggregate", .{
        .root_source_file = b.path("src/query/aggregate.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "schema", .module = schema_mod_main },
            .{ .name = "table", .module = table_mod_main },
            .{ .name = "proto", .module = proto_mod_main },
            .{ .name = "filter", .module = filter_mod_main },
        },
    });

    const table_manager_mod_main = b.addModule("table_manager", .{
        .root_source_file = b.path("src/table_manager.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "schema", .module = schema_mod_main },
            .{ .name = "table", .module = table_mod_main },
            .{ .name = "config", .module = config_mod_main },
            .{ .name = "wal", .module = wal_mod_main },
            .{ .name = "snapshot", .module = snapshot_mod_main },
            .{ .name = "proto", .module = proto_mod_main },
            .{ .name = "filter", .module = filter_mod_main },
            .{ .name = "aggregate", .module = aggregate_mod_main },
        },
    });

    // Add modules to executable
    exe.root_module.addImport("protobuf", protobuf_mod);
    exe.root_module.addImport("grpc", grpc_mod);
    exe.root_module.addImport("schema", schema_mod_main);
    exe.root_module.addImport("table", table_mod_main);
    exe.root_module.addImport("config", config_mod_main);
    exe.root_module.addImport("wal", wal_mod_main);
    exe.root_module.addImport("snapshot", snapshot_mod_main);
    exe.root_module.addImport("table_manager", table_manager_mod_main);
    exe.root_module.addImport("proto", proto_mod_main);

    // Client executable
    const client_exe = b.addExecutable(.{
        .name = "coleman-client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/client.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    client_exe.root_module.addImport("protobuf", protobuf_mod);
    client_exe.root_module.addImport("grpc", grpc_mod);
    client_exe.root_module.addImport("schema", schema_mod_main);
    client_exe.root_module.addImport("table", table_mod_main);
    client_exe.root_module.addImport("table_manager", table_manager_mod_main);
    b.installArtifact(client_exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Test suite organization
    const test_step = b.step("test", "Run all tests");
    const unit_test_step = b.step("test-unit", "Run unit tests only");
    const integration_test_step = b.step("test-integration", "Run integration tests (requires server running on port 50051)");

    // Helper function to create a test executable
    const TestFile = struct {
        path: []const u8,
        name: []const u8,
    };

    const unit_tests = [_]TestFile{
        .{ .path = "tests/schema_test.zig", .name = "schema" },
        .{ .path = "tests/table_test.zig", .name = "table" },
        .{ .path = "tests/table_manager_test.zig", .name = "table_manager" },
        .{ .path = "tests/filter_test.zig", .name = "filter" },
        .{ .path = "tests/aggregate_test.zig", .name = "aggregate" },
    };

    const integration_tests = [_]TestFile{
        .{ .path = "tests/integration_test.zig", .name = "integration" },
    };

    // Create modules for source files that tests need to import
    const schema_mod = b.addModule("schema", .{
        .root_source_file = b.path("src/schema.zig"),
        .target = target,
    });

    const table_mod = b.addModule("table", .{
        .root_source_file = b.path("src/table.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "schema", .module = schema_mod },
        },
    });

    const config_mod = b.addModule("config", .{
        .root_source_file = b.path("src/config.zig"),
        .target = target,
    });

    const wal_mod = b.addModule("wal", .{
        .root_source_file = b.path("src/wal.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "schema", .module = schema_mod },
            .{ .name = "table", .module = table_mod },
        },
    });

    const snapshot_mod = b.addModule("snapshot", .{
        .root_source_file = b.path("src/snapshot.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "schema", .module = schema_mod },
            .{ .name = "table", .module = table_mod },
        },
    });

    const proto_mod_test = b.addModule("proto", .{
        .root_source_file = b.path("src/proto/log.pb.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "protobuf", .module = protobuf_mod },
        },
    });

    const filter_mod_test = b.addModule("filter", .{
        .root_source_file = b.path("src/query/filter.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "schema", .module = schema_mod },
            .{ .name = "table", .module = table_mod },
            .{ .name = "proto", .module = proto_mod_test },
        },
    });

    const aggregate_mod_test = b.addModule("aggregate", .{
        .root_source_file = b.path("src/query/aggregate.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "schema", .module = schema_mod },
            .{ .name = "table", .module = table_mod },
            .{ .name = "proto", .module = proto_mod_test },
            .{ .name = "filter", .module = filter_mod_test },
        },
    });

    const table_manager_mod = b.addModule("table_manager", .{
        .root_source_file = b.path("src/table_manager.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "schema", .module = schema_mod },
            .{ .name = "table", .module = table_mod },
            .{ .name = "config", .module = config_mod },
            .{ .name = "wal", .module = wal_mod },
            .{ .name = "snapshot", .module = snapshot_mod },
            .{ .name = "proto", .module = proto_mod_test },
            .{ .name = "filter", .module = filter_mod_test },
            .{ .name = "aggregate", .module = aggregate_mod_test },
        },
    });

    // Add unit tests
    for (unit_tests) |test_file| {
        const unit_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(test_file.path),
                .target = target,
                .optimize = optimize,
            }),
        });

        // Add module imports based on test file
        if (std.mem.indexOf(u8, test_file.path, "schema") != null) {
            unit_test.root_module.addImport("schema", schema_mod);
        }
        if (std.mem.indexOf(u8, test_file.path, "table_test") != null) {
            unit_test.root_module.addImport("schema", schema_mod);
            unit_test.root_module.addImport("table", table_mod);
        }
        if (std.mem.indexOf(u8, test_file.path, "table_manager") != null) {
            unit_test.root_module.addImport("schema", schema_mod);
            unit_test.root_module.addImport("table", table_mod);
            unit_test.root_module.addImport("table_manager", table_manager_mod);
            unit_test.root_module.addImport("config", config_mod);
        }
        if (std.mem.indexOf(u8, test_file.path, "filter_test") != null or std.mem.indexOf(u8, test_file.path, "filter_debug") != null) {
            unit_test.root_module.addImport("schema", schema_mod);
            unit_test.root_module.addImport("table", table_mod);
            unit_test.root_module.addImport("table_manager", table_manager_mod);
            unit_test.root_module.addImport("config", config_mod);
            unit_test.root_module.addImport("proto", proto_mod_test);
        }
        if (std.mem.indexOf(u8, test_file.path, "aggregate_test") != null) {
            unit_test.root_module.addImport("schema", schema_mod);
            unit_test.root_module.addImport("table", table_mod);
            unit_test.root_module.addImport("table_manager", table_manager_mod);
            unit_test.root_module.addImport("config", config_mod);
            unit_test.root_module.addImport("proto", proto_mod_test);
        }

        const run_unit_test = b.addRunArtifact(unit_test);
        unit_test_step.dependOn(&run_unit_test.step);
        test_step.dependOn(&run_unit_test.step);
    }

    // Create proto module for integration tests
    const proto_mod = b.addModule("proto", .{
        .root_source_file = b.path("src/proto/log.pb.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "protobuf", .module = protobuf_mod },
        },
    });

    // Add integration tests
    for (integration_tests) |test_file| {
        const int_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(test_file.path),
                .target = target,
                .optimize = optimize,
                .imports = &.{},
            }),
        });
        int_test.root_module.addImport("protobuf", protobuf_mod);
        int_test.root_module.addImport("grpc", grpc_mod);
        int_test.root_module.addImport("proto", proto_mod);

        const run_int_test = b.addRunArtifact(int_test);
        integration_test_step.dependOn(&run_int_test.step);
        // Note: Integration tests not added to main test step by default
        // Run with: zig build test-integration
    }

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
