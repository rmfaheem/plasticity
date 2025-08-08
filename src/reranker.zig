const std = @import("std");
const arango = @import("arango.zig");
const config = @import("config.zig");

pub const TimeRange = struct {
    start: i64,
    end: i64,
};

pub const ContextType = enum {
    preference,
    decision,
    observation,
};

pub const SearchQuery = struct {
    vector: []const f32,
    limit: ?u32 = null,
    time_range: ?TimeRange = null,
    topic_id: ?[]const u8 = null,
    source_node_id: ?[]const u8 = null,
    user_id: ?[]const u8 = null,
    context_types: ?[]const ContextType = null,
    session_id: ?[]const u8 = null,
    tags: ?[][]const u8 = null,

    pub fn deinit(self: *const SearchQuery, allocator: std.mem.Allocator) void {
        allocator.free(self.vector);
        if (self.topic_id) |topic| {
            allocator.free(topic);
        }
        if (self.source_node_id) |node| {
            allocator.free(node);
        }
        if (self.user_id) |user| allocator.free(user);
        if (self.context_types) |types| allocator.free(types);
        if (self.session_id) |sid| allocator.free(sid);
        if (self.tags) |ts| {
            for (ts) |t| allocator.free(t);
            allocator.free(ts);
        }
    }
};

pub const VectorResult = struct {
    id: []const u8,
    score: f32,
    timestamp: i64,
    content: ?[]const u8 = null,
    importance: f32 = 0.0,
    behavior: f32 = 0.0,

    pub fn deinit(self: *const VectorResult, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        if (self.content) |content| {
            allocator.free(content);
        }
    }
};

pub const SearchResult = struct {
    id: []const u8,
    score: f32,
    timestamp: i64,
    content: ?[]const u8 = null,
    graph_neighbors: [][]const u8,
    similarity_score: f32,
    recency_score: f32,
    graph_score: f32,
    importance_score: f32,
    behavior_score: f32,

    pub fn deinit(self: *const SearchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        if (self.content) |content| {
            allocator.free(content);
        }
        for (self.graph_neighbors) |neighbor| {
            allocator.free(neighbor);
        }
        allocator.free(self.graph_neighbors);
    }
};

pub fn deinitMetadata(metadata: *const std.StringHashMap([]const u8), allocator: std.mem.Allocator) void {
    var it = metadata.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    // Cast away const for deinit
    @as(*std.StringHashMap([]const u8), @ptrFromInt(@intFromPtr(metadata))).deinit();
}

pub const Document = struct {
    id: []const u8,
    vector: []const f32,
    timestamp: i64,
    content: ?[]const u8 = null,
    topic_id: ?[]const u8 = null,
    related_documents: ?[][]const u8 = null,
    user_id: ?[]const u8 = null,
    context_type: ?ContextType = null,
    metadata: ?std.StringHashMap([]const u8) = null,
    // Conversation-specific (optional)
    session_id: ?[]const u8 = null,
    turn_number: ?u32 = null,
    role: ?[]const u8 = null,
    importance_score: ?f32 = null,
    tags: ?[][]const u8 = null,

    pub fn deinit(self: *const Document, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.vector);
        if (self.content) |content| {
            allocator.free(content);
        }
        if (self.topic_id) |topic| {
            allocator.free(topic);
        }
        if (self.related_documents) |related| {
            for (related) |doc| {
                allocator.free(doc);
            }
            allocator.free(related);
        }
        if (self.user_id) |user| allocator.free(user);
        if (self.metadata) |*meta| {
            deinitMetadata(meta, allocator);
        }
        if (self.session_id) |sid| allocator.free(sid);
        if (self.role) |r| allocator.free(r);
        if (self.tags) |ts| {
            for (ts) |t| allocator.free(t);
            allocator.free(ts);
        }
    }

    pub fn fromJson(allocator: std.mem.Allocator, json_doc: DocumentJson) !Document {
        var metadata: ?std.StringHashMap([]const u8) = null;
        if (json_doc.metadata) |json_meta| {
            metadata = std.StringHashMap([]const u8).init(allocator);
            if (json_meta == .object) {
                var it = json_meta.object.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.* == .string) {
                        try metadata.?.put(try allocator.dupe(u8, entry.key_ptr.*), try allocator.dupe(u8, entry.value_ptr.*.string));
                    }
                }
            }
        }

        return Document{
            .id = try allocator.dupe(u8, json_doc.id),
            .vector = try allocator.dupe(f32, json_doc.vector),
            .timestamp = json_doc.timestamp,
            .content = if (json_doc.content) |content| try allocator.dupe(u8, content) else null,
            .topic_id = if (json_doc.topic_id) |topic| try allocator.dupe(u8, topic) else null,
            .related_documents = if (json_doc.related_documents) |related| blk: {
                var docs = try allocator.alloc([]const u8, related.len);
                for (related, 0..) |doc, i| {
                    docs[i] = try allocator.dupe(u8, doc);
                }
                break :blk docs;
            } else null,
            .user_id = if (json_doc.user_id) |user| try allocator.dupe(u8, user) else null,
            .context_type = json_doc.context_type,
            .metadata = metadata,
            .session_id = null,
            .turn_number = null,
            .role = null,
            .importance_score = null,
            .tags = null,
        };
    }
};

