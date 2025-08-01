// build.zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "semantic-search",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

// =============================================================================
// src/main.zig
// =============================================================================

const std = @import("std");
const config = @import("config.zig");
const qdrant = @import("qdrant.zig");
const arango = @import("arango.zig");
const reranker = @import("reranker.zig");
const utils = @import("utils.zig");

const SemanticSearchApp = struct {
    allocator: std.mem.Allocator,
    config: config.Config,
    qdrant_client: qdrant.QdrantClient,
    arango_client: arango.ArangoClient,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config_path: []const u8) !Self {
        const app_config = try config.loadConfig(allocator, config_path);
        
        return Self{
            .allocator = allocator,
            .config = app_config,
            .qdrant_client = qdrant.QdrantClient.init(allocator, app_config.qdrant),
            .arango_client = arango.ArangoClient.init(allocator, app_config.arango),
        };
    }

    pub fn deinit(self: *Self) void {
        self.qdrant_client.deinit();
        self.arango_client.deinit();
        self.config.deinit(self.allocator);
    }

    pub fn search(self: *Self, query: reranker.SearchQuery) ![]reranker.SearchResult {
        // Step 1: Vector search in Qdrant
        std.log.info("Performing vector search in Qdrant...", .{});
        const vector_results = try self.qdrant_client.search(query);
        defer self.allocator.free(vector_results);

        if (vector_results.len == 0) {
            return &[_]reranker.SearchResult{};
        }

        // Step 2: Fetch graph context from ArangoDB
        std.log.info("Fetching graph context from ArangoDB...", .{});
        var graph_context = std.HashMap([]const u8, arango.GraphContext, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(self.allocator);
        defer {
            var iterator = graph_context.iterator();
            while (iterator.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            graph_context.deinit();
        }

        for (vector_results) |result| {
            const context = try self.arango_client.getGraphContext(result.id);
            try graph_context.put(result.id, context);
        }

        // Step 3: Re-rank results
        std.log.info("Re-ranking results...", .{});
        const ranked_results = try reranker.rerank(
            self.allocator,
            vector_results,
            &graph_context,
            query,
        );

        return ranked_results;
    }

    pub fn ingest(self: *Self, document: reranker.Document) !void {
        // Store vector in Qdrant
        try self.qdrant_client.upsert(document);
        
        // Store graph relationships in ArangoDB
        try self.arango_client.upsertNode(document);
        
        std.log.info("Ingested document: {s}", .{document.id});
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.log.err("Usage: {s} <command> [args...]", .{args[0]});
        std.log.err("Commands:");
        std.log.err("  search <query.json>");
        std.log.err("  ingest <document.json>");
        return;
    }

    var app = try SemanticSearchApp.init(allocator, "config/config.json");
    defer app.deinit();

    const command = args[1];

    if (std.mem.eql(u8, command, "search")) {
        if (args.len < 3) {
            std.log.err("Usage: {s} search <query.json>", .{args[0]});
            return;
        }

        const query_json = try std.fs.cwd().readFileAlloc(allocator, args[2], 1024 * 1024);
        defer allocator.free(query_json);

        const query = try utils.parseJson(reranker.SearchQuery, allocator, query_json);
        defer query.deinit(allocator);

        const results = try app.search(query);
        defer {
            for (results) |result| {
                result.deinit(allocator);
            }
            allocator.free(results);
        }

        const results_json = try utils.stringifyJson(allocator, results);
        defer allocator.free(results_json);

        try std.io.getStdOut().writeAll(results_json);
    } else if (std.mem.eql(u8, command, "ingest")) {
        if (args.len < 3) {
            std.log.err("Usage: {s} ingest <document.json>", .{args[0]});
            return;
        }

        const doc_json = try std.fs.cwd().readFileAlloc(allocator, args[2], 1024 * 1024);
        defer allocator.free(doc_json);

        const document = try utils.parseJson(reranker.Document, allocator, doc_json);
        defer document.deinit(allocator);

        try app.ingest(document);
        std.log.info("Document ingested successfully", .{});
    } else {
        std.log.err("Unknown command: {s}", .{command});
        return;
    }
}

// =============================================================================
// src/config.zig
// =============================================================================

const std = @import("std");
const utils = @import("utils.zig");

pub const QdrantConfig = struct {
    host: []const u8,
    port: u16,
    collection_name: []const u8,
    api_key: ?[]const u8 = null,

    pub fn deinit(self: *const QdrantConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        allocator.free(self.collection_name);
        if (self.api_key) |key| {
            allocator.free(key);
        }
    }
};

pub const ArangoConfig = struct {
    host: []const u8,
    port: u16,
    database: []const u8,
    username: []const u8,
    password: []const u8,

    pub fn deinit(self: *const ArangoConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        allocator.free(self.database);
        allocator.free(self.username);
        allocator.free(self.password);
    }
};

pub const RankingConfig = struct {
    similarity_weight: f32 = 0.5,
    recency_weight: f32 = 0.3,
    graph_weight: f32 = 0.2,
    recency_decay_factor: f32 = 0.1,
};

pub const Config = struct {
    qdrant: QdrantConfig,
    arango: ArangoConfig,
    ranking: RankingConfig = .{},

    pub fn deinit(self: *const Config, allocator: std.mem.Allocator) void {
        self.qdrant.deinit(allocator);
        self.arango.deinit(allocator);
    }
};

pub fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !Config {
    const config_json = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(config_json);

    return try utils.parseJson(Config, allocator, config_json);
}

// =============================================================================
// src/qdrant.zig
// =============================================================================

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

        // Build search request
        const SearchRequest = struct {
            vector: []const f32,
            limit: u32,
            filter: ?FilterCondition = null,
            with_payload: bool = true,
        };

        const FilterCondition = struct {
            must: []FilterClause,
        };

        const FilterClause = struct {
            range: ?RangeFilter = null,
            match: ?MatchFilter = null,
        };

        const RangeFilter = struct {
            timestamp: struct {
                gte: ?i64 = null,
                lte: ?i64 = null,
            },
        };

        const MatchFilter = struct {
            topic_id: []const u8,
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
        defer response.deinit(self.allocator);

        var results = try self.allocator.alloc(reranker.VectorResult, response.result.len);
        for (response.result, 0..) |item, i| {
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

        const UpsertRequest = struct {
            points: []PointData,
        };

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

        const points = [_]PointData{.{
            .id = document.id,
            .vector = document.vector,
            .payload = .{
                .timestamp = document.timestamp,
                .graph_node_id = document.id,
                .content = document.content,
                .topic_id = document.topic_id,
            },
        }};

        const request = UpsertRequest{ .points = &points };
        const request_json = try utils.stringifyJson(self.allocator, request);
        defer self.allocator.free(request_json);

        const response_json = try self.makeRequest(.PUT, url, request_json);
        defer self.allocator.free(response_json);
    }

    fn makeRequest(self: *Self, method: std.http.Method, url: []const u8, body: ?[]const u8) ![]u8 {
        const uri = try std.Uri.parse(url);
        
        var headers = std.http.Client.Request.Headers{};
        if (self.config.api_key) |api_key| {
            try headers.append("api-key", api_key);
        }
        try headers.append("content-type", "application/json");

        var request = try self.http_client.request(method, uri, headers, .{});
        defer request.deinit();

        if (body) |b| {
            request.transfer_encoding = .{ .content_length = b.len };
            try request.send();
            try request.writeAll(b);
        } else {
            try request.send();
        }

        try request.finish();
        try request.wait();

        const response_body = try request.reader().readAllAlloc(self.allocator, 1024 * 1024);
        return response_body;
    }
};

// =============================================================================
// src/arango.zig
// =============================================================================

const std = @import("std");
const utils = @import("utils.zig");
const config = @import("config.zig");
const reranker = @import("reranker.zig");

pub const GraphContext = struct {
    neighbors: [][]const u8,
    weights: []f32,
    topics: [][]const u8,

    pub fn deinit(self: *const GraphContext, allocator: std.mem.Allocator) void {
        for (self.neighbors) |neighbor| {
            allocator.free(neighbor);
        }
        allocator.free(self.neighbors);
        allocator.free(self.weights);
        for (self.topics) |topic| {
            allocator.free(topic);
        }
        allocator.free(self.topics);
    }
};

pub const ArangoClient = struct {
    allocator: std.mem.Allocator,
    config: config.ArangoConfig,
    http_client: std.http.Client,
    auth_token: ?[]u8 = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, arango_config: config.ArangoConfig) Self {
        return Self{
            .allocator = allocator,
            .config = arango_config,
            .http_client = std.http.Client{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.auth_token) |token| {
            self.allocator.free(token);
        }
        self.http_client.deinit();
    }

    pub fn authenticate(self: *Self) !void {
        const url = try std.fmt.allocPrint(
            self.allocator,
            "http://{s}:{d}/_open/auth",
            .{ self.config.host, self.config.port }
        );
        defer self.allocator.free(url);

        const AuthRequest = struct {
            username: []const u8,
            password: []const u8,
        };

        const auth_request = AuthRequest{
            .username = self.config.username,
            .password = self.config.password,
        };

        const request_json = try utils.stringifyJson(self.allocator, auth_request);
        defer self.allocator.free(request_json);

        const response_json = try self.makeRequest(.POST, url, request_json, false);
        defer self.allocator.free(response_json);

        const AuthResponse = struct {
            jwt: []const u8,
        };

        const response = try utils.parseJson(AuthResponse, self.allocator, response_json);
        defer response.deinit(self.allocator);

        self.auth_token = try self.allocator.dupe(u8, response.jwt);
    }

    pub fn getGraphContext(self: *Self, node_id: []const u8) !GraphContext {
        if (self.auth_token == null) {
            try self.authenticate();
        }

        const query = try std.fmt.allocPrint(
            self.allocator,
            \\FOR v, e IN 1..2 OUTBOUND @node_id edges
            \\RETURN {{
            \\  neighbor: v._key,
            \\  weight: e.weight || 1.0,
            \\  type: e.type
            \\}}
            ,
            .{}
        );
        defer self.allocator.free(query);

        const QueryRequest = struct {
            query: []const u8,
            bindVars: struct {
                node_id: []const u8,
            },
        };

        const query_request = QueryRequest{
            .query = query,
            .bindVars = .{ .node_id = node_id },
        };

        const request_json = try utils.stringifyJson(self.allocator, query_request);
        defer self.allocator.free(request_json);

        const url = try std.fmt.allocPrint(
            self.allocator,
            "http://{s}:{d}/_db/{s}/_api/cursor",
            .{ self.config.host, self.config.port, self.config.database }
        );
        defer self.allocator.free(url);

        const response_json = try self.makeRequest(.POST, url, request_json, true);
        defer self.allocator.free(response_json);

        const QueryResponse = struct {
            result: []struct {
                neighbor: []const u8,
                weight: f32,
                type: []const u8,
            },
        };

        const response = try utils.parseJson(QueryResponse, self.allocator, response_json);
        defer response.deinit(self.allocator);

        var neighbors = std.ArrayList([]const u8).init(self.allocator);
        var weights = std.ArrayList(f32).init(self.allocator);
        var topics = std.ArrayList([]const u8).init(self.allocator);

        for (response.result) |item| {
            try neighbors.append(try self.allocator.dupe(u8, item.neighbor));
            try weights.append(item.weight);
            
            if (std.mem.eql(u8, item.type, "HAS_TOPIC")) {
                try topics.append(try self.allocator.dupe(u8, item.neighbor));
            }
        }

        return GraphContext{
            .neighbors = try neighbors.toOwnedSlice(),
            .weights = try weights.toOwnedSlice(),
            .topics = try topics.toOwnedSlice(),
        };
    }

    pub fn upsertNode(self: *Self, document: reranker.Document) !void {
        if (self.auth_token == null) {
            try self.authenticate();
        }

        // Create/update the document node
        const NodeDocument = struct {
            _key: []const u8,
            timestamp: i64,
            content: ?[]const u8,
            topic_id: ?[]const u8,
        };

        const node_doc = NodeDocument{
            ._key = document.id,
            .timestamp = document.timestamp,
            .content = document.content,
            .topic_id = document.topic_id,
        };

        const node_json = try utils.stringifyJson(self.allocator, node_doc);
        defer self.allocator.free(node_json);

        const url = try std.fmt.allocPrint(
            self.allocator,
            "http://{s}:{d}/_db/{s}/_api/document/chunks",
            .{ self.config.host, self.config.port, self.config.database }
        );
        defer self.allocator.free(url);

        const response_json = try self.makeRequest(.POST, url, node_json, true);
        defer self.allocator.free(response_json);

        // Create topic relationship if specified
        if (document.topic_id) |topic_id| {
            try self.createEdge(document.id, topic_id, "HAS_TOPIC", 1.0);
        }

        // Create relationships to related documents if specified
        if (document.related_documents) |related| {
            for (related) |related_id| {
                try self.createEdge(document.id, related_id, "REFERS_TO", 0.8);
            }
        }
    }

    fn createEdge(self: *Self, from_id: []const u8, to_id: []const u8, edge_type: []const u8, weight: f32) !void {
        const EdgeDocument = struct {
            _from: []const u8,
            _to: []const u8,
            type: []const u8,
            weight: f32,
        };

        const from_full = try std.fmt.allocPrint(self.allocator, "chunks/{s}", .{from_id});
        defer self.allocator.free(from_full);
        
        const to_full = try std.fmt.allocPrint(self.allocator, "chunks/{s}", .{to_id});
        defer self.allocator.free(to_full);

        const edge_doc = EdgeDocument{
            ._from = from_full,
            ._to = to_full,
            .type = edge_type,
            .weight = weight,
        };

        const edge_json = try utils.stringifyJson(self.allocator, edge_doc);
        defer self.allocator.free(edge_json);

        const url = try std.fmt.allocPrint(
            self.allocator,
            "http://{s}:{d}/_db/{s}/_api/document/edges",
            .{ self.config.host, self.config.port, self.config.database }
        );
        defer self.allocator.free(url);

        const response_json = try self.makeRequest(.POST, url, edge_json, true);
        defer self.allocator.free(response_json);
    }

    fn makeRequest(self: *Self, method: std.http.Method, url: []const u8, body: ?[]const u8, use_auth: bool) ![]u8 {
        const uri = try std.Uri.parse(url);
        
        var headers = std.http.Client.Request.Headers{};
        if (use_auth and self.auth_token != null) {
            const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.auth_token.?});
            defer self.allocator.free(auth_header);
            try headers.append("Authorization", auth_header);
        }
        try headers.append("content-type", "application/json");

        var request = try self.http_client.request(method, uri, headers, .{});
        defer request.deinit();

        if (body) |b| {
            request.transfer_encoding = .{ .content_length = b.len };
            try request.send();
            try request.writeAll(b);
        } else {
            try request.send();
        }

        try request.finish();
        try request.wait();

        const response_body = try request.reader().readAllAlloc(self.allocator, 1024 * 1024);
        return response_body;
    }
};

