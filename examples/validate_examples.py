#!/usr/bin/env python3
"""
Script to validate that all example JSON files are properly formatted.
"""

import json
import os
import sys
from pathlib import Path

def validate_json_file(file_path):
    """Validate that a JSON file is properly formatted."""
    try:
        with open(file_path, 'r') as f:
            json.load(f)
        print(f"✅ {file_path.name}")
        return True
    except json.JSONDecodeError as e:
        print(f"❌ {file_path.name}: {e}")
        return False
    except Exception as e:
        print(f"❌ {file_path.name}: {e}")
        return False

def main():
    """Validate all JSON files in the examples directory."""
    examples_dir = Path(__file__).parent
    json_files = list(examples_dir.glob("*.json"))
    
    if not json_files:
        print("No JSON files found in examples directory")
        return 1
    
    print("Validating JSON files in examples directory:")
    print("-" * 50)
    
    valid_count = 0
    total_count = len(json_files)
    
    for json_file in sorted(json_files):
        if validate_json_file(json_file):
            valid_count += 1
    
    print("-" * 50)
    print(f"Validation complete: {valid_count}/{total_count} files are valid")
    
    if valid_count == total_count:
        print("🎉 All example files are properly formatted!")
        return 0
    else:
        print("⚠️  Some files have formatting issues")
        return 1

if __name__ == "__main__":
    sys.exit(main()) 