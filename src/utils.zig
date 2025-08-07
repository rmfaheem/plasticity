const std = @import("std");

pub fn parseJson(comptime T: type, allocator: std.mem.Allocator, json_str: []const u8) !std.json.Parsed(T) {
    std.log.info("parseJson: Starting to parse JSON for type {s}", .{@typeName(T)});
    std.log.info("parseJson: JSON string length: {d}", .{json_str.len});
    std.log.info("parseJson: JSON string: {s}", .{json_str});

    const result = std.json.parseFromSlice(T, allocator, json_str, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.log.err("parseJson: Failed to parse JSON for type {s}: {any}", .{ @typeName(T), err });
        std.log.err("parseJson: JSON string was: {s}", .{json_str});
        return err;
    };

    std.log.info("parseJson: Successfully parsed JSON for type {s}", .{@typeName(T)});
    return result;
}

pub fn stringifyJson(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var string = std.ArrayList(u8).init(allocator);
    try std.json.stringify(value, .{}, string.writer());
    return string.toOwnedSlice();
}

pub fn getCurrentTimestamp() i64 {
    return std.time.timestamp();
}
