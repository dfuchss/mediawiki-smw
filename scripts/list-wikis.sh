#!/usr/bin/env bash
# Lists the wikis in wikis/: name, URL, local port and whether their containers run.
#
# Usage:   scripts/list-wikis.sh
# Reads:   wikis/*/.env (only WIKI_SERVER and WIKI_PORT, without sourcing it); docker compose ps
# Writes:  nothing
# Exit:    0 (also when there are no wikis)
# Example: scripts/list-wikis.sh
. "$(dirname "$0")/lib.sh"

# Prints the value of setting $2 in the .env file $1 (quotes removed), or nothing.
env_value() {
  local env_file="$1" setting="$2"
  sed -n "s/^$setting=//p" "$env_file" | tail -n 1 | sed "s/^['\"]//; s/['\"]$//"
}

printf '%-20s %-40s %-6s %s\n' NAME URL PORT STATE
for env_file in "$WIKIS_DIR"/*/.env; do
  [ -f "$env_file" ] || continue
  wiki_name="$(basename "$(dirname "$env_file")")"
  running_count="$(docker compose -p "$wiki_name" ps --status running -q 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$running_count" -gt 0 ]; then state="running ($running_count)"; else state=stopped; fi
  printf '%-20s %-40s %-6s %s\n' "$wiki_name" "$(env_value "$env_file" WIKI_SERVER)" "$(env_value "$env_file" WIKI_PORT)" "$state"
done
