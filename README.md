# MediaWiki + Semantic MediaWiki on Docker Compose

A reusable stack for private wikis: MediaWiki 1.46, Semantic MediaWiki 7.3, SemanticResultFormats, PageForms, HeaderTabs, CodeMirror, VisualEditor (switchable per wiki), optional two-factor authentication (OATHAuth with passkeys) and MySQL 8.4. Two containers per wiki (`db`, `wiki`). Wikis are private: login required to read, no self-registration, no mail unless SMTP is configured.

The image contains the extensions, the MediaWiki configuration (`config/`), a self-hosted Roboto font and an entrypoint that runs `update.php` once per new image or configuration (under a lock), then supervises Apache and the job queue loop. It contains no wiki-specific settings, branding or data.

Hardening built in:

- Uploads are served only through `img_auth.php`, which checks read rights; Apache denies `/images` itself. Anonymous users get 403 for files, old versions and thumbnails; deleted files are never served.
- Apache serves no server-side or version-revealing files (`/vendor`, `/maintenance`, `/tests`, `/docs`, `/cache`, `/mw-config`, `composer.*`, READMEs, release notes, extension manifests, dotfiles) and sends no version headers.
- Each container gets only the variables it needs: the wiki never sees `DB_ROOT_PASSWORD` or `ADMIN_*`.
- The port is published on `127.0.0.1` unless `WIKI_BIND` says otherwise, and `X-Forwarded-For` is trusted only from `WIKI_TRUSTED_PROXIES` (for MediaWiki and for the Apache access log alike).
- The entrypoint handles `SIGTERM` in every phase, so `docker stop` takes about a second.

## Layout

Clone the repository once per machine. Wikis and backups live inside the clone and are ignored by git (and by the Docker build context):

    wikis/<name>/
      .env            settings and secrets (mode 600)
      compose.yaml    both containers; standalone, yours to edit
      data/           only with --storage folders: db/ (MySQL), images/ (uploads), state/ (update stamp)
      branding/       optional: wordmark.svg, icon.svg, favicon.svg|png|ico, apple-touch-icon.png, branding.css
      settings.php    optional extra MediaWiki settings, included last (must exist, may stay empty)
      README.md       what to edit for production
    backups/<name>/wiki-<timestamp>.tar.gz

`<name>` is the folder name and the compose project name (with the default storage it also names the volumes `<name>_db-data`, `<name>_images`, `<name>_wiki-state`). A wiki folder is self-contained: run plain `docker compose` inside it, or copy it alone to a server.

`templates/` holds what `new-wiki.sh` copies. Updating the repository never touches existing wikis: their `compose.yaml` stays as generated. After an update, compare it with `templates/compose.yaml` and merge changes by hand if you want them. Configuration changes (`config/`) reach a wiki with the next image.

## Create a wiki

    scripts/new-wiki.sh

It asks for the name, the port on this machine the wiki is published on (`http://127.0.0.1:<port>`, the next free one from 8081, since 8080 is often taken; only for direct access, not used behind Traefik), the public URL, site name, admin user and password (generated unless you type one), language, time zone, date format, default theme, font, visual editor, image and data storage, with defaults in brackets. It generates all secrets with `openssl rand`, writes the folder above, shows a summary and asks whether to install now: get the image (the default is the image this repository's workflow publishes, `ghcr.io/<owner>/<repo>:1.46-smw7.3` derived from the clone's GitHub `origin`, which is pulled; a plain name such as `mediawiki-smw:1.46-smw7.3` is built from this repository instead and is also the default when `origin` is not on GitHub), install, start, wait until healthy, and run the smoke test.

