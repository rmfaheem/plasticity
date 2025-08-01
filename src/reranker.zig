const std = @import("std");
const arango = @import("arango.zig");
const config = @import("config.zig");

pub const TimeRange = struct {
    start: i64,
    end: i64,
};

pub const SearchQuery = struct {
    vector: []const f32,
    limit: ?u32 = null,
    time_range: ?TimeRange = null,
    topic_id: ?[]const u8 = null,
    source_node_id: ?[]const u8 = null,

    pub fn deinit(self: *const SearchQuery, allocator: std.mem.Allocator) void {
        allocator.free(self.vector);
        if (self.topic_id) |topic| {
            allocator.free(topic);
        }
        if (self.source_node_id) |node| {
            allocator.free(node);
        }
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

pub const Document = struct {
    id: []const u8,
    vector: []const f32,
    timestamp: i64,
    content: ?[]const u8 = null,
    topic_id: ?[]const u8 = null,
    related_documents: ?[][]const u8 = null,

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
    }
};

pub fn rerank(
    allocator: std.mem.Allocator,
    vector_results: []const VectorResult,
    graph_contexts: *const std.HashMap([]const u8, arango.GraphContext, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    _: SearchQuery,
) ![]SearchResult {
    const ranking_config = config.RankingConfig{};
    const current_time = std.time.timestamp();

    var scored_results = try allocator.alloc(SearchResult, vector_results.len);
    
    for (vector_results, 0..) |result, i| {
        const graph_context = graph_contexts.get(result.id) orelse arango.GraphContext{
            .neighbors = &[_][]const u8{},
            .weights = &[_]f32{},
            .topics = &[_][]const u8{},
        };

        // Calculate component scores
        const similarity_score = result.score;
        const age_seconds = @as(f32, @floatFromInt(current_time - result.timestamp));
        const recency_score = 1.0 / (1.0 + ranking_config.recency_decay_factor * age_seconds / 86400.0); // decay per day
        
        // Calculate graph score (average of neighbor weights)
        var graph_score: f32 = 0.0;
        if (graph_context.weights.len > 0) {
            var total_weight: f32 = 0.0;
            for (graph_context.weights) |weight| {
                total_weight += weight;
            }
            graph_score = total_weight / @as(f32, @floatFromInt(graph_context.weights.len));
        }

        // Combined score
        const final_score = ranking_config.similarity_weight * similarity_score +
            ranking_config.recency_weight * recency_score +
            ranking_config.graph_weight * graph_score;

        // Copy neighbors for result
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

    // Sort by final score (descending)
    std.sort.insertion(SearchResult, scored_results, {}, compareSearchResults);

    return scored_results;
}

fn compareSearchResults(_: void, a: SearchResult, b: SearchResult) bool {
    return a.score > b.score;
}