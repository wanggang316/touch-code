function __tc_should_offer_completions_for_flags_or_options -a expected_commands
    set -l non_repeating_flags_or_options $argv[2..]

    set -l non_repeating_flags_or_options_absent 0
    set -l positional_index 0
    set -l commands
    __tc_parse_tokens
    test "$commands" = "$expected_commands"; and return $non_repeating_flags_or_options_absent
end

function __tc_should_offer_completions_for_positional -a expected_commands expected_positional_index positional_index_comparison
    if test -z $positional_index_comparison
        set positional_index_comparison -eq
    end

    set -l non_repeating_flags_or_options
    set -l non_repeating_flags_or_options_absent 0
    set -l positional_index 0
    set -l commands
    __tc_parse_tokens
    test "$commands" = "$expected_commands" -a \( "$positional_index" "$positional_index_comparison" "$expected_positional_index" \)
end

function __tc_parse_tokens -S
    set -l unparsed_tokens (__tc_tokens -pc)
    set -l present_flags_and_options

    switch $unparsed_tokens[1]
    case 'tc'
        __tc_parse_subcommand 0 'version' 'h/help'
        switch $unparsed_tokens[1]
        case 'system'
            __tc_parse_subcommand 0 'version' 'h/help'
            switch $unparsed_tokens[1]
            case 'ping'
                __tc_parse_subcommand 0 'json' 'socket=' 'timeout=' 'version' 'h/help'
            case 'version'
                __tc_parse_subcommand 0 'json' 'socket=' 'timeout=' 'version' 'h/help'
            case 'status'
                __tc_parse_subcommand 0 'json' 'socket=' 'timeout=' 'version' 'h/help'
            case 'quit'
                __tc_parse_subcommand 0 'json' 'socket=' 'timeout=' 'version' 'h/help'
            case 'sockets'
                __tc_parse_subcommand 0 'json' 'socket=' 'timeout=' 'version' 'h/help'
            case 'launch'
                __tc_parse_subcommand 0 'json' 'socket=' 'timeout=' 'wait-seconds=' 'bundle=' 'version' 'h/help'
            case 'completions'
                __tc_parse_subcommand 1 'version' 'h/help'
            end
        case 'space'
            __tc_parse_subcommand 0 'version' 'h/help'
            switch $unparsed_tokens[1]
            case 'list'
                __tc_parse_subcommand 0 'json' 'socket=' 'timeout=' 'version' 'h/help'
            case 'create'
                __tc_parse_subcommand 1 'json' 'socket=' 'timeout=' 'activate' 'version' 'h/help'
            case 'activate'
                __tc_parse_subcommand 1 'json' 'socket=' 'timeout=' 'version' 'h/help'
            case 'rename'
                __tc_parse_subcommand 2 'json' 'socket=' 'timeout=' 'version' 'h/help'
            case 'remove'
                __tc_parse_subcommand 1 'json' 'socket=' 'timeout=' 'version' 'h/help'
            end
        case 'project'
            __tc_parse_subcommand 0 'version' 'h/help'
            switch $unparsed_tokens[1]
            case 'add'
                __tc_parse_subcommand 0 'json' 'socket=' 'timeout=' 'space=' 'name=' 'path=' 'version' 'h/help'
            case 'list'
                __tc_parse_subcommand 0 'json' 'socket=' 'timeout=' 'space=' 'version' 'h/help'
            case 'remove'
                __tc_parse_subcommand 1 'json' 'socket=' 'timeout=' 'space=' 'version' 'h/help'
            end
        case 'worktree'
            __tc_parse_subcommand 0 'version' 'h/help'
            switch $unparsed_tokens[1]
            case 'activate'
                __tc_parse_subcommand 1 'json' 'socket=' 'timeout=' 'version' 'h/help'
            case 'list'
                __tc_parse_subcommand 0 'json' 'socket=' 'timeout=' 'space=' 'project=' 'version' 'h/help'
            case 'remove'
                __tc_parse_subcommand 1 'json' 'socket=' 'timeout=' 'space=' 'project=' 'version' 'h/help'
            end
        case 'tab'
            __tc_parse_subcommand 0 'version' 'h/help'
            switch $unparsed_tokens[1]
            case 'activate'
                __tc_parse_subcommand 1 'json' 'socket=' 'timeout=' 'version' 'h/help'
            case 'list'
                __tc_parse_subcommand 0 'json' 'socket=' 'timeout=' 'space=' 'project=' 'worktree=' 'version' 'h/help'
            case 'close'
                __tc_parse_subcommand 1 'json' 'socket=' 'timeout=' 'space=' 'project=' 'worktree=' 'version' 'h/help'
            end
        case 'pane'
            __tc_parse_subcommand 0 'version' 'h/help'
            switch $unparsed_tokens[1]
            case 'label'
                __tc_parse_subcommand -r 2 'json' 'socket=' 'timeout=' 'replace' 'version' 'h/help'
            case 'list'
                __tc_parse_subcommand 0 'json' 'socket=' 'timeout=' 'space=' 'project=' 'worktree=' 'tab=' 'version' 'h/help'
            case 'close'
                __tc_parse_subcommand 1 'json' 'socket=' 'timeout=' 'space=' 'project=' 'worktree=' 'tab=' 'version' 'h/help'
            case 'focus'
                __tc_parse_subcommand 1 'json' 'socket=' 'timeout=' 'space=' 'project=' 'worktree=' 'tab=' 'version' 'h/help'
            end
        case 'send'
            __tc_parse_subcommand -r 2 'json' 'socket=' 'timeout=' 'version' 'h/help'
        case 'broadcast'
            __tc_parse_subcommand -r 1 'json' 'socket=' 'timeout=' 'tab=' 'worktree=' 'space=' 'label=' 'version' 'h/help'
        case 'hook'
            __tc_parse_subcommand 0 'version' 'h/help'
            switch $unparsed_tokens[1]
            case 'list'
                __tc_parse_subcommand 0 'json' 'socket=' 'timeout=' 'event=' 'version' 'h/help'
            case 'install'
                __tc_parse_subcommand 1 'json' 'socket=' 'timeout=' 'version' 'h/help'
            case 'remove'
                __tc_parse_subcommand 1 'json' 'socket=' 'timeout=' 'version' 'h/help'
            case 'enable'
                __tc_parse_subcommand 1 'json' 'socket=' 'timeout=' 'version' 'h/help'
            case 'disable'
                __tc_parse_subcommand 1 'json' 'socket=' 'timeout=' 'version' 'h/help'
            case 'reload'
                __tc_parse_subcommand 0 'json' 'socket=' 'timeout=' 'version' 'h/help'
            case 'test'
                __tc_parse_subcommand 1 'json' 'socket=' 'timeout=' 'payload=' 'version' 'h/help'
            case 'fire'
                __tc_parse_subcommand 0 'json' 'socket=' 'timeout=' 'payload=' 'version' 'h/help'
            case 'recent'
                __tc_parse_subcommand 0 'json' 'socket=' 'timeout=' 'limit=' 'version' 'h/help'
            case 'tail'
                __tc_parse_subcommand 0 'json' 'socket=' 'timeout=' 'idle-timeout=' 'version' 'h/help'
            case 'edit'
                __tc_parse_subcommand 0 'json' 'socket=' 'timeout=' 'version' 'h/help'
            end
        case 'open'
            __tc_parse_subcommand 1 'json' 'socket=' 'timeout=' 'in=' 'version' 'h/help'
        case 'rpc'
            __tc_parse_subcommand 2 'json' 'socket=' 'timeout=' 'version' 'h/help'
        case 'help'
            __tc_parse_subcommand -r 1 'version'
        end
    end