// =============================================================================
// src/reranker.zig
// =============================================================================

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
    query: SearchQuery,
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

// =============================================================================
// src/utils.zig
// =============================================================================

const std = @import("std");

pub fn parseJson(comptime T: type, allocator: std.mem.Allocator, json_str: []const u8) !T {
    const parsed = try std.json.parseFromSlice(T, allocator, json_str, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    return parsed.value;
}

pub fn stringifyJson(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var string = std.ArrayList(u8).init(allocator);
    try std.json.stringify(value, .{}, string.writer());
    return string.toOwnedSlice();
}

pub fn getCurrentTimestamp() i64 {
    return std.time.timestamp();
}

// =============================================================================
// Example configuration files
// =============================================================================

// config/config.json
{
  "qdrant": {
    "host": "localhost",
    "port": 6333,
    "collection_name": "semantic_chunks",
    "api_key": null
  },
  "arango": {
    "host": "localhost",
    "port": 8529,
    "database": "semantic_graph",
    "username": "root",
    "password": "password"
  },
  "ranking": {
    "similarity_weight": 0.5,
    "recency_weight": 0.3,
    "graph_weight": 0.2,
    "recency_decay_factor": 0.1
  }
}

// =============================================================================
// Example query and document files
// =============================================================================

// examples/query.json
{
  "vector": [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8],
  "limit": 10,
  "time_range": {
    "start": 1722480000,
    "end": 1722566400
  },
  "topic_id": "machine_learning"
}

// examples/document.json
{
  "id": "doc_001",
  "vector": [0.15, 0.25, 0.35, 0.45, 0.55, 0.65, 0.75, 0.85],
  "timestamp": 1722516000,
  "content": "This is a sample document about machine learning algorithms.",
  "topic_id": "machine_learning",
  "related_documents": ["doc_002", "doc_003"]
}

// =============================================================================
// README.md
// =============================================================================

# Time-Aware Semantic Retrieval System

A high-performance semantic search system built with Zig that combines vector similarity search with graph-based contextual understanding and temporal awareness.

## Features

- **Vector Search**: Fast similarity search using Qdrant vector database
- **Graph Context**: Relationship modeling with ArangoDB for enhanced relevance
- **Time Awareness**: Temporal filtering and recency-based scoring
- **Efficient Re-ranking**: Multi-factor scoring algorithm combining similarity, recency, and graph weights
- **Single Binary**: Compiled to a fast, standalone executable

## Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Qdrant DB     │    │   ArangoDB      │    │   Zig App       │
│  (Vectors)      │◄──►│  (Graph)        │◄──►│  (Orchestrator) │
│                 │    │                 │    │                 │
│ • Embeddings    │    │ • Relationships │    │ • Query Router  │
│ • Metadata      │    │ • Topics        │    │ • Re-ranker     │
│ • Time filters  │    │ • Weights       │    │ • HTTP Client   │
└─────────────────┘    └─────────────────┘    └─────────────────┘
```

## Quick Start

### Prerequisites

- Zig 0.11+ installed
- Qdrant running on localhost:6333
- ArangoDB running on localhost:8529

### Build

```bash
zig build -Drelease-fast
```

### Configuration

Create `config/config.json`:

```json
{
  "qdrant": {
    "host": "localhost",
    "port": 6333,
    "collection_name": "semantic_chunks"
  },
  "arango": {
    "host": "localhost",
    "port": 8529,
    "database": "semantic_graph",
    "username": "root",
    "password": "your_password"
  }
}
```

### Usage

**Ingest a document:**
```bash
./zig-out/bin/semantic-search ingest examples/document.json
```

**Search:**
```bash
./zig-out/bin/semantic-search search examples/query.json
```

## API Reference

### Search Query Format

```json
{
  "vector": [0.1, 0.2, 0.3, ...],
  "limit": 10,
  "time_range": {
    "start": 1722480000,
    "end": 1722566400
  },
  "topic_id": "machine_learning"
}
```

### Document Format

```json
{
  "id": "unique_doc_id",
  "vector": [0.1, 0.2, 0.3, ...],
  "timestamp": 1722516000,
  "content": "Document text content",
  "topic_id": "topic_category",
  "related_documents": ["doc_002", "doc_003"]
}
```

### Search Results

```json
[
  {
    "id": "doc_001",
    "score": 0.88,
    "timestamp": 1722516000,
    "content": "Document content...",
    "graph_neighbors": ["doc_002", "doc_003"],
    "similarity_score": 0.92,
    "recency_score": 0.85,
    "graph_score": 0.78
  }
]
```

## Scoring Algorithm

The system uses a weighted combination of three factors:

```
final_score = α × similarity + β × recency + γ × graph_weight
```

Where:
- **similarity**: Cosine similarity from vector search (0-1)
- **recency**: Time-based decay score (1/(1 + decay_factor × age_days))  
- **graph_weight**: Average weight of connected nodes (0-1)

Default weights: α=0.5, β=0.3, γ=0.2

## Database Setup

### Qdrant Collection

```bash
curl -X PUT http://localhost:6333/collections/semantic_chunks \
  -H "Content-Type: application/json" \
  -d '{
    "vectors": {
      "size": 768,
      "distance": "Cosine"
    }
  }'
