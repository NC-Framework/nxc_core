--- Startup orchestration — the entry point this resource did not have.
---
--- Everything before this file DEFINES things. Nothing ran them. `nxc_core`
--- loaded twenty-eight modules of tested logic and executed none of it: bootstrap
--- validation never ran, the provider was never installed, migrations never
--- applied. The resource reported "Started" and did nothing, which is the
--- failure mode hardest to notice, because there is no error to read.
---
--- Order matters and each step gates the next:
---
---   1. Validate the environment. Refuse to run if it is wrong.
---   2. Reach the database. Refuse to run if it is unreachable.
---   3. Apply migrations. Refuse to run if any fails.
---   4. Register the service and open for connections.
---
--- **A failure at any step stops the framework rather than degrading it.** A
--- server that starts without its database looks healthy and fails on the first
--- player action, which costs more to diagnose than a refusal at boot.

if not IsDuplicityVersion() then return end

local Startup = {}

local ready = false
local failure = nil

---@return boolean
function Startup.isReady() return ready end

---@return table|nil
function Startup.failure() return failure end

--- The startup banner.
---
--- Plain ASCII on purpose. Box-drawing and block characters look better and
--- depend on the console's encoding; a banner that renders as replacement
--- characters is worse than no banner, and this is the one thing an operator
--- sees before anything else works.
---
--- Printed before validation, so it appears whether the server starts or not.
local BANNER = {
'         /-------------------------------------------------------------------------------------/',
'        / ##   ##  #######  ##   ##  ##   ##   ######         #####    #####   ######   ##### /',
'       / ###  ##  ##        ## ##   ##   ##  ##             ##   ##  ##   ##  ##   ##  ##    /',
'      / #### ##  ##         ###    ##   ##  ##             ##       ##   ##  ##   ##  ##    /',
'     / ## ####  ######      #     ##   ##   #####         ##       ##   ##  ######   ##### /',
'    / ##  ###  ##         ###    ##   ##       ##        ##       ##   ##  ##  ##   ##    /',
'   / ##   ##  ##        ## ##   ##   ##       ##        ##   ##  ##   ##  ##   ##  ##    /',
'  / ##   ##  #######  ##   ##   #####   ######          #####    #####   ##   ##  ######/',
' /-------------------------------------------------------------------------------------/',
}