// JSON-compatible version of Document for parsing
pub const DocumentJson = struct {
    id: []const u8,
    vector: []const f32,
    timestamp: i64,
    content: ?[]const u8 = null,
    topic_id: ?[]const u8 = null,
    related_documents: ?[][]const u8 = null,
    user_id: ?[]const u8 = null,
    context_type: ?ContextType = null,
    metadata: ?std.json.Value = null,
};

pub fn rerank(
    allocator: std.mem.Allocator,
    vector_results: []const VectorResult,
    graph_contexts: *const std.HashMap([]const u8, arango.GraphContext, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    app_config: config.Config,
) ![]SearchResult {
    const current_time = std.time.timestamp();
    var scored_results = try allocator.alloc(SearchResult, vector_results.len);

    for (vector_results, 0..) |result, i| {
        const graph_context = graph_contexts.get(result.id) orelse arango.GraphContext{
            .neighbors = &[_][]const u8{},
            .weights = &[_]f32{},
            .topics = &[_][]const u8{},
        };

        // Calculate scores
        const similarity_score = result.score;
        const age_seconds = @as(f32, @floatFromInt(current_time - result.timestamp));
        const recency_score = if (age_seconds < @as(f32, @floatFromInt(app_config.persistent_memory.retention_period)) * 86400.0)
            1.0 / (1.0 + app_config.ranking.recency_decay_factor * age_seconds / 86400.0)
        else
            0.0;

        var graph_score: f32 = 0.0;
        if (graph_context.weights.len > 0) {
            var total_weight: f32 = 0.0;
            for (graph_context.weights) |weight| total_weight += weight;
            graph_score = total_weight / @as(f32, @floatFromInt(graph_context.weights.len));
        }

        const final_score = app_config.ranking.similarity_weight * similarity_score +
            app_config.ranking.recency_weight * recency_score +
            app_config.ranking.graph_weight * graph_score +
            app_config.ranking.importance_weight * result.importance +
            app_config.ranking.behavior_weight * result.behavior;

        var neighbors = try allocator.alloc([]const u8, graph_context.neighbors.len);
        for (graph_context.neighbors, 0..) |neighbor, j| {
            neighbors[j] = try allocator.dupe(u8, neighbor);
        }

        scored_results[i] = SearchResult{
            .id = try allocator.dupe(u8, result.id),
            .score = final_score,
            .timestamp = result.timestamp,
            .content = if (result.content) |content| try allocator.dupe(u8, content) else null,
            .graph_neighbors = neighbors,
            .similarity_score = similarity_score,
            .recency_score = recency_score,
            .graph_score = graph_score,
            .importance_score = result.importance,
            .behavior_score = result.behavior,
        };
    }

    std.sort.insertion(SearchResult, scored_results, {}, compareSearchResults);
    return scored_results;
}

fn compareSearchResults(_: void, a: SearchResult, b: SearchResult) bool {
    return a.score > b.score;
}

test "rerank importance affects order" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx_map = std.HashMap([]const u8, arango.GraphContext, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator);
    defer {
        var it = ctx_map.iterator();
        while (it.next()) |e| e.value_ptr.deinit(allocator);
        ctx_map.deinit();
    }

    const now: i64 = 1_700_000_000;
    var results = try allocator.alloc(VectorResult, 2);
    defer allocator.free(results);
    results[0] = .{ .id = try allocator.dupe(u8, "a"), .score = 0.8, .timestamp = now, .importance = 0.1 };
    results[1] = .{ .id = try allocator.dupe(u8, "b"), .score = 0.8, .timestamp = now, .importance = 0.9 };

    const cfg = config.Config{
        .qdrant = .{ .host = "h", .port = 0, .collection_name = "c" },
        .arango = .{ .host = "h", .port = 0, .database = "d", .username = "u", .password = "p" },
        .ranking = .{ .similarity_weight = 0.0, .recency_weight = 0.0, .graph_weight = 0.0, .recency_decay_factor = 0.1, .importance_weight = 1.0, .behavior_weight = 0.0 },
        .server = .{},
        .persistent_memory = .{},
        .conversation_memory = .{},
        .embedding = .{},
    };

    const ranked = try rerank(allocator, results, &ctx_map, cfg);
    defer {
        for (ranked) |r| r.deinit(allocator);
        allocator.free(ranked);
    }
    allocator.free(results[0].id);
    allocator.free(results[1].id);
    try std.testing.expect(std.mem.eql(u8, ranked[0].id, "b"));
}

