.PHONY: run test clean integration-test unit-test docker-build docker-up docker-down test-docker test-ci

# Include .env file if it exists
-include .env
export

# Build stamp for caching
DOCKER_BUILD_STAMP := .docker-build-stamp

# Local development
run:
	gleam run

build:
	gleam build

# Run unit tests
unit-test:
	MOCK_MODE=true gleam test

# Run all tests locally
test: unit-test 

# Docker commands with .env support
docker-build: $(DOCKER_BUILD_STAMP)

$(DOCKER_BUILD_STAMP): Dockerfile $(shell find src -type f -name "*.gleam") gleam.toml manifest.toml
	@echo "🔨 Building Docker image..."
	docker build -t tracktags .
	@touch $(DOCKER_BUILD_STAMP)

docker-up: docker-build
	@echo "Cleaning up old containers..."
	@docker compose -f docker-compose.test.yml down 2>/dev/null || true
	@test -f .env || (echo "ERROR: .env file not found" && exit 1)
	@echo "Starting services with .env file..."
	docker compose --env-file .env -f docker-compose.test.yml up -d
	@sleep 15
	@docker ps | grep tracktags
	@curl -f http://localhost:8080/health || docker logs tracktags-tracktags-1 | tail -20

# Run a specific integration test by path
# Usage: make test-single FILE=test/integration/hurl/test_reset_metrics.hurl
test-single:
	@if [ -z "$(FILE)" ]; then \
		echo "Error: FILE variable is required"; \
		echo "Usage: make test-single FILE=test/integration/hurl/test_reset_metrics.hurl"; \
		exit 1; \
	fi
	@if [ ! -f "$(FILE)" ]; then \
		echo "Error: File not found: $(FILE)"; \
		exit 1; \
	fi
	@echo "Running test: $(FILE)"
	@docker compose -f docker-compose.test.yml up -d
	@sleep 2
	hurl --test --verbose \
		--variable ADMIN_SECRET_KEY=$(ADMIN_SECRET_KEY) \
                --variable TRACKTAGS_URL=http://localhost:8080 \
                --variable SUPABASE_URL=$(SUPABASE_URL) \
		--variable SUPABASE_ANON_KEY=$(SUPABASE_ANON_KEY) \
                --variable PROXY_TARGET_URL=http://webhook:9090 \
		--variable test_id=$$(date +%s) \
		$(FILE) || \
		(echo "Test failed, showing container logs:"; \
		 docker compose -f docker-compose.test.yml logs --tail=100 tracktags; \
		 exit 1)

# Run all integration tests
test-docker:
	@echo "Starting Docker services..."
	@docker compose -f docker-compose.test.yml up -d
	@sleep 2
	@echo "Running integration tests..."
	hurl --test --retry 3 --retry-interval 5000 \
		--variable ADMIN_SECRET_KEY=$(ADMIN_SECRET_KEY) \
		--variable TRACKTAGS_URL=http://localhost:8080 \
		--variable SUPABASE_URL=$(SUPABASE_URL) \
		--variable SUPABASE_ANON_KEY=$(SUPABASE_ANON_KEY) \
		--variable PROXY_TARGET_URL=http://webhook:9090 \
		--variable test_id=$$(date +%s) \
		test/integration/hurl/*.hurl || \
		(echo "Test failed, showing container logs:"; \
		 docker compose -f docker-compose.test.yml logs --tail=200 tracktags; \
		 exit 1)
	@echo "Stopping Docker services..."
	@docker compose -f docker-compose.test.yml down
docker-down:
	docker compose -f docker-compose.test.yml down
	@docker rm -f tracktags webhook 2>/dev/null || true

# CI pipeline
test-ci: docker-build test-docker

# Clean build artifacts and test data
clean:
	rm -rf build _build $(DOCKER_BUILD_STAMP)
	docker compose -f docker-compose.test.yml down -v
	@bash test/integration/cleanup_test_data.sh

# Interactive Docker shell for debugging
docker-shell:
	docker run --rm -it --env-file .env tracktags /bin/sh
