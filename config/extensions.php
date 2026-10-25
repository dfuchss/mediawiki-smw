<?php
wfLoadExtension( 'SemanticMediaWiki' );
wfLoadExtension( 'ParserFunctions' );
wfLoadExtension( 'Cite' );
wfLoadExtension( 'CategoryTree' );
wfLoadExtension( 'SyntaxHighlight_GeSHi' );
wfLoadExtension( 'WikiEditor' );
wfLoadExtension( 'CodeMirror' );
wfLoadExtension( 'ReplaceText' );
wfLoadExtension( 'PageForms' );
wfLoadExtension( 'HeaderTabs' );
wfLoadExtension( 'SemanticResultFormats' );
wfLoadExtension( 'OATHAuth' );

# Optional two-factor authentication at Special:AccountSecurity: TOTP apps, security keys and
# passkeys (WebAuthn needs HTTPS). Not enforced. Passkeys are bound to the host of WIKI_SERVER.
$wgOATHPasswordlessLogin = true;
$wgWebAuthnRelyingPartyID = parse_url( $wgServer, PHP_URL_HOST );
# Encrypt 2FA secrets in the DB. Set before anyone enrols; changing or removing it later breaks 2FA logins.
if ( getenv( 'WIKI_OATH_KEY' ) ) {
	$wgOATHSecretKey = getenv( 'WIKI_OATH_KEY' );
}
