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
        defer response.deinit();

        self.auth_token = try self.allocator.dupe(u8, response.value.jwt);
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
        
        var headers = std.ArrayList(std.http.Header).init(self.allocator);
        defer headers.deinit();
        
        if (use_auth and self.auth_token != null) {
            const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.auth_token.?});
            defer self.allocator.free(auth_header);
            try headers.append(.{ .name = "authorization", .value = auth_header });
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