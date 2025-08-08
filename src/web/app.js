// Utility functions
function showLoading() {
    document.getElementById('loadingSpinner').style.display = 'flex';
}

function hideLoading() {
    document.getElementById('loadingSpinner').style.display = 'none';
}

function showNotification(message, isError = false) {
    const notification = document.getElementById('notification');
    const text = document.getElementById('notificationText');
    text.textContent = message;
    if (isError) {
        notification.classList.add('error');
    } else {
        notification.classList.remove('error');
    }
    notification.style.display = 'flex';
    setTimeout(hideNotification, 3000);
}

function hideNotification() {
    document.getElementById('notification').style.display = 'none';
}

// Tab functionality
function switchTab(tabId) {
    // Hide all tab contents
    document.querySelectorAll('.tab-content').forEach(content => {
        content.classList.remove('active');
    });
    
    // Remove active class from all tab buttons
    document.querySelectorAll('.tab-btn').forEach(btn => {
        btn.classList.remove('active');
    });
    
    // Show selected tab content
    document.getElementById(tabId).classList.add('active');
    
    // Add active class to clicked button
    document.querySelector(`[data-tab="${tabId}"]`).classList.add('active');
}

// Initialize tab functionality
document.addEventListener('DOMContentLoaded', () => {
    // Tab switching
    document.querySelectorAll('.tab-btn').forEach(btn => {
        btn.addEventListener('click', () => {
            const tabId = btn.getAttribute('data-tab');
            switchTab(tabId);
        });
    });
    
    // JSON validation
    document.getElementById('validateJsonBtn').addEventListener('click', validateJson);
    
    // JSON ingestion
    document.getElementById('ingestJsonBtn').addEventListener('click', ingestJsonDocument);
    
    // Load example
    document.getElementById('loadExampleBtn').addEventListener('click', loadExample);
    
    // Load batch example
    document.getElementById('loadBatchExampleBtn').addEventListener('click', loadBatchExample);

    // Conversation tab actions
    const convSendBtn = document.getElementById('convSendBtn');
    if (convSendBtn) convSendBtn.addEventListener('click', saveConversationTurn);
    const convGenerateBtn = document.getElementById('convGenerateBtn');
    if (convGenerateBtn) convGenerateBtn.addEventListener('click', generateAssistantAndSave);
    const loadHistoryBtn = document.getElementById('loadHistoryBtn');
    if (loadHistoryBtn) loadHistoryBtn.addEventListener('click', loadConversationHistory);
});

// JSON validation function
function validateJson() {
    const jsonInput = document.getElementById('jsonInput').value.trim();
    const validationDiv = document.getElementById('jsonValidation');
    const messageDiv = document.getElementById('validationMessage');
    
    if (!jsonInput) {
        showValidationMessage('Please enter JSON content', 'error');
        return false;
    }
    
    try {
        const parsed = JSON.parse(jsonInput);
        
        // Check if it's an array (batch) or single document
        const documents = Array.isArray(parsed) ? parsed : [parsed];
        
        // Validate each document
        for (let i = 0; i < documents.length; i++) {
            const doc = documents[i];
            const docPrefix = Array.isArray(parsed) ? `Document ${i + 1}: ` : '';
            
            if (!doc.id) {
                showValidationMessage(`${docPrefix}Missing required field: id`, 'error');
                return false;
            }
            
            if (!doc.content) {
                showValidationMessage(`${docPrefix}Missing required field: content`, 'error');
                return false;
            }
        }
        
        const count = documents.length;
        const message = count === 1 ? 
            'JSON is valid! All required fields are present.' : 
            `JSON is valid! All ${count} documents have required fields.`;
        showValidationMessage(message, 'success');
        return true;
    } catch (error) {
        showValidationMessage('Invalid JSON format: ' + error.message, 'error');
        return false;
    }
}

function showValidationMessage(message, type) {
    const validationDiv = document.getElementById('jsonValidation');
    const messageDiv = document.getElementById('validationMessage');
    
    messageDiv.textContent = message;
    validationDiv.className = `json-validation ${type}`;
    validationDiv.style.display = 'block';
}