After the install, a wiki with a public URL (anything but `http(s)://localhost` or `127.0.0.1`) is stopped again (`docker compose stop`; data kept), since it still needs the Traefik block in its `compose.yaml`, `TRAEFIK_CERTRESOLVER` and `WIKI_TRUSTED_PROXIES` in `.env`, and its branding. `new-wiki.sh` prints these next steps, and the wiki's `README.md` lists them; then start it with `docker compose up -d` in its folder. A localhost wiki keeps running. `--keep-running` and `--stop-after-install` override the default. A failed smoke test only prints a warning: the wiki is installed either way.

Non-interactive (CI, scripts): every answer has an option, `--yes` takes defaults for the rest, and the admin password comes from `ADMIN_PASSWORD` in the environment or is generated:

    scripts/new-wiki.sh --yes --name team --server https://wiki.example.org --site-name "Team Wiki" \
      --image ghcr.io/<owner>/<repo>:1.46-smw7.3 --no-install

`scripts/new-wiki.sh --help` lists all options.

### Data storage

`--storage volumes|folders` (asked interactively, default `volumes`) decides where database, uploads and update stamp live:

- `volumes`: Docker named volumes `<name>_db-data`, `<name>_images`, `<name>_wiki-state`. Docker manages them; they are the faster choice on Docker Desktop for macOS, but hidden under `/var/lib/docker`.
- `folders`: bind mounts to `wikis/<name>/data/db`, `data/images` and `data/state`, so everything about a wiki is in one visible folder that file-level backups and `rsync` can include. Copy `data/db` only while the database is stopped (`docker compose down`), or use `scripts/backup.sh`, which dumps it consistently. The containers own these folders (MySQL uid 999, the wiki `www-data`, uid 33): on Linux you need root to read or delete them.

Ownership is handled automatically: MySQL's official entrypoint chowns its data directory when it starts as root, and this image's entrypoint hands `images` and `state` to `www-data` at startup if the top-level owner is wrong (it never walks the upload tree; `restore.sh` chowns recursively after unpacking). `new-wiki.sh` creates the folders with mode 700. The generated `compose.yaml` explains at its end how to switch modes; move data between them with `backup.sh` and `restore.sh`.

## Scripts

All take the wiki name first.

| Script | Does |
|---|---|
| `scripts/new-wiki.sh [options] [name]` | Create `wikis/<name>/`, optionally install it |
| `scripts/install.sh <name>` | First install: database, admin account, `update.php`, start, wait until healthy |
| `scripts/compose.sh <name> <args...>` | `docker compose` for that wiki, from anywhere (`ps`, `logs -f wiki`, `pull`, `up -d`) |
| `scripts/smoke.sh <name>` | Diagnostic, read-only: login page, private API, admin login, SMW. Runs curl inside the wiki container, so it needs no Traefik, DNS, TLS or published port (and does not test the public route); every request has a timeout, the wait for the wiki at most 2 minutes |
| `scripts/backup.sh <name>` | `backups/<name>/wiki-<timestamp>.tar.gz` |
| `scripts/restore.sh <name> [--yes] <archive>` | Replace database and uploads from a backup |
| `scripts/update.sh <name> [--tag <tag>] [--yes]` | Update to the version on `main` (or any tag): backup, pull, start, health and smoke check |
| `scripts/list-wikis.sh` | Name, URL, published port (`-` behind Traefik), storage mode and state of all wikis |

The scripts stop with a clear message when a required setting is missing, run with `umask 077`, never put passwords on command lines, and start one-off containers with `traefik.enable=false` so Traefik never routes to them.

## Settings

Logos and icons go into `branding/` (served at `/branding/...` without login), never as wiki uploads referenced in `$wgLogos`/`$wgFavicon`: uploads need a login and would be missing on the login page.

The settings are in the wiki's `.env` (commented; template `templates/wiki.env`): URL, name, language, time zone, date format, theme, font, visual editor (`WIKI_VISUAL_EDITOR`), image and tag, port and bind address, DB and secret keys, admin account, job loop interval, SMTP, Traefik values, trusted proxies. Apply changes with `docker compose up -d`. Anything else goes into `settings.php`; a change there runs `update.php` once on the next start, because it is part of the update stamp.

