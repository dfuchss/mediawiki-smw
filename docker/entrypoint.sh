#!/usr/bin/env bash
# Image entrypoint of the wiki container.
#
# Usage: wiki-entrypoint [apache2-foreground | update | job-loop | <command> [args...]]
#   apache2-foreground (default CMD)  run update.php if this image and config are new to the database,
#                                     then supervise Apache and the job loop
#   update                            force update.php and record the stamp (install.sh, restore.sh)
#   job-loop                          internal: the job queue loop, started by the supervisor below
#   anything else                     passed to the base image's entrypoint unchanged (php ..., sh, ...)
#
# Reads:  WIKI_RECIPE (set in the image), /config/*.php (baked in, plus the mounted settings.php),
#         DB_NAME/DB_USER/DB_PASSWORD, JOB_RUNNER_INTERVAL.
# Writes: /var/lib/wiki-state/stamp and .../lock (volume or folder wiki-state). When it starts as root
#         it also hands /var/www/html/images and /var/lib/wiki-state to www-data if they belong to
#         someone else (a fresh bind-mounted folder is owned by root or the host user).
# Exit:   0 after `update` or a clean stop, 143 on a signal before the supervisor runs, 1 when
#         update.php fails, the database stays unreachable, or Apache or the job loop dies (the
#         restart policy then restarts the container).
# Example: docker compose run --rm wiki update
set -euo pipefail
cd /var/www/html

# Prints a log line with a prefix, so entrypoint messages stand out in `docker compose logs`.
log() { echo "[entrypoint] $*"; }

# Bash as PID 1 ignores SIGTERM unless trapped, and runs a trap only after the foreground command
# returns. So the trap is set first, and every long step runs as a child (run_child) that the trap
# forwards the signal to: `docker stop` takes about a second in every phase (lock, DB wait, update).
child_pid=

# Signal handler: stops the running child (if any) and exits 143.
# shellcheck disable=SC2329  # invoked by the trap below
on_signal() {
  log "signal received, stopping"
  if [ -n "$child_pid" ]; then
    kill -TERM "$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
  fi
  exit 143
}
trap on_signal TERM INT

# Runs "$@" in the background and waits for it, so the signal trap can interrupt the wait.
# Returns the command's exit code.
run_child() {
  local exit_code=0
  "$@" & child_pid=$!
  wait "$child_pid" || exit_code=$?
  child_pid=
  return "$exit_code"
}

STATE_DIR=/var/lib/wiki-state   # named volume or host folder
IMAGES_DIR=/var/www/html/images # uploads: named volume or host folder
STAMP_FILE="$STATE_DIR/stamp"   # recipe of the last image+config whose update.php succeeded
# The configuration (baked into the image, plus the wiki's mounted settings.php) is part of the
# recipe: loading an extension or changing SMW settings can need update.php.
CONFIG_HASH="$(cat /config/*.php | sha256sum | cut -c1-16)"
RECIPE="${WIKI_RECIPE:?WIKI_RECIPE missing from the image} config=$CONFIG_HASH"

# Runs "$@" as www-data (Apache drops to it as well), unless we already are non-root.
as_www() { if [ "$(id -u)" = 0 ]; then runuser -u www-data -- "$@"; else "$@"; fi; }

# Gives the data directories $@ to www-data when running as root and the top-level owner is someone
# else. Docker creates a named volume with the owner of the image's directory, but a bind-mounted host
# folder keeps its host owner (root or the host user), where Apache could not write uploads. Only the
# directory itself is checked and changed, never the tree below it (a big upload tree would make
# every start slow); restore.sh chowns recursively after unpacking.
ensure_data_ownership() {
  [ "$(id -u)" = 0 ] || return 0
  local data_dir wanted_owner current_owner
  wanted_owner="$(id -u www-data):$(id -g www-data)"
  for data_dir in "$@"; do
    [ -d "$data_dir" ] || continue
    current_owner="$(stat -c '%u:%g' "$data_dir")"
    [ "$current_owner" = "$wanted_owner" ] && continue
    log "giving $data_dir to www-data (was $current_owner)"
    chown www-data:www-data "$data_dir" || log "warning: cannot chown $data_dir; uploads may fail"
  done
}

# Checks the database. Exit 0: wiki installed, 1: reachable but empty (fresh volume), 2: unreachable.
# shellcheck disable=SC2016  # PHP code, not shell
db_state() {
  php -r '
    mysqli_report(MYSQLI_REPORT_OFF);
    $conn = @mysqli_connect("db", getenv("DB_USER"), getenv("DB_PASSWORD"), getenv("DB_NAME") ?: "wiki");
    if (!$conn) exit(2);
    $result = mysqli_query($conn, "SHOW TABLES LIKE \"page\"");
    exit($result && mysqli_num_rows($result) ? 0 : 1);'
}

