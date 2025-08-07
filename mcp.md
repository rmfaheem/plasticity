# MCP Server Implementation Guide

## Table of Contents
1. [Introduction](#introduction)
2. [MCP Protocol Overview](#mcp-protocol-overview)
3. [Core Protocol Messages](#core-protocol-messages)
4. [Server Implementation in Zig](#server-implementation-in-zig)
5. [Authentication](#authentication)
6. [Extensions](#extensions)
7. [Error Handling](#error-handling)
8. [Best Practices](#best-practices)
9. [Complete Example](#complete-example)

## Introduction

The Model Context Protocol (MCP) is a standardized protocol that enables AI models to securely interact with external tools, data sources, and services. MCP servers act as bridges between AI models and various resources, providing a consistent interface for data access and tool execution.

This guide focuses on implementing MCP servers using Zig, a systems programming language that offers excellent performance and safety guarantees.

## MCP Protocol Overview

### Architecture

MCP follows a client-server architecture where:
- **MCP Client**: The AI model or application consuming resources
- **MCP Server**: Your implementation that provides tools, resources, and prompts
- **Transport Layer**: Communication mechanism (stdio, HTTP, WebSocket)

### Transport Mechanisms

MCP supports multiple transport layers:
1. **Standard I/O (stdio)**: Process-based communication
2. **HTTP**: RESTful API with Server-Sent Events
3. **WebSocket**: Real-time bidirectional communication

### Message Format

All MCP messages use JSON-RPC 2.0 format:

```json
{
  "jsonrpc": "2.0",
  "id": "unique-request-id",
  "method": "method_name",
  "params": {
    "parameter": "value"
  }
}
```

## Core Protocol Messages

### Initialization

The MCP protocol begins with a handshake:

1. **Client → Server**: `initialize` request
2. **Server → Client**: `initialize` response with capabilities
3. **Client → Server**: `initialized` notification

### Capabilities

Servers declare their capabilities during initialization:

```json
{
  "capabilities": {
    "resources": {
      "subscribe": true,
      "listChanged": true
    },
    "tools": {
      "listChanged": true
    },
    "prompts": {
      "listChanged": true
    },
    "logging": {
      "level": "info"
    }
  }
}
```

### Core Methods

#### Resources
- `resources/list`: List available resources
- `resources/read`: Read resource content
- `resources/subscribe`: Subscribe to resource changes
- `resources/unsubscribe`: Unsubscribe from resource changes

#### Tools
- `tools/list`: List available tools
- `tools/call`: Execute a tool

#### Prompts
- `prompts/list`: List available prompt templates
- `prompts/get`: Get a specific prompt template

#### Notifications
- `notifications/resources/list_changed`: Resource list changed
- `notifications/tools/list_changed`: Tool list changed
- `notifications/prompts/list_changed`: Prompt list changed

## Server Implementation in Zig

### Project Structure

```
mcp_server/
├── build.zig
├── src/
│   ├── main.zig
│   ├── server.zig
│   ├── protocol.zig
│   ├── transport/
│   │   ├── stdio.zig
│   │   ├── http.zig
│   │   └── websocket.zig
│   ├── handlers/
│   │   ├── resources.zig
│   │   ├── tools.zig
│   │   └── prompts.zig
│   └── auth/
│       └── auth.zig
```

### Basic Types and Structures

```zig
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

// JSON-RPC message structure
const JsonRpcMessage = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?json.Value = null,
    method: ?[]const u8 = null,
    params: ?json.Value = null,
    result: ?json.Value = null,
    @"error": ?JsonRpcError = null,
};

const JsonRpcError = struct {
    code: i32,
    message: []const u8,
    data: ?json.Value = null,
};

// MCP-specific types
const ServerCapabilities = struct {
    resources: ?ResourceCapabilities = null,
    tools: ?ToolCapabilities = null,
    prompts: ?PromptCapabilities = null,
    logging: ?LoggingCapabilities = null,
};

const ResourceCapabilities = struct {
    subscribe: bool = false,
    listChanged: bool = false,
};

const ToolCapabilities = struct {
    listChanged: bool = false,
};

const PromptCapabilities = struct {
    listChanged: bool = false,
};

const LoggingCapabilities = struct {
    level: []const u8 = "info",
};

const Resource = struct {
    uri: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
};

const Tool = struct {
    name: []const u8,
    description: []const u8,
    inputSchema: json.Value,
};

const Prompt = struct {
    name: []const u8,
    description: []const u8,
    arguments: ?[]PromptArgument = null,
};

const PromptArgument = struct {
    name: []const u8,
    description: []const u8,
    required: bool = false,
};
```

### Core Server Implementation

```zig
const McpServer = struct {
    allocator: Allocator,
    capabilities: ServerCapabilities,
    resources: std.ArrayList(Resource),
    tools: std.ArrayList(Tool),
    prompts: std.ArrayList(Prompt),
    initialized: bool = false,

    pub fn init(allocator: Allocator) McpServer {
        return McpServer{
            .allocator = allocator,
            .capabilities = ServerCapabilities{
                .resources = ResourceCapabilities{
                    .subscribe = true,
                    .listChanged = true,
                },
                .tools = ToolCapabilities{
                    .listChanged = true,
                },
                .prompts = PromptCapabilities{
                    .listChanged = true,
                },
                .logging = LoggingCapabilities{
                    .level = "info",
                },
            },
            .resources = std.ArrayList(Resource).init(allocator),
            .tools = std.ArrayList(Tool).init(allocator),
            .prompts = std.ArrayList(Prompt).init(allocator),
        };
    }

    pub fn deinit(self: *McpServer) void {
        self.resources.deinit();
        self.tools.deinit();
        self.prompts.deinit();
    }

    pub fn handleRequest(self: *McpServer, request: []const u8) ![]const u8 {
        var parsed = try json.parseFromSlice(JsonRpcMessage, self.allocator, request, .{});
        defer parsed.deinit();

        const message = parsed.value;
        
        if (message.method) |method| {
            return try self.dispatchMethod(method, message.params, message.id);
        }

        return try self.createErrorResponse(message.id, -32600, "Invalid Request");
    }

    fn dispatchMethod(self: *McpServer, method: []const u8, params: ?json.Value, id: ?json.Value) ![]const u8 {
        if (std.mem.eql(u8, method, "initialize")) {
            return try self.handleInitialize(params, id);
        } else if (std.mem.eql(u8, method, "initialized")) {
            return try self.handleInitialized(params, id);
        } else if (std.mem.eql(u8, method, "resources/list")) {
            return try self.handleResourcesList(params, id);
        } else if (std.mem.eql(u8, method, "resources/read")) {
            return try self.handleResourcesRead(params, id);
        } else if (std.mem.eql(u8, method, "tools/list")) {
            return try self.handleToolsList(params, id);
        } else if (std.mem.eql(u8, method, "tools/call")) {
            return try self.handleToolsCall(params, id);
        } else if (std.mem.eql(u8, method, "prompts/list")) {
            return try self.handlePromptsList(params, id);
        } else if (std.mem.eql(u8, method, "prompts/get")) {
            return try self.handlePromptsGet(params, id);
        }

        return try self.createErrorResponse(id, -32601, "Method not found");
    }

    fn handleInitialize(self: *McpServer, params: ?json.Value, id: ?json.Value) ![]const u8 {
        // Validate client capabilities and protocol version
        const result = json.Value{
            .object = std.json.ObjectMap.init(self.allocator),
        };
        
        try result.object.put("protocolVersion", json.Value{ .string = "2024-11-05" });
        try result.object.put("capabilities", try json.valueFromObject(self.capabilities, self.allocator));
        try result.object.put("serverInfo", json.Value{
            .object = blk: {
                var info = std.json.ObjectMap.init(self.allocator);
                try info.put("name", json.Value{ .string = "zig-mcp-server" });
                try info.put("version", json.Value{ .string = "1.0.0" });
                break :blk info;
            },
        });

        return try self.createSuccessResponse(id, result);
    }

    fn handleInitialized(self: *McpServer, params: ?json.Value, id: ?json.Value) ![]const u8 {
        _ = params;
        _ = id;
        self.initialized = true;
        // This is a notification, no response needed
        return "";
    }

    fn createSuccessResponse(self: *McpServer, id: ?json.Value, result: json.Value) ![]const u8 {
        const response = JsonRpcMessage{
            .id = id,
            .result = result,
        };
        return try json.stringifyAlloc(self.allocator, response, .{});
    }

    fn createErrorResponse(self: *McpServer, id: ?json.Value, code: i32, message: []const u8) ![]const u8 {
        const response = JsonRpcMessage{
            .id = id,
            .@"error" = JsonRpcError{
                .code = code,
                .message = message,
            },
        };
        return try json.stringifyAlloc(self.allocator, response, .{});
    }
};
```

### Transport Layer - Standard I/O

```zig
const StdioTransport = struct {
    server: *McpServer,
    stdin: std.fs.File.Reader,
    stdout: std.fs.File.Writer,

    pub fn init(server: *McpServer) StdioTransport {
        return StdioTransport{
            .server = server,
            .stdin = std.io.getStdIn().reader(),
            .stdout = std.io.getStdOut().writer(),
        };
    }

    pub fn run(self: *StdioTransport) !void {
        var buffer: [4096]u8 = undefined;
        
        while (true) {
            if (try self.stdin.readUntilDelimiterOrEof(buffer[0..], '\n')) |line| {
                const response = try self.server.handleRequest(line);
                if (response.len > 0) {
                    try self.stdout.print("{s}\n", .{response});
                }
            } else {
                break;
            }
        }
    }
};
```

### Resource Handler Implementation

```zig
// In handlers/resources.zig
const ResourceHandler = struct {
    server: *McpServer,

    pub fn init(server: *McpServer) ResourceHandler {
        return ResourceHandler{ .server = server };
    }

    pub fn listResources(self: *ResourceHandler) !json.Value {
        var resources_array = std.ArrayList(json.Value).init(self.server.allocator);
        
        for (self.server.resources.items) |resource| {
            const resource_obj = try json.valueFromObject(resource, self.server.allocator);
            try resources_array.append(resource_obj);
        }

        const result = json.Value{
            .object = blk: {
                var obj = std.json.ObjectMap.init(self.server.allocator);
                try obj.put("resources", json.Value{ .array = resources_array });
                break :blk obj;
            },
        };

        return result;
    }

    pub fn readResource(self: *ResourceHandler, uri: []const u8) !json.Value {
        // Find resource by URI
        for (self.server.resources.items) |resource| {
            if (std.mem.eql(u8, resource.uri, uri)) {
                // Read resource content (implementation specific)
                const content = try self.readResourceContent(uri);
                
                const result = json.Value{
                    .object = blk: {
                        var obj = std.json.ObjectMap.init(self.server.allocator);
                        try obj.put("contents", json.Value{
                            .array = blk2: {
                                var contents = std.ArrayList(json.Value).init(self.server.allocator);
                                var content_obj = std.json.ObjectMap.init(self.server.allocator);
                                try content_obj.put("uri", json.Value{ .string = uri });
                                try content_obj.put("mimeType", json.Value{ .string = resource.mimeType orelse "text/plain" });
                                try content_obj.put("text", json.Value{ .string = content });
                                try contents.append(json.Value{ .object = content_obj });
                                break :blk2 contents;
                            },
                        });
                        break :blk obj;
                    },
                };
                
                return result;
            }
        }

        return error.ResourceNotFound;
    }

    fn readResourceContent(self: *ResourceHandler, uri: []const u8) ![]const u8 {
        // Implementation depends on resource type
        // For file resources:
        if (std.mem.startsWith(u8, uri, "file://")) {
            const path = uri[7..]; // Remove "file://" prefix
            const file = try std.fs.cwd().openFile(path, .{});
            defer file.close();
            
            const content = try file.readToEndAlloc(self.server.allocator, std.math.maxInt(usize));
            return content;
        }

        return error.UnsupportedResourceType;
    }
};
```

## Authentication

MCP supports optional authentication through various mechanisms:

### Bearer Token Authentication

```zig
const AuthHandler = struct {
    tokens: std.HashMap([]const u8, AuthInfo, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    allocator: Allocator,

    const AuthInfo = struct {
        user_id: []const u8,
        scopes: []const []const u8,
        expires_at: ?i64 = null,
    };

    pub fn init(allocator: Allocator) AuthHandler {
        return AuthHandler{
            .tokens = std.HashMap([]const u8, AuthInfo, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn validateToken(self: *AuthHandler, token: []const u8) ?AuthInfo {
        return self.tokens.get(token);
    }

    pub fn addToken(self: *AuthHandler, token: []const u8, auth_info: AuthInfo) !void {
        try self.tokens.put(token, auth_info);
    }

    pub fn requireAuth(self: *AuthHandler, request_headers: ?json.Value) !AuthInfo {
        if (request_headers) |headers| {
            if (headers.object.get("Authorization")) |auth_header| {
                if (auth_header == .string and std.mem.startsWith(u8, auth_header.string, "Bearer ")) {
                    const token = auth_header.string[7..]; // Remove "Bearer " prefix
                    
                    if (self.validateToken(token)) |auth_info| {
                        // Check expiration
                        if (auth_info.expires_at) |expires_at| {
                            const now = std.time.timestamp();
                            if (now > expires_at) {
                                return error.TokenExpired;
                            }
                        }
                        return auth_info;
                    }
                }
            }
        }
        return error.Unauthorized;
    }
};
```

## Extensions

### Custom Methods

Implement server-specific functionality by adding custom methods:

```zig
fn dispatchCustomMethod(self: *McpServer, method: []const u8, params: ?json.Value, id: ?json.Value) ![]const u8 {
    if (std.mem.startsWith(u8, method, "custom/")) {
        if (std.mem.eql(u8, method, "custom/health")) {
            return try self.handleHealthCheck(params, id);
        } else if (std.mem.eql(u8, method, "custom/metrics")) {
            return try self.handleMetrics(params, id);
        }
    }
    
    return error.MethodNotFound;
}

fn handleHealthCheck(self: *McpServer, params: ?json.Value, id: ?json.Value) ![]const u8 {
    _ = params;
    
    const result = json.Value{
        .object = blk: {
            var obj = std.json.ObjectMap.init(self.allocator);
            try obj.put("status", json.Value{ .string = "healthy" });
            try obj.put("timestamp", json.Value{ .integer = std.time.timestamp() });
            try obj.put("uptime", json.Value{ .integer = self.getUptime() });
            break :blk obj;
        },
    };

    return try self.createSuccessResponse(id, result);
}
```

### Subscription Management

Implement resource change notifications:

```zig
const SubscriptionManager = struct {
    subscriptions: std.HashMap([]const u8, std.ArrayList([]const u8), std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    allocator: Allocator,

    pub fn init(allocator: Allocator) SubscriptionManager {
        return SubscriptionManager{
            .subscriptions = std.HashMap([]const u8, std.ArrayList([]const u8), std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn subscribe(self: *SubscriptionManager, resource_uri: []const u8, client_id: []const u8) !void {
        var result = try self.subscriptions.getOrPut(resource_uri);
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList([]const u8).init(self.allocator);
        }
        try result.value_ptr.append(client_id);
    }

    pub fn unsubscribe(self: *SubscriptionManager, resource_uri: []const u8, client_id: []const u8) void {
        if (self.subscriptions.getPtr(resource_uri)) |subscribers| {
            for (subscribers.items, 0..) |subscriber, i| {
                if (std.mem.eql(u8, subscriber, client_id)) {
                    _ = subscribers.swapRemove(i);
                    break;
                }
            }
        }
    }

    pub fn notifyResourceChange(self: *SubscriptionManager, resource_uri: []const u8, change_type: []const u8) !void {
        if (self.subscriptions.get(resource_uri)) |subscribers| {
            for (subscribers.items) |client_id| {
                try self.sendNotification(client_id, "notifications/resources/list_changed", .{
                    .resource_uri = resource_uri,
                    .change_type = change_type,
                });
            }
        }
    }

    fn sendNotification(self: *SubscriptionManager, client_id: []const u8, method: []const u8, params: anytype) !void {
        // Implementation depends on transport layer
        // Send notification to specific client
        _ = self;
        _ = client_id;
        _ = method;
        _ = params;
    }
};
```

## Error Handling

### Standard JSON-RPC Errors

```zig
const JsonRpcErrorCodes = struct {
    pub const PARSE_ERROR = -32700;
    pub const INVALID_REQUEST = -32600;
    pub const METHOD_NOT_FOUND = -32601;
    pub const INVALID_PARAMS = -32602;
    pub const INTERNAL_ERROR = -32603;
    
    // MCP-specific errors
    pub const RESOURCE_NOT_FOUND = -32000;
    pub const TOOL_EXECUTION_ERROR = -32001;
    pub const AUTHENTICATION_ERROR = -32002;
    pub const AUTHORIZATION_ERROR = -32003;
};

fn createMcpError(allocator: Allocator, id: ?json.Value, code: i32, message: []const u8, details: ?json.Value) ![]const u8 {
    var error_data = std.json.ObjectMap.init(allocator);
    if (details) |d| {
        try error_data.put("details", d);
    }

    const response = JsonRpcMessage{
        .id = id,
        .@"error" = JsonRpcError{
            .code = code,
            .message = message,
            .data = if (error_data.count() > 0) json.Value{ .object = error_data } else null,
        },
    };

    return try json.stringifyAlloc(allocator, response, .{});
}
```

## Best Practices

### Security
1. **Input Validation**: Always validate and sanitize input parameters
2. **Rate Limiting**: Implement request rate limiting to prevent abuse
3. **Authentication**: Use strong authentication mechanisms when handling sensitive data
4. **Sandboxing**: Run tool executions in isolated environments

### Performance
1. **Connection Pooling**: Reuse database and HTTP connections
2. **Caching**: Cache frequently accessed resources
3. **Async Operations**: Use Zig's async/await for I/O operations
4. **Memory Management**: Properly manage memory allocation and deallocation

### Reliability
1. **Error Recovery**: Implement graceful error handling and recovery
2. **Logging**: Comprehensive logging for debugging and monitoring
3. **Health Checks**: Implement health check endpoints
4. **Graceful Shutdown**: Handle shutdown signals properly

### Code Organization

```zig
// Use comptime for configuration
const ServerConfig = struct {
    pub const MAX_REQUEST_SIZE = 1024 * 1024; // 1MB
    pub const TIMEOUT_SECONDS = 30;
    pub const MAX_CONCURRENT_REQUESTS = 100;
};

// Use Zig's error handling
const ServerError = error{
    InvalidRequest,
    ResourceNotFound,
    ToolExecutionFailed,
    AuthenticationFailed,
    OutOfMemory,
};
```

## Complete Example

Here's a minimal but complete MCP server implementation:

```zig
const std = @import("std");
const json = std.json;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = McpServer.init(allocator);
    defer server.deinit();

    // Add sample resources, tools, and prompts
    try server.addResource(Resource{
        .uri = "file:///tmp/example.txt",
        .name = "Example Text File",
        .description = "A sample text file",
        .mimeType = "text/plain",
    });

    try server.addTool(Tool{
        .name = "echo",
        .description = "Echo the input text",
        .inputSchema = json.Value{
            .object = blk: {
                var schema = std.json.ObjectMap.init(allocator);
                try schema.put("type", json.Value{ .string = "object" });
                var properties = std.json.ObjectMap.init(allocator);
                var text_prop = std.json.ObjectMap.init(allocator);
                try text_prop.put("type", json.Value{ .string = "string" });
                try properties.put("text", json.Value{ .object = text_prop });
                try schema.put("properties", json.Value{ .object = properties });
                break :blk schema;
            },
        },
    });

    // Start stdio transport
    var transport = StdioTransport.init(&server);
    try transport.run();
}
```

This guide provides a comprehensive foundation for implementing MCP servers in Zig, covering the protocol, authentication, extensions, and best practices. The modular design allows for easy customization and extension based on specific use cases.