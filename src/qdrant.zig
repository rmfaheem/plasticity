const std = @import("std");
const utils = @import("utils.zig");
const config = @import("config.zig");
const reranker = @import("reranker.zig");

pub const QdrantClient = struct {
    allocator: std.mem.Allocator,
    config: config.QdrantConfig,
    http_client: std.http.Client,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, qdrant_config: config.QdrantConfig) Self {
        return Self{
            .allocator = allocator,
            .config = qdrant_config,
            .http_client = std.http.Client{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *Self) void {
        self.http_client.deinit();
    }

    pub fn search(self: *Self, query: reranker.SearchQuery) ![]reranker.VectorResult {
        const url = try std.fmt.allocPrint(
            self.allocator,
            "http://{s}:{d}/collections/{s}/points/search",
            .{ self.config.host, self.config.port, self.config.collection_name }
        );
        defer self.allocator.free(url);

        // Build search request structures
        const RangeFilter = struct {
            timestamp: struct {
                gte: ?i64 = null,
                lte: ?i64 = null,
            },
        };

        const MatchFilter = struct {
            topic_id: []const u8,
        };

        const FilterClause = struct {
            range: ?RangeFilter = null,
            match: ?MatchFilter = null,
        };

        const FilterCondition = struct {
            must: []FilterClause,
        };

        const SearchRequest = struct {
            vector: []const f32,
            limit: u32,
            filter: ?FilterCondition = null,
            with_payload: bool = true,
        };

        var filter: ?FilterCondition = null;
        var filter_clauses = std.ArrayList(FilterClause).init(self.allocator);
        defer filter_clauses.deinit();

        // Add time range filter
        if (query.time_range) |time_range| {
            try filter_clauses.append(.{
                .range = .{
                    .timestamp = .{
                        .gte = time_range.start,
                        .lte = time_range.end,
                    },
                },
            });
        }

        // Add topic filter
        if (query.topic_id) |topic_id| {
            try filter_clauses.append(.{
                .match = .{
                    .topic_id = topic_id,
                },
            });
        }

        if (filter_clauses.items.len > 0) {
            filter = .{ .must = filter_clauses.items };
        }

        const search_request = SearchRequest{
            .vector = query.vector,
            .limit = query.limit orelse 10,
            .filter = filter,
        };

        const request_json = try utils.stringifyJson(self.allocator, search_request);
        defer self.allocator.free(request_json);

        // Make HTTP request
        const response_json = try self.makeRequest(.POST, url, request_json);
        defer self.allocator.free(response_json);

        // Parse response
        const SearchResponse = struct {
            result: []struct {
                id: []const u8,
                score: f32,
                payload: struct {
                    timestamp: i64,
                    graph_node_id: []const u8,
                    content: ?[]const u8 = null,
                },
            },
        };

        const response = try utils.parseJson(SearchResponse, self.allocator, response_json);
        defer response.deinit();

        var results = try self.allocator.alloc(reranker.VectorResult, response.value.result.len);
        for (response.value.result, 0..) |item, i| {
            results[i] = reranker.VectorResult{
                .id = try self.allocator.dupe(u8, item.id),
                .score = item.score,
                .timestamp = item.payload.timestamp,
                .content = if (item.payload.content) |content| 
                    try self.allocator.dupe(u8, content) else null,
            };
        }

        return results;
    }

    pub fn upsert(self: *Self, document: reranker.Document) !void {
        const url = try std.fmt.allocPrint(
            self.allocator,
            "http://{s}:{d}/collections/{s}/points",
            .{ self.config.host, self.config.port, self.config.collection_name }
        );
        defer self.allocator.free(url);

        const PointData = struct {
            id: []const u8,
            vector: []const f32,
            payload: struct {
                timestamp: i64,
                graph_node_id: []const u8,
                content: ?[]const u8 = null,
                topic_id: ?[]const u8 = null,
            },
        };

        const UpsertRequest = struct {
            points: []PointData,
        };

        var points = [_]PointData{.{
            .id = document.id,
            .vector = document.vector,
            .payload = .{
                .timestamp = document.timestamp,
                .graph_node_id = document.id,
                .content = document.content,
                .topic_id = document.topic_id,
            },
        }};

        const request = UpsertRequest{ .points = points[0..] };
        const request_json = try utils.stringifyJson(self.allocator, request);
        defer self.allocator.free(request_json);

        const response_json = try self.makeRequest(.PUT, url, request_json);
        defer self.allocator.free(response_json);
    }

    fn makeRequest(self: *Self, method: std.http.Method, url: []const u8, body: ?[]const u8) ![]u8 {
        const uri = try std.Uri.parse(url);
        
        var headers = std.ArrayList(std.http.Header).init(self.allocator);
        defer headers.deinit();
        
        if (self.config.api_key) |api_key| {
            try headers.append(.{ .name = "api-key", .value = api_key });
        }
        try headers.append(.{ .name = "content-type", .value = "application/json" });

        var response_body = std.ArrayList(u8).init(self.allocator);

        const result = try self.http_client.fetch(.{
            .method = method,
            .location = .{ .uri = uri },
            .extra_headers = headers.items,
            .payload = body,
            .response_storage = .{ .dynamic = &response_body },
        });

        _ = result; // Ignore result for now

        return response_body.toOwnedSlice();
    }
};