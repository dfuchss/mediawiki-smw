#!/usr/bin/env bash
# Creates a new wiki in wikis/<name>/ and optionally installs and starts it.
#
# Usage:   scripts/new-wiki.sh [options] [name]
# Interactive by default: asks for every value, with the default in [brackets] (Enter accepts it).
# Options (each one answers its question; with --yes the rest take their defaults):
#   --name <name>          folder and compose project name: lowercase letters, digits, dashes
#   --port <port>          port on this machine the wiki is published on, http://127.0.0.1:<port>
#                          (WIKI_PORT; default: the next free one from 8081, see suggest_port). Only
#                          for direct access; behind Traefik the compose file publishes no port.
#   --server <url>         public URL, WIKI_SERVER (default: http://localhost:<port>)
#   --site-name <text>     site name (default: Wiki)
#   --admin-user <name>    first administrator (default: Admin)
#   --lang <code>          content language (default: en)
#   --timezone <zone>      e.g. Europe/Paris (default: UTC)
#   --date-format <fmt>    dmy, mdy, ymd or "ISO 8601" (default: dmy)
#   --theme <theme>        os, day or night (default: os)
#   --font <font>          roboto or default (default: roboto)
#   --storage <mode>       volumes (Docker named volumes, default) or folders (bind mounts to
#                          wikis/<name>/data/db, images and state)
#   --image <image:tag>    default: the image the GitHub Actions workflow publishes for this clone,
#                          ghcr.io/<owner>/<repo>:<tag> from the origin remote (see default_image), which
#                          is pulled; a plain name such as mediawiki-smw:1.46-smw7.3 is built from this
#                          repository instead (also the default when origin is not on GitHub)
#   --install | --no-install   install now or only write the files (default: install)
#   --refresh-image        pull or rebuild the image even if it exists locally
#   --keep-running | --stop-after-install   after install and smoke test, leave the wiki running or
#                          stop it (docker compose stop; data kept) and print the next steps (Traefik,
#                          .env, branding; also in wikis/<name>/README.md). Default: keep running when
#                          WIKI_SERVER is http(s)://localhost or 127.0.0.1 (a local wiki), else stop
#   --yes                  non-interactive: no questions, defaults for everything not given
#   -h, --help             this help
# The admin password is never an option (it would show up in ps): it is generated, typed in at the
# hidden prompt, or taken from the environment variable ADMIN_PASSWORD.
#
# Reads:   templates/wiki.env, templates/compose.yaml, templates/settings.php, templates/README.md;
#          wikis/*/.env (ports in use); docker (existing projects, images)
# Writes:  wikis/<name>/.env (mode 600, all secrets generated with openssl rand), compose.yaml,
#          settings.php, branding/, README.md; with --storage folders also the empty folders
#          data/db, data/images, data/state (mode 700; the containers take over their ownership).
#          With install: the image (pull or build), the volumes <name>_db-data, <name>_images,
#          <name>_wiki-state (storage volumes) and the running containers.
# Exit:    0 when the files are written (and, with install, the wiki is installed and healthy); 1 on
#          an invalid answer in --yes mode, on abort, or when a step fails. A failed install keeps the
#          files, so `scripts/install.sh <name>` can be retried. A failed smoke test after the install
#          only prints a warning (the wiki is installed; re-run scripts/smoke.sh <name>): CI runs
#          smoke.sh itself.
# Examples:
#   scripts/new-wiki.sh
#   ADMIN_PASSWORD=... scripts/new-wiki.sh --yes --name team --server https://wiki.example.org --no-install
. "$(dirname "$0")/lib.sh"

TEMPLATES_DIR="$REPO_ROOT/templates"
FIRST_PORT=8081
LAST_PORT=8999

# Prints the help (the header of this file) and exits with $1.
usage() {
  sed -n '2,/^\. /{ /^\. /d; s/^# \{0,1\}//; p; }' "$0"
  exit "${1:-0}"
}

