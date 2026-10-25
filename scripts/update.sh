#!/usr/bin/env bash
# Interactive update of one wiki to another image tag; by default the version the main branch
# publishes. Patch updates within a version line come automatically through Watchtower (it follows the
# floating WIKI_TAG); this script is for version-line changes (MediaWiki or SMW minor), manual
# refreshes and pinning an immutable tag (rollback).
#
# Usage:   scripts/update.sh <name> [options]
#   --tag <tag>      target tag instead of asking (default: the floating tag of origin/main, e.g.
#                    1.46-smw7.3; an immutable tag such as 1.46.2-smw7.3.1-42 pins that build)
#   --yes            no questions: default target tag, git pull when behind, backup, continue
#   --no-backup      skip the backup (refused for a version-line change unless --force)
#   --force          allow --no-backup for a version-line change
#   --no-git-pull    do not offer `git pull --ff-only` when this clone is behind origin/main
#   -h, --help       this help
# Steps: show the current tag and the running image; fetch origin/main and work out its floating tag
# from the Dockerfile there (exactly as the CI workflow does); offer `git pull --ff-only` when this
# clone is behind; ask for the target tag and check that it exists in the registry; show what kind of
# update it is; back up (scripts/backup.sh); pull the image (or, for a plain local image name, build
# it from this checkout); set WIKI_TAG in .env (the only line changed); `docker compose up -d`; wait
# until healthy; show the entrypoint's update.php lines; run scripts/smoke.sh (only warns). On a
# failure it prints the rollback steps and changes nothing back by itself.
#
# Reads:   wikis/<name>/.env and compose.yaml; origin/main (git fetch); the registry (docker manifest)
# Writes:  backups/<name>/wiki-<ts>.tar.gz (unless declined), the WIKI_TAG line of wikis/<name>/.env,
#          the image, the running containers (the entrypoint runs update.php when the image changed);
#          with consent the clone itself (git pull --ff-only; never the wiki's own files)
# Exit:    0 when the wiki runs healthy on the target tag (a failed smoke test only warns); 1 when
#          refused or aborted before anything changed, or when a step fails (rollback steps printed)
# Example: scripts/update.sh team                      # interactive, Enter accepts every default
#          scripts/update.sh team --tag 1.46.2-smw7.3.1-42 --yes   # pin an immutable build
. "$(dirname "$0")/lib.sh"

# Bounded wait for the wiki to become healthy (update.php of a version-line change can take a while)
HEALTHY_TIMEOUT_SECONDS=900

# Prints the help (the header of this file) and exits with $1.
usage() {
  sed -n '2,/^\. /{ /^\. /d; s/^# \{0,1\}//; p; }' "$0"
  exit "${1:-0}"
}

# Asks a yes/no question. $1: question, $2: default (y or n). With --yes returns the default without
# asking. Returns 0 for yes, 1 for no.
confirm() {
  local question="$1" default_answer="$2" answer hint="[y/N]"
  [ "$default_answer" = y ] && hint="[Y/n]"
  if [ "$assume_yes" = 1 ]; then [ "$default_answer" = y ]; return; fi
  while true; do
    printf '%s %s: ' "$question" "$hint" >&2
    IFS= read -r answer || die $'\nAborted (end of input); nothing was changed.'
    case "${answer:-$default_answer}" in
      y|Y|yes|Yes) return 0 ;;
      n|N|no|No) return 1 ;;
    esac
  done
}

# Returns 0 when $1 is a valid Docker tag.
is_valid_tag() {
  [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]
}

# Reads a Dockerfile on stdin and prints the floating tag the CI workflow publishes for it:
# <MW minor>-smw<SMW minor> (MW_VERSION=1.46.2, SMW_VERSION=7.3.1 -> 1.46-smw7.3). Same derivation as
# the "meta" step in .github/workflows/build.yml. Returns 1 when an ARG is missing.
floating_tag_of_dockerfile() {
  local dockerfile_text mw_version smw_version
  dockerfile_text="$(cat)"
  mw_version="$(sed -n 's/^ARG MW_VERSION=//p' <<< "$dockerfile_text")"
  smw_version="$(sed -n 's/^ARG SMW_VERSION=//p' <<< "$dockerfile_text")"
  [ -n "$mw_version" ] && [ -n "$smw_version" ] || return 1
  echo "${mw_version%.*}-smw${smw_version%.*}"
}

