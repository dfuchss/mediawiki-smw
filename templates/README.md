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
`scripts/restore.sh @NAME@ <archive>`.

## Next steps (production behind Traefik)

With a public `WIKI_SERVER`, `scripts/new-wiki.sh` installs the wiki and then stops it (data kept),
because it still needs these steps:

1. `compose.yaml`: comment out `ports:` and enable the Traefik block (`networks:` and `labels:` of
   the wiki, and the top-level `networks:`); see the comments there. Defaults: network `web`,
   entrypoint `websecure`.
2. `.env`: set `TRAEFIK_CERTRESOLVER` and `WIKI_TRUSTED_PROXIES` (the Traefik network's subnet, from
   `docker network inspect web --format '{{(index .IPAM.Config 0).Subnet}}'`, or `private`; MediaWiki
   and the Apache access log then show real client IPs); check `WIKI_SERVER`/`WIKI_HOST`, `WIKI_IMAGE`/`WIKI_TAG` (`ghcr.io/<owner>/<repo>` with
   the floating tag for Watchtower), and `TRAEFIK_NETWORK`/`TRAEFIK_ENTRYPOINT` if yours differ.
3. Logos and icons into `branding/`, extra MediaWiki settings into `settings.php`.
4. Start it: `cd wikis/@NAME@ && docker compose up -d` (or `scripts/compose.sh @NAME@ up -d`).

## Updating

Patch updates arrive automatically when Watchtower runs: it follows the floating `WIKI_TAG`. For a new
version line (MediaWiki or SMW minor), a manual refresh or a rollback to an immutable tag, run
`scripts/update.sh @NAME@` from the repository root: it backs up, pulls, sets `WIKI_TAG` in `.env`,
starts the wiki and checks it, and prints the rollback steps if anything fails.

## Afterwards

Keep `WIKI_OATH_KEY` and `WIKI_SECRET_KEY` when moving the wiki (backup and restore), and run
`scripts/backup.sh @NAME@` nightly with off-site copies.
