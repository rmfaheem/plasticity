const std = @import("std");

pub const ExtractionItem = struct {
    kind: []const u8, // "preference" | "decision" | "fact" | "task"
    value: []const u8,
    score: f32,
};

pub const ExtractionResult = struct {
    tags: [][]const u8,
    importance_score: f32,
    items: []ExtractionItem,

    pub fn deinit(self: *const ExtractionResult, allocator: std.mem.Allocator) void {
        for (self.tags) |t| allocator.free(t);
        allocator.free(self.tags);
        for (self.items) |item| {
            allocator.free(item.kind);
            allocator.free(item.value);
        }
        allocator.free(self.items);
    }
};

pub fn extractFromText(allocator: std.mem.Allocator, text: []const u8) !ExtractionResult {
    // Baseline heuristics
    var importance: f32 = 0.5;

    const lower = try toLower(allocator, text);
    defer allocator.free(lower);

    if (std.mem.indexOf(u8, lower, "prefer") != null) importance += 0.2;
    if (std.mem.indexOf(u8, lower, "decision") != null) importance += 0.2;
    if (std.mem.indexOf(u8, lower, "urgent") != null) importance += 0.1;
    if (importance > 1.0) importance = 1.0;

    // Build tags: pick distinct words with length >= 4, limit 6
    var tag_set = std.StringHashMap(void).init(allocator);
    defer tag_set.deinit();

    var it = std.mem.tokenizeAny(u8, lower, " \n\t.,;:!?()[]{}\"'`");
    while (it.next()) |tok| {
        if (tok.len >= 4 and isAlphaNum(tok)) {
            _ = try tag_set.put(tok, {});
            if (tag_set.count() >= 6) break;
        }
    }

    var tags = try allocator.alloc([]const u8, tag_set.count());
    {
        var i: usize = 0;
        var iter = tag_set.iterator();
        while (iter.next()) |entry| : (i += 1) {
            tags[i] = try allocator.dupe(u8, entry.key_ptr.*);
        }
    }

    // Items: simple signals
    var items_list = std.ArrayList(ExtractionItem).init(allocator);
    defer items_list.deinit();

    if (std.mem.indexOf(u8, lower, "prefer") != null) {
        try items_list.append(.{
            .kind = try allocator.dupe(u8, "preference"),
            .value = try allocator.dupe(u8, text),
            .score = 0.8,
        });
    }
    if (std.mem.indexOf(u8, lower, "decide") != null or std.mem.indexOf(u8, lower, "decision") != null) {
        try items_list.append(.{
            .kind = try allocator.dupe(u8, "decision"),
            .value = try allocator.dupe(u8, text),
            .score = 0.7,
        });
    }
    if (std.mem.indexOf(u8, lower, "todo") != null or std.mem.indexOf(u8, lower, "task") != null) {
        try items_list.append(.{
            .kind = try allocator.dupe(u8, "task"),
            .value = try allocator.dupe(u8, text),
            .score = 0.6,
        });
    }

    const items = try items_list.toOwnedSlice();

    return ExtractionResult{
        .tags = tags,
        .importance_score = importance,
        .items = items,
    };
}

fn toLower(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var buf = try allocator.alloc(u8, text.len);
    for (text, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf;
}

fn isAlphaNum(s: []const u8) bool {
    for (s) |c| if (!(isAsciiAlphaNum(c) or c == '_' or c == '-')) return false;
    return true;
}

fn isAsciiAlphaNum(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9');
}