-- local BANNER = {
--     '                                                                           %++++====*#',
--     '                                                                        *@+ ::::..:-  %%%%%#**',
--     '                                                                  %%%=  :+ *#:.     *  *        =#%#++',
--     '                                                            %@%#+.     *@-*=::     . =  #            =#*+=#',
--     '                                                         %%@#    -    =@=*%:-::. .:::.#=+%#-       .     +#=:=+=+',
--     '                                                     %%@@=  .-     +#: :.=%:--::::--.+= %- -##***+          -*..+',
--     '                                                  ##%@*: --    =%###*. :#.**.::...::+#=+@        .=---        :###%#         %%',
--     '                                                ##%%+.:+.   #%## -      .*#%@#.  .+%%#+%-         .  .+*#   +%*.    =##     #',
--     '                                             ***%@=..+. .#%%%=   :   ..  -@@@##-  ++%@@@@%*.   .        +%@=  .##*%*   %####  %',
--     '                                           .=#%-.:+@%%#%%%-       . =##%@@@@@*+:  +:*%%%%%%%@@@#=        *=## .      *-  %# #%  %%',
--     '                                          *#%  ==:     ##  .    =%%%@@@%##*#@. :  - =#*#**===+#%%%%#=.  @+=-.:.     . #  #%%%%##  %%',
--     '                            @       #*   #%. ##.     -#  *.  +#%@@#++-=###*%%+ :.:- ****+**+****--*%%%@@-=%.:-:....:::#  #%%**##%%',
--     '                            @@%%%     **%- *%.=:.    .    @%%@@@##*.-*###%#-.*%#  .##       ==-:=+++=%@%#%@.:::::-=++:%. # -#**#',
--     '                              %%%#*+%##%# -#:-=-:   .:- #%@@@@%######*=:..  :+##.  *###+-       .=++*#%=-==+.  .::--:%#+=*  :##=*',
--     '                                %%##=*#@%::#--==-::::--.@:  *%%#%##+:-::=%%%##++:  *#**++==---.    -#       #=...:-#%=.#%.    ##=*',
--     '                             %%%  %###%-%=:=@----:::.: *:-#   =%%=---%###:####**-   :.-*+=+=-==-*# : :+   ++--%@#: .%#%@=      ##-+',
--     '                        @@   @% %###%% -*@.+#%*:.. ..=%=    ++   *#%%#####-         :        ++**###+ . :-.-%@@@%%%#=  =#.     .##:#',
--     '                          @%%%@%####%::=%@@%*++*#%*@@%+=+=    -#:#%%###.       . ..:+.          -*#    -:=@@@*#%%*:.    -.      =#%:*',
--     '                              %####%-.-*--+@@@@#++=%@@@#.  #    :%%#*-      ++*#**+++++**=:.      :  --#%%*##*****+      +*      %%*+',
--     '                               #%##+.:+=-:@#++**+%@%##%#%@@#+:+    :    .+%%=.. .         .#%-.     +%%%#*  -++++++.      ++  =   %%-#',
--     '                              ##%#%..:*:.+%=:-+:*%#..+*#*:+%@%#=+.:.   +%*..:::..            -*-     .%++++   :.:-*#      +##  -*+%%%=#',
--     '                              *###* .*.. ##..-..%##***** -%%*#%#---. .##:::::::..             .**      *-::.   :-=**#    :%*--=.    :+**    ++++**',
--     '                             **##%  .=.  .:.-: -%#****#. %%##@%.    =#%::::::::..            ...#*      :..:+  +#-:+#= *%: ..     +#  +++++==---=+    +#*#%%%',
--     '                             +##**  :-. ++..=  #%*:.:++ #%%*@@..    %#:--::::::....         .....##     :**:*:  =+*%%%%%  ::     . :+  =--=:     ..::=',
--     '                            *+#**.  +-:.%*  .  %###**+  +==#@*:..  =@--=-:::::::. ..      .... .::%* ..  %#%#+:        - .--:. .::  %  . .=+:..:-',
--     '                            #*#*+  .#*##@*  .  @%#*=#+.+%#+@%+---  #%:===-::::::::::......::::::::%%     --=    .      = .:::::==+ :@: #*******#',
--     '                         #  #*#*+ :#+  -@@@=:  @%@@%%+:#%%#@# ::- -##:-==--:::::::::::::::::::::::%%-  ..:.#*#**##*####%% . .::-=--@#  #%###***###',
--     '                         #****##%- -#- .   =%%%@%%%@@%*=:.  #.--= .#%.-==--:::::::::::::::::::-=+-%%- :+%%%@@%---::-=+**@@*:...:=%* :*#%%%%',
--     '                            ##*:+%# :-:      :  +=:  -      *.+=+  *%.:::::::::::::::::::--:===++=@#  :: *@%%@==%@@@@@@%%%*==+%+: +#%@@%%%',
--     '                     *****####+.-# .-:.    .. *      .    =#@.+++= +%- ...::::::-----===++++++*+=*@= .:: @@%%% .#%##%%%+:*#%@@@++#@%-@@#%%%*',
--     '             %%###*#++=***++=++..+ :=-::.:::: =%*####%%@%#*+#++#%#+ :*-    ..:::::--==+++=*****=+@*  :::%@%#%+  #*+++**    .=%@%: -::@@#%%#',
--     '                  *=:   :+-:  .::%-:-=--::::=.@*+==+%##%%@@@@@%-***   +.   .:::::::-===++****+:*@+ .:--+@@+#%: -#-::---     =*#  .  =@@+#%*',
--     '              -::....   .-==::+=:#@=.:::.:::-%%@@@@@@@%*:=@%%%@-+***-  =+.  .::::---==+++*++:-%%   .:-*%@%#%#  ##+++++      ==:  -  #@#=#',
--     '        ##**#       ++==**+*###*+: +@#-..-#%+*@+*@%#++**. =#**%@+-***+  +++-  .::::::---:::+%%:  = ..*+  %%#  ##=-***=      .:   .  %@+***#%',
--     '                  ###*****#%%#%@%*+*+=:.:%##%=+-.+#++-=-:  .*#%%@# =++#-.   ##+=:.....-+#%%+      :#%      -+*%#*##*#      **=  *  :@%*##    %%%@',
--     '                   ####*=+   % %%@@@%##*+@@#:-:=  #*+.  .-: :%##%#%#+*===-=    .:=+*+=: :   .:-.:=##*#-      :%%%= **..   *#%  -   @@###   #%',
--     '                              %#%%@+-*#%+.#%#.::=  -:=-:=*#+=+%=-=   #%=:===--+:         +::.. *#%@@@*+#=    : :*:-    :+%%% ..=. *@%#*%',
--     '                           %##%%%#%@::*#-  +#*+  :  %##*-###@-.=    %*#@@#*-.*-.. *-.  . ::**+=%@@@@@@@*=+#    =  ..      =  #%..:@@####+*%',
--     '                        @%# @%% %#*%%..+*   *+-::.-: +%%%%%=.:    *=*%@@@@@%#**+=**::-+#+**#%@@%%#+#%%%%@#-+*-= ::.     . .%  %*.%@%%#%    ###%',
--     '                              ##%%*+%% .=-   =##.::-*#  %+.-.    =+*@%%%#%%%@@@@@%#*::+*@@%%#######..-*%@@@#*% :--:.   .:. %  #+#@%%#% %       @@@',
--     '                               *# %-=%# .:    =%@#%*      =    *..%#*#%#%%%%##%#%@+#  -:*%%#=*##+ ::..#%###%%% ----:::-=+- %: -@@@%%##',
--     '                                ##%#:-%# .-.:=#-.= ::.       ==.+@@@%**+=+#%%###%@-#     @%%=    .*##+-##%@%-#=...:::-===.+@+ .@@%%%  ##%',
--     '                                 **%*:-%%  **-.*% --:.     . :#%@#*%%%%#*-..   .=%=+     *=   -###+###%%@*-@%*##.....::.:##  -.%@@%%     %%',
--     '                                 #*#%@*+@@- %=:*=::=::. ..::..%=@%%%++%%%#*+#+:.-%*++    -@%##*=###*%%#   : %@@#*#%++*%@#  -**@@@%%         @',
--     '                               #%  ##%%%*%@%#.-##.-==-:----- ++=@+@%######+.=#%%%@#+@==%%##%####*%%*    .    -@%=++..==  +*=@@@%%%#%',
--     '                            %%#   @ %%%%@##@@.-*@*.:..::::::=*+%#-    *%####%%%@:*@  .     .  *#        .. =%@@%*%@%+=+++#@@@@%%@',
--     '                          %%         %#%#@%#@=*= .%+:. ...=##@@@:.          :*@  - -:        :  %:      .*%%%*:--==*%@@@@@@@%%%',
--     '                                     %#%%%@@@@%=--: :%%%%*.=*#@@*.   .     -=%*+@ :::.    .: =  .#   .+*##*: ---.=#*%@@@@@%%###        ####%',
--     '                                    %%%@%##%@@@@%=...  :-=+#@*%@%#-.-.      :+ -#.:--:::::== -#  @***=*+ .:::  ***@@@@@%%%#####**+     #####              @*+*#%@',
--     '                                  %%     %%%%@@@@%%*.  +=#@=++=-::=**#####+=*+.-@:=:::::-===.#% -#%-   .:: .+**%@@@%%%%%%##*-*-.:-==+****     %#=...:=+*#%%@@',
--     '                                %%      @%%@%%%%@@@@%%+%@%#%%#-::-::  .=*#%@@#-:+%...    .--@*.=+@:..   -***%@@@@@%%%##+===****+++++=-:......-*%%%%%#+=.   #',
--     '                                            %%%%%#%@@@@@@@@@%*####- .-:::::-=##+:.#@%=..=%@@:.+#@#  *##*#@@@@@%%#####*###*+=-.      .=##%%%%%+            #  %',
--     '                                            #%%#%%%%%%@%%%%%%@@@%*=*###***-.  *@*++-.     :-++*@@#*#%@@@@%%%%###+.        ....:-+*#*-      =%.         -+%%',
--     '                                               #%##%%%##%%%%%%%%@@@@@%#***#*##%%@@#+-+*******%@@@@@@@@%#*+-::.:-=*#######+-.:##             #:    %%%%%#=*%',
--     '                                         #       ##**##*#####%%%%%%@@@%@@@@@@@@@@@@@@@@@@@@@@@@%%#**###%%%%%#+=:+%*.          *=       -    #-           *%',
--     '                                               * *++===-==+**##=..-*%%%@@@@@@@@@@@@@@@@@%%##%%%@@@@@%+          %             *=    ###%    #=         .+%',
--     '                                            **+====::     .:=*%%%%%%*+=+++**####%%%%%%@@@@@#%@@@@%+            #%    =#%%%    *+            %+   .#%%%%*-  .#%',
--     '                                         #*:.......:::::-==-:     .-*#####%%@@@@@%*-.       %%%%@+      .+%%%%@%%    %%%%%    +*      ... *%%+ ...  ..::::.+%',
--     '                                  ++*-..=##*=-.    =+.    .+####%%%@@@@@@@*   .@=          -%%%%%+    -@%%%%%%%%%    #%%#%  . +% ...## ::: ##* ::::::::.. +% #####%%@',
--     '                           #*+*###%%+...    ......***##%@@@@@@%%+=    %%%%-    %     =**#%%%%%%%%*    :%%%#####%%    *%%%# ...=% :..#%#:.::.=*   .=*##%%%@     %@%',
--     '                    #######-:.........::::-=+#%#%%%%%%%@%%%*    %-    %%%%+    %    *=:    =%%%%%#    .%%%%%%%%%% ...     .::.*% ::.## #=:-+#%%##% %#**#####',
--     '                  #+-:.....-=****#%%%%%%%%%#+-. #      -%%*    #@=    %%%%#    %             %@@@%  .. %%#+=:   %..:::::::.. =%%++#%%    %+:===-=+#',
--     '            %#=:-*%%%%@@@@@%%#-   *%#:          %%#      -    %%@+    %%@%%    @%:   :+#%    *@@@@ .::. .::::::.%%.    -%%%%@%#**#%+   .--=+++##',
--     '      @%%##   %%@@%=   #%%%%%.    -#           -%%##:        %%%%#    %%@@%    %@@@@@%%+.    *%%%%* :----..  .-+%%%%%#%%%+:       . .:=+=#@',
--     '             %#.        :%%%%+    .%    -#%%%%%%%%####      #@%%%%    %%%@%    %:           =%%%%##%+-+#@@@@@@@@%#*          .:=#%',
--     '               ##         #%%*     %           =%%%##%       .@@@%    -        @         .#%%%%%   #%%%%@%%.    .*    .*%#   #%%##%',
--     '               ##          .%%     %          .%%%%#%          +@%            %@%%%%@@%%%%%%%%%%   %#+==#%##+*   ##  ####%',
--     '               #%     .      +     %.   :%%%%%%%%%%%     %%.     %%   .:-+#@@@@@@@@*=#####% %%%%#%',
--     '                %     @#           %-    :       #%     %%%%*  .+#@@@@@@@@%#+:.    .@',
--     '                %     #%%=         #+           +*   .*%%%%%%@%%%@@@%#*+=#*=.:=#@@',
--     '                %     +%##%        *#      .=++*#***#####=.. .:-#+=:.:=+*#@@  %%%%',
--     '                %:    -%%#%%#  .   +%*%%%##*+=:.     ...:=++***%%@@% %#%%%%%@',
--     '               %%= .. .%#%% %%#%%%%%#*+-.        .:-*#####%     @%%%',
--     '                #+   .@%%%%%%#*=-::=+*##***++++==++*',
--     '          %=--:-=#-#%%%########%      ##***',
--     '      @@%       %%%%%%                =',
--     '                             *',
-- }





