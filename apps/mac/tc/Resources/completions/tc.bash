#!/bin/bash

__tc_cursor_index_in_current_word() {
    local remaining="${COMP_LINE}"

    local word
    for word in "${COMP_WORDS[@]::COMP_CWORD}"; do
        remaining="${remaining##*([[:space:]])"${word}"*([[:space:]])}"
    done

    local -ir index="$((COMP_POINT - ${#COMP_LINE} + ${#remaining}))"
    if [[ "${index}" -le 0 ]]; then
        printf 0
    else
        printf %s "${index}"
    fi
}

# positional arguments:
#
# - 1: the current (sub)command's count of positional arguments
#
# required variables:
#
# - repeating_flags: the repeating flags that the current (sub)command can accept
# - non_repeating_flags: the non-repeating flags that the current (sub)command can accept
# - repeating_options: the repeating options that the current (sub)command can accept
# - non_repeating_options: the non-repeating options that the current (sub)command can accept
# - positional_number: value ignored
# - unparsed_words: unparsed words from the current command line
#
# modified variables:
#
# - non_repeating_flags: remove flags for this (sub)command that are already on the command line
# - non_repeating_options: remove options for this (sub)command that are already on the command line
# - positional_number: set to the current positional number
# - unparsed_words: remove all flags, options, and option values for this (sub)command
__tc_offer_flags_options() {
    local -ir positional_count="${1}"
    positional_number=0

    local was_flag_option_terminator_seen=false
    local is_parsing_option_value=false

    local -ar unparsed_word_indices=("${!unparsed_words[@]}")
    local -i word_index
    for word_index in "${unparsed_word_indices[@]}"; do
        if "${is_parsing_option_value}"; then
            # This word is an option value:
            # Reset marker for next word iff not currently the last word
            [[ "${word_index}" -ne "${unparsed_word_indices[${#unparsed_word_indices[@]} - 1]}" ]] && is_parsing_option_value=false
            unset "unparsed_words[${word_index}]"
            # Do not process this word as a flag or an option
            continue
        fi

        local word="${unparsed_words["${word_index}"]}"
        if ! "${was_flag_option_terminator_seen}"; then
            case "${word}" in
            --)
                unset "unparsed_words[${word_index}]"
                # by itself -- is a flag/option terminator, but if it is the last word, it is the start of a completion
                if [[ "${word_index}" -ne "${unparsed_word_indices[${#unparsed_word_indices[@]} - 1]}" ]]; then
                    was_flag_option_terminator_seen=true
                fi
                continue
                ;;
            -*)
                # ${word} is a flag or an option
                # If ${word} is an option, mark that the next word to be parsed is an option value
                local option
                for option in "${repeating_options[@]}" "${non_repeating_options[@]}"; do
                    [[ "${word}" = "${option}" ]] && is_parsing_option_value=true && break
                done

                # Remove ${word} from ${non_repeating_flags} or ${non_repeating_options} so it isn't offered again
                local not_found=true
                local -i index
                for index in "${!non_repeating_flags[@]}"; do
                    if [[ "${non_repeating_flags[${index}]}" = "${word}" ]]; then
                        unset "non_repeating_flags[${index}]"
                        non_repeating_flags=("${non_repeating_flags[@]}")
                        not_found=false
                        break
                    fi
                done
                if "${not_found}"; then
                    for index in "${!non_repeating_flags[@]}"; do
                        if [[ "${non_repeating_flags[${index}]}" = "${word}" ]]; then
                            unset "non_repeating_flags[${index}]"
                            non_repeating_flags=("${non_repeating_flags[@]}")
                            break
                        fi
                    done
                fi
                unset "unparsed_words[${word_index}]"
                continue
                ;;
            esac
        fi

        # ${word} is neither a flag, nor an option, nor an option value
        if [[ "${positional_number}" -lt "${positional_count}" || "${positional_count}" -lt 0 ]]; then
            # ${word} is a positional
            ((positional_number++))
            unset "unparsed_words[${word_index}]"
        else
            if [[ -z "${word}" ]]; then
                # Could be completing a flag, option, or subcommand
                positional_number=-1
            else
                # ${word} is a subcommand or invalid, so stop processing this (sub)command
                positional_number=-2
            fi
            break
        fi
    done

    unparsed_words=("${unparsed_words[@]}")

    if\
        ! "${was_flag_option_terminator_seen}"\
        && ! "${is_parsing_option_value}"\
        && [[ ("${cur}" = -* && "${positional_number}" -ge 0) || "${positional_number}" -eq -1 ]]
    then
        COMPREPLY+=($(compgen -W "${repeating_flags[*]} ${non_repeating_flags[*]} ${repeating_options[*]} ${non_repeating_options[*]}" -- "${cur}"))
    fi
}

