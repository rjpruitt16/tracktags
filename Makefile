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

# Run integration tests using Python test runner
integration-test:
	@echo "Running integration tests with test runner..."
	@MOCK_MODE=true ADMIN_SECRET_KEY=admin_secret_key_123 python3 test/integration/test_runner.py
	@echo "Cleaning up test data..."
	@bash test/integration/cleanup_test_data.sh

# Run specific test pattern
integration-test-pattern:
	@echo "Running integration tests matching pattern: $(PATTERN)"
	@MOCK_MODE=true ADMIN_SECRET_KEY=admin_secret_key_123 python3 test/integration/test_runner.py --pattern "$(PATTERN)"
	@bash test/integration/cleanup_test_data.sh

# Run integration tests with services already running
integration-test-quick:
	@echo "Running integration tests (assuming services running)..."
	@MOCK_MODE=true ADMIN_SECRET_KEY=admin_secret_key_123 python3 test/integration/test_runner.py --skip-services
	@bash test/integration/cleanup_test_data.sh

# Run integration tests in verbose mode
integration-test-verbose:
	@echo "Running integration tests (verbose)..."
	@MOCK_MODE=true ADMIN_SECRET_KEY=admin_secret_key_123 python3 test/integration/test_runner.py --verbose
	@bash test/integration/cleanup_test_data.sh

# Run all tests locally
test: unit-test integration-test

# Docker commands with .env support
docker-build: $(DOCKER_BUILD_STAMP)

$(DOCKER_BUILD_STAMP): Dockerfile $(shell find src -type f -name "*.gleam") gleam.toml manifest.toml
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

test-docker: docker-up
	@echo "Running tests against Docker environment..."
	@sleep 5
	@echo "Using ADMIN_SECRET_KEY: $${ADMIN_SECRET_KEY:-admin_secret_key_123}"
	hurl --test --retry 3 --retry-interval 5000 --very-verbose \
		--variable ADMIN_SECRET_KEY=$${ADMIN_SECRET_KEY:-admin_secret_key_123} \
		--variable TRACKTAGS_URL=http://localhost:8080 \
		--variable PROXY_TARGET_URL=http://webhook:9090 \
		--variable test_id=$$(date +%s) \
		test/integration/test_proxy_forward.hurl || \
		(echo "Test failed, showing container logs:"; \
		 docker compose -f docker-compose.test.yml logs --tail=100 tracktags; \
		 exit 1)
	@bash test/integration/cleanup_test_data.sh
	@make docker-down

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
