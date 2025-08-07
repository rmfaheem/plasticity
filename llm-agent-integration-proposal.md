# LLM Agent Integration Proposal: Conversation Memory & Retrieval System

## Executive Summary

This proposal outlines the extension of the Plasticity semantic search system to become a user-friendly LLM agent memory platform. The current system provides excellent vector search and graph-based contextual understanding, but lacks conversation management capabilities essential for LLM agents. This proposal details how to add conversation turn storage, retrieval, and an MCP (Model Context Protocol) server interface to transform Plasticity into a comprehensive agent memory system.

## Current System Analysis

### Strengths
- **Robust Architecture**: Zig-based system with Qdrant (vector) + ArangoDB (graph) storage
- **Advanced Reranking**: Multi-factor scoring combining similarity, recency, and graph weights
- **Temporal Awareness**: Built-in time-based filtering and decay
- **Flexible Data Model**: Support for metadata, relationships, and context types
- **Performance Optimized**: Single binary, efficient memory management, streaming JSON

### Existing Components
1. **Document Ingestion**: JSON document storage with vector embeddings
2. **Vector Search**: Semantic similarity search via Qdrant
3. **Graph Context**: Relationship modeling via ArangoDB
4. **Re-ranking**: Weighted scoring algorithm
5. **Web Interface**: Basic search and ingestion UI
6. **HTTP API**: `/api/search`, `/api/ingest`, `/api/text-search` endpoints

### Current Limitations for LLM Agents
- No conversation turn management
- Missing agent session handling  
- No conversation-specific retrieval patterns
- Limited context extraction from conversations
- No MCP server implementation for agent integration

## Proposed Architecture

### Enhanced System Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                     LLM Agent Memory System                     │
├─────────────────┬─────────────────┬─────────────────┬───────────┤
│  MCP Server     │ Conversation    │  Semantic       │  Current  │
│  Interface      │  Management     │  Search Core    │  System   │
│                 │                 │                 │           │
│ • Memory tools  │ • Turn storage  │ • Vector search │ • Qdrant  │
│ • Resources     │ • Session mgmt  │ • Graph context │ • ArangoDB│
│ • Agent APIs    │ • Context ext.  │ • Re-ranking    │ • Zig core│
└─────────────────┴─────────────────┴─────────────────┴───────────┘
```

### Core Components Extension

#### 1. Conversation Memory Layer
```zig
pub const ConversationTurn = struct {
    id: []const u8,
    session_id: []const u8,
    turn_number: u32,
    timestamp: i64,
    user_message: []const u8,
    assistant_message: []const u8,
    context_extracted: []ContextExtraction,
    importance_score: f32,
    tags: []const []const u8,
    metadata: ?std.json.Value,
};

