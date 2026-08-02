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

server_scripts {
    'server/*.lua',
}

-- No client block yet: nothing client-side is implemented. It is added when
-- the client directory gains files.

dependencies {
    'nxc_lib',
    'oxmysql',
}
