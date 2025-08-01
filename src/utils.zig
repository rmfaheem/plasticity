const std = @import("std");

pub fn parseJson(comptime T: type, allocator: std.mem.Allocator, json_str: []const u8) !std.json.Parsed(T) {
    return try std.json.parseFromSlice(T, allocator, json_str, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}

pub fn stringifyJson(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var string = std.ArrayList(u8).init(allocator);
    try std.json.stringify(value, .{}, string.writer());
    return string.toOwnedSlice();
}

pub fn getCurrentTimestamp() i64 {
    return std.time.timestamp();
}