pub const ContextExtraction = struct {
    type: ContextType, // preference, decision, fact, task
    content: []const u8,
    confidence: f32,
    entities: []const []const u8,
};
```

#### 2. Session Management
```zig
pub const AgentSession = struct {
    session_id: []const u8,
    agent_id: []const u8,
    user_id: ?[]const u8,
    created_at: i64,
    last_active: i64,
    conversation_turns: []const []const u8, // turn IDs
    session_summary: ?[]const u8,
    preferences: std.json.Value,
};
```

#### 3. Enhanced Search Queries
```zig
pub const ConversationQuery = struct {
    query_text: []const u8,
    session_id: ?[]const u8,
    user_id: ?[]const u8,
    context_types: []const ContextType,
    time_range: ?TimeRange,
    include_conversation_context: bool,
    max_turns: u32,
};
```

## Implementation Plan

### Phase 1: Conversation Storage Foundation

#### 1.1 Database Schema Extensions

**Qdrant Collections:**
- Extend existing `semantic_chunks` collection for conversation turns
- Add conversation-specific metadata fields

**ArangoDB Collections:**
- `conversation_turns`: Store conversation metadata and relationships
- `agent_sessions`: Track agent sessions and preferences  
- `context_extractions`: Store extracted context with confidence scores
- Enhanced `edges` for conversation relationships

#### 1.2 Data Models

```zig
// src/conversation.zig
pub const ConversationManager = struct {
    allocator: std.mem.Allocator,
    qdrant_client: *qdrant.QdrantClient,
    arango_client: *arango.ArangoClient,

    pub fn saveTurn(self: *ConversationManager, turn: ConversationTurn) ![]const u8;
    pub fn getConversationHistory(self: *ConversationManager, session_id: []const u8, limit: u32) ![]ConversationTurn;
    pub fn searchConversations(self: *ConversationManager, query: ConversationQuery) ![]ConversationTurn;
    pub fn extractContext(self: *ConversationManager, turn: ConversationTurn) ![]ContextExtraction;
};
```

#### 1.3 Configuration Extensions

```json
{
  "conversation_memory": {
    "auto_extract_context": true,
    "context_extraction_threshold": 0.7,
    "session_timeout_hours": 24,
    "max_turns_per_session": 1000
  }
}
```

### Phase 2: Context Extraction & Intelligence

#### 2.1 Intelligent Context Extraction

```zig
pub const ContextExtractor = struct {
    pub fn extractFromTurn(turn: ConversationTurn) ![]ContextExtraction;
    
    // Extract different types of context
    fn extractPreferences(text: []const u8) ![]ContextExtraction;
    fn extractDecisions(text: []const u8) ![]ContextExtraction;
    fn extractFacts(text: []const u8) ![]ContextExtraction;
    fn extractTasks(text: []const u8) ![]ContextExtraction;
};
```

#### 2.2 Relationship Building

Automatically build relationships between:
- Conversation turns within sessions
- Related topics across conversations
- User preferences and decisions
- Context extractions and entities

### Phase 3: Enhanced Retrieval for Agents

#### 3.1 Conversation-Aware Search

```zig
pub const AgentRetrieval = struct {
    pub fn getRelevantContext(
        self: *AgentRetrieval,
        current_message: []const u8,
        session_id: []const u8,
        max_context_turns: u32
    ) !ConversationContext;
    
    pub fn searchMemory(
        self: *AgentRetrieval,
        query: ConversationQuery
    ) ![]ConversationTurn;
};

pub const ConversationContext = struct {
    recent_turns: []ConversationTurn,
    relevant_history: []ConversationTurn,
    extracted_preferences: []ContextExtraction,
    related_sessions: []AgentSession,
};
```

#### 3.2 Memory Consolidation

```zig
pub const MemoryConsolidator = struct {
    pub fn consolidateSession(session_id: []const u8) !SessionSummary;
    pub fn updateUserProfile(user_id: []const u8) !UserProfile;
    pub fn buildTopicModel(conversations: []ConversationTurn) !TopicModel;
};
```

### Phase 4: MCP Server Implementation

#### 4.1 MCP Protocol Integration

```zig
// src/mcp_server.zig
pub const McpMemoryServer = struct {
    allocator: std.mem.Allocator,
    app: *SemanticSearchApp,
    conversation_manager: *ConversationManager,
    
    pub fn init(allocator: std.mem.Allocator, app: *SemanticSearchApp) !McpMemoryServer;
    pub fn handleRequest(self: *McpMemoryServer, request: []const u8) ![]const u8;
};
```

#### 4.2 MCP Methods

**Core Memory Operations:**
- `memory/conversation/save` - Save conversation turn
- `memory/conversation/recall` - Retrieve conversation history
- `memory/conversation/search` - Semantic search across conversations
- `memory/context/extract` - Extract context from text
- `memory/session/create` - Create new agent session
- `memory/session/update` - Update session preferences

**Resources:**
- `memory://conversations/recent` - Recent conversation turns
- `memory://sessions/active` - Active agent sessions  
- `memory://context/preferences` - User preferences
- `memory://topics/trending` - Trending conversation topics

**Tools:**
- `summarize_conversation` - Generate conversation summaries
- `extract_preferences` - Extract user preferences
- `find_related_context` - Find related conversation context

#### 4.3 Agent Integration API

