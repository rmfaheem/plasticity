# LLM Agent Memory System Interface Design

## Overview

For an LLM agent memory system built on graph and vector databases, you need intuitive high-level interfaces that abstract the complexity while providing powerful memory capabilities. This document outlines the essential interfaces beyond basic MCP server functionality.

## Core Memory Interfaces

### 1. Conversation Memory Interface

#### Save Conversation Turn
```zig
const ConversationTurn = struct {
    id: []const u8,
    timestamp: i64,
    user_message: []const u8,
    assistant_message: []const u8,
    context: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
    importance_score: f32 = 0.5, // 0.0 to 1.0
    session_id: ?[]const u8 = null,
    metadata: ?std.json.Value = null,
};

const MemoryInterface = struct {
    // Save a conversation turn with automatic extraction
    pub fn saveConversation(
        self: *MemoryInterface,
        turn: ConversationTurn
    ) ![]const u8; // Returns memory_id

    // Recall conversations by keywords, context, or semantic similarity
    pub fn recallConversations(
        self: *MemoryInterface,
        query: []const u8,
        options: RecallOptions
    ) ![]ConversationTurn;

    // Get related conversations based on current context
    pub fn getRelatedMemories(
        self: *MemoryInterface,
        current_context: []const u8,
        limit: usize
    ) ![]ConversationTurn;
};

const RecallOptions = struct {
    max_results: usize = 10,
    similarity_threshold: f32 = 0.7,
    time_range: ?TimeRange = null,
    session_filter: ?[]const u8 = null,
    importance_threshold: f32 = 0.0,
};
```

### 2. Semantic Memory Interface

#### Concept and Relationship Management
```zig
const Concept = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    attributes: std.json.Value,
    confidence: f32,
    created_at: i64,
    last_updated: i64,
};

const Relationship = struct {
    id: []const u8,
    from_concept: []const u8,
    to_concept: []const u8,
    relationship_type: RelationshipType,
    strength: f32, // 0.0 to 1.0
    evidence: []const []const u8, // References to conversations/documents
};

const RelationshipType = enum {
    related_to,
    causes,
    is_a,
    part_of,
    similar_to,
    contradicts,
    implies,
    custom,
};

const SemanticMemory = struct {
    // Extract and store concepts from text
    pub fn extractConcepts(
        self: *SemanticMemory,
        text: []const u8,
        source_id: []const u8
    ) ![]Concept;

    // Build relationships between concepts
    pub fn buildRelationships(
        self: *SemanticMemory,
        concepts: []const Concept,
        context: []const u8
    ) ![]Relationship;

    // Query concept graph
    pub fn queryConcepts(
        self: *SemanticMemory,
        query: []const u8,
        depth: usize
    ) !ConceptGraph;
};
```

### 3. Episodic Memory Interface

#### Time-based and Context-aware Memory
```zig
const Episode = struct {
    id: []const u8,
    title: []const u8,
    summary: []const u8,
    start_time: i64,
    end_time: i64,
    participants: []const []const u8,
    location: ?[]const u8 = null,
    tags: []const []const u8,
    conversation_turns: []const []const u8, // References to conversation IDs
    key_insights: []const []const u8,
    emotional_tone: ?EmotionalTone = null,
};

const EmotionalTone = struct {
    valence: f32, // -1.0 (negative) to 1.0 (positive)
    arousal: f32, // 0.0 (calm) to 1.0 (excited)
    dominance: f32, // 0.0 (submissive) to 1.0 (dominant)
};

const EpisodicMemory = struct {
    // Create episode from conversation sequence
    pub fn createEpisode(
        self: *EpisodicMemory,
        conversation_ids: []const []const u8,
        metadata: EpisodeMetadata
    ) !Episode;

    // Recall episodes by temporal or contextual similarity
    pub fn recallEpisodes(
        self: *EpisodicMemory,
        query: EpisodeQuery
    ) ![]Episode;

    // Get episode timeline
    pub fn getTimeline(
        self: *EpisodicMemory,
        time_range: TimeRange,
        filters: ?TimelineFilters = null
    ) ![]Episode;
};
```

### 4. Adaptive Forgetting Interface

