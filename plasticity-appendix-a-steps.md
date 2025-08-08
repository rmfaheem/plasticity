### Plasticity Appendix A Implementation Plan: High-level APIs for Conversation Memory

Scope
- Implement Appendix A capabilities focused on storing/retrieving conversation turns for LLM agents, leveraging existing vector (Qdrant), graph (ArangoDB), and ranking components already implemented per `plasticity.md`.

Outcomes
- High-level APIs to save conversation turns and recall context.
- Conversation-aware retrieval with time- and graph-weighting.
- Background preprocessing (extraction, enrichment, relationships).
- HTTP and MCP surfaces for agent integration.

Milestones
- M1 Schema & Config
- M2 Data Models & Interfaces
- M3 Ingestion APIs (save turn)
- M4 Retrieval APIs (recall/search/related)
- M5 Preprocessing & Background Indexing
- M6 Ranking Updates & Tuning
- M7 Tests, Examples, Docs
- M8 Web UI Conversation System & External LLM API

---

### M1 — Schema & Config (A.1, A.3, A.6, A.7)
Config
- Extend `src/config.zig` with `persistent_memory` and `conversation_memory`:
  - `retention_period_days`, `indexing_interval_secs`, `max_context_bytes`
  - `auto_extract_context`, `context_extraction_threshold`, `session_timeout_hours`, `max_turns_per_session`

Qdrant (collection: `semantic_chunks` or new `conversation_turns`)
- Payload additions: `turn_id`, `session_id`, `user_id`, `turn_number`, `role` (user|assistant), `timestamp`, `content`, `tags`, `importance_score`, `context_types`.
- Optional: separate collection `conversation_turns` to isolate query paths.

ArangoDB
- Collections: `conversation_turns`, `agent_sessions`, `context_extractions` (+ existing `edges`).
- Edge types: `PART_OF_SESSION`, `FOLLOWS_TURN`, `EXTRACTS_TO`, `REFERENCES`, `HAS_TOPIC`, `USER_OF_SESSION`.
- Indexes: persistent indexes on `_key`, `session_id`, `timestamp`, `relationship_type`.

Acceptance
- Schema creation scripts in docs; config parse/deinit updated.

---

### M2 — Data Models & Interfaces (A.2, A.3, A.4)
New/extended Zig types (files noted for placement)
- `src/conversation.zig`
  - `ConversationTurn { id, session_id, turn_number, timestamp, role, user_message?, assistant_message?, content, tags, importance_score, metadata }`
  - `RecallOptions { max_results, similarity_threshold, time_range, session_filter, importance_threshold, types?, tags? }`
- `src/interfaces.zig` (or fold into `conversation.zig`)
  - `MemoryInterface { saveConversation(turn) -> turn_id; recallConversations(query, options) -> []ConversationTurn; getRelatedMemories(current_context, limit) }`
- Reuse `src/embedding.zig` if present; otherwise stub an embedding provider interface.

Acceptance
- Types compile and integrate with existing modules (no-op impls allowed temporarily).

---

### M3 — Ingestion APIs: Save Conversation Turn (A.4, A.7)
Logic
- Build embedding from `content` (user + assistant merged or per-role chunks).
- Upsert to Qdrant with payload fields above.
- Upsert `conversation_turns` document in Arango; create edges:
  - `PART_OF_SESSION` to `agent_sessions/{session_id}` (create session if missing).
  - `FOLLOWS_TURN` to previous turn in session.
  - `HAS_TOPIC` when tags/topics present.
  - `REFERENCES` based on lightweight link detection (URLs, IDs) if available.
- If `auto_extract_context`: produce `context_extractions` nodes and `EXTRACTS_TO` edges.

Surfaces
- HTTP: `POST /api/conversation/save` accepting example in `examples/conversation_turn.json`.
- MCP: `memory/conversation/save`.

Acceptance
- Saving a turn writes to both stores and returns `turn_id`.

---

### M4 — Retrieval APIs: Recall/Search/Related (A.2, A.5)
Recall by text
- Embed query, Qdrant search with payload filters: `session_id`, `user_id`, `context_types`, `tags`, `time_range`.
- For top-k, fetch graph context in Arango (neighbors, topics, previous/next turns).
- Rerank with similarity + recency + graph weight; respect `importance_score` and `retention_period_days`.

Related memories for current context
- Embed `current_context`; mix of semantic + session-aware traversal (2 hops) for coherent snippets.

Surfaces
- HTTP: `POST /api/conversation/search`, `GET /api/conversation/history/{session_id}`, `POST /api/conversation/related`.
- MCP: `memory/conversation/recall`, `memory/conversation/search`, `memory/conversation/related`.

Acceptance
- End-to-end returns ranked `ConversationTurn` objects with minimal latency (<300ms local dev target, excluding external embedding).

---