# ---- answers ---------------------------------------------------------------------------------------

# Prints $1 as a .env value that bash (lib.sh sources the file) and docker compose both read
# literally: bare when it has only safe characters, else in single quotes, else (it contains a single
# quote) in double quotes. Returns 1 when no quoting is safe (both quote kinds, or $ \ ` with a ').
quote_env_value() {
  local value="$1"
  if [[ "$value" =~ ^[A-Za-z0-9._:/@+-]*$ ]]; then
    printf '%s' "$value"
  elif [[ "$value" != *"'"* ]]; then
    printf "'%s'" "$value"
  elif [[ "$value" != *[\"\$\\\`]* ]]; then
    printf '"%s"' "$value"
  else
    return 1
  fi
}

# Prints the WIKI_PORT values of all existing wikis, one per line.
ports_of_existing_wikis() {
  local env_file
  for env_file in "$WIKIS_DIR"/*/.env; do
    [ -f "$env_file" ] || continue
    sed -n "s/^WIKI_PORT=//p" "$env_file" | tr -d "'\""
  done
}

# Returns 0 when something accepts connections on 127.0.0.1:$1 (bash's /dev/tcp, no extra tools).
port_is_listening() {
  local port="$1"
  (exec 3<>"/dev/tcp/127.0.0.1/$port") 2> /dev/null
}

# Prints the first port from FIRST_PORT up that no wiki's .env uses and nothing listens on.
# Returns 1 when all ports up to LAST_PORT are taken.
suggest_port() {
  local port taken_ports
  taken_ports=" $(ports_of_existing_wikis | tr '\n' ' ') "
  for port in $(seq "$FIRST_PORT" "$LAST_PORT"); do
    [[ "$taken_ports" == *" $port "* ]] && continue
    port_is_listening "$port" && continue
    echo "$port"; return 0
  done
  return 1
}

# Each validate_* function checks one answer ($1). Returns 0 when it is valid; otherwise prints the
# reason to stderr and returns 1.

validate_name() {
  local candidate="$1" docker_objects
  is_valid_wiki_name "$candidate" \
    || { echo "  Use lowercase letters, digits and dashes (max. 40), starting with a letter or digit." >&2; return 1; }
  [ ! -e "$WIKIS_DIR/$candidate" ] || { echo "  wikis/$candidate already exists." >&2; return 1; }
  # Volumes or containers of a compose project with this name (e.g. an older setup) would be reused
  # and their data mixed with the new wiki. Skipped when docker is not reachable.
  docker_objects="$( { docker volume ls -q --filter "label=com.docker.compose.project=$candidate"
                       docker ps -aq --filter "label=com.docker.compose.project=$candidate"; } 2> /dev/null || true)"
  [ -z "$docker_objects" ] \
    || { echo "  Docker already has volumes or containers of a project named '$candidate'; choose another name." >&2; return 1; }
}

validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] \
    || { echo "  Not a port number." >&2; return 1; }
  ! ports_of_existing_wikis | grep -qx "$port" || { echo "  Another wiki already uses port $port." >&2; return 1; }
  ! port_is_listening "$port" || { echo "  Port $port is in use." >&2; return 1; }
}

validate_url() {
  [[ "$1" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] \
    || { echo "  Use http(s)://host[:port], without a path or trailing slash." >&2; return 1; }
}

validate_text() {
  [ -n "$1" ] && [ "${#1}" -le 100 ] || { echo "  Enter 1 to 100 characters." >&2; return 1; }
  quote_env_value "$1" > /dev/null || { echo "  Do not combine ' with \", \$, \\ or \` ." >&2; return 1; }
}

validate_admin_user() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9\ ._-]{0,39}$ ]] \
    || { echo "  Letters, digits, spaces, . _ - (max. 40), starting with a letter or digit." >&2; return 1; }
}

validate_lang() {
  [[ "$1" =~ ^[a-z]{2,3}(-[a-z0-9]+)*$ ]] || { echo "  A language code such as en, de or pt-br." >&2; return 1; }
}

validate_timezone() {
  [[ "$1" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]] || { echo "  A zone such as UTC or Europe/Paris." >&2; return 1; }
  # Check against the host's zone database when it has one
  if [ -d /usr/share/zoneinfo ] && [ ! -f "/usr/share/zoneinfo/$1" ]; then
    echo "  Unknown time zone '$1'." >&2; return 1
  fi
}

validate_date_format() {
  case "$1" in dmy|mdy|ymd|"ISO 8601") return 0 ;; esac
  echo "  One of: dmy, mdy, ymd, ISO 8601." >&2; return 1
}

validate_theme() {
  case "$1" in os|day|night) return 0 ;; esac
  echo "  One of: os, day, night." >&2; return 1
}

validate_font() {
  case "$1" in roboto|default) return 0 ;; esac
  echo "  One of: roboto, default." >&2; return 1
}

validate_storage() {
  case "$1" in volumes|folders) return 0 ;; esac
  echo "  One of: volumes, folders." >&2; return 1
}

validate_image() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9._/:-]*:[A-Za-z0-9._-]+$ ]] && [[ "${1##*/}" == *:* ]] \
    || { echo "  Use <image>:<tag>, e.g. mediawiki-smw:1.46-smw7.3 or ghcr.io/<owner>/<repo>:1.46-smw7.3." >&2; return 1; }
}

validate_password() {
  [ "${#1}" -ge 10 ] || { echo "  At least 10 characters (MediaWiki's minimum for administrators)." >&2; return 1; }
  quote_env_value "$1" > /dev/null || { echo "  Do not combine ' with \", \$, \\ or \` ." >&2; return 1; }
}

# Sets the variable named $1 to an answer. $2: question, $3: default, $4: validator function,
# $5: value given as an option (skips the question). In --yes mode the default is taken without
# asking. Loops until the answer is valid; exits 1 on an invalid option/default in --yes mode or at
# the end of input.
ask() {
  local target_var="$1" question="$2" default_value="$3" validator="$4" given_value="${5:-}" answer
  if [ -n "$given_value" ] || [ "$assume_yes" = 1 ]; then
    answer="${given_value:-$default_value}"
    "$validator" "$answer" || die "Invalid value for '$question': $answer"
    [ "$assume_yes" = 1 ] || printf '%s: %s\n' "$question" "$answer" >&2
    printf -v "$target_var" '%s' "$answer"
    return 0
  fi
  while true; do
    # Prompt on stderr, so it also shows when stdout is redirected
    if [ -n "$default_value" ]; then printf '%s [%s]: ' "$question" "$default_value" >&2
    else printf '%s: ' "$question" >&2; fi
    IFS= read -r answer || die $'\nAborted (end of input); nothing was created.'
    answer="${answer:-$default_value}"
    if "$validator" "$answer"; then printf -v "$target_var" '%s' "$answer"; return 0; fi
  done
}

# Asks a yes/no question. $1: question, $2: default (y or n). In --yes mode returns the default
# without asking. Returns 0 for yes, 1 for no.
confirm() {
  local question="$1" default_answer="$2" answer hint="[y/N]"
  [ "$default_answer" = y ] && hint="[Y/n]"
  if [ "$assume_yes" = 1 ]; then [ "$default_answer" = y ]; return; fi
  while true; do
    printf '%s %s: ' "$question" "$hint" >&2
    IFS= read -r answer || die $'\nAborted (end of input).'
    case "${answer:-$default_answer}" in
      y|Y|yes|Yes) return 0 ;;
      n|N|no|No) return 1 ;;
    esac
  done
}

