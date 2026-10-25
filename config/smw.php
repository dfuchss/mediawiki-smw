<?php
# SMW 7 keeps its setup state in the database (no .smw.json, $smwgConfigFileDir is deprecated).

$smwgNamespace = parse_url( $wgServer, PHP_URL_HOST ) ?: 'localhost';

$wgSearchType = 'SMWSearch';
$smwgPageSpecialProperties[] = '_MDAT';
$smwgNamespacesWithSemanticLinks[NS_MAIN] = true;
$smwgNamespacesWithSemanticLinks[NS_USER] = true;
$smwgNamespacesWithSemanticLinks[NS_PROJECT] = true;

# Dates in MediaWiki's format (the user's date preference, day-month-year by default) instead of
# SMW's English "January 15, 2026" in Special:Browse and the factbox.
$smwgDefaultOutputFormatters['_dat'] = 'MEDIAWIKI';
