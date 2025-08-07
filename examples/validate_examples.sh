#!/bin/bash

echo "Validating JSON files in examples directory:"
echo "----------------------------------------"

valid_count=0
total_count=0

for file in *.json; do
    if [ -f "$file" ]; then
        total_count=$((total_count + 1))
        if jq empty "$file" 2>/dev/null; then
            echo "✅ $file"
            valid_count=$((valid_count + 1))
        else
            echo "❌ $file: Invalid JSON"
        fi
    fi
done

echo "----------------------------------------"
echo "Validation complete: $valid_count/$total_count files are valid"

if [ $valid_count -eq $total_count ]; then
    echo "🎉 All example files are properly formatted!"
    exit 0
else
    echo "⚠️  Some files have formatting issues"
    exit 1
fi 