const std = @import("std");
const zap = @import("zap");
const config = @import("config.zig");
const qdrant = @import("qdrant.zig");
const arango = @import("arango.zig");
const reranker = @import("reranker.zig");
const utils = @import("utils.zig");
const embedding = @import("embedding.zig");
const conversation = @import("conversation.zig");
const extract = @import("extract.zig");
const llm = @import("llm.zig");

var global_app: *SemanticSearchApp = undefined;

const BackgroundIndexer = struct {
    allocator: std.mem.Allocator,
    app: *SemanticSearchApp,
    running: bool,

    pub fn init(allocator: std.mem.Allocator, app: *SemanticSearchApp) !*BackgroundIndexer {
        const indexer = try allocator.create(BackgroundIndexer);
        indexer.* = .{ .allocator = allocator, .app = app, .running = true };
        return indexer;
    }

    pub fn start(self: *BackgroundIndexer) !void {
        while (self.running) {
            // Simulate processing conversation chunks
            const documents = try self.fetchUnindexedChunks();
            defer {
                for (documents) |doc| doc.deinit(self.allocator);
                self.allocator.free(documents);
            }

            for (documents) |doc| {
                try self.app.ingest(doc);
            }
            std.time.sleep(self.app.config.persistent_memory.indexing_interval * std.time.ns_per_s);
        }
    }

    fn fetchUnindexedChunks(self: *BackgroundIndexer) ![]reranker.Document {
        // Placeholder: Fetch unindexed conversation chunks from a queue or database
        return self.allocator.alloc(reranker.Document, 0);
    }

    pub fn stop(self: *BackgroundIndexer) void {
        self.running = false;
    }
};

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
            // Increment behavior counter for access
            self.arango_client.incrementAccessCount(result.id) catch |e| {
                std.log.warn("incrementAccessCount failed for {s}: {s}", .{ result.id, @errorName(e) });
            };
        }

        // Step 3: Re-rank results
        std.log.info("Re-ranking results...", .{});
        const ranked_results = try reranker.rerank(
            self.allocator,
            vector_results,
            &graph_context,
            self.config,
        );

        return ranked_results;
    }

    pub fn ingest(self: *Self, document: reranker.Document) !void {
        // Store vector in Qdrant
        self.qdrant_client.upsert(document) catch |err| {
            std.log.err("Error upserting to Qdrant: {s}", .{@errorName(err)});
            return err;
        };

        // Store graph relationships in ArangoDB
        self.arango_client.upsertNode(document) catch |err| {
            std.log.err("Error upserting to ArangoDB: {s}", .{@errorName(err)});
            return err;
        };

        std.log.info("Ingested document: {s}", .{document.id});
    }
};

fn startServer(app: *SemanticSearchApp) !void {
    global_app = app;

    var listener = zap.HttpListener.init(.{
        .port = app.config.server.port,
        .on_request = handleRequest,
        .log = true,
    });

    std.log.info("Server listening on port {d}", .{app.config.server.port});
    try listener.listen();

    // start worker threads
    zap.start(.{
        .threads = 2,
        .workers = 2,
    });
}