--- Print the banner, unless the operator has turned it off.
---
--- Configurable because Nexus Core is a distributable framework (ADR-0018), and
--- an operator running someone else's framework may reasonably not want its logo
--- in their console every restart.
local function printBanner()
    if not NxcCore.Config.get('nxc_core.startup.banner') then return end

    print('')
    for _, line in ipairs(BANNER) do
        print('^4' .. line .. '^7')
    end
    print(('^7  %s  v%s   contract v%d   %s^7')
        :format(('-'):rep(30), NxcCore.VERSION, NxcCore.CONTRACT_VERSION, ('-'):rep(29)))
    print('')
end

--- Stop the framework with an explanation an operator can act on.
local function halt(headline, err)
    ready = false
    failure = err
    print('^1')
    print('^1========================================================================^7')
    print('^1 NEXUS CORE DID NOT START^7')
    print('^1========================================================================^7')
    print('^1 ' .. headline .. '^7')
    if err and err.details and err.details.fields then
        print('^1' .. NxcCore.Bootstrap.explain(err) .. '^7')
    elseif err and err.message then
        print('^1 ' .. tostring(err.message) .. '^7')
        if err.details and err.details.reason then
            print('^1 ' .. tostring(err.details.reason) .. '^7')
        end
    end
    print('^1========================================================================^7')
    print('^1')

    if Nxc.Health then Nxc.Health.fail(headline) end
