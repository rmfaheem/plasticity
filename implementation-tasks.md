# LLM Agent Integration - Detailed Implementation Tasks

## Overview

This document provides a comprehensive task breakdown for implementing LLM agent conversation memory and retrieval capabilities in the Plasticity system. Each task specifies exactly where modifications integrate with existing components.

---

## Phase 1: Conversation Storage Foundation (2-3 weeks)

### Task 1.1: Extend Data Models

**Files to modify:**
- `src/reranker.zig` - Add conversation-specific structures
- `src/config.zig` - Add conversation memory configuration

**New files to create:**
- `src/conversation.zig` - Core conversation management types and functions

#### Subtasks:

**1.1.1: Add ConversationTurn structure to reranker.zig**
```zig
// Location: src/reranker.zig (after existing Document struct)
pub const ConversationTurn = struct {
    id: []const u8,
    session_id: []const u8,
    turn_number: u32,
    timestamp: i64,
    user_message: []const u8,
    assistant_message: []const u8,
    importance_score: f32 = 0.5,
    tags: []const []const u8 = &.{},
    user_id: ?[]const u8 = null,
    metadata: ?std.json.Value = null,
    
    pub fn deinit(self: *const ConversationTurn, allocator: std.mem.Allocator) void;
    pub fn toDocument(self: *const ConversationTurn, allocator: std.mem.Allocator) !Document;
};
```
- **Integration**: Extends existing Document-based architecture
- **Dependencies**: Uses existing JSON parsing from `utils.zig`

**1.1.2: Add AgentSession structure**
```zig
// Location: src/conversation.zig (new file)
pub const AgentSession = struct {
    session_id: []const u8,
    agent_id: []const u8,
    user_id: ?[]const u8,
    created_at: i64,
    last_active: i64,
    preferences: std.json.Value,
    
    pub fn deinit(self: *const AgentSession, allocator: std.mem.Allocator) void;
};
```

**1.1.3: Extend configuration**
```zig
// Location: src/config.zig (add to Config struct)
pub const ConversationConfig = struct {
    auto_extract_context: bool = true,
    context_extraction_threshold: f32 = 0.7,
    session_timeout_hours: u32 = 24,
    max_turns_per_session: u32 = 1000,
    enable_forgetting: bool = true,
    forgetting_curve_factor: f32 = 0.95,
};

// Add to Config struct:
conversation: ConversationConfig = .{},
```
- **Integration**: Extends existing Config loading in `loadConfig()`

### Task 1.2: Extend Database Clients

**Files to modify:**
- `src/qdrant.zig` - Add conversation-specific vector operations
- `src/arango.zig` - Add conversation graph operations

#### Subtasks:

**1.2.1: Extend QdrantClient for conversations**
```zig
// Location: src/qdrant.zig (add methods to QdrantClient)
pub fn upsertConversationTurn(self: *Self, turn: ConversationTurn) !void {
    // Convert turn to Document format and call existing upsert
    const doc = try turn.toDocument(self.allocator);
    defer doc.deinit(self.allocator);
    return self.upsert(doc);
}

pub fn searchConversations(self: *Self, query: ConversationQuery) ![]VectorResult {
    // Convert to SearchQuery and use existing search
    const search_query = try query.toSearchQuery(self.allocator);
    defer search_query.deinit(self.allocator);
    return self.search(search_query);
}
```
- **Integration**: Leverages existing `upsert()` and `search()` methods
- **No breaking changes**: Extends interface without modifying existing functionality

**1.2.2: Extend ArangoClient for conversation graphs**
```zig
// Location: src/arango.zig (add methods to ArangoClient)
pub fn upsertConversationNode(self: *Self, turn: ConversationTurn) !void {
    // Create node document
    // Use existing upsertNode() pattern but with conversation-specific fields
}

pub fn createSessionEdge(self: *Self, from_turn: []const u8, to_turn: []const u8) !void {
    // Create "PART_OF_SESSION" edge using existing createEdge() pattern
}

pub fn getConversationContext(self: *Self, session_id: []const u8, limit: u32) ![]ConversationTurn {
    // Query conversation history using existing AQL patterns
}
```
- **Integration**: Uses existing HTTP client and authentication
- **Reuses patterns**: Follows existing `upsertNode()` and `createEdge()` patterns

### Task 1.3: Create Conversation Manager

**New file:** `src/conversation.zig`

