# Source from .zshrc to make interactive Codex read the selected file credential.
# Requires a Codex CLI supporting --no-daemon (verified with 0.159.0).

typeset -g _AISWITCHER_CODEX_INTEGRATION_DIR=${${(%):-%N}:A:h}

# Use the optional, matching-version email/input repair for interactive calls.
# Utilities use the upstream executable. Upgrading upstream automatically skips
# this version-specific repair. No credentials are read and arguments stay intact.
function _aiswitcher_codex_interactive() {
    emulate -L zsh
    local repaired="$_AISWITCHER_CODEX_INTEGRATION_DIR/codex-status/bin/codex"
    if [[ -x "$repaired" ]] && \
        [[ "$(command codex --version 2>/dev/null)" == 'codex-cli 0.159.0' ]]; then
        AISWITCHER_CODEX_AI_SUGGESTIONS=${AISWITCHER_CODEX_AI_SUGGESTIONS:-1} \
            command "$repaired" "$@"
    else
        command codex "$@"
    fi
}

# Forward every argument and the executable's exit status unchanged, adding
# --no-daemon only to local interactive launches/resume/fork. Explicit remote
# connections and utility commands retain their upstream behavior. This function
# does not read credentials, change permissions, or stop existing processes.
function codex() {
    emulate -L zsh
    local -a invocation=("$@")
    local -i argument_index=1
    local -i interactive_command_index=0
    local -i explicit_server=0
    local argument

    while (( argument_index <= ${#invocation} )); do
        argument=${invocation[argument_index]}
        case "$argument" in
            -h|--help|-V|--version)
                command codex "$@"
                return $?
                ;;
            --remote)
                explicit_server=1
                (( argument_index += 2 ))
                continue
                ;;
            --remote=*|--no-daemon)
                explicit_server=1
                (( argument_index += 1 ))
                continue
                ;;
            -c|--config|--enable|--disable|--remote-auth-token-env|-i|--image|-m|--model|--local-provider|-p|--profile|-s|--sandbox|-C|--cd|--add-dir|-a|--ask-for-approval)
                (( argument_index += 2 ))
                continue
                ;;
            --)
                break
                ;;
            -*)
                (( argument_index += 1 ))
                continue
                ;;
        esac

        if (( interactive_command_index == 0 )); then
            case "$argument" in
                resume|fork)
                    interactive_command_index=$argument_index
                    ;;
                agents|exec|e|review|login|logout|mcp|plugin|app-server|remote-control|app|completion|update|doctor|sandbox|debug|apply|a|queue|archive|delete|migrate-rollouts|unarchive|cloud|exec-server|features|help)
                    command codex "$@"
                    return $?
                    ;;
                *)
                    interactive_command_index=-1
                    ;;
            esac
        fi
        (( argument_index += 1 ))
    done

    if (( explicit_server )); then
        _aiswitcher_codex_interactive "$@"
    elif (( interactive_command_index > 0 )); then
        _aiswitcher_codex_interactive "${(@)invocation[1,interactive_command_index]}" --no-daemon \
            "${(@)invocation[interactive_command_index+1,-1]}"
    else
        _aiswitcher_codex_interactive --no-daemon "$@"
    fi
}
