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
-- local BANNER = {
--     '  ##   ## ###### ##   ## ##   ##  #####      #####  #####  ######  ######',
--     '  ###  ## ##      ## ##  ##   ## ##         ##     ##   ## ##   ## ##',
--     '  ## # ## #####    ###   ##   ##  ####      ##     ##   ## ######  #####',
--     '  ##  ### ##      ## ##  ##   ##     ##     ##     ##   ## ##  ##  ##',
--     '  ##   ## ###### ##   ##  #####  #####       #####  #####  ##   ## ######',
-- }




local BANNER = {
    '                                                                           %++++====*#',
    '                                                                        *@+ ::::..:-  %%%%%#**',
    '                                                                  %%%=  :+ *#:.     *  *        =#%#++',
    '                                                            %@%#+.     *@-*=::     . =  #            =#*+=#',
    '                                                         %%@#    -    =@=*%:-::. .:::.#=+%#-       .     +#=:=+=+',
    '                                                     %%@@=  .-     +#: :.=%:--::::--.+= %- -##***+          -*..+',
    '                                                  ##%@*: --    =%###*. :#.**.::...::+#=+@        .=---        :###%#         %%',
    '                                                ##%%+.:+.   #%## -      .*#%@#.  .+%%#+%-         .  .+*#   +%*.    =##     #',
    '                                             ***%@=..+. .#%%%=   :   ..  -@@@##-  ++%@@@@%*.   .        +%@=  .##*%*   %####  %',
    '                                           .=#%-.:+@%%#%%%-       . =##%@@@@@*+:  +:*%%%%%%%@@@#=        *=## .      *-  %# #%  %%',
    '                                          *#%  ==:     ##  .    =%%%@@@%##*#@. :  - =#*#**===+#%%%%#=.  @+=-.:.     . #  #%%%%##  %%',
    '                            @       #*   #%. ##.     -#  *.  +#%@@#++-=###*%%+ :.:- ****+**+****--*%%%@@-=%.:-:....:::#  #%%**##%%',
    '                            @@%%%     **%- *%.=:.    .    @%%@@@##*.-*###%#-.*%#  .##       ==-:=+++=%@%#%@.:::::-=++:%. # -#**#',
    '                              %%%#*+%##%# -#:-=-:   .:- #%@@@@%######*=:..  :+##.  *###+-       .=++*#%=-==+.  .::--:%#+=*  :##=*',
    '                                %%##=*#@%::#--==-::::--.@:  *%%#%##+:-::=%%%##++:  *#**++==---.    -#       #=...:-#%=.#%.    ##=*',
    '                             %%%  %###%-%=:=@----:::.: *:-#   =%%=---%###:####**-   :.-*+=+=-==-*# : :+   ++--%@#: .%#%@=      ##-+',
    '                        @@   @% %###%% -*@.+#%*:.. ..=%=    ++   *#%%#####-         :        ++**###+ . :-.-%@@@%%%#=  =#.     .##:#',
    '                          @%%%@%####%::=%@@%*++*#%*@@%+=+=    -#:#%%###.       . ..:+.          -*#    -:=@@@*#%%*:.    -.      =#%:*',
    '                              %####%-.-*--+@@@@#++=%@@@#.  #    :%%#*-      ++*#**+++++**=:.      :  --#%%*##*****+      +*      %%*+',
    '                               #%##+.:+=-:@#++**+%@%##%#%@@#+:+    :    .+%%=.. .         .#%-.     +%%%#*  -++++++.      ++  =   %%-#',
    '                              ##%#%..:*:.+%=:-+:*%#..+*#*:+%@%#=+.:.   +%*..:::..            -*-     .%++++   :.:-*#      +##  -*+%%%=#',
    '                              *###* .*.. ##..-..%##***** -%%*#%#---. .##:::::::..             .**      *-::.   :-=**#    :%*--=.    :+**    ++++**',
    '                             **##%  .=.  .:.-: -%#****#. %%##@%.    =#%::::::::..            ...#*      :..:+  +#-:+#= *%: ..     +#  +++++==---=+    +#*#%%%',
    '                             +##**  :-. ++..=  #%*:.:++ #%%*@@..    %#:--::::::....         .....##     :**:*:  =+*%%%%%  ::     . :+  =--=:     ..::=',
    '                            *+#**.  +-:.%*  .  %###**+  +==#@*:..  =@--=-:::::::. ..      .... .::%* ..  %#%#+:        - .--:. .::  %  . .=+:..:-',
    '                            #*#*+  .#*##@*  .  @%#*=#+.+%#+@%+---  #%:===-::::::::::......::::::::%%     --=    .      = .:::::==+ :@: #*******#',
    '                         #  #*#*+ :#+  -@@@=:  @%@@%%+:#%%#@# ::- -##:-==--:::::::::::::::::::::::%%-  ..:.#*#**##*####%% . .::-=--@#  #%###***###',
    '                         #****##%- -#- .   =%%%@%%%@@%*=:.  #.--= .#%.-==--:::::::::::::::::::-=+-%%- :+%%%@@%---::-=+**@@*:...:=%* :*#%%%%',
    '                            ##*:+%# :-:      :  +=:  -      *.+=+  *%.:::::::::::::::::::--:===++=@#  :: *@%%@==%@@@@@@%%%*==+%+: +#%@@%%%',
    '                     *****####+.-# .-:.    .. *      .    =#@.+++= +%- ...::::::-----===++++++*+=*@= .:: @@%%% .#%##%%%+:*#%@@@++#@%-@@#%%%*',
    '             %%###*#++=***++=++..+ :=-::.:::: =%*####%%@%#*+#++#%#+ :*-    ..:::::--==+++=*****=+@*  :::%@%#%+  #*+++**    .=%@%: -::@@#%%#',
    '                  *=:   :+-:  .::%-:-=--::::=.@*+==+%##%%@@@@@%-***   +.   .:::::::-===++****+:*@+ .:--+@@+#%: -#-::---     =*#  .  =@@+#%*',
    '              -::....   .-==::+=:#@=.:::.:::-%%@@@@@@@%*:=@%%%@-+***-  =+.  .::::---==+++*++:-%%   .:-*%@%#%#  ##+++++      ==:  -  #@#=#',
    '        ##**#       ++==**+*###*+: +@#-..-#%+*@+*@%#++**. =#**%@+-***+  +++-  .::::::---:::+%%:  = ..*+  %%#  ##=-***=      .:   .  %@+***#%',
    '                  ###*****#%%#%@%*+*+=:.:%##%=+-.+#++-=-:  .*#%%@# =++#-.   ##+=:.....-+#%%+      :#%      -+*%#*##*#      **=  *  :@%*##    %%%@',
    '                   ####*=+   % %%@@@%##*+@@#:-:=  #*+.  .-: :%##%#%#+*===-=    .:=+*+=: :   .:-.:=##*#-      :%%%= **..   *#%  -   @@###   #%',
    '                              %#%%@+-*#%+.#%#.::=  -:=-:=*#+=+%=-=   #%=:===--+:         +::.. *#%@@@*+#=    : :*:-    :+%%% ..=. *@%#*%',
    '                           %##%%%#%@::*#-  +#*+  :  %##*-###@-.=    %*#@@#*-.*-.. *-.  . ::**+=%@@@@@@@*=+#    =  ..      =  #%..:@@####+*%',
    '                        @%# @%% %#*%%..+*   *+-::.-: +%%%%%=.:    *=*%@@@@@%#**+=**::-+#+**#%@@%%#+#%%%%@#-+*-= ::.     . .%  %*.%@%%#%    ###%',
    '                              ##%%*+%% .=-   =##.::-*#  %+.-.    =+*@%%%#%%%@@@@@%#*::+*@@%%#######..-*%@@@#*% :--:.   .:. %  #+#@%%#% %       @@@',
    '                               *# %-=%# .:    =%@#%*      =    *..%#*#%#%%%%##%#%@+#  -:*%%#=*##+ ::..#%###%%% ----:::-=+- %: -@@@%%##',
    '                                ##%#:-%# .-.:=#-.= ::.       ==.+@@@%**+=+#%%###%@-#     @%%=    .*##+-##%@%-#=...:::-===.+@+ .@@%%%  ##%',
    '                                 **%*:-%%  **-.*% --:.     . :#%@#*%%%%#*-..   .=%=+     *=   -###+###%%@*-@%*##.....::.:##  -.%@@%%     %%',
    '                                 #*#%@*+@@- %=:*=::=::. ..::..%=@%%%++%%%#*+#+:.-%*++    -@%##*=###*%%#   : %@@#*#%++*%@#  -**@@@%%         @',
    '                               #%  ##%%%*%@%#.-##.-==-:----- ++=@+@%######+.=#%%%@#+@==%%##%####*%%*    .    -@%=++..==  +*=@@@%%%#%',
    '                            %%#   @ %%%%@##@@.-*@*.:..::::::=*+%#-    *%####%%%@:*@  .     .  *#        .. =%@@%*%@%+=+++#@@@@%%@',
    '                          %%         %#%#@%#@=*= .%+:. ...=##@@@:.          :*@  - -:        :  %:      .*%%%*:--==*%@@@@@@@%%%',
    '                                     %#%%%@@@@%=--: :%%%%*.=*#@@*.   .     -=%*+@ :::.    .: =  .#   .+*##*: ---.=#*%@@@@@%%###        ####%',
    '                                    %%%@%##%@@@@%=...  :-=+#@*%@%#-.-.      :+ -#.:--:::::== -#  @***=*+ .:::  ***@@@@@%%%#####**+     #####              @*+*#%@',
    '                                  %%     %%%%@@@@%%*.  +=#@=++=-::=**#####+=*+.-@:=:::::-===.#% -#%-   .:: .+**%@@@%%%%%%##*-*-.:-==+****     %#=...:=+*#%%@@',
    '                                %%      @%%@%%%%@@@@%%+%@%#%%#-::-::  .=*#%@@#-:+%...    .--@*.=+@:..   -***%@@@@@%%%##+===****+++++=-:......-*%%%%%#+=.   #',
    '                                            %%%%%#%@@@@@@@@@%*####- .-:::::-=##+:.#@%=..=%@@:.+#@#  *##*#@@@@@%%#####*###*+=-.      .=##%%%%%+            #  %',
    '                                            #%%#%%%%%%@%%%%%%@@@%*=*###***-.  *@*++-.     :-++*@@#*#%@@@@%%%%###+.        ....:-+*#*-      =%.         -+%%',
    '                                               #%##%%%##%%%%%%%%@@@@@%#***#*##%%@@#+-+*******%@@@@@@@@%#*+-::.:-=*#######+-.:##             #:    %%%%%#=*%',
    '                                         #       ##**##*#####%%%%%%@@@%@@@@@@@@@@@@@@@@@@@@@@@@%%#**###%%%%%#+=:+%*.          *=       -    #-           *%',
    '                                               * *++===-==+**##=..-*%%%@@@@@@@@@@@@@@@@@%%##%%%@@@@@%+          %             *=    ###%    #=         .+%',
    '                                            **+====::     .:=*%%%%%%*+=+++**####%%%%%%@@@@@#%@@@@%+            #%    =#%%%    *+            %+   .#%%%%*-  .#%',
    '                                         #*:.......:::::-==-:     .-*#####%%@@@@@%*-.       %%%%@+      .+%%%%@%%    %%%%%    +*      ... *%%+ ...  ..::::.+%',
    '                                  ++*-..=##*=-.    =+.    .+####%%%@@@@@@@*   .@=          -%%%%%+    -@%%%%%%%%%    #%%#%  . +% ...## ::: ##* ::::::::.. +% #####%%@',
    '                           #*+*###%%+...    ......***##%@@@@@@%%+=    %%%%-    %     =**#%%%%%%%%*    :%%%#####%%    *%%%# ...=% :..#%#:.::.=*   .=*##%%%@     %@%',
    '                    #######-:.........::::-=+#%#%%%%%%%@%%%*    %-    %%%%+    %    *=:    =%%%%%#    .%%%%%%%%%% ...     .::.*% ::.## #=:-+#%%##% %#**#####',
    '                  #+-:.....-=****#%%%%%%%%%#+-. #      -%%*    #@=    %%%%#    %             %@@@%  .. %%#+=:   %..:::::::.. =%%++#%%    %+:===-=+#',
    '            %#=:-*%%%%@@@@@%%#-   *%#:          %%#      -    %%@+    %%@%%    @%:   :+#%    *@@@@ .::. .::::::.%%.    -%%%%@%#**#%+   .--=+++##',
    '      @%%##   %%@@%=   #%%%%%.    -#           -%%##:        %%%%#    %%@@%    %@@@@@%%+.    *%%%%* :----..  .-+%%%%%#%%%+:       . .:=+=#@',
    '             %#.        :%%%%+    .%    -#%%%%%%%%####      #@%%%%    %%%@%    %:           =%%%%##%+-+#@@@@@@@@%#*          .:=#%',
    '               ##         #%%*     %           =%%%##%       .@@@%    -        @         .#%%%%%   #%%%%@%%.    .*    .*%#   #%%##%',
    '               ##          .%%     %          .%%%%#%          +@%            %@%%%%@@%%%%%%%%%%   %#+==#%##+*   ##  ####%',
    '               #%     .      +     %.   :%%%%%%%%%%%     %%.     %%   .:-+#@@@@@@@@*=#####% %%%%#%',
    '                %     @#           %-    :       #%     %%%%*  .+#@@@@@@@@%#+:.    .@',
    '                %     #%%=         #+           +*   .*%%%%%%@%%%@@@%#*+=#*=.:=#@@',
    '                %     +%##%        *#      .=++*#***#####=.. .:-#+=:.:=+*#@@  %%%%',
    '                %:    -%%#%%#  .   +%*%%%##*+=:.     ...:=++***%%@@% %#%%%%%@',
    '               %%= .. .%#%% %%#%%%%%#*+-.        .:-*#####%     @%%%',
    '                #+   .@%%%%%%#*=-::=+*##***++++==++*',
    '          %=--:-=#-#%%%########%      ##***',
    '      @@%       %%%%%%                =',
    '                             *',
}





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
        :format(('-'):rep(18), NxcCore.VERSION, NxcCore.CONTRACT_VERSION, ('-'):rep(18)))
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
    print(('  buckets allocated %d'):format(NxcCore.Buckets.count()))
    print('  configuration:')
    for key, value in pairs(NxcCore.Config.snapshot()) do
        print(('    %-38s %s'):format(key, tostring(value)))
    end
end, true)

NxcCore.Startup = Startup
return Startup