# Sets admin_password and password_origin (generated, entered, environment). Entered passwords are
# read without echo and twice.
choose_admin_password() {
  local first_entry second_entry
  if [ -n "${ADMIN_PASSWORD:-}" ]; then
    validate_password "$ADMIN_PASSWORD" || die "ADMIN_PASSWORD from the environment is not usable"
    admin_password="$ADMIN_PASSWORD"; password_origin=environment; return 0
  fi
  if [ "$assume_yes" != 1 ]; then
    while true; do
      printf 'Admin password (Enter = generate one): ' >&2
      IFS= read -r -s first_entry || die $'\nAborted (end of input); nothing was created.'
      echo >&2
      [ -n "$first_entry" ] || break
      validate_password "$first_entry" || continue
      printf 'Repeat the password: ' >&2
      IFS= read -r -s second_entry || die $'\nAborted (end of input); nothing was created.'
      echo >&2
      if [ "$first_entry" = "$second_entry" ]; then
        admin_password="$first_entry"; password_origin=entered; return 0
      fi
      echo "  The passwords differ." >&2
    done
  fi
  admin_password="$(openssl rand -hex 12)"; password_origin=generated
}

# ---- files -----------------------------------------------------------------------------------------

# Prints the default image reference. When this clone's origin remote is on GitHub, that is the image
# the workflow publishes: ghcr.io/<owner>/<repo> (lowercase, as GHCR requires) with the floating tag
# from templates/wiki.env. Otherwise the local build name from templates/wiki.env.
default_image() {
  local template_image template_tag origin_url owner_and_repo
  template_image="$(sed -n 's/^WIKI_IMAGE=//p' "$TEMPLATES_DIR/wiki.env")"
  template_tag="$(sed -n 's/^WIKI_TAG=//p' "$TEMPLATES_DIR/wiki.env")"
  origin_url="$(git -C "$REPO_ROOT" remote get-url origin 2> /dev/null || true)"
  # git@github.com:owner/repo.git, https://github.com/owner/repo(.git), ssh://git@github.com/owner/repo
  owner_and_repo="$(printf '%s\n' "$origin_url" | sed -n 's#^.*github\.com[:/]\([^/]*/[^/]*\)$#\1#p')"
  owner_and_repo="${owner_and_repo%.git}"
  if [ -n "$owner_and_repo" ]; then
    echo "ghcr.io/$(printf '%s' "$owner_and_repo" | tr '[:upper:]' '[:lower:]'):$template_tag"
  else
    echo "$template_image:$template_tag"
  fi
}

