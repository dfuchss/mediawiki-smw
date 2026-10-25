<?php
# Look: Vector 2022 plus optional branding. Everything here follows the wiki's .env and the files in
# its branding/ folder (mounted at $IP/branding); nothing is required.

# Default theme for everyone, including logged-out visitors: os (follows the system), day or night.
# Users switch in the appearance menu.
$wgDefaultUserOptions['vector-theme'] = getenv( 'WIKI_DEFAULT_THEME' ) ?: 'os';

# Branding files, each used only when present. Without them Vector shows the site name as text and
# browsers show their default icon.
#   wordmark.svg          header wordmark (replaces the site name text; size read from the SVG)
#   icon.svg              square header icon next to the wordmark
#   favicon.svg|png|ico   favicon
#   apple-touch-icon.png  touch icon; also the 1x logo for legacy skins and link previews
#   branding.css          extra CSS, loaded after the stack's theme fixes
$brandingDir = "$IP/branding";
$brandingUrl = "$wgScriptPath/branding";
$hasBranding = static fn ( string $f ): bool => is_file( "$brandingDir/$f" );
$wgLogos = [];
if ( $hasBranding( 'wordmark.svg' ) ) {
	$svg = file_get_contents( "$brandingDir/wordmark.svg", false, null, 0, 4096 );
	preg_match( '/<svg[^>]*\swidth="([\d.]+)/', $svg, $w );
	preg_match( '/<svg[^>]*\sheight="([\d.]+)/', $svg, $h );
	$wgLogos['wordmark'] = [
		'src' => "$brandingUrl/wordmark.svg",
		'width' => (int)round( (float)( $w[1] ?? 120 ) ),
		'height' => (int)round( (float)( $h[1] ?? 20 ) ),
	];
}
if ( $hasBranding( 'icon.svg' ) ) {
	$wgLogos['icon'] = "$brandingUrl/icon.svg";
}
if ( $hasBranding( 'apple-touch-icon.png' ) ) {
	$wgAppleTouchIcon = "$brandingUrl/apple-touch-icon.png";
	$wgLogos['1x'] = $wgAppleTouchIcon;
}
if ( $wgLogos ) {
	# '1x' is the base entry MediaWiki expects; fall back to the icon or MediaWiki's placeholder
	$wgLogos['1x'] ??= $wgLogos['icon'] ?? "$wgScriptPath/resources/assets/change-your-logo.svg";
} else {
	$wgLogos = false;   # MediaWiki's default
}
foreach ( [ 'favicon.svg', 'favicon.png', 'favicon.ico' ] as $f ) {
	if ( $hasBranding( $f ) ) {
		$wgFavicon = "$brandingUrl/$f";
		break;
	}
}

# Stylesheets on every page: Roboto (WIKI_FONT=roboto, the default; "default" keeps Vector's fonts),
# the generic theme fixes (docker/theme.css), and the wiki's branding.css.
$wikiStyleModules = [ 'wiki.theme' ];
$wgResourceModules['wiki.theme'] = [
	'localBasePath' => "$IP/theme",
	'remoteBasePath' => "$wgScriptPath/theme",
	'styles' => [ 'theme.css' ],
];
if ( ( getenv( 'WIKI_FONT' ) ?: 'roboto' ) === 'roboto' ) {
	$wgResourceModules['wiki.fonts.roboto'] = [
		'localBasePath' => "$IP/fonts/roboto",
		'remoteBasePath' => "$wgScriptPath/fonts/roboto",
		'styles' => [ 'font-face.css', 'use-roboto.css' ],
	];
	array_unshift( $wikiStyleModules, 'wiki.fonts.roboto' );
}
if ( $hasBranding( 'branding.css' ) ) {
	$wgResourceModules['wiki.branding'] = [
		'localBasePath' => $brandingDir,
		'remoteBasePath' => $brandingUrl,
		'styles' => [ 'branding.css' ],
	];
	$wikiStyleModules[] = 'wiki.branding';
}
$wgHooks['BeforePageDisplay'][] = static function ( $out ) use ( $wikiStyleModules ) {
	$out->addModuleStyles( $wikiStyleModules );
};
unset( $brandingDir, $brandingUrl, $hasBranding, $svg, $w, $h, $f );