fn handleRequest(r: zap.Request) !void {
    const app = global_app;
    const path = r.path orelse return error.NoPath;
    const method = r.method orelse return error.NoMethod;

    if (std.mem.eql(u8, path, "/api/llm/generate") and std.mem.eql(u8, method, "POST")) {
        const app2 = app;
        const body = r.body orelse return error.NoBody;

        const LlmRequest = struct {
            prompt: []const u8,
            system: ?[]const u8 = null,
            model: ?[]const u8 = null,
            temperature: ?f32 = null,
        };

        const parsed = utils.parseJson(LlmRequest, app2.allocator, body) catch |err| {
            std.log.err("Error parsing LLM request: {s}", .{@errorName(err)});
            r.setStatus(.bad_request);
            r.sendBody("Bad Request") catch {};
            return;
        };
        defer parsed.deinit();

        var service = llm.LLMService.init(app2.allocator, app2.config.llm);
        defer service.deinit();
        const completion = service.generateCompletion(parsed.value.prompt, parsed.value.system, parsed.value.model, parsed.value.temperature) catch |e| {
            std.log.err("LLM generate failed: {s}", .{@errorName(e)});
            r.setStatus(.bad_request);
            r.sendBody("LLM disabled or failed") catch {};
            return;
        };
        defer app2.allocator.free(completion);

        const resp = std.fmt.allocPrint(app2.allocator, "{{\"completion\": {s}}}", .{try utils.stringifyJson(app2.allocator, completion)}) catch {
            r.setStatus(.internal_server_error);
            r.sendBody("Internal Server Error") catch {};
            return;
        };
        defer app2.allocator.free(resp);
        r.setStatus(.ok);
        r.setHeader("content-type", "application/json") catch {};
        r.sendBody(resp) catch {};
        return;
    }
    // path/method already extracted above

    if (std.mem.eql(u8, path, "/")) {
        serveFile(r, "src/web/index.html", "text/html") catch |err| {
            std.log.err("Error serving index.html: {s}", .{@errorName(err)});
            r.setStatus(.internal_server_error);
            r.sendBody("Internal Server Error") catch {};
        };
        return;
    }

    if (std.mem.startsWith(u8, path, "/static/")) {
        const file_name = path[8..];
        const full_path = std.fmt.allocPrint(app.allocator, "src/web/{s}", .{file_name}) catch |err| {
            std.log.err("Error allocating path: {s}", .{@errorName(err)});
            r.setStatus(.internal_server_error);
            r.sendBody("Internal Server Error") catch {};
            return;
        };
        defer app.allocator.free(full_path);

        const mime = if (std.mem.endsWith(u8, file_name, ".css")) "text/css" else if (std.mem.endsWith(u8, file_name, ".js")) "application/javascript" else "text/plain";
        serveFile(r, full_path, mime) catch |err| {
            std.log.err("Error serving static file: {s}", .{@errorName(err)});
            r.setStatus(.not_found);
            r.sendBody("Not Found") catch {};
        };
        return;
    }

    if (std.mem.eql(u8, path, "/api/text-search") and std.mem.eql(u8, method, "POST")) {
        const body = r.body orelse return error.NoBody;

        const TextSearchRequest = struct {
            query: []const u8,
            limit: ?u32 = null,
            topic_id: ?[]const u8 = null,
            user_id: ?[]const u8 = null,
            context_types: ?[][]const u8 = null,
        };

        const text_search_parsed = utils.parseJson(TextSearchRequest, app.allocator, body) catch |err| {
            std.log.err("Error parsing text search JSON: {s}", .{@errorName(err)});
            r.setStatus(.bad_request);
            r.sendBody("Bad Request") catch {};
            return;
        };
        defer text_search_parsed.deinit();

        std.log.info("Text search query: '{s}'", .{text_search_parsed.value.query});

        // Initialize embedding service
        var embedding_service = embedding.EmbeddingService.init(app.allocator, app.config.embedding);
        defer embedding_service.deinit();

        // Convert text to vector
        const vector = embedding_service.textToVector(text_search_parsed.value.query) catch |err| {
            std.log.err("Failed to convert text to vector: {s}", .{@errorName(err)});
            r.setStatus(.internal_server_error);
            r.sendBody("Internal Server Error") catch {};
            return;
        };
        defer app.allocator.free(vector);

        // Convert context_types strings to enums if provided
        var context_types: ?[]reranker.ContextType = null;
        if (text_search_parsed.value.context_types) |context_strings| {
            context_types = app.allocator.alloc(reranker.ContextType, context_strings.len) catch |err| {
                std.log.err("Failed to allocate context types: {s}", .{@errorName(err)});
                r.setStatus(.internal_server_error);
                r.sendBody("Internal Server Error") catch {};
                return;
            };

            for (context_strings, 0..) |context_str, i| {
                context_types.?[i] = if (std.mem.eql(u8, context_str, "preference"))
                    .preference
                else if (std.mem.eql(u8, context_str, "decision"))
                    .decision
                else if (std.mem.eql(u8, context_str, "observation"))
                    .observation
                else {
                    std.log.err("Invalid context type: {s}", .{context_str});
                    if (context_types) |ct| app.allocator.free(ct);
                    r.setStatus(.bad_request);
                    r.sendBody("Invalid context type") catch {};
                    return;
                };
            }
        }
        defer if (context_types) |ct| app.allocator.free(ct);

        // Create search query
        const search_query = reranker.SearchQuery{
            .vector = vector,
            .limit = text_search_parsed.value.limit,
            .topic_id = text_search_parsed.value.topic_id,
            .user_id = text_search_parsed.value.user_id,
            .context_types = context_types,
            .time_range = null,
            .source_node_id = null,
        };

        const results = app.search(search_query) catch |err| {
            std.log.err("Error searching: {s}", .{@errorName(err)});
            r.setStatus(.internal_server_error);
            r.sendBody("Internal Server Error") catch {};
            return;
        };
        defer {
            for (results) |*result| {
                result.deinit(app.allocator);
            }
            app.allocator.free(results);
        }

        const json = utils.stringifyJson(app.allocator, results) catch |err| {
            std.log.err("Error stringifying JSON: {s}", .{@errorName(err)});
            r.setStatus(.internal_server_error);
            r.sendBody("Internal Server Error") catch {};
            return;
        };
        defer app.allocator.free(json);

        r.setStatus(.ok);
        r.setHeader("content-type", "application/json") catch {};
        r.sendBody(json) catch |err| {
            std.log.err("Error sending response: {s}", .{@errorName(err)});
        };
        return;
    }

    if (std.mem.eql(u8, path, "/api/conversation/search") and std.mem.eql(u8, method, "POST")) {
        const app2 = global_app;
        const body = r.body orelse return error.NoBody;

        // ConversationQuery input format matching LLM Agent Integration Proposal
        const ConversationQueryInput = struct {
            query_text: []const u8,
            session_id: ?[]const u8 = null,
            user_id: ?[]const u8 = null,
            context_types: ?[][]const u8 = null, // String array converted to ContextType enum
            time_range: ?struct { start: i64, end: i64 } = null,
            include_conversation_context: ?bool = null, // New field from proposal
            max_turns: ?u32 = null, // New field from proposal (renamed from limit)
        };

        const parsed = utils.parseJson(ConversationQueryInput, app2.allocator, body) catch |err| {
            std.log.err("Error parsing conversation search: {s}", .{@errorName(err)});
            r.setStatus(.bad_request);
            r.sendBody("Bad Request") catch {};
            return;
        };
        defer parsed.deinit();

        // Embed query text
        var embedding_service = embedding.EmbeddingService.init(app2.allocator, app2.config.embedding);
        defer embedding_service.deinit();
        const vector = embedding_service.textToVector(parsed.value.query_text) catch |err| {
            std.log.err("Embedding failed: {s}", .{@errorName(err)});
            r.setStatus(.internal_server_error);
            r.sendBody("Internal Server Error") catch {};
            return;
        };

        // Convert context types from strings to ContextType enum (from conversation.zig)
        var context_types: ?[]conversation.ContextType = null;
        if (parsed.value.context_types) |context_strings| {
            context_types = app2.allocator.alloc(conversation.ContextType, context_strings.len) catch {
                r.setStatus(.internal_server_error);
                r.sendBody("Internal Server Error") catch {};
                return;
            };
            for (context_strings, 0..) |context_str, i| {
                context_types.?[i] = if (std.mem.eql(u8, context_str, "preference"))
                    .preference
                else if (std.mem.eql(u8, context_str, "decision"))
                    .decision
                else if (std.mem.eql(u8, context_str, "fact"))
                    .fact
                else if (std.mem.eql(u8, context_str, "task"))
                    .task
                else if (std.mem.eql(u8, context_str, "observation"))
                    .observation
                else if (std.mem.eql(u8, context_str, "intent"))
                    .intent
                else if (std.mem.eql(u8, context_str, "emotion"))
                    .emotion
                else if (std.mem.eql(u8, context_str, "goal"))
                    .goal
                else
                    .observation; // Default fallback
            }
        }

        const search_query = reranker.SearchQuery{
            .vector = vector,
            .limit = parsed.value.max_turns orelse 10, // Use max_turns from proposal, default to 10
            .time_range = if (parsed.value.time_range) |tr| reranker.TimeRange{ .start = tr.start, .end = tr.end } else null,
            .topic_id = null,
            .source_node_id = null,
            .user_id = parsed.value.user_id,
            .context_types = context_types,
            .session_id = parsed.value.session_id,
            .tags = null, // Remove tags field since it's not in ConversationQuery proposal
        };

        const results = app2.search(search_query) catch |err| {
            std.log.err("Error searching: {s}", .{@errorName(err)});
            r.setStatus(.internal_server_error);
            r.sendBody("Internal Server Error") catch {};
            return;
        };
        defer {
            for (results) |*result| result.deinit(app2.allocator);
            app2.allocator.free(results);
        }

        const json = utils.stringifyJson(app2.allocator, results) catch {
            r.setStatus(.internal_server_error);
            r.sendBody("Internal Server Error") catch {};
            return;
        };
        defer app2.allocator.free(json);

        r.setStatus(.ok);
        r.setHeader("content-type", "application/json") catch {};
        r.sendBody(json) catch {};
        return;
    }

    if (std.mem.startsWith(u8, path, "/api/conversation/history/") and std.mem.eql(u8, method, "GET")) {
        const app2 = global_app;
        const session_id = path["/api/conversation/history/".len..];
        const json = app2.arango_client.getConversationHistoryJson(session_id, null) catch |err| {
            std.log.err("Error fetching history: {s}", .{@errorName(err)});
            r.setStatus(.internal_server_error);
            r.sendBody("Internal Server Error") catch {};
            return;
        };
        defer app2.allocator.free(json);
        r.setStatus(.ok);
        r.setHeader("content-type", "application/json") catch {};
        r.sendBody(json) catch {};
        return;
    }

    if (std.mem.eql(u8, path, "/api/conversation/related") and std.mem.eql(u8, method, "POST")) {
        const app2 = global_app;
        const body = r.body orelse return error.NoBody;
        const RelatedRequest = struct {
            current_context: []const u8,
            limit: ?u32 = null,
            session_id: ?[]const u8 = null,
            user_id: ?[]const u8 = null,
        };
        const parsed = utils.parseJson(RelatedRequest, app2.allocator, body) catch |err| {
            std.log.err("Error parsing related: {s}", .{@errorName(err)});
            r.setStatus(.bad_request);
            r.sendBody("Bad Request") catch {};
            return;
        };
        defer parsed.deinit();
        var embedding_service = embedding.EmbeddingService.init(app2.allocator, app2.config.embedding);
        defer embedding_service.deinit();
        const vector = embedding_service.textToVector(parsed.value.current_context) catch {
            r.setStatus(.internal_server_error);
            r.sendBody("Internal Server Error") catch {};
            return;
        };
        const search_query = reranker.SearchQuery{
            .vector = vector,
            .limit = parsed.value.limit,
            .time_range = null,
            .topic_id = null,
            .source_node_id = null,
            .user_id = parsed.value.user_id,
            .context_types = null,
            .session_id = parsed.value.session_id,
            .tags = null,
        };
        const results = app2.search(search_query) catch {
            r.setStatus(.internal_server_error);
            r.sendBody("Internal Server Error") catch {};
            return;
        };
        defer {
            for (results) |*result| result.deinit(app2.allocator);
            app2.allocator.free(results);
        }
        const json = utils.stringifyJson(app2.allocator, results) catch {
            r.setStatus(.internal_server_error);
            r.sendBody("Internal Server Error") catch {};
            return;
        };
        defer app2.allocator.free(json);
        r.setStatus(.ok);
        r.setHeader("content-type", "application/json") catch {};
        r.sendBody(json) catch {};
        return;
    }

    if (std.mem.eql(u8, path, "/api/search") and std.mem.eql(u8, method, "POST")) {
        const body = r.body orelse return error.NoBody;

        const query_parsed = utils.parseJson(reranker.SearchQuery, app.allocator, body) catch |err| {
            std.log.err("Error parsing JSON: {s}", .{@errorName(err)});
            r.setStatus(.bad_request);
            r.sendBody("Bad Request") catch {};
            return;
        };
        defer query_parsed.deinit();

        const results = app.search(query_parsed.value) catch |err| {
            std.log.err("Error searching: {s}", .{@errorName(err)});
            r.setStatus(.internal_server_error);
            r.sendBody("Internal Server Error") catch {};
            return;
        };
        defer {
            for (results) |*result| {
                result.deinit(app.allocator);
            }
            app.allocator.free(results);
        }

        const json = utils.stringifyJson(app.allocator, results) catch |err| {
            std.log.err("Error stringifying JSON: {s}", .{@errorName(err)});
            r.setStatus(.internal_server_error);
            r.sendBody("Internal Server Error") catch {};
            return;
        };
        defer app.allocator.free(json);

        r.setStatus(.ok);
        r.setHeader("content-type", "application/json") catch {};
        r.sendBody(json) catch |err| {
            std.log.err("Error sending response: {s}", .{@errorName(err)});
        };
        return;
    }

    if (std.mem.eql(u8, path, "/api/context/extract") and std.mem.eql(u8, method, "POST")) {
        const body = r.body orelse return error.NoBody;

        // Context extraction request format per LLM Agent Integration Proposal
        const ContextExtractionRequest = struct {
            text: []const u8,
            extraction_types: ?[][]const u8 = null, // Optional: ["preference", "decision", "fact", "task", etc.]
        };

        const parsed = utils.parseJson(ContextExtractionRequest, app.allocator, body) catch |err| {
            std.log.err("Error parsing context extraction request: {s}", .{@errorName(err)});
            r.setStatus(.bad_request);
            r.sendBody("Bad Request") catch {};
            return;
        };
        defer parsed.deinit();

        // Convert extraction types from strings to ContextType enum
        var extraction_types: ?[]conversation.ContextType = null;
        if (parsed.value.extraction_types) |type_strings| {
            extraction_types = app.allocator.alloc(conversation.ContextType, type_strings.len) catch {
                r.setStatus(.internal_server_error);
                r.sendBody("Internal Server Error") catch {};
                return;
            };
            for (type_strings, 0..) |type_str, i| {
                extraction_types.?[i] = if (std.mem.eql(u8, type_str, "preference"))
                    .preference
                else if (std.mem.eql(u8, type_str, "decision"))
                    .decision
                else if (std.mem.eql(u8, type_str, "fact"))
                    .fact
                else if (std.mem.eql(u8, type_str, "task"))
                    .task
                else if (std.mem.eql(u8, type_str, "observation"))
                    .observation
                else if (std.mem.eql(u8, type_str, "intent"))
                    .intent
                else if (std.mem.eql(u8, type_str, "emotion"))
                    .emotion
                else if (std.mem.eql(u8, type_str, "goal"))
                    .goal
                else
                    .observation; // Default fallback
            }
        }

        // Perform context extraction using existing extract module
        const extraction_result = extract.extractFromText(app.allocator, parsed.value.text) catch |err| {
            std.log.err("Error extracting context: {s}", .{@errorName(err)});
            r.setStatus(.internal_server_error);
            r.sendBody("Internal Server Error") catch {};
            return;
        };
        defer extraction_result.deinit(app.allocator);

        // Convert extraction result to ConversationExtraction format
        var context_extractions = std.ArrayList(conversation.ContextExtraction).init(app.allocator);
        defer {
            for (context_extractions.items) |*extraction| {
                extraction.deinit(app.allocator);
            }
            context_extractions.deinit();
        }

        // Filter and convert based on requested extraction types
        for (extraction_result.items) |item| {
            // Check if this extraction type is requested (if filter specified)
            const should_include = if (extraction_types) |types| blk: {
                for (types) |req_type| {
                    const item_type: conversation.ContextType = if (std.mem.eql(u8, item.kind, "preference"))
                        .preference
                    else if (std.mem.eql(u8, item.kind, "decision"))
                        .decision
                    else if (std.mem.eql(u8, item.kind, "task"))
                        .task
                    else
                        .observation;

                    if (req_type == item_type) break :blk true;
                }
                break :blk false;
            } else true; // Include all if no filter specified

            if (should_include) {
                const extraction_type: conversation.ContextType = if (std.mem.eql(u8, item.kind, "preference"))
                    .preference
                else if (std.mem.eql(u8, item.kind, "decision"))
                    .decision
                else if (std.mem.eql(u8, item.kind, "task"))
                    .task
                else
                    .observation;

                const context_extraction = conversation.ContextExtraction{
                    .type = extraction_type,
                    .content = try app.allocator.dupe(u8, item.value),
                    .confidence = item.score,
                    .entities = &[_][]const u8{}, // Empty for now - could be enhanced later
                };
                try context_extractions.append(context_extraction);
            }
        }

        // Create response format
        const ContextExtractionResponse = struct {
            extractions: []conversation.ContextExtraction,
        };

        const response = ContextExtractionResponse{
            .extractions = context_extractions.toOwnedSlice() catch {
                r.setStatus(.internal_server_error);
                r.sendBody("Internal Server Error") catch {};
                return;
            },
        };

        const json = utils.stringifyJson(app.allocator, response) catch |err| {
            std.log.err("Error stringifying context extraction response: {s}", .{@errorName(err)});
            r.setStatus(.internal_server_error);
            r.sendBody("Internal Server Error") catch {};
            return;
        };
        defer app.allocator.free(json);

        r.setStatus(.ok);
        r.setHeader("content-type", "application/json") catch {};
        r.sendBody(json) catch |err| {
            std.log.err("Error sending context extraction response: {s}", .{@errorName(err)});
        };
        return;
    }

    // Session Management Endpoints per LLM Agent Integration Proposal

    if (std.mem.startsWith(u8, path, "/api/session/") and std.mem.eql(u8, method, "GET")) {
        // GET /api/session/{session_id} - Get session info
        const session_id = path["/api/session/".len..];

        if (session_id.len == 0) {
            r.setStatus(.bad_request);
            r.sendBody("Session ID required") catch {};
            return;
        }

        // Get session from ArangoDB
        const session_json = app.arango_client.getSessionJson(session_id) catch |err| {
            if (err == arango.ArangoError.DocumentNotFound) {
                r.setStatus(.not_found);
                r.sendBody("{\"error\":\"Session not found\"}") catch {};
                return;
            }
            std.log.err("Error fetching session: {s}", .{@errorName(err)});
            r.setStatus(.internal_server_error);
            r.sendBody("Internal Server Error") catch {};
            return;
        };
        defer app.allocator.free(session_json);

        r.setStatus(.ok);
        r.setHeader("content-type", "application/json") catch {};
        r.sendBody(session_json) catch |err| {
            std.log.err("Error sending session response: {s}", .{@errorName(err)});
        };
        return;
    }

    if (std.mem.eql(u8, path, "/api/session/create") and std.mem.eql(u8, method, "POST")) {
        // POST /api/session/create - Create new agent session
        const body = r.body orelse return error.NoBody;

        const SessionCreateRequest = struct {
            agent_id: []const u8,
            user_id: ?[]const u8 = null,
            session_summary: ?[]const u8 = null,
            preferences: ?std.json.Value = null,
        };

        const parsed = utils.parseJson(SessionCreateRequest, app.allocator, body) catch |err| {
            std.log.err("Error parsing session create request: {s}", .{@errorName(err)});
            r.setStatus(.bad_request);
            r.sendBody("Bad Request") catch {};
            return;
        };
        defer parsed.deinit();

        // Generate session ID
        const timestamp = std.time.timestamp();
        const hash = std.hash.Wyhash.hash(0, std.mem.asBytes(&timestamp));
        const session_id = try std.fmt.allocPrint(app.allocator, "session_{d}_{x}", .{ timestamp, @as(u32, @truncate(hash)) });
        defer app.allocator.free(session_id);

        // Create AgentSession struct
        const new_session = conversation.AgentSession{
            .session_id = try app.allocator.dupe(u8, session_id),
            .agent_id = try app.allocator.dupe(u8, parsed.value.agent_id),
            .user_id = if (parsed.value.user_id) |uid| try app.allocator.dupe(u8, uid) else null,
            .created_at = timestamp,
            .last_active = timestamp,
            .conversation_turns = &[_][]const u8{}, // Empty initially
            .session_summary = if (parsed.value.session_summary) |summary| try app.allocator.dupe(u8, summary) else null,
            .preferences = parsed.value.preferences orelse std.json.Value{ .object = std.json.ObjectMap.init(app.allocator) },
        };

        // Save session to ArangoDB
        app.arango_client.saveSession(new_session) catch |err| {
            std.log.err("Error saving session: {s}", .{@errorName(err)});
            // Clean up allocated memory
            new_session.deinit(app.allocator);
            r.setStatus(.internal_server_error);
            r.sendBody("Internal Server Error") catch {};
            return;
        };

        // Create response
        const SessionCreateResponse = struct {
            session_id: []const u8,
            agent_id: []const u8,
            user_id: ?[]const u8,
            created_at: i64,
        };

        const response = SessionCreateResponse{
            .session_id = new_session.session_id,
            .agent_id = new_session.agent_id,
            .user_id = new_session.user_id,
            .created_at = new_session.created_at,
        };

        const json = utils.stringifyJson(app.allocator, response) catch |err| {
            std.log.err("Error stringifying session create response: {s}", .{@errorName(err)});
            new_session.deinit(app.allocator);
            r.setStatus(.internal_server_error);
            r.sendBody("Internal Server Error") catch {};
            return;
        };
        defer app.allocator.free(json);

        // Clean up session memory after response is serialized
        new_session.deinit(app.allocator);

        r.setStatus(.ok);
        r.setHeader("content-type", "application/json") catch {};
        r.sendBody(json) catch |err| {
            std.log.err("Error sending session create response: {s}", .{@errorName(err)});
        };
        return;
    }

    if (std.mem.startsWith(u8, path, "/api/session/") and std.mem.endsWith(u8, path, "/preferences") and std.mem.eql(u8, method, "PUT")) {
        // PUT /api/session/{session_id}/preferences - Update session preferences
        const session_path = path["/api/session/".len..];
        const preferences_suffix = "/preferences";

        if (session_path.len <= preferences_suffix.len) {
            r.setStatus(.bad_request);
            r.sendBody("Invalid session ID") catch {};
            return;
        }

        const session_id = session_path[0 .. session_path.len - preferences_suffix.len];
        const body = r.body orelse return error.NoBody;

        const PreferencesUpdateRequest = struct {
            preferences: std.json.Value,
        };

        const parsed = utils.parseJson(PreferencesUpdateRequest, app.allocator, body) catch |err| {
            std.log.err("Error parsing preferences update request: {s}", .{@errorName(err)});
            r.setStatus(.bad_request);
            r.sendBody("Bad Request") catch {};
            return;
        };
        defer parsed.deinit();

        // Update session preferences in ArangoDB
        app.arango_client.updateSessionPreferences(session_id, parsed.value.preferences) catch |err| {
            if (err == arango.ArangoError.DocumentNotFound) {
                r.setStatus(.not_found);
                r.sendBody("{\"error\":\"Session not found\"}") catch {};
                return;
            }
            std.log.err("Error updating session preferences: {s}", .{@errorName(err)});
            r.setStatus(.internal_server_error);
            r.sendBody("Internal Server Error") catch {};
            return;
        };

        r.setStatus(.ok);
        r.setHeader("content-type", "application/json") catch {};
        r.sendBody("{\"status\":\"preferences updated\"}") catch |err| {
            std.log.err("Error sending preferences update response: {s}", .{@errorName(err)});
        };
        return;
    }

    if (std.mem.eql(u8, path, "/api/health") and std.mem.eql(u8, method, "GET")) {
        r.setStatus(.ok);
        r.setHeader("content-type", "application/json") catch {};
        r.sendBody("{\"status\":\"ok\"}") catch |err| {
            std.log.err("Error sending health response: {s}", .{@errorName(err)});
        };
        return;
    }

    if (std.mem.eql(u8, path, "/api/ingest") and std.mem.eql(u8, method, "POST")) {
        const body = r.body orelse return error.NoBody;

        const json_doc_parsed = utils.parseJson(reranker.DocumentJson, app.allocator, body) catch |err| {
            std.log.err("Error parsing JSON: {s}", .{@errorName(err)});
            r.setStatus(.bad_request);
            r.sendBody("Bad Request") catch {};
            return;
        };
        defer json_doc_parsed.deinit();

        const document = reranker.Document.fromJson(app.allocator, json_doc_parsed.value) catch |err| {
            std.log.err("Error converting document: {s}", .{@errorName(err)});
            r.setStatus(.internal_server_error);
            r.sendBody("Internal Server Error") catch {};
            return;
        };
        defer document.deinit(app.allocator);

        app.ingest(document) catch |err| {
            std.log.err("Error ingesting document '{s}': {s}", .{ document.id, @errorName(err) });
            r.setStatus(.internal_server_error);
            const error_msg = try std.fmt.allocPrint(app.allocator, "{{\"error\": \"{s}\", \"details\": \"Failed to ingest document\"}}", .{@errorName(err)});
            defer app.allocator.free(error_msg);
            r.setHeader("content-type", "application/json") catch {};
            r.sendBody(error_msg) catch |send_err| {
                std.log.err("Error sending error response: {s}", .{@errorName(send_err)});
            };
            return;
        };

        const response_json = "{\"status\": \"ok\"}";
        r.setStatus(.ok);
        r.setHeader("content-type", "application/json") catch {};
        r.sendBody(response_json) catch |err| {
            std.log.err("Error sending response: {s}", .{@errorName(err)});
        };
        return;
    }

    if (std.mem.eql(u8, path, "/api/conversation/save") and std.mem.eql(u8, method, "POST")) {
        const body = r.body orelse return error.NoBody;

        // ConversationTurn input format matching LLM Agent Integration Proposal
        const ConversationTurnInput = struct {
            id: ?[]const u8 = null, // Auto-generate if not provided
            session_id: []const u8,
            turn_number: ?u32 = null, // Auto-increment if not provided
            timestamp: ?i64 = null, // Auto-generate if not provided
            user_message: []const u8, // REQUIRED per proposal
            assistant_message: []const u8, // REQUIRED per proposal
            importance_score: ?f32 = null, // Default to 0.5 if not provided
            tags: ?[][]const u8 = null, // Default to empty if not provided
            user_id: ?[]const u8 = null, // Optional
            metadata: ?std.json.Value = null, // Optional
        };

        const parsed = utils.parseJson(ConversationTurnInput, app.allocator, body) catch |err| {
            std.log.err("Error parsing conversation turn: {s}", .{@errorName(err)});
            r.setStatus(.bad_request);
            r.sendBody("Bad Request") catch {};
            return;
        };
        defer parsed.deinit();

        // Generate defaults for optional fields
        const turn_id = parsed.value.id orelse blk: {
            const timestamp = std.time.timestamp();
            const hash = std.hash.Wyhash.hash(0, std.mem.asBytes(&timestamp));
            break :blk try std.fmt.allocPrint(app.allocator, "turn_{d}_{x}", .{ timestamp, @as(u32, @truncate(hash)) });
        };
        defer if (parsed.value.id == null) app.allocator.free(turn_id);

        const timestamp = parsed.value.timestamp orelse std.time.timestamp();
        const importance_score = parsed.value.importance_score orelse 0.5;

        // Handle tags - ensure we have a non-null array with proper type
        const tags: ?[][]const u8 = if (parsed.value.tags) |input_tags| input_tags else null;

        // Build content for embedding (concat user/assistant messages)
        var content_builder = std.ArrayList(u8).init(app.allocator);
        defer content_builder.deinit();
        try content_builder.appendSlice(parsed.value.user_message);
        try content_builder.appendSlice("\n");
        try content_builder.appendSlice(parsed.value.assistant_message);
        const content = content_builder.toOwnedSlice() catch |err| {
            std.log.err("Alloc content failed: {s}", .{@errorName(err)});
            r.setStatus(.internal_server_error);
            r.sendBody("Internal Server Error") catch {};
            return;
        };
        defer app.allocator.free(content);

        var embedding_service = embedding.EmbeddingService.init(app.allocator, app.config.embedding);
        defer embedding_service.deinit();
        const vector = embedding_service.textToVector(content) catch |err| {
            std.log.err("Embedding failed: {s}", .{@errorName(err)});
            r.setStatus(.internal_server_error);
            r.sendBody("Internal Server Error") catch {};
            return;
        };

        const document = reranker.Document{
            .id = turn_id,
            .vector = vector,
            .timestamp = timestamp,
            .content = content,
            .topic_id = null,
            .related_documents = null,
            .user_id = parsed.value.user_id,
            .context_type = .observation,
            .metadata = null,
            .session_id = parsed.value.session_id,
            .turn_number = parsed.value.turn_number,
            .role = null, // Remove deprecated role field
            .importance_score = importance_score,
            .tags = tags,
        };
        // ownership of vector/content is moved into ingest

        // Optional lightweight extraction if enabled: adjust importance and persist artifacts
        if (app.config.conversation_memory.auto_extract_context) {
            const ex = extract.extractFromText(app.allocator, content) catch null;
            if (ex) |res| {
                if (document.importance_score == null or res.importance_score > document.importance_score.?) {
                    // SAFETY: mutate local variable before ingest
                    @constCast(&document).importance_score = res.importance_score;
                }
                // Persist extractions and tag edges
                // Note: we first persist the turn (ingest) to ensure turn exists, then persist extractions
                res.deinit(app.allocator);
            }
        }

        app.ingest(document) catch |err| {
            std.log.err("Error saving conversation turn: {s}", .{@errorName(err)});
            r.setStatus(.internal_server_error);
            r.sendBody("Internal Server Error") catch {};
            return;
        };

        // After ingest, run extraction again to persist artifacts (cheap re-run)
        if (app.config.conversation_memory.auto_extract_context) {
            const ex2 = extract.extractFromText(app.allocator, content) catch null;
            if (ex2) |res2| {
                // Persist items as context_extractions
                for (res2.items) |item| {
                    app.arango_client.persistExtraction(turn_id, item.kind, item.value) catch |e| {
                        std.log.warn("persistExtraction failed: {s}", .{@errorName(e)});
                    };
                }
                res2.deinit(app.allocator);
            }
        }

        const resp = std.fmt.allocPrint(app.allocator, "{{\"turn_id\":\"{s}\"}}", .{turn_id}) catch {
            r.setStatus(.ok);
            r.setHeader("content-type", "application/json") catch {};
            r.sendBody("{\"status\":\"ok\"}") catch {};
            return;
        };
        defer app.allocator.free(resp);
        r.setStatus(.ok);
        r.setHeader("content-type", "application/json") catch {};
        r.sendBody(resp) catch {};
        return;
    }

    r.setStatus(.not_found);
    r.sendBody("Not Found") catch |err| {
        std.log.err("Error sending 404: {s}", .{@errorName(err)});
    };
}

