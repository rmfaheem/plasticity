# Time-Aware Semantic Retrieval System

A high-performance semantic search system built with Zig that combines vector similarity search with graph-based contextual understanding and temporal awareness.

## Features

- **Vector Search**: Fast similarity search using Qdrant vector database
- **Graph Context**: Relationship modeling with ArangoDB for enhanced relevance
- **Time Awareness**: Temporal filtering and recency-based scoring
- **Efficient Re-ranking**: Multi-factor scoring algorithm combining similarity, recency, and graph weights
- **Single Binary**: Compiled to a fast, standalone executable

## Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Qdrant DB     │    │   ArangoDB      │    │   Zig App       │
│  (Vectors)      │◄──►│  (Graph)        │◄──►│  (Orchestrator) │
│                 │    │                 │    │                 │
│ • Embeddings    │    │ • Relationships │    │ • Query Router  │
│ • Metadata      │    │ • Topics        │    │ • Re-ranker     │
│ • Time filters  │    │ • Weights       │    │ • HTTP Client   │
└─────────────────┘    └─────────────────┘    └─────────────────┘
```

## Quick Start

### Option 1: Docker Deployment (Recommended)

The easiest way to get started is using Docker Compose, which will set up all required services automatically.

#### Prerequisites
- Docker and Docker Compose installed
- 4GB+ RAM available
- 10GB+ disk space

#### Production Deployment

1. **Clone and start the system:**
```bash
git clone <repository-url>
cd plasticity
docker-compose up -d
```

2. **Initialize databases:**
```bash
# The databases will be automatically initialized, but you can manually run:
docker-compose exec semantic-search /app/setup/init-databases.sh
```

3. **Test the system:**
```bash
# Ingest a sample document
docker-compose exec semantic-search semantic-search ingest /app/examples/document.json

# Search
docker-compose exec semantic-search semantic-search search /app/examples/query.json
```

#### Development Setup

For development with hot reload capabilities:

```bash
# Start development environment
docker-compose -f docker-compose.dev.yml up -d

# Access development container
docker-compose -f docker-compose.dev.yml exec semantic-search-dev bash

# Build and test inside container
zig build
./zig-out/bin/semantic-search search /app/examples/query.json
```

#### Services Overview

- **Qdrant**: Vector database (http://localhost:6333)
- **ArangoDB**: Graph database (http://localhost:8529, user: root, pass: password)  
- **Semantic Search**: Main application

#### Database Access

- **Qdrant Web UI**: http://localhost:6333/dashboard
- **ArangoDB Web Interface**: http://localhost:8529 (root/password)

### Option 2: Native Build

If you prefer to build and run natively:

#### Prerequisites

- Zig 0.14.1+ installed
- Qdrant running on localhost:6333
- ArangoDB running on localhost:8529

#### Build

```bash
zig build -Doptimize=ReleaseFast
```

#### Configuration

Use the provided configuration file or create your own:

```bash
cp config/config.json config/config.local.json
# Edit config/config.local.json with your settings
```

#### Database Setup

**Qdrant Collection:**
```bash
curl -X PUT http://localhost:6333/collections/semantic_chunks \
  -H "Content-Type: application/json" \
  -d '{
    "vectors": {
      "size": 768,
      "distance": "Cosine"
    }
  }'
```

**ArangoDB Setup:**
```javascript
// In ArangoDB web interface or arangosh:
db._createDatabase("semantic_graph");
db._useDatabase("semantic_graph");
db._create("chunks");
db._createEdgeCollection("edges");
db.chunks.ensureIndex({ type: "persistent", fields: ["timestamp"] });
db.edges.ensureIndex({ type: "persistent", fields: ["type"] });
```

#### Usage

**Ingest a document:**
```bash
./zig-out/bin/semantic-search ingest examples/document.json
```

**Search:**
```bash
./zig-out/bin/semantic-search search examples/query.json
```

## API Reference

### Search Query Format

```json
{
  "vector": [0.1, 0.2, 0.3, ...],
  "limit": 10,
  "time_range": {
    "start": 1722480000,
    "end": 1722566400
  },
  "topic_id": "machine_learning"
}
```

### Document Format

```json
{
  "id": "unique_doc_id",
  "vector": [0.1, 0.2, 0.3, ...],
  "timestamp": 1722516000,
  "content": "Document text content",
  "topic_id": "topic_category",
  "related_documents": ["doc_002", "doc_003"]
}
```

### Search Results

```json
[
  {
    "id": "doc_001",
    "score": 0.88,
    "timestamp": 1722516000,
    "content": "Document content...",
    "graph_neighbors": ["doc_002", "doc_003"],
    "similarity_score": 0.92,
    "recency_score": 0.85,
    "graph_score": 0.78
  }
]
```

## Scoring Algorithm

The system uses a weighted combination of three factors:

```
final_score = α × similarity + β × recency + γ × graph_weight
```

Where:
- **similarity**: Cosine similarity from vector search (0-1)
- **recency**: Time-based decay score (1/(1 + decay_factor × age_days))  
- **graph_weight**: Average weight of connected nodes (0-1)

Default weights: α=0.5, β=0.3, γ=0.2

## Troubleshooting

### Docker Issues

**Services not starting:**
```bash
# Check service status
docker-compose ps

