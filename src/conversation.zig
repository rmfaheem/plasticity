const std = @import("std");

pub const Role = enum { user, assistant };

pub const ConversationTurn = struct {
    id: []const u8,
    session_id: []const u8,
    turn_number: u32 = 0,
    timestamp: i64,
    role: Role = .user,
    user_message: ?[]const u8 = null,
    assistant_message: ?[]const u8 = null,
    content: ?[]const u8 = null,
    tags: ?[][]const u8 = null,
    importance_score: f32 = 0.5,
    metadata: ?std.json.Value = null,

    pub fn deinit(self: *const ConversationTurn, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.session_id);
        if (self.user_message) |m| allocator.free(m);
        if (self.assistant_message) |m| allocator.free(m);
        if (self.content) |c| allocator.free(c);
        if (self.tags) |ts| {
            for (ts) |t| allocator.free(t);
            allocator.free(ts);
        }
        if (self.metadata) |*meta| {
            // Free json.Value recursively where needed (only strings/objects used in this project)
            deinitJsonValue(meta, allocator);
        }
    }
};

fn deinitJsonValue(value: *std.json.Value, allocator: std.mem.Allocator) void {
    switch (value.*) {
        .string => |
        s| allocator.free(s),
        .array => |*arr| {
            for (arr.items) |*item| deinitJsonValue(item, allocator);
            arr.deinit();
        },
        .object => |*obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                var v = entry.value_ptr.*;
                deinitJsonValue(&v, allocator);
            }
            obj.deinit();
        },
        else => {},
    }
}

pub const TimeRange = struct { start: i64, end: i64 };

pub const RecallOptions = struct {
    max_results: usize = 10,
    similarity_threshold: f32 = 0.7,
    time_range: ?TimeRange = null,
    session_filter: ?[]const u8 = null,
    importance_threshold: f32 = 0.0,
    tags: ?[][]const u8 = null,
};

pub const MemoryError = error{ NotImplemented };

pub const MemoryInterface = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MemoryInterface {
        return .{ .allocator = allocator };
    }

    pub fn saveConversation(self: *MemoryInterface, turn: ConversationTurn) ![]const u8 {
        _ = self;
        _ = turn;
        return MemoryError.NotImplemented;
    }

    pub fn recallConversations(self: *MemoryInterface, query: []const u8, options: RecallOptions) ![]ConversationTurn {
        _ = self;
        _ = query;
        _ = options;
        return MemoryError.NotImplemented;
    }

    pub fn getRelatedMemories(self: *MemoryInterface, current_context: []const u8, limit: usize) ![]ConversationTurn {
        _ = self;
        _ = current_context;
        _ = limit;
        return MemoryError.NotImplemented;
    }
};
