#!/usr/bin/env bash
# Read-only smoke test of a running wiki (CI runs it on a throwaway wiki; safe on production):
#   the login page answers 200, anonymous API reads are denied (private wiki), the admin can log in,
#   siteinfo lists SemanticMediaWiki, and SMW's own API (smwinfo) answers.
#
# Usage:   scripts/smoke.sh <name>
# Reads:   wikis/<name>/.env (WIKI_SERVER, ADMIN_USER, ADMIN_PASSWORD); talks HTTP to WIKI_SERVER
# Writes:  nothing (a cookie jar in a private temp folder, removed on exit)
# Exit:    0 when all checks pass; 1 with "SMOKE FAIL: ..." on the first failing check
# Example: scripts/smoke.sh demo
. "$(dirname "$0")/lib.sh"
load_wiki "${1:-}"
: "${ADMIN_USER:?}" "${ADMIN_PASSWORD:?}"
base_url="$WIKI_SERVER"
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT
cookie_jar="$temp_dir/cookies"

# Prints the failure and exits 1.
fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }
# Calls api.php with the session cookies; extra curl arguments follow. Prints the response body.
api() { curl -sS -b "$cookie_jar" -c "$cookie_jar" "$base_url/api.php" "$@"; }

status_code=000
for _attempt in $(seq 60); do   # up to 2 minutes for update.php and Apache
  # -L: in other content languages the canonical page name differs (de: Spezial:Anmelden, a 301)
  status_code="$(curl -sL -o "$temp_dir/login.html" -w '%{http_code}' "$base_url/index.php?title=Special:UserLogin" || true)"
  [ "$status_code" = 200 ] && break
  sleep 2
done
[ "$status_code" = 200 ] || fail "login page returned $status_code"
echo "ok   login page 200"

api -G -d action=query -d meta=siteinfo -d format=json | grep -q '"readapidenied"' \
  || fail "anonymous api.php is not denied"
echo "ok   anonymous api.php: readapidenied"

# JSON escapes the token's backslash ("+\\"); undo that
login_token="$(api -G -d action=query -d meta=tokens -d type=login -d format=json \
  | sed -n 's/.*"logintoken":"\([^"]*\)".*/\1/p' | sed 's/\\\\/\\/g')"
[ -n "$login_token" ] || fail "no login token"
# The password goes to curl through stdin, not the command line (visible in ps)
printf '%s' "$ADMIN_PASSWORD" | api -d action=clientlogin -d format=json -d loginreturnurl="$base_url/" \
  --data-urlencode "username=$ADMIN_USER" --data-urlencode "password@-" --data-urlencode "logintoken=$login_token" \
  | grep -q '"status":"PASS"' || fail "admin login failed"
echo "ok   admin login"

api -G -d action=query -d meta=siteinfo -d siprop=extensions -d format=json | grep -q '"name":"SemanticMediaWiki"' \
  || fail "SemanticMediaWiki missing from siteinfo"
echo "ok   siteinfo lists SemanticMediaWiki"

api -G -d action=smwinfo -d format=json | grep -q '"propcount"' || fail "smwinfo does not answer"
echo "ok   smwinfo answers"
echo "smoke test passed: $base_url"
