# TerminalGridMenubar shell hooks for codex/claude completion events.
# Source this file from ~/.zshrc.

if [[ -n "${__TERMINAL_GRID_HOOKS_LOADED:-}" ]]; then
  return
fi

__TERMINAL_GRID_HOOKS_LOADED=1
__terminal_grid_socket_path="$HOME/.terminal-grid-menubar/events.sock"

typeset -g __terminal_grid_track=0
typeset -g __terminal_grid_cmd=""
typeset -g __terminal_grid_tty=""

__terminal_grid_escape_json() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

__terminal_grid_send_event() {
  local payload="$1"

  [[ -S "$__terminal_grid_socket_path" ]] || return 0

  command python3 - "$__terminal_grid_socket_path" "$payload" <<'PY' >/dev/null 2>&1
import socket
import sys

path = sys.argv[1]
payload = (sys.argv[2] + "\n").encode("utf-8")

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(0.2)

try:
    sock.connect(path)
    sock.sendall(payload)
except Exception:
    pass
finally:
    try:
        sock.close()
    except Exception:
        pass
PY
}

__terminal_grid_detect_command() {
  local full_cmd="$1"
  local -a words
  local token base
  local i max_idx first_word alias_expansion function_body

  words=("${(z)full_cmd}")
  (( ${#words[@]} == 0 )) && return 1

  max_idx=${#words[@]}
  (( max_idx > 6 )) && max_idx=6

  for (( i = 1; i <= max_idx; i++ )); do
    token="${words[$i]}"
    [[ -z "$token" ]] && continue
    [[ "$token" == -* ]] && continue

    base="${token:t}"
    case "$base" in
      codex|codex.js|codex-cli)
        printf '%s' "codex"
        return 0
        ;;
      claude|claude.js|claude-code)
        printf '%s' "claude"
        return 0
        ;;
    esac
  done

  first_word="${words[1]}"
  if [[ -n "$first_word" && -n "${aliases[$first_word]-}" ]]; then
    alias_expansion="${aliases[$first_word]}"
    case "$alias_expansion" in
      *codex*)
        printf '%s' "codex"
        return 0
        ;;
      *claude*)
        printf '%s' "claude"
        return 0
        ;;
    esac
  fi

  if [[ -n "$first_word" && -n "${functions[$first_word]-}" ]]; then
    function_body="${functions[$first_word]}"
    case "$function_body" in
      *codex*)
        printf '%s' "codex"
        return 0
        ;;
      *claude*)
        printf '%s' "claude"
        return 0
        ;;
    esac
  fi

  return 1
}

__terminal_grid_preexec() {
  local full_cmd="$1"
  local detected_cmd=""

  detected_cmd="$(__terminal_grid_detect_command "$full_cmd" 2>/dev/null || true)"

  case "$detected_cmd" in
    codex|claude)
      __terminal_grid_track=1
      __terminal_grid_cmd="$detected_cmd"
      __terminal_grid_tty="$(command tty 2>/dev/null || true)"

      if [[ -n "$__terminal_grid_tty" && "$__terminal_grid_tty" != "not a tty" ]]; then
        local project_name="${PWD:t}"
        local escaped_tty
        local escaped_cmd
        local escaped_project
        local payload

        if [[ -z "$project_name" ]]; then
          project_name="$PWD"
        fi

        escaped_tty="$(__terminal_grid_escape_json "$__terminal_grid_tty")"
        escaped_cmd="$(__terminal_grid_escape_json "$__terminal_grid_cmd")"
        escaped_project="$(__terminal_grid_escape_json "$project_name")"
        payload=$(printf '{"type":"job_start","tty":"%s","command":"%s","project":"%s"}' "$escaped_tty" "$escaped_cmd" "$escaped_project")
        __terminal_grid_send_event "$payload"
      fi
      ;;
    *)
      __terminal_grid_track=0
      __terminal_grid_cmd=""
      __terminal_grid_tty=""
      ;;
  esac
}

__terminal_grid_precmd() {
  local exit_code="$?"

  if [[ "${__terminal_grid_track:-0}" -eq 1 ]]; then
    local tty_value="${__terminal_grid_tty:-$(command tty 2>/dev/null || true)}"

    if [[ -n "$tty_value" && "$tty_value" != "not a tty" ]]; then
      local escaped_tty
      local escaped_cmd
      local escaped_project
      local project_name="${PWD:t}"
      local payload

      if [[ -z "$project_name" ]]; then
        project_name="$PWD"
      fi

      escaped_tty="$(__terminal_grid_escape_json "$tty_value")"
      escaped_cmd="$(__terminal_grid_escape_json "$__terminal_grid_cmd")"
      escaped_project="$(__terminal_grid_escape_json "$project_name")"

      payload=$(printf '{"type":"job_done","tty":"%s","command":"%s","project":"%s","exitCode":%d}' "$escaped_tty" "$escaped_cmd" "$escaped_project" "$exit_code")
      __terminal_grid_send_event "$payload"
    fi
  fi

  __terminal_grid_track=0
  __terminal_grid_cmd=""
  __terminal_grid_tty=""
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec __terminal_grid_preexec
add-zsh-hook precmd __terminal_grid_precmd
