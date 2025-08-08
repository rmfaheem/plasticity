const std = @import("std");
const utils = @import("utils.zig");

pub const LLMError = error{
    Disabled,
    MissingApiKey,
    NetworkError,
    InvalidResponse,
};

pub const LLMConfig = struct {
    enabled: bool = false,
    provider: ?[]const u8 = null, // e.g., "openai"
    api_url: ?[]const u8 = null, // default based on provider
    api_key: ?[]const u8 = null,
    model: ?[]const u8 = null,
    temperature: f32 = 0.7,
    max_tokens: u32 = 256,
};

pub const LLMService = struct {
    allocator: std.mem.Allocator,
    config: LLMConfig,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, cfg: LLMConfig) Self {
        return .{ .allocator = allocator, .config = cfg };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn generateCompletion(self: *Self, prompt: []const u8, system: ?[]const u8, model_override: ?[]const u8, temperature_override: ?f32) ![]const u8 {
        if (!self.config.enabled) return LLMError.Disabled;

        const provider = self.config.provider orelse "openai";
        if (std.mem.eql(u8, provider, "openai")) {
            return self.openaiChatCompletion(prompt, system, model_override, temperature_override);
        }
        // Fallback: disabled/unsupported provider
        return LLMError.Disabled;
    }

    fn openaiChatCompletion(self: *Self, prompt: []const u8, system: ?[]const u8, model_override: ?[]const u8, temperature_override: ?f32) ![]const u8 {
        if (self.config.api_key == null) return LLMError.MissingApiKey;

        const url = self.config.api_url orelse "https://api.openai.com/v1/chat/completions";
        const model = model_override orelse (self.config.model orelse "gpt-4o-mini");
        const temperature = temperature_override orelse self.config.temperature;
        const max_tokens = self.config.max_tokens;

        const Message = struct { role: []const u8, content: []const u8 };
        var messages = std.ArrayList(Message).init(self.allocator);
        defer messages.deinit();
        if (system) |sys| try messages.append(.{ .role = "system", .content = sys });
        try messages.append(.{ .role = "user", .content = prompt });

        const RequestBody = struct {
            model: []const u8,
            messages: []Message,
            temperature: f32,
            max_tokens: u32,
        };

        const body = RequestBody{ .model = model, .messages = messages.items, .temperature = temperature, .max_tokens = max_tokens };
        const request_json = try utils.stringifyJson(self.allocator, body);
        defer self.allocator.free(request_json);

        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();
        const uri = try std.Uri.parse(url);

        var headers = std.ArrayList(std.http.Header).init(self.allocator);
        defer headers.deinit();

        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.config.api_key.?});
        defer self.allocator.free(auth_header);
        try headers.append(.{ .name = "Authorization", .value = auth_header });
        try headers.append(.{ .name = "Content-Type", .value = "application/json" });

        var response_buf = std.ArrayList(u8).init(self.allocator);
        defer response_buf.deinit();

        const res = try client.fetch(.{
            .method = .POST,
            .location = .{ .uri = uri },
            .extra_headers = headers.items,
            .payload = request_json,
            .response_storage = .{ .dynamic = &response_buf },
        });

        if (res.status.class() != .success) {
            std.log.err("LLM API error status: {any}", .{res.status});
            return LLMError.NetworkError;
        }

        const ResponseBody = struct {
            choices: []struct {
                message: struct { content: []const u8 },
            },
        };

        const parsed = try utils.parseJson(ResponseBody, self.allocator, response_buf.items);
        defer parsed.deinit();

        if (parsed.value.choices.len == 0) return LLMError.InvalidResponse;
        const content = parsed.value.choices[0].message.content;
        return try self.allocator.dupe(u8, content);
    }
};
