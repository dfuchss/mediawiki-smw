#!/usr/bin/env bash
# Shared code for the scripts in this folder. Source it, do not run it.
#
# Usage (in a script):  . "$(dirname "$0")/lib.sh"; load_wiki "${1:-}"; shift
#
# Provides:
#   REPO_ROOT, WIKIS_DIR (REPO_ROOT/wikis), BACKUPS_DIR (REPO_ROOT/backups)
#   die, is_valid_wiki_name, wiki_storage_mode, ensure_image, load_wiki
#   after load_wiki: WIKI_NAME_ARG, WIKI_DIR, every variable of the wiki's .env (exported), and the
#   command arrays COMPOSE (docker compose for this wiki) and RUN_ONE_OFF (compose run for one-off
#   containers)
# Reads:  wikis/<name>/.env and wikis/<name>/compose.yaml. Writes nothing itself.
# Exit:   load_wiki exits 1 with a message when the name, the folder or a required setting is wrong.
# Example: scripts/compose.sh demo ps   (compose.sh is three lines on top of this file)
#
# Works with bash 3.2 (macOS): no associative arrays, no ${var,,}, no empty "${array[@]}" under set -u.
set -euo pipefail
# Backups, dumps, generated .env files and temp files: readable by the owner only
umask 077

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WIKIS_DIR="$REPO_ROOT/wikis"
# shellcheck disable=SC2034  # used by the scripts that source this file
BACKUPS_DIR="$REPO_ROOT/backups"
# Settings a wiki cannot run without (compose.yaml would stop with a less helpful message)
REQUIRED_SETTINGS="COMPOSE_PROJECT_NAME WIKI_SERVER WIKI_IMAGE WIKI_TAG WIKI_PORT DB_PASSWORD DB_ROOT_PASSWORD WIKI_SECRET_KEY WIKI_UPGRADE_KEY"

# Prints its arguments to stderr and exits 1.
die() { echo "$*" >&2; exit 1; }

# Returns 0 when $1 is a valid wiki name: a lowercase slug (letters, digits, dashes; starts with a
# letter or digit; at most 40 characters). It is the folder name and the compose project name.
is_valid_wiki_name() {
  local candidate="$1"
  [[ "$candidate" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]]
}

# Prints how the wiki folder $1 stores its data: "folders" when its compose.yaml bind-mounts
# ./data/db, otherwise "volumes" (Docker named volumes). Read from the file, so it follows hand edits.
wiki_storage_mode() {
  if grep -q '^ *- \./data/db:' "$1/compose.yaml" 2> /dev/null; then echo folders; else echo volumes; fi
}

# Makes sure the image WIKI_IMAGE:WIKI_TAG is available. Without an argument it does nothing when the
# image exists locally. "refresh" pulls or builds it anyway. Images with a registry path (a "/" in the
# name, e.g. ghcr.io/<owner>/<repo>) are pulled; plain names (mediawiki-smw) are built from this
# repository. Returns the exit code of docker pull/build.
ensure_image() {
  local mode="${1:-}"
  local image_ref="$WIKI_IMAGE:$WIKI_TAG"
  if [ "$mode" != refresh ] && docker image inspect "$image_ref" > /dev/null 2>&1; then
    return 0
  fi
  case "$WIKI_IMAGE" in
    */*) echo "Pulling $image_ref"; docker pull "$image_ref" ;;
    *)   echo "Building $image_ref from $REPO_ROOT"; docker build --pull -t "$image_ref" "$REPO_ROOT" ;;
  esac
}

# Selects the wiki wikis/<name>: checks the name and its files, loads its .env (exported, so docker
# compose and the scripts see the same values) and sets COMPOSE and RUN_ONE_OFF.
# $1: wiki name. Exits 1 with a message on any problem.
load_wiki() {
  local wiki_name="${1:-}" var_name missing_settings=""
  [ -n "$wiki_name" ] || die "Missing wiki name. Existing wikis: $(find "$WIKIS_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort | tr '\n' ' ')"
  is_valid_wiki_name "$wiki_name" || die "Invalid wiki name '$wiki_name' (lowercase letters, digits, dashes)"
  # shellcheck disable=SC2034  # used by the scripts that source this file
  WIKI_NAME_ARG="$wiki_name"
  WIKI_DIR="$WIKIS_DIR/$wiki_name"
  [ -d "$WIKI_DIR" ] || die "No wiki '$wiki_name' (no folder $WIKI_DIR; create one with scripts/new-wiki.sh)"
  [ -f "$WIKI_DIR/.env" ] || die "Missing $WIKI_DIR/.env"
  [ -f "$WIKI_DIR/compose.yaml" ] || die "Missing $WIKI_DIR/compose.yaml"

  set -a
  # shellcheck source=/dev/null
  . "$WIKI_DIR/.env"
  set +a
  for var_name in $REQUIRED_SETTINGS; do
    [ -n "${!var_name:-}" ] || missing_settings="$missing_settings $var_name"
  done
  [ -z "$missing_settings" ] || die "Set these in $WIKI_DIR/.env:$missing_settings"
  # Plain `docker compose` in the folder uses COMPOSE_PROJECT_NAME; the scripts use the folder name.
  # They must agree, or the two would manage different volumes.
  [ "$COMPOSE_PROJECT_NAME" = "$wiki_name" ] \
    || die "COMPOSE_PROJECT_NAME=$COMPOSE_PROJECT_NAME in $WIKI_DIR/.env must equal the folder name '$wiki_name'"

  COMPOSE=(docker compose --project-directory "$WIKI_DIR" -p "$wiki_name"
           -f "$WIKI_DIR/compose.yaml" --env-file "$WIKI_DIR/.env")
  # One-off containers (install, backup, restore) must never be registered as Traefik backends
  # shellcheck disable=SC2034  # used by the scripts that source this file
  RUN_ONE_OFF=("${COMPOSE[@]}" run --rm -l traefik.enable=false)
}
