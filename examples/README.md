# Semantic Search Examples

This directory contains example files demonstrating how to use the semantic search system.

## Document Examples

### Basic Documents

- **`document.json`** - Basic document with required fields
- **`document_minimal.json`** - Minimal document with only required fields (id, vector, timestamp, content)

### Documents with Context Types

- **`document_with_metadata.json`** - Document with metadata and preference context
- **`document_decision.json`** - Document with decision context type
- **`document_observation.json`** - Document with observation context type

### Batch Documents

- **`batch_documents.json`** - Array of multiple documents for batch ingestion

## Query Examples

### Basic Queries

- **`query.json`** - Basic query with time range and topic filtering
- **`query_simple.json`** - Simple query with minimal parameters

### Context-Specific Queries

- **`query_with_user_context.json`** - Query with user-specific context filtering
- **`query_architecture.json`** - Query focused on architecture decisions
- **`query_performance.json`** - Query focused on performance observations

## Usage Examples

### Ingesting Documents

```bash
# Ingest a single document
./zig-out/bin/semantic-search ingest examples/document.json

# Ingest a document with metadata
./zig-out/bin/semantic-search ingest examples/document_with_metadata.json

# Ingest a decision document
./zig-out/bin/semantic-search ingest examples/document_decision.json

# Ingest an observation document
./zig-out/bin/semantic-search ingest examples/document_observation.json
```

### Searching Documents

```bash
# Basic search
./zig-out/bin/semantic-search search examples/query.json

# Simple search without filters
./zig-out/bin/semantic-search search examples/query_simple.json

# Search with user context
./zig-out/bin/semantic-search search examples/query_with_user_context.json

# Search for architecture decisions
./zig-out/bin/semantic-search search examples/query_architecture.json

# Search for performance observations
./zig-out/bin/semantic-search search examples/query_performance.json
```

## Document Structure

### Required Fields
- `id` - Unique document identifier
- `vector` - Embedding vector (array of floats)
- `timestamp` - Unix timestamp
- `content` - Document text content

### Optional Fields
- `topic_id` - Topic categorization
- `related_documents` - Array of related document IDs
- `user_id` - User identifier for personalization
- `context_type` - One of: "preference", "decision", "observation"
- `metadata` - JSON object with custom key-value pairs

## Query Structure

### Required Fields
- `vector` - Query embedding vector (array of floats)

### Optional Fields
- `limit` - Maximum number of results (default: 10)
- `time_range` - Object with `start` and `end` timestamps
- `topic_id` - Filter by topic
- `source_node_id` - Start search from specific document
- `user_id` - Filter by user
- `context_types` - Array of context types to include

## Context Types

1. **preference** - User preferences and likes
2. **decision** - Decisions made and their rationale
3. **observation** - Observations and measurements

## Vector Dimensions

All examples use 8-dimensional vectors for simplicity. In production, you would typically use higher-dimensional vectors (e.g., 768 for BERT, 1536 for OpenAI embeddings).

## Metadata Examples

The metadata field allows you to store custom attributes:

```json
{
  "source": "research_paper",
  "author": "Dr. Jane Smith",
  "publication_year": "2024",
  "confidence_score": "0.95"
}
```

## Related Documents

The `related_documents` field creates graph connections between documents:

```json
{
  "related_documents": ["doc_002", "doc_003", "doc_004"]
}
```

This enables graph-based ranking and context-aware search results. 