# Writes the compose file $2 from the template $1 for the data storage $3 (volumes or folders). The
# template uses named volumes; for folders the three mounts are rewritten to relative bind mounts
# and the top-level volumes block is replaced by a comment that says how to switch back. Exits 1 when
# the template no longer has the lines this expects.
write_compose_file() {
  local template_file="$1" target_file="$2" storage_mode="$3"
  if [ "$storage_mode" = volumes ]; then
    cp "$template_file" "$target_file"
    return 0
  fi
  sed -e 's|^\( *- \)db-data:/var/lib/mysql|\1./data/db:/var/lib/mysql|' \
      -e 's|^\( *- \)images:/var/www/html/images|\1./data/images:/var/www/html/images|' \
      -e 's|^\( *- \)wiki-state:/var/lib/wiki-state|\1./data/state:/var/lib/wiki-state|' \
      -e 's|data storage: see the end of this file|data storage: folders, see the end of this file|' \
      -e '/^# Data storage: /,$d' "$template_file" > "$target_file"
  cat >> "$target_file" <<'EOF'
# Data storage: folders (chosen when the wiki was created). Database, uploads and update stamp live in
# ./data/db, ./data/images and ./data/state next to this file, so everything about this wiki is in one
# folder. Docker creates no volumes for them. The containers set the owners (MySQL: uid 999, wiki:
# www-data, uid 33), so on Linux you need root to read or delete them. Copy ./data/db only while the
# database is stopped (`docker compose down`), or use scripts/backup.sh, which dumps it consistently.
# To switch to Docker named volumes: replace the three ./data/... mounts above with
#   db-data:/var/lib/mysql      images:/var/www/html/images      wiki-state:/var/lib/wiki-state
# and add at the end of this file
#   volumes:
#     db-data:
#     images:
#     wiki-state:
# then move the data over with scripts/backup.sh and scripts/restore.sh.
EOF
  [ "$(grep -c '^ *- \./data/' "$target_file")" = 3 ] || die "templates/compose.yaml lacks the three data mounts"
  ! grep -q '^ *- \(db-data\|images\|wiki-state\):' "$target_file" || die "templates/compose.yaml: a named volume mount was not rewritten"
}

