# All versions are pinned here; the `# renovate:` comments let Renovate bump them (see renovate.json).
# renovate: datasource=docker depName=mediawiki
ARG MW_VERSION=1.46.2
FROM mediawiki:${MW_VERSION}

ARG MW_VERSION
# renovate: datasource=packagist depName=mediawiki/semantic-media-wiki
ARG SMW_VERSION=7.3.1
# renovate: datasource=packagist depName=mediawiki/semantic-result-formats
ARG SRF_VERSION=6.0.0
# Git extensions, pinned by commit. PageForms follows its release tags: REL1_46 (6.0.5) still calls
# an SMW API that SMW 7 removed ("Fix support for SMW 7" is in 6.0.11). The others follow REL1_46.
# renovate: datasource=git-tags depName=PageForms packageName=https://github.com/wikimedia/mediawiki-extensions-PageForms version=6.0.11
ARG PAGEFORMS_SHA=88ad8f1805a11bb1c693ddd9e5311b059593344f
# renovate: datasource=git-refs depName=HeaderTabs packageName=https://github.com/wikimedia/mediawiki-extensions-HeaderTabs branch=1.3
ARG HEADERTABS_SHA=2ba26f649e3a66d6fac6f4d620095043665b56ef
# renovate: datasource=git-refs depName=CodeMirror packageName=https://github.com/wikimedia/mediawiki-extensions-CodeMirror branch=REL1_46
ARG CODEMIRROR_SHA=587cc3fa0fe2d0a9ef25f1ab2e3c1ee4f27fac79
# Roboto webfont (self-hosted, see the font step below); bump version and checksum together
ARG ROBOTO_VERSION=5.3.0
ARG ROBOTO_SHA256=77620f437249772e381698224ea1bddd01c985ecd60267a63ddc96b9eb9348f7
# Bump for image changes the versions above do not show (PHP settings, entrypoint, ...). It is part
# of the recipe below, so the entrypoint runs update.php once (the image tag uses the CI build number).
ARG IMAGE_REVISION=6

