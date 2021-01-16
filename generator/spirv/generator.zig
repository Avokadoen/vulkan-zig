const std = @import("std");
const reg = @import("registry.zig");
const render = @import("render.zig");
const Allocator = std.mem.Allocator;

fn getEnumerantValue(enumerant: *const reg.Enumerant) !u31 {
    return switch (enumerant.value) {
        .bitflag => |str| try render.parseHex(str),
        .int => |int| int
    };
}

/// The spir-v registries contain many enums which have aliased fields - mostly extensions
/// that got lifted to core. As generating these aliases would result in sufficiently
/// different usage in generated Zig code (eg, using a fully qualified enum variant instead
/// of an enum literal, and bit fields cannot have an alias generated at all) that the
/// backwards compatibility part it is intended for is useless anyway, it might as well
/// be removed. This also clears up some rendering code.
fn removeAliasedEnumerants(allocator: *Allocator, operand_kinds: []reg.OperandKind) !void {
    var non_aliased_enumerants = std.AutoHashMap(u32, []const u8).init(allocator);
    defer non_aliased_enumerants.deinit();

    for (operand_kinds) |*operand_kind| {
        var enumerants = operand_kind.enumerants orelse continue;

        non_aliased_enumerants.clearRetainingCapacity();
        for (enumerants) |enumerant| {
            const value = try getEnumerantValue(&enumerant);
            const result = try non_aliased_enumerants.getOrPut(value);

            // If a hit was found, keep the one with the shortest length. This is likely
            // to not contain any tag, and should be the easiest to type in general if
            // those kinds of aliases even exist.
            if (!result.found_existing and enumerant.enumerant.len < result.entry.value.len) {
                result.entry.value = enumerant.enumerant;
            }
        }

        var write_index: usize = 0;
        for (enumerants) |enumerant| {
            const value = try getEnumerantValue(&enumerant);
            const base_enumerant = non_aliased_enumerants.get(value).?;
            const is_alias = !std.mem.eql(u8, enumerant.enumerant, base_enumerant);
            if (is_alias) {
                continue;
            }

            enumerants[write_index] = enumerant;
            write_index += 1;
        }

        operand_kind.enumerants = enumerants[0 .. write_index];
    }
}

pub fn generateCore(allocator: *Allocator, spec_json: []const u8, writer: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var tokens = std.json.TokenStream.init(spec_json);
    var registry = try std.json.parse(reg.CoreRegistry, &tokens, .{.allocator = &arena.allocator});

    try removeAliasedEnumerants(&arena.allocator, registry.operand_kinds);
    try render.renderCore(writer, &arena.allocator, &registry);
}

pub fn generateExtinst(allocator: *Allocator, exstinst_json: []const u8, writer: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var tokens = std.json.TokenStream.init(exstinst_json);
    var registry = try std.json.parse(reg.ExtensionRegistry, &tokens, .{.allocator = &arena.allocator});

    try removeAliasedEnumerants(&arena.allocator, registry.operand_kinds);
    try render.renderExstinst(writer, &arena.allocator, &registry);
}
