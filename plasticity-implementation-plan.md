# Implementation Plan for Persistent Memory Architecture

This document outlines the implementation plan for integrating the persistent memory architecture described in Appendix A into the existing semantic search system implemented in Zig. The plan leverages the system's existing components (Qdrant for vector search, ArangoDB for graph storage, and the reranking module) to enable long-term context management, dynamic context retrieval, and relationship-driven intelligence for LLM agents.

## 1. Architectural Overview

The persistent memory architecture extends the existing semantic search system to support continuous ingestion, storage, and retrieval of contextual information, enabling LLM agents to maintain long-term memory. The architecture integrates with the existing components as follows:

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Qdrant DB     │◄──►│   ArangoDB      │◄──►│   Zig App       │
│  (Vectors)      │    │  (Graph)        │    │  (Orchestrator) │
│ • Embeddings    │    │ • Relationships │    │ • Ingestion     │
│ • Metadata      │    │ • Topics        │    │ • Retrieval     │
│ • Time filters  │    │ • Weights       │    │ • Re-ranking    │
└─────────────────┘    └─────────────────┘    └─────────────────┘
      ↑                       ↑                       ↑
      │                       │                       │
┌─────┴───────────────────────┴───────────────────────┴──────┐
│                    LLM Agent Interface                    │
│ • Query Processing                                        │
│ • Context Storage                                         │
│ • Response Generation with Historical Context            │
└───────────────────────────────────────────────────────────┘
```

### Key Components
- **Qdrant**: Stores document embeddings and metadata for vector-based similarity search.
- **ArangoDB**: Manages a knowledge graph of relationships, topics, and weights for contextual understanding.
- **Zig Application**: Orchestrates ingestion, retrieval, and reranking, now extended to handle persistent memory tasks.
- **LLM Agent Interface**: A new module to process queries, store context, and generate responses using historical data.

## 2. Implementation Steps

### 2.1 Extend Configuration for Persistent Memory
The existing `config.zig` will be updated to include settings for persistent memory management, such as retention periods and indexing intervals.

#### Steps:
1. Add a `persistent_memory` section to the `Config` struct in `src/config.zig`:
   - `retention_period`: Duration (in days) for retaining historical context.
   - `indexing_interval`: Frequency (in seconds) for background indexing.
   - `max_context_size`: Maximum size (in bytes) for stored context per session.
2. Update `loadConfig` to parse these new fields.
3. Ensure proper deallocation in `Config.deinit`.

#### Example Configuration:
```json
{
  "qdrant": { ... },
  "arango": { ... },
  "ranking": { ... },
  "persistent_memory": {
    "retention_period": 365,
    "indexing_interval": 3600,
    "max_context_size": 1048576
  }
}
```

### 2.2 Enhance Document Ingestion
The ingestion process in `SemanticSearchApp.ingest` will be modified to support continuous context storage, including user preferences, decisions, and relationships.

#### Steps:
1. Update `reranker.Document` to include fields for:
   - `user_id`: Unique identifier for the user or session.
   - `context_type`: Enum (`preference`, `decision`, `observation`).
   - `metadata`: Key-value pairs for additional context (e.g., emotional tone, project ID).
2. Extend `qdrant.upsert` to store embeddings with `user_id` and `context_type` in the payload.
3. Enhance `arango.upsertNode` to create relationships for:
   - User-to-context (`user_id → context_type`).
   - Context-to-project (`context_id → project_id`).
   - Context-to-context (`context_id → related_context_id`).
4. Implement background indexing as a separate thread in `main.zig` to process conversation chunks periodically.

#### Code Snippet (src/reranker.zig):
```zig
pub const ContextType = enum {
    preference,
    decision,
    observation,
};

