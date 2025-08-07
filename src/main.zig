const std = @import("std");
const zap = @import("zap");
const config = @import("config.zig");
const qdrant = @import("qdrant.zig");
const arango = @import("arango.zig");
const reranker = @import("reranker.zig");
const utils = @import("utils.zig");
const embedding = @import("embedding.zig");

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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try SemanticSearchApp.init(allocator, "config/config.docker.json");
    defer app.deinit();

    const doc_id = "test_doc_user_context";
    const vector = try allocator.alloc(f32, 768);
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

    const query_vector = try allocator.alloc(f32, 768);
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
