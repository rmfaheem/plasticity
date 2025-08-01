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

// Search functionality
document.getElementById('searchBtn').addEventListener('click', async () => {
    const queryInput = document.getElementById('searchQuery').value.trim();
    if (!queryInput) {
        showNotification('Please enter a search query', true);
        return;
    }

    showLoading();

    try {
        let vector;
        try {
            vector = JSON.parse(queryInput);
        } catch {
            // If not valid JSON, treat as text query
            // In real app, you'd call an embedding API here
            showNotification('Note: Text queries require embedding service', true);
            vector = Array(8).fill(0).map(() => Math.random()); // Dummy vector
        }

        const payload = {
            vector,
            limit: parseInt(document.getElementById('limit').value),
            topic_id: document.getElementById('topic').value.trim() || null
        };

        const response = await fetch('/api/search', {
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

// Ingest functionality
document.getElementById('ingestForm').addEventListener('submit', async (e) => {
    e.preventDefault();

    const id = document.getElementById('docId').value.trim();
    const content = document.getElementById('docContent').value.trim();
    const topic = document.getElementById('docTopic').value.trim();
    const vectorStr = document.getElementById('docVector').value.trim();

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

    showLoading();

    try {
        const payload = {
            id,
            vector,
            timestamp: Math.floor(Date.now() / 1000),
            content,
            topic_id: topic || null,
            related_documents: []
        };

        const response = await fetch('/api/ingest', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload)
        });

        if (!response.ok) throw new Error('Ingest failed');

        showNotification('Document added successfully');
        e.target.reset();
    } catch (error) {
        showNotification('Error adding document: ' + error.message, true);
    } finally {
        hideLoading();
    }
});
