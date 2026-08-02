fx_version 'cerulean'
game 'gta5'

author 'The Nexus Core Framework team'
description 'The Nexus Core framework spine: lifecycle, identity, sessions, permissions, shared state, and service discovery.'
version '0.1.0'

shared_scripts {
    'shared/*.lua',
}

client_scripts {
    'client/*.lua',
}

server_scripts {
    'server/*.lua',
}

files {
    'locales/*.json',
}

dependencies {
    'nxc_lib',
    'oxmysql',
}
