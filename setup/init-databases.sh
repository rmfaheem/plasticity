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
Q_SIZE=${QDRANT_VECTOR_SIZE:-8}
cat > /tmp/qdrant_collection.json <<EOF
{
  "vectors": { "size": ${Q_SIZE}, "distance": "Cosine" },
  "payload_schema": {
    "timestamp": { "data_type": "integer" },
    "topic_id": { "data_type": "keyword" },
    "user_id": { "data_type": "keyword" },
    "context_type": { "data_type": "keyword" },
    "session_id": { "data_type": "keyword" },
    "turn_number": { "data_type": "integer" },
    "role": { "data_type": "keyword" },
    "importance_score": { "data_type": "float" },
    "tags": { "data_type": "keyword" }
  },
  "optimizers_config": { "default_segment_number": 2 },
  "hnsw_config": { "m": 16, "ef_construct": 100 }
}
EOF
curl -sf -X PUT http://qdrant:6333/collections/semantic_chunks \
  -H "Content-Type: application/json" \
  --data-binary @/tmp/qdrant_collection.json || echo "Qdrant collection create/update returned non-zero (may already exist)."
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
create_coll() { curl -sf -X POST http://arangodb:8529/_db/semantic_graph/_api/collection -H "Content-Type: application/json" -u "root:${ARANGO_ROOT_PASSWORD:-password}" -d "$1" || echo "Create collection returned non-zero (may exist): $1"; }
create_coll '{"name": "chunks", "type": 2}'
create_coll '{"name": "edges", "type": 3}'
create_coll '{"name": "users", "type": 2}'
create_coll '{"name": "user_context", "type": 3}'
create_coll '{"name": "conversation_turns", "type": 2}'
create_coll '{"name": "agent_sessions", "type": 2}'
create_coll '{"name": "session_edges", "type": 3}'
create_coll '{"name": "topics", "type": 2}'
create_coll '{"name": "context_extractions", "type": 2}'
echo "--- Collection creation commands executed. ---"

echo "--- Creating ArangoDB indexes... "
# Create indexes
create_index() { curl -sf -X POST http://arangodb:8529/_db/semantic_graph/_api/index -H "Content-Type: application/json" -u "root:${ARANGO_ROOT_PASSWORD:-password}" -d "$1" || echo "Create index returned non-zero (may exist): $1"; }
create_index '{"type": "persistent", "fields": ["timestamp"], "collection": "chunks"}'
create_index '{"type": "persistent", "fields": ["type"], "collection": "edges"}'
create_index '{"type": "persistent", "fields": ["session_id","turn_number","timestamp"], "collection": "conversation_turns"}'
echo "--- Index creation commands executed. ---"

echo "--- Database Initialization Completed Successfully ---"
