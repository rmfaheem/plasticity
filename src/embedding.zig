const std = @import("std");
const utils = @import("utils.zig");
const config = @import("config.zig");

pub const EmbeddingError = error{
    NetworkError,
    InvalidResponse,
    MissingApiKey,
    UnsupportedMethod,
    OutOfMemory,
};

pub const EmbeddingMethod = enum {
    simple_keyword, // Simple keyword-based approach
    openai_api,     // OpenAI embeddings API
    huggingface_api, // Hugging Face embeddings API
    local_model,    // Local embedding model (future)
};

pub const EmbeddingConfig = struct {
    method: EmbeddingMethod = .simple_keyword,
    api_key: ?[]const u8 = null,
    api_url: ?[]const u8 = null,
    model_name: ?[]const u8 = null,
    vector_size: u32 = 8, // Default to match our current setup
};

pub const EmbeddingService = struct {
    allocator: std.mem.Allocator,
    config: EmbeddingConfig,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, embedding_config: EmbeddingConfig) Self {
        return Self{
            .allocator = allocator,
            .config = embedding_config,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn textToVector(self: *Self, text: []const u8) ![]f32 {
        std.log.info("Converting text to vector using method: {any}", .{self.config.method});
        std.log.info("Input text: '{s}'", .{text});

        switch (self.config.method) {
            .simple_keyword => return self.simpleKeywordEmbedding(text),
            .openai_api => return self.openaiEmbedding(text),
            .huggingface_api => return self.huggingfaceEmbedding(text),
            .local_model => return EmbeddingError.UnsupportedMethod,
        }
    }

    fn simpleKeywordEmbedding(self: *Self, text: []const u8) ![]f32 {
        // Simple keyword-based embedding for demonstration
        // This creates a basic vector based on word presence and characteristics
        
        var vector = try self.allocator.alloc(f32, self.config.vector_size);
        
        // Initialize with small random values
        var prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
        const random = prng.random();
        
        for (vector) |*v| {
            v.* = (random.float(f32) - 0.5) * 0.1; // Small random values between -0.05 and 0.05
        }

        // Convert to lowercase for processing
        var lowercase_text = try self.allocator.alloc(u8, text.len);
        defer self.allocator.free(lowercase_text);
        
        for (text, 0..) |c, i| {
            lowercase_text[i] = std.ascii.toLower(c);
        }

        // Define keyword categories that map to vector dimensions
        const keywords = [_]struct {
            words: []const []const u8,
            dimension: usize,
            weight: f32,
        }{
            .{ .words = &[_][]const u8{ "machine", "learning", "ai", "artificial", "intelligence", "neural", "network" }, .dimension = 0, .weight = 0.8 },
            .{ .words = &[_][]const u8{ "data", "database", "storage", "information", "query" }, .dimension = 1, .weight = 0.7 },
            .{ .words = &[_][]const u8{ "performance", "optimization", "speed", "fast", "improve", "efficient" }, .dimension = 2, .weight = 0.6 },
            .{ .words = &[_][]const u8{ "architecture", "design", "system", "structure", "framework" }, .dimension = 3, .weight = 0.7 },
            .{ .words = &[_][]const u8{ "decision", "choice", "select", "decide", "determine" }, .dimension = 4, .weight = 0.5 },
            .{ .words = &[_][]const u8{ "preference", "like", "prefer", "favor", "choose" }, .dimension = 5, .weight = 0.5 },
            .{ .words = &[_][]const u8{ "observation", "observe", "notice", "see", "watch", "monitor" }, .dimension = 6, .weight = 0.4 },
            .{ .words = &[_][]const u8{ "technology", "tech", "software", "application", "development" }, .dimension = 7, .weight = 0.6 },
        };

        // Check for keyword presence and adjust vector values
        for (keywords) |category| {
            if (category.dimension < vector.len) {
                for (category.words) |keyword| {
                    if (std.mem.indexOf(u8, lowercase_text, keyword) != null) {
                        vector[category.dimension] += category.weight;
                        std.log.info("Found keyword '{s}' in category {d}, added weight {d}", .{ keyword, category.dimension, category.weight });
                    }
                }
            }
        }

        // Add text length factor
        const length_factor = @min(1.0, @as(f32, @floatFromInt(text.len)) / 100.0);
        for (vector) |*v| {
            v.* *= (0.5 + length_factor * 0.5); // Scale based on text length
        }

        // Normalize vector to unit length
        var magnitude: f32 = 0;
        for (vector) |v| {
            magnitude += v * v;
        }
        magnitude = @sqrt(magnitude);
        
        if (magnitude > 0) {
            for (vector) |*v| {
                v.* /= magnitude;
            }
        }

        std.log.info("Generated vector: [{d:.3}, {d:.3}, {d:.3}, {d:.3}, {d:.3}, {d:.3}, {d:.3}, {d:.3}]", .{ 
            vector[0], vector[1], vector[2], vector[3], vector[4], vector[5], vector[6], vector[7] 
        });

        return vector;
    }

    fn openaiEmbedding(self: *Self, text: []const u8) ![]f32 {
        if (self.config.api_key == null) {
            return EmbeddingError.MissingApiKey;
        }

        // OpenAI embeddings API implementation
        const url = self.config.api_url orelse "https://api.openai.com/v1/embeddings";
        const model = self.config.model_name orelse "text-embedding-3-small";

        const RequestBody = struct {
            input: []const u8,
            model: []const u8,
        };

        const request_body = RequestBody{
            .input = text,
            .model = model,
        };

        const request_json = try utils.stringifyJson(self.allocator, request_body);
        defer self.allocator.free(request_json);

        var http_client = std.http.Client{ .allocator = self.allocator };
        defer http_client.deinit();

        const uri = try std.Uri.parse(url);
        
        var headers = std.ArrayList(std.http.Header).init(self.allocator);
        defer headers.deinit();
        
        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.config.api_key.?});
        defer self.allocator.free(auth_header);
        
        try headers.append(.{ .name = "Authorization", .value = auth_header });
        try headers.append(.{ .name = "Content-Type", .value = "application/json" });

        var response_body = std.ArrayList(u8).init(self.allocator);
        defer response_body.deinit();

        const result = try http_client.fetch(.{
            .method = .POST,
            .location = .{ .uri = uri },
            .extra_headers = headers.items,
            .payload = request_json,
            .response_storage = .{ .dynamic = &response_body },
        });

        if (result.status.class() != .success) {
            std.log.err("OpenAI API request failed with status: {any}", .{result.status});
            return EmbeddingError.NetworkError;
        }

        const ResponseBody = struct {
            data: []struct {
                embedding: []f32,
            },
        };

        const response = try utils.parseJson(ResponseBody, self.allocator, response_body.items);
        defer response.deinit();

        if (response.value.data.len == 0) {
            return EmbeddingError.InvalidResponse;
        }

        const embedding = response.value.data[0].embedding;
        
        // If the embedding is larger than our vector size, truncate it
        // If smaller, pad with zeros
        const result_vector = try self.allocator.alloc(f32, self.config.vector_size);
        
        for (result_vector, 0..) |*v, i| {
            if (i < embedding.len) {
                v.* = embedding[i];
            } else {
                v.* = 0.0;
            }
        }

        return result_vector;
    }

    fn huggingfaceEmbedding(self: *Self, text: []const u8) ![]f32 {
        // Hugging Face Inference API implementation
        // Similar structure to OpenAI but with different API format
        _ = text;
        _ = self;
        return EmbeddingError.UnsupportedMethod; // TODO: Implement if needed
    }
};