# Writes the README $2 of the wiki from the template $1: @NAME@ becomes the wiki name, and the line
# "@STORAGE@" the paragraph that describes the data storage $3 (volumes or folders).
write_readme_file() {
  local template_file="$1" target_file="$2" storage_mode="$3" line
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "@STORAGE@" ]; then
      if [ "$storage_mode" = folders ]; then
        printf '%s\n' \
          "Data storage: **folders**. \`data/db\` (MySQL), \`data/images\` (uploads) and \`data/state\` (update" \
          "stamp) hold all data of this wiki. The containers own them (MySQL uid 999, the wiki www-data, uid 33), so" \
          "reading or deleting them on Linux needs root. Copy \`data/db\` only while the database is stopped" \
          "(\`docker compose down\`), or use \`scripts/backup.sh @NAME@\`. See the end of \`compose.yaml\` for how to switch to volumes."
      else
        printf '%s\n' \
          "Data storage: **Docker volumes** \`@NAME@_db-data\`, \`@NAME@_images\` and \`@NAME@_wiki-state\`, managed by" \
          "Docker (\`docker volume ls\`). Use \`scripts/backup.sh @NAME@\` for backups. See the end of \`compose.yaml\` for how to" \
          "switch to folders next to this file."
      fi
    else
      printf '%s\n' "$line"
    fi
  done < "$template_file" | sed "s/@NAME@/$wiki_name/g" > "$target_file"
}

# Writes the .env file $2 from the template $1: every "KEY=..." line whose KEY has a value in
# setting_<KEY> (see set_setting) gets that value, quoted; everything else (comments, other
# defaults) is copied. Exits 1 when a set value has no line in the template.
write_env_file() {
  local template_file="$1" target_file="$2" line setting_name value_var setting_key
  while IFS= read -r line || [ -n "$line" ]; do
    setting_name="${line%%=*}"
    if [[ "$line" =~ ^[A-Z_][A-Z0-9_]*= ]] && [[ " $SET_SETTINGS " == *" $setting_name "* ]]; then
      value_var="setting_$setting_name"
      printf '%s=%s\n' "$setting_name" "$(quote_env_value "${!value_var}")"
    else
      printf '%s\n' "$line"
    fi
  done < "$template_file" > "$target_file"
  for setting_key in $SET_SETTINGS; do
    [ "$(grep -c "^$setting_key=" "$target_file")" = 1 ] || die "templates/wiki.env lacks exactly one $setting_key= line"
  done
}

# Names of the settings recorded by set_setting, space-separated
SET_SETTINGS=""

# Records value $2 for the .env setting $1 (written by write_env_file).
set_setting() {
  printf -v "setting_$1" '%s' "$2"
  SET_SETTINGS="$SET_SETTINGS $1"
}

