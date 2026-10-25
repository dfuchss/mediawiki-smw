# MediaWiki + Semantic MediaWiki on Docker Compose

A reusable stack for private wikis: MediaWiki 1.46, Semantic MediaWiki 7.3, SemanticResultFormats, PageForms, HeaderTabs, CodeMirror, optional two-factor authentication (OATHAuth with passkeys) and MySQL 8.4. Two containers per wiki (`db`, `wiki`). Wikis are private: login required to read, no self-registration, no mail unless SMTP is configured.

The image contains the extensions, the MediaWiki configuration (`config/`), a self-hosted Roboto font and an entrypoint that runs `update.php` once per new image or configuration (under a lock), then supervises Apache and the job queue loop. It contains no wiki-specific settings, branding or data.

Hardening built in:

- Uploads are served only through `img_auth.php`, which checks read rights; Apache denies `/images` itself. Anonymous users get 403 for files, old versions and thumbnails; deleted files are never served.
- Apache serves no server-side or version-revealing files (`/vendor`, `/maintenance`, `/tests`, `/docs`, `/cache`, `/mw-config`, `composer.*`, READMEs, release notes, extension manifests, dotfiles) and sends no version headers.
- Each container gets only the variables it needs: the wiki never sees `DB_ROOT_PASSWORD` or `ADMIN_*`.
- The port is published on `127.0.0.1` unless `WIKI_BIND` says otherwise, and `X-Forwarded-For` is trusted only from `WIKI_TRUSTED_PROXIES`.
- The entrypoint handles `SIGTERM` in every phase, so `docker stop` takes about a second.

## Layout

Clone the repository once per machine. Wikis and backups live inside the clone and are ignored by git (and by the Docker build context):

    wikis/<name>/
      .env            settings and secrets (mode 600)
      compose.yaml    both containers; standalone, yours to edit
      branding/       optional: wordmark.svg, icon.svg, favicon.svg|png|ico, apple-touch-icon.png, branding.css
      settings.php    optional extra MediaWiki settings, included last (must exist, may stay empty)
      README.md       what to edit for production
    backups/<name>/wiki-<timestamp>.tar.gz

`<name>` is the folder name and the compose project name (it also names the volumes `<name>_db-data`, `<name>_images`, `<name>_wiki-state`). A wiki folder is self-contained: run plain `docker compose` inside it, or copy it alone to a server.

`templates/` holds what `new-wiki.sh` copies. Updating the repository never touches existing wikis: their `compose.yaml` stays as generated. After an update, compare it with `templates/compose.yaml` and merge changes by hand if you want them. Configuration changes (`config/`) reach a wiki with the next image.

## Create a wiki

    scripts/new-wiki.sh

It asks for the name, the local port (the next free one from 8080), the public URL, site name, admin user and password (generated unless you type one), language, time zone, date format, default theme, font and image, with defaults in brackets. It generates all secrets with `openssl rand`, writes the folder above, shows a summary and asks whether to install now: get the image (a plain name such as `mediawiki-smw` is built from this repository, `ghcr.io/...` is pulled), install, start, wait until healthy, and run the smoke test.

Non-interactive (CI, scripts): every answer has an option, `--yes` takes defaults for the rest, and the admin password comes from `ADMIN_PASSWORD` in the environment or is generated:

    scripts/new-wiki.sh --yes --name team --server https://wiki.example.org --site-name "Team Wiki" \
      --image ghcr.io/<owner>/<repo>:1.46-smw7.3 --no-install

`scripts/new-wiki.sh --help` lists all options.

## Scripts

All take the wiki name first.

| Script | Does |
|---|---|
| `scripts/new-wiki.sh [options] [name]` | Create `wikis/<name>/`, optionally install it |
| `scripts/install.sh <name>` | First install: database, admin account, `update.php`, start, wait until healthy |
| `scripts/compose.sh <name> <args...>` | `docker compose` for that wiki, from anywhere (`ps`, `logs -f wiki`, `pull`, `up -d`) |
| `scripts/smoke.sh <name>` | Read-only check: login page, private API, admin login, SMW |
| `scripts/backup.sh <name>` | `backups/<name>/wiki-<timestamp>.tar.gz` |
| `scripts/restore.sh <name> [--yes] <archive>` | Replace database and uploads from a backup |
| `scripts/list-wikis.sh` | Name, URL, port and state of all wikis |

The scripts stop with a clear message when a required setting is missing, run with `umask 077`, never put passwords on command lines, and start one-off containers with `traefik.enable=false` so Traefik never routes to them.

## Settings

Logos and icons go into `branding/` (served at `/branding/...` without login), never as wiki uploads referenced in `$wgLogos`/`$wgFavicon`: uploads need a login and would be missing on the login page.