test "rerank graph weight affects order" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx_map = std.HashMap([]const u8, arango.GraphContext, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator);
    defer {
        var it = ctx_map.iterator();
        while (it.next()) |e| e.value_ptr.deinit(allocator);
        ctx_map.deinit();
    }

    const now: i64 = 1_700_000_000;
    var results = try allocator.alloc(VectorResult, 2);
    defer allocator.free(results);
    results[0] = .{ .id = try allocator.dupe(u8, "a"), .score = 0.5, .timestamp = now };
    results[1] = .{ .id = try allocator.dupe(u8, "b"), .score = 0.5, .timestamp = now };

    var neigh_a = try allocator.alloc([]const u8, 1);
    neigh_a[0] = try allocator.dupe(u8, "n1");
    var weights_a = try allocator.alloc(f32, 1);
    weights_a[0] = 0.1;
    const ctx_a = arango.GraphContext{ .neighbors = neigh_a, .weights = weights_a, .topics = &[_][]const u8{} };
    try ctx_map.put(results[0].id, ctx_a);

    var neigh_b = try allocator.alloc([]const u8, 1);
    neigh_b[0] = try allocator.dupe(u8, "n2");
    var weights_b = try allocator.alloc(f32, 1);
    weights_b[0] = 1.0;
    const ctx_b = arango.GraphContext{ .neighbors = neigh_b, .weights = weights_b, .topics = &[_][]const u8{} };
    try ctx_map.put(results[1].id, ctx_b);

    const cfg = config.Config{
        .qdrant = .{ .host = "h", .port = 0, .collection_name = "c" },
        .arango = .{ .host = "h", .port = 0, .database = "d", .username = "u", .password = "p" },
        .ranking = .{ .similarity_weight = 0.0, .recency_weight = 0.0, .graph_weight = 1.0, .recency_decay_factor = 0.1, .importance_weight = 0.0, .behavior_weight = 0.0 },
        .server = .{},
        .persistent_memory = .{},
        .conversation_memory = .{},
        .embedding = .{},
    };

    const ranked = try rerank(allocator, results, &ctx_map, cfg);
    defer {
        for (ranked) |r| r.deinit(allocator);
        allocator.free(ranked);
    }
    allocator.free(results[0].id);
    allocator.free(results[1].id);
    try std.testing.expect(std.mem.eql(u8, ranked[0].id, "b"));
}