fn serveFile(r: zap.Request, file_path: []const u8, content_type: []const u8) !void {
    const app = global_app;
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const stat = try file.stat();
    const content = try app.allocator.alloc(u8, stat.size);
    defer app.allocator.free(content);
    _ = try file.readAll(content);

    r.setStatus(.ok);
    r.setHeader("content-type", content_type) catch {};
    r.sendBody(content) catch |err| {
        std.log.err("Error sending file content: {s}", .{@errorName(err)});
    };
}

fn waitForServices(app: *SemanticSearchApp) !void {
    const max_retries = 30; // 30 retries = ~5 minutes with 10s delays
    const retry_delay_ms = 10000; // 10 seconds

    std.log.info("Waiting for Qdrant to be ready...", .{});
    var qdrant_ready = false;
    for (0..max_retries) |attempt| {
        if (app.qdrant_client.healthCheck()) {
            qdrant_ready = true;
            std.log.info("Qdrant is ready!", .{});
            break;
        } else |_| {
            if (attempt < max_retries - 1) {
                std.log.info("Qdrant not ready (attempt {}/{}), waiting 10s...", .{ attempt + 1, max_retries });
                std.time.sleep(retry_delay_ms * std.time.ns_per_ms);
            }
        }
    }

    if (!qdrant_ready) {
        std.log.err("Qdrant failed to become ready after {} attempts", .{max_retries});
        return error.ServiceNotReady;
    }

    std.log.info("Waiting for ArangoDB to be ready...", .{});
    var arango_ready = false;
    for (0..max_retries) |attempt| {
        if (app.arango_client.healthCheck()) {
            arango_ready = true;
            std.log.info("ArangoDB is ready!", .{});
            break;
        } else |_| {
            if (attempt < max_retries - 1) {
                std.log.info("ArangoDB not ready (attempt {}/{}), waiting 10s...", .{ attempt + 1, max_retries });
                std.time.sleep(retry_delay_ms * std.time.ns_per_ms);
            }
        }
    }

    if (!arango_ready) {
        std.log.err("ArangoDB failed to become ready after {} attempts", .{max_retries});
        return error.ServiceNotReady;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.log.err("Usage: {s} <command> [args...]", .{args[0]});
        std.log.err("Commands:", .{});
        std.log.err("  search <query.json>", .{});
        std.log.err("  ingest <document.json>", .{});
        return;
    }

    var app = try SemanticSearchApp.init(allocator, "config/config.docker.json");
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
        defer query.deinit();

        const results = try app.search(query.value);
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

        const json_document = try utils.parseJson(reranker.DocumentJson, allocator, doc_json);
        defer json_document.deinit();

        const document = try reranker.Document.fromJson(allocator, json_document.value);
        defer document.deinit(allocator);

        try app.ingest(document);
        std.log.info("Document ingested successfully", .{});
    } else if (std.mem.eql(u8, command, "setup")) {
        std.log.info("Setting up databases...", .{});

        // Use ArenaAllocator for the entire setup operation to eliminate any memory leaks
        var setup_arena = std.heap.ArenaAllocator.init(allocator);
        defer setup_arena.deinit(); // All setup memory freed at once
        const setup_allocator = setup_arena.allocator();

        // Create setup-specific app instance with arena allocator
        var setup_app = try SemanticSearchApp.init(setup_allocator, "config/config.docker.json");
        // Note: We don't call deinit() on setup_app since arena.deinit() handles everything

        // Wait for services to be ready with retry logic
        try waitForServices(&setup_app);

        // Initialize Qdrant collection
        try setup_app.qdrant_client.initCollection();
        std.log.info("Qdrant collection 'semantic_chunks' created successfully", .{});

        // Initialize ArangoDB collections
        try setup_app.arango_client.initCollections();
        std.log.info("ArangoDB collections and indexes initialized successfully", .{});

        std.log.info("Database setup completed successfully", .{});
    } else if (std.mem.eql(u8, command, "server")) {
        var indexer = try BackgroundIndexer.init(allocator, &app);
        const indexer_thread = try std.Thread.spawn(.{}, BackgroundIndexer.start, .{indexer});
        defer indexer.stop();
        defer indexer_thread.join();

        try startServer(&app);
    } else {
        std.log.err("Unknown command: {s}", .{command});
        return;
    }
}