The settings are in the wiki's `.env` (commented; template `templates/wiki.env`): URL, name, language, time zone, date format, theme, font, image and tag, port and bind address, DB and secret keys, admin account, job loop interval, SMTP, Traefik values, trusted proxies. Apply changes with `docker compose up -d`. Anything else goes into `settings.php`; a change there runs `update.php` once on the next start, because it is part of the update stamp.

## Production

On the server, either clone the repository and create the wiki there with `new-wiki.sh`, or copy a wiki folder (it needs nothing else at runtime; for backups the scripts need the clone). Then edit:

1. `compose.yaml`: comment out `ports:` and enable the commented Traefik block (labels, the external network); the comments there list the steps.
2. `.env`: `WIKI_SERVER=https://<host>` (forces HTTPS and secure cookies), `WIKI_HOST=<host>`, `TRAEFIK_CERTRESOLVER`, and `TRAEFIK_NETWORK` (default `web`) and `TRAEFIK_ENTRYPOINT` (default `websecure`) if yours differ.
3. `.env`: `WIKI_TRUSTED_PROXIES` to the Traefik network's subnet (`docker network inspect web`) or `private` (10/8, 172.16/12, 192.168/16), so real client IPs appear in RecentChanges and blocks.
4. `.env`: `WIKI_IMAGE=ghcr.io/<owner>/<repo>` with the floating `WIKI_TAG=1.46-smw7.3`.
5. `docker compose pull && docker compose up -d`, then schedule `scripts/backup.sh <name>` nightly with off-site copies.

## Updates

- The CI workflow (`.github/workflows/build.yml`) builds amd64 and arm64 images, creates a throwaway wiki with `new-wiki.sh --yes`, installs and smoke-tests it, and only then publishes `ghcr.io/<owner>/<repo>` with three tags: immutable `<MW>-smw<SMW>-r<REV>.<run>` (`.<attempt>` on re-runs; an existing immutable tag is never overwritten), floating `<MW minor>-smw<SMW minor>` and `<MW minor>`. A weekly run publishes only when the base image or the recipe (`Dockerfile`, `docker/`, `config/`) changed. Pull requests are built and smoke-tested, never published.
- Watchtower (e.g. the maintained `nickfedor/watchtower` fork) follows the floating tag. On start, the entrypoint compares the image recipe plus a hash of the configuration with the stamp in the `wiki-state` volume and runs `update.php` once when they differ; a plain restart skips it. Watch for `[entrypoint] update.php done` in `docker compose logs wiki`.
- Renovate (`renovate.json`) bumps the versions pinned in the `Dockerfile`. MediaWiki patch releases and extension commits on the release branch are automerged once build and smoke passed (patch releases also need to be 3 days old); SMW/SRF and PageForms updates stay manual.
- Manual update (new SMW minor, new MediaWiki branch): back up, set `WIKI_TAG`, `docker compose pull && docker compose up -d`.
- Rollback: pin the previous immutable tag in `WIKI_TAG` and `docker compose up -d` (Watchtower leaves pinned tags alone). If the newer version changed the schema, restore the backup taken before the update.

## Backup and restore

    scripts/backup.sh <name>                                    # -> backups/<name>/wiki-<ts>.tar.gz
    scripts/restore.sh <name> backups/<name>/wiki-<ts>.tar.gz    # asks you to type the name
    scripts/restore.sh <name> --yes <archive>                    # non-interactive

A backup holds the SQL dump and the whole upload directory (current files, old versions, deleted files, thumbnails). It is written under a temporary name, renamed only when complete, and readable by its owner only. Restore first checks the archive, then asks for confirmation (or takes `--yes`), replaces database and uploads, gives the files back to `www-data`, runs `update.php` and starts the wiki. It also moves a wiki: create the target with `new-wiki.sh --no-install`, copy `WIKI_OATH_KEY` (otherwise enrolled 2FA stops working) and `WIKI_SECRET_KEY` from the old `.env`, then restore. Run backups before Watchtower's update window.

## Publishing the image

1. Push this repository to GitHub. The workflow names the image after the repository.
2. Run the `build` workflow once (Actions, "Run workflow"). Then make the GHCR package public in its settings (so Watchtower needs no login) and link it to the repository.
3. Protect `main` and require the status checks `build (linux/amd64)`, `build (linux/arm64)` and `smoke`. They run on every pull request, so they always report. Renovate automerges only when they are green. Install the Renovate app.
4. Use `ghcr.io/<owner>/<repo>:<tag>` as the image in `new-wiki.sh`, or set `WIKI_IMAGE` in existing wikis' `.env`.

## License

The files in this repository are licensed under the [MIT License](LICENSE).
The built image contains third-party software under its own licenses, notably MediaWiki and
Semantic MediaWiki (GPL-2.0-or-later) and the Roboto font (SIL Open Font License 1.1).