end

function __tc_tokens
    if test (string split -m 1 -f 1 -- . "$FISH_VERSION") -gt 3
        commandline --tokens-raw $argv
    else
        commandline -o $argv
    end
end

function __tc_parse_subcommand -S -a positional_count
    argparse -s r -- $argv
    set -l option_specs $argv[2..]

    set -a commands $unparsed_tokens[1]
    set -e unparsed_tokens[1]

    set positional_index 0

    while true
        argparse -sn "$commands" $option_specs -- $unparsed_tokens 2> /dev/null
        set unparsed_tokens $argv
        set positional_index (math $positional_index + 1)

        for non_repeating_flag_or_option in $non_repeating_flags_or_options
            if set -ql _flag_$non_repeating_flag_or_option
                set non_repeating_flags_or_options_absent 1
                break
            end
        end

        if test (count $unparsed_tokens) -eq 0 -o \( -z "$_flag_r" -a "$positional_index" -gt "$positional_count" \)
            break
        end
        set -e unparsed_tokens[1]
    end
end

function __tc_complete_directories
    set -l token (commandline -t)
    string match -- '*/' $token
    set -l subdirs $token*/
    printf '%s\n' $subdirs
end

function __tc_custom_completion
    set -x SAP_SHELL fish
    set -x SAP_SHELL_VERSION $FISH_VERSION

    set -l tokens (__tc_tokens -p)
    if test -z (__tc_tokens -t)
        set -l index (count (__tc_tokens -pc))
        set tokens $tokens[..$index] \'\' $tokens[(math $index + 1)..]
    end
    command $tokens[1] $argv $tokens
end

