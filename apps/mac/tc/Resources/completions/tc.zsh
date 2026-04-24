#compdef tc

__tc_complete() {
    local -ar non_empty_completions=("${@:#(|:*)}")
    local -ar empty_completions=("${(M)@:#(|:*)}")
    _describe -V '' non_empty_completions -- empty_completions -P $'\'\''
}

__tc_custom_complete() {
    local -a completions
    completions=("${(@f)"$("${command_name}" "${@}" "${command_line[@]}")"}")
    if [[ "${#completions[@]}" -gt 1 ]]; then
        __tc_complete "${completions[@]:0:-1}"
    fi
}

__tc_cursor_index_in_current_word() {
    if [[ -z "${QIPREFIX}${IPREFIX}${PREFIX}" ]]; then
        printf 0
    else
        printf %s "${#${(z)LBUFFER}[-1]}"
    fi
}

_tc() {
    emulate -RL zsh -G
    setopt extendedglob nullglob numericglobsort
    unsetopt aliases banghist

    local -xr SAP_SHELL=zsh
    local -x SAP_SHELL_VERSION
    SAP_SHELL_VERSION="$(builtin emulate zsh -c 'printf %s "${ZSH_VERSION}"')"
    local -r SAP_SHELL_VERSION

    local context state state_descr line
    local -A opt_args

    local -r command_name="${words[1]}"
    local -ar command_line=("${words[@]}")
    local -ir current_word_index="$((CURRENT - 1))"

    local -i ret=1
    local -ar arg_specs=(
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
        '(-): :->command'
        '(-)*:: :->arg'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0
    case "${state}" in
    command)
        local -ar subcommands=(
            'system:Utility verbs for talking to the running touch-code app.'
            'space:Space-level verbs.'
            'project:Project-level verbs.'
            'worktree:Worktree-level verbs.'
            'tab:Tab-level verbs.'
            'pane:Pane-level verbs.'
            'send:Send text input to a specific pane (by UUID, @label, or '\''current'\'').'
            'broadcast:Fan-out text to a tab, worktree, space, or label scope.'
            'hook:Install, list, fire, and tail lifecycle hooks.'
            'open:Open a directory in an external editor (or terminal / git client / Finder).'
            'rpc:Low-level: invoke an arbitrary RPC method. Parses JSON params from argv.'
            'help:Show subcommand help information.'
        )
        _describe -V subcommand subcommands && ret=0
        ;;
    arg)
        case "${words[1]}" in
        system|space|project|worktree|tab|pane|send|broadcast|hook|open|rpc|help)
            "_tc_${words[1]}" && ret=0
            ;;
        esac
        ;;
    esac

    return "${ret}"
}

_tc_system() {
    local -i ret=1
    local -ar arg_specs=(
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
        '(-): :->command'
        '(-)*:: :->arg'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0
    case "${state}" in
    command)
        local -ar subcommands=(
            'ping:Probe the running app; prints '\''pong'\'' on exit 0.'
            'version:Show tc and server versions.'
            'status:Show app runtime status (version, uptime, clients).'
            'quit:Ask the running app to quit gracefully.'
            'sockets:List discovered socket paths and reachability.'
            'launch:Start the touch-code app if it isn'\''t running and wait until its socket is reachable.'
            'completions:Print a shell completion script for tc (bash / zsh / fish).'
        )
        _describe -V subcommand subcommands && ret=0
        ;;
    arg)
        case "${words[1]}" in
        ping|version|status|quit|sockets|launch|completions)
            "_tc_system_${words[1]}" && ret=0
            ;;
        esac
        ;;
    esac

    return "${ret}"
}

