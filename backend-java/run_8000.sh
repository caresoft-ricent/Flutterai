#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# Build (uses Maven Wrapper, no system Maven required)
./mvnw -q -DskipTests package

JAR="$(ls -1t target/backend-*.jar | grep -v '\.original$' | head -n 1)"

echo "Starting $JAR on http://localhost:8000"
exec java -jar "$JAR" --server.port=8000
