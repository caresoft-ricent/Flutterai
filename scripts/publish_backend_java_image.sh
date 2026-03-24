#!/usr/bin/env bash
set -euo pipefail

# Publish backend-java Docker image to a registry (for K8s rollout).
# Usage:
#   IMAGE_REPO=registry.example.com/team/flutterai-backend-java \
#   TAG=20260129-1 \
#   ./scripts/publish_backend_java_image.sh
#
# Notes (Mac -> Linux K8s):
#   PLATFORM defaults to linux/amd64.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

ENV_FILE="${ENV_FILE:-.env.registry}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

# Workaround for broken/misconfigured Docker credential helpers:
# Use a temporary isolated DOCKER_CONFIG so pulls from docker.io don't try to
# invoke a missing credsStore helper. This also prevents writing creds to the
# user's global ~/.docker/config.json.
ISOLATE_DOCKER_CONFIG="${ISOLATE_DOCKER_CONFIG:-1}"
TMP_DOCKER_CONFIG=""
if [[ "$ISOLATE_DOCKER_CONFIG" == "1" ]]; then
  TMP_DOCKER_CONFIG="$(mktemp -d 2>/dev/null || mktemp -d -t docker-config)"
  export DOCKER_CONFIG="$TMP_DOCKER_CONFIG"

  # Docker CLI plugins (like buildx) are discovered relative to DOCKER_CONFIG.
  # When we isolate DOCKER_CONFIG, we must also make the buildx plugin available.
  mkdir -p "$DOCKER_CONFIG/cli-plugins"
  if [[ ! -x "$DOCKER_CONFIG/cli-plugins/docker-buildx" ]]; then
    for candidate in \
      "$HOME/.docker/cli-plugins/docker-buildx" \
      "/Applications/Docker.app/Contents/Resources/cli-plugins/docker-buildx" \
      "/usr/local/lib/docker/cli-plugins/docker-buildx" \
      "/opt/homebrew/lib/docker/cli-plugins/docker-buildx"; do
      if [[ -x "$candidate" ]]; then
        ln -s "$candidate" "$DOCKER_CONFIG/cli-plugins/docker-buildx" 2>/dev/null || cp "$candidate" "$DOCKER_CONFIG/cli-plugins/docker-buildx"
        break
      fi
    done
  fi

  trap 'rm -rf "$TMP_DOCKER_CONFIG"' EXIT
fi

IMAGE_REPO="${IMAGE_REPO:-}"
TAG="${TAG:-}"
PLATFORM="${PLATFORM:-linux/amd64}"

DOCKER_REGISTRY="${DOCKER_REGISTRY:-}"
DOCKER_USERNAME="${DOCKER_USERNAME:-}"
DOCKER_PASSWORD="${DOCKER_PASSWORD:-}"

BASE_IMAGE_JDK="${BASE_IMAGE_JDK:-}"
BASE_IMAGE_JRE="${BASE_IMAGE_JRE:-}"

# Prefer locally available base images to avoid pulling from Docker Hub in restricted networks.
# You can override explicitly via BASE_IMAGE_JDK / BASE_IMAGE_JRE in the env file.
if [[ -z "$BASE_IMAGE_JDK" ]]; then
  if docker image inspect maven:3.9.9-eclipse-temurin-17 >/dev/null 2>&1; then
    BASE_IMAGE_JDK="maven:3.9.9-eclipse-temurin-17"
  elif docker image inspect maven:3.9.6-eclipse-temurin-17 >/dev/null 2>&1; then
    BASE_IMAGE_JDK="maven:3.9.6-eclipse-temurin-17"
  fi
fi

if [[ -z "$BASE_IMAGE_JRE" ]]; then
  if docker image inspect eclipse-temurin:17-jre >/dev/null 2>&1; then
    BASE_IMAGE_JRE="eclipse-temurin:17-jre"
  fi
fi

if [[ -f "$ENV_FILE" && -z "$DOCKER_PASSWORD" ]]; then
  if grep -Eq '^\s*#\s*DOCKER_PASSWORD\s*=' "$ENV_FILE"; then
    echo "NOTE: DOCKER_PASSWORD looks commented out in $ENV_FILE; remove the leading '#' so the script can log in non-interactively." >&2
  fi
fi

if [[ -z "$IMAGE_REPO" ]]; then
  echo "ERROR: IMAGE_REPO is required (e.g. registry.example.com/team/flutterai-backend-java)" >&2
  exit 1
fi

if [[ -z "$TAG" ]]; then
  TAG="$(date +%Y%m%d-%H%M%S)"
fi

if [[ -n "$DOCKER_REGISTRY" && -n "$DOCKER_USERNAME" ]]; then
  if [[ -n "$DOCKER_PASSWORD" ]]; then
    echo "Logging in to $DOCKER_REGISTRY as $DOCKER_USERNAME (password-stdin)"
    printf %s "$DOCKER_PASSWORD" | docker login "$DOCKER_REGISTRY" -u "$DOCKER_USERNAME" --password-stdin
  else
    echo "DOCKER_PASSWORD not set; running interactive login for $DOCKER_REGISTRY"
    docker login "$DOCKER_REGISTRY" -u "$DOCKER_USERNAME"
  fi
fi

echo "Building & pushing: ${IMAGE_REPO}:${TAG} (platform=${PLATFORM})"

if ! docker buildx version >/dev/null 2>&1; then
  echo "ERROR: docker buildx is not available in this environment. Disable isolation with ISOLATE_DOCKER_CONFIG=0, or ensure buildx plugin exists." >&2
  exit 1
fi

docker buildx build \
  --platform "$PLATFORM" \
  ${BASE_IMAGE_JDK:+--build-arg BASE_IMAGE_JDK="$BASE_IMAGE_JDK"} \
  ${BASE_IMAGE_JRE:+--build-arg BASE_IMAGE_JRE="$BASE_IMAGE_JRE"} \
  -t "${IMAGE_REPO}:${TAG}" \
  -t "${IMAGE_REPO}:latest" \
  --push \
  backend-java

echo "Done: ${IMAGE_REPO}:${TAG}"
