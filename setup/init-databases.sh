#!/bin/bash

# Database initialization script for semantic search system

set -e

echo "Initializing Semantic Search Databases..."

# Wait for services to be ready
echo "Waiting for Qdrant to be ready..."
until curl -f http://qdrant:6333/collections > /dev/null 2>&1; do
    echo "Waiting for Qdrant..."
    sleep 2
done

echo "Waiting for ArangoDB to be ready..."
until curl -f http://arangodb:8529/_api/version > /dev/null 2>&1; do
    echo "Waiting for ArangoDB..."
    sleep 2
done

# Initialize Qdrant collection
echo "Creating Qdrant collection 'semantic_chunks'..."
curl -X PUT http://qdrant:6333/collections/semantic_chunks \
  -H "Content-Type: application/json" \
  -d '{
    "vectors": {
      "size": 768,
      "distance": "Cosine"
    },
    "optimizers_config": {
      "default_segment_number": 2
    },
    "hnsw_config": {
      "m": 16,
      "ef_construct": 100
    }
  }'

echo "Qdrant collection created successfully!"

# Initialize ArangoDB database and collections
echo "Creating ArangoDB database 'semantic_graph'..."
curl -X POST http://arangodb:8529/_api/database \
  -H "Content-Type: application/json" \
  -u "root:${ARANGO_ROOT_PASSWORD:-password}" \
  -d '{
    "name": "semantic_graph"
  }' || echo "Database might already exist"

echo "Creating ArangoDB collections..."
# Create chunks collection
curl -X POST http://arangodb:8529/_db/semantic_graph/_api/collection \
  -H "Content-Type: application/json" \
  -u "root:${ARANGO_ROOT_PASSWORD:-password}" \
  -d '{
    "name": "chunks",
    "type": 2
  }' || echo "Chunks collection might already exist"

# Create edges collection
curl -X POST http://arangodb:8529/_db/semantic_graph/_api/collection \
  -H "Content-Type: application/json" \
  -u "root:${ARANGO_ROOT_PASSWORD:-password}" \
  -d '{
    "name": "edges",
    "type": 3
  }' || echo "Edges collection might already exist"

# Create indexes
echo "Creating ArangoDB indexes..."
curl -X POST http://arangodb:8529/_db/semantic_graph/_api/index \
  -H "Content-Type: application/json" \
  -u "root:${ARANGO_ROOT_PASSWORD:-password}" \
  -d '{
    "type": "persistent",
    "fields": ["timestamp"],
    "collection": "chunks"
  }' || echo "Timestamp index might already exist"

curl -X POST http://arangodb:8529/_db/semantic_graph/_api/index \
  -H "Content-Type: application/json" \
  -u "root:${ARANGO_ROOT_PASSWORD:-password}" \
  -d '{
    "type": "persistent", 
    "fields": ["type"],
    "collection": "edges"
  }' || echo "Type index might already exist"

echo "Database initialization completed successfully!"