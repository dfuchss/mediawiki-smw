#!/usr/bin/env bash
# Backup of a wiki: database dump and all uploads (originals, old versions, deleted files, thumbnails).
#
# Usage:   scripts/backup.sh <name>
# Reads:   the running db container (mysqldump) and the uploads (volume <name>_images or folder
#          data/images), through containers, so both storage modes work the same
# Writes:  backups/<name>/wiki-<YYYYmmdd-HHMMSS>.tar.gz with db.sql and images.tar, mode 600; prints
#          its path. Written as *.partial and renamed only when complete, so a failed run leaves no
#          truncated archive under a valid name.
# Exit:    0 on success; non-zero when the dump or the copy fails (the partial file is removed)
# Example: scripts/backup.sh demo   # nightly from cron, before Watchtower's update window
# shellcheck disable=SC2016  # single-quoted on purpose: expanded inside the container
. "$(dirname "$0")/lib.sh"
load_wiki "${1:-}"
backup_dir="$BACKUPS_DIR/$WIKI_NAME_ARG"
mkdir -p "$backup_dir"
backup_file="$backup_dir/wiki-$(date +%Y%m%d-%H%M%S).tar.gz"
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir" "$backup_file.partial"' EXIT

# The root password stays inside the container (MYSQL_PWD from its own environment)
"${COMPOSE[@]}" exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysqldump -uroot --single-transaction --routines --triggers --no-tablespaces "$MYSQL_DATABASE"' > "$temp_dir/db.sql"
"${RUN_ONE_OFF[@]}" -T --no-deps --entrypoint tar wiki -C /var/www/html/images -cf - . > "$temp_dir/images.tar"
tar -C "$temp_dir" -czf "$backup_file.partial" db.sql images.tar
mv "$backup_file.partial" "$backup_file"
echo "$backup_file"
