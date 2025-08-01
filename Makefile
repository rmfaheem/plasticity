# Makefile for Semantic Search System

.PHONY: help build build-dev clean test docker-build docker-up docker-down docker-dev docker-logs init-db backup

# Default target
help:
	@echo "Available targets:"
	@echo "  build       - Build the application natively"
	@echo "  build-dev   - Build in development mode"
	@echo "  clean       - Clean build artifacts"
	@echo "  test        - Run tests"
	@echo "  docker-build - Build Docker images"
	@echo "  docker-up   - Start production Docker services"
	@echo "  docker-down - Stop Docker services"
	@echo "  docker-dev  - Start development Docker services"
	@echo "  docker-logs - View Docker logs"
	@echo "  init-db     - Initialize databases"
	@echo "  backup      - Backup databases"

# Native builds
build:
	zig build -Doptimize=ReleaseFast

build-dev:
	zig build

clean:
	rm -rf zig-out zig-cache .zig-cache

test:
	zig build test

# Docker commands
docker-build:
	docker-compose build

docker-up:
	docker-compose up -d

docker-down:
	docker-compose down

docker-dev:
	docker-compose -f docker-compose.dev.yml up -d

docker-logs:
	docker-compose logs -f

# Database operations
init-db:
	docker-compose exec semantic-search /app/setup/init-databases.sh

backup:
	@echo "Creating backup directory..."
	@mkdir -p backups/$(shell date +%Y%m%d-%H%M%S)
	@echo "Backing up Qdrant..."
	docker run --rm -v plasticity_qdrant_data:/data -v $(PWD)/backups/$(shell date +%Y%m%d-%H%M%S):/backup alpine tar czf /backup/qdrant-backup.tar.gz -C /data .
	@echo "Backing up ArangoDB..."
	docker-compose exec arangodb arangodump --server.database semantic_graph --output-directory /tmp/backup
	docker cp $(shell docker-compose ps -q arangodb):/tmp/backup ./backups/$(shell date +%Y%m%d-%H%M%S)/arango-backup
	@echo "Backup completed in backups/$(shell date +%Y%m%d-%H%M%S)/"

# Development helpers
dev-shell:
	docker-compose -f docker-compose.dev.yml exec semantic-search-dev bash

dev-build:
	docker-compose -f docker-compose.dev.yml exec semantic-search-dev zig build

dev-test:
	docker-compose -f docker-compose.dev.yml exec semantic-search-dev zig build test

# System info
status:
	@echo "=== System Status ==="
	@echo "Docker services:"
	@docker-compose ps
	@echo ""
	@echo "Qdrant health:"
	@curl -s http://localhost:6333/health || echo "Qdrant not accessible"
	@echo ""
	@echo "ArangoDB health:"
	@curl -s http://localhost:8529/_api/version || echo "ArangoDB not accessible"