#### Subtasks:

**1.3.1: Implement ConversationManager**
```zig
// Location: src/conversation.zig
pub const ConversationManager = struct {
    allocator: std.mem.Allocator,
    qdrant_client: *qdrant.QdrantClient,
    arango_client: *arango.ArangoClient,
    config: config.ConversationConfig,
    
    pub fn init(
        allocator: std.mem.Allocator,
        qdrant_client: *qdrant.QdrantClient,
        arango_client: *arango.ArangoClient,
        conv_config: config.ConversationConfig
    ) ConversationManager;
    
    pub fn saveTurn(self: *ConversationManager, turn: ConversationTurn) ![]const u8;
    pub fn getConversationHistory(self: *ConversationManager, session_id: []const u8, limit: u32) ![]ConversationTurn;
    pub fn searchConversations(self: *ConversationManager, query: ConversationQuery) ![]ConversationTurn;
};
```
- **Integration**: Wraps existing Qdrant and Arango clients
- **Dependencies**: Uses existing config, utils, and client infrastructure

**1.3.2: Add to main SemanticSearchApp**
```zig
// Location: src/main.zig (modify SemanticSearchApp struct)
const SemanticSearchApp = struct {
    allocator: std.mem.Allocator,
    config: config.Config,
    qdrant_client: qdrant.QdrantClient,
    arango_client: arango.ArangoClient,
    conversation_manager: conversation.ConversationManager, // NEW
    
    pub fn init(allocator: std.mem.Allocator, config_path: []const u8) !Self {
        // ... existing code ...
        
        // Add conversation manager initialization
        const conv_manager = conversation.ConversationManager.init(
            allocator,
            &app.qdrant_client,
            &app.arango_client,
            app_config.conversation
        );
        
        return Self{
            // ... existing fields ...
            .conversation_manager = conv_manager,
        };
    }
};
```
- **Integration**: Non-breaking addition to existing app structure

### Task 1.4: Database Schema Setup

#### Subtasks:

**1.4.1: Extend Qdrant collection initialization**
```zig
// Location: src/qdrant.zig (modify initCollection method)
pub fn initCollection(self: *Self) !void {
    // Existing collection creation code...
    
    // Add conversation-specific payload schema
    // No schema changes needed - Qdrant is schemaless
    // Document in comments the expected conversation payload structure
}
```
- **Integration**: Extends existing `initCollection()` method
- **No breaking changes**: Qdrant collections are schemaless

**1.4.2: Create ArangoDB conversation collections**
```zig
// Location: src/arango.zig (modify initCollections method)
pub fn initCollections(self: *Self) !void {
    // Existing collection creation...
    
    // Add conversation-specific collections
    try self.createCollection("conversation_turns");
    try self.createCollection("agent_sessions");
    try self.createCollection("context_extractions");
    
    // Add conversation-specific indexes
    try self.createIndex("conversation_turns", .{.fields = &[_][]const u8{"session_id"}});
    try self.createIndex("conversation_turns", .{.fields = &[_][]const u8{"timestamp"}});
}
```
- **Integration**: Extends existing collection initialization

### Task 1.5: Update Configuration Files

#### Subtasks:

**1.5.1: Update config.json**
```json
// Location: config/config.json
{
  "qdrant": {...},
  "arango": {...},
  "ranking": {...},
  "server": {...},
  "persistent_memory": {...},
  "conversation": {
    "auto_extract_context": true,
    "context_extraction_threshold": 0.7,
    "session_timeout_hours": 24,
    "max_turns_per_session": 1000,
    "enable_forgetting": true,
    "forgetting_curve_factor": 0.95
  }
}
```

**1.5.2: Update example files**
- Create `examples/conversation_turn.json`
- Create `examples/conversation_query.json`

---

## Phase 2: Context Extraction & Intelligence (2-3 weeks)

### Task 2.1: Implement Context Extraction

**New files:**
- `src/context_extractor.zig`

#### Subtasks:

**2.1.1: Create ContextExtraction types**
```zig
// Location: src/context_extractor.zig
pub const ContextType = enum {
    preference,
    decision,
    fact,
    task,
    entity,
};

pub const ContextExtraction = struct {
    id: []const u8,
    type: ContextType,
    content: []const u8,
    confidence: f32,
    entities: []const []const u8,
    source_turn_id: []const u8,
    
    pub fn deinit(self: *const ContextExtraction, allocator: std.mem.Allocator) void;
};
```

