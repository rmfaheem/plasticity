const std = @import("std");

// Context types for semantic classification
pub const ContextType = enum { 
    preference, 
    decision, 
    fact, 
    task, 
    observation,
    intent,
    emotion,
    goal 
};

// Context extraction result from conversation analysis
pub const ContextExtraction = struct {
    type: ContextType,
    content: []const u8,
    confidence: f32,
    entities: []const []const u8,

    pub fn deinit(self: *const ContextExtraction, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        for (self.entities) |entity| {
            allocator.free(entity);
        }
        allocator.free(self.entities);
    }
};

// ConversationTurn struct matching LLM Agent Integration Proposal specification
pub const ConversationTurn = struct {
    id: []const u8,
    session_id: []const u8,
    turn_number: u32,
    timestamp: i64,
    user_message: []const u8,                    // Required field (not optional)
    assistant_message: []const u8,               // Required field (not optional)
    context_extracted: []ContextExtraction,     // New field from proposal
    importance_score: f32,
    tags: []const []const u8,                   // Required field (not optional)
    metadata: ?std.json.Value,

    pub fn deinit(self: *const ConversationTurn, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.session_id);
        allocator.free(self.user_message);
        allocator.free(self.assistant_message);
        
        // Free context extractions
        for (self.context_extracted) |*extraction| {
            extraction.deinit(allocator);
        }
        allocator.free(self.context_extracted);
        
        // Free tags
        for (self.tags) |tag| {
            allocator.free(tag);
        }
        allocator.free(self.tags);
        
        // Free metadata if present
        if (self.metadata) |*meta| {
            deinitJsonValue(meta, allocator);
        }
    }
};

fn deinitJsonValue(value: *std.json.Value, allocator: std.mem.Allocator) void {
    switch (value.*) {
        .string => |
        s| allocator.free(s),
        .array => |*arr| {
            for (arr.items) |*item| deinitJsonValue(item, allocator);
            arr.deinit();
        },
        .object => |*obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                var v = entry.value_ptr.*;
                deinitJsonValue(&v, allocator);
            }
            obj.deinit();
        },
        else => {},
    }
}

pub const TimeRange = struct { start: i64, end: i64 };

// AgentSession struct matching LLM Agent Integration Proposal specification
pub const AgentSession = struct {
    session_id: []const u8,
    agent_id: []const u8,
    user_id: ?[]const u8,
    created_at: i64,
    last_active: i64,
    conversation_turns: []const []const u8, // turn IDs
    session_summary: ?[]const u8,
    preferences: std.json.Value,

    pub fn deinit(self: *const AgentSession, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.agent_id);
        if (self.user_id) |uid| allocator.free(uid);
        
        for (self.conversation_turns) |turn_id| {
            allocator.free(turn_id);
        }
        allocator.free(self.conversation_turns);
        
        if (self.session_summary) |summary| allocator.free(summary);
        
        var prefs = self.preferences;
        deinitJsonValue(&prefs, allocator);
    }
};

// ConversationQuery struct matching LLM Agent Integration Proposal specification
pub const ConversationQuery = struct {
    query_text: []const u8,
    session_id: ?[]const u8,
    user_id: ?[]const u8,
    context_types: []const ContextType,
    time_range: ?TimeRange,
    include_conversation_context: bool,
    max_turns: u32,

    pub fn deinit(self: *const ConversationQuery, allocator: std.mem.Allocator) void {
        allocator.free(self.query_text);
        if (self.session_id) |sid| allocator.free(sid);
        if (self.user_id) |uid| allocator.free(uid);
        allocator.free(self.context_types);
    }
};

pub const RecallOptions = struct {
    max_results: usize = 10,
    similarity_threshold: f32 = 0.7,
    time_range: ?TimeRange = null,
    session_filter: ?[]const u8 = null,
    importance_threshold: f32 = 0.0,
    tags: ?[][]const u8 = null,
};

pub const MemoryError = error{ NotImplemented };

pub const MemoryInterface = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MemoryInterface {
        return .{ .allocator = allocator };
    }

    pub fn saveConversation(self: *MemoryInterface, turn: ConversationTurn) ![]const u8 {
        _ = self;
        _ = turn;
        return MemoryError.NotImplemented;
    }

    pub fn recallConversations(self: *MemoryInterface, query: []const u8, options: RecallOptions) ![]ConversationTurn {
        _ = self;
        _ = query;
        _ = options;
        return MemoryError.NotImplemented;
    }

    pub fn getRelatedMemories(self: *MemoryInterface, current_context: []const u8, limit: usize) ![]ConversationTurn {
        _ = self;
        _ = current_context;
        _ = limit;
        return MemoryError.NotImplemented;
    }

    // Session management methods per LLM Agent Integration Proposal
    pub fn createSession(self: *MemoryInterface, agent_id: []const u8, user_id: ?[]const u8) !AgentSession {
        _ = self;
        _ = agent_id;
        _ = user_id;
        return MemoryError.NotImplemented;
    }

    pub fn getSession(self: *MemoryInterface, session_id: []const u8) !?AgentSession {
        _ = self;
        _ = session_id;
        return MemoryError.NotImplemented;
    }

    pub fn updateSession(self: *MemoryInterface, session: AgentSession) !void {
        _ = self;
        _ = session;
        return MemoryError.NotImplemented;
    }

    pub fn expireSessions(self: *MemoryInterface, timeout_hours: u64) !void {
        _ = self;
        _ = timeout_hours;
        return MemoryError.NotImplemented;
    }

    // Context extraction method per proposal
    pub fn extractContext(self: *MemoryInterface, text: []const u8, extraction_types: ?[]ContextType) ![]ContextExtraction {
        _ = self;
        _ = text;
        _ = extraction_types;
        return MemoryError.NotImplemented;
    }
};