#### Intelligent Memory Management
```zig
const ForgettingStrategy = enum {
    importance_based,
    recency_based,
    frequency_based,
    composite,
};

const MemoryDecay = struct {
    base_decay_rate: f32 = 0.95,
    importance_multiplier: f32 = 2.0,
    access_boost: f32 = 1.1,
    max_memory_size: usize = 1000000,
    consolidation_threshold: f32 = 0.8,
};

const AdaptiveMemory = struct {
    // Apply forgetting curves to memories
    pub fn applyDecay(
        self: *AdaptiveMemory,
        strategy: ForgettingStrategy,
        params: MemoryDecay
    ) !void;

    // Consolidate similar memories
    pub fn consolidateMemories(
        self: *AdaptiveMemory,
        similarity_threshold: f32
    ) ![]ConsolidationResult;

    // Predict memory importance
    pub fn predictImportance(
        self: *AdaptiveMemory,
        memory_id: []const u8,
        context: []const u8
    ) !f32;
};
```

### 5. Context-Aware Retrieval Interface

#### Smart Memory Access
```zig
const ContextualQuery = struct {
    query: []const u8,
    current_context: []const u8,
    conversation_history: []const ConversationTurn,
    user_preferences: ?std.json.Value = null,
    temporal_context: ?TimeContext = null,
    emotional_context: ?EmotionalTone = null,
};

const RetrievalStrategy = enum {
    semantic_similarity,
    temporal_relevance,
    causal_chain,
    associative_network,
    hybrid,
};

const ContextualRetrieval = struct {
    // Multi-strategy memory retrieval
    pub fn retrieve(
        self: *ContextualRetrieval,
        query: ContextualQuery,
        strategy: RetrievalStrategy,
        options: RetrievalOptions
    ) !RetrievalResult;

    // Get memory chain (causally related memories)
    pub fn getMemoryChain(
        self: *ContextualRetrieval,
        anchor_memory: []const u8,
        direction: ChainDirection,
        max_length: usize
    ) ![]ConversationTurn;

    // Contextual memory ranking
    pub fn rankMemories(
        self: *ContextualRetrieval,
        memories: []const ConversationTurn,
        context: []const u8
    ) ![]RankedMemory;
};

const ChainDirection = enum { forward, backward, bidirectional };
```

### 6. Learning and Adaptation Interface

#### Continuous Improvement
```zig
const LearningSignal = struct {
    memory_id: []const u8,
    feedback_type: FeedbackType,
    strength: f32,
    timestamp: i64,
    context: []const u8,
};

const FeedbackType = enum {
    positive_recall,
    negative_recall,
    correction,
    reinforcement,
    irrelevance,
};

const AdaptiveLearning = struct {
    // Learn from retrieval feedback
    pub fn processFeedback(
        self: *AdaptiveLearning,
        signal: LearningSignal
    ) !void;

    // Adjust memory weights based on usage patterns
    pub fn updateMemoryWeights(
        self: *AdaptiveLearning,
        access_patterns: []const AccessPattern
    ) !void;

    // Optimize retrieval strategies
    pub fn optimizeRetrieval(
        self: *AdaptiveLearning,
        performance_metrics: RetrievalMetrics
    ) !StrategyWeights;
};
```

## MCP Server Integration

### Memory-Specific MCP Methods

```zig
const MemoryMcpMethods = struct {
    // Core memory operations
    pub const SAVE_CONVERSATION = "memory/conversation/save";
    pub const RECALL_CONVERSATION = "memory/conversation/recall";
    pub const GET_RELATED = "memory/conversation/related";
    
    // Semantic operations
    pub const EXTRACT_CONCEPTS = "memory/semantic/extract";
    pub const QUERY_CONCEPTS = "memory/semantic/query";
    pub const BUILD_RELATIONSHIPS = "memory/semantic/relate";
    
    // Episodic operations
    pub const CREATE_EPISODE = "memory/episodic/create";
    pub const RECALL_EPISODES = "memory/episodic/recall";
    pub const GET_TIMELINE = "memory/episodic/timeline";
    
    // Meta operations
    pub const MEMORY_STATS = "memory/stats";
    pub const OPTIMIZE_MEMORY = "memory/optimize";
    pub const EXPORT_MEMORY = "memory/export";
};
```

### Memory Resources

```zig
const MemoryResources = struct {
    // Dynamic resources representing memory state
    pub const RECENT_CONVERSATIONS = "memory://conversations/recent";
    pub const CONCEPT_GRAPH = "memory://graph/concepts";
    pub const EPISODE_TIMELINE = "memory://episodes/timeline";
    pub const MEMORY_METRICS = "memory://metrics/current";
    pub const LEARNING_INSIGHTS = "memory://learning/insights";
};
```