__tc_add_completions() {
    local completion
    while IFS='' read -r completion; do
        COMPREPLY+=("${completion}")
    done < <(IFS=$'\n' compgen "${@}" -- "${cur}")
}

__tc_custom_complete() {
    if [[ -n "${cur}" || -z ${COMP_WORDS[${COMP_CWORD}]} || "${COMP_LINE:${COMP_POINT}:1}" != ' ' ]]; then
        local -ar words=("${COMP_WORDS[@]}")
    else
        local -ar words=("${COMP_WORDS[@]::${COMP_CWORD}}" '' "${COMP_WORDS[@]:${COMP_CWORD}}")
    fi

    "${COMP_WORDS[0]}" "${@}" "${words[@]}"
}

_tc() {
    local state
    state="$(shopt -p;shopt -po)"
    trap "${state//$'\n'/;}" RETURN
    shopt -s extglob
    set +o history +o posix

    local -xr SAP_SHELL=bash
    local -x SAP_SHELL_VERSION
    SAP_SHELL_VERSION="$(IFS='.';printf %s "${BASH_VERSINFO[*]}")"
    local -r SAP_SHELL_VERSION

    local -r cur="${2}"
    local -r prev="${3}"

    local -i positional_number
    local -a unparsed_words=("${COMP_WORDS[@]:1:${COMP_CWORD}}")

    local -a repeating_flags=()
    local -a non_repeating_flags=(--version -h --help)
    local -a repeating_options=()
    local -a non_repeating_options=()
    __tc_offer_flags_options 0

    # Offer subcommand / subcommand argument completions
    local -r subcommand="${unparsed_words[0]}"
    unset 'unparsed_words[0]'
    unparsed_words=("${unparsed_words[@]}")
    case "${subcommand}" in
    system|space|project|worktree|tab|panel|send|broadcast|hook|skill|open|rpc|help)
        # Offer subcommand argument completions
        "_tc_${subcommand}"
        ;;
    *)
        # Offer subcommand completions
        COMPREPLY+=($(compgen -W 'system space project worktree tab panel send broadcast hook skill open rpc help' -- "${cur}"))
        ;;
    esac
}

_tc_system() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __tc_offer_flags_options 0

    # Offer subcommand / subcommand argument completions
    local -r subcommand="${unparsed_words[0]}"
    unset 'unparsed_words[0]'
    unparsed_words=("${unparsed_words[@]}")
    case "${subcommand}" in
    ping|version|status|quit|sockets|launch|completions)
        # Offer subcommand argument completions
        "_tc_system_${subcommand}"
        ;;
    *)
        # Offer subcommand completions
        COMPREPLY+=($(compgen -W 'ping version status quit sockets launch completions' -- "${cur}"))
        ;;
    esac
}

_tc_system_ping() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout)
    __tc_offer_flags_options 0

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    esac
}

_tc_system_version() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout)
    __tc_offer_flags_options 0

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    esac
}

_tc_system_status() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout)
    __tc_offer_flags_options 0

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    esac
}

_tc_system_quit() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout)
    __tc_offer_flags_options 0

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    esac
}

_tc_system_sockets() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout)
    __tc_offer_flags_options 0

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    esac
}

_tc_system_launch() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout --wait-seconds --bundle)
    __tc_offer_flags_options 0

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    '--wait-seconds')
        return
        ;;
    '--bundle')
        return
        ;;
    esac
}

_tc_system_completions() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __tc_offer_flags_options 1
}

_tc_space() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __tc_offer_flags_options 0

    # Offer subcommand / subcommand argument completions
    local -r subcommand="${unparsed_words[0]}"
    unset 'unparsed_words[0]'
    unparsed_words=("${unparsed_words[@]}")
    case "${subcommand}" in
    list|create|activate)
        # Offer subcommand argument completions
        "_tc_space_${subcommand}"
        ;;
    *)
        # Offer subcommand completions
        COMPREPLY+=($(compgen -W 'list create activate' -- "${cur}"))
        ;;
    esac
}

_tc_space_list() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout)
    __tc_offer_flags_options 0

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    esac
}

_tc_space_create() {
    repeating_flags=()
    non_repeating_flags=(--json --activate --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout)
    __tc_offer_flags_options 1

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    esac
}

_tc_space_activate() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout)
    __tc_offer_flags_options 1

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    esac
}

_tc_project() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __tc_offer_flags_options 0

    # Offer subcommand / subcommand argument completions
    local -r subcommand="${unparsed_words[0]}"
    unset 'unparsed_words[0]'
    unparsed_words=("${unparsed_words[@]}")
    case "${subcommand}" in
    add)
        # Offer subcommand argument completions
        "_tc_project_${subcommand}"
        ;;
    *)
        # Offer subcommand completions
        COMPREPLY+=($(compgen -W 'add' -- "${cur}"))
        ;;
    esac
}

