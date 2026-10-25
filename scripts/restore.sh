#!/usr/bin/env bash
# Restore a wiki from a backup of scripts/backup.sh (also to move a wiki to another host or name).
#
# Usage:   scripts/restore.sh <name> [--yes] <archive.tar.gz>
#   --yes  skip the confirmation (required when stdin is not a terminal)
# Reads:   the archive (db.sql, images.tar), wikis/<name>/.env
# Writes:  REPLACES the database and the uploads (volume <name>_images or folder data/images), runs update.php, starts the wiki.
#          Works on a wiki that was never installed, too (new-wiki.sh without install, then restore).
# Exit:    0 on success; 1 before anything is changed when the archive is not a valid backup or the
#          confirmation fails; non-zero when a restore step fails
# Example: scripts/restore.sh demo backups/demo/wiki-20260101-030000.tar.gz
# shellcheck disable=SC2016  # single-quoted on purpose: expanded inside the container
. "$(dirname "$0")/lib.sh"
usage="usage: scripts/restore.sh <name> [--yes] <archive.tar.gz>"
load_wiki "${1:-}"; shift
assume_yes=0
if [ "${1:-}" = --yes ]; then assume_yes=1; shift; fi
archive_path="${1:?$usage}"
[ -f "$archive_path" ] || die "No such file: $archive_path"

# Validate the archive completely before touching anything
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT
tar -C "$temp_dir" -xzf "$archive_path" db.sql images.tar \
  || die "Not a wiki backup (needs db.sql and images.tar): $archive_path"
grep -q 'CREATE TABLE' "$temp_dir/db.sql" || die "db.sql in $archive_path is not a dump"
tar -tf "$temp_dir/images.tar" > /dev/null || die "images.tar in $archive_path is damaged"

if [ "$assume_yes" != 1 ]; then
  [ -t 0 ] || die "Refusing to restore without confirmation; pass --yes"
  echo "This REPLACES the database and all uploads of wiki '$WIKI_NAME_ARG' with $archive_path."
  read -r -p "Type the wiki name to continue: " confirmation
  [ "$confirmation" = "$WIKI_NAME_ARG" ] || die "Aborted; nothing changed."
fi

ensure_image
"${COMPOSE[@]}" up -d --wait db
"${COMPOSE[@]}" stop wiki
"${COMPOSE[@]}" exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -e "DROP DATABASE IF EXISTS \`$MYSQL_DATABASE\`; CREATE DATABASE \`$MYSQL_DATABASE\`"'
"${COMPOSE[@]}" exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot "$MYSQL_DATABASE"' < "$temp_dir/db.sql"
# As root: empty the volume or folder, unpack, and give everything back to www-data (Apache and the job loop
# write there; the archive may come from a host with other user ids)
"${RUN_ONE_OFF[@]}" -T --no-deps -u root --entrypoint sh wiki -c \
  'find /var/www/html/images -mindepth 1 -delete && tar -C /var/www/html/images -xf - && chown -R www-data:www-data /var/www/html/images' \
  < "$temp_dir/images.tar"
"${RUN_ONE_OFF[@]}" -T wiki update
"${COMPOSE[@]}" up -d --wait --wait-timeout 600
echo "Restored '$WIKI_NAME_ARG' from $archive_path"
