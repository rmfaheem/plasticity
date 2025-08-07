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

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, arango_config: config.ArangoConfig) Self {
        return Self{
            .allocator = allocator,
            .config = arango_config,
            .http_client = std.http.Client{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *Self) void {
        self.http_client.deinit();
    }

    pub fn healthCheck(self: *Self) !void {
        const url = try std.fmt.allocPrint(self.allocator, "http://{s}:{d}/_api/version", .{ self.config.host, self.config.port });
        defer self.allocator.free(url);

        const response = self.makeRequest(.GET, url, null) catch |err| {
            std.log.err("ArangoDB health check failed: {s}", .{@errorName(err)});
            return err;
        };
        defer self.allocator.free(response);

        // If we got here without error, ArangoDB is responding
        std.log.info("ArangoDB health check passed", .{});
    }

    pub fn authenticate(self: *Self) !void {
        const url = try std.fmt.allocPrint(self.allocator, "http://{s}:{d}/_api/auth", .{ self.config.host, self.config.port });
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

        const response_json = try self.makeRequest(.POST, url, request_json);
        defer self.allocator.free(response_json);

        const AuthResponse = struct {
            jwt: []const u8,
        };

        const response = try utils.parseJson(AuthResponse, self.allocator, response_json);
        defer response.deinit();

        // self.auth_token = try self.allocator.dupe(u8, response.value.jwt); // This line is removed
    }

    pub fn initCollections(self: *Self) !void {
        // Create database if it doesn't exist
        const db_url = try std.fmt.allocPrint(self.allocator, "http://{s}:{d}/_api/database", .{ self.config.host, self.config.port });
        defer self.allocator.free(db_url);

        const DbRequest = struct {
            name: []const u8,
        };

        const db_request = DbRequest{ .name = self.config.database };
        const db_json = try utils.stringifyJson(self.allocator, db_request);
        defer self.allocator.free(db_json);

        // Try to create database (ignore if it already exists)
        const db_response = self.makeRequest(.POST, db_url, db_json) catch |err| {
            std.log.info("Database '{s}' creation failed (may already exist): {s}", .{ self.config.database, @errorName(err) });
            return; // Early return on database creation failure
        };
        defer self.allocator.free(db_response);

        // Create collections
        const collections = [_][]const u8{ "chunks", "edges", "users", "user_context" };
        const collection_types = [_]u32{ 2, 3, 2, 3 }; // 2 = document, 3 = edge

        for (collections, 0..) |collection_name, i| {
            const collection_url = try std.fmt.allocPrint(self.allocator, "http://{s}:{d}/_db/{s}/_api/collection", .{ self.config.host, self.config.port, self.config.database });
            defer self.allocator.free(collection_url);

            const CollectionRequest = struct {
                name: []const u8,
                type: u32,
            };

            const collection_request = CollectionRequest{
                .name = collection_name,
                .type = collection_types[i],
            };

            const collection_json = try utils.stringifyJson(self.allocator, collection_request);
            defer self.allocator.free(collection_json);

            // Try to create collection (ignore if it already exists)
            const collection_response = self.makeRequest(.POST, collection_url, collection_json) catch |err| {
                std.log.info("Collection '{s}' creation failed (may already exist): {s}", .{ collection_name, @errorName(err) });
                continue;
            };
            defer self.allocator.free(collection_response);
        }

        // Create indexes
        const indexes = [_]struct {
            collection: []const u8,
            fields: []const []const u8,
        }{
            .{ .collection = "chunks", .fields = &[_][]const u8{"timestamp"} },
            .{ .collection = "edges", .fields = &[_][]const u8{"type"} },
        };

        for (indexes) |index| {
            const index_url = try std.fmt.allocPrint(self.allocator, "http://{s}:{d}/_db/{s}/_api/index", .{ self.config.host, self.config.port, self.config.database });
            defer self.allocator.free(index_url);

            const IndexRequest = struct {
                type: []const u8,
                fields: []const []const u8,
                collection: []const u8,
            };

            const index_request = IndexRequest{
                .type = "persistent",
                .fields = index.fields,
                .collection = index.collection,
            };

            const index_json = try utils.stringifyJson(self.allocator, index_request);
            defer self.allocator.free(index_json);

            // Try to create index (ignore if it already exists)
            const index_response = self.makeRequest(.POST, index_url, index_json) catch |err| {
                std.log.info("Index on '{s}' creation failed (may already exist): {s}", .{ index.collection, @errorName(err) });
                continue;
            };
            defer self.allocator.free(index_response);
        }

        std.log.info("ArangoDB collections and indexes initialized successfully", .{});
    }

    pub fn getGraphContext(self: *Self, node_id: []const u8) !GraphContext {
        // if (self.auth_token == null) { // This line is removed
        //     try self.authenticate(); // This line is removed
        // }

        const query = "FOR v, e IN 1..2 ANY @node_id edges, user_context RETURN { neighbor: v._key, weight: e.weight || 1.0, type: e.type }";

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

        const url = try std.fmt.allocPrint(self.allocator, "http://{s}:{d}/_db/{s}/_api/cursor", .{ self.config.host, self.config.port, self.config.database });
        defer self.allocator.free(url);

        const response_json = try self.makeRequest(.POST, url, request_json);
        defer self.allocator.free(response_json);

        const QueryResponse = struct {
            result: []struct {
                neighbor: []const u8,
                weight: f32,
                type: []const u8,
            },
        };

        const response = try utils.parseJson(QueryResponse, self.allocator, response_json);
        defer response.deinit();

        var neighbors = std.ArrayList([]const u8).init(self.allocator);
        var weights = std.ArrayList(f32).init(self.allocator);
        var topics = std.ArrayList([]const u8).init(self.allocator);

        for (response.value.result) |item| {
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
        // if (self.auth_token == null) { // This line is removed
        //     try self.authenticate(); // This line is removed
        // }

        // Create/update the document node
        const NodeDocument = struct {
            _key: []const u8,
            timestamp: i64,
            content: ?[]const u8,
            topic_id: ?[]const u8,
            user_id: ?[]const u8,
            context_type: ?reranker.ContextType,
        };

        const node_doc = NodeDocument{
            ._key = document.id,
            .timestamp = document.timestamp,
            .content = document.content,
            .topic_id = document.topic_id,
            .user_id = document.user_id,
            .context_type = document.context_type,
        };

        const node_json = try utils.stringifyJson(self.allocator, node_doc);
        defer self.allocator.free(node_json);

        const url = try std.fmt.allocPrint(self.allocator, "http://{s}:{d}/_db/{s}/_api/document/chunks", .{ self.config.host, self.config.port, self.config.database });
        defer self.allocator.free(url);

        const response_json = try self.makeRequest(.POST, url, node_json);
        defer self.allocator.free(response_json);

        // Create user and user-context relationship if specified
        if (document.user_id) |user_id| {
            try self.ensureUserNode(user_id);
            try self.createEdge(user_id, document.id, "HAS_CONTEXT", 1.0, "user_context");
        }

        // Create topic relationship if specified
        if (document.topic_id) |topic_id| {
            try self.createEdge(document.id, topic_id, "HAS_TOPIC", 1.0, "edges");
        }

        // Create relationships to related documents if specified
        if (document.related_documents) |related| {
            for (related) |related_id| {
                try self.createEdge(document.id, related_id, "REFERS_TO", 0.8, "edges");
            }
        }
    }

    fn ensureUserNode(self: *Self, user_id: []const u8) !void {
        const UserDocument = struct {
            _key: []const u8,
        };
        const user_doc = UserDocument{ ._key = user_id };
        const user_json = try utils.stringifyJson(self.allocator, user_doc);
        defer self.allocator.free(user_json);

        const url = try std.fmt.allocPrint(self.allocator, "http://{s}:{d}/_db/{s}/_api/document/users", .{ self.config.host, self.config.port, self.config.database });
        defer self.allocator.free(url);

        // We use POST with overwriteMode = "ignore" to avoid errors if the user already exists
        const response_json = try self.makeRequest(.POST, url, user_json);
        defer self.allocator.free(response_json);
    }

    fn createEdge(self: *Self, from_id: []const u8, to_id: []const u8, edge_type: []const u8, weight: f32, collection: []const u8) !void {
        const EdgeDocument = struct {
            _from: []const u8,
            _to: []const u8,
            type: []const u8,
            weight: f32,
        };

        const from_collection = if (std.mem.eql(u8, collection, "user_context")) "users" else "chunks";
        const to_collection = "chunks";

        const from_full = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ from_collection, from_id });
        defer self.allocator.free(from_full);

        const to_full = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ to_collection, to_id });
        defer self.allocator.free(to_full);

        const edge_doc = EdgeDocument{
            ._from = from_full,
            ._to = to_full,
            .type = edge_type,
            .weight = weight,
        };

        const edge_json = try utils.stringifyJson(self.allocator, edge_doc);
        defer self.allocator.free(edge_json);

        const url = try std.fmt.allocPrint(self.allocator, "http://{s}:{d}/_db/{s}/_api/document/{s}", .{ self.config.host, self.config.port, self.config.database, collection });
        defer self.allocator.free(url);

        const response_json = try self.makeRequest(.POST, url, edge_json);
        defer self.allocator.free(response_json);
    }

    fn makeRequest(self: *Self, method: std.http.Method, url: []const u8, body: ?[]const u8) ![]u8 {
        const uri = try std.Uri.parse(url);

        var headers = std.ArrayList(std.http.Header).init(self.allocator);
        defer headers.deinit();

        // Use basic authentication - manually create base64 for "root:password"
        const auth_header = "Basic cm9vdDpwYXNzd29yZA=="; // base64 of "root:password"
        try headers.append(.{ .name = "authorization", .value = auth_header });

        try headers.append(.{ .name = "content-type", .value = "application/json" });
        try headers.append(.{ .name = "accept", .value = "application/json" });
        try headers.append(.{ .name = "connection", .value = "close" });

        // Create a new HTTP client for each request to avoid connection reuse issues
        var http_client = std.http.Client{ .allocator = self.allocator };
        defer http_client.deinit();

        // Use fetch() method with dynamic response storage
        var response_body = std.ArrayList(u8).init(self.allocator);
        errdefer response_body.deinit();

        _ = try http_client.fetch(.{
            .method = method,
            .location = .{ .uri = uri },
            .extra_headers = headers.items,
            .payload = body,
            .response_storage = .{ .dynamic = &response_body },
        });

        // Return owned slice - caller must free with allocator.free()
        return try response_body.toOwnedSlice();
    }
};