_tc_project_add() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout --space --name --path)
    __tc_offer_flags_options 0

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    '--space')
        return
        ;;
    '--name')
        return
        ;;
    '--path')
        return
        ;;
    esac
}

_tc_worktree() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __tc_offer_flags_options 0

    # Offer subcommand / subcommand argument completions
    local -r subcommand="${unparsed_words[0]}"
    unset 'unparsed_words[0]'
    unparsed_words=("${unparsed_words[@]}")
    case "${subcommand}" in
    activate)
        # Offer subcommand argument completions
        "_tc_worktree_${subcommand}"
        ;;
    *)
        # Offer subcommand completions
        COMPREPLY+=($(compgen -W 'activate' -- "${cur}"))
        ;;
    esac
}

_tc_worktree_activate() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout)
    __tc_offer_flags_options 1

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    esac
}

_tc_tab() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __tc_offer_flags_options 0

    # Offer subcommand / subcommand argument completions
    local -r subcommand="${unparsed_words[0]}"
    unset 'unparsed_words[0]'
    unparsed_words=("${unparsed_words[@]}")
    case "${subcommand}" in
    activate)
        # Offer subcommand argument completions
        "_tc_tab_${subcommand}"
        ;;
    *)
        # Offer subcommand completions
        COMPREPLY+=($(compgen -W 'activate' -- "${cur}"))
        ;;
    esac
}

_tc_tab_activate() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout)
    __tc_offer_flags_options 1

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    esac
}

_tc_panel() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __tc_offer_flags_options 0

    # Offer subcommand / subcommand argument completions
    local -r subcommand="${unparsed_words[0]}"
    unset 'unparsed_words[0]'
    unparsed_words=("${unparsed_words[@]}")
    case "${subcommand}" in
    label)
        # Offer subcommand argument completions
        "_tc_panel_${subcommand}"
        ;;
    *)
        # Offer subcommand completions
        COMPREPLY+=($(compgen -W 'label' -- "${cur}"))
        ;;
    esac
}

_tc_panel_label() {
    repeating_flags=()
    non_repeating_flags=(--json --replace --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout)
    __tc_offer_flags_options -1

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    esac
}

_tc_send() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout)
    __tc_offer_flags_options -1

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    esac
}

_tc_broadcast() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout --tab --worktree --space --label)
    __tc_offer_flags_options -1

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    '--tab')
        return
        ;;
    '--worktree')
        return
        ;;
    '--space')
        return
        ;;
    '--label')
        return
        ;;
    esac
}

_tc_hook() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __tc_offer_flags_options 0

    # Offer subcommand / subcommand argument completions
    local -r subcommand="${unparsed_words[0]}"
    unset 'unparsed_words[0]'
    unparsed_words=("${unparsed_words[@]}")
    case "${subcommand}" in
    list|install|remove|enable|disable|reload|test|fire|recent|tail|edit)
        # Offer subcommand argument completions
        "_tc_hook_${subcommand}"
        ;;
    *)
        # Offer subcommand completions
        COMPREPLY+=($(compgen -W 'list install remove enable disable reload test fire recent tail edit' -- "${cur}"))
        ;;
    esac
}

_tc_hook_list() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout --event)
    __tc_offer_flags_options 0

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    '--event')
        return
        ;;
    esac
}

_tc_hook_install() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout)
    __tc_offer_flags_options 1

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    esac
}

_tc_hook_remove() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout)
    __tc_offer_flags_options 1

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    esac
}

_tc_hook_enable() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout)
    __tc_offer_flags_options 1

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    esac
}

_tc_hook_disable() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout)
    __tc_offer_flags_options 1

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    esac
}

_tc_hook_reload() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout)
    __tc_offer_flags_options 0

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    esac
}

_tc_hook_test() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout --payload)
    __tc_offer_flags_options 1

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    '--payload')
        return
        ;;
    esac
}

_tc_hook_fire() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout --payload)
    __tc_offer_flags_options 0

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    '--payload')
        return
        ;;
    esac
}

_tc_hook_recent() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout --limit)
    __tc_offer_flags_options 0

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    '--limit')
        return
        ;;
    esac
}

_tc_hook_tail() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout --idle-timeout)
    __tc_offer_flags_options 0

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    '--idle-timeout')
        return
        ;;
    esac
}

_tc_hook_edit() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout)
    __tc_offer_flags_options 0

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    esac
}

_tc_skill() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __tc_offer_flags_options 0
}

_tc_open() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout --in --path)
    __tc_offer_flags_options 1

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    '--in')
        return
        ;;
    '--path')
        return
        ;;
    esac
}

_tc_rpc() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout)
    __tc_offer_flags_options 2

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    esac
}

_tc_help() {
    repeating_flags=()
    non_repeating_flags=(--version)
    repeating_options=()
    non_repeating_options=()
    __tc_offer_flags_options -1
}

complete -o filenames -F _tc tc
