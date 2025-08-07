const std = @import("std");
const utils = @import("utils.zig");
const embedding = @import("embedding.zig");

pub const QdrantConfig = struct {
    host: []const u8,
    port: u16,
    collection_name: []const u8,
    api_key: ?[]const u8 = null,

    pub fn deinit(self: *const QdrantConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        allocator.free(self.collection_name);
        if (self.api_key) |key| {
            allocator.free(key);
        }
    }
};

pub const ArangoConfig = struct {
    host: []const u8,
    port: u16,
    database: []const u8,
    username: []const u8,
    password: []const u8,

    pub fn deinit(self: *const ArangoConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        allocator.free(self.database);
        allocator.free(self.username);
        allocator.free(self.password);
    }
};

pub const RankingConfig = struct {
    similarity_weight: f32 = 0.5,
    recency_weight: f32 = 0.3,
    graph_weight: f32 = 0.2,
    recency_decay_factor: f32 = 0.1,
};

pub const ServerConfig = struct {
    port: u16 = 8080,
};

pub const PersistentMemoryConfig = struct {
    retention_period: u64 = 365,
    indexing_interval: u64 = 3600,
    max_context_size: u64 = 1048576,
};

pub const Config = struct {
    qdrant: QdrantConfig,
    arango: ArangoConfig,
    ranking: RankingConfig = .{},
    server: ServerConfig = .{},
    persistent_memory: PersistentMemoryConfig = .{},
    embedding: embedding.EmbeddingConfig = .{},

    pub fn deinit(self: *const Config, allocator: std.mem.Allocator) void {
        self.qdrant.deinit(allocator);
        self.arango.deinit(allocator);
    }
};

pub fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !Config {
    const config_json = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(config_json);

    const parsed = try utils.parseJson(Config, allocator, config_json);
    defer parsed.deinit();

    // Check for Docker environment variables
    const qdrant_host = std.process.getEnvVarOwned(allocator, "QDRANT_HOST") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try allocator.dupe(u8, parsed.value.qdrant.host),
        else => return err,
    };
    defer allocator.free(qdrant_host);

    const arango_host = std.process.getEnvVarOwned(allocator, "ARANGO_HOST") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try allocator.dupe(u8, parsed.value.arango.host),
        else => return err,
    };
    defer allocator.free(arango_host);

    // We need to duplicate the config data since the parsed data will be freed
    const result = Config{
        .qdrant = QdrantConfig{
            .host = try allocator.dupe(u8, qdrant_host),
            .port = parsed.value.qdrant.port,
            .collection_name = try allocator.dupe(u8, parsed.value.qdrant.collection_name),
            .api_key = if (parsed.value.qdrant.api_key) |key| try allocator.dupe(u8, key) else null,
        },
        .arango = ArangoConfig{
            .host = try allocator.dupe(u8, arango_host),
            .port = parsed.value.arango.port,
            .database = try allocator.dupe(u8, parsed.value.arango.database),
            .username = try allocator.dupe(u8, parsed.value.arango.username),
            .password = try allocator.dupe(u8, parsed.value.arango.password),
        },
        .ranking = parsed.value.ranking,
        .server = parsed.value.server,
        .persistent_memory = parsed.value.persistent_memory,
        .embedding = parsed.value.embedding,
    };

    return result;
}