# Returns 0 when the URL $1 points to this machine (http(s)://localhost or 127.0.0.1, any port): a
# local wiki, reached through its published port, that needs no Traefik.
is_local_url() {
  [[ "$1" =~ ^https?://(localhost|127\.0\.0\.1)(:[0-9]+)?$ ]]
}

# Prints the next steps for production: the "Next steps" section of the wiki's README.md $1, without
# its heading and the following one.
print_next_steps() {
  sed -n '/^## Next steps/,/^## /{ /^## /d; p; }' "$1"
}

# ---- main ------------------------------------------------------------------------------------------

assume_yes=0; install_choice=""; refresh_image=0; after_install=""
opt_name=""; opt_port=""; opt_server=""; opt_site_name=""; opt_admin_user=""; opt_lang=""
opt_timezone=""; opt_date_format=""; opt_theme=""; opt_font=""; opt_image=""; opt_storage=""
# The answers, set by ask
wiki_name=""; wiki_port=""; wiki_server=""; site_name=""; admin_user=""; wiki_lang=""
wiki_timezone=""; date_format=""; default_theme=""; wiki_font=""; image_ref=""; storage_mode=""
admin_password=""; password_origin=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --yes) assume_yes=1; shift; continue ;;
    --install) install_choice=yes; shift; continue ;;
    --no-install) install_choice=no; shift; continue ;;
    --refresh-image) refresh_image=1; shift; continue ;;
    --keep-running) after_install=keep; shift; continue ;;
    --stop-after-install) after_install=stop; shift; continue ;;
    --name|--port|--server|--site-name|--admin-user|--lang|--timezone|--date-format|--theme|--font|--image|--storage)
      [ $# -ge 2 ] || die "$1 needs a value"
      case "$1" in
        --name) opt_name="$2" ;;          --port) opt_port="$2" ;;
        --server) opt_server="$2" ;;      --site-name) opt_site_name="$2" ;;
        --admin-user) opt_admin_user="$2" ;; --lang) opt_lang="$2" ;;
        --timezone) opt_timezone="$2" ;;  --date-format) opt_date_format="$2" ;;
        --theme) opt_theme="$2" ;;        --font) opt_font="$2" ;;
        --image) opt_image="$2" ;;        --storage) opt_storage="$2" ;;
      esac
      shift 2 ;;
    -*) echo "Unknown option: $1" >&2; usage 1 ;;
    *) [ -z "$opt_name" ] || die "Only one wiki name, please"; opt_name="$1"; shift ;;
  esac
done
command -v openssl > /dev/null || die "openssl is needed to generate the secrets"
[ "$assume_yes" != 1 ] || [ -n "$opt_name" ] || die "--yes needs a wiki name (--name <name>)"

[ "$assume_yes" = 1 ] || echo "New wiki. Enter accepts the default in [brackets]; Ctrl-C aborts (nothing is written before the summary)." >&2
ask wiki_name "Wiki name (folder wikis/<name>, compose project)" "" validate_name "$opt_name"
suggested_port="$(suggest_port)" || die "No free port between $FIRST_PORT and $LAST_PORT"
ask wiki_port "Port on this machine (wiki at http://127.0.0.1:<port>; not used behind Traefik)" "$suggested_port" validate_port "$opt_port"
ask wiki_server "Public URL (WIKI_SERVER)" "http://localhost:$wiki_port" validate_url "$opt_server"
ask site_name "Site name" "Wiki" validate_text "$opt_site_name"
ask admin_user "Admin user name" "Admin" validate_admin_user "$opt_admin_user"
choose_admin_password
ask wiki_lang "Content language" "en" validate_lang "$opt_lang"
ask wiki_timezone "Time zone" "UTC" validate_timezone "$opt_timezone"
ask date_format "Date format (dmy, mdy, ymd, ISO 8601)" "dmy" validate_date_format "$opt_date_format"
ask default_theme "Default theme (os, day, night)" "os" validate_theme "$opt_theme"
ask wiki_font "Font (roboto, default)" "roboto" validate_font "$opt_font"
ask image_ref "Image (ghcr.io/... is pulled; a plain name such as mediawiki-smw:<tag> is built from this repository)" "$(default_image)" validate_image "$opt_image"
ask storage_mode "Data storage: volumes (Docker-managed) or folders (wikis/$wiki_name/data/...)" "volumes" validate_storage "$opt_storage"