**2.1.2: Implement extraction logic**
```zig
// Location: src/context_extractor.zig
pub const ContextExtractor = struct {
    allocator: std.mem.Allocator,
    config: config.ConversationConfig,
    
    pub fn extractFromTurn(self: *ContextExtractor, turn: ConversationTurn) ![]ContextExtraction {
        // Rule-based and pattern matching extraction
        // Can be enhanced with ML models later
    }
    
    fn extractPreferences(self: *ContextExtractor, text: []const u8) ![]ContextExtraction;
    fn extractDecisions(self: *ContextExtractor, text: []const u8) ![]ContextExtraction;
};
```
- **Integration**: Uses existing config and utils
- **Extension point**: Can integrate with embedding service for semantic extraction

**2.1.3: Integrate with ConversationManager**
```zig
// Location: src/conversation.zig (modify saveTurn method)
pub fn saveTurn(self: *ConversationManager, turn: ConversationTurn) ![]const u8 {
    // Save the turn (existing logic)
    const turn_id = try self.saveBasicTurn(turn);
    
    // Extract context if enabled
    if (self.config.auto_extract_context) {
        var extractor = ContextExtractor.init(self.allocator, self.config);
        const extractions = try extractor.extractFromTurn(turn);
        defer {
            for (extractions) |ext| ext.deinit(self.allocator);
            self.allocator.free(extractions);
        }
        
        // Save extractions to ArangoDB
        try self.saveContextExtractions(turn_id, extractions);
    }
    
    return turn_id;
}
```

### Task 2.2: Enhanced Relationship Building

#### Subtasks:

**2.2.1: Extend ArangoClient with conversation relationships**
```zig
// Location: src/arango.zig
pub fn buildConversationRelationships(self: *Self, turn: ConversationTurn, extractions: []ContextExtraction) !void {
    // Create edges between:
    // - Turn -> Session (PART_OF_SESSION)
    // - Turn -> Turn (FOLLOWS)
    // - Turn -> Context (EXTRACTS_TO)
    // - Context -> Entity (MENTIONS)
}
```
- **Integration**: Uses existing edge creation patterns

**2.2.2: Topic modeling integration**
```zig
// Location: src/conversation.zig
pub fn updateTopicModel(self: *ConversationManager, turn: ConversationTurn) !void {
    // Extract topics and update graph relationships
    // Integrates with existing topic_id functionality in reranker.zig
}
```

---

## Phase 3: Enhanced Retrieval for Agents (2-3 weeks)

### Task 3.1: Conversation-Aware Search

**Files to modify:**
- `src/reranker.zig` - Add conversation query types
- `src/main.zig` - Add conversation search methods

#### Subtasks:

**3.1.1: Add ConversationQuery to reranker.zig**
```zig
// Location: src/reranker.zig (after SearchQuery struct)
pub const ConversationQuery = struct {
    query_text: []const u8,
    session_id: ?[]const u8 = null,
    user_id: ?[]const u8 = null,
    context_types: []const ContextType = &.{},
    time_range: ?TimeRange = null,
    include_conversation_context: bool = true,
    max_turns: u32 = 10,
    
    pub fn deinit(self: *const ConversationQuery, allocator: std.mem.Allocator) void;
    pub fn toSearchQuery(self: *const ConversationQuery, allocator: std.mem.Allocator) !SearchQuery;
};
```

**3.1.2: Add conversation search to SemanticSearchApp**
```zig
// Location: src/main.zig (add method to SemanticSearchApp)
pub fn searchConversations(self: *Self, query: ConversationQuery) ![]ConversationTurn {
    // Convert to vector search
    const search_query = try query.toSearchQuery(self.allocator);
    defer search_query.deinit(self.allocator);
    
    // Use existing search pipeline but return ConversationTurn objects
    const vector_results = try self.qdrant_client.search(search_query);
    defer self.allocator.free(vector_results);
    
    // Convert results and add conversation context
    return try self.conversation_manager.hydrateConversationResults(vector_results, query);
}
```
- **Integration**: Leverages existing search pipeline
- **Reuses infrastructure**: Uses existing vector search and graph context

### Task 3.2: Context-Aware Retrieval

**New file:** `src/agent_retrieval.zig`

#### Subtasks:

