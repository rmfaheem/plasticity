const std = @import("std");
const main = @import("main.zig");
const reranker = @import("reranker.zig");
const utils = @import("utils.zig");

pub const Agent = struct {
    allocator: std.mem.Allocator,
    app: *main.SemanticSearchApp,

    pub fn init(allocator: std.mem.Allocator, app: *main.SemanticSearchApp) Agent {
        return .{ .allocator = allocator, .app = app };
    }

    pub fn processQuery(self: *Agent, user_id: []const u8, query_text: []const u8) ![]u8 {
        // Convert query to embedding (placeholder: assumes external embedding service)
        const vector = try self.generateEmbedding(query_text);
        defer self.allocator.free(vector);

        const query = reranker.SearchQuery{
            .vector = vector,
            .user_id = try self.allocator.dupe(u8, user_id),
            .context_types = &[_]reranker.ContextType{ .preference, .decision, .observation },
        };
        defer query.deinit(self.allocator);

        const results = try self.app.search(query);
        defer {
            for (results) |result| result.deinit(self.allocator);
            self.allocator.free(results);
        }

        // Generate response with context
        const response = try self.generateResponse(query_text, results);
        return response;
    }

    fn generateEmbedding(self: *Agent, text: []const u8) ![]f32 {
        // Placeholder: Call external embedding service
        _ = text;
        const vector = try self.allocator.alloc(f32, 768); // Example dimension
        @memset(vector, 0);
        return vector;
    }

    fn generateResponse(self: *Agent, query_text: []const u8, results: []reranker.SearchResult) ![]u8 {
        var response = std.ArrayList(u8).init(self.allocator);
        defer response.deinit();

        // Proactive context surfacing
        for (results) |result| {
            if (result.recency_score > 0.8) {
                try response.writer().print(
                    "I noticed you recently mentioned {s}. Would you like me to apply this preference?",
                    .{result.content orelse "a preference"}
                );
            }
        }

        // Generate main response (placeholder: assumes LLM integration)
        try response.writer().print("Response to: {s}\n", .{query_text});
        return response.toOwnedSlice();
    }
};

test "agent processing" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try main.SemanticSearchApp.init(allocator, "config/config.docker.json");
    defer app.deinit();

    var agent = Agent.init(allocator, &app);

    const response = try agent.processQuery("test_user", "what is the meaning of life?");
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "Response to: what is the meaning of life?") != null);
}