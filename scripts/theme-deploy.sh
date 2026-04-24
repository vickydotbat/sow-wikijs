#!/usr/bin/env bash
set -euo pipefail

THEME_NAME="${THEME_NAME:-westgate}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WIKI_HOME="${WIKI_HOME:-$HOME/wikijs}"
DEPLOY_DIR="${DEPLOY_DIR:-${WIKI_HOME}/deploy}"
BUILD_DIR="${BUILD_DIR:-${WIKI_HOME}/build}"
BUILD_SRC_DIR="${BUILD_DIR}/wiki-src"
STATE_DIR="${BUILD_DIR}/.theme-deploy"
ENV_FILE="${ENV_FILE:-${DEPLOY_DIR}/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-${DEPLOY_DIR}/docker-compose.yml}"
SOURCE_THEME_DIR="${REPO_ROOT}/client/themes/${THEME_NAME}"
TARGET_THEME_DIR="${BUILD_SRC_DIR}/client/themes/${THEME_NAME}"
SOURCE_STATIC_DIR="${REPO_ROOT}/client/static"
TARGET_STATIC_DIR="${BUILD_SRC_DIR}/client/static"
SOURCE_FAVICON_DIR="${REPO_ROOT}/client/static/favicons"
TARGET_FAVICON_DIR="${BUILD_SRC_DIR}/client/static/favicons"
STATE_HASH_FILE="${STATE_DIR}/${THEME_NAME}.sha256"
STATE_VERSION_FILE="${STATE_DIR}/wiki-version"


log() {
  printf '[theme-deploy] %s\n' "$*"
}

fail() {
  printf '[theme-deploy] ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

require_file() {
  [ -f "$1" ] || fail "Missing required file: $1"
}

require_dir() {
  [ -d "$1" ] || fail "Missing required directory: $1"
}

theme_hash() {
  (
    {
      cd "$SOURCE_THEME_DIR"
      find . -type f -print0 | sort -z | xargs -0 sha256sum

      cd "$SOURCE_STATIC_DIR"
      find favicon.ico browserconfig.xml manifest.json favicons -type f -print0 | sort -z | xargs -0 sha256sum
    } | sha256sum | awk '{print $1}'
  )
}

ensure_build_tree() {
  local current_version=''

  mkdir -p "$BUILD_DIR" "$STATE_DIR"

  if [ -f "$STATE_VERSION_FILE" ]; then
    current_version="$(cat "$STATE_VERSION_FILE")"
  fi

  if [ ! -d "$BUILD_SRC_DIR" ] || [ "$current_version" != "$WIKI_VERSION" ]; then
    log "Preparing stable Wiki.js source tree for ${WIKI_VERSION}"
    rm -rf "$BUILD_SRC_DIR"
    cd "$BUILD_DIR"
    curl -fsSL "https://github.com/Requarks/wiki/archive/refs/tags/v${WIKI_VERSION}.tar.gz" | tar -xz
    mv "wiki-${WIKI_VERSION}" wiki-src
    printf '%s' "$WIKI_VERSION" > "$STATE_VERSION_FILE"
    rm -f "$STATE_HASH_FILE"
  fi
}

patch_release_metadata() {
  cd "$BUILD_SRC_DIR"
  sed -i 's/"dev": true/"dev": false/' package.json
  sed -i "s/\"version\": \"2.0.0\"/\"version\": \"${WIKI_VERSION}\"/" package.json
  sed -i "s/\"releaseDate\": \".*\"/\"releaseDate\": \"${WIKI_RELEASE_DATE}\"/" package.json
}

main() {
  require_command curl
  require_command docker
  require_command rsync
  require_command sha256sum
  require_command tar
  require_command sed

  require_file "$ENV_FILE"
  require_file "$COMPOSE_FILE"
  require_dir "$SOURCE_THEME_DIR"
  require_dir "$SOURCE_STATIC_DIR"
  require_dir "$SOURCE_FAVICON_DIR"
  require_file "${SOURCE_STATIC_DIR}/favicon.ico"
  require_file "${SOURCE_STATIC_DIR}/browserconfig.xml"
  require_file "${SOURCE_STATIC_DIR}/manifest.json"

  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a

  : "${WIKI_VERSION:?WIKI_VERSION must be set in ${ENV_FILE}}"
  : "${WIKI_RELEASE_DATE:?WIKI_RELEASE_DATE must be set in ${ENV_FILE}}"
  : "${WIKI_IMAGE:?WIKI_IMAGE must be set in ${ENV_FILE}}"
  : "${WIKI_HTTP_PORT:?WIKI_HTTP_PORT must be set in ${ENV_FILE}}"

  ensure_build_tree
  patch_release_metadata

  local current_hash previous_hash='' should_build='false'
  current_hash="$(theme_hash)"

  if [ -f "$STATE_HASH_FILE" ]; then
    previous_hash="$(cat "$STATE_HASH_FILE")"
  fi

  if [ "$current_hash" != "$previous_hash" ]; then
    should_build='true'
    log "Theme or favicon changes detected"
  fi

  if ! docker image inspect "$WIKI_IMAGE" >/dev/null 2>&1; then
    should_build='true'
    log "Docker image ${WIKI_IMAGE} is missing"
  fi

  if [ "$should_build" = 'true' ]; then
    log "Syncing ${THEME_NAME} theme into stable source tree"
    mkdir -p "$TARGET_THEME_DIR"
    rsync -a --delete "${SOURCE_THEME_DIR}/" "${TARGET_THEME_DIR}/"
    mkdir -p "$TARGET_STATIC_DIR"
    mkdir -p "$TARGET_FAVICON_DIR"
    rsync -a "${SOURCE_STATIC_DIR}/favicon.ico" "${TARGET_STATIC_DIR}/favicon.ico"
    rsync -a "${SOURCE_STATIC_DIR}/browserconfig.xml" "${TARGET_STATIC_DIR}/browserconfig.xml"
    rsync -a "${SOURCE_STATIC_DIR}/manifest.json" "${TARGET_STATIC_DIR}/manifest.json"
    rsync -a --delete "${SOURCE_FAVICON_DIR}/" "${TARGET_FAVICON_DIR}/"

    log "Building ${WIKI_IMAGE}"
    cd "$BUILD_SRC_DIR"
    docker build -f dev/build/Dockerfile -t "$WIKI_IMAGE" .
    printf '%s' "$current_hash" > "$STATE_HASH_FILE"
  else
    log "No theme changes detected; skipping image rebuild"
  fi

  log "Starting Wiki.js stack on host port ${WIKI_HTTP_PORT}"
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d
}

main "$@"