test "ingest and retrieve user context" {
    // Skip integration test unless explicitly enabled
    const want = std.process.hasEnvVar(std.heap.page_allocator, "RUN_INTEGRATION_TESTS") catch false;
    if (!want) return;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try SemanticSearchApp.init(allocator, "config/config.docker.json");
    defer app.deinit();

    const doc_id = "test_doc_user_context";
    const vector = try allocator.alloc(f32, 8);
    defer allocator.free(vector);
    @memset(vector, 0.1);

    const document = reranker.Document{
        .id = doc_id,
        .vector = vector,
        .timestamp = std.time.timestamp(),
        .user_id = "user_123",
        .context_type = .preference,
    };
    // No deinit, since we are passing ownership to ingest

    try app.ingest(document);

    const query_vector = try allocator.alloc(f32, 8);
    defer allocator.free(query_vector);
    @memset(query_vector, 0.1);

    const query = reranker.SearchQuery{
        .vector = query_vector,
        .user_id = "user_123",
        .context_types = &[_]reranker.ContextType{.preference},
    };
    // No deinit, since we are passing ownership to search

    const results = try app.search(query);
    defer {
        for (results) |result| result.deinit(allocator);
        allocator.free(results);
    }

    try std.testing.expect(results.len > 0);
    var found = false;
    for (results) |result| {
        if (std.mem.eql(u8, result.id, doc_id)) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}
