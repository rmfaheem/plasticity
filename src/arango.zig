const std = @import("std");
const utils = @import("utils.zig");
const config = @import("config.zig");
const reranker = @import("reranker.zig");
const conversation = @import("conversation.zig");

// ArangoDB specific errors
pub const ArangoError = error{
    DocumentNotFound,
    DocumentConflict,
    ConnectionFailed,
    InvalidResponse,
};

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
        const collections = [_][]const u8{ "chunks", "edges", "users", "user_context", "conversation_turns", "agent_sessions", "session_edges", "topics", "context_extractions" };
        const collection_types = [_]u32{ 2, 3, 2, 3, 2, 2, 3, 2, 2 }; // 2 = document, 3 = edge

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
            .{ .collection = "conversation_turns", .fields = &[_][]const u8{ "session_id", "turn_number", "timestamp" } },
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

        const query = "FOR v, e IN 1..2 ANY @node_id edges, user_context RETURN { neighbor: v._key, weight: (e.type==\"FOLLOWS_TURN\" ? 1.5 : (e.weight || 1.0)), type: e.type }";

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

    pub fn incrementAccessCount(self: *Self, node_id: []const u8) !void {
        // Increment access_count in chunks, then in conversation_turns (one will be a no-op if key not found)
        const UpdateReq = struct { query: []const u8, bindVars: struct { id: []const u8 } };
        const url = try std.fmt.allocPrint(self.allocator, "http://{s}:{d}/_db/{s}/_api/cursor", .{ self.config.host, self.config.port, self.config.database });
        defer self.allocator.free(url);

        const aql_chunks = "FOR d IN chunks FILTER d._key==@id UPDATE d WITH { access_count: (d.access_count || 0) + 1 } IN chunks";
        const req_chunks = UpdateReq{ .query = aql_chunks, .bindVars = .{ .id = node_id } };
        const body_chunks = try utils.stringifyJson(self.allocator, req_chunks);
        defer self.allocator.free(body_chunks);
        _ = self.makeRequest(.POST, url, body_chunks) catch {};

        const aql_turns = "FOR d IN conversation_turns FILTER d._key==@id UPDATE d WITH { access_count: (d.access_count || 0) + 1 } IN conversation_turns";
        const req_turns = UpdateReq{ .query = aql_turns, .bindVars = .{ .id = node_id } };
        const body_turns = try utils.stringifyJson(self.allocator, req_turns);
        defer self.allocator.free(body_turns);
        _ = self.makeRequest(.POST, url, body_turns) catch {};
    }

    pub fn getConversationHistoryJson(self: *Self, session_id: []const u8, limit: ?u32) ![]u8 {
        const QueryRequest = struct {
            query: []const u8,
            bindVars: struct {
                sid: []const u8,
                lim: u32,
            },
        };

        const aql =
            "FOR d IN conversation_turns " ++
            "FILTER d.session_id == @sid " ++
            "SORT d.turn_number ASC, d.timestamp ASC " ++
            "LIMIT @lim " ++
            "RETURN { id: d._key, session_id: d.session_id, turn_number: d.turn_number, timestamp: d.timestamp, role: d.role, content: d.content, user_id: d.user_id, importance_score: d.importance_score, tags: d.tags }";

        const q = QueryRequest{
            .query = aql,
            .bindVars = .{ .sid = session_id, .lim = limit orelse 1000 },
        };

        const request_json = try utils.stringifyJson(self.allocator, q);
        defer self.allocator.free(request_json);

        const url = try std.fmt.allocPrint(self.allocator, "http://{s}:{d}/_db/{s}/_api/cursor", .{ self.config.host, self.config.port, self.config.database });
        defer self.allocator.free(url);

        const response_json = try self.makeRequest(.POST, url, request_json);
        // We will parse only to extract `result`
        const CursorResponse = struct { result: []std.json.Value };
        const parsed = utils.parseJson(CursorResponse, self.allocator, response_json) catch |err| {
            self.allocator.free(response_json);
            return err;
        };
        defer parsed.deinit();
        self.allocator.free(response_json);

        // Stringify the result array to return as JSON
        const out_json = try utils.stringifyJson(self.allocator, parsed.value.result);
        return out_json;
    }

    pub fn upsertNode(self: *Self, document: reranker.Document) !void {
        // if (self.auth_token == null) { // This line is removed
        //     try self.authenticate(); // This line is removed
        // }

        // If this is a conversation turn, store in conversation_turns; else in chunks
        const is_conversation = document.session_id != null;
        if (is_conversation) {
            const TurnDoc = struct {
                _key: []const u8,
                session_id: []const u8,
                turn_number: ?u32 = null,
                timestamp: i64,
                role: ?[]const u8 = null,
                content: ?[]const u8 = null,
                user_id: ?[]const u8 = null,
                importance_score: ?f32 = null,
                tags: ?[][]const u8 = null,
            };

            const turn_doc = TurnDoc{
                ._key = document.id,
                .session_id = document.session_id.?,
                .turn_number = document.turn_number,
                .timestamp = document.timestamp,
                .role = document.role,
                .content = document.content,
                .user_id = document.user_id,
                .importance_score = document.importance_score,
                .tags = document.tags,
            };
            const turn_json = try utils.stringifyJson(self.allocator, turn_doc);
            defer self.allocator.free(turn_json);
            const turn_url = try std.fmt.allocPrint(self.allocator, "http://{s}:{d}/_db/{s}/_api/document/conversation_turns", .{ self.config.host, self.config.port, self.config.database });
            defer self.allocator.free(turn_url);
            const turn_resp = try self.makeRequest(.POST, turn_url, turn_json);
            defer self.allocator.free(turn_resp);

            // Ensure session node
            const SessionDoc = struct { _key: []const u8 };
            const session_doc = SessionDoc{ ._key = document.session_id.? };
            const session_json = try utils.stringifyJson(self.allocator, session_doc);
            defer self.allocator.free(session_json);
            const session_url = try std.fmt.allocPrint(self.allocator, "http://{s}:{d}/_db/{s}/_api/document/agent_sessions", .{ self.config.host, self.config.port, self.config.database });
            defer self.allocator.free(session_url);
            const session_resp = try self.makeRequest(.POST, session_url, session_json);
            defer self.allocator.free(session_resp);

            // PART_OF_SESSION edge (turn -> session)
            try self.createEdgeCustom("conversation_turns", document.id, "agent_sessions", document.session_id.?, "PART_OF_SESSION", 1.0, "session_edges");

            // FOLLOWS_TURN edge if previous exists
            if (document.turn_number) |tn| {
                if (tn > 1) {
                    const prev_id = try std.fmt.allocPrint(self.allocator, "{s}_turn_{d}", .{ document.session_id.?, tn - 1 });
                    defer self.allocator.free(prev_id);
                    try self.createEdgeCustom("conversation_turns", prev_id, "conversation_turns", document.id, "FOLLOWS_TURN", 1.0, "session_edges");
                }
            }

            // USER_OF_SESSION edge
            if (document.user_id) |uid| {
                try self.ensureUserNode(uid);
                try self.createEdgeCustom("users", uid, "agent_sessions", document.session_id.?, "USER_OF_SESSION", 1.0, "session_edges");
            }

            // HAS_TOPIC edges from tags (create topic docs)
            if (document.tags) |ts| {
                for (ts) |tag| {
                    const topic_doc = struct { _key: []const u8 }{ ._key = tag };
                    const topic_json = try utils.stringifyJson(self.allocator, topic_doc);
                    defer self.allocator.free(topic_json);
                    const topic_url = try std.fmt.allocPrint(self.allocator, "http://{s}:{d}/_db/{s}/_api/document/topics", .{ self.config.host, self.config.port, self.config.database });
                    defer self.allocator.free(topic_url);
                    const topic_resp = try self.makeRequest(.POST, topic_url, topic_json);
                    defer self.allocator.free(topic_resp);
                    try self.createEdgeCustom("conversation_turns", document.id, "topics", tag, "HAS_TOPIC", 1.0, "edges");
                }
            }

            // Future: persist extraction artifacts here (context_extractions + EXTRACTS_TO)
        } else {
            // Create/update the document node in chunks
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
        }

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

    fn createEdgeCustom(self: *Self, from_collection: []const u8, from_id: []const u8, to_collection: []const u8, to_id: []const u8, edge_type: []const u8, weight: f32, collection: []const u8) !void {
        const EdgeDocument = struct {
            _from: []const u8,
            _to: []const u8,
            type: []const u8,
            weight: f32,
        };

        const from_full = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ from_collection, from_id });
        defer self.allocator.free(from_full);
        const to_full = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ to_collection, to_id });
        defer self.allocator.free(to_full);

        const edge_doc = EdgeDocument{ ._from = from_full, ._to = to_full, .type = edge_type, .weight = weight };
        const edge_json = try utils.stringifyJson(self.allocator, edge_doc);
        defer self.allocator.free(edge_json);
        const url = try std.fmt.allocPrint(self.allocator, "http://{s}:{d}/_db/{s}/_api/document/{s}", .{ self.config.host, self.config.port, self.config.database, collection });
        defer self.allocator.free(url);
        const response_json = try self.makeRequest(.POST, url, edge_json);
        defer self.allocator.free(response_json);
    }

    pub fn persistExtraction(self: *Self, turn_id: []const u8, kind: []const u8, value: []const u8) !void {
        const ExtractionDoc = struct {
            _key: []const u8,
            kind: []const u8,
            value: []const u8,
        };

        // Build stable key from turn_id + kind + hash(value)
        const key_base = try std.fmt.allocPrint(self.allocator, "{s}:{s}:", .{ turn_id, kind });
        defer self.allocator.free(key_base);
        var hasher = std.hash.Fnv1a_64.init();
        hasher.update(value);
        const hash_val = hasher.final();
        const key = try std.fmt.allocPrint(self.allocator, "{s}{d}", .{ key_base, hash_val });
        defer self.allocator.free(key);

        const doc = ExtractionDoc{ ._key = key, .kind = kind, .value = value };
        const json_body = try utils.stringifyJson(self.allocator, doc);
        defer self.allocator.free(json_body);

        const url = try std.fmt.allocPrint(self.allocator, "http://{s}:{d}/_db/{s}/_api/document/context_extractions", .{ self.config.host, self.config.port, self.config.database });
        defer self.allocator.free(url);
        const resp = try self.makeRequest(.POST, url, json_body);
        defer self.allocator.free(resp);

        try self.createEdgeCustom("conversation_turns", turn_id, "context_extractions", key, "EXTRACTS_TO", 1.0, "edges");
    }

    // Session management methods per LLM Agent Integration Proposal

    pub fn saveSession(self: *Self, session: conversation.AgentSession) !void {
        // Create session document for ArangoDB
        const SessionDoc = struct {
            _key: []const u8,
            session_id: []const u8,
            agent_id: []const u8,
            user_id: ?[]const u8,
            created_at: i64,
            last_active: i64,
            conversation_turns: []const []const u8,
            session_summary: ?[]const u8,
            preferences: std.json.Value,
        };

        const doc = SessionDoc{
            ._key = session.session_id,
            .session_id = session.session_id,
            .agent_id = session.agent_id,
            .user_id = session.user_id,
            .created_at = session.created_at,
            .last_active = session.last_active,
            .conversation_turns = session.conversation_turns,
            .session_summary = session.session_summary,
            .preferences = session.preferences,
        };

        const json_body = try utils.stringifyJson(self.allocator, doc);
        defer self.allocator.free(json_body);

        const url = try std.fmt.allocPrint(self.allocator, "http://{s}:{d}/_db/{s}/_api/document/agent_sessions", .{ self.config.host, self.config.port, self.config.database });
        defer self.allocator.free(url);

        const resp = try self.makeRequest(.POST, url, json_body);
        defer self.allocator.free(resp);
    }

    pub fn getSessionJson(self: *Self, session_id: []const u8) ![]u8 {
        const url = try std.fmt.allocPrint(self.allocator, "http://{s}:{d}/_db/{s}/_api/document/agent_sessions/{s}", .{ self.config.host, self.config.port, self.config.database, session_id });
        defer self.allocator.free(url);

        const response_json = self.makeRequest(.GET, url, null) catch |err| {
            if (err == error.HttpStatus404) {
                return ArangoError.DocumentNotFound;
            }
            return err;
        };

        // Parse the response to extract just the document data (without _id, _rev, etc.)
        const DocumentResponse = struct {
            session_id: []const u8,
            agent_id: []const u8,
            user_id: ?[]const u8,
            created_at: i64,
            last_active: i64,
            conversation_turns: []const []const u8,
            session_summary: ?[]const u8,
            preferences: std.json.Value,
        };

        const parsed = utils.parseJson(DocumentResponse, self.allocator, response_json) catch |err| {
            self.allocator.free(response_json);
            return err;
        };
        defer parsed.deinit();
        self.allocator.free(response_json);

        // Return clean JSON without ArangoDB metadata
        const clean_json = try utils.stringifyJson(self.allocator, parsed.value);
        return clean_json;
    }

    pub fn updateSessionPreferences(self: *Self, session_id: []const u8, new_preferences: std.json.Value) !void {
        const UpdateDoc = struct {
            preferences: std.json.Value,
            last_active: i64,
        };

        const update_doc = UpdateDoc{
            .preferences = new_preferences,
            .last_active = std.time.timestamp(),
        };

        const json_body = try utils.stringifyJson(self.allocator, update_doc);
        defer self.allocator.free(json_body);

        const url = try std.fmt.allocPrint(self.allocator, "http://{s}:{d}/_db/{s}/_api/document/agent_sessions/{s}", .{ self.config.host, self.config.port, self.config.database, session_id });
        defer self.allocator.free(url);

        const resp = self.makeRequest(.PATCH, url, json_body) catch |err| {
            if (err == error.HttpStatus404) {
                return ArangoError.DocumentNotFound;
            }
            return err;
        };
        defer self.allocator.free(resp);
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
