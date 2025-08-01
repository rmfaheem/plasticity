const std = @import("std");
const net = std.net;
const json = std.json;
const SemanticSearchApp = @import("main.zig").SemanticSearchApp;
const reranker = @import("reranker.zig");
const utils = @import("utils.zig");

const WebServer = struct {
    allocator: std.mem.Allocator,
    app: *SemanticSearchApp,
    server: net.StreamServer,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, app: *SemanticSearchApp) !Self {
        return Self{
            .allocator = allocator,
            .app = app,
            .server = net.StreamServer.init(.{}),
        };
    }

    pub fn deinit(self: *Self) void {
        self.server.deinit();
    }

    pub fn start(self: *Self, port: u16) !void {
        const address = try net.Address.parseIp("0.0.0.0", port);
        try self.server.listen(address);

        std.log.info("Web server started on http://localhost:{d}", .{port});

        while (true) {
            const connection = try self.server.accept();
            const thread = try std.Thread.spawn(.{}, handleConnection, .{ self, connection });
            thread.detach();
        }
    }

    fn handleConnection(self: *Self, connection: net.StreamServer.Connection) void {
        defer connection.stream.close();

        var buffer: [4096]u8 = undefined;
        const bytes_read = connection.stream.read(&buffer) catch |err| {
            std.log.err("Failed to read request: {}", .{err});
            return;
        };

        if (bytes_read == 0) return;

        const request = buffer[0..bytes_read];
        const response = self.handleRequest(request) catch |err| blk: {
            std.log.err("Error handling request: {}", .{err});
            break :blk internalServerError();
        };

        _ = connection.stream.write(response) catch |err| {
            std.log.err("Failed to write response: {}", .{err});
            return;
        };
    }

    fn handleRequest(self: *Self, request: []const u8) ![]const u8 {
        var lines = std.mem.tokenize(u8, request, "\r\n");
        const first_line = lines.next() orelse return badRequest();

        var parts = std.mem.tokenize(u8, first_line, " ");
        const method = parts.next() orelse return badRequest();
        const path = parts.next() orelse return badRequest();

        if (std.mem.eql(u8, method, "GET")) {
            if (std.mem.eql(u8, path, "/")) {
                return serveIndexHtml();
            } else if (std.mem.eql(u8, path, "/api/health")) {
                return serveHealthCheck();
            } else if (std.mem.startsWith(u8, path, "/static/")) {
                return serveStaticFile(path);
            }
        } else if (std.mem.eql(u8, method, "POST")) {
            if (std.mem.eql(u8, path, "/api/search")) {
                return try self.handleSearch(request);
            } else if (std.mem.eql(u8, path, "/api/ingest")) {
                return try self.handleIngest(request);
            }
        }

        return notFound();
    }

    fn handleSearch(self: *Self, request: []const u8) ![]const u8 {
        const body_start = std.mem.indexOf(u8, request, "\r\n\r\n") orelse return badRequest();
        const body = request[body_start + 4 ..];

        const search_query = try utils.parseJson(reranker.SearchQuery, self.allocator, body);
        defer search_query.deinit();

        const results = try self.app.search(search_query.value);
        defer {
            for (results) |result| {
                result.deinit(self.allocator);
            }
            self.allocator.free(results);
        }

        const results_json = try utils.stringifyJson(self.allocator, results);
        defer self.allocator.free(results_json);

        return try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Access-Control-Allow-Origin: *\r\n" ++
            "Content-Length: {d}\r\n\r\n" ++
            "{s}", .{ results_json.len, results_json });
    }

    fn handleIngest(self: *Self, request: []const u8) ![]const u8 {
        const body_start = std.mem.indexOf(u8, request, "\r\n\r\n") orelse return badRequest();
        const body = request[body_start + 4 ..];

        const document = try utils.parseJson(reranker.Document, self.allocator, body);
        defer document.deinit();

        try self.app.ingest(document.value);

        return try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Access-Control-Allow-Origin: *\r\n" ++
            "Content-Length: 25\r\n\r\n" ++
            "{\"status\":\"success\"}", .{});
    }
};

fn serveIndexHtml() []const u8 {
    return @embedFile("web/index.html");
}

fn serveHealthCheck() []const u8 {
    return "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: 15\r\n\r\n" ++
        "{\"status\":\"ok\"}";
}

fn serveStaticFile(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".css")) {
        return "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/css\r\n" ++
            "Content-Length: 0\r\n\r\n";
    } else if (std.mem.endsWith(u8, path, ".js")) {
        return "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: application/javascript\r\n" ++
            "Content-Length: 0\r\n\r\n";
    }
    return notFound();
}

fn badRequest() []const u8 {
    return "HTTP/1.1 400 Bad Request\r\n\r\n";
}

fn notFound() []const u8 {
    return "HTTP/1.1 404 Not Found\r\n\r\n";
}

fn internalServerError() []const u8 {
    return "HTTP/1.1 500 Internal Server Error\r\n\r\n";
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try SemanticSearchApp.init(allocator, "config/config.json");
    defer app.deinit();

    var server = try WebServer.init(allocator, &app);
    defer server.deinit();

    try server.start(8080);
}