```zig
pub const AgentMemoryAPI = struct {
    pub fn remember(
        session_id: []const u8,
        user_message: []const u8,
        assistant_message: []const u8
    ) !void;
    
    pub fn recall(
        session_id: []const u8,
        query: []const u8,
        max_results: u32
    ) ![]ConversationTurn;
    
    pub fn getContext(
        session_id: []const u8,
        current_message: []const u8
    ) !ConversationContext;
};
```

### Phase 5: Advanced Features

#### 5.1 Adaptive Forgetting

```zig
pub const MemoryManager = struct {
    pub fn applyForgettingCurve(session_id: []const u8) !void;
    pub fn consolidateImportantMemories() !void;
    pub fn archiveOldSessions(retention_days: u32) !void;
};
```

#### 5.2 Multi-Agent Support

```zig
pub const MultiAgentMemory = struct {
    pub fn shareContext(
        from_session: []const u8,
        to_session: []const u8,
        context_id: []const u8
    ) !void;
    
    pub fn getSharedMemories(session_id: []const u8) ![]SharedContext;
};
```

#### 5.3 Privacy & Security

```zig
pub const PrivacyManager = struct {
    pub fn anonymizePersonalData(user_id: []const u8) !void;
    pub fn setRetentionPolicy(data_type: DataType, retention_days: u32) !void;
    pub fn exportUserData(user_id: []const u8) ![]u8;
};
```

## API Endpoints

### New HTTP Endpoints

```
POST /api/conversation/save
POST /api/conversation/search  
GET  /api/conversation/history/{session_id}
POST /api/context/extract
GET  /api/session/{session_id}
POST /api/session/create
PUT  /api/session/{session_id}/preferences
```

### MCP Server Endpoints

```
ws://localhost:8081/mcp     # WebSocket transport
stdio://semantic-search-mcp # Stdio transport  
```

## Database Schema Changes

### Qdrant Schema Extensions

```json
{
  "conversation_turn": {
    "vector": [...],
    "payload": {
      "id": "turn_123",
      "session_id": "session_456", 
      "turn_number": 5,
      "timestamp": 1703123456,
      "message_type": "user|assistant",
      "content": "...",
      "importance_score": 0.8,
      "context_extractions": [...],
      "user_id": "user_789"
    }
  }
}
```

### ArangoDB Schema Extensions

```javascript
// Collections
db._create("conversation_turns");
db._create("agent_sessions");  
db._create("context_extractions");
db._create("user_profiles");

// New edge types
db.edges.ensureIndex({type: "persistent", fields: ["relationship_type"]});
// relationship_types: "PART_OF_SESSION", "FOLLOWS_TURN", "EXTRACTS_TO", "REFERENCES"
```

## Configuration Changes

### Enhanced Config Structure

```json
{
  "qdrant": {...},
  "arango": {...},
  "ranking": {...},
  "server": {...},
  "persistent_memory": {...},
  "conversation_memory": {
    "auto_extract_context": true,
    "context_extraction_threshold": 0.7,
    "session_timeout_hours": 24,
    "max_turns_per_session": 1000,
    "enable_forgetting": true,
    "forgetting_curve_factor": 0.95
  },
  "mcp_server": {
    "enabled": true,
    "port": 8081,
    "transport": ["websocket", "stdio"],
    "auth_required": false
  },
  "privacy": {
    "anonymize_after_days": 365,
    "retention_policy": "user_controlled",
    "allow_data_export": true
  }
}
```

## Migration Plan

### 1. Backward Compatibility
- All existing APIs remain functional
- Current document ingestion continues to work
- Existing Qdrant/ArangoDB data is preserved

### 2. Incremental Rollout
- Phase 1: Core conversation storage (2-3 weeks)
- Phase 2: Context extraction (2-3 weeks)  
- Phase 3: Enhanced retrieval (2-3 weeks)
- Phase 4: MCP server (3-4 weeks)
- Phase 5: Advanced features (4-6 weeks)

### 3. Testing Strategy
- Unit tests for all new components
- Integration tests for conversation flows
- Performance tests for large conversation histories
- MCP protocol compliance tests

