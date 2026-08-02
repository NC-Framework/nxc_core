fx_version 'cerulean'
game 'gta5'

author 'The Nexus Core Framework team'
description 'The Nexus Core framework spine: lifecycle, identity, sessions, permissions, shared state, and service discovery.'
version '0.1.0'

shared_scripts {
    'shared/*.lua',
}

files {
    'locales/*.json',
}

-- No client or server blocks yet: the implemented modules are all shared pure
-- logic. Blocks are added when those directories gain files.

dependencies {
    'nxc_lib',
    'oxmysql',
}