Page URLs are short, `/wiki/<page>` (Apache hands `/wiki/...` to `index.php`, which checks read rights as for every request). `/index.php/<page>` and `/index.php?title=<page>` keep working, so older links do not break. To switch back to `/index.php/<page>` URLs, set `WIKI_ARTICLE_PATH=/index.php` in `.env` (a wiki folder created before this setting existed also needs `WIKI_ARTICLE_PATH: ${WIKI_ARTICLE_PATH:-/wiki}` in the wiki's `environment:` in `compose.yaml`) and run `docker compose up -d`.

### Visual editor

VisualEditor (bundled with MediaWiki, with Parsoid in core) is on by default: pages show two tabs, "Edit" (visual, `?veaction=edit`) and "Edit source" (wikitext, `?action=edit`), in the main, user, `Wiki:` (project) and help namespaces (plus File and Category). Parsoid runs inside the PHP request, so there is no extra service; the editor talks to `api.php` with the user's session cookie, which is why it works on the private wiki (anonymous requests get `readapidenied`). Semantic MediaWiki annotations such as `[[Has x::y]]` survive a round trip. Not included: PageForms form fields cannot use the visual editor without the separate VEForAll extension.

`new-wiki.sh --visual-editor on|off` (or the question) writes `WIKI_VISUAL_EDITOR` to `.env`. An empty or missing value means on, so existing wikis get the editor with the new image without changes. To turn it off for an existing wiki, add `WIKI_VISUAL_EDITOR: ${WIKI_VISUAL_EDITOR:-on}` to the `environment:` of the `wiki` service in its `compose.yaml`, set `WIKI_VISUAL_EDITOR=off` in `.env` and run `docker compose up -d`.

## Production

On the server, either clone the repository and create the wiki there with `new-wiki.sh`, or copy a wiki folder (it needs nothing else at runtime; for backups the scripts need the clone). Then edit:

1. `compose.yaml`: comment out `ports:` and enable the commented Traefik block (labels, the external network); the comments there list the steps.
2. `.env`: `WIKI_SERVER=https://<host>` (forces HTTPS and secure cookies), `WIKI_HOST=<host>`, `TRAEFIK_CERTRESOLVER`, and `TRAEFIK_NETWORK` (default `web`) and `TRAEFIK_ENTRYPOINT` (default `websecure`) if yours differ.
3. `.env`: `WIKI_TRUSTED_PROXIES` to the Traefik network's subnet or `private` (10/8, 172.16/12, 192.168/16). Find the subnet with `docker network inspect web --format '{{(index .IPAM.Config 0).Subnet}}'` (use your `TRAEFIK_NETWORK`'s name). The setting affects both MediaWiki (client IPs in RecentChanges, blocks, throttles) and the Apache access log (`docker compose logs wiki`), which otherwise shows only Traefik's IP. Entries are IPs/CIDRs separated by spaces or commas; an invalid entry stops the container with an error. Empty (the default) trusts no proxy, so a forged `X-Forwarded-For` is ignored.
4. `.env`: `WIKI_IMAGE=ghcr.io/<owner>/<repo>` with the floating `WIKI_TAG=1.46-smw7.3`.
5. `docker compose pull && docker compose up -d`, then schedule `scripts/backup.sh <name>` nightly with off-site copies.

## Updating