_tc_system_ping() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_system_version() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_system_status() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_system_quit() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_system_sockets() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_system_launch() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--wait-seconds[Seconds to wait for the socket to come up after launch.]:wait-seconds:'
        '--bundle[Bundle name to pass to `open -ga` (default\: touch-code).]:bundle:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_system_completions() {
    local -i ret=1
    local -ar arg_specs=(
        ':shell:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_space() {
    local -i ret=1
    local -ar arg_specs=(
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
        '(-): :->command'
        '(-)*:: :->arg'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0
    case "${state}" in
    command)
        local -ar subcommands=(
            'list:List all spaces.'
            'create:Create a new space.'
            'activate:Activate a space by id or '\''current'\''.'
            'rename:Rename a space by id or '\''current'\''.'
            'remove:Remove a space (and its projects) by id.'
        )
        _describe -V subcommand subcommands && ret=0
        ;;
    arg)
        case "${words[1]}" in
        list|create|activate|rename|remove)
            "_tc_space_${words[1]}" && ret=0
            ;;
        esac
        ;;
    esac

    return "${ret}"
}

_tc_space_list() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_space_create() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':name:'
        '--activate[Activate the new space immediately.]'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_space_activate() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':id:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_space_rename() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':id:'
        ':name:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_space_remove() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':id:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_project() {
    local -i ret=1
    local -ar arg_specs=(
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
        '(-): :->command'
        '(-)*:: :->arg'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0
    case "${state}" in
    command)
        local -ar subcommands=(
            'add:Add an existing directory as a project in a space.'
            'list:List projects in a space (default: current).'
            'remove:Remove a project from a space.'
        )
        _describe -V subcommand subcommands && ret=0
        ;;
    arg)
        case "${words[1]}" in
        add|list|remove)
            "_tc_project_${words[1]}" && ret=0
            ;;
        esac
        ;;
    esac

    return "${ret}"
}

_tc_project_add() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--space[Space id (UUID or '\''current'\'').]:space:'
        '--name[Display name.]:name:'
        '--path[Path on disk to use as the project root.]:path:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_project_list() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--space[Space id (UUID or '\''current'\'').]:space:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_project_remove() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--space[Space id (UUID or '\''current'\'').]:space:'
        ':id:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_worktree() {
    local -i ret=1
    local -ar arg_specs=(
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
        '(-): :->command'
        '(-)*:: :->arg'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0
    case "${state}" in
    command)
        local -ar subcommands=(
            'activate:Activate a worktree by id or '\''current'\''.'
            'list:List worktrees in a project.'
            'remove:Remove a worktree (clears the hierarchy entry; does not delete on-disk files).'
        )
        _describe -V subcommand subcommands && ret=0
        ;;
    arg)
        case "${words[1]}" in
        activate|list|remove)
            "_tc_worktree_${words[1]}" && ret=0
            ;;
        esac
        ;;
    esac

    return "${ret}"
}

_tc_worktree_activate() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':id:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_worktree_list() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--space[Space id (UUID or '\''current'\'').]:space:'
        '--project[Project id (UUID or '\''current'\'').]:project:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_worktree_remove() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--space[Space id (UUID or '\''current'\'').]:space:'
        '--project[Project id (UUID or '\''current'\'').]:project:'
        ':id:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_tab() {
    local -i ret=1
    local -ar arg_specs=(
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
        '(-): :->command'
        '(-)*:: :->arg'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0
    case "${state}" in
    command)
        local -ar subcommands=(
            'activate:Activate a tab by id or '\''current'\''.'
            'list:List tabs in a worktree.'
            'close:Close a tab.'
        )
        _describe -V subcommand subcommands && ret=0
        ;;
    arg)
        case "${words[1]}" in
        activate|list|close)
            "_tc_tab_${words[1]}" && ret=0
            ;;
        esac
        ;;
    esac

    return "${ret}"
}

