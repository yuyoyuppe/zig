const std = @import("../std.zig");
const Step = std.Build.Step;
const CompileStep = std.Build.CompileStep;
const CheckFileStep = std.Build.CheckFileStep;
const fs = std.fs;
const mem = std.mem;
const CrossTarget = std.zig.CrossTarget;

const TranslateCStep = @This();

pub const base_id = .translate_c;

step: Step,
builder: *std.Build,
source: std.Build.FileSource,
include_dirs: std.ArrayList([]const u8),
c_macros: std.ArrayList([]const u8),
output_dir: ?[]const u8,
out_basename: []const u8,
target: CrossTarget,
optimize: std.builtin.OptimizeMode,
output_file: std.Build.GeneratedFile,

pub const Options = struct {
    source_file: std.Build.FileSource,
    target: CrossTarget,
    optimize: std.builtin.OptimizeMode,
};

pub fn create(builder: *std.Build, options: Options) *TranslateCStep {
    const self = builder.allocator.create(TranslateCStep) catch @panic("OOM");
    const source = options.source_file.dupe(builder);
    self.* = TranslateCStep{
        .step = Step.init(.translate_c, "translate-c", builder.allocator, make),
        .builder = builder,
        .source = source,
        .include_dirs = std.ArrayList([]const u8).init(builder.allocator),
        .c_macros = std.ArrayList([]const u8).init(builder.allocator),
        .output_dir = null,
        .out_basename = undefined,
        .target = options.target,
        .optimize = options.optimize,
        .output_file = std.Build.GeneratedFile{ .step = &self.step },
    };
    source.addStepDependencies(&self.step);
    return self;
}

pub const AddExecutableOptions = struct {
    name: ?[]const u8 = null,
    version: ?std.builtin.Version = null,
    target: ?CrossTarget = null,
    optimize: ?std.builtin.Mode = null,
    linkage: ?CompileStep.Linkage = null,
};

/// Creates a step to build an executable from the translated source.
pub fn addExecutable(self: *TranslateCStep, options: AddExecutableOptions) *CompileStep {
    return self.builder.addExecutable(.{
        .root_source_file = .{ .generated = &self.output_file },
        .name = options.name orelse "translated_c",
        .version = options.version,
        .target = options.target orelse self.target,
        .optimize = options.optimize orelse self.optimize,
        .linkage = options.linkage,
    });
}

pub fn addIncludeDir(self: *TranslateCStep, include_dir: []const u8) void {
    self.include_dirs.append(self.builder.dupePath(include_dir)) catch @panic("OOM");
}

pub fn addCheckFile(self: *TranslateCStep, expected_matches: []const []const u8) *CheckFileStep {
    return CheckFileStep.create(self.builder, .{ .generated = &self.output_file }, self.builder.dupeStrings(expected_matches));
}

/// If the value is omitted, it is set to 1.
/// `name` and `value` need not live longer than the function call.
pub fn defineCMacro(self: *TranslateCStep, name: []const u8, value: ?[]const u8) void {
    const macro = std.Build.constructCMacro(self.builder.allocator, name, value);
    self.c_macros.append(macro) catch @panic("OOM");
}

/// name_and_value looks like [name]=[value]. If the value is omitted, it is set to 1.
pub fn defineCMacroRaw(self: *TranslateCStep, name_and_value: []const u8) void {
    self.c_macros.append(self.builder.dupe(name_and_value)) catch @panic("OOM");
}

fn make(step: *Step) !void {
    const self = @fieldParentPtr(TranslateCStep, "step", step);

    var argv_list = std.ArrayList([]const u8).init(self.builder.allocator);
    try argv_list.append(self.builder.zig_exe);
    try argv_list.append("translate-c");
    try argv_list.append("-lc");

    try argv_list.append("--enable-cache");

    if (!self.target.isNative()) {
        try argv_list.append("-target");
        try argv_list.append(try self.target.zigTriple(self.builder.allocator));
    }

    switch (self.optimize) {
        .Debug => {}, // Skip since it's the default.
        else => try argv_list.append(self.builder.fmt("-O{s}", .{@tagName(self.optimize)})),
    }

    for (self.include_dirs.items) |include_dir| {
        try argv_list.append("-I");
        try argv_list.append(include_dir);
    }

    for (self.c_macros.items) |c_macro| {
        try argv_list.append("-D");
        try argv_list.append(c_macro);
    }

    try argv_list.append(self.source.getPath(self.builder));

    const output_path_nl = try self.builder.execFromStep(argv_list.items, &self.step);
    const output_path = mem.trimRight(u8, output_path_nl, "\r\n");

    self.out_basename = fs.path.basename(output_path);
    if (self.output_dir) |output_dir| {
        const full_dest = try fs.path.join(self.builder.allocator, &[_][]const u8{ output_dir, self.out_basename });
        try self.builder.updateFile(output_path, full_dest);
    } else {
        self.output_dir = fs.path.dirname(output_path).?;
    }

    self.output_file.path = try fs.path.join(
        self.builder.allocator,
        &[_][]const u8{ self.output_dir.?, self.out_basename },
    );
}
