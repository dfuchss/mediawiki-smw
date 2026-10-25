#!/usr/bin/env bash
# First install of a wiki: creates the database and the admin account, then starts the wiki and
# waits until it is healthy. Pulls or builds the image first if it is missing (see ensure_image).
#
# Usage:   scripts/install.sh <name>
# Reads:   wikis/<name>/.env (ADMIN_USER, ADMIN_PASSWORD and the wiki settings)
# Writes:  the database and the update stamp (volumes <name>_db-data and <name>_wiki-state, or the
#          folders data/db and data/state); starts both containers
# Exit:    0 when the wiki is installed and healthy; non-zero when any step fails (the installer
#          refuses to run on a database that is already installed)
# Example: scripts/install.sh demo
# shellcheck disable=SC2016  # single-quoted on purpose: expanded inside the container
. "$(dirname "$0")/lib.sh"
load_wiki "${1:-}"
: "${ADMIN_USER:?set ADMIN_USER in $WIKI_DIR/.env}" "${ADMIN_PASSWORD:?set ADMIN_PASSWORD in $WIKI_DIR/.env}"
ensure_image
"${COMPOSE[@]}" up -d --wait db

# The admin password goes from the host's environment (the .env) through stdin, the DB password from
# the container's own environment; both reach the installer as private files in the one-off
# container's /tmp, never on a command line (visible in ps). The installer's generated
# LocalSettings.php goes to /tmp and is discarded: the image's /config is used afterwards.
printf '%s' "$ADMIN_PASSWORD" | "${RUN_ONE_OFF[@]}" -T -u www-data -e MW_CONFIG_FILE=/nonexistent/LocalSettings.php \
  wiki sh -c 'umask 077 && cat > /tmp/pass && printf "%s" "$DB_PASSWORD" > /tmp/dbpass && exec php maintenance/run.php install \
    --dbtype mysql --dbserver db --dbname "$DB_NAME" --dbuser "$DB_USER" --dbpassfile /tmp/dbpass \
    --server "$WIKI_SERVER" --scriptpath "" --lang "$WIKI_LANG" \
    --passfile /tmp/pass --skins Vector --confpath /tmp \
    "$WIKI_NAME" "$1"' sh "$ADMIN_USER"

# update.php with our settings (SMW tables) and the update stamp, so the wiki does not run it again
"${RUN_ONE_OFF[@]}" -T wiki update
"${COMPOSE[@]}" up -d --wait --wait-timeout 600
echo "Installed '$WIKI_NAME_ARG'. Log in as $ADMIN_USER at $WIKI_SERVER (password: ADMIN_PASSWORD in $WIKI_DIR/.env)"