// Load example JSON
function loadExample() {
    const exampleJson = {
        "id": "doc_example_001",
        "content": "This is an example document about artificial intelligence and machine learning. It discusses various algorithms and their applications in modern technology.",
        "vector": [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8],
        "topic_id": "artificial_intelligence",
        "user_id": "user_example_123",
        "context_type": "observation",
        "related_documents": ["doc_002", "doc_003", "doc_004"],
        "metadata": {
            "source": "web",
            "author": "example_user",
            "tags": ["ai", "ml", "technology"],
            "created_at": "2024-01-15T10:30:00Z",
            "version": "1.0"
        }
    };
    
    document.getElementById('jsonInput').value = JSON.stringify(exampleJson, null, 2);
    showValidationMessage('Single document example loaded! Click "Validate JSON" to check.', 'success');
}

// Load batch example JSON
function loadBatchExample() {
    const batchExampleJson = [
        {
            "id": "batch_doc_001",
            "vector": [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8],
            "timestamp": 1722516000,
            "content": "First document in batch about machine learning basics.",
            "topic_id": "machine_learning",
            "user_id": "user_123",
            "context_type": "preference"
        },
        {
            "id": "batch_doc_002",
            "vector": [0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9],
            "timestamp": 1722516100,
            "content": "Second document in batch about deep learning applications.",
            "topic_id": "machine_learning",
            "user_id": "user_123",
            "context_type": "preference",
            "related_documents": ["batch_doc_001"]
        },
        {
            "id": "batch_doc_003",
            "vector": [0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0],
            "timestamp": 1722516200,
            "content": "Third document in batch about neural network optimization.",
            "topic_id": "machine_learning",
            "user_id": "user_123",
            "context_type": "observation",
            "related_documents": ["batch_doc_001", "batch_doc_002"],
            "metadata": {
                "optimization_technique": "gradient_descent",
                "performance_improvement": "15%"
            }
        }
    ];
    
    document.getElementById('jsonInput').value = JSON.stringify(batchExampleJson, null, 2);
    showValidationMessage('Batch example loaded! Click "Validate JSON" to check.', 'success');
}

// JSON document ingestion
async function ingestJsonDocument() {
    const jsonInput = document.getElementById('jsonInput').value.trim();
    
    if (!jsonInput) {
        showNotification('Please enter JSON content', true);
        return;
    }
    
    // Validate JSON first
    if (!validateJson()) {
        return;
    }
    
    showLoading();
    
    try {
        const documentData = JSON.parse(jsonInput);
        
        // Check if it's an array (batch) or single document
        const documents = Array.isArray(documentData) ? documentData : [documentData];
        
        let successCount = 0;
        let errorCount = 0;
        const errors = [];
        
        // Ingest each document
        for (let i = 0; i < documents.length; i++) {
            const doc = documents[i];
            try {
                // Prepare payload with timestamp
                const payload = {
                    ...doc,
                    timestamp: doc.timestamp || Math.floor(Date.now() / 1000)
                };
                
                const response = await fetch('/api/ingest', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(payload)
                });
                
                if (!response.ok) {
                    const errorData = await response.json();
                    throw new Error(errorData.error || 'Ingest failed');
                }
                
                successCount++;
            } catch (error) {
                errorCount++;
                errors.push(`Document ${i + 1} (${doc.id || 'unknown'}): ${error.message}`);
            }
        }
        
        // Show result summary
        if (errorCount === 0) {
            const message = documents.length === 1 ? 
                'Document ingested successfully!' : 
                `All ${successCount} documents ingested successfully!`;
            showNotification(message);
            document.getElementById('jsonInput').value = '';
            document.getElementById('jsonValidation').style.display = 'none';
        } else {
            const message = `${successCount} documents ingested successfully, ${errorCount} failed. Errors: ${errors.join('; ')}`;
            showNotification(message, true);
        }
    } catch (error) {
        showNotification('Error ingesting document: ' + error.message, true);
    } finally {
        hideLoading();
    }
}

