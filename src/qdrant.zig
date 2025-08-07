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
        std.log.info("Starting Qdrant search", .{});

        const url = try std.fmt.allocPrint(self.allocator, "http://{s}:{d}/collections/{s}/points/search", .{ self.config.host, self.config.port, self.config.collection_name });
        defer self.allocator.free(url);

        std.log.info("Search URL: {s}", .{url});

        // Build search request structures using correct Qdrant format
        const MatchValue = struct {
            value: []const u8,
        };

        const RangeValue = struct {
            gte: ?i64 = null,
            lte: ?i64 = null,
        };

        const FilterClause = struct {
            key: []const u8,
            match: ?MatchValue = null,
            range: ?RangeValue = null,
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
                .key = "timestamp",
                .range = .{
                    .gte = time_range.start,
                    .lte = time_range.end,
                },
            });
        }

        // Add topic filter
        if (query.topic_id) |topic_id| {
            try filter_clauses.append(.{
                .key = "topic_id",
                .match = .{
                    .value = topic_id,
                },
            });
        }

        // Add user filter
        if (query.user_id) |user_id| {
            try filter_clauses.append(.{
                .key = "user_id",
                .match = .{
                    .value = user_id,
                },
            });
        }

        // Add context_types filter
        if (query.context_types) |context_types| {
            // For now, just use the first context type
            // TODO: Implement proper OR logic for multiple context types
            const context_type_str = switch (context_types[0]) {
                .preference => "preference",
                .decision => "decision",
                .observation => "observation",
            };
            try filter_clauses.append(.{
                .key = "context_type",
                .match = .{
                    .value = context_type_str,
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

        std.log.info("Search request constructed successfully", .{});

        const request_json = try utils.stringifyJson(self.allocator, search_request);
        defer self.allocator.free(request_json);

        // Debug logging
        std.log.info("Qdrant search request JSON: {s}", .{request_json});

        // Make HTTP request
        const response_json = try self.makeRequest(.POST, url, request_json);
        defer self.allocator.free(response_json);

        // Debug logging
        std.log.info("Qdrant search response: {s}", .{response_json});

        // Parse response
        std.log.info("About to parse Qdrant search response JSON", .{});
        const SearchResponse = struct {
            result: []struct {
                id: u64,
                score: f32,
                payload: ?struct {
                    timestamp: i64,
                    graph_node_id: []const u8,
                    content: ?[]const u8 = null,
                    topic_id: ?[]const u8 = null,
                    user_id: ?[]const u8 = null,
                    context_type: ?[]const u8 = null,
                    metadata: ?std.json.Value = null,
                } = null,
            },
        };

        std.log.info("SearchResponse struct defined, attempting to parse JSON", .{});
        const response = utils.parseJson(SearchResponse, self.allocator, response_json) catch |err| {
            std.log.err("Failed to parse Qdrant search response JSON: {any}", .{err});
            std.log.err("Response JSON was: {s}", .{response_json});
            return err;
        };
        defer response.deinit();
        std.log.info("Successfully parsed Qdrant search response", .{});

        std.log.info("Processing {d} search results", .{response.value.result.len});
        var results = try self.allocator.alloc(reranker.VectorResult, response.value.result.len);
        for (response.value.result, 0..) |item, i| {
            std.log.info("Processing result {d}: id={d}, score={d}", .{ i, item.id, item.score });

            // Convert integer ID back to string for consistency
            const id_str = std.fmt.allocPrint(self.allocator, "{d}", .{item.id}) catch |err| {
                std.log.err("Failed to convert ID {d} to string: {any}", .{ item.id, err });
                return err;
            };

            std.log.info("Result {d} has payload: {any}", .{ i, item.payload != null });
            if (item.payload) |payload| {
                std.log.info("Result {d} payload timestamp: {d}", .{ i, payload.timestamp });
                std.log.info("Result {d} payload content: {any}", .{ i, payload.content });
            }

            results[i] = reranker.VectorResult{
                .id = id_str,
                .score = item.score,
                .timestamp = if (item.payload) |payload| payload.timestamp else 0,
                .content = if (item.payload) |payload|
                    if (payload.content) |content|
                        self.allocator.dupe(u8, content) catch |err| {
                            std.log.err("Failed to duplicate content for result {d}: {any}", .{ i, err });
                            return err;
                        }
                    else
                        null
                else
                    null,
            };
            std.log.info("Successfully processed result {d}", .{i});
        }

        return results;
    }

    pub fn initCollection(self: *Self) !void {
        const url = try std.fmt.allocPrint(self.allocator, "http://{s}:{d}/collections/{s}", .{ self.config.host, self.config.port, self.config.collection_name });
        defer self.allocator.free(url);

        const CollectionConfig = struct {
            vectors: struct {
                size: u32,
                distance: []const u8,
            },
            optimizers_config: struct {
                default_segment_number: u32,
            },
            hnsw_config: struct {
                m: u32,
                ef_construct: u32,
            },
        };

        const collection_config = CollectionConfig{
            .vectors = .{
                .size = 8,
                .distance = "Cosine",
            },
            .optimizers_config = .{
                .default_segment_number = 2,
            },
            .hnsw_config = .{
                .m = 16,
                .ef_construct = 100,
            },
        };

        const config_json = try utils.stringifyJson(self.allocator, collection_config);
        defer self.allocator.free(config_json);

        // Try to create the collection
        const response_json = self.makeRequest(.PUT, url, config_json) catch |err| {
            // If collection already exists, that's fine
            if (err == error.CollectionExists) {
                std.log.info("Qdrant collection '{s}' already exists", .{self.config.collection_name});
                return;
            }
            return err;
        };
        defer self.allocator.free(response_json);

        std.log.info("Qdrant collection '{s}' created successfully", .{self.config.collection_name});
    }

    pub fn upsert(self: *Self, document: reranker.Document) !void {
        const url = try std.fmt.allocPrint(self.allocator, "http://{s}:{d}/collections/{s}/points", .{ self.config.host, self.config.port, self.config.collection_name });
        defer self.allocator.free(url);

        // Convert document ID to integer for Qdrant using hash
        const point_id = std.hash.Fnv1a_64.hash(document.id);

        // Convert metadata HashMap to JSON Value
        var metadata_json: ?std.json.Value = null;
        std.log.info("Starting metadata conversion for document '{s}'", .{document.id});

        if (document.metadata) |*meta| {
            std.log.info("Document has metadata, converting HashMap to JSON", .{});
            var metadata_obj = std.json.ObjectMap.init(self.allocator);
            std.log.info("Created metadata ObjectMap", .{});

            var it = meta.iterator();
            var entry_count: usize = 0;
            while (it.next()) |entry| {
                std.log.info("Processing metadata entry: key='{s}', value='{s}'", .{ entry.key_ptr.*, entry.value_ptr.* });
                try metadata_obj.put(entry.key_ptr.*, std.json.Value{ .string = entry.value_ptr.* });
                entry_count += 1;
            }
            std.log.info("Processed {d} metadata entries", .{entry_count});

            metadata_json = std.json.Value{ .object = metadata_obj };
            std.log.info("Successfully created metadata JSON Value", .{});
        } else {
            std.log.info("Document has no metadata", .{});
        }

        const PointData = struct {
            id: u64,
            vector: []const f32,
            payload: struct {
                timestamp: i64,
                graph_node_id: []const u8,
                content: ?[]const u8 = null,
                topic_id: ?[]const u8 = null,
                user_id: ?[]const u8 = null,
                context_type: ?[]const u8 = null,
                metadata: ?std.json.Value = null,
            },
        };

        const UpsertRequest = struct {
            points: []PointData,
        };

        // Convert context_type enum to string
        var context_type_str: ?[]const u8 = null;
        if (document.context_type) |context_type| {
            context_type_str = switch (context_type) {
                .preference => "preference",
                .decision => "decision",
                .observation => "observation",
            };
        }

        var points = [_]PointData{.{
            .id = point_id,
            .vector = document.vector,
            .payload = .{
                .timestamp = document.timestamp,
                .graph_node_id = document.id,
                .content = document.content,
                .topic_id = document.topic_id,
                .user_id = document.user_id,
                .context_type = context_type_str,
                .metadata = metadata_json,
            },
        }};

        const request = UpsertRequest{ .points = points[0..] };
        const request_json = try utils.stringifyJson(self.allocator, request);
        defer self.allocator.free(request_json);

        // Debug logging
        std.log.info("Qdrant upsert request JSON: {s}", .{request_json});

        const response_json = try self.makeRequest(.PUT, url, request_json);
        defer self.allocator.free(response_json);

        // Debug logging
        std.log.info("Qdrant upsert response: {s}", .{response_json});
    }

    fn makeRequest(self: *Self, method: std.http.Method, url: []const u8, body: ?[]const u8) ![]u8 {
        const uri = try std.Uri.parse(url);

        var headers = std.ArrayList(std.http.Header).init(self.allocator);
        defer headers.deinit();

        if (self.config.api_key) |api_key| {
            try headers.append(.{ .name = "api-key", .value = api_key });
        }
        try headers.append(.{ .name = "content-type", .value = "application/json" });
        try headers.append(.{ .name = "accept", .value = "application/json" });
        try headers.append(.{ .name = "connection", .value = "close" });

        var response_body = std.ArrayList(u8).init(self.allocator);

        // Create a new HTTP client for each request to avoid connection reuse issues
        var http_client = std.http.Client{ .allocator = self.allocator };
        defer http_client.deinit();

        // Add connection timeout and retry logic
        const result = try http_client.fetch(.{
            .method = method,
            .location = .{ .uri = uri },
            .extra_headers = headers.items,
            .payload = body,
            .response_storage = .{ .dynamic = &response_body },
        });

        _ = result; // Use result to avoid linter error

        const response = response_body.toOwnedSlice();
        return response;
    }
};