pub const Document = struct {
    id: []const u8,
    vector: []const f32,
    timestamp: i64,
    content: ?[]const u8 = null,
    topic_id: ?[]const u8 = null,
    related_documents: ?[][]const u8 = null,
    user_id: ?[]const u8 = null,
    context_type: ?ContextType = null,
    metadata: ?std.StringHashMap([]const u8) = null,

    pub fn deinit(self: *const Document, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.vector);
        if (self.content) |content| allocator.free(content);
        if (self.topic_id) |topic| allocator.free(topic);
        if (self.related_documents) |related| {
            for (related) |doc| allocator.free(doc);
            allocator.free(related);
        }
        if (self.user_id) |user| allocator.free(user);
        if (self.metadata) |meta| {
            var it = meta.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            meta.deinit();
        }
    }
};
```

### 2.3 Implement Dynamic Context Retrieval
The `SemanticSearchApp.search` function will be extended to support dynamic context retrieval with time-aware weighting and graph-based navigation.

#### Steps:
1. Update `reranker.SearchQuery` to include:
   - `user_id`: To filter context by user.
   - `context_types`: Array of desired context types to retrieve.
2. Modify `qdrant.search` to filter by `user_id` and `context_type` in the payload.
3. Enhance `arango.getGraphContext` to traverse the knowledge graph up to a configurable depth (default: 2 hops).
4. Update the reranking algorithm in `reranker.rerank` to incorporate:
   - Temporal weighting based on `timestamp` and `retention_period`.
   - Graph-based scoring using relationship weights.
   - User behavior patterns (e.g., frequently accessed contexts).

#### Code Snippet (src/reranker.zig):
```zig
pub const SearchQuery = struct {
    vector: []const f32,
    limit: ?u32 = null,
    time_range: ?TimeRange = null,
    topic_id: ?[]const u8 = null,
    source_node_id: ?[]const u8 = null,
    user_id: ?[]const u8 = null,
    context_types: ?[]const ContextType = null,

    pub fn deinit(self: *const SearchQuery, allocator: std.mem.Allocator) void {
        allocator.free(self.vector);
        if (self.topic_id) |topic| allocator.free(topic);
        if (self.source_node_id) |node| allocator.free(node);
        if (self.user_id) |user| allocator.free(user);
        if (self.context_types) |types| allocator.free(types);
    }
};

pub fn rerank(
    allocator: std.mem.Allocator,
    vector_results: []const VectorResult,
    graph_contexts: *const std.HashMap([]const u8, arango.GraphContext, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    query: SearchQuery,
    config: config.Config,
) ![]SearchResult {
    const current_time = std.time.timestamp();
    var scored_results = try allocator.alloc(SearchResult, vector_results.len);

    for (vector_results, 0..) |result, i| {
        const graph_context = graph_contexts.get(result.id) orelse arango.GraphContext{
            .neighbors = &[_][]const u8{},
            .weights = &[_]f32{},
            .topics = &[_][]const u8{},
        };

        // Calculate scores
        const similarity_score = result.score;
        const age_seconds = @as(f32, @floatFromInt(current_time - result.timestamp));
        const recency_score = if (age_seconds < config.persistent_memory.retention_period * 86400.0)
            1.0 / (1.0 + config.ranking.recency_decay_factor * age_seconds / 86400.0)
        else
            0.0;

        var graph_score: f32 = 0.0;
        if (graph_context.weights.len > 0) {
            var total_weight: f32 = 0.0;
            for (graph_context.weights) |weight| total_weight += weight;
            graph_score = total_weight / @as(f32, @floatFromInt(graph_context.weights.len));
        }

        const final_score = config.ranking.similarity_weight * similarity_score +
            config.ranking.recency_weight * recency_score +
            config.ranking.graph_weight * graph_score;

        var neighbors = try allocator.alloc([]const u8, graph_context.neighbors.len);
        for (graph_context.neighbors, 0..) |neighbor, j| {
            neighbors[j] = try allocator.dupe(u8, neighbor);
        }

        scored_results[i] = SearchResult{
            .id = try allocator.dupe(u8, result.id),
            .score = final_score,
            .timestamp = result.timestamp,
            .content = if (result.content) |content| try allocator.dupe(u8, content) else null,
            .graph_neighbors = neighbors,
            .similarity_score = similarity_score,
            .recency_score = recency_score,
            .graph_score = graph_score,
        };
    }

    std.sort.insertion(SearchResult, scored_results, {}, compareSearchResults);
    return scored_results;
}
```

### 2.4 Add Background Indexing Process
Implement a background thread in `main.zig` to continuously index conversation chunks and update the knowledge graph.

#### Steps:
1. Create a new `BackgroundIndexer` struct to manage indexing tasks.
2. Implement a loop that runs every `indexing_interval` seconds.
3. Process unindexed conversation chunks, extracting preferences, decisions, and relationships.
4. Store results in Qdrant and ArangoDB using existing ingestion methods.

#### Code Snippet (src/main.zig):
```zig
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
            for (documents) |doc| {
                try self.app.ingest(doc);
            }
            std.time.sleep(self.app.config.persistent_memory.indexing_interval * std.time.ns_per_s);
        }
    }

    fn fetchUnindexedChunks(self: *BackgroundIndexer) ![]Document {
        // Placeholder: Fetch unindexed conversation chunks from a queue or database
        return &[_]Document{};
    }

    pub fn stop(self: *BackgroundIndexer) void {
        self.running = false;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var app = try SemanticSearchApp.init(allocator, "config/config.json");
    defer app.deinit();

    // Start background indexer
    var indexer = try BackgroundIndexer.init(allocator, &app);
    const indexer_thread = try std.Thread.spawn(.{}, BackgroundIndexer.start, .{indexer});
    defer indexer.stop();
    defer indexer_thread.join();

    // Existing command-line logic
    // ...
}
```

### 2.5 Implement LLM Agent Interface
Create a new module `agent.zig` to handle LLM interactions, integrating with the persistent memory system.

#### Steps:
1. Define an `Agent` struct with methods for:
   - Processing user queries.
   - Storing conversation context.
   - Generating responses with historical context.
2. Use `SemanticSearchApp.search` to retrieve relevant context for each query.
3. Implement proactive context surfacing by analyzing retrieved context for patterns.

#### Code Snippet (src/agent.zig):
```zig
const std = @import("std");
const search = @import("main.zig");
const reranker = @import("reranker.zig");
const utils = @import("utils.zig");

