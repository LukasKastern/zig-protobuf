const std = @import("std");
const builtin = @import("builtin");
const Build = std.Build;
const Step = std.Build.Step;
const fs = std.fs;
const mem = std.mem;
const LazyPath = std.Build.LazyPath;

const PROTOC_VERSION = "23.4";

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

    const protobuf_mod = b.addModule("protobuf", .{
        .root_source_file = b.path("src/protobuf.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = buildGenerator(b, .{
        .target = target,
        .optimize = optimize,
    }, protobuf_mod);

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    _ = try getProtocInstallDir(std.heap.page_allocator, PROTOC_VERSION);
}

pub const RunProtocStep = struct {
    step: Step,
    source_file: []const u8,
    include_directories: []const []const u8,

    generator: *std.Build.Step.Compile,
    verbose: bool = false, // useful for debugging if you need to know what protoc command is sent

    output_file: std.Build.GeneratedFile,
    out_file_path: []const u8,

    module: *std.Build.Module,

    pub const base_id = .protoc;

    pub const Options = struct {
        source_file: []const u8,
        include_directories: []const []const u8 = &.{},
        out_file_path: []const u8,
    };

    pub const StepErr = error{
        FailedToConvertProtobuf,
    };

    pub fn create(
        owner: *std.Build,
        dependency_builder: *std.Build,
        target: std.Build.ResolvedTarget,
        options: Options,
        protobuf_module: *std.Build.Module,
    ) *RunProtocStep {
        var self: *RunProtocStep = owner.allocator.create(RunProtocStep) catch @panic("OOM");
        self.* = .{
            .step = Step.init(.{
                .id = .check_file,
                .name = "run protoc",
                .owner = owner,
                .makeFn = make,
            }),
            .source_file = owner.dupe(options.source_file),
            .include_directories = owner.dupeStrings(options.include_directories),
            .output_file = .{ .step = &self.step },
            .generator = buildGenerator(dependency_builder, .{ .target = target }, protobuf_module),
            .out_file_path = owner.dupe(options.out_file_path),
            .module = undefined,
        };

        // Create module
        self.module = owner.createModule(.{
            .root_source_file = .{
                .generated = .{
                    .file = &self.output_file,
                },
            },
            .target = target,
            .optimize = .ReleaseFast,
        });
        self.module.addImport("protobuf", protobuf_module);

        self.step.dependOn(&self.generator.step);

        return self;
    }

    pub fn setName(self: *RunProtocStep, name: []const u8) void {
        self.step.name = name;
    }

    fn make(step: *Step, make_opt: std.Build.Step.MakeOptions) anyerror!void {
        _ = make_opt;
        const b = step.owner;
        const self: *RunProtocStep = @fieldParentPtr("step", step);

        var man = b.graph.cache.obtain();
        defer man.deinit();

        // Random bytes to make step unique. Refresh this with new
        // random bytes when ConfigHeader implementation is modified in a
        // non-backwards-compatible way.
        man.hash.add(@as(u32, 0xdef01d56));
        for (self.include_directories) |include| {
            man.hash.addBytes(include);
        }

        man.hash.addBytes(self.source_file);

        const src = b.build_root.handle.readFileAlloc(b.allocator, self.source_file, 1024 * 1024 * 32) catch |e| {
            return step.fail("unable to find source file {s}: {}", .{ self.source_file, e });
        };
        defer b.allocator.free(src);

        man.hash.addBytes(src);

        if (try step.cacheHit(&man)) {
            const digest = man.final();
            self.output_file.path = try b.cache_root.join(b.allocator, &.{
                "o", &digest, self.out_file_path,
            });
            return;
        }

        const digest = man.final();

        const dir_path = try b.cache_root.join(b.allocator, &.{
            "o", &digest,
        });

        const proto_gen_path = try b.cache_root.join(b.allocator, &.{
            "o", &digest, "gen",
        });

        b.cache_root.handle.makePath(dir_path) catch |err| {
            return step.fail("unable to make path '{}{s}': {s}", .{
                b.cache_root, dir_path, @errorName(err),
            });
        };

        b.cache_root.handle.makePath(proto_gen_path) catch |e| {
            return step.fail("unable to make path {s}: {}", .{ proto_gen_path, e });
        };

        {
            // run protoc
            var argv = std.ArrayList([]const u8).init(b.allocator);

            const protoc_path = try ensureProtocBinaryDownloaded(std.heap.page_allocator, PROTOC_VERSION);
            try argv.append(protoc_path);

            // specify the path to the plugin
            try argv.append(try std.mem.concat(b.allocator, u8, &.{ "--plugin=protoc-gen-zig=", self.generator.getEmittedBin().getPath(b) }));

            // specify the destination

            try argv.append(try std.mem.concat(b.allocator, u8, &.{ "--zig_out=", proto_gen_path }));
            if (!dirExists(proto_gen_path)) {
                try std.fs.makeDirAbsolute(proto_gen_path);
            }

            // include directories
            for (self.include_directories) |it| {
                try argv.append(try std.mem.concat(b.allocator, u8, &.{ "-I", it }));
            }

            const real_path = try b.build_root.handle.realpathAlloc(b.allocator, self.source_file);
            const source_file_dir_path = std.fs.path.dirname(real_path) orelse return error.NoDirNameFound;

            try argv.append(try std.mem.concat(b.allocator, u8, &.{ "--proto_path=", source_file_dir_path }));

            // Add source file
            try argv.append(std.fs.path.basename(real_path));

            if (self.verbose) {
                std.debug.print("Running protoc:", .{});
                for (argv.items) |it| {
                    std.debug.print(" {s}", .{it});
                }
                std.debug.print("\n", .{});
            }

            // Run with working dir set to build root
            const result = std.process.Child.run(.{
                .allocator = b.allocator,
                .argv = argv.items,
                .progress_node = std.Progress.Node.none,
                .cwd_dir = b.build_root.handle,
            }) catch |err| return step.fail("failed to run {s}: {s}", .{ argv.items[0], @errorName(err) });
            try step.handleChildProcessTerm(result.term, null, argv.items);
        }

        { // run zig fmt <destination>
            var argv = std.ArrayList([]const u8).init(b.allocator);

            try argv.append(b.graph.zig_exe);
            try argv.append("fmt");
            try argv.append(proto_gen_path);

            _ = try step.evalChildProcess(argv.items);
        }

        const child_dir = try b.cache_root.handle.openDir(proto_gen_path, .{ .iterate = true });
        var content = std.ArrayListUnmanaged(u8){};

        const DirStackEntry = struct {
            path: []const u8,
            entry: std.fs.Dir,
        };
        var dir_stack = std.ArrayListUnmanaged(DirStackEntry){};
        try dir_stack.append(b.allocator, .{ .path = "gen/", .entry = child_dir });

        // Find exports inside the generated proto files
        var exports = std.ArrayListUnmanaged([]const u8){};
        while (dir_stack.items.len > 0) {
            const next_child = dir_stack.pop() orelse @panic("");
            var it = next_child.entry.iterate();
            while (try it.next()) |next| {
                switch (next.kind) {
                    .file => {
                        const child_content = try next_child.entry.readFileAlloc(b.allocator, next.name, 1024 * 1024 * 32);

                        const export_prefix = "pub const ";

                        var exported_members = std.mem.splitScalar(u8, child_content, '\n');
                        while (exported_members.next()) |line| {
                            if (!std.mem.startsWith(u8, line, export_prefix)) {
                                continue;
                            }

                            const end = std.mem.indexOfScalar(u8, line[export_prefix.len..], ' ') orelse {
                                return error.CorruptExport;
                            };

                            const type_name = line[export_prefix.len .. export_prefix.len + end];
                            const export_line = try std.fmt.allocPrint(b.allocator, "pub const {s} = @import(\"{s}{s}\").{s};", .{ type_name, next_child.path, next.name, type_name });
                            try exports.append(b.allocator, export_line);
                        }
                    },
                    .directory => {
                        const dir = try next_child.entry.openDir(next.name, .{ .iterate = true });
                        const path = try std.mem.concat(b.allocator, u8, &.{ next_child.path, next.name, "/" });

                        try dir_stack.append(b.allocator, .{
                            .entry = dir,
                            .path = path,
                        });
                    },
                    else => {},
                }
            }
        }

        // Build content
        try content.appendSlice(b.allocator, "// Code generated by protoc-gen-zig\n");

        for (exports.items) |export_line| {
            try content.appendSlice(b.allocator, export_line);
            try content.append(b.allocator, '\n');
        }

        const sub_path = b.pathJoin(&.{ "o", &digest, self.out_file_path });

        b.cache_root.handle.writeFile(.{ .data = content.items, .sub_path = sub_path }) catch |err| {
            return step.fail("unable to write proto file '{}{s}': {s}", .{
                b.cache_root, sub_path, @errorName(err),
            });
        };

        self.output_file.path = try b.cache_root.join(b.allocator, &.{
            "o", &digest, self.out_file_path,
        });

        try man.writeManifest();
    }
};