# Prints the version line of tag $1, "<MW major.minor>-smw<SMW major.minor>": 1.46-smw7.3 for both
# 1.46-smw7.3 and 1.46.2-smw7.3.1-42. Tags of another form (e.g. "1.46") print themselves.
version_line_of_tag() {
  local tag="$1" mw_part smw_part
  if [[ "$tag" =~ ^([0-9]+\.[0-9]+)(\.[0-9]+)?-smw([0-9]+\.[0-9]+) ]]; then
    mw_part="${BASH_REMATCH[1]}"; smw_part="${BASH_REMATCH[3]}"
    echo "$mw_part-smw$smw_part"
  else
    echo "$tag"
  fi
}

# Prints "<version label> (<image id>)" of the running wiki container's image, or "not running".
running_image_description() {
  local container_id image_id image_version
  container_id="$("${COMPOSE[@]}" ps -q --status running wiki 2> /dev/null || true)"
  [ -n "$container_id" ] || { echo "not running"; return 0; }
  image_id="$(docker inspect -f '{{.Image}}' "$container_id")"
  image_version="$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$image_id" 2> /dev/null || true)"
  image_id="${image_id#sha256:}"
  echo "${image_version:-local build} (image ${image_id:0:12})"
}

# Sets main_tag to the floating tag of origin/main (fetched; on failure the last fetched state, or
# this checkout) and offers `git pull --ff-only` when this clone is behind. After a pull the script
# runs again from the updated file (bash reads scripts while running them).
determine_main_tag() {
  local main_ref=origin/main behind_count template_tag
  if ! GIT_TERMINAL_PROMPT=0 git -C "$REPO_ROOT" fetch --quiet origin main < /dev/null 2> /dev/null; then
    echo "WARNING: git fetch origin main failed (offline?); using the last fetched state." >&2
  fi
  if ! git -C "$REPO_ROOT" rev-parse --verify --quiet "$main_ref" > /dev/null; then
    echo "WARNING: no origin/main; using this checkout." >&2
    main_ref=HEAD
  fi
  behind_count="$(git -C "$REPO_ROOT" rev-list --count "HEAD..$main_ref")"
  if [ "$behind_count" -gt 0 ]; then
    echo "This clone is $behind_count commit(s) behind origin/main (scripts and templates; the wiki's own files are never touched)."
    if [ "$git_pull_allowed" = 1 ] && [ "$(git -C "$REPO_ROOT" symbolic-ref --short -q HEAD)" = main ] \
       && confirm "Update it with git pull --ff-only first?" y; then
      git -C "$REPO_ROOT" pull --ff-only --quiet origin main || die "git pull --ff-only failed; nothing was changed."
      echo "Updated. Running the updated update.sh."
      exec "$0" "$WIKI_NAME_ARG" ${original_args[@]+"${original_args[@]}"} --no-git-pull
    fi
  fi
  main_tag="$(git -C "$REPO_ROOT" show "$main_ref:Dockerfile" | floating_tag_of_dockerfile)" \
    || die "Cannot read MW_VERSION/SMW_VERSION from the Dockerfile on $main_ref"
  # new-wiki.sh's default comes from templates/wiki.env; CI checks that both agree
  template_tag="$(git -C "$REPO_ROOT" show "$main_ref:templates/wiki.env" | sed -n 's/^WIKI_TAG=//p')"
  [ "$template_tag" = "$main_tag" ] \
    || echo "WARNING: templates/wiki.env on $main_ref says WIKI_TAG=$template_tag; the Dockerfile publishes $main_tag (used)." >&2
}

