const std = @import("std");
const reg = @import("registry.zig");
const mem = std.mem;
const IdRenderer = @import("../id_render.zig").IdRenderer;
const Allocator = std.mem.Allocator;

const preamble =
    \\const Version = @import("builtin").Version;
    \\
    ;

// The SPIR-V spec doesn't contain any tag information like vulkan.xml does,
// so the tags are just hardcoded. They are retrieved from
// https://github.com/KhronosGroup/SPIRV-Registry/tree/master/extensions
// TODO: Automate checking whether these are still correct?
const tags = [_][]const u8{
    "AMD",
    "EXT",
    "GOOGLE",
    "INTEL",
    "KHR",
    "NV",
};

fn getEnumerantValue(enumerant: *const reg.Enumerant) !u31 {
    return switch (enumerant.value) {
        .bitflag => |str| try parseHexInt(str),
        .int => |int| int
    };
}

fn parseHexInt(text: []const u8) !u31 {
    const prefix = "0x";
    if (!mem.startsWith(u8, text, prefix))
        return error.InvalidHexInt;
    return try std.fmt.parseInt(u31, text[prefix.len ..], 16);
}

fn Renderer(comptime WriterType: type) type {
    return struct {
        const Self = @This();

        writer: WriterType,
        id_renderer: IdRenderer,

        fn init(allocator: *Allocator, writer: WriterType) Self {
            return .{
                .writer = writer,
                .id_renderer = IdRenderer.init(allocator, &tags),
            };
        }

        fn deinit(self: Self) void {
            self.id_renderer.deinit();
        }

        fn renderCore(self: *Self, registry: *const reg.CoreRegistry) !void {
            try self.renderCopyright(registry.copyright);
            try self.writer.writeAll(preamble);
            try self.writer.print("pub const magic_number: u32 = {s};\n", .{ registry.magic_number });
            try self.writer.print(
                "pub const version = Version{{.major = {}, .minor = {}, .patch = {}}};\n",
                .{ registry.major_version, registry.minor_version, registry.revision },
            );
            try self.renderOpcodes(registry.instructions, true);
            try self.renderOperandKinds(registry.operand_kinds);
        }

        fn renderExstinst(self: *Self, registry: *const reg.ExtensionRegistry) !void {
            try self.renderCopyright(registry.copyright);
            try self.writer.writeAll(preamble);
            try self.writer.print(
                "pub const version = Version{{.major = {}, .minor = 0, .patch = {}}};\n",
                .{ registry.version, registry.revision },
            );
            try self.renderOpcodes(registry.instructions, false);
            try self.renderOperandKinds(registry.operand_kinds);
        }

        fn renderCopyright(self: *Self, copyright: []const []const u8) !void {
            for (copyright) |line| {
                try self.writer.print("// {s}\n", .{ line });
            }
        }

        fn renderOpcodes(self: *Self, instructions: []const reg.Instruction, is_core: bool) !void {
            try self.writer.writeAll("pub const Opcode = enum(u16) {\n");
            for (instructions) |instr| {
                const opname = if (is_core) blk: {
                    const prefix = "Op";
                    if (!mem.startsWith(u8, instr.opname, prefix)) return error.InvalidRegistry;
                    break :blk instr.opname[prefix.len ..];
                } else instr.opname;

                try self.id_renderer.renderWithCase(self.writer, .snake, opname);
                try self.writer.print(" = {},\n", .{ instr.opcode });
            }
            try self.writer.writeAll("};\n");
        }

        fn renderOperandKinds(self: *Self, operand_kinds: []const reg.OperandKind) !void {
            for (operand_kinds) |*kind| {
                try self.renderOperandKind(kind);
            }
        }

        fn renderOperandKind(self: *Self, operand_kind: *const reg.OperandKind) !void {
            switch (operand_kind.category) {
                .ValueEnum => try self.renderValueEnum(operand_kind),
                .BitEnum => try self.renderBitEnum(operand_kind),
                else => {},
            }
        }

        fn renderValueEnum(self: *Self, enumeration: *const reg.OperandKind) !void {
            try self.writer.writeAll("pub const ");
            try self.id_renderer.renderWithCase(self.writer, .title, enumeration.kind);
            try self.writer.writeAll(" = extern enum(u32) {\n");

            const enumerants = enumeration.enumerants orelse return error.InvalidRegistry;
            for (enumerants) |enumerant| {
                if (enumerant.value != .int) return error.InvalidRegistry;

                try self.id_renderer.renderWithCase(self.writer, .snake, enumerant.enumerant);
                try self.writer.print(" = {}, ", .{ enumerant.value.int });
            }

            try self.writer.writeAll("_,};\n");
        }

        fn renderBitEnum(self: *Self, enumeration: *const reg.OperandKind) !void {
            try self.writer.writeAll("pub const ");
            try self.id_renderer.renderWithCase(self.writer, .title, enumeration.kind);
            try self.writer.writeAll(" = packed struct {\n");

            var flags_by_bitpos = [_]?[]const u8{null} ** 32;
            const enumerants = enumeration.enumerants orelse return error.InvalidRegistry;
            for (enumerants) |enumerant| {
                if (enumerant.value != .bitflag) return error.InvalidRegistry;
                const value = try parseHexInt(enumerant.value.bitflag);
                if (@popCount(u32, value) != 1) {
                    continue; // Skip combinations and 'none' items
                }

                var bitpos = std.math.log2_int(u32, value);
                if (flags_by_bitpos[bitpos]) |*existing|{
                    // Keep the shortest
                    if (enumerant.enumerant.len < existing.len)
                        existing.* = enumerant.enumerant;
                } else {
                    flags_by_bitpos[bitpos] = enumerant.enumerant;
                }
            }

            for (flags_by_bitpos) |maybe_flag_name, bitpos| {
                if (maybe_flag_name) |flag_name| {
                    try self.id_renderer.renderWithCase(self.writer, .snake, flag_name);
                } else {
                    try self.writer.print("_reserved_bit_{}", .{bitpos});
                }

                try self.writer.writeAll(": bool ");
                if (bitpos == 0) { // Force alignment to integer boundaries
                    try self.writer.writeAll("align(@alignOf(u32)) ");
                }
                try self.writer.writeAll("= false, ");
            }

            try self.writer.writeAll("};\n");
        }
    };
}

pub fn renderCore(writer: anytype, allocator: *Allocator, registry: *const reg.CoreRegistry) !void {
    var renderer = Renderer(@TypeOf(writer)).init(allocator, writer);
    defer renderer.deinit();
    try renderer.renderCore(registry);
}

pub fn renderExstinst(writer: anytype, allocator: *Allocator, registry: *const reg.ExtensionRegistry) !void {
    var renderer = Renderer(@TypeOf(writer)).init(allocator, writer);
    defer renderer.deinit();
    try renderer.renderExstinst(registry);
}