pub const GenOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode = .Debug,
};

pub fn buildGenerator(b: *std.Build, opt: GenOptions, protobuf_module: *std.Build.Module) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "protoc-gen-zig",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("bootstrapped-generator/main.zig"),
        .target = opt.target,
        .optimize = opt.optimize,
    });

    // const module = b.addModule("protobuf", .{
    // .root_source_file = b.path("src/protobuf.zig"),
    // });

    exe.root_module.addImport("protobuf", protobuf_module);

    b.installArtifact(exe);

    return exe;
}

fn getGitHubBaseURLOwned(allocator: std.mem.Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "GITHUB_BASE_URL")) |base_url| {
        std.log.info("zig-protobuf: respecting GITHUB_BASE_URL: {s}\n", .{base_url});
        return base_url;
    } else |_| {
        return allocator.dupe(u8, "https://github.com");
    }
}

var download_mutex = std.Thread.Mutex{};

fn getProtocInstallDir(
    allocator: std.mem.Allocator,
    protoc_version: []const u8,
) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "PROTOC_PATH") catch null) |protoc_path| {
        std.log.info("zig-protobuf: respecting PROTOC_PATH: {s}\n", .{protoc_path});
        if (fileExists(protoc_path)) {
            // user has probably provided full path to protoc binary instead of proto_dir
            // also, if these fail and user explicitly provided custom path, we probably don't want to download stuff
            const bin_dir = std.fs.path.dirname(protoc_path).?;
            const real_proto_dir = std.fs.path.dirname(bin_dir).?;
            return real_proto_dir;
        }

        std.log.err("zig-protobuf: cannot resolve a protoc provided via PROTOC_PATH env var ({s}), make sure the value is correct", .{protoc_path});
        std.process.exit(1);
    }

    const base_cache_dir_rel = try std.fs.path.join(allocator, &.{ ".zig-cache", "zig-protobuf", "protoc" });
    try std.fs.cwd().makePath(base_cache_dir_rel);
    const base_cache_dir = try std.fs.cwd().realpathAlloc(allocator, base_cache_dir_rel);
    const versioned_cache_dir = try std.fs.path.join(allocator, &.{ base_cache_dir, protoc_version });
    defer {
        allocator.free(base_cache_dir_rel);
        allocator.free(base_cache_dir);
        allocator.free(versioned_cache_dir);
    }

    const target_cache_dir = try std.fs.path.join(allocator, &.{ versioned_cache_dir, @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) });
    return target_cache_dir;
}