complete -c 'tc' -f
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc" 1' -fa 'system' -d 'Utility verbs for talking to the running touch-code app.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc" 1' -fa 'space' -d 'Space-level verbs.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc" 1' -fa 'project' -d 'Project-level verbs.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc" 1' -fa 'worktree' -d 'Worktree-level verbs.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc" 1' -fa 'tab' -d 'Tab-level verbs.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc" 1' -fa 'pane' -d 'Pane-level verbs.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc" 1' -fa 'send' -d 'Send text input to a specific pane (by UUID, @label, or \'current\').'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc" 1' -fa 'broadcast' -d 'Fan-out text to a tab, worktree, space, or label scope.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc" 1' -fa 'hook' -d 'Install, list, fire, and tail lifecycle hooks.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc" 1' -fa 'open' -d 'Open a directory in an external editor (or terminal / git client / Finder).'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc" 1' -fa 'rpc' -d 'Low-level: invoke an arbitrary RPC method. Parses JSON params from argv.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc" 1' -fa 'help' -d 'Show subcommand help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc system" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc system" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc system" 1' -fa 'ping' -d 'Probe the running app; prints \'pong\' on exit 0.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc system" 1' -fa 'version' -d 'Show tc and server versions.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc system" 1' -fa 'status' -d 'Show app runtime status (version, uptime, clients).'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc system" 1' -fa 'quit' -d 'Ask the running app to quit gracefully.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc system" 1' -fa 'sockets' -d 'List discovered socket paths and reachability.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc system" 1' -fa 'launch' -d 'Start the touch-code app if it isn\'t running and wait until its socket is reachable.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc system" 1' -fa 'completions' -d 'Print a shell completion script for tc (bash / zsh / fish).'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc system ping" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc system ping" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc system ping" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc system ping" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc system ping" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc system version" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc system version" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc system version" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc system version" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc system version" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc system status" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc system status" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc system status" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc system status" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc system status" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc system quit" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc system quit" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc system quit" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc system quit" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc system quit" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc system sockets" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc system sockets" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc system sockets" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc system sockets" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc system sockets" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc system launch" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc system launch" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc system launch" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc system launch" wait-seconds' -l 'wait-seconds' -d 'Seconds to wait for the socket to come up after launch.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc system launch" bundle' -l 'bundle' -d 'Bundle name to pass to `open -ga` (default: touch-code).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc system launch" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc system launch" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc system completions" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc system completions" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc space" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc space" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc space" 1' -fa 'list' -d 'List all spaces.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc space" 1' -fa 'create' -d 'Create a new space.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc space" 1' -fa 'activate' -d 'Activate a space by id or \'current\'.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc space" 1' -fa 'rename' -d 'Rename a space by id or \'current\'.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc space" 1' -fa 'remove' -d 'Remove a space (and its projects) by id.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc space list" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc space list" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc space list" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc space list" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc space list" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc space create" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc space create" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc space create" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc space create" activate' -l 'activate' -d 'Activate the new space immediately.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc space create" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc space create" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc space activate" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc space activate" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc space activate" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc space activate" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc space activate" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc space rename" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc space rename" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc space rename" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc space rename" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc space rename" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc space remove" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc space remove" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc space remove" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc space remove" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc space remove" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc project" 1' -fa 'add' -d 'Add an existing directory as a project in a space.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc project" 1' -fa 'list' -d 'List projects in a space (default: current).'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc project" 1' -fa 'remove' -d 'Remove a project from a space.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project add" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project add" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project add" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project add" space' -l 'space' -d 'Space id (UUID or \'current\').' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project add" name' -l 'name' -d 'Display name.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project add" path' -l 'path' -d 'Path on disk to use as the project root.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project add" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project add" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project list" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project list" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project list" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project list" space' -l 'space' -d 'Space id (UUID or \'current\').' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project list" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project list" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project remove" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project remove" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project remove" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project remove" space' -l 'space' -d 'Space id (UUID or \'current\').' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project remove" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project remove" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc worktree" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc worktree" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc worktree" 1' -fa 'activate' -d 'Activate a worktree by id or \'current\'.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc worktree" 1' -fa 'list' -d 'List worktrees in a project.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc worktree" 1' -fa 'remove' -d 'Remove a worktree (clears the hierarchy entry; does not delete on-disk files).'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc worktree activate" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc worktree activate" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc worktree activate" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc worktree activate" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc worktree activate" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc worktree list" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc worktree list" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc worktree list" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc worktree list" space' -l 'space' -d 'Space id (UUID or \'current\').' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc worktree list" project' -l 'project' -d 'Project id (UUID or \'current\').' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc worktree list" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc worktree list" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc worktree remove" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc worktree remove" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc worktree remove" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc worktree remove" space' -l 'space' -d 'Space id (UUID or \'current\').' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc worktree remove" project' -l 'project' -d 'Project id (UUID or \'current\').' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc worktree remove" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc worktree remove" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tab" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tab" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc tab" 1' -fa 'activate' -d 'Activate a tab by id or \'current\'.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc tab" 1' -fa 'list' -d 'List tabs in a worktree.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc tab" 1' -fa 'close' -d 'Close a tab.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tab activate" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tab activate" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tab activate" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tab activate" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tab activate" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tab list" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tab list" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tab list" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tab list" space' -l 'space' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tab list" project' -l 'project' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tab list" worktree' -l 'worktree' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tab list" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tab list" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tab close" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tab close" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tab close" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tab close" space' -l 'space' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tab close" project' -l 'project' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tab close" worktree' -l 'worktree' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tab close" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tab close" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc pane" 1' -fa 'label' -d 'Apply labels to a pane (by UUID or @label alias).'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc pane" 1' -fa 'list' -d 'List panes in a tab.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc pane" 1' -fa 'close' -d 'Close a pane.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc pane" 1' -fa 'focus' -d 'Focus a pane within its tab.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane label" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane label" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane label" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane label" replace' -l 'replace' -d 'Replace the pane\'s label set instead of union-merging.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane label" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane label" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane list" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane list" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane list" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane list" space' -l 'space' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane list" project' -l 'project' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane list" worktree' -l 'worktree' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane list" tab' -l 'tab' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane list" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane list" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane close" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane close" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane close" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane close" space' -l 'space' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane close" project' -l 'project' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane close" worktree' -l 'worktree' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane close" tab' -l 'tab' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane close" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane close" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane focus" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane focus" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane focus" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane focus" space' -l 'space' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane focus" project' -l 'project' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane focus" worktree' -l 'worktree' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane focus" tab' -l 'tab' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane focus" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane focus" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc send" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc send" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc send" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc send" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc send" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc broadcast" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc broadcast" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc broadcast" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc broadcast" tab' -l 'tab' -d 'Tab id.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc broadcast" worktree' -l 'worktree' -d 'Worktree id.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc broadcast" space' -l 'space' -d 'Space id.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc broadcast" label' -l 'label' -d 'Label string.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc broadcast" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc broadcast" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc hook" 1' -fa 'list' -d 'List installed hook subscriptions.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc hook" 1' -fa 'install' -d 'Install a subscription from a JSON file (or stdin with \'-\').'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc hook" 1' -fa 'remove' -d 'Remove a subscription by id.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc hook" 1' -fa 'enable' -d 'Enable a subscription.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc hook" 1' -fa 'disable' -d 'Disable a subscription.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc hook" 1' -fa 'reload' -d 'Reload hooks.json from disk.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc hook" 1' -fa 'test' -d 'Fire a subscription against a synthetic envelope (for handler development).'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc hook" 1' -fa 'fire' -d 'Manually fire a synthetic envelope through the dispatcher.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc hook" 1' -fa 'recent' -d 'Show recent hook firings from the ring buffer.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc hook" 1' -fa 'tail' -d 'Stream hook envelopes to stdout as they fire (Ctrl-C to stop).'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc hook" 1' -fa 'edit' -d 'Open ~/.config/touch-code/hooks.json in $EDITOR; reload on exit.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook list" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook list" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook list" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook list" event' -l 'event' -d 'Filter by event name (e.g. pane.ready).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook list" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook list" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook install" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook install" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook install" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook install" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook install" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook remove" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook remove" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook remove" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook remove" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook remove" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook enable" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook enable" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook enable" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook enable" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook enable" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook disable" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook disable" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook disable" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook disable" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook disable" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook reload" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook reload" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook reload" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook reload" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook reload" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook test" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook test" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook test" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook test" payload' -l 'payload' -d 'Path to a HookEnvelope JSON payload.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook test" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook test" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook fire" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook fire" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook fire" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook fire" payload' -l 'payload' -d 'Path to a HookEnvelope JSON payload.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook fire" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook fire" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook recent" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook recent" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook recent" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook recent" limit' -l 'limit' -d 'Maximum number of entries to return.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook recent" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook recent" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook tail" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook tail" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook tail" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook tail" idle-timeout' -l 'idle-timeout' -d 'Maximum seconds without an event before the stream is considered
dead (default: 86400 = 24h). The server does not currently send
keepalives (TODO(M3.1) — adding keepalive frames will let this
shrink to a few minutes without killing legit idle tails).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook tail" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook tail" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook edit" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook edit" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook edit" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook edit" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc hook edit" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc open" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc open" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc open" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc open" in' -l 'in' -d 'Editor id (e.g. cursor, zed, vscode, xcode, finder, ghostty). Omit to use per-Project / Settings defaults.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc open" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc open" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc rpc" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc rpc" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc rpc" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc rpc" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc rpc" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc help" version' -l 'version' -d 'Show the version.'