**3.2.1: Implement AgentRetrieval**
```zig
// Location: src/agent_retrieval.zig
pub const ConversationContext = struct {
    recent_turns: []ConversationTurn,
    relevant_history: []ConversationTurn,
    extracted_preferences: []ContextExtraction,
    related_sessions: []AgentSession,
    
    pub fn deinit(self: *const ConversationContext, allocator: std.mem.Allocator) void;
};

pub const AgentRetrieval = struct {
    allocator: std.mem.Allocator,
    app: *SemanticSearchApp,
    
    pub fn getRelevantContext(
        self: *AgentRetrieval,
        current_message: []const u8,
        session_id: []const u8,
        max_context_turns: u32
    ) !ConversationContext;
};
```

**3.2.2: Integrate with main app**
```zig
// Location: src/main.zig (add to SemanticSearchApp)
agent_retrieval: agent_retrieval.AgentRetrieval, // NEW field

// Add in init()
.agent_retrieval = agent_retrieval.AgentRetrieval.init(allocator, &app),
```

---

## Phase 4: MCP Server Implementation (3-4 weeks)

### Task 4.1: MCP Protocol Foundation

**New files:**
- `src/mcp_server.zig`
- `src/mcp_protocol.zig`
- `src/mcp_transport.zig`

#### Subtasks:

**4.1.1: Implement basic MCP protocol**
```zig
// Location: src/mcp_protocol.zig
pub const JsonRpcMessage = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?std.json.Value = null,
    method: ?[]const u8 = null,
    params: ?std.json.Value = null,
    result: ?std.json.Value = null,
    @"error": ?JsonRpcError = null,
};
```
- **Integration**: Uses existing JSON parsing from `utils.zig`

**4.1.2: Create MCP server wrapper**
```zig
// Location: src/mcp_server.zig
pub const McpMemoryServer = struct {
    allocator: std.mem.Allocator,
    app: *SemanticSearchApp,
    
    pub fn init(allocator: std.mem.Allocator, app: *SemanticSearchApp) !McpMemoryServer;
    pub fn handleRequest(self: *McpMemoryServer, request: []const u8) ![]const u8;
};
```
- **Integration**: Wraps existing SemanticSearchApp
- **No modifications**: Doesn't change existing app structure

### Task 4.2: MCP Memory Methods

#### Subtasks:

**4.2.1: Implement memory tools**
```zig
// Location: src/mcp_server.zig (add methods)
fn handleMemoryConversationSave(self: *McpMemoryServer, params: std.json.Value) !std.json.Value {
    // Parse params to ConversationTurn
    // Call app.conversation_manager.saveTurn()
    // Return success response
}

fn handleMemoryConversationRecall(self: *McpMemoryServer, params: std.json.Value) !std.json.Value {
    // Parse params to ConversationQuery  
    // Call app.searchConversations()
    // Return conversation results
}
```
- **Integration**: Uses existing conversation manager methods

**4.2.2: Add to main application**
```zig
// Location: src/main.zig (modify main function)
pub fn main() !void {
    // ... existing CLI handling ...
    
    } else if (std.mem.eql(u8, command, "mcp-server")) {
        // Start MCP server
        var mcp_server = try McpMemoryServer.init(allocator, &app);
        try mcp_server.startStdio(); // or startWebSocket()
    } else {
        // ... existing error handling ...
    }
}
```
- **Integration**: Adds new CLI command without breaking existing ones

### Task 4.3: Transport Layer

#### Subtasks:

**4.3.1: Implement stdio transport**
```zig
// Location: src/mcp_transport.zig
pub const StdioTransport = struct {
    server: *McpMemoryServer,
    
    pub fn run(self: *StdioTransport) !void {
        // Read from stdin, write to stdout
        // Similar pattern to existing CLI handling
    }
};
```

**4.3.2: Implement WebSocket transport**
```zig
// Location: src/mcp_transport.zig
pub const WebSocketTransport = struct {
    server: *McpMemoryServer,
    port: u16,
    
    pub fn start(self: *WebSocketTransport) !void {
        // WebSocket server implementation
        // Can leverage existing web server patterns from web_server.zig
    }
};
```
- **Integration**: Uses similar patterns to existing web server

---

## Phase 5: HTTP API Extensions (2-3 weeks)

### Task 5.1: Conversation HTTP Endpoints

**Files to modify:**
- `src/web_server.zig` - Add conversation endpoints