# Returns 0 when WIKI_IMAGE:$1 exists in the registry (anonymous docker manifest inspect, or with the
# login docker already has).
tag_exists_in_registry() {
  docker manifest inspect "$WIKI_IMAGE:$1" > /dev/null 2>&1
}

# Writes .env with WIKI_TAG set to $1: only that line changes; its quotes and anything after the value
# (a comment) stay. Written to a private temp file next to it and moved over it.
set_env_tag() {
  local new_tag="$1" env_file="$WIKI_DIR/.env"
  [ "$(grep -c '^WIKI_TAG=' "$env_file")" = 1 ] || die "$env_file needs exactly one WIKI_TAG= line"
  sed -E "s/^(WIKI_TAG=['\"]?)[A-Za-z0-9_.-]*/\1$new_tag/" "$env_file" > "$env_file.partial"
  chmod 600 "$env_file.partial"
  mv "$env_file.partial" "$env_file"
}

# Prints the rollback steps (after a failure) and exits 1. $1: what failed.
fail_with_rollback() {
  echo >&2
  echo "UPDATE FAILED: $1" >&2
  echo "Nothing was rolled back automatically. To go back:" >&2
  echo "  1. set WIKI_TAG=$old_tag in wikis/$WIKI_NAME_ARG/.env (it is now: $(sed -n 's/^WIKI_TAG=//p' "$WIKI_DIR/.env"))" >&2
  if [ -n "$backup_file" ]; then
    echo "  2. scripts/restore.sh $WIKI_NAME_ARG $backup_file   (database and uploads from before the update; starts the wiki)" >&2
  else
    echo "  2. scripts/compose.sh $WIKI_NAME_ARG up -d   (no backup was made; a migrated database cannot be downgraded)" >&2
  fi
  echo "Logs: scripts/compose.sh $WIKI_NAME_ARG logs wiki" >&2
  exit 1
}

# ---- main ------------------------------------------------------------------------------------------

case "${1:-}" in -h|--help) usage 0 ;; esac
load_wiki "${1:-}"; shift
original_args=("$@")
assume_yes=0; backup_wanted=1; force=0; git_pull_allowed=1; target_tag=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --tag) [ $# -ge 2 ] || die "--tag needs a value"; target_tag="$2"; shift 2; continue ;;
    --yes) assume_yes=1 ;;
    --no-backup) backup_wanted=0 ;;
    --force) force=1 ;;
    --no-git-pull) git_pull_allowed=0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
  shift
done
old_tag="$WIKI_TAG"
backup_file=""

echo "Wiki '$WIKI_NAME_ARG': $WIKI_SERVER"
echo "  Configured  $WIKI_IMAGE:$old_tag"
echo "  Running     $(running_image_description)"

main_tag=""
determine_main_tag
echo "  origin/main publishes  $main_tag"