_tc_tab_activate() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':id:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_tab_list() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--space:space:'
        '--project:project:'
        '--worktree:worktree:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_tab_close() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--space:space:'
        '--project:project:'
        '--worktree:worktree:'
        ':id:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_pane() {
    local -i ret=1
    local -ar arg_specs=(
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
        '(-): :->command'
        '(-)*:: :->arg'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0
    case "${state}" in
    command)
        local -ar subcommands=(
            'label:Apply labels to a pane (by UUID or @label alias).'
            'list:List panes in a tab.'
            'close:Close a pane.'
            'focus:Focus a pane within its tab.'
        )
        _describe -V subcommand subcommands && ret=0
        ;;
    arg)
        case "${words[1]}" in
        label|list|close|focus)
            "_tc_pane_${words[1]}" && ret=0
            ;;
        esac
        ;;
    esac

    return "${ret}"
}

_tc_pane_label() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':pane:'
        '*:labels:'
        '--replace[Replace the pane'\''s label set instead of union-merging.]'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_pane_list() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--space:space:'
        '--project:project:'
        '--worktree:worktree:'
        '--tab:tab:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_pane_close() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--space:space:'
        '--project:project:'
        '--worktree:worktree:'
        '--tab:tab:'
        ':id:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_pane_focus() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--space:space:'
        '--project:project:'
        '--worktree:worktree:'
        '--tab:tab:'
        ':id:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_send() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':target:'
        '*:text-pieces:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_broadcast() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--tab[Tab id.]:tab:'
        '--worktree[Worktree id.]:worktree:'
        '--space[Space id.]:space:'
        '--label[Label string.]:label:'
        '*:text-pieces:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_hook() {
    local -i ret=1
    local -ar arg_specs=(
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
        '(-): :->command'
        '(-)*:: :->arg'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0
    case "${state}" in
    command)
        local -ar subcommands=(
            'list:List installed hook subscriptions.'
            'install:Install a subscription from a JSON file (or stdin with '\''-'\'').'
            'remove:Remove a subscription by id.'
            'enable:Enable a subscription.'
            'disable:Disable a subscription.'
            'reload:Reload hooks.json from disk.'
            'test:Fire a subscription against a synthetic envelope (for handler development).'
            'fire:Manually fire a synthetic envelope through the dispatcher.'
            'recent:Show recent hook firings from the ring buffer.'
            'tail:Stream hook envelopes to stdout as they fire (Ctrl-C to stop).'
            'edit:Open ~/.config/touch-code/hooks.json in $EDITOR; reload on exit.'
        )
        _describe -V subcommand subcommands && ret=0
        ;;
    arg)
        case "${words[1]}" in
        list|install|remove|enable|disable|reload|test|fire|recent|tail|edit)
            "_tc_hook_${words[1]}" && ret=0
            ;;
        esac
        ;;
    esac

    return "${ret}"
}

_tc_hook_list() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--event[Filter by event name (e.g. pane.ready).]:event:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_hook_install() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':source:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_hook_remove() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':id:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_hook_enable() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':id:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_hook_disable() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':id:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_hook_reload() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_hook_test() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':id:'
        '--payload[Path to a HookEnvelope JSON payload.]:payload:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_hook_fire() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--payload[Path to a HookEnvelope JSON payload.]:payload:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_hook_recent() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--limit[Maximum number of entries to return.]:limit:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_hook_tail() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--idle-timeout[Maximum seconds without an event before the stream is considered
        dead (default\: 86400 = 24h). The server does not currently send
        keepalives (TODO(M3.1) — adding keepalive frames will let this
        shrink to a few minutes without killing legit idle tails).]:idle-timeout:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_hook_edit() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_open() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--in[Editor id (e.g. cursor, zed, vscode, xcode, finder, ghostty). Omit to use per-Project / Settings defaults.]:in:'
        ':path:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_rpc() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':method:'
        ':params:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_help() {
    local -i ret=1
    local -ar arg_specs=(
        '*:subcommands:'
        '--version[Show the version.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

if [[ "${funcstack[1]}" = _tc ]]; then
    _tc "${@}"
else
    compdef _tc tc
fi
