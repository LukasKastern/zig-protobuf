const std = @import("std");
const builtin = @import("builtin");
const Build = std.Build;
const Step = std.Build.Step;
const fs = std.fs;
const mem = std.mem;
const LazyPath = std.Build.LazyPath;

const Self = @This();

pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addLibrary(.{
        .name = "zig-protobuf",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/protobuf.zig"),
            .target = target,
            .optimize = optimize,
        }),

        .linkage = .static,
    });

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    const module = b.addModule("protobuf", .{
        .root_source_file = b.path("src/protobuf.zig"),
        .target = target,
        .optimize = optimize,
    });

    const merge_proto = b.addExecutable(.{
        .name = "merge_proto",
        .root_module = b.createModule(.{
            .optimize = .Debug,
            .root_source_file = b.path("src/merge_proto.zig"),
            .target = b.graph.host, // always build for native
        }),
    });
    b.installArtifact(merge_proto);

    const exe = b.addExecutable(.{
        .name = "protoc-gen-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bootstrapped-generator/main.zig"),
            .target = b.graph.host, // always build for native
            .optimize = optimize,
        }),
    });

    exe.root_module.addImport("protobuf", module);

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    const test_step = b.step("test", "Run library tests");

    const tests = [_]*std.Build.Step.Compile{
        // b.addTest(.{ .name = "protobuf", .root_module = module }),
        b.addTest(.{
            .name = "bootstrap",
            .root_module = b.createModule(.{
                .root_source_file = b.path("bootstrapped-generator/main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        }),
        b.addTest(.{
            .name = "tests",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/tests.zig"),
                .target = target,
                .optimize = optimize,
            }),
        }),
        b.addTest(.{
            .name = "alltypes",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/alltypes.zig"),
                .target = target,
                .optimize = optimize,
            }),
        }),
        b.addTest(.{
            .name = "integration",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/integration.zig"),
                .target = target,
                .optimize = optimize,
            }),
        }),
        b.addTest(.{
            .name = "fixedsizes",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/tests_fixedsizes.zig"),
                .target = target,
                .optimize = optimize,
            }),
        }),
        b.addTest(.{
            .name = "varints",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/tests_varints.zig"),
                .target = target,
                .optimize = optimize,
            }),
        }),
        b.addTest(.{
            .name = "json",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/tests_json.zig"),
                .target = target,
                .optimize = optimize,
            }),
        }),
        b.addTest(.{
            .name = "FullName",
            .root_module = b.createModule(.{
                .root_source_file = b.path("bootstrapped-generator/FullName.zig"),
                .target = target,
                .optimize = optimize,
            }),
        }),
        b.addTest(.{
            .name = "complex_type",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/tests_complex_type.zig"),
                .target = target,
                .optimize = optimize,
            }),
        }),
        b.addTest(.{
            .name = "services",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/test_services.zig"),
                .target = target,
                .optimize = optimize,
            }),
        }),
        b.addTest(.{
            .name = "stream",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/stream.zig"),
                .target = target,
                .optimize = optimize,
            }),
        }),
    };

    var dep = std.Build.Dependency{ .builder = b };
    const convertStep = runProtoc(b, &dep, &.{
        .source_files = &.{b.path("tests/protos_for_test/generated_in_ci.proto")},
        .include_directories = &.{b.path("tests/protos_for_test")},
    });

    const convertStep2 = runProtoc(b, &dep, &.{
        .source_files = &.{
            b.path("tests/protos_for_test/all.proto"),
            b.path("tests/protos_for_test/complex_type.proto"),
            // b.path("tests/protos_for_test/onnx.proto"),
            b.path("tests/protos_for_test/test_service.proto"),
            b.path("tests/protos_for_test/whitespace-in-name.proto"),
        },
        .include_directories = &.{b.path("tests/protos_for_test")},
    });

    const convert_one_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = convertStep,
    });
    convert_one_mod.addImport("protobuf", module);

    const convert_two_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = convertStep2,
    });
    convert_two_mod.addImport("protobuf", module);

    for (tests) |test_item| {
        if (!std.mem.eql(u8, "protobuf", test_item.name)) {
            test_item.root_module.addImport("protobuf", module);
        }
        test_item.root_module.addImport("protobuf", module);

        test_item.root_module.addImport("API", convert_one_mod);
        test_item.root_module.addImport("API_Two", convert_one_mod);

        // This creates a build step. It will be visible in the `zig build --help` menu,
        // and can be selected like this: `zig build test`
        // This will evaluate the `test` step rather than the default, which is "install".
        const run_main_tests = b.addRunArtifact(test_item);
        test_step.dependOn(&run_main_tests.step);
    }

    const protobuf_dep = b.dependency("protobuf", .{ .optimize = .Debug });

    const include = try protobuf_dep.namedLazyPath("protobuf_source").join(b.allocator, "src");

    const bootstrap = b.step("bootstrap", "run the generator over its own sources");

    const bootstrap_src = runProtoc(b, &dep, &.{
        .source_files = &.{
            try include.join(b.allocator, "google/protobuf/compiler/plugin.proto"),
            try include.join(b.allocator, "google/protobuf/descriptor.proto"),
        },
        .proto_path = include,
    });
    const bootstrap_lib = b.addLibrary(.{
        .name = "bootstrap",
        .root_module = b.createModule(.{
            .root_source_file = bootstrap_src,
            .target = target,
            .optimize = optimize,
        }),
    });
    const install_bootstrap = b.addInstallArtifact(bootstrap_lib, .{});
    bootstrap.dependOn(&install_bootstrap.step);
}