pub const Agent = struct {
    allocator: std.mem.Allocator,
    app: *search.SemanticSearchApp,

    pub fn init(allocator: std.mem.Allocator, app: *search.SemanticSearchApp) Agent {
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
        return try self.allocator.alloc(f32, 768); // Example dimension
    }

    fn generateResponse(self: *Agent, query_text: []const u8, results: []reranker.SearchResult) ![]u8 {
        var response = std.ArrayList(u8).init(self.allocator);
        defer response.deinit();

        // Proactive context surfacing
        for (results) |result| {
            if (result.recency_score > 0.8 and result.context_type == .preference) {
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
```

### 2.6 Update Database Schemas
Ensure Qdrant and ArangoDB schemas support the new fields and relationships.

#### Qdrant Schema Update:
Add `user_id` and `context_type` to the payload:
```bash
curl -X PUT http://localhost:6333/collections/semantic_chunks \
  -H "Content-Type: application/json" \
  -d '{
    "vectors": {
      "size": 768,
      "distance": "Cosine"
    },
    "payload_schema": {
      "user_id": { "data_type": "keyword" },
      "context_type": { "data_type": "keyword" }
    }
  }'
```

#### ArangoDB Schema Update:
Create additional edge types for user-to-context and context-to-project relationships:
```javascript
db._useDatabase("semantic_graph");
db._createEdgeCollection("user_context");
db._createEdgeCollection("context_project");
db.user_context.ensureIndex({ type: "persistent", fields: ["type"] });
db.context_project.ensureIndex({ type: "persistent", fields: ["type"] });
```

### 2.7 Testing and Validation
Implement unit tests to validate the new functionality.

#### Steps:
1. Add tests in `src/main.zig` for:
   - Ingestion of documents with `user_id` and `context_type`.
   - Retrieval of context filtered by user and context type.
   - Correct weighting of recent vs. historical context.
2. Update `build.zig` to include new test files.
3. Run tests using `zig build test`.

#### Code Snippet (src/main.zig):
```zig
test "ingest and retrieve user context" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try SemanticSearchApp.init(allocator, "config/config.json");
    defer app.deinit();

    const document = reranker.Document{
        .id = "test_doc",
        .vector = try allocator.alloc(f32, 768),
        .timestamp = std.time.timestamp(),
        .user_id = "user_123",
        .context_type = .preference,
    };
    defer document.deinit(allocator);

    try app.ingest(document);

    const query = reranker.SearchQuery{
        .vector = try allocator.alloc(f32, 768),
        .user_id = "user_123",
        .context_types = &[_]reranker.ContextType{.preference},
    };
    defer query.deinit(allocator);

    const results = try app.search(query);
    defer {
        for (results) |result| result.deinit(allocator);
        allocator.free(results);
    };

    try std.testing.expect(results.len > 0);
    try std.testing.expectEqualStrings("test_doc", results[0].id);
}
```

## 3. Performance Considerations
- **Memory Management**: Ensure proper deallocation of new fields in `Document` and `SearchQuery`.
- **Indexing Efficiency**: Limit background indexing to avoid overwhelming database resources.
- **Query Latency**: Cache frequently accessed user contexts in memory (e.g., using a Redis layer).
- **Graph Traversal**: Restrict traversal depth to 2 hops to balance relevance and performance.

## 4. Deployment Plan
- **Staging Environment**: Deploy the updated system in a test environment with sample conversation data.
- **Monitoring**: Log indexing frequency, query latency, and context retrieval accuracy.
- **Scaling**: Use Qdrant and ArangoDB clustering for high availability and load balancing.

## 5. Future Enhancements
- **Learning Weights**: Implement machine learning to adapt ranking weights based on user feedback.
- **Proactive Suggestions**: Enhance the agent to suggest actions based on detected patterns.
- **Multi-User Support**: Add tenant isolation for multi-user environments.

This implementation plan ensures the persistent memory architecture is seamlessly integrated into the existing system, enabling LLM agents to maintain long-term context and deliver intelligent, context-aware responses.