# python3: SyntaxHighlight; GMP: fast big-number math for OATHAuth (WebAuthn/passkeys).
# Composer extensions (exact versions): `composer update` re-resolves the whole vendor/ directory, so
# the libraries of bundled extensions we load (OATHAuth: WebAuthn, QR codes) are merged in too.
# Git extensions that are not bundled are fetched at the pinned commit.
# One layer: install the build tools, build, then purge the tools again (git, unzip, the GMP headers;
# the runtime library libgmp10 stays). Composer is bind-mounted from its image, never copied in.
RUN --mount=type=bind,from=composer:2,source=/usr/bin/composer,target=/usr/local/bin/composer \
    apt-get update \
 && apt-get install -y --no-install-recommends python3 git unzip libgmp-dev \
 && docker-php-ext-install -j"$(nproc)" gmp \
 && printf '{"require":{"mediawiki/semantic-media-wiki":"%s","mediawiki/semantic-result-formats":"%s"},"extra":{"merge-plugin":{"include":["extensions/OATHAuth/composer.json"]}},"config":{"allow-plugins":{"composer/installers":true}}}\n' \
      "${SMW_VERSION}" "${SRF_VERSION}" > composer.local.json \
 && COMPOSER_ALLOW_SUPERUSER=1 composer update --no-dev --no-interaction --optimize-autoloader \
 && for e in "PageForms $PAGEFORMS_SHA" "HeaderTabs $HEADERTABS_SHA" "CodeMirror $CODEMIRROR_SHA"; do \
      set -- $e; \
      git init -q "extensions/$1" \
      && git -C "extensions/$1" fetch -q --depth 1 "https://github.com/wikimedia/mediawiki-extensions-$1.git" "$2" \
      && git -C "extensions/$1" checkout -q FETCH_HEAD \
      && echo "$2" > "extensions/$1/.pinned-sha" \
      && rm -rf "extensions/$1/.git" || exit 1; \
    done \
 && apt-mark manual libgmp10 \
 && apt-get purge -y --auto-remove git unzip libgmp-dev \
 && rm -rf /var/lib/apt/lists/* /root/.composer /root/.cache \
 && php -m | grep -qx gmp

# PHP keeps UTC like the DB; MediaWiki switches to $wgLocaltimezone (WIKI_TIMEZONE) at runtime.
# Errors go to the container log, never into pages; deprecation notices are dropped.
RUN printf '%s\n' upload_max_filesize=50M post_max_size=55M memory_limit=512M date.timezone=UTC \
      display_errors=Off log_errors=On 'error_reporting=E_ALL & ~E_DEPRECATED & ~E_USER_DEPRECATED' \
      expose_php=Off > /usr/local/etc/php/conf.d/wiki.ini \
 && mkdir -p /var/lib/wiki-state

# Roboto webfont, self-hosted (no requests to font CDNs). The @font-face rules come from the pinned
# @fontsource/roboto package itself, so they always match its woff2 files: bumping ROBOTO_VERSION and
# ROBOTO_SHA256 is all an update needs. Only latin and latin-ext, weights 400/500/700, normal and
# italic: the per-weight CSS files (400.css, 400-italic.css, ...) are filtered to those two subsets
# (their per-subset siblings lack unicode-range and cannot be combined), the .woff fallback is dropped
# (only woff2 is shipped), and exactly the woff2 files the result references are extracted. The url()s
# stay "./files/..." and resolve from fonts/roboto/. Any missing file fails the build.
RUN curl -fsSL -o /tmp/roboto.tgz "https://registry.npmjs.org/@fontsource/roboto/-/roboto-${ROBOTO_VERSION}.tgz" \
 && echo "${ROBOTO_SHA256}  /tmp/roboto.tgz" | sha256sum -c - \
 && mkdir -p /tmp/roboto fonts/roboto \
 && tar -xzf /tmp/roboto.tgz -C /tmp/roboto package/LICENSE \
      package/400.css package/400-italic.css package/500.css package/500-italic.css package/700.css package/700-italic.css \
 && awk '/^\/\* roboto-/ { keep = ($0 ~ /^\/\* roboto-latin(-ext)?-[0-9]+-(normal|italic) \*\/$/) } keep' \
      /tmp/roboto/package/[457]00.css /tmp/roboto/package/[457]00-italic.css \
    | sed 's#, url(\./files/[^)]*\.woff) format(.woff.)##' > fonts/roboto/font-face.css \
 && grep -o 'files/roboto-[a-z-]*-[0-9]*-[a-z]*\.woff2' fonts/roboto/font-face.css | sed 's#^#package/#' > /tmp/roboto/files \
 && tar -xzf /tmp/roboto.tgz -C fonts/roboto --strip-components=1 -T /tmp/roboto/files \
 && mv /tmp/roboto/package/LICENSE fonts/roboto/LICENSE \
 && test "$(grep -c '@font-face' fonts/roboto/font-face.css)" = 12 \
 && test "$(ls fonts/roboto/files/*.woff2 | wc -l)" = 12 \
 && ! grep -q '\.woff)' fonts/roboto/font-face.css \
 && rm -rf /tmp/roboto /tmp/roboto.tgz
# Applies the font (font-family rules; code stays monospace)
COPY docker/fonts/use-roboto.css fonts/roboto/use-roboto.css
# Generic theme fixes; a wiki's branding/ folder is mounted at runtime over the empty /var/www/html/branding
COPY docker/theme.css theme/theme.css
COPY docker/robots.txt robots.txt
# Uploads only through img_auth.php, no server-side or version files over HTTP, no version headers
COPY docker/apache-wiki.conf /etc/apache2/conf-enabled/wiki.conf

# Access log with the real client IP. mod_remoteip (configured by the entrypoint from
# WIKI_TRUSTED_PROXIES) replaces the peer address with the client behind a trusted proxy; %a is that
# address, while the stock %h would still print the peer. The vhost logs with the "combined" format.
RUN a2enmod remoteip \
 && sed -i 's/^LogFormat "%h %l %u %t \\"%r\\" %>s %O \\"%{Referer}i\\" \\"%{User-Agent}i\\"" combined$/LogFormat "%a %l %u %t \\"%r\\" %>s %O \\"%{Referer}i\\" \\"%{User-Agent}i\\"" combined/' /etc/apache2/apache2.conf \
 && grep -q '^LogFormat "%a .* combined$' /etc/apache2/apache2.conf

# The MediaWiki configuration is part of the image, so a wiki folder (compose.yaml, .env, branding/,
# settings.php) runs without a checkout of this repository. A wiki's settings.php is mounted over the
# empty /config/instance.php, which LocalSettings.php includes last.
COPY config/ /config/
ENV MW_CONFIG_FILE=/config/LocalSettings.php

COPY docker/entrypoint.sh /usr/local/bin/wiki-entrypoint
# a+rX: the files must be readable by www-data even when the build context had a strict umask
RUN chmod 755 /usr/local/bin/wiki-entrypoint \
 && chmod -R a+rX /config theme fonts robots.txt /etc/apache2/conf-enabled/wiki.conf \
 && mkdir -p branding

# Identifies what this image would do to the DB. The entrypoint adds a hash of /config (including the
# mounted settings.php) and runs update.php when the stamp in the wiki-state volume differs.
# BUILD_ID is the CI build number ("local" for a local build).
ARG BUILD_ID=local
ENV WIKI_RECIPE="mw=${MW_VERSION} smw=${SMW_VERSION} srf=${SRF_VERSION} rev=${IMAGE_REVISION} build=${BUILD_ID} pageforms=${PAGEFORMS_SHA} headertabs=${HEADERTABS_SHA} codemirror=${CODEMIRROR_SHA}"

# TERM stops Apache and the job loop at once (the base image's SIGWINCH would wait for requests)
STOPSIGNAL SIGTERM
ENTRYPOINT ["wiki-entrypoint"]
CMD ["apache2-foreground"]