#### Subtasks:

**5.1.1: Add conversation routes**
```zig
// Location: src/web_server.zig (modify handleRequest method)
fn handleRequest(self: *Self, request: []const u8) ![]const u8 {
    // ... existing routing ...
    
    } else if (std.mem.eql(u8, method, "POST")) {
        if (std.mem.eql(u8, path, "/api/search")) {
            return try self.handleSearch(request);
        } else if (std.mem.eql(u8, path, "/api/text-search")) {
            return try self.handleTextSearch(request);
        } else if (std.mem.eql(u8, path, "/api/ingest")) {
            return try self.handleIngest(request);
        // NEW ENDPOINTS:
        } else if (std.mem.eql(u8, path, "/api/conversation/save")) {
            return try self.handleConversationSave(request);
        } else if (std.mem.eql(u8, path, "/api/conversation/search")) {
            return try self.handleConversationSearch(request);
        }
    } else if (std.mem.eql(u8, method, "GET")) {
        // ... existing GET handlers ...
        
        // NEW: Conversation history endpoint
        if (std.mem.startsWith(u8, path, "/api/conversation/history/")) {
            const session_id = path[27..]; // Extract session_id from path
            return try self.handleConversationHistory(session_id);
        }
    }
    
    // ... rest of existing code ...
}
```
- **Integration**: Extends existing routing without breaking existing endpoints

**5.1.2: Implement conversation handlers**
```zig
// Location: src/web_server.zig (add methods)
fn handleConversationSave(self: *Self, request: []const u8) ![]const u8 {
    const body = try self.extractRequestBody(request);
    
    const turn_json = try utils.parseJson(ConversationTurn, self.allocator, body);
    defer turn_json.deinit();
    
    const turn_id = try self.app.conversation_manager.saveTurn(turn_json.value);
    
    return try self.createJsonResponse(.{.turn_id = turn_id});
}
```
- **Integration**: Uses existing HTTP parsing patterns and JSON utilities

### Task 5.2: Update Web UI

**Files to modify:**
- `src/web/index.html` - Add conversation UI tabs
- `src/web/app.js` - Add conversation JavaScript functions  
- `src/web/styles.css` - Add conversation styling

#### Subtasks:

**5.2.1: Add conversation UI sections**
```html
<!-- Location: src/web/index.html (add after existing sections) -->
<div id="conversationSection" class="section">
    <h2>Conversation Memory</h2>
    <div class="tabs">
        <button class="tab-button active" onclick="showConversationTab('save')">Save Turn</button>
        <button class="tab-button" onclick="showConversationTab('search')">Search</button>
        <button class="tab-button" onclick="showConversationTab('history')">History</button>
    </div>
    <!-- Add forms for conversation operations -->
</div>
```
- **Integration**: Extends existing UI pattern with tabs and forms

**5.2.2: Add conversation JavaScript**
```javascript
// Location: src/web/app.js (add functions)
async function saveConversationTurn() {
    const sessionId = document.getElementById('sessionId').value;
    const userMessage = document.getElementById('userMessage').value;
    const assistantMessage = document.getElementById('assistantMessage').value;
    
    const response = await fetch('/api/conversation/save', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
            session_id: sessionId,
            user_message: userMessage,
            assistant_message: assistantMessage,
            timestamp: Math.floor(Date.now() / 1000)
        })
    });
    
    // Handle response...
}
```
- **Integration**: Uses existing JavaScript patterns and fetch utilities

---

## Phase 6: Advanced Features (4-6 weeks)

### Task 6.1: Memory Consolidation

**New file:** `src/memory_consolidator.zig`

#### Subtasks:

**6.1.1: Implement session summarization**
```zig
// Location: src/memory_consolidator.zig
pub const MemoryConsolidator = struct {
    allocator: std.mem.Allocator,
    app: *SemanticSearchApp,
    
    pub fn consolidateSession(self: *MemoryConsolidator, session_id: []const u8) !SessionSummary {
        // Analyze conversation turns
        // Extract key themes and decisions
        // Create summary document
    }
};
```

