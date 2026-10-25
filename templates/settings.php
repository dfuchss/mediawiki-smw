<?php
# Extra MediaWiki settings for this wiki only. The image's LocalSettings.php includes this file last,
# so it can override anything. It may stay empty, but must exist (it is mounted into the container).
# After a change: `docker compose up -d --force-recreate wiki` (the entrypoint runs update.php once,
# because this file is part of the update stamp).
#
# Examples:
# $wgLogos = [ 'icon' => "$wgScriptPath/branding/icon.svg" ];   # files in branding/ are served at /branding
# $wgGroupPermissions['user']['upload'] = false;
# wfLoadExtension( 'Gadgets' );                                  # bundled extensions only
