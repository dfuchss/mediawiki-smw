# Wiki "@NAME@"

Created by `scripts/new-wiki.sh` of the MediaWiki + Semantic MediaWiki stack. Everything about this
wiki is in this folder:

| File | What |
|---|---|
| `.env` | Settings and secrets (mode 600; keep it private and back it up) |
| `compose.yaml` | Both containers (`db`, `wiki`); yours to edit, never changed by stack updates |
| `branding/` | Optional: `wordmark.svg`, `icon.svg`, `favicon.svg`/`.png`/`.ico`, `apple-touch-icon.png`, `branding.css` |
| `settings.php` | Optional extra MediaWiki settings, included last (must exist, may stay empty) |
| `data/` | Only with the folders storage: `db`, `images`, `state` (see below) |

@STORAGE@

Logos and icons go into `branding/` (served without login), never as wiki uploads in `$wgLogos` or
`$wgFavicon`: uploads need a login and would be missing on the login page.

Run it with plain `docker compose` in this folder (`docker compose ps`, `logs -f wiki`, `up -d`), or
with the scripts from the repository root: `scripts/compose.sh @NAME@ ...`, `scripts/backup.sh @NAME@`,
`scripts/restore.sh @NAME@ <archive>`, `scripts/smoke.sh @NAME@`.

## For production

1. `compose.yaml`: comment out `ports:` and enable the Traefik block (see the comments there).
2. `.env`: `WIKI_SERVER=https://<host>`, `WIKI_HOST=<host>`, `TRAEFIK_NETWORK`, `TRAEFIK_CERTRESOLVER`
   (and `TRAEFIK_ENTRYPOINT`), `WIKI_TRUSTED_PROXIES` (the Traefik network's subnet, or `private`).
3. `.env`: `WIKI_IMAGE=ghcr.io/<owner>/<repo>` with the floating `WIKI_TAG` for Watchtower.
4. Keep `WIKI_OATH_KEY` and `WIKI_SECRET_KEY` when moving the wiki (backup and restore), and run
   `scripts/backup.sh @NAME@` nightly with off-site copies.