end

CreateThread(function()
    -- oxmysql is a dependency, so it has started; but its connection is
    -- established asynchronously and may not be ready in the same tick.
    Wait(0)

    printBanner()

    ------------------------------------------------------- 0. library contract
    -- Every resource loads its OWN copy of nxc_lib, so the copy running inside
    -- nxc_core is whichever was on disk when nxc_core was last deployed. Nothing
    -- keeps two resources on the same version.
    --
    -- THIS IS A SAFETY NET, NOT THE MECHANISM. What prevents mismatched versions
    -- is installing a compatibility set — one verified bundle — rather than
    -- individual resources. An operator should never meet this message. When
    -- they do, it means the set was broken by hand, so the message has to be
    -- actionable by someone who did not write any of this.
    --
    -- BOUNDED AT BOTH ENDS. A minimum alone is wrong: CONTRACT_VERSION is
    -- incremented on INCOMPATIBLE change, so a newer nxc_lib is not
    -- automatically safer — contract 2 would satisfy `>= 1` and then break at
    -- whatever it removed.
    local LIB_CONTRACT_MIN, LIB_CONTRACT_MAX = 1, 1

    local function versionAdvice(problem, detail)
        return {
            message = problem,
            details = {
                reason = detail .. '\n'
                    .. '\n  Nexus Core resources are released together as a compatibility set:'
                    .. '\n  a bundle of versions verified against each other. Installing or'
                    .. '\n  updating one resource on its own is what produces this.'
                    .. '\n'
                    .. '\n  To fix it, reinstall the set rather than chasing individual'
                    .. '\n  resources. Run `nxc_versions` in this console to see what you have.',
            },
        }
    end

    if type(Nxc) ~= 'table' or not Nxc.CONTRACT_VERSION then
        return halt('nxc_lib is missing, or too old to identify itself.', versionAdvice(
            'nxc_core needs nxc_lib, and cannot find a usable one.',
            ('  installed nxc_lib   %s\n  required contract  v%d')
                :format(type(Nxc) == 'table' and tostring(Nxc.VERSION) or 'not installed',
                        LIB_CONTRACT_MIN)))
    end

    if Nxc.CONTRACT_VERSION < LIB_CONTRACT_MIN then
        return halt('nxc_lib is older than this nxc_core supports.', versionAdvice(
            'UPDATE NXC_LIB. It is the resource that is behind.',
            ('  installed nxc_lib   v%s  (contract v%d)\n  this nxc_core       v%s  (needs contract v%d)')
                :format(tostring(Nxc.VERSION), Nxc.CONTRACT_VERSION,
                        NxcCore.VERSION, LIB_CONTRACT_MIN)))
    end

    if Nxc.CONTRACT_VERSION > LIB_CONTRACT_MAX then
        return halt('nxc_core is older than the installed nxc_lib.', versionAdvice(
            'UPDATE NXC_CORE. This time it is nxc_core that is behind, not the library.',
            ('  installed nxc_lib   v%s  (contract v%d)\n  this nxc_core       v%s  (supports up to contract v%d)')
                :format(tostring(Nxc.VERSION), Nxc.CONTRACT_VERSION,
                        NxcCore.VERSION, LIB_CONTRACT_MAX)))
    end

    ------------------------------------------------------------------ 1. environment
    local env = NxcCore.Bootstrap.validate(function(name, default)
        return GetConvar(name, default or '')
    end)
    if not env.ok then
        return halt('The server is not configured correctly.', env.error)
    end
    local settings = env.value

    -- Name ourselves before logging anything. nxc_lib's modules run inside this
    -- resource's own Lua state, so without this every line below claims to come
    -- from nxc_lib.
    Nxc.Logger.setResource(NxcCore.RESOURCE)
    Nxc.Logger.setLevel(settings.nxc_log_level)
    Nxc.Logger.setEnvironment(settings.nxc_environment)
    Nxc.Logger.info('startup.environment_valid', {
        environment = settings.nxc_environment,
        serverBuild = settings.nxc_server_build,
        startupMode = settings.nxc_startup_mode,
    })

    ------------------------------------------------------------------ 2. database
    local reachable, pingErr = NxcCore.MariaDBProvider.ping()
    if not reachable then
        return halt('The database is unreachable.', {
            message = 'nxc_core cannot run without its database.',
            details = { reason = pingErr },
        })
    end

    NxcCore.Persistence.setProvider(NxcCore.MariaDBProvider)
    NxcCore.Accounts.setProvider(NxcCore.Persistence.scoped(NxcCore.RESOURCE))
    Nxc.Logger.info('startup.database_ready', {})

    -------------------------------------------------------- 2b. signing key
    -- After the database, because the entropy comes from it.
    local decided = NxcCore.Tokens.decide(
        GetConvar('nxc_token_signing_key', ''),
        function() return NxcCore.MariaDBProvider.randomHex(32) end)
    if not decided.ok then
        return halt('The token signing key could not be established.', decided.error)
    end
    NxcCore.Tokens.install(decided.value.key, decided.value.source)

    -- The SOURCE is logged. The key never is, at any level, in any environment.
    Nxc.Logger.info('startup.signing_key_ready', { source = decided.value.source })

    ------------------------------------------------------------------ 3. migrations
    if NxcCore.Config.get('nxc_core.migrations.applyOnStart') then
        local migrated = NxcCore.Migrator.run(NxcCore.MariaDBProvider)
        if not migrated.ok then
            return halt('A database migration failed.', migrated.error)
        end
        if #migrated.value.applied > 0 then
            Nxc.Logger.info('startup.migrations_applied', {
                count = #migrated.value.applied,
                migrations = migrated.value.applied,
            })
        end
    else
        Nxc.Logger.warn('startup.migrations_skipped', {
            detail = 'nxc_core.migrations.applyOnStart is false; the schema may be behind',
        })
    end

    ------------------------------------------------------------------ 4. open
    NxcCore.Services.register({
        name = NxcCore.RESOURCE,
        contractVersion = NxcCore.CONTRACT_VERSION,
        version = NxcCore.VERSION,
        capabilities = { 'sessions', 'accounts', 'capabilities', 'buckets', 'persistence' },
    })
    NxcCore.Services.setState(NxcCore.RESOURCE, NxcCore.Services.STATE.READY)

    ready = true
    failure = nil

    Nxc.Logger.info('startup.ready', {
        version = NxcCore.VERSION,
        contractVersion = NxcCore.CONTRACT_VERSION,
        serverBuild = settings.nxc_server_build,
    })
    print(('^2[nxc_core]^7 ready — v%s, contract v%d, Cfx Server build %s')
        :format(NxcCore.VERSION, NxcCore.CONTRACT_VERSION, tostring(settings.nxc_server_build)))

    TriggerEvent('nxc_core:server:ready', {
        version = NxcCore.VERSION,
        contractVersion = NxcCore.CONTRACT_VERSION,
    })
end)

