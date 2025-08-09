#!/bin/bash

# Start the app
echo "Starting TrackTags..."
gleam run &
APP_PID=$!
sleep 5

# Run tests
echo "Running tests..."
./test/test_daily_limits.sh
./test/test_overage.sh
./test/test_invoice_webhook.sh

# Cleanup
kill $APP_PID

echo "✅ Tests complete!"
