#!/usr/bin/env bash
# docker compose for one wiki: the same as running `docker compose` inside wikis/<name>/, from anywhere.
#
# Usage:   scripts/compose.sh <name> <compose command> [args...]
# Reads:   wikis/<name>/.env, wikis/<name>/compose.yaml (see lib.sh)
# Writes:  whatever the compose command does (containers, volumes <name>_*)
# Exit:    docker compose's exit code; 1 when the wiki cannot be loaded
# Example: scripts/compose.sh demo logs -f wiki
. "$(dirname "$0")/lib.sh"
load_wiki "${1:-}"; shift
exec "${COMPOSE[@]}" "$@"
