#!/usr/bin/env python3
"""
Test script to validate the updated API contracts match the LLM Agent Integration Proposal specification.
"""

import json
import sys
from pathlib import Path

def test_conversation_turn_format():
    """Test the updated conversation turn format"""
    print("Testing ConversationTurn format...")
    
    with open('conversation_turn_updated.json', 'r') as f:
        turn = json.load(f)
    
    # Required fields per proposal
    required_fields = [
        'session_id', 
        'user_message', 
        'assistant_message'
    ]
    
    for field in required_fields:
        if field not in turn:
            print(f"❌ Missing required field: {field}")
            return False
        if not turn[field]:  # Check for empty strings
            print(f"❌ Required field '{field}' is empty")
            return False
    
    # Optional fields that should be supported
    optional_fields = [
        'id', 'turn_number', 'timestamp', 'importance_score', 
        'tags', 'user_id', 'metadata'
    ]
    
    for field in optional_fields:
        if field in turn:
            print(f"✅ Optional field '{field}' present: {type(turn[field]).__name__}")
    
    print("✅ ConversationTurn format is valid!")
    return True

def test_conversation_query_format():
    """Test the updated conversation query format"""
    print("\nTesting ConversationQuery format...")
    
    with open('conversation_query_updated.json', 'r') as f:
        query = json.load(f)
    
    # Required fields per proposal
    required_fields = ['query_text']
    
    for field in required_fields:
        if field not in query:
            print(f"❌ Missing required field: {field}")
            return False
        if not query[field]:
            print(f"❌ Required field '{field}' is empty")
            return False
    
    # Expected fields from proposal
    expected_fields = [
        'query_text', 'session_id', 'user_id', 'context_types',
        'time_range', 'include_conversation_context', 'max_turns'
    ]
    
    for field in expected_fields:
        if field in query:
            print(f"✅ Field '{field}' present: {type(query[field]).__name__}")
    
    # Validate context_types are valid strings
    if 'context_types' in query:
        valid_types = ['preference', 'decision', 'fact', 'task', 'observation', 'intent', 'emotion', 'goal']
        for ct in query['context_types']:
            if ct not in valid_types:
                print(f"❌ Invalid context_type: {ct}")
                return False
        print(f"✅ All context_types are valid: {query['context_types']}")
    
    print("✅ ConversationQuery format is valid!")
    return True

def test_context_extraction_format():
    """Test the new context extraction endpoint format"""
    print("\nTesting ContextExtraction format...")
    
    with open('context_extraction_request.json', 'r') as f:
        request = json.load(f)
    
    # Required fields
    if 'text' not in request or not request['text']:
        print("❌ Missing required field: text")
        return False
    
    print(f"✅ Text field present: {len(request['text'])} characters")
    
    # Optional extraction_types field
    if 'extraction_types' in request:
        valid_types = ['preference', 'decision', 'fact', 'task', 'observation', 'intent', 'emotion', 'goal']
        for et in request['extraction_types']:
            if et not in valid_types:
                print(f"❌ Invalid extraction_type: {et}")
                return False
        print(f"✅ All extraction_types are valid: {request['extraction_types']}")
    
    print("✅ ContextExtraction format is valid!")
    return True

def main():
    print("🧪 Testing Updated API Contracts for LLM Agent Integration Proposal")
    print("=" * 70)
    
    # Change to examples directory
    examples_dir = Path(__file__).parent
    original_dir = Path.cwd()
    
    try:
        import os
        os.chdir(examples_dir)
        
        success = True
        success &= test_conversation_turn_format()
        success &= test_conversation_query_format()
        success &= test_context_extraction_format()
        
        print("\n" + "=" * 70)
        if success:
            print("🎉 All API contract tests passed!")
            print("\nAPI Endpoints Updated:")
            print("✅ POST /api/conversation/save - Updated to match proposal")
            print("✅ POST /api/conversation/search - Updated to use ConversationQuery")
            print("✅ GET /api/conversation/history/{session_id} - Already compliant")
            print("✅ POST /api/context/extract - NEW endpoint added")
            print("\nStill Missing:")
            print("❌ GET /api/session/{session_id}")
            print("❌ POST /api/session/create")
            print("❌ PUT /api/session/{session_id}/preferences")
            print("❌ MCP Server (ws://localhost:8081/mcp)")
            return 0
        else:
            print("❌ Some tests failed!")
            return 1
            
    finally:
        os.chdir(original_dir)

if __name__ == "__main__":
    sys.exit(main())
