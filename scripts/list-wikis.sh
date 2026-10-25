#!/usr/bin/env bash
# Lists the wikis in wikis/: name, URL, published port, data storage (volumes or folders) and
# whether their containers run.
# PORT is the host port the wiki is really published on: read from the running container; for a
# stopped wiki WIKI_PORT from .env when compose.yaml has an active `ports:` mapping; "-" when it has
# none (behind Traefik).
#
# Usage:   scripts/list-wikis.sh
# Reads:   wikis/*/.env (only WIKI_SERVER and WIKI_PORT, without sourcing it), wikis/*/compose.yaml
#          (storage mode, ports mapping); docker compose ps, docker ps (published ports)
# Writes:  nothing
# Exit:    0 (also when there are no wikis)
# Example: scripts/list-wikis.sh
. "$(dirname "$0")/lib.sh"

# Prints the value of setting $2 in the .env file $1 (quotes removed), or nothing.
env_value() {
  local env_file="$1" setting="$2"
  sed -n "s/^$setting=//p" "$env_file" | tail -n 1 | sed "s/^['\"]//; s/['\"]$//"
}

# Prints the host port wiki $1 (folder $2) is published on, or "-" when it publishes none.
published_port() {
  local wiki_name="$1" wiki_dir="$2" port_mappings
  port_mappings="$(docker ps --filter "label=com.docker.compose.project=$wiki_name" \
    --filter label=com.docker.compose.service=wiki --format '{{.Ports}}' 2> /dev/null || true)"
  if [ -n "$port_mappings" ]; then
    # e.g. "127.0.0.1:8081->80/tcp"; a running container without a mapping shows "80/tcp"
    printf '%s\n' "$port_mappings" | sed -n 's/^.*:\([0-9][0-9]*\)->80\/tcp.*$/\1/p' | head -n 1 | grep . || echo -
  elif grep -q '^ *ports:' "$wiki_dir/compose.yaml" 2> /dev/null; then
    env_value "$wiki_dir/.env" WIKI_PORT
  else
    echo -
  fi
}

printf '%-20s %-40s %-6s %-8s %s\n' NAME URL PORT STORAGE STATE
for env_file in "$WIKIS_DIR"/*/.env; do
  [ -f "$env_file" ] || continue
  wiki_name="$(basename "$(dirname "$env_file")")"
  running_count="$(docker compose -p "$wiki_name" ps --status running -q 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$running_count" -gt 0 ]; then state="running ($running_count)"; else state=stopped; fi
  printf '%-20s %-40s %-6s %-8s %s\n' "$wiki_name" "$(env_value "$env_file" WIKI_SERVER)" "$(published_port "$wiki_name" "$(dirname "$env_file")")" \
    "$(wiki_storage_mode "$(dirname "$env_file")")" "$state"
done