# Split at the last ":" (the tag; validate_image made sure it comes after the last "/")
WIKI_IMAGE="${image_ref%:*}"
WIKI_TAG="${image_ref##*:}"
wiki_host="${wiki_server#*://}"; wiki_host="${wiki_host%%:*}"
if [ -z "$after_install" ]; then
  if is_local_url "$wiki_server"; then after_install=keep; else after_install=stop; fi
fi

# 1. Settings; the secrets come from openssl rand (hex, so they never need quoting)
set_setting COMPOSE_PROJECT_NAME "$wiki_name"
set_setting WIKI_SERVER "$wiki_server"
set_setting WIKI_HOST "$wiki_host"
set_setting WIKI_NAME "$site_name"
set_setting WIKI_LANG "$wiki_lang"
set_setting WIKI_TIMEZONE "$wiki_timezone"
set_setting WIKI_DATE_FORMAT "$date_format"
set_setting WIKI_DEFAULT_THEME "$default_theme"
set_setting WIKI_FONT "$wiki_font"
set_setting WIKI_IMAGE "$WIKI_IMAGE"
set_setting WIKI_TAG "$WIKI_TAG"
set_setting WIKI_PORT "$wiki_port"
set_setting DB_PASSWORD "$(openssl rand -hex 16)"
set_setting DB_ROOT_PASSWORD "$(openssl rand -hex 16)"
set_setting WIKI_SECRET_KEY "$(openssl rand -hex 32)"
set_setting WIKI_UPGRADE_KEY "$(openssl rand -hex 8)"
set_setting WIKI_OATH_KEY "$(openssl rand -hex 32)"   # 64 hex characters, as OATHAuth expects
set_setting ADMIN_USER "$admin_user"
set_setting ADMIN_PASSWORD "$admin_password"

# 2. Files. A failure before the end removes the half-written folder again.
wiki_dir="$WIKIS_DIR/$wiki_name"
files_complete=0
trap '[ "$files_complete" = 1 ] || rm -rf "$wiki_dir"' EXIT
mkdir -p "$WIKIS_DIR"
mkdir "$wiki_dir"   # mode 700 (umask in lib.sh): the folder holds the secrets
write_env_file "$TEMPLATES_DIR/wiki.env" "$wiki_dir/.env.partial"
chmod 600 "$wiki_dir/.env.partial"
mv "$wiki_dir/.env.partial" "$wiki_dir/.env"
write_compose_file "$TEMPLATES_DIR/compose.yaml" "$wiki_dir/compose.yaml" "$storage_mode"
write_readme_file "$TEMPLATES_DIR/README.md" "$wiki_dir/README.md" "$storage_mode"
# branding/ and settings.php are bind-mounted: www-data in the container must be able to read them
mkdir "$wiki_dir/branding"
chmod 755 "$wiki_dir/branding"
cp "$TEMPLATES_DIR/settings.php" "$wiki_dir/settings.php"
# Data folders: mode 700 (umask in lib.sh), like the wiki folder. The Docker daemon runs as root (also
# in Docker Desktop's VM), so it can mount them whoever owns them; the containers start as root and
# take over: MySQL's entrypoint chowns its datadir, the wiki's entrypoint the uploads and the state.
if [ "$storage_mode" = folders ]; then
  mkdir -p "$wiki_dir/data/db" "$wiki_dir/data/images" "$wiki_dir/data/state"
fi
chmod 644 "$wiki_dir/settings.php" "$wiki_dir/compose.yaml" "$wiki_dir/README.md"
files_complete=1

if [ "$storage_mode" = folders ]; then
  storage_description="folders: wikis/$wiki_name/data/{db,images,state}"
  data_line="  data/           db, images, state: the data of the wiki"