```

### ArangoDB Collections

```javascript
// Create database
db._createDatabase("semantic_graph");

// Switch to database
db._useDatabase("semantic_graph");

// Create collections
db._create("chunks");
db._createEdgeCollection("edges");

// Create indexes
db.chunks.ensureIndex({ type: "persistent", fields: ["timestamp"] });
db.edges.ensureIndex({ type: "persistent", fields: ["type"] });
```

## Performance Considerations

- **Memory Usage**: Results are streamed and cleaned up automatically
- **HTTP Pooling**: Single HTTP client instance per database connection
- **JSON Parsing**: Efficient streaming JSON parser with minimal allocations
- **Graph Traversal**: Limited depth (1-2 hops) to prevent expensive operations
- **Batch Operations**: Support for bulk document ingestion

## Development

### Running Tests

```bash
zig build test
```

### Adding Features

The modular design makes it easy to extend:

- **New databases**: Implement client interface in new module
- **Custom scoring**: Modify `reranker.zig` scoring functions  
- **Additional filters**: Extend query structure and filter logic
- **Web API**: Add HTTP server to `main.zig`

### Performance Tuning

Key configuration parameters:

```json
{
  "ranking": {
    "similarity_weight": 0.5,
    "recency_weight": 0.3,
    "graph_weight": 0.2,
    "recency_decay_factor": 0.1
  }
}
```

## Production Deployment

### Docker Setup

```dockerfile
FROM alpine:latest
RUN apk add --no-cache ca-certificates
COPY ./zig-out/bin/semantic-search /usr/local/bin/
COPY ./config /etc/semantic-search/config
ENTRYPOINT ["/usr/local/bin/semantic-search"]
```

### Monitoring

The system logs key metrics:
- Query latency breakdown (vector + graph + ranking)
- Database connection health
- Error rates and types

### Scaling

- **Horizontal**: Multiple app instances behind load balancer
- **Database**: Qdrant and ArangoDB both support clustering
- **Caching**: Add Redis layer for frequently accessed graph contexts

## License

MIT License - see LICENSE file for details.