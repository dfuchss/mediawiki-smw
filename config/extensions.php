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

# VisualEditor (bundled with MediaWiki; Parsoid is part of core and runs in-process, so there is no
# $wgVirtualRestConfig, no Node service and no extra port: VE calls the action API (api.php), which
# calls Parsoid inside the same PHP request with the user's session, so it works on this private
# wiki). WIKI_VISUAL_EDITOR=off removes it; empty or unset (wikis whose compose.yaml predates the
# variable) means on.
# Two tabs: "Edit" opens the visual editor (?veaction=edit), "Edit source" the wikitext editor
# (?action=edit); the user's last choice is remembered. Available in the main, user, project
# (Wiki:) and help namespaces plus VE's own defaults (File, Category). 'visualeditor-enable' is
# listed for completeness: VE reads it only in the legacy beta mode, otherwise it is on for everyone.
# Not covered: PageForms form fields need the separate VEForAll extension (not installed).
if ( ( getenv( 'WIKI_VISUAL_EDITOR' ) ?: 'on' ) !== 'off' ) {
	wfLoadExtension( 'VisualEditor' );
	$wgDefaultUserOptions['visualeditor-enable'] = 1;
	$wgVisualEditorUseSingleEditTab = false;
	$wgVisualEditorAvailableNamespaces = [
		NS_MAIN => true,
		NS_USER => true,
		NS_PROJECT => true,
		NS_HELP => true,
	];
}