--- `nxc_status` — what is actually true right now.
---
--- Console only. It reports internal state, and MDD 38.8 forbids exposing
--- development tooling globally in production.
RegisterCommand('nxc_status', function(source)
    if source ~= 0 then return end

    print(('^5[nxc_core]^7 %s'):format(ready and '^2ready^7' or '^1NOT READY^7'))
    if failure then
        print(('  failure: %s'):format(tostring(failure.message or failure)))
    end
    print(('  version           %s (contract v%d)'):format(NxcCore.VERSION, NxcCore.CONTRACT_VERSION))
    print(('  sessions open     %d'):format(NxcCore.Sessions.count()))
    print(('  persistence       %s'):format(NxcCore.Persistence.isReady() and 'ready' or 'unavailable'))
    print(('  signing key       %s'):format(
        NxcCore.Tokens.isReady() and (NxcCore.Tokens.source() .. ', rotates on restart') or 'not set'))
    print(('  buckets allocated %d'):format(NxcCore.Buckets.count()))
    print('  configuration:')
    for key, value in pairs(NxcCore.Config.snapshot()) do
        print(('    %-38s %s'):format(key, tostring(value)))
    end
end, true)

--- `nxc_versions` — what is actually installed.
---
--- The first question in any support conversation, and one an operator cannot
--- currently answer without opening files. Every Nexus resource declares
--- `nxc_platform` in its manifest, which makes them enumerable.
---
--- Console only, like `nxc_status`.
RegisterCommand('nxc_versions', function(source)
    if source ~= 0 then return end

    print('^5[nxc_core]^7 installed Nexus Core resources:')
    print(('  %-18s %-10s %-16s %s'):format('RESOURCE', 'VERSION', 'MIN SERVER BUILD', 'STATE'))

    local found = 0
    for i = 0, GetNumResources() - 1 do
        local name = GetResourceByFindIndex(i)
        if name and GetResourceMetadata(name, 'nxc_platform', 0) then
            found = found + 1
            print(('  %-18s %-10s %-16s %s'):format(
                name,
                GetResourceMetadata(name, 'version', 0) or '?',
                GetResourceMetadata(name, 'nxc_min_server_build', 0) or '?',
                GetResourceState(name)))
        end
    end

    if found == 0 then
        print('  none found, which should be impossible from inside one of them')
    end

    print(('  nxc_lib contract    v%s'):format(tostring(Nxc.CONTRACT_VERSION)))
    print(('  nxc_core contract   v%d'):format(NxcCore.CONTRACT_VERSION))
    print('')
    print('  These are released together as a compatibility set. If they did not all')
    print('  come from the same one, that is worth fixing before anything else.')
end, true)

NxcCore.Startup = Startup
return Startup