## Usage Examples

### 1. Basic Agent Integration (MCP)

```python
# Python LLM agent using MCP client
import mcp

client = mcp.Client("ws://localhost:8081/mcp")

# Save conversation turn
await client.call("memory/conversation/save", {
    "session_id": "chat_123",
    "user_message": "I prefer Python over JavaScript",
    "assistant_message": "I'll remember that you prefer Python for future suggestions."
})

# Retrieve relevant context
context = await client.call("memory/conversation/recall", {
    "session_id": "chat_123", 
    "query": "programming languages",
    "max_results": 5
})
```

### 2. Advanced Context Retrieval

```zig
// Zig agent using direct API
const query = ConversationQuery{
    .query_text = "database optimization",
    .session_id = "session_456",
    .context_types = &[_]ContextType{.decision, .preference},
    .include_conversation_context = true,
    .max_turns = 10
};

const results = try agent_retrieval.searchMemory(query);
```

### 3. HTTP API Usage

```bash
# Save conversation turn
curl -X POST http://localhost:8080/api/conversation/save \
  -H "Content-Type: application/json" \
  -d '{
    "session_id": "chat_789",
    "user_message": "Set up automated backups",
    "assistant_message": "I can help you set up automated backups...",
    "tags": ["backup", "automation"]
  }'

# Search conversations
curl -X POST http://localhost:8080/api/conversation/search \
  -H "Content-Type: application/json" \
  -d '{
    "query_text": "backup strategy",
    "session_id": "chat_789",
    "max_results": 5
  }'
```

## Performance Considerations

### Scalability Targets
- **Conversations**: 1M+ conversations per agent
- **Turn Volume**: 10K+ turns per day
- **Search Latency**: <100ms for context retrieval
- **Memory Usage**: <1GB for 100K conversations

### Optimization Strategies
- **Conversation Chunking**: Split long conversations into chunks
- **Lazy Loading**: Load conversation history on demand
- **Caching**: Cache frequently accessed conversations
- **Background Processing**: Async context extraction and consolidation

## Security & Privacy

### Data Protection
- **Encryption at Rest**: Sensitive conversation data encrypted
- **Access Control**: Session-based access to conversations
- **Audit Logging**: Track all memory access and modifications
- **Data Anonymization**: Remove PII from old conversations

### Privacy Features
- **Right to be Forgotten**: Complete user data deletion
- **Data Export**: Export user conversation history
- **Retention Policies**: Configurable data retention periods
- **Opt-out Mechanisms**: Disable memory features per user

## Benefits

### For LLM Agents
1. **Persistent Context**: Remember user preferences across sessions
2. **Intelligent Retrieval**: Find relevant conversation history automatically
3. **Adaptive Learning**: Improve responses based on past interactions
4. **Multi-Session Memory**: Share context across different conversations

### For Developers
1. **Standard Interface**: MCP protocol for easy integration
2. **Flexible APIs**: HTTP REST and MCP options
3. **Rich Context**: Structured context extraction
4. **Performance**: Optimized for real-time agent interactions

### For Users
1. **Personalized Experience**: Agents remember preferences and history
2. **Continuity**: Seamless conversation across sessions
3. **Privacy Control**: Manage memory retention and data sharing
4. **Transparency**: Understand what agents remember

## Conclusion

This proposal transforms Plasticity from a semantic search system into a comprehensive LLM agent memory platform. By leveraging the existing robust architecture and adding conversation management, context extraction, and MCP server capabilities, we create a powerful tool for building intelligent, memory-enabled AI agents.

The incremental implementation plan ensures backward compatibility while adding substantial value for LLM agent developers. The MCP server provides standard protocol compliance for easy integration with existing agent frameworks.

**Timeline**: 12-16 weeks for full implementation
**Effort**: 2-3 developers  
**Impact**: Transforms Plasticity into a complete agent memory solution

The proposed system will enable LLM agents to maintain rich, contextual conversations while providing developers with powerful tools for building more intelligent and personalized AI applications.