## High-Level API Design

### Simple Agent Interface

```zig
const AgentMemory = struct {
    mcp_client: *McpClient,
    session_id: []const u8,

    // Dead simple interface for agents
    pub fn remember(self: *AgentMemory, user_msg: []const u8, assistant_msg: []const u8) !void {
        const turn = ConversationTurn{
            .id = generateId(),
            .timestamp = std.time.timestamp(),
            .user_message = user_msg,
            .assistant_message = assistant_msg,
            .session_id = self.session_id,
        };

        _ = try self.mcp_client.call(MemoryMcpMethods.SAVE_CONVERSATION, turn);
    }

    pub fn recall(self: *AgentMemory, keywords: []const u8) ![]ConversationTurn {
        const options = RecallOptions{
            .max_results = 5,
            .similarity_threshold = 0.7,
        };

        const result = try self.mcp_client.call(MemoryMcpMethods.RECALL_CONVERSATION, .{
            .query = keywords,
            .options = options,
        });

        return parseConversationTurns(result);
    }

    pub fn getContext(self: *AgentMemory, current_msg: []const u8) ![]ConversationTurn {
        const result = try self.mcp_client.call(MemoryMcpMethods.GET_RELATED, .{
            .current_context = current_msg,
            .limit = 3,
        });

        return parseConversationTurns(result);
    }
};
```

### Advanced Query Interface

```zig
const MemoryQuery = struct {
    // Natural language query builder
    pub fn fromNaturalLanguage(query: []const u8) !ContextualQuery {
        // Parse natural language into structured query
        // "Remember what we discussed about databases last week"
        // -> ContextualQuery with temporal and semantic filters
    }

    // Fluent query builder
    pub fn new() QueryBuilder {
        return QueryBuilder.init();
    }
};

const QueryBuilder = struct {
    query: ContextualQuery,

    pub fn withText(self: *QueryBuilder, text: []const u8) *QueryBuilder {
        self.query.query = text;
        return self;
    }

    pub fn inTimeRange(self: *QueryBuilder, start: i64, end: i64) *QueryBuilder {
        self.query.temporal_context = TimeContext{ .start = start, .end = end };
        return self;
    }

    pub fn withEmotion(self: *QueryBuilder, emotion: EmotionalTone) *QueryBuilder {
        self.query.emotional_context = emotion;
        return self;
    }

    pub fn execute(self: *QueryBuilder) !RetrievalResult {
        // Execute the built query
    }
};
```

## Additional Considerations

### 1. Privacy and Security Interface

```zig
const PrivacyControls = struct {
    pub fn setRetentionPolicy(
        self: *PrivacyControls,
        memory_type: MemoryType,
        retention_days: u32
    ) !void;

    pub fn anonymizeMemory(
        self: *PrivacyControls,
        memory_id: []const u8
    ) !void;

    pub fn deletePersonalData(
        self: *PrivacyControls,
        user_id: []const u8
    ) !void;
};
```

### 2. Multi-Agent Memory Sharing

```zig
const SharedMemory = struct {
    pub fn shareMemory(
        self: *SharedMemory,
        memory_id: []const u8,
        target_agents: []const []const u8,
        permissions: SharingPermissions
    ) !void;

    pub fn getSharedMemories(
        self: *SharedMemory,
        agent_id: []const u8
    ) ![]SharedMemoryItem;
};
```

### 3. Memory Visualization Interface

```zig
const MemoryVisualization = struct {
    pub fn generateConceptMap(
        self: *MemoryVisualization,
        center_concept: []const u8,
        depth: usize
    ) !GraphVisualization;

    pub fn generateTimeline(
        self: *MemoryVisualization,
        time_range: TimeRange
    ) !TimelineVisualization;
};
```

## Implementation Priorities

1. **Start with Core Interfaces**: ConversationMemory and ContextualRetrieval
2. **Add Semantic Layer**: Concept extraction and relationship building
3. **Implement Adaptive Features**: Forgetting and learning mechanisms
4. **Enhance with Advanced Features**: Episodic memory and multi-agent sharing
5. **Add Visualization and Analytics**: For debugging and insights

This design provides intuitive high-level interfaces while leveraging the power of your graph and vector databases underneath. The MCP server acts as the orchestration layer, making the memory system accessible to any MCP-compatible LLM agent.