**6.1.2: Background consolidation process**
```zig
// Location: src/main.zig (extend BackgroundIndexer)
const BackgroundIndexer = struct {
    // ... existing fields ...
    consolidator: memory_consolidator.MemoryConsolidator,
    
    pub fn start(self: *BackgroundIndexer) !void {
        while (self.running) {
            // ... existing document processing ...
            
            // Add memory consolidation
            try self.consolidateExpiredSessions();
            
            std.time.sleep(self.app.config.persistent_memory.indexing_interval * std.time.ns_per_s);
        }
    }
};
```
- **Integration**: Extends existing background processing

---

## Integration Testing Tasks

### Task T.1: Unit Tests

**New files:**
- `tests/test_conversation.zig`
- `tests/test_context_extractor.zig`  
- `tests/test_mcp_server.zig`

#### Subtasks:

**T.1.1: Conversation manager tests**
```zig
// Location: tests/test_conversation.zig
test "ConversationManager.saveTurn saves and retrieves turns" {
    // Setup test database
    // Save conversation turn
    // Retrieve and verify
}

test "ConversationManager.searchConversations finds relevant turns" {
    // Setup test data
    // Perform search
    // Verify results
}
```

**T.1.2: MCP protocol tests**
```zig
// Location: tests/test_mcp_server.zig
test "MCP server handles memory/conversation/save requests" {
    // Create test MCP request
    // Send to server
    // Verify response format and data persistence
}
```

### Task T.2: Integration Tests

**New files:**
- `tests/integration/test_full_pipeline.zig`

#### Subtasks:

**T.2.1: End-to-end conversation flow**
```zig
test "Complete conversation memory pipeline" {
    // Save conversation turn
    // Extract context
    // Search and retrieve
    // Verify all components work together
}
```

**T.2.2: MCP protocol compliance**
```zig
test "MCP server protocol compliance" {
    // Test initialization handshake
    // Test all supported methods
    // Verify JSON-RPC 2.0 compliance
}
```

### Task T.3: Performance Tests

#### Subtasks:

**T.3.1: Conversation search performance**
- Test search latency with 10K+ conversations
- Verify memory usage stays within bounds
- Test concurrent conversation saves

**T.3.2: MCP server performance**
- Test WebSocket connection handling
- Verify stdio transport performance
- Test under concurrent load

---

## Documentation Tasks

### Task D.1: API Documentation

**New files:**
- `docs/conversation-api.md`
- `docs/mcp-server.md`

### Task D.2: Example Updates

**Files to create:**
- `examples/conversation_turn.json`
- `examples/conversation_query.json`
- `examples/mcp_client.py`
- `examples/agent_integration.py`

### Task D.3: Migration Guide

**New file:** `docs/migration-guide.md`
- How to upgrade existing installations
- Database migration scripts
- Configuration changes needed

---

## Dependencies & Prerequisites

### External Dependencies
- No new external dependencies required
- Leverages existing Zig standard library
- Uses existing Qdrant and ArangoDB clients

### Configuration Changes
- Update `config/config.json` with conversation settings
- Add MCP server configuration options
- Update Docker compose if needed

### Database Schema Evolution
- ArangoDB: Add new collections (backward compatible)
- Qdrant: No schema changes needed (document-based)
- Migration scripts for existing data

---

## Risk Mitigation

### Backward Compatibility
- All existing APIs remain unchanged
- New functionality is additive only
- Existing data continues to work

### Performance Impact
- New features are opt-in via configuration
- Background processing doesn't block existing operations
- Memory usage monitored and bounded

### Testing Strategy
- Comprehensive unit test coverage
- Integration tests for all new workflows
- Performance regression testing
- MCP protocol compliance verification

---

## Delivery Milestones

### Milestone 1 (Week 3): Basic Conversation Storage
- ConversationTurn storage and retrieval working
- Database extensions complete
- Basic HTTP endpoints functional

### Milestone 2 (Week 6): Context Extraction
- Context extraction pipeline working
- Enhanced relationship building
- Conversation-aware search functional

### Milestone 3 (Week 9): MCP Server
- MCP protocol implementation complete
- Stdio and WebSocket transports working
- Basic agent integration examples

### Milestone 4 (Week 12): Complete System
- All HTTP APIs implemented
- Web UI updated
- Documentation complete
- Ready for production deployment

### Milestone 5 (Week 16): Advanced Features
- Memory consolidation working
- Privacy features implemented
- Performance optimized
- Full feature set complete

This task breakdown provides clear, actionable items while showing exactly how each modification integrates with your existing Plasticity codebase. Each task maintains backward compatibility and leverages existing infrastructure wherever possible.
