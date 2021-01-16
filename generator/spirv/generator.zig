const std = @import("std");
const reg = @import("registry.zig");
const render = @import("render.zig");
const Allocator = std.mem.Allocator;

pub fn generateCore(allocator: *Allocator, spec_json: []const u8, writer: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var tokens = std.json.TokenStream.init(spec_json);
    var registry = try std.json.parse(reg.CoreRegistry, &tokens, .{.allocator = &arena.allocator});

    try render.renderCore(writer, &arena.allocator, &registry);
}

pub fn generateExtinst(allocator: *Allocator, exstinst_json: []const u8, writer: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var tokens = std.json.TokenStream.init(exstinst_json);
    var registry = try std.json.parse(reg.ExtensionRegistry, &tokens, .{.allocator = &arena.allocator});

    try render.renderExstinst(writer, &arena.allocator, &registry);
}
