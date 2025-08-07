#!/bin/bash
set -ex

echo "--- Starting Database Initialization ---"

# Wait for services to be ready
echo "--- Waiting for Qdrant to be ready..."
until curl -sf http://qdrant:6333/collections > /dev/null 2>&1; do
    echo "Qdrant not ready, waiting..."
    sleep 2
done
echo "--- Qdrant is ready. ---"

echo "--- Waiting for ArangoDB to be ready..."
until curl -sf http://arangodb:8529/_api/version > /dev/null 2>&1; do
    echo "ArangoDB not ready, waiting..."
    sleep 2
done
echo "--- ArangoDB is ready. ---"

# Initialize Qdrant collection
echo "--- Creating Qdrant collection 'semantic_chunks'..."
curl -X PUT http://qdrant:6333/collections/semantic_chunks \
  -H "Content-Type: application/json" \
  -d '{
    "vectors": { "size": 768, "distance": "Cosine" },
    "optimizers_config": { "default_segment_number": 2 },
    "hnsw_config": { "m": 16, "ef_construct": 100 }
  }'
echo "--- Qdrant collection creation command executed. ---"

# Initialize ArangoDB
echo "--- Creating ArangoDB database 'semantic_graph'..."
curl -X POST http://arangodb:8529/_api/database \
  -H "Content-Type: application/json" \
  -u "root:${ARANGO_ROOT_PASSWORD:-password}" \
  -d '{"name": "semantic_graph"}' || echo "Database creation failed or database already exists."
echo "--- ArangoDB database creation command executed. ---"

echo "--- Creating ArangoDB collections... ---"
# Create collections
curl -X POST http://arangodb:8529/_db/semantic_graph/_api/collection -H "Content-Type: application/json" -u "root:${ARANGO_ROOT_PASSWORD:-password}" -d '{"name": "chunks", "type": 2}' || echo "Failed to create 'chunks' collection."
curl -X POST http://arangodb:8529/_db/semantic_graph/_api/collection -H "Content-Type: application/json" -u "root:${ARANGO_ROOT_PASSWORD:-password}" -d '{"name": "edges", "type": 3}' || echo "Failed to create 'edges' collection."
curl -X POST http://arangodb:8529/_db/semantic_graph/_api/collection -H "Content-Type: application/json" -u "root:${ARANGO_ROOT_PASSWORD:-password}" -d '{"name": "users", "type": 2}' || echo "Failed to create 'users' collection."
curl -X POST http://arangodb:8529/_db/semantic_graph/_api/collection -H "Content-Type: application/json" -u "root:${ARANGO_ROOT_PASSWORD:-password}" -d '{"name": "user_context", "type": 3}' || echo "Failed to create 'user_context' collection."
echo "--- Collection creation commands executed. ---"

echo "--- Creating ArangoDB indexes... "
# Create indexes
curl -X POST http://arangodb:8529/_db/semantic_graph/_api/index -H "Content-Type: application/json" -u "root:${ARANGO_ROOT_PASSWORD:-password}" -d '{"type": "persistent", "fields": ["timestamp"], "collection": "chunks"}' || echo "Failed to create timestamp index."
curl -X POST http://arangodb:8529/_db/semantic_graph/_api/index -H "Content-Type: application/json" -u "root:${ARANGO_ROOT_PASSWORD:-password}" -d '{"type": "persistent", "fields": ["type"], "collection": "edges"}' || echo "Failed to create type index."
echo "--- Index creation commands executed. ---"

echo "--- Database Initialization Completed Successfully ---"