/// ensures the protoc executable exists and returns an absolute path to it
fn ensureProtocBinaryDownloaded(
    allocator: std.mem.Allocator,
    protoc_version: []const u8,
) ![]const u8 {
    const target_cache_dir = try getProtocInstallDir(allocator, protoc_version);

    const executable_path = if (builtin.os.tag == .windows)
        try std.fs.path.join(allocator, &.{ target_cache_dir, "bin", "protoc.exe" })
    else
        try std.fs.path.join(allocator, &.{ target_cache_dir, "bin", "protoc" });

    if (fileExists(executable_path)) {
        return executable_path; // nothing to do, already have the binary
    }

    downloadProtoc(allocator, target_cache_dir, protoc_version) catch |err| {
        // A download failed, or extraction failed, so wipe out the directory to ensure we correctly
        // try again next time.
        // std.fs.deleteTreeAbsolute(base_cache_dir) catch {};
        std.log.err("zig-protobuf: download protoc failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    if (!fileExists(executable_path)) {
        std.log.err("zig-protobuf: file not found: {s}", .{executable_path});
        std.process.exit(1);
    }

    return executable_path;
}

/// Compose the download URL, e.g.:
/// https://github.com/protocolbuffers/protobuf/releases/download/v24.3/protoc-24.3-linux-aarch_64.zip
fn getProtocDownloadLink(allocator: std.mem.Allocator, version: []const u8) !?[]const u8 {
    const github_base_url = try getGitHubBaseURLOwned(allocator);
    defer allocator.free(github_base_url);

    const os: ?[]const u8 = switch (builtin.os.tag) {
        .macos => "osx",
        .linux => "linux",
        else => null,
    };

    const arch: ?[]const u8 = switch (builtin.cpu.arch) {
        .powerpcle, .powerpc64le => "ppcle",
        .aarch64, .aarch64_be => "aarch_64",
        .s390x => "s390",
        .x86_64 => "x86_64",
        .x86 => "x86_32",
        else => null,
    };

    const asset = if (builtin.os.tag == .windows)
        try std.mem.concat(allocator, u8, &.{ "protoc-", version, "-win64.zip" })
    else if (os != null and arch != null)
        try std.mem.concat(allocator, u8, &.{ "protoc-", version, "-", os.?, "-", arch.?, ".zip" })
    else
        return null;
    defer allocator.free(asset);

    return try std.mem.concat(allocator, u8, &.{
        github_base_url,
        "/protocolbuffers/protobuf/releases/download/v",
        version,
        "/",
        asset,
    });
}

fn downloadProtoc(
    allocator: std.mem.Allocator,
    target_cache_dir: []const u8,
    protoc_version: []const u8,
) !void {
    download_mutex.lock();
    defer download_mutex.unlock();

    ensureCanDownloadFiles(allocator);
    ensureCanUnzipFiles(allocator);

    const download_dir = try std.fs.path.join(allocator, &.{ target_cache_dir, "download" });
    defer allocator.free(download_dir);
    std.fs.cwd().makePath(download_dir) catch @panic(download_dir);
    std.debug.print("download_dir: {s}\n", .{download_dir});

    // Replace "..." with "---" because GitHub releases has very weird restrictions on file names.
    // https://twitter.com/slimsag/status/1498025997987315713

    const download_url = try getProtocDownloadLink(allocator, protoc_version);

    if (download_url == null) {
        std.log.err("zig-protobuf: cannot resolve a protoc version to download. make sure the architecture you are using is supported", .{});
        std.process.exit(1);
    }

    defer allocator.free(download_url.?);

    // Download protoc
    const zip_target_file = try std.fs.path.join(allocator, &.{ download_dir, "protoc.zip" });
    defer allocator.free(zip_target_file);
    downloadFile(allocator, zip_target_file, download_url.?) catch @panic(zip_target_file);

    // Decompress the .zip file
    unzipFile(allocator, zip_target_file, target_cache_dir) catch @panic(zip_target_file);

    try std.fs.deleteTreeAbsolute(download_dir);
}

fn dirExists(path: []const u8) bool {
    var dir = std.fs.openDirAbsolute(path, .{}) catch return false;
    dir.close();
    return true;
}

fn fileExists(path: []const u8) bool {
    var file = std.fs.openFileAbsolute(path, .{}) catch return false;
    file.close();
    return true;
}

fn isEnvVarTruthy(allocator: std.mem.Allocator, name: []const u8) bool {
    if (std.process.getEnvVarOwned(allocator, name)) |truthy| {
        defer allocator.free(truthy);
        if (std.mem.eql(u8, truthy, "true")) return true;
        return false;
    } else |_| {
        return false;
    }
}

fn downloadFile(allocator: std.mem.Allocator, target_file: []const u8, url: []const u8) !void {
    std.debug.print("downloading {s}..\n", .{url});

    // Some Windows users experience `SSL certificate problem: unable to get local issuer certificate`
    // so we give them the option to disable SSL if they desire / don't want to debug the issue.
    var child = if (isEnvVarTruthy(allocator, "CURL_INSECURE"))
        std.process.Child.init(&.{ "curl", "--insecure", "-L", "-o", target_file, url }, allocator)
    else
        std.process.Child.init(&.{ "curl", "-L", "-o", target_file, url }, allocator);
    child.cwd = sdkPath("/");
    child.stderr = std.io.getStdErr();
    child.stdout = std.io.getStdOut();
    _ = try child.spawnAndWait();
}

fn unzipFile(allocator: std.mem.Allocator, file: []const u8, target_directory: []const u8) !void {
    var child = switch (builtin.os.tag) {
        .windows => std.process.Child.init(
            &.{ "powershell", "-Command", "Microsoft.PowerShell.Archive\\Expand-Archive -Force -Path", file, "-DestinationPath", target_directory },
            allocator,
        ),
        else => std.process.Child.init(
            &.{ "unzip", "-o", file, "-d", target_directory },
            allocator,
        ),
    };
    child.cwd = sdkPath("/");
    child.stderr = std.io.getStdErr();
    child.stdout = std.io.getStdOut();
    _ = try child.spawnAndWait();
}

fn ensureCanDownloadFiles(allocator: std.mem.Allocator) void {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "curl", "--version" },
        .cwd = sdkPath("/"),
    }) catch { // e.g. FileNotFound
        std.log.err("zig-protobuf: error: 'curl --version' failed. Is curl not installed?", .{});
        std.process.exit(1);
    };
    defer {
        allocator.free(result.stderr);
        allocator.free(result.stdout);
    }
    if (result.term.Exited != 0) {
        std.log.err("zig-protobuf: error: 'curl --version' failed. Is curl not installed?", .{});
        std.process.exit(1);
    }
}

fn ensureCanUnzipFiles(allocator: std.mem.Allocator) void {
    switch (builtin.os.tag) {
        .windows => {},
        else => {
            const result = std.process.Child.run(.{
                .allocator = allocator,
                .argv = &.{"unzip"},
                .cwd = sdkPath("/"),
            }) catch { // e.g. FileNotFound
                std.log.err("zig-protobuf: error: 'unzip' failed. Is unzip not installed?", .{});
                std.process.exit(1);
            };
            defer {
                allocator.free(result.stderr);
                allocator.free(result.stdout);
            }
            if (result.term.Exited != 0) {
                std.log.err("zig-protobuf: error: 'unzip' failed. Is unzip not installed?", .{});
                std.process.exit(1);
            }
        },
    }
}

fn sdkPath(comptime suffix: []const u8) []const u8 {
    if (suffix[0] != '/') @compileError("suffix must be an absolute path");
    return comptime blk: {
        const root_dir = std.fs.path.dirname(@src().file) orelse ".";
        break :blk root_dir ++ suffix;
    };
}
