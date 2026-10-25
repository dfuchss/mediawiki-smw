<?php
# Private wiki: login required to read anything.
$wgGroupPermissions['*']['read'] = false;
$wgGroupPermissions['*']['edit'] = false;
$wgWhitelistRead = [ 'Special:UserLogin' ];

# No self-registration; only admins create accounts.
$wgGroupPermissions['*']['createaccount'] = false;
$wgGroupPermissions['*']['autocreateaccount'] = false;
$wgGroupPermissions['user']['createaccount'] = false;
$wgGroupPermissions['sysop']['createaccount'] = true;

# No patrolling: in a private wiki every editor is trusted
$wgUseRCPatrol = false;
$wgUseNPPatrol = false;
$wgUseFilePatrol = false;

# A block also locks the user out of reading (private wiki)
$wgBlockDisablesLogin = true;