- The CI workflow (`.github/workflows/build.yml`) builds amd64 and arm64 images, creates two throwaway wikis with `new-wiki.sh --yes` (Docker volumes and data folders), installs and smoke-tests them, and only then publishes `ghcr.io/<owner>/<repo>` with three tags: immutable `<MW>-smw<SMW>-<build>` such as `1.46.2-smw7.3.1-42`, with the workflow's run number as build number (`.<attempt>` on re-runs; an existing immutable tag is never overwritten), floating `<MW minor>-smw<SMW minor>` and `<MW minor>`. A weekly run publishes only when the base image or the recipe (`Dockerfile`, `docker/`, `config/`) changed. Pull requests are built and smoke-tested, never published.
- Watchtower (e.g. the maintained `nickfedor/watchtower` fork) follows the floating tag. On start, the entrypoint compares the image recipe plus a hash of the configuration with the stamp in `wiki-state` (volume or `data/state`) and runs `update.php` once when they differ; a plain restart skips it. Watch for `[entrypoint] update.php done` in `docker compose logs wiki`.
- Renovate (`renovate.json`) bumps the versions pinned in the `Dockerfile`. MediaWiki patch releases and extension commits on the release branch are automerged once build and smoke passed (patch releases also need to be 3 days old); SMW/SRF and PageForms updates stay manual.
- Patch updates are automatic: Watchtower pulls the newest build of the floating `WIKI_TAG` (e.g. `1.46-smw7.3`) and restarts the wiki.
- `scripts/update.sh <name>` for version-line changes (new SMW minor, new MediaWiki branch) and manual refreshes. It offers the version the `main` branch publishes (the floating tag derived from the `Dockerfile` on `origin/main`, as CI does; it offers `git pull --ff-only` first when the clone is behind), accepts any other tag, checks that the tag exists in the registry, warns about schema migrations on a version-line change, backs up with `backup.sh` (mandatory for a version-line change unless `--no-backup --force`), pulls, sets `WIKI_TAG` in `.env` (only that line), starts the wiki, waits until it is healthy, shows the entrypoint's `update.php` lines and runs the smoke test (warning only). Afterwards Watchtower follows the new floating tag; an immutable tag holds that build. Non-interactive: `--tag <tag> --yes`. For a plain local image name it rebuilds from the checkout.
- Rollback: `scripts/update.sh <name> --tag <previous immutable tag>` (or set `WIKI_TAG` and `docker compose up -d`). If the newer version changed the schema, restore the backup taken before the update (`update.sh` prints the exact commands when a step fails).

## Backup and restore

    scripts/backup.sh <name>                                    # -> backups/<name>/wiki-<ts>.tar.gz
    scripts/restore.sh <name> backups/<name>/wiki-<ts>.tar.gz    # asks you to type the name
    scripts/restore.sh <name> --yes <archive>                    # non-interactive

Backup and restore work through the containers, so they behave the same for both storage modes. A backup holds the SQL dump and the whole upload directory (current files, old versions, deleted files, thumbnails). It is written under a temporary name, renamed only when complete, and readable by its owner only. Restore first checks the archive, then asks for confirmation (or takes `--yes`), replaces database and uploads, gives the files back to `www-data`, runs `update.php` and starts the wiki. It also moves a wiki: create the target with `new-wiki.sh --no-install`, copy `WIKI_OATH_KEY` (otherwise enrolled 2FA stops working) and `WIKI_SECRET_KEY` from the old `.env`, then restore. Run backups before Watchtower's update window.

## Publishing the image

1. Push this repository to GitHub. The workflow names the image after the repository.
2. Run the `build` workflow once (Actions, "Run workflow"). Then make the GHCR package public in its settings (so Watchtower needs no login) and link it to the repository.
3. Protect `main` and require the status checks `build (linux/amd64)`, `build (linux/arm64)` and `smoke`. They run on every pull request, so they always report. Renovate automerges only when they are green. Install the Renovate app.
4. Use `ghcr.io/<owner>/<repo>:<tag>` as the image in `new-wiki.sh`, or set `WIKI_IMAGE` in existing wikis' `.env`.

## License

The files in this repository are licensed under the [MIT License](LICENSE).
The built image contains third-party software under its own licenses, notably MediaWiki and
Semantic MediaWiki (GPL-2.0-or-later) and the Roboto font (SIL Open Font License 1.1).