### M5 — Preprocessing & Background Indexing (A.4, A.6, A.7)
Extraction (lightweight baseline)
- `src/extract.zig`: heuristics for preferences, decisions, facts, tasks; tag detection; importance scoring.
- Enrichment: merge extraction into Arango and Qdrant payload; set `importance_score`.

Background indexer
- `BackgroundIndexer` loop (interval from config): consume unindexed turns (queue or in-memory buffer), run extraction, persist relationships.
- Wire lifecycle in `src/main.zig` startup.

Acceptance
- Indexer processes queued turns; extraction artifacts visible in graph; CPU/memory footprint bounded.

---

### M6 — Ranking Updates & Tuning (A.5, A.10)
Reranker changes (`src/reranker.zig`)
- Inputs: add `importance_weight`, `behavior_weight` (access frequency) to `RankingConfig`.
- Recency: clamp to `retention_period_days`; decay factor configurable.
- Graph: neighbor weight average; boost if `FOLLOWS_TURN` within same session.
- Importance: linear blend using `importance_score`.
- Optional behavior: maintain lightweight access counters in Arango for boosts.

Acceptance
- Unit tests show ordering affected by recency, graph, and importance consistent with config weights.

---

### M7 — Tests, Examples, Docs (A.8–A.11 readiness)
Tests
- Save + recall happy path; filters by session/time/type/tags.
- Graph traversal depth=2 correctness; session chain reconstruction.
- Ranking knobs: similarity/recency/graph/importance toggles.

Examples
- Ensure `examples/conversation_turn.json` and `examples/conversation_query.json` validate via `examples/validate_examples.py`.

Docs
- README additions: new endpoints, config, schema setup for Qdrant/Arango.
- Privacy section: retention, anonymization placeholders.

Acceptance
- `zig build test` green; manual curl flows work; example queries produce sensible recall.

---

### M8 — Web UI Conversation System & External LLM API (User testing)
Web UI (`src/web/index.html`, `src/web/app.js`)
- Add a Conversation tab with:
  - Message thread view (role, timestamp, content), infinite scroll.
  - Input box for user message; send button.
  - Toggle to "remember this turn" (importance slider, tags input).
  - Session selector (create/new, switch sessions), show session summary.
- Client flows:
  - POST `/api/conversation/save` on send with `{ session_id, user_message, assistant_message?, tags, importance_score }`.
  - GET `/api/conversation/history/{session_id}` to render thread.
  - POST `/api/conversation/search` to pull related context for compose-assist.

Server (`src/web_server.zig`)
- Add endpoints:
  - `POST /api/conversation/save`
  - `GET  /api/conversation/history/{session_id}`
  - `POST /api/conversation/search`
  - `POST /api/llm/generate` (optional, behind config).
- Wire to `MemoryInterface` and embedding service.

External LLM API
- Config: `embedding` (already), add `llm` block with provider, endpoint, api_key.
- New module `src/llm.zig`:
  - `generateCompletion(prompt, system?, model, temperature)` calling external provider.
  - Respect rate limits/timeouts; redact keys in logs.
- UI flow: on user send, optionally call `/api/llm/generate` to get assistant reply, then persist both turns with one save call.

Acceptance
- End-to-end: chat in UI, assistant reply generated (mockable), turns persisted, history renders, recall sidebar shows related memories.
- Feature flags: LLM disabled uses only memory recall; enabled uses external API.

---

### API Sketches
HTTP
```http
POST /api/conversation/save
POST /api/conversation/search
POST /api/conversation/related
GET  /api/conversation/history/{session_id}
POST /api/llm/generate
```

MCP Methods
```text
memory/conversation/save
memory/conversation/recall
memory/conversation/search
memory/conversation/related
```

Zig Interfaces
```zig
pub const MemoryInterface = struct {
    pub fn saveConversation(self: *MemoryInterface, turn: ConversationTurn) ![]const u8;
    pub fn recallConversations(self: *MemoryInterface, query: []const u8, options: RecallOptions) ![]ConversationTurn;
    pub fn getRelatedMemories(self: *MemoryInterface, current_context: []const u8, limit: usize) ![]ConversationTurn;
};
```

---

### Mapping to Appendix A
- A.1/A.2: Retrieval pipeline implemented via M4 + reranker.
- A.3: Graph relations via M3/M5 edges and traversal.
- A.4: Preprocessing via M5 extraction.
- A.5: Dynamic weights via M6 (recency, similarity, behavior, importance).
- A.6/A.7: Dataflow and parallel processes via M5 indexer + M4 retrieval.
- A.9/A.10: Proactive surfacing enabled later via agent layer using M4 and access patterns.

Timeline (indicative)
- Weeks 1–2: M1–M2
- Weeks 3–4: M3–M4
- Week 5: M5
- Week 6: M6–M7
- Week 7: M8 (UI + LLM)

Risk/Notes
- Embedding provider abstraction needed; mock for tests.
- Qdrant payload filtering performance: may warrant dedicated collection for conversation turns.
- Ensure no PII leaks; add config for anonymization/retention (future enhancement).
