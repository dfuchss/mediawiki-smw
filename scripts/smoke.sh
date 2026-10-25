#!/usr/bin/env bash
# Read-only smoke test of a running wiki (CI runs it on a throwaway wiki; safe on production):
#   the login page answers 200, anonymous API reads are denied (private wiki), the admin can log in,
#   siteinfo lists SemanticMediaWiki, and SMW's own API (smwinfo) answers.
#
# It talks to the wiki container directly: curl runs inside it (docker compose exec) against
# http://localhost, with X-Forwarded-Proto: https for an https WIKI_SERVER (what Traefik sends). So it
# needs no Traefik, DNS, TLS certificate or published port, and works right after install, before the
# public route exists. It does not test the public route (DNS, Traefik, certificate): open
# WIKI_SERVER in a browser for that.
#
# Usage:   scripts/smoke.sh <name>
# Reads:   wikis/<name>/.env (WIKI_SERVER, ADMIN_USER, ADMIN_PASSWORD); the running wiki container
# Writes:  nothing in the wiki (a cookie jar in a private temp folder inside the container, removed
#          on exit)
# Exit:    0 when all checks pass; 1 with "SMOKE FAIL: ..." on the first failing check. Every request
#          has a timeout and the wait for the login page is bounded (WAIT_SECONDS), so it never hangs.
# Example: scripts/smoke.sh demo
. "$(dirname "$0")/lib.sh"
load_wiki "${1:-}"
: "${ADMIN_USER:?}" "${ADMIN_PASSWORD:?}"

# How long to wait for the login page (update.php and Apache may still be starting)
WAIT_SECONDS=120
# Inside the container: the wiki's Apache
LOCAL_URL="http://localhost"
# The scheme of WIKI_SERVER, sent as X-Forwarded-Proto. MediaWiki 1.46 (WebRequest::detectProtocol)
# takes "X-Forwarded-Proto: https" as HTTPS from any client, independent of the trusted proxies
# ($wgCdnServersNoPurge only governs X-Forwarded-For), so $wgForceHTTPS does not redirect and no
# setting has to be relaxed. "http" changes nothing.
wiki_proto="${WIKI_SERVER%%://*}"

# Runs curl inside the wiki container (as www-data) with X-Forwarded-Proto, timeouts and the cookie
# jar $jar_path; $@: further curl arguments. Stdin is passed on (curl reads the password from it);
# callers without input redirect it from /dev/null, so docker never takes the terminal's input.
# Prints the response body; returns the exit code of curl (or of docker compose exec).
#
# Secure cookies: with an https WIKI_SERVER MediaWiki marks its session cookies Secure. curl keeps and
# sends Secure cookies only in a secure context, and it counts http://localhost as one (but not
# http://localhost with another Host header, which would make it drop them). So the Host header stays
# "localhost": MediaWiki builds its URLs and redirects from $wgServer, not from the Host header, and
# sets host-only cookies, so nothing depends on it. No jar editing, no cookies passed by hand.
in_wiki_curl() {
  "${COMPOSE[@]}" exec -T -u www-data wiki curl -sS --connect-timeout 5 --max-time 20 \
    -b "$jar_path" -c "$jar_path" -H "X-Forwarded-Proto: $wiki_proto" "$@"
}

# Prints the failure and exits 1.
fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }
# GET/POST to api.php with the session cookies; extra curl arguments follow. Prints the response body.
api() { in_wiki_curl "$LOCAL_URL/api.php" "$@" < /dev/null; }

# Prints "<http status> <redirect target>" for the login page. Redirects (other content languages:
# de: Spezial:Anmelden, a 301) point to WIKI_SERVER; up to 3 of them are followed via http://localhost.
login_page_status() {
  local url="$LOCAL_URL/index.php?title=Special:UserLogin" response status_code redirect_url hop
  for hop in 0 1 2 3; do
    response="$(in_wiki_curl -o /dev/null -w '%{http_code} %{redirect_url}' "$url" < /dev/null 2> /dev/null)" \
      || { echo "000 (no answer)"; return 0; }
    status_code="${response%% *}"; redirect_url="${response#* }"
    case "$status_code" in
      30[1278]) [ "$hop" -lt 3 ] && [[ "$redirect_url" == "$WIKI_SERVER/"* ]] || break
                url="$LOCAL_URL/${redirect_url#"$WIKI_SERVER/"}" ;;
      *) break ;;
    esac
  done
  echo "$response"
}

# Cookie jar in a private temp folder inside the container; removed on exit (if the container still runs)
jar_dir="$("${COMPOSE[@]}" exec -T -u www-data wiki mktemp -d < /dev/null 2> /dev/null)" \
  || fail "the wiki container is not running. Start it (scripts/compose.sh $WIKI_NAME_ARG up -d) and check scripts/compose.sh $WIKI_NAME_ARG logs wiki"
jar_path="$jar_dir/cookies"
trap '"${COMPOSE[@]}" exec -T -u www-data wiki rm -rf "$jar_dir" < /dev/null > /dev/null 2>&1 || true' EXIT

deadline=$((SECONDS + WAIT_SECONDS))
login_status="000"
while true; do
  login_status="$(login_page_status)"
  [ "${login_status%% *}" = 200 ] && break
  [ "$SECONDS" -lt "$deadline" ] || fail "login page: no 200 within ${WAIT_SECONDS}s (last answer: $login_status)." \
    "Is the wiki container running and healthy (scripts/compose.sh $WIKI_NAME_ARG ps)? See scripts/compose.sh $WIKI_NAME_ARG logs wiki"
  sleep 3
done
echo "ok   login page 200"

# The answer is read in full before grep looks at it: an early grep -q exit must not fail the pipe
api_answer="$(api -G -d action=query -d meta=siteinfo -d format=json)" || fail "api.php does not answer"
grep -q '"readapidenied"' <<< "$api_answer" || fail "anonymous api.php is not denied"
echo "ok   anonymous api.php: readapidenied"

# JSON escapes the token's backslash ("+\\"); undo that
api_answer="$(api -G -d action=query -d meta=tokens -d type=login -d format=json)" || fail "api.php does not answer"
login_token="$(sed -n 's/.*"logintoken":"\([^"]*\)".*/\1/p' <<< "$api_answer" | sed 's/\\\\/\\/g')"
[ -n "$login_token" ] || fail "no login token"
# The password goes to curl in the container through stdin, never on a command line (visible in ps)
api_answer="$(printf '%s' "$ADMIN_PASSWORD" | in_wiki_curl "$LOCAL_URL/api.php" -d action=clientlogin -d format=json \
  -d loginreturnurl="$WIKI_SERVER/" --data-urlencode "username=$ADMIN_USER" --data-urlencode "password@-" \
  --data-urlencode "logintoken=$login_token")" || fail "api.php does not answer the login"
grep -q '"status":"PASS"' <<< "$api_answer" || fail "admin login failed"
echo "ok   admin login"

api_answer="$(api -G -d action=query -d meta=siteinfo -d siprop=extensions -d format=json)" || fail "api.php does not answer"
grep -q '"name":"SemanticMediaWiki"' <<< "$api_answer" || fail "SemanticMediaWiki missing from siteinfo"
echo "ok   siteinfo lists SemanticMediaWiki"

api_answer="$(api -G -d action=smwinfo -d format=json)" || fail "api.php does not answer"
grep -q '"propcount"' <<< "$api_answer" || fail "smwinfo does not answer"
echo "ok   smwinfo answers"
echo "smoke test passed: $WIKI_SERVER (through the wiki container)"
