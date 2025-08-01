const std = @import("std");
const zap = @import("zap");
const config = @import("config.zig");
const qdrant = @import("qdrant.zig");
const arango = @import("arango.zig");
const reranker = @import("reranker.zig");
const utils = @import("utils.zig");

var global_app: *SemanticSearchApp = undefined;

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

fn startServer(app: *SemanticSearchApp) !void {
    global_app = app;

    var listener = zap.HttpListener.init(.{
        .port = app.config.server.port,
        .on_request = handleRequest,
        .log = true,
    });

    std.log.info("Server listening on port {d}", .{app.config.server.port});
    try listener.listen();

    std.debug.print("Listening on 0.0.0.0:3000\n", .{});

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

    if (std.mem.eql(u8, path, "/api/ingest") and std.mem.eql(u8, method, "POST")) {
        const body = r.body orelse return error.NoBody;

        const doc_parsed = utils.parseJson(reranker.Document, app.allocator, body) catch |err| {
            std.log.err("Error parsing JSON: {s}", .{@errorName(err)});
            r.setStatus(.bad_request);
            r.sendBody("Bad Request") catch {};
            return;
        };
        defer doc_parsed.deinit();

        app.ingest(doc_parsed.value) catch |err| {
            std.log.err("Error ingesting: {s}", .{@errorName(err)});
            r.setStatus(.internal_server_error);
            r.sendBody("Internal Server Error") catch {};
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

        const document = try utils.parseJson(reranker.Document, allocator, doc_json);
        defer document.deinit();

        try app.ingest(document.value);
        std.log.info("Document ingested successfully", .{});
    } else if (std.mem.eql(u8, command, "server")) {
        try startServer(&app);
    } else {
        std.log.err("Unknown command: {s}", .{command});
        return;
    }
}