else
  storage_description="volumes: Docker volumes ${wiki_name}_db-data, ${wiki_name}_images, ${wiki_name}_wiki-state"
  data_line=""
fi
case "$WIKI_IMAGE" in */*) image_action="pulled from its registry" ;; *) image_action="built from $REPO_ROOT" ;; esac
cat <<EOF

Created wikis/$wiki_name:
  .env            settings and generated secrets (mode 600)
  compose.yaml    db + wiki; Traefik block commented out (see README.md there for production)
${data_line:+$data_line
}  settings.php    extra MediaWiki settings (empty)
  branding/       logo, favicon, branding.css (empty)
  README.md       what to edit for production

  URL         $wiki_server   (port $wiki_port on 127.0.0.1)
  Site name   $site_name
  Admin       $admin_user   (password $password_origin; ADMIN_PASSWORD in .env)
  Locale      $wiki_lang, $wiki_timezone, $date_format; theme $default_theme; font $wiki_font
  Image       $WIKI_IMAGE:$WIKI_TAG   ($image_action if missing)
  Storage     $storage_description
  Afterwards  $( [ "$after_install" = keep ] && echo "keep running" || echo "stop; then set up Traefik (next steps in README.md)")
EOF

# 3. Install now?
if [ -z "$install_choice" ]; then
  if confirm $'\nInstall now (get the image, install, start, smoke test)?' y; then install_choice=yes; else install_choice=no; fi
fi
if [ "$install_choice" != yes ]; then
  echo
  echo "Not installed. Later: scripts/install.sh $wiki_name && scripts/smoke.sh $wiki_name"
  echo "(or, to move an existing wiki here, set WIKI_OATH_KEY and WIKI_SECRET_KEY in .env from the old"
  echo " wiki, then: scripts/restore.sh $wiki_name <backup.tar.gz>)"
  exit 0
fi

if [ "$refresh_image" != 1 ] && docker image inspect "$WIKI_IMAGE:$WIKI_TAG" > /dev/null 2>&1; then
  confirm "Image $WIKI_IMAGE:$WIKI_TAG exists locally. Pull or rebuild it anyway?" n && refresh_image=1
fi
if [ "$refresh_image" = 1 ]; then ensure_image refresh; else ensure_image; fi
"$REPO_ROOT/scripts/install.sh" "$wiki_name"
# The smoke test talks to the container and should pass, but a failure must not hide that the wiki is
# installed: warn, and go on (CI runs smoke.sh itself)
if ! "$REPO_ROOT/scripts/smoke.sh" "$wiki_name"; then
  echo >&2
  echo "WARNING: the wiki is installed, but the smoke test failed (see SMOKE FAIL above)." >&2
  echo "  Re-run it later:  scripts/smoke.sh $wiki_name" >&2
  echo "  Wiki logs:        scripts/compose.sh $wiki_name logs wiki" >&2
fi

echo
if [ "$after_install" = keep ]; then
  echo "Wiki '$wiki_name' is running: $wiki_server"
else
  # stop, not down: containers and data stay, `up -d` brings the wiki back as it is
  "$REPO_ROOT/scripts/compose.sh" "$wiki_name" stop
  echo
  echo "Wiki '$wiki_name' is installed and stopped (data kept). It will be at: $wiki_server"
  echo "Next steps (also in wikis/$wiki_name/README.md):"
  print_next_steps "$wiki_dir/README.md"
fi
echo "  Log in as:  $admin_user"
if [ "$password_origin" = generated ]; then
  echo "  Password:   $admin_password   (generated; also ADMIN_PASSWORD in wikis/$wiki_name/.env)"
else
  echo "  Password:   the one you $( [ "$password_origin" = entered ] && echo entered || echo passed in ADMIN_PASSWORD) (also ADMIN_PASSWORD in wikis/$wiki_name/.env)"
fi
echo "  Manage:     cd wikis/$wiki_name && docker compose ps   (or scripts/compose.sh $wiki_name ps)"