pub const RunProtocSettings = struct {
    // List of source files
    source_files: []const std.Build.LazyPath,
    include_directories: []const std.Build.LazyPath = &.{},

    // Proto path override - by default the directory name of the first source file is used
    proto_path: ?std.Build.LazyPath = null,
};

// Create a run step that converts the given protoc input into a zig source file
pub fn runProtoc(b: *std.Build, protoc_dep: *std.Build.Dependency, options: *const RunProtocSettings) std.Build.LazyPath {
    // Declare protobuf - always using native target and debug for compilation speed
    const protobuf = protoc_dep.builder.dependency("protobuf", .{
        .optimize = .Debug,
        .target = b.graph.host,
    });

    // Grab protoc
    const protoc = protobuf.artifact("protoc");

    // Grab merge proto
    const merge_proto = protoc_dep.artifact("merge_proto");

    const run_protoc = b.addRunArtifact(protoc);

    // Declare plugin
    run_protoc.addPrefixedArtifactArg("--plugin=protoc-gen-zig=", protoc_dep.artifact("protoc-gen-zig"));

    // Declare output
    run_protoc.addArg("--zig_out");

    const output_dir = run_protoc.addOutputDirectoryArg("proto_out");

    // Include default src
    const google_include = protobuf.namedLazyPath("protobuf_source").join(b.allocator, "src") catch @panic("OOM");
    run_protoc.addPrefixedDirectoryArg("-I", google_include);

    // Declare input directories
    for (options.include_directories) |include| {
        run_protoc.addPrefixedDirectoryArg("-I", include);
    }

    // Declare source file directory
    std.debug.assert(options.source_files.len > 0);

    const proto_path = options.proto_path orelse options.source_files[0].dirname();
    run_protoc.setCwd(proto_path);
    run_protoc.addPrefixedDirectoryArg("--proto_path=", proto_path);

    // Declare source file
    for (options.source_files) |file| {
        run_protoc.addFileArg(file);
    }

    // Merge the generated packages into a single file
    const run_merge = b.addRunArtifact(merge_proto);
    run_merge.addDirectoryArg(output_dir);
    run_merge.addArg(b.graph.zig_exe);
    const merged_dir = run_merge.addOutputDirectoryArg("proto_out");

    return merged_dir.join(b.allocator, "api.zig") catch unreachable;
}