// Search functionality
document.getElementById('searchBtn').addEventListener('click', async () => {
    const queryInput = document.getElementById('searchQuery').value.trim();
    if (!queryInput) {
        showNotification('Please enter a search query', true);
        return;
    }

    showLoading();

    try {
        let payload;
        let endpoint;

        // Try to parse as JSON vector first
        try {
            const vector = JSON.parse(queryInput);
            if (Array.isArray(vector)) {
                // It's a vector search
                payload = {
                    vector,
                    limit: parseInt(document.getElementById('limit').value),
                    topic_id: document.getElementById('topic').value.trim() || null
                };
                endpoint = '/api/search';
            } else {
                throw new Error('Not a vector array');
            }
        } catch {
            // It's a text search
            payload = {
                query: queryInput,
                limit: parseInt(document.getElementById('limit').value),
                topic_id: document.getElementById('topic').value.trim() || null
            };
            endpoint = '/api/text-search';
        }

        const response = await fetch(endpoint, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload)
        });

        if (!response.ok) throw new Error('Search failed');

        const results = await response.json();
        displayResults(results);
    } catch (error) {
        showNotification('Error performing search: ' + error.message, true);
    } finally {
        hideLoading();
    }
});

function displayResults(results) {
    const resultsList = document.getElementById('resultsList');
    resultsList.innerHTML = '';

    if (results.length === 0) {
        resultsList.innerHTML = '<p>No results found.</p>';
    } else {
        results.forEach(result => {
            const card = document.createElement('div');
            card.className = 'result-card';
            card.innerHTML = `
                <div class="result-header">
                    <span class="result-id">${result.id}</span>
                    <span class="result-score">Score: ${result.score.toFixed(3)}</span>
                </div>
                <p class="result-content">${result.content || 'No content available'}</p>
                <div class="result-metadata">
                    Timestamp: ${new Date(result.timestamp * 1000).toLocaleString()}
                    <br>Neighbors: ${result.graph_neighbors.length}
                </div>
            `;
            resultsList.appendChild(card);
        });
    }

    document.getElementById('searchResults').style.display = 'block';
}

async function saveConversationTurn() {
    const sessionId = document.getElementById('convSessionId').value.trim() || `session_${Date.now()}`;
    const userId = document.getElementById('convUserId').value.trim() || null;
    const userMessage = document.getElementById('convUserMessage').value.trim();
    const remember = document.getElementById('rememberTurn').checked;
    const importance = parseFloat(document.getElementById('importanceScore').value);
    const tagsStr = document.getElementById('tagsInput').value.trim();
    const tags = tagsStr ? tagsStr.split(',').map(t => t.trim()).filter(Boolean) : null;

    if (!userMessage) {
        showNotification('Please enter a message', true);
        return;
    }

    showLoading();
    try {
        const turnId = `turn_${Date.now()}`;
        const payload = {
            id: turnId,
            session_id: sessionId,
            timestamp: Math.floor(Date.now() / 1000),
            user_message: userMessage,
            assistant_message: null,
            importance_score: remember ? importance : 0.0,
            tags: remember ? tags : null,
            user_id: userId,
        };
        const resp = await fetch('/api/conversation/save', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload),
        });
        if (!resp.ok) throw new Error('Save failed');
        showNotification('Turn saved');
    } catch (e) {
        showNotification('Error saving turn: ' + e.message, true);
    } finally {
        hideLoading();
    }
}

