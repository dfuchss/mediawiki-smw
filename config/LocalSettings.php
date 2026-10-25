<?php
if ( !defined( 'MEDIAWIKI' ) ) { exit; }

$wgSitename = getenv( 'WIKI_NAME' ) ?: 'Wiki';
$wgMetaNamespace = 'Wiki';   # project namespace "Wiki:" ("Project:" stays an alias)
$wgScriptPath = '';
$wgServer = rtrim( getenv( 'WIKI_SERVER' ) ?: 'http://localhost:8080', '/' );
$wgLanguageCode = getenv( 'WIKI_LANG' ) ?: 'en';   # fixed at install; changing it later is hard
# Short URLs: pages at /wiki/<page> (docker/apache-wiki.conf hands /wiki and everything below it to
# index.php). WIKI_ARTICLE_PATH=/index.php switches back to /index.php/<page>. Either way the other
# forms keep working: /index.php/<page> ($wgUsePathInfo) and /index.php?title=<page>.
$wgArticlePath = rtrim( getenv( 'WIKI_ARTICLE_PATH' ) ?: '/wiki', '/' ) . '/$1';
$wgUsePathInfo = true;
$wgDefaultSkin = 'vector-2022';

# Time: the DB stores UTC; pages show WIKI_TIMEZONE (default UTC) in WIKI_DATE_FORMAT (default dmy:
# "14:30, 25 October 2026"). MediaWiki sets PHP's runtime timezone from $wgLocaltimezone itself, and
# the user default timecorrection to "System" (= this zone, with DST); users can change both.
$wgLocaltimezone = getenv( 'WIKI_TIMEZONE' ) ?: 'UTC';
$wgDefaultUserOptions['date'] = getenv( 'WIKI_DATE_FORMAT' ) ?: 'dmy';

# Private: keep search engines out (robots.txt in the image says the same)
$wgDefaultRobotPolicy = 'noindex,nofollow';
# Error details only for local debugging (WIKI_DEBUG=1)
$wgShowExceptionDetails = (bool)getenv( 'WIKI_DEBUG' );
# Behind Traefik (https WIKI_SERVER): redirect plain HTTP and mark cookies secure. Traefik sends
# X-Forwarded-Proto: https, which MediaWiki honours. http://localhost keeps working.
$wgForceHTTPS = str_starts_with( $wgServer, 'https://' );

# Database
$wgDBtype = 'mysql';
$wgDBserver = 'db';
$wgDBname = getenv( 'DB_NAME' ) ?: 'wiki';
$wgDBuser = getenv( 'DB_USER' ) ?: 'wiki';
$wgDBpassword = getenv( 'DB_PASSWORD' );

# Secrets
$wgSecretKey = getenv( 'WIKI_SECRET_KEY' );
$wgUpgradeKey = getenv( 'WIKI_UPGRADE_KEY' );
$wgAuthenticationTokenVersion = '1';

# Caching and jobs. Object cache in APCu (one container); parser cache and sessions stay in the DB
# so logins and rendered pages survive container restarts (Watchtower updates). Jobs: entrypoint loop.
$wgMainCacheType = CACHE_ACCEL;
$wgParserCacheType = CACHE_DB;
$wgSessionCacheType = CACHE_DB;
$wgMessageCacheType = CACHE_DB;
$wgJobRunRate = 0;
# Localisation cache as files inside the container (rebuilt after each image change, faster than the DB)
$wgCacheDirectory = '/tmp/mw-cache';

# Uploads
$wgEnableUploads = true;
$wgMaxUploadSize = 50 * 1024 * 1024;   # = upload_max_filesize in the image's PHP settings
$wgUseImageMagick = true;
$wgImageMagickConvertCommand = '/usr/bin/convert';
$wgFileExtensions = array_merge( $wgFileExtensions, [ 'pdf', 'svg', 'docx' ] );
$wgUploadDirectory = "$IP/images";
# Private wiki: files are served only through img_auth.php, which checks read rights (403 otherwise;
# $wgImgAuthDetails stays false, so no reasons are shown). The image's Apache config denies /images.
$wgUploadPath = "$wgScriptPath/img_auth.php";

# Reverse proxies whose X-Forwarded-For header is believed (client IPs in RecentChanges, blocks,
# throttles). WIKI_TRUSTED_PROXIES: space- or comma-separated IPs/CIDRs, or "private" for the private
# networks (10/8, 172.16/12, 192.168/16, e.g. behind Traefik). Empty (the default): nothing is trusted,
# so clients cannot spoof their IP.
$wikiProxies = trim( (string)getenv( 'WIKI_TRUSTED_PROXIES' ) );
if ( $wikiProxies === 'private' ) {
	$wikiProxies = '10.0.0.0/8 172.16.0.0/12 192.168.0.0/16';
}
$wgCdnServersNoPurge = preg_split( '/[\s,]+/', $wikiProxies, -1, PREG_SPLIT_NO_EMPTY );
unset( $wikiProxies );

# Mail: off unless SMTP_HOST is set
$wgEnableEmail = false;
$wgEnableUserEmail = false;
$wgPasswordResetRoutes = [ 'username' => false, 'email' => false ];
if ( getenv( 'SMTP_HOST' ) ) {
	$wgEnableEmail = true;
	$wgEmergencyContact = $wgPasswordSender = getenv( 'WIKI_EMAIL_FROM' ) ?: 'wiki@localhost';
	$wgSMTP = [
		'host' => getenv( 'SMTP_HOST' ),
		'IDHost' => parse_url( $wgServer, PHP_URL_HOST ),
		'port' => (int)( getenv( 'SMTP_PORT' ) ?: 587 ),
		'auth' => (bool)getenv( 'SMTP_USER' ),
		'username' => getenv( 'SMTP_USER' ),
		'password' => getenv( 'SMTP_PASSWORD' ),
	];
}

$wgRightsText = '';
wfLoadSkin( 'Vector' );

require __DIR__ . '/permissions.php';
require __DIR__ . '/smw.php';
require __DIR__ . '/extensions.php';
require __DIR__ . '/skin.php';
# The wiki's own settings last: its settings.php is mounted over this (otherwise empty) file
require __DIR__ . '/instance.php';