# View logs
docker-compose logs qdrant
docker-compose logs arangodb
docker-compose logs semantic-search

# Restart services
docker-compose restart
```

**Memory issues:**
```bash
# Increase Docker memory limit to 4GB+
# Check available resources
docker system df
docker system prune  # Clean up unused resources
```

**Port conflicts:**
```bash
# Check if ports are in use
netstat -tulpn | grep :6333
netstat -tulpn | grep :8529

# Modify ports in docker-compose.yml if needed
```

### Database Issues

**Qdrant connection errors:**
```bash
# Test Qdrant connectivity
curl http://localhost:6333/health

# Check collection status
curl http://localhost:6333/collections/semantic_chunks
```

**ArangoDB authentication:**
```bash
# Reset ArangoDB password
docker-compose exec arangodb arangosh --server.password=""

# Create user in ArangoDB
db._users.save("semantic_user", "secure_password", true);
```

### Performance Tuning

**Qdrant optimization:**
```json
{
  "vectors": {
    "size": 768,
    "distance": "Cosine"
  },
  "optimizers_config": {
    "default_segment_number": 4
  },
  "hnsw_config": {
    "m": 16,
    "ef_construct": 200
  }
}
```

**ArangoDB optimization:**
```javascript
// Add more indexes for better performance
db.chunks.ensureIndex({ type: "persistent", fields: ["topic_id"] });
db.edges.ensureIndex({ type: "persistent", fields: ["_from", "_to"] });
```

## Performance Considerations

- **Memory Usage**: Results are streamed and cleaned up automatically
- **HTTP Pooling**: Single HTTP client instance per database connection
- **JSON Parsing**: Efficient streaming JSON parser with minimal allocations
- **Graph Traversal**: Limited depth (1-2 hops) to prevent expensive operations
- **Batch Operations**: Support for bulk document ingestion

## Development

### Running Tests

```bash
zig build test
```

### Adding Features

The modular design makes it easy to extend:

- **New databases**: Implement client interface in new module
- **Custom scoring**: Modify `reranker.zig` scoring functions  
- **Additional filters**: Extend query structure and filter logic
- **Web API**: Add HTTP server to `main.zig`

### Performance Tuning

Key configuration parameters:

```json
{
  "ranking": {
    "similarity_weight": 0.5,
    "recency_weight": 0.3,
    "graph_weight": 0.2,
    "recency_decay_factor": 0.1
  }
}
```

## Production Deployment

### Docker Deployment (Recommended)

The system includes production-ready Docker configurations:

```bash
# Production deployment
docker-compose up -d

# Scale the application
docker-compose up -d --scale semantic-search=3

# View logs
docker-compose logs -f semantic-search

# Update application
docker-compose build semantic-search
docker-compose up -d semantic-search
```

### Environment Variables

Key environment variables for Docker deployment:

```bash
# Database Configuration
QDRANT_HOST=qdrant
QDRANT_PORT=6333
ARANGO_HOST=arangodb
ARANGO_PORT=8529
ARANGO_ROOT_PASSWORD=your_secure_password

# Application Configuration
ZIG_ENV=production
LOG_LEVEL=info
```

### Health Monitoring

The system includes health checks and monitoring:

```bash
# Check service health
docker-compose ps

# Monitor logs
docker-compose logs -f --tail=100

# Database health
curl http://localhost:6333/health
curl http://localhost:8529/_api/version
```

### Backup and Recovery

**Qdrant Backup:**
```bash
# Backup Qdrant data
docker run --rm -v qdrant_data:/data -v $(pwd):/backup alpine tar czf /backup/qdrant-backup.tar.gz /data

# Restore
docker run --rm -v qdrant_data:/data -v $(pwd):/backup alpine tar xzf /backup/qdrant-backup.tar.gz -C /
```

**ArangoDB Backup:**
```bash
# Backup ArangoDB
docker-compose exec arangodb arangodump --server.database semantic_graph --output-directory /tmp/backup
docker cp $(docker-compose ps -q arangodb):/tmp/backup ./arango-backup

# Restore  
docker cp ./arango-backup $(docker-compose ps -q arangodb):/tmp/restore
docker-compose exec arangodb arangorestore --server.database semantic_graph --input-directory /tmp/restore
```

### Scaling

- **Horizontal**: Multiple app instances behind load balancer
- **Database Clustering**: Both Qdrant and ArangoDB support clustering
- **Caching**: Add Redis layer for frequently accessed graph contexts
- **Load Balancing**: Use nginx or HAProxy for request distribution

### Security

Production security recommendations:

```bash
# Use secrets for passwords
echo "your_secure_password" | docker secret create arango_password -

# Run with non-root user (already configured in Dockerfile)
# Enable TLS for database connections
# Use authentication for all services
```

## License

MIT License - see LICENSE file for details.