case "$WIKI_IMAGE" in
  */*) image_is_local=0 ;;
  *)   image_is_local=1
       echo "  $WIKI_IMAGE is a local image name: the update builds it from this checkout (its Dockerfile," \
            "currently $(floating_tag_of_dockerfile < "$REPO_ROOT/Dockerfile")); the tag is only its name." ;;
esac

if [ -z "$target_tag" ]; then
  if [ "$assume_yes" = 1 ]; then
    target_tag="$main_tag"
  else
    printf 'Target tag [%s]: ' "$main_tag" >&2
    IFS= read -r target_tag || die $'\nAborted (end of input); nothing was changed.'
    target_tag="${target_tag:-$main_tag}"
  fi
fi
is_valid_tag "$target_tag" || die "Not a valid tag: $target_tag"
if [ "$image_is_local" = 0 ]; then
  tag_exists_in_registry "$target_tag" \
    || die "$WIKI_IMAGE:$target_tag does not exist in the registry (or is not readable); nothing was changed."
fi

# What kind of update this is
old_line="$(version_line_of_tag "$old_tag")"
new_line="$(version_line_of_tag "$target_tag")"
line_change=0
echo
if [ "$target_tag" = "$old_tag" ]; then
  echo "Refresh of $WIKI_IMAGE:$old_tag: the newest build of this tag (patch level)."
  echo "The entrypoint runs update.php only if the image changed."
elif [ "$old_line" = "$new_line" ]; then
  echo "Change within version line $old_line: $old_tag -> $target_tag."
else
  line_change=1
  echo "VERSION-LINE CHANGE: $old_tag ($old_line) -> $target_tag ($new_line)."
  echo "  update.php migrates the database schema on start. Going back needs the backup (restore);"
  echo "  setting the old tag again does not downgrade the database."
  echo "  Read the release notes first: MediaWiki https://www.mediawiki.org/wiki/Release_notes and"
  echo "  Semantic MediaWiki https://www.semantic-mediawiki.org/wiki/Help:Upgrade"
fi
case "$target_tag" in
  *-r*) echo "Watchtower: $target_tag is immutable, so Watchtower holds this build." ;;
  *)    echo "Watchtower: it follows the floating tag $target_tag from now on." ;;
esac

if [ "$backup_wanted" = 0 ] && [ "$line_change" = 1 ] && [ "$force" != 1 ]; then
  die "--no-backup is refused for a version-line change (add --force to skip the backup anyway)."
fi
if [ "$backup_wanted" = 1 ] && [ "$line_change" = 0 ] && ! confirm "Back up first (scripts/backup.sh)?" y; then
  backup_wanted=0
fi
echo "Backup: $( [ "$backup_wanted" = 1 ] && echo yes || echo NO)"
confirm "Continue?" y || die "Aborted; nothing was changed."

# 1. Backup (the database must run for the dump)
if [ "$backup_wanted" = 1 ]; then
  "${COMPOSE[@]}" up -d --wait db
  backup_file="$("$REPO_ROOT/scripts/backup.sh" "$WIKI_NAME_ARG")" || die "Backup failed; nothing was changed."
  echo "Backup: $backup_file"
fi

# 2. Image first, so a failed pull or build changes nothing
WIKI_TAG="$target_tag"
ensure_image refresh || { WIKI_TAG="$old_tag"; fail_with_rollback "getting $WIKI_IMAGE:$target_tag failed (.env unchanged)"; }

# 3. .env and start
set_env_tag "$target_tag"
echo "WIKI_TAG: $old_tag -> $target_tag (in $WIKI_DIR/.env; the old value is what a rollback needs)"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
"${COMPOSE[@]}" up -d --wait --wait-timeout "$HEALTHY_TIMEOUT_SECONDS" \
  || { "${COMPOSE[@]}" logs --since "$started_at" wiki 2>&1 | grep '\[entrypoint\]' >&2 || true
       fail_with_rollback "the wiki did not become healthy within ${HEALTHY_TIMEOUT_SECONDS}s"; }
entrypoint_lines="$("${COMPOSE[@]}" logs --no-log-prefix --since "$started_at" wiki 2>&1 \
  | grep -E '\[entrypoint\] .*(update\.php|no update needed|FAILED|giving up)' || true)"
echo "${entrypoint_lines:-(no entrypoint lines about update.php in the log)}"
case "$entrypoint_lines" in *FAILED*|*"giving up"*) fail_with_rollback "the entrypoint reported a failure" ;; esac

# 4. Smoke test: a warning only, the update itself succeeded
if ! "$REPO_ROOT/scripts/smoke.sh" "$WIKI_NAME_ARG"; then
  echo "WARNING: the wiki is healthy on $target_tag, but the smoke test failed. Re-run: scripts/smoke.sh $WIKI_NAME_ARG" >&2
fi
echo
echo "Wiki '$WIKI_NAME_ARG' runs $WIKI_IMAGE:$target_tag   (was $old_tag${backup_file:+; backup $backup_file})"
echo "  Running     $(running_image_description)"
