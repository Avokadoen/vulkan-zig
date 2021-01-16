const std = @import("std");
const reg = @import("registry.zig");
const mem = std.mem;
const IdRenderer = @import("../id_render.zig").IdRenderer;
const Allocator = std.mem.Allocator;

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
        non_aliased_enum_cache: std.AutoHashMap(u32, []const u8),

        fn init(allocator: *Allocator, writer: WriterType) Self {
            return .{
                .writer = writer,
                .id_renderer = IdRenderer.init(allocator, &tags),
                .non_aliased_enum_cache = std.AutoHashMap(u32, []const u8).init(allocator),
            };
        }

        fn deinit(self: *Self) void {
            self.non_aliased_enum_cache.deinit();
            self.id_renderer.deinit();
        }

        fn renderCore(self: *Self, registry: *const reg.CoreRegistry) !void {
            try self.renderCopyright(registry.copyright);
            try self.renderOpcodes(registry.instructions, true);
            try self.renderOperandKinds(registry.operand_kinds);
        }

        fn renderExstinst(self: *Self, registry: *const reg.ExtensionRegistry) !void {
            try self.renderCopyright(registry.copyright);
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

        // Fills self.non_aliased_enum_cache
        fn extractNonAliasedEnumerants(self: *Self, enumerants: []const reg.Enumerant) !void {
            self.non_aliased_enum_cache.clearRetainingCapacity();
            for (enumerants) |enumerant| {
                const value = try getEnumerantValue(&enumerant);
                const result = try self.non_aliased_enum_cache.getOrPut(value);

                // If a hit was found, keep the one with the shortest length. This is likely
                // to not contain any tag, and should be the easiest to type in general if
                // those kinds of aliases even exist.
                if (!result.found_existing and enumerant.enumerant.len < result.entry.value.len) {
                    result.entry.value = enumerant.enumerant;
                }
            }
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