# Waits up to 5 minutes for the database (Watchtower may be restarting it at the same time).
# Sets wiki_installed to 1 or 0; exits 1 when the database never answers.
wait_db() {
  local attempt state
  for attempt in $(seq 60); do
    state=0; run_child db_state || state=$?
    if [ "$state" != 2 ]; then wiki_installed=$(( state == 0 )); return 0; fi
    log "waiting for database ($attempt/60)"; run_child sleep 5
  done
  log "database not reachable, giving up"; exit 1
}

# Runs update.php and writes the stamp only on success; exits 1 when update.php fails.
# A signal during update.php ends the container without writing the stamp (on_signal), so the next
# start runs it again. That is safe: update.php is idempotent and only applies what is missing.
run_update() {
  log "running update.php for: $RECIPE"
  if ! run_child as_www php maintenance/run.php update --quick; then
    log "update.php FAILED; stamp left at: $(cat "$STAMP_FILE" 2>/dev/null || echo none)"; exit 1
  fi
  printf '%s\n' "$RECIPE" > "$STAMP_FILE.tmp" && mv "$STAMP_FILE.tmp" "$STAMP_FILE"   # atomic
  log "update.php done, stamp written"
}

# Runs update.php under an exclusive lock when needed. $1: "force" (always) or "auto" (only when the
# stamp differs from the recipe). Does nothing on a fresh database (install.sh installs it).
locked_update() {
  local mode="$1"
  mkdir -p "$STATE_DIR"
  ensure_data_ownership "$STATE_DIR" "$IMAGES_DIR"
  # Serialise schema changes: a second container or `compose run wiki update` waits here. The stamp
  # is read only after taking the lock, so the loser of a race sees the winner's stamp.
  exec 9>"$STATE_DIR/lock"
  run_child flock 9     # the lock belongs to the shared file description, so it stays held after flock exits
  wait_db
  if [ "$wiki_installed" != 1 ]; then
    log "wiki not installed yet (fresh database); leaving it to scripts/install.sh"
  elif [ "$mode" = force ] || [ "$(cat "$STAMP_FILE" 2>/dev/null)" != "$RECIPE" ]; then
    run_update
  else
    log "stamp matches image recipe, no update needed"
  fi
  flock -u 9; exec 9>&-     # release; children must not inherit the lock
}

# The job queue loop. Jobs are rows in the DB; each runJobs drains a backlog (up to 1000 jobs or
# 5 minutes), then the loop sleeps JOB_RUNNER_INTERVAL seconds (default 30) and polls again.
# Exits 0 on SIGTERM, 1 when runJobs fails (the supervisor then restarts the container).
job_loop() {
  local loop_child=
  trap 'kill "$loop_child" 2>/dev/null; exit 0' TERM
  # Fresh install: wait until install.sh has created the tables
  until db_state; do sleep 10 & loop_child=$!; wait "$loop_child"; done
  while true; do
    as_www php maintenance/run.php runJobs --maxjobs 1000 --maxtime 300 & loop_child=$!
    wait "$loop_child" || { echo "runJobs exited with status $?, stopping"; exit 1; }
    sleep "${JOB_RUNNER_INTERVAL:-30}" & loop_child=$!; wait "$loop_child"
  done
}

case "${1:-}" in
  update)
    locked_update force
    exit 0 ;;
  job-loop)               # internal: started below as its own process (visible in ps as "job-loop")
    job_loop ;;
  apache2-foreground)
    locked_update auto ;;
  *)
    exec docker-php-entrypoint "$@" ;;
esac

# Supervise Apache and the job loop. If one exits, stop the other and exit 1 (restart policy).
apache_pid=; jobs_pid=; stopping=0
trap 'stopping=1; kill -TERM $apache_pid $jobs_pid 2>/dev/null || true' TERM INT
"$0" job-loop > >(sed -u 's/^/[jobs] /') 2>&1 & jobs_pid=$!
docker-php-entrypoint "$@" & apache_pid=$!
# A signal that arrived while starting found empty PIDs; forward it now
if [ "$stopping" = 1 ]; then kill -TERM "$apache_pid" "$jobs_pid" 2>/dev/null || true; fi
exit_code=0; wait -n "$apache_pid" "$jobs_pid" || exit_code=$?
if [ "$stopping" = 1 ]; then
  wait "$apache_pid" "$jobs_pid" 2>/dev/null || true
  log "stopped"; exit 0
fi
log "a child exited (status $exit_code); stopping the other so the container restarts"
kill -TERM "$apache_pid" "$jobs_pid" 2>/dev/null || true
wait "$apache_pid" "$jobs_pid" 2>/dev/null || true
exit 1
