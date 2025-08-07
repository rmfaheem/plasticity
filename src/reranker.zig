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
    }
};

pub const VectorResult = struct {
    id: []const u8,
    score: f32,
    timestamp: i64,
    content: ?[]const u8 = null,

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
    }

    pub fn fromJson(allocator: std.mem.Allocator, json_doc: DocumentJson) !Document {
        var metadata: ?std.StringHashMap([]const u8) = null;
        if (json_doc.metadata) |json_meta| {
            metadata = std.StringHashMap([]const u8).init(allocator);
            if (json_meta == .object) {
                var it = json_meta.object.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.* == .string) {
                        try metadata.?.put(
                            try allocator.dupe(u8, entry.key_ptr.*),
                            try allocator.dupe(u8, entry.value_ptr.*.string)
                        );
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
            app_config.ranking.graph_weight * graph_score;

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
        };
    }

    std.sort.insertion(SearchResult, scored_results, {}, compareSearchResults);
    return scored_results;
}

fn compareSearchResults(_: void, a: SearchResult, b: SearchResult) bool {
    return a.score > b.score;
}