async function generateAssistantAndSave() {
    const sessionId = document.getElementById('convSessionId').value.trim() || `session_${Date.now()}`;
    const userId = document.getElementById('convUserId').value.trim() || null;
    const userMessage = document.getElementById('convUserMessage').value.trim();
    const remember = document.getElementById('rememberTurn').checked;
    const importance = parseFloat(document.getElementById('importanceScore').value);
    const tagsStr = document.getElementById('tagsInput').value.trim();
    const tags = tagsStr ? tagsStr.split(',').map(t => t.trim()).filter(Boolean) : null;

    if (!userMessage) {
        showNotification('Please enter a message', true);
        return;
    }

    showLoading();
    try {
        // Generate assistant reply
        const genResp = await fetch('/api/llm/generate', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ prompt: userMessage })
        });
        if (!genResp.ok) throw new Error('LLM not available');
        const genJson = await genResp.json();
        const assistant = genJson.completion || '';
        document.getElementById('assistantReplyText').textContent = assistant;
        document.getElementById('assistantReply').style.display = 'block';

        // Save combined turn
        const turnId = `turn_${Date.now()}`;
        const payload = {
            id: turnId,
            session_id: sessionId,
            timestamp: Math.floor(Date.now() / 1000),
            user_message: userMessage,
            assistant_message: assistant,
            importance_score: remember ? importance : 0.0,
            tags: remember ? tags : null,
            user_id: userId,
        };
        const resp = await fetch('/api/conversation/save', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload),
        });
        if (!resp.ok) throw new Error('Save failed');
        showNotification('Assistant generated and turn saved');
    } catch (e) {
        showNotification('Error generating/saving: ' + e.message, true);
    } finally {
        hideLoading();
    }
}

async function loadConversationHistory() {
    const sessionId = document.getElementById('historySessionId').value.trim();
    if (!sessionId) {
        showNotification('Enter session id', true);
        return;
    }
    showLoading();
    try {
        const resp = await fetch(`/api/conversation/history/${encodeURIComponent(sessionId)}`);
        if (!resp.ok) throw new Error('Failed to load history');
        const history = await resp.json();
        const list = document.getElementById('historyList');
        list.innerHTML = '';
        (history.turns || history || []).forEach(turn => {
            const card = document.createElement('div');
            card.className = 'result-card';
            const role = turn.role || (turn.user_message ? 'user' : 'assistant');
            card.innerHTML = `
                <div class="result-header">
                    <span>${role}</span>
                    <span>${new Date((turn.timestamp||0) * 1000).toLocaleString()}</span>
                </div>
                <div class="result-content">${(turn.content) || (turn.user_message || '') + (turn.assistant_message ? ('\n' + turn.assistant_message) : '')}</div>
            `;
            list.appendChild(card);
        });
    } catch (e) {
        showNotification('Error loading history: ' + e.message, true);
    } finally {
        hideLoading();
    }
}

// Ingest functionality
document.getElementById('ingestForm').addEventListener('submit', async (e) => {
    e.preventDefault();

    const id = document.getElementById('docId').value.trim();
    const content = document.getElementById('docContent').value.trim();
    const topic = document.getElementById('docTopic').value.trim();
    const vectorStr = document.getElementById('docVector').value.trim();
    const userId = document.getElementById('docUserId').value.trim();
    const contextType = document.getElementById('docContextType').value;
    const relatedDocsStr = document.getElementById('docRelatedDocs').value.trim();
    const metadataStr = document.getElementById('docMetadata').value.trim();

    if (!id || !content) {
        showNotification('ID and content are required', true);
        return;
    }

    let vector;
    try {
        vector = vectorStr ? vectorStr.split(',').map(v => parseFloat(v.trim())) : null;
    } catch {
        showNotification('Invalid vector format', true);
        return;
    }

    let relatedDocuments = null;
    if (relatedDocsStr) {
        relatedDocuments = relatedDocsStr.split(',').map(doc => doc.trim()).filter(doc => doc.length > 0);
    }

    let metadata = null;
    if (metadataStr) {
        try {
            metadata = JSON.parse(metadataStr);
        } catch {
            showNotification('Invalid metadata JSON format', true);
            return;
        }
    }

    showLoading();

    try {
        const payload = {
            id,
            vector,
            timestamp: Math.floor(Date.now() / 1000),
            content,
            topic_id: topic || null,
            user_id: userId || null,
            context_type: contextType || null,
            related_documents: relatedDocuments,
            metadata: metadata
        };

        const response = await fetch('/api/ingest', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload)
        });

        if (!response.ok) {
            const errorData = await response.json();
            throw new Error(errorData.error || 'Ingest failed');
        }

        showNotification('Document added successfully');
        e.target.reset();
    } catch (error) {
        showNotification('Error adding document: ' + error.message, true);
    } finally {
        hideLoading();
    }
});
