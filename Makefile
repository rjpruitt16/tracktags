.PHONY: run test clean integration-test unit-test docker-build docker-up docker-down test-docker test-ci

# Include .env file if it exists
-include .env
export

# Local development
run:
	gleam run

build:
	gleam build

# Run unit tests
unit-test:
	gleam test

# Run integration tests locally with cleanup
integration-test:
	@echo "Running integration tests..."
	hurl --test --retry 3 --retry-interval 5000ms \
		--variable ADMIN_API_KEY=$${ADMIN_API_KEY:-admin_secret_key_123} \
		--variable TRACKTAGS_URL=http://localhost:8080 \
		--variable PROXY_TARGET_URL=http://httpbin.org/post \
		--variable test_id=$$(date +%s) \
		test/integration/test_proxy_forward.hurl
	@echo "Cleaning up test data..."
	@bash test/integration/cleanup_test_data.sh

# Run all tests locally
test: unit-test integration-test

# Docker commands with .env support
docker-build:
	docker build -t tracktags .

docker-up: docker-build
	@echo "Cleaning up old containers..."
	@docker compose -f docker-compose.test.yml down 2>/dev/null || true
	@if [ ! -f .env ]; then \
		echo "ERROR: .env file not found"; \
		exit 1; \
	fi
	@echo "Starting services with .env file..."
	docker compose --env-file .env -f docker-compose.test.yml up -d
	@sleep 15
	@docker ps | grep tracktags
	@curl -f http://localhost:8080/health || docker logs tracktags-tracktags-1 | tail -20

test-docker: docker-up
	@echo "Running tests against Docker environment..."
	@sleep 5
	@if [ -f .env ]; then \
		export $$(grep -v '^#' .env | xargs) && \
		hurl --test --retry 3 --retry-interval 5000ms \
			--variable ADMIN_API_KEY=$${ADMIN_API_KEY:-admin_secret_key_123} \
			--variable TRACKTAGS_URL=http://localhost:8080 \
			--variable PROXY_TARGET_URL=http://webhook:9090/webhook \
			--variable test_id=$$(date +%s) \
			test/integration/test_proxy_forward.hurl; \
	else \
		hurl --test --retry 3 --retry-interval 5000ms \
			--variable ADMIN_API_KEY=admin_secret_key_123 \
			--variable TRACKTAGS_URL=http://localhost:8080 \
			--variable PROXY_TARGET_URL=http://webhook:9090/webhook \
			--variable test_id=$$(date +%s) \
			test/integration/test_proxy_forward.hurl; \
	fi
	@bash test/integration/cleanup_test_data.sh
	@make docker-down

docker-down:
	docker compose -f docker-compose.test.yml down
	@docker rm -f tracktags webhook 2>/dev/null || true

# CI pipeline
test-ci: docker-build test-docker

# Clean build artifacts and test data
clean:
	rm -rf build _build
	docker compose -f docker-compose.test.yml down -v
	@bash test/integration/cleanup_test_data.sh

# Interactive Docker shell for debugging
docker-shell:
	@if [ -f .env ]; then \
		docker run --rm -it --env-file .env tracktags /bin/sh; \
	else \
		docker run --rm -it tracktags /bin/sh; \
	fi
