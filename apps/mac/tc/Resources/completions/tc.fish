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
        case 'project'
            __tc_parse_subcommand 0 'version' 'h/help'
            switch $unparsed_tokens[1]
            case 'add'
                __tc_parse_subcommand 0 'json' 'socket=' 'timeout=' 'name=' 'path=' 'version' 'h/help'
            case 'list'
                __tc_parse_subcommand 0 'json' 'socket=' 'timeout=' 'tag=' 'untagged' 'version' 'h/help'
            case 'remove'
                __tc_parse_subcommand 1 'json' 'socket=' 'timeout=' 'version' 'h/help'
            case 'tag'
                __tc_parse_subcommand 0 'version' 'h/help'
                switch $unparsed_tokens[1]
                case 'add'
                    __tc_parse_subcommand -r 2 'json' 'socket=' 'timeout=' 'version' 'h/help'
                case 'remove'
                    __tc_parse_subcommand -r 2 'json' 'socket=' 'timeout=' 'version' 'h/help'
                end
            end
        case 'tag'
            __tc_parse_subcommand 0 'version' 'h/help'
            switch $unparsed_tokens[1]
            case 'list'
                __tc_parse_subcommand 0 'json' 'socket=' 'timeout=' 'version' 'h/help'
            case 'create'
                __tc_parse_subcommand 1 'json' 'socket=' 'timeout=' 'color=' 'version' 'h/help'
            case 'rename'
                __tc_parse_subcommand 2 'json' 'socket=' 'timeout=' 'version' 'h/help'
            case 'recolor'
                __tc_parse_subcommand 2 'json' 'socket=' 'timeout=' 'version' 'h/help'
            case 'remove'
                __tc_parse_subcommand 1 'json' 'socket=' 'timeout=' 'version' 'h/help'
            end
        case 'worktree'
            __tc_parse_subcommand 0 'version' 'h/help'
            switch $unparsed_tokens[1]
            case 'activate'
                __tc_parse_subcommand 1 'json' 'socket=' 'timeout=' 'version' 'h/help'
            case 'list'
                __tc_parse_subcommand 0 'json' 'socket=' 'timeout=' 'project=' 'version' 'h/help'
            case 'remove'
                __tc_parse_subcommand 1 'json' 'socket=' 'timeout=' 'project=' 'version' 'h/help'
            end
        case 'tab'
            __tc_parse_subcommand 0 'version' 'h/help'
            switch $unparsed_tokens[1]
            case 'activate'
                __tc_parse_subcommand 1 'json' 'socket=' 'timeout=' 'version' 'h/help'
            case 'list'
                __tc_parse_subcommand 0 'json' 'socket=' 'timeout=' 'project=' 'worktree=' 'version' 'h/help'
            case 'close'
                __tc_parse_subcommand 1 'json' 'socket=' 'timeout=' 'project=' 'worktree=' 'version' 'h/help'
            end
        case 'pane'
            __tc_parse_subcommand 0 'version' 'h/help'
            switch $unparsed_tokens[1]
            case 'label'
                __tc_parse_subcommand -r 2 'json' 'socket=' 'timeout=' 'replace' 'version' 'h/help'
            case 'list'
                __tc_parse_subcommand 0 'json' 'socket=' 'timeout=' 'project=' 'worktree=' 'tab=' 'version' 'h/help'
            case 'close'
                __tc_parse_subcommand 1 'json' 'socket=' 'timeout=' 'project=' 'worktree=' 'tab=' 'version' 'h/help'
            case 'focus'
                __tc_parse_subcommand 1 'json' 'socket=' 'timeout=' 'project=' 'worktree=' 'tab=' 'version' 'h/help'
            end
        case 'send'
            __tc_parse_subcommand -r 2 'json' 'socket=' 'timeout=' 'version' 'h/help'
        case 'broadcast'
            __tc_parse_subcommand -r 1 'json' 'socket=' 'timeout=' 'tab=' 'worktree=' 'label=' 'version' 'h/help'
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
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc" 1' -fa 'project' -d 'Project-level verbs.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc" 1' -fa 'tag' -d 'Tag-level verbs.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc" 1' -fa 'worktree' -d 'Worktree-level verbs.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc" 1' -fa 'tab' -d 'Tab-level verbs.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc" 1' -fa 'pane' -d 'Pane-level verbs.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc" 1' -fa 'send' -d 'Send text input to a specific pane (by UUID, @label, or \'current\').'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc" 1' -fa 'broadcast' -d 'Fan-out text to a tab, worktree, or label scope.'
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
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc project" 1' -fa 'add' -d 'Add an existing directory as a project.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc project" 1' -fa 'list' -d 'List all projects, optionally filtered by tag.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc project" 1' -fa 'remove' -d 'Remove a project.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc project" 1' -fa 'tag' -d 'Add or remove tags on a project.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project add" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project add" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project add" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project add" name' -l 'name' -d 'Display name.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project add" path' -l 'path' -d 'Path on disk to use as the project root.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project add" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project add" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project list" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project list" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project list" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project list" tag' -l 'tag' -d 'Restrict to projects carrying this tag (id or name).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project list" untagged' -l 'untagged' -d 'Restrict to projects with no tags. Mutually exclusive with --tag.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project list" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project list" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project remove" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project remove" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project remove" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project remove" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project remove" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project tag" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project tag" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc project tag" 1' -fa 'add' -d 'Add one or more tags to a project.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc project tag" 1' -fa 'remove' -d 'Remove one or more tags from a project.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project tag add" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project tag add" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project tag add" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project tag add" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project tag add" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project tag remove" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project tag remove" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project tag remove" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project tag remove" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc project tag remove" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tag" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tag" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc tag" 1' -fa 'list' -d 'List all tags.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc tag" 1' -fa 'create' -d 'Create a new tag.'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc tag" 1' -fa 'rename' -d 'Rename a tag (by id or unique name).'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc tag" 1' -fa 'recolor' -d 'Recolor a tag (by id or unique name).'
complete -c 'tc' -n '__tc_should_offer_completions_for_positional "tc tag" 1' -fa 'remove' -d 'Remove a tag. Strips the tag from every project (Project data is untouched).'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tag list" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tag list" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tag list" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tag list" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tag list" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tag create" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tag create" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tag create" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tag create" color' -l 'color' -d 'Color: red|orange|yellow|green|blue|purple|grey (default: blue).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tag create" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tag create" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tag rename" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tag rename" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tag rename" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tag rename" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tag rename" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tag recolor" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tag recolor" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tag recolor" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tag recolor" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tag recolor" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tag remove" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tag remove" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tag remove" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tag remove" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tag remove" h help' -s 'h' -l 'help' -d 'Show help information.'
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
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc worktree list" project' -l 'project' -d 'Project id (UUID or \'current\').' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc worktree list" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc worktree list" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc worktree remove" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc worktree remove" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc worktree remove" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
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
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tab list" project' -l 'project' -d 'Project id (UUID or \'current\').' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tab list" worktree' -l 'worktree' -d 'Worktree id (UUID or \'current\').' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tab list" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tab list" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tab close" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tab close" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tab close" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tab close" project' -l 'project' -d 'Project id (UUID or \'current\').' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc tab close" worktree' -l 'worktree' -d 'Worktree id (UUID or \'current\').' -rfka ''
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
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane list" project' -l 'project' -d 'Project id (UUID or \'current\').' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane list" worktree' -l 'worktree' -d 'Worktree id (UUID or \'current\').' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane list" tab' -l 'tab' -d 'Tab id (UUID or \'current\').' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane list" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane list" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane close" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane close" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane close" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane close" project' -l 'project' -d 'Project id (UUID or \'current\').' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane close" worktree' -l 'worktree' -d 'Worktree id (UUID or \'current\').' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane close" tab' -l 'tab' -d 'Tab id (UUID or \'current\').' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane close" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane close" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane focus" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane focus" socket' -l 'socket' -d 'Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane focus" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane focus" project' -l 'project' -d 'Project id (UUID or \'current\').' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane focus" worktree' -l 'worktree' -d 'Worktree id (UUID or \'current\').' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc pane focus" tab' -l 'tab' -d 'Tab id (UUID or \'current\').' -rfka ''
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
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc broadcast" label' -l 'label' -d 'Label string.' -rfka ''
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc broadcast" version' -l 'version' -d 'Show the version.'
complete -c 'tc' -n '__tc_should_offer_completions_for_flags_or_options "tc broadcast" h help' -s 'h' -l 'help' -d 'Show help information.'
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
