#!/bin/bash

set -Eeuo pipefail
IFS=$'\n\t'

# =========================================================
# Appwrite Updater
# Safe sequential upgrades with migration-aware execution
# =========================================================

# ---------- Color System ----------
NC='\033[0m'
BOLD='\033[1m'

RED='\033[38;5;203m'
GREEN='\033[38;5;78m'
YELLOW='\033[38;5;221m'
BLUE='\033[38;5;75m'
CYAN='\033[38;5;81m'
WHITE='\033[38;5;15m'
SOFT='\033[38;5;245m'

BG_BLUE='\033[48;5;24m'
BG_GREEN='\033[48;5;22m'
BG_YELLOW='\033[48;5;94m'
BG_RED='\033[48;5;52m'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
RELEASES_API_URL="https://api.github.com/repos/appwrite/appwrite/releases"
REMOTE_VERSIONS_JSON_URL="https://raw.githubusercontent.com/ItzNotABug/appwriteupdaterscript/master/versions.json"

APPWRITE_DIR="./appwrite"
TARGET_VERSION=""
DRY_RUN=false
ASSUME_YES=false
NO_CLEANUP=false
NO_RESTART=false
VERBOSE=false
LOG_FILE=""
CURRENT_VERSION=""
RESOLVED_TARGET_VERSION=""
MIGRATION_SOURCE=""
HAS_RELEASE_DISCOVERY=false
MIGRATION_RUNTIME_BACKUP_PATH='/usr/src/code/src/Appwrite/Migration/Migration.php.appwrite-updater.bak'
ACTIVE_COMMAND_PID=''
ACTIVE_COMMAND_DESCRIPTION=''
TREE_PREFIX=''

RELEASE_VERSIONS=()
MIGRATION_BOUNDARIES=()
PLAN_VERSIONS=()
PLAN_MIGRATIONS=()
CLEANUP_IMAGES=()
HAS_TPUT=false
HAS_UNICODE=false
SPINNER_INTERVAL='0.08'
SPINNER_FRAMES=()
ICON_OK='OK'
ICON_FAIL='ERR'
ICON_WARN='!'
ICON_INFO='i'
ICON_ARROW='>'

# ---------- Terminal / Capability ----------
set_spinner_frames() {
    if [ "$HAS_UNICODE" = true ]; then
        SPINNER_FRAMES=('◜' '◠' '◝' '◞' '◡' '◟')
        ICON_OK='✓'
        ICON_FAIL='✕'
        ICON_WARN='!'
        ICON_INFO='•'
        ICON_ARROW='→'
    else
        SPINNER_FRAMES=("-" "\\" "|" "/")
        ICON_OK='OK'
        ICON_FAIL='ERR'
        ICON_WARN='!'
        ICON_INFO='i'
        ICON_ARROW='>'
    fi
}

terminal_width() {
    local width=92

    if [ "$HAS_TPUT" = true ] && [ -t 1 ]; then
        local detected_width
        detected_width="$(tput cols 2>/dev/null || true)"
        if [[ "$detected_width" =~ ^[0-9]+$ ]] && [ "$detected_width" -ge 60 ]; then
            width="$detected_width"
        fi
    fi

    if [ "$width" -gt 110 ]; then
        width=110
    fi

    echo "$width"
}

repeat_char() {
    local count="$1"
    local char="$2"
    local result=''
    local i

    for ((i = 0; i < count; i++)); do
        result+="$char"
    done

    printf '%s' "$result"
}

clear_line() {
    if [ "$HAS_TPUT" = true ] && [ -t 1 ]; then
        tput el >/dev/null 2>&1 || true
    fi
}

erase_status_line() {
    local width
    width="$(terminal_width)"
    printf '\r%*s\r' "$width" ''
    clear_line
}

hide_cursor() {
    if [ "$HAS_TPUT" = true ] && [ -t 1 ]; then
        tput civis >/dev/null 2>&1 || true
    fi
}

show_cursor() {
    if [ "$HAS_TPUT" = true ] && [ -t 1 ]; then
        tput cnorm >/dev/null 2>&1 || true
    fi
}

# ---------- ANSI-safe text helpers ----------
strip_ansi() {
    sed -E $'s/\x1B\\[[0-9;]*[[:alpha:]]//g'
}

visible_length() {
    local text="$1"
    local stripped
    stripped="$(printf '%b' "$text" | strip_ansi)"
    printf '%s' "${#stripped}"
}

log_plain() {
    local text="$1"
    local timestamp

    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    if [ -z "${LOG_FILE:-}" ]; then
        return
    fi

    printf '[%s] %s\n' "$timestamp" "$text" >> "$LOG_FILE"
}

log_rendered() {
    local text="$1"
    local rendered

    rendered="$(printf '%b' "$text" | strip_ansi)"
    while IFS= read -r line || [ -n "$line" ]; do
        log_plain "$line"
    done <<EOF_RENDERED
$rendered
EOF_RENDERED
}

join_command_for_log() {
    local parts=()
    local arg

    for arg in "$@"; do
        parts+=("$(printf '%q' "$arg")")
    done

    printf '%s' "${parts[*]}"
}

log_command_context() {
    local description="$1"
    shift

    log_plain "[RUN] ${description}"
    log_plain "[CMD] $(join_command_for_log "$@")"
}

log_failure_summary_from_output() {
    local file="$1"
    local matches

    if [ ! -f "$file" ]; then
        return
    fi

    matches="$(grep -E -m 5 'Failed to update project|Failed to migrate project|Fatal error:|SQLSTATE\[|Collection not found|No migration found for version|^\[Error\]' "$file" || true)"

    if [ -z "$matches" ]; then
        return
    fi

    log_plain "[FAILURE SUMMARY]"
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] && log_plain "  ${line}"
    done <<EOF_FAILURE
$matches
EOF_FAILURE
}

# ---------- Layout Primitives ----------
box_rule() {
    local width="$1"
    local left="$2"
    local fill="$3"
    local right="$4"
    printf '%s%s%s\n' "$left" "$(repeat_char "$((width - 2))" "$fill")" "$right"
}

box_content() {
    local width="$1"
    local text="$2"
    local content_width=$((width - 4))
    local line wrapped_line rendered_line visible_len pad_len

    if [ -z "$text" ]; then
        printf '│ %-*s │\n' "$content_width" ''
        return
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        rendered_line="$(printf '%b' "$line")"

        if [[ "$rendered_line" == *$'\033'* ]]; then
            visible_len="$(visible_length "$rendered_line")"
            pad_len=$((content_width - visible_len))
            [ "$pad_len" -lt 0 ] && pad_len=0

            printf '│ '
            printf '%s' "$rendered_line"
            printf '%*s' "$pad_len" ''
            printf ' │\n'
            continue
        fi

        while IFS= read -r wrapped_line || [ -n "$wrapped_line" ]; do
            visible_len="${#wrapped_line}"
            pad_len=$((content_width - visible_len))
            [ "$pad_len" -lt 0 ] && pad_len=0

            printf '│ '
            printf '%b' "$wrapped_line"
            printf '%*s' "$pad_len" ''
            printf ' │\n'
        done < <(printf '%b\n' "$line" | fold -s -w "$content_width")
    done < <(printf '%s\n' "$text")
}

card() {
    local title="$1"
    shift
    local width
    width="$(terminal_width)"

    log_plain ""
    log_plain "$title"
    log_plain "$(repeat_char 48 '-')"

    printf '\n%b' "${CYAN}"
    box_rule "$width" '╭' '─' '╮'
    printf '%b' "${NC}"
    box_content "$width" "${BOLD}${WHITE}${title}${NC}"
    printf '%b' "${SOFT}"
    box_rule "$width" '├' '─' '┤'
    printf '%b' "${NC}"

    local line
    for line in "$@"; do
        box_content "$width" "$line"
        log_rendered "$line"
    done

    printf '%b' "${CYAN}"
    box_rule "$width" '╰' '─' '╯'
    printf '%b\n' "${NC}"
}

section() {
    local title="$1"
    printf '\n%b%s%b %b%s%b\n' \
        "${CYAN}${BOLD}" "${ICON_ARROW}" "${NC}" \
        "${BOLD}${WHITE}" "$title" "${NC}"
    log_plain ""
    log_plain "== ${title} =="
}

success() {
    printf '%b%s%b %s\n' "${GREEN}${BOLD}" "${ICON_OK}" "${NC}" "$1"
    log_plain "[OK] $1"
}

warn() {
    printf '%b%s%b %s\n' "${YELLOW}${BOLD}" "${ICON_WARN}" "${NC}" "$1" >&2
    log_plain "[WARN] $1"
}

error() {
    printf '%b%s%b %s\n' "${RED}${BOLD}" "${ICON_FAIL}" "${NC}" "$1" >&2
    log_plain "[ERR] $1"
}

info() {
    printf '%b%s%b %s\n' "${BLUE}${BOLD}" "${ICON_INFO}" "${NC}" "$1"
    log_plain "[INFO] $1"
}

step() {
    printf '%b%s%b %s\n' "${CYAN}" "${ICON_ARROW}" "${NC}" "$1"
    log_plain "[STEP] $1"
}

subtle() {
    local text="$1"
    local width
    local content_width
    local branch_prefix='  └─ '
    local continuation_prefix='     '
    local first_line=true
    local line

    width="$(terminal_width)"
    content_width=$((width - ${#branch_prefix}))
    if [ "$content_width" -lt 20 ]; then
        content_width=20
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$first_line" = true ]; then
            printf '%b%s%s%b\n' "${SOFT}" "${branch_prefix}" "$line" "${NC}"
            log_plain "${branch_prefix}${line}"
            first_line=false
        else
            printf '%b%s%s%b\n' "${SOFT}" "${continuation_prefix}" "$line" "${NC}"
            log_plain "${continuation_prefix}${line}"
        fi
    done < <(printf '%s\n' "$text" | fold -s -w "$content_width")
}

render_prefixed_text() {
    local prefix="$1"
    local continuation_prefix="$2"
    local color="$3"
    local text="$4"
    local width
    local content_width
    local first_line=true
    local line

    width="$(terminal_width)"
    content_width=$((width - ${#prefix}))
    if [ "$content_width" -lt 20 ]; then
        content_width=20
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$first_line" = true ]; then
            printf '%b%s%b%b%s%b\n' "${SOFT}" "${prefix}" "${NC}" "${color}" "${line}" "${NC}"
            log_plain "${prefix}${line}"
            first_line=false
        else
            printf '%b%s%b%b%s%b\n' "${SOFT}" "${continuation_prefix}" "${NC}" "${color}" "${line}" "${NC}"
            log_plain "${continuation_prefix}${line}"
        fi
    done < <(printf '%s\n' "$text" | fold -s -w "$content_width")
}

tree_line() {
    render_prefixed_text '  ├─ ' '  │  ' "${WHITE}" "$1"
}

tree_leaf() {
    render_prefixed_text '  └─ ' '     ' "${WHITE}" "$1"
}

tree_note() {
    render_prefixed_text '    └─ ' '       ' "${SOFT}" "$1"
}

tree_prefix_for_index() {
    local index="$1"
    local total="$2"

    if [ "$index" -ge "$total" ]; then
        printf '  └─ '
    else
        printf '  ├─ '
    fi
}

tree_status_line() {
    local prefix="$1"
    local color="$2"
    local icon="$3"
    local text="$4"
    printf '%b%s%b%b%s%b %s\n' "${SOFT}" "${prefix}" "${NC}" "${color}${BOLD}" "${icon}" "${NC}" "${text}"
    log_plain "${prefix}[${icon}] ${text}"
}

render_tree_spinner_line() {
    local frame="$1"
    local prefix="$2"
    local message="$3"
    printf '\r%b%s%b%b%s%b %s' "${SOFT}" "${prefix}" "${NC}" "${CYAN}" "${frame}" "${NC}" "${message}"
    clear_line
}

badge() {
    local tone="$1"
    local label="$2"

    case "$tone" in
        success) printf '%b %s %b' "${BG_GREEN}${WHITE}" "$label" "${NC}" ;;
        warn)    printf '%b %s %b' "${BG_YELLOW}${WHITE}" "$label" "${NC}" ;;
        danger)  printf '%b %s %b' "${BG_RED}${WHITE}" "$label" "${NC}" ;;
        info)    printf '%b %s %b' "${BG_BLUE}${WHITE}" "$label" "${NC}" ;;
        *)       printf '[ %s ]' "$label" ;;
    esac
}

kv_row() {
    local label="$1"
    local value="$2"
    local content_width
    local value_width
    local padded_label
    local line

    content_width=$(( $(terminal_width) - 4 ))
    value_width=$((content_width - 19))
    if [ "$value_width" -lt 16 ]; then
        value_width=16
    fi

    padded_label="$(printf '%-18s' "${label}")"

    if [[ "$value" == *$'\033'* ]]; then
        printf '%b%s%b %s' "${SOFT}" "${padded_label}" "${NC}" "$value"
        return
    fi

    local first_line=true
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$first_line" = true ]; then
            printf '%b%s%b %s' "${SOFT}" "${padded_label}" "${NC}" "$line"
            first_line=false
        else
            printf '\n%b%s%b %s' "${SOFT}" "$(printf '%-18s' '')" "${NC}" "$line"
        fi
    done < <(printf '%s\n' "$value" | fold -s -w "$value_width")
}

print_banner() {
    local width
    width="$(terminal_width)"

    log_plain "Appwrite Updater"
    log_plain "Migration-aware upgrades for self-hosted Appwrite."
    log_plain "Boundary-aware. Dry-run friendly. Operator-safe."

    printf '\n'
    printf '%b%s%b\n' "${CYAN}" "$(repeat_char "$width" '═')" "${NC}"
    printf '%b%s%b\n' "${BOLD}${WHITE}" "  Appwrite Updater" "${NC}"
    printf '%b%s%b\n' "${SOFT}" "  Migration-aware upgrades for self-hosted Appwrite." "${NC}"
    printf '%b%s%b\n' "${SOFT}" "  Boundary-aware. Dry-run friendly. Operator-safe." "${NC}"
    printf '%b%s%b\n' "${CYAN}" "$(repeat_char "$width" '═')" "${NC}"
}

print_summary_card() {
    local title="$1"
    shift
    card "$title" "$@"
}

print_help() {
    cat <<'EOF_HELP'
Usage:
  ./appwrite-updater.sh [options]

Options:
  -v, --version <ver>      Target version (default: latest stable)
  -d, --appwrite-dir <dir> Appwrite directory (default: ./appwrite)
      --dry-run            Preview the plan without making changes
  -y, --yes                Skip confirmation prompts
      --no-cleanup         Keep previous Appwrite images
      --no-restart         Skip the final docker compose restart
      --verbose            Stream command output to the terminal
  -h, --help               Show this help
EOF_HELP
}

# ---------- File / temp helpers ----------
cleanup_temp_file() {
    local file="$1"
    if [ -n "$file" ] && [ -f "$file" ]; then
        rm -f "$file"
    fi
}

show_failure_output() {
    local file="$1"

    if [ ! -f "$file" ]; then
        return
    fi

    echo
    warn "Last command output"
    tail -n 40 "$file" >&2 || true
}

require_command() {
    local command_name="$1"
    local install_hint="$2"

    if ! command -v "$command_name" >/dev/null 2>&1; then
        error "Missing required command: $command_name"
        subtle "$install_hint"
        exit 1
    fi
}

prompt_or_exit() {
    local prompt="$1"
    local __resultvar="$2"
    local input=''

    if ! read -r -p "$prompt" input; then
        printf '\n' >&2
        warn "Interrupted"
        exit 130
    fi

    printf -v "$__resultvar" '%s' "$input"
}

normalize_version() {
    local version="$1"
    version="${version#v}"
    echo "$version"
}

expand_path() {
    local path="$1"

    if [ "$path" = "~" ]; then
        echo "$HOME"
        return
    fi

    if [[ "$path" == ~/* ]]; then
        echo "$HOME/${path#~/}"
        return
    fi

    echo "$path"
}

compare_versions() {
    local left right
    left="$(normalize_version "$1")"
    right="$(normalize_version "$2")"

    local IFS='.'
    local left_parts right_parts
    read -r -a left_parts <<< "$left"
    read -r -a right_parts <<< "$right"

    local index=0
    local max_len=${#left_parts[@]}
    if [ ${#right_parts[@]} -gt "$max_len" ]; then
        max_len=${#right_parts[@]}
    fi

    while [ "$index" -lt "$max_len" ]; do
        local left_num=${left_parts[$index]:-0}
        local right_num=${right_parts[$index]:-0}

        if [ "$left_num" -gt "$right_num" ]; then
            return 0
        fi
        if [ "$left_num" -lt "$right_num" ]; then
            return 1
        fi

        index=$((index + 1))
    done

    return 2
}

version_gt() {
    local result
    if compare_versions "$1" "$2"; then
        result=0
    else
        result=$?
    fi
    [ "$result" -eq 0 ]
}

version_lt() {
    local result
    if compare_versions "$1" "$2"; then
        result=0
    else
        result=$?
    fi
    [ "$result" -eq 1 ]
}

version_eq() {
    local result
    if compare_versions "$1" "$2"; then
        result=0
    else
        result=$?
    fi
    [ "$result" -eq 2 ]
}

sort_versions_desc() {
    local values=("$@")
    local count=${#values[@]}
    local i j tmp

    if [ "$count" -le 1 ]; then
        printf '%s\n' "${values[@]}"
        return
    fi

    for ((i = 0; i < count; i++)); do
        for ((j = i + 1; j < count; j++)); do
            if version_lt "${values[i]}" "${values[j]}"; then
                tmp="${values[i]}"
                values[i]="${values[j]}"
                values[j]="$tmp"
            fi
        done
    done

    printf '%s\n' "${values[@]}"
}

major_minor() {
    local normalized
    normalized="$(normalize_version "$1")"
    local major minor _rest
    IFS='.' read -r major minor _rest <<< "$normalized"
    echo "${major}.${minor}"
}

contains_normalized_value() {
    local needle
    needle="$(normalize_version "$1")"
    shift
    local version
    for version in "$@"; do
        if [ "$(normalize_version "$version")" = "$needle" ]; then
            return 0
        fi
    done
    return 1
}

is_boundary_minor() {
    local boundary
    for boundary in "${MIGRATION_BOUNDARIES[@]}"; do
        if version_eq "$boundary" "$1"; then
            return 0
        fi
    done
    return 1
}

init_log_file() {
    if [ "$DRY_RUN" = true ]; then
        LOG_FILE=""
        return
    fi

    local timestamp log_candidate
    timestamp="$(date '+%Y%m%d-%H%M%S')"
    log_candidate="$PWD/appwrite-updater-${timestamp}.log"

    if : > "$log_candidate" 2>/dev/null; then
        LOG_FILE="$log_candidate"
    else
        LOG_FILE="$(mktemp -t appwrite-updater.log)"
    fi
}

render_spinner_line() {
    local frame="$1"
    local message="$2"
    printf '\r%b%s%b %s' "${CYAN}" "$frame" "${NC}" "$message"
    clear_line
}

run_with_spinner_capture() {
    local description="$1"
    local output_file
    output_file="$2"
    shift 2

    log_command_context "$description" "$@"

    local spinner_count=${#SPINNER_FRAMES[@]}
    local status=0
    local cursor_hidden=false

    if [ "$VERBOSE" = true ]; then
        if [ -n "${TREE_PREFIX:-}" ]; then
            tree_line "$description"
        else
            step "$description"
        fi
        if [ -n "${LOG_FILE:-}" ]; then
            "$@" > >(tee -a "$LOG_FILE" "$output_file") 2> >(tee -a "$LOG_FILE" "$output_file" >&2) || status=$?
        else
            "$@" > >(tee "$output_file") 2> >(tee "$output_file" >&2) || status=$?
        fi
    else
        local spinner_index=0
        local pid
        local command_status=0

        hide_cursor
        cursor_hidden=true
        (
            "$@" >"$output_file" 2>&1
        ) &
        pid=$!
        ACTIVE_COMMAND_PID="$pid"
        ACTIVE_COMMAND_DESCRIPTION="$description"

        if [ -n "${TREE_PREFIX:-}" ]; then
            render_tree_spinner_line "${SPINNER_FRAMES[0]}" "$TREE_PREFIX" "$description"
        else
            render_spinner_line "${SPINNER_FRAMES[0]}" "$description"
        fi
        spinner_index=1

        while kill -0 "$pid" >/dev/null 2>&1; do
            if [ -n "${TREE_PREFIX:-}" ]; then
                render_tree_spinner_line "${SPINNER_FRAMES[$spinner_index]}" "$TREE_PREFIX" "$description"
            else
                render_spinner_line "${SPINNER_FRAMES[$spinner_index]}" "$description"
            fi
            spinner_index=$(( (spinner_index + 1) % spinner_count ))
            sleep "$SPINNER_INTERVAL"
        done

        if wait "$pid"; then
            command_status=0
        else
            command_status=$?
        fi
        ACTIVE_COMMAND_PID=''
        ACTIVE_COMMAND_DESCRIPTION=''
        status=$command_status
        if [ -n "${LOG_FILE:-}" ]; then
            cat "$output_file" >> "$LOG_FILE"
        fi

        if [ -n "${TREE_PREFIX:-}" ]; then
            erase_status_line
            if [ "$status" -eq 0 ]; then
                tree_status_line "$TREE_PREFIX" "${GREEN}" "${ICON_OK}" "$description"
            else
                tree_status_line "$TREE_PREFIX" "${RED}" "${ICON_FAIL}" "$description"
            fi
        else
            erase_status_line
            if [ "$status" -eq 0 ]; then
                printf '%b%s%b %s\n' "${GREEN}${BOLD}" "${ICON_OK}" "${NC}" "${description}"
            else
                printf '%b%s%b %s\n' "${RED}${BOLD}" "${ICON_FAIL}" "${NC}" "${description}"
            fi
        fi
        show_cursor
        cursor_hidden=false
    fi

    if [ "$cursor_hidden" = true ]; then
        show_cursor
    fi

    ACTIVE_COMMAND_PID=''
    ACTIVE_COMMAND_DESCRIPTION=''

    return "$status"
}

run_with_tree_spinner_capture() {
    local branch_prefix="$1"
    local description="$2"
    local output_file="$3"
    shift 3

    log_command_context "${branch_prefix}${description}" "$@"

    local spinner_count=${#SPINNER_FRAMES[@]}
    local status=0
    local cursor_hidden=false

    if [ "$VERBOSE" = true ]; then
        tree_line "$description"
        if [ -n "${LOG_FILE:-}" ]; then
            "$@" > >(tee -a "$LOG_FILE" "$output_file") 2> >(tee -a "$LOG_FILE" "$output_file" >&2) || status=$?
        else
            "$@" > >(tee "$output_file") 2> >(tee "$output_file" >&2) || status=$?
        fi
    else
        local spinner_index=0
        local pid
        local command_status=0

        hide_cursor
        cursor_hidden=true
        (
            "$@" >"$output_file" 2>&1
        ) &
        pid=$!
        ACTIVE_COMMAND_PID="$pid"
        ACTIVE_COMMAND_DESCRIPTION="$description"

        render_tree_spinner_line "${SPINNER_FRAMES[0]}" "${branch_prefix}" "$description"
        spinner_index=1

        while kill -0 "$pid" >/dev/null 2>&1; do
            render_tree_spinner_line "${SPINNER_FRAMES[$spinner_index]}" "${branch_prefix}" "$description"
            spinner_index=$(( (spinner_index + 1) % spinner_count ))
            sleep "$SPINNER_INTERVAL"
        done

        if wait "$pid"; then
            command_status=0
        else
            command_status=$?
        fi
        ACTIVE_COMMAND_PID=''
        ACTIVE_COMMAND_DESCRIPTION=''
        status=$command_status
        if [ -n "${LOG_FILE:-}" ]; then
            cat "$output_file" >> "$LOG_FILE"
        fi

        if [ "$status" -eq 0 ]; then
            printf '\r'
            tree_status_line "${branch_prefix}" "${GREEN}" "${ICON_OK}" "${description}"
        else
            printf '\r'
            tree_status_line "${branch_prefix}" "${RED}" "${ICON_FAIL}" "${description}"
        fi
        show_cursor
        cursor_hidden=false
    fi

    if [ "$cursor_hidden" = true ]; then
        show_cursor
    fi

    ACTIVE_COMMAND_PID=''
    ACTIVE_COMMAND_DESCRIPTION=''

    return "$status"
}

run_command() {
    local description="$1"
    shift

    local output_file
    output_file="$(mktemp -t appwrite-updater-command.log)"

    local status=0
    run_with_spinner_capture "$description" "$output_file" "$@" || status=$?

    if [ "$status" -ne 0 ]; then
        error "$description failed"
        show_failure_output "$output_file"
        cleanup_temp_file "$output_file"
        return "$status"
    fi

    cleanup_temp_file "$output_file"
    return 0
}

migration_output_has_errors() {
    local file="$1"
    grep -Eq 'Failed to update project|Failed to migrate project|Fatal error:|SQLSTATE\[|^\[Error\]|Collection not found|No migration found for version' "$file"
}

run_migration_command() {
    local version="$1"
    local output_file
    output_file="$(mktemp -t appwrite-updater-migrate.log)"

    local description="Running migration for ${version}"
    local status=0

    run_with_spinner_capture \
        "$description" \
        "$output_file" \
        docker compose --project-directory "$APPWRITE_DIR" exec -T appwrite migrate "--version=${version}" || status=$?

    if [ "$status" -ne 0 ] || migration_output_has_errors "$output_file"; then
        error "Migration failed for ${version}"
        log_plain "[FAIL] Migration step failed for version ${version}"
        log_failure_summary_from_output "$output_file"
        show_failure_output "$output_file"
        cleanup_temp_file "$output_file"
        return 1
    fi

    log_plain "[OK] Migration completed for ${version}"
    cleanup_temp_file "$output_file"
    return 0
}

wait_for_appwrite_ready() {
    local attempts=30
    local delay_seconds=2
    local attempt
    local spinner_count=${#SPINNER_FRAMES[@]}
    local frame
    local container_id
    local container_state

    if [ -n "${TREE_PREFIX:-}" ]; then
        printf '%b%s%b%b%s%b' "${SOFT}" "${TREE_PREFIX}" "${NC}" "${CYAN}" "Waiting for Appwrite container readiness" "${NC}"
    else
        printf '%b' "${CYAN}Waiting for Appwrite container readiness${NC}"
    fi

    for ((attempt = 1; attempt <= attempts; attempt++)); do
        container_id="$(docker compose --project-directory "$APPWRITE_DIR" ps -q appwrite 2>/dev/null || true)"

        if [ -n "$container_id" ]; then
            container_state="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id" 2>/dev/null || true)"

            if [ "$container_state" = 'healthy' ]; then
                erase_status_line
                if [ -n "${TREE_PREFIX:-}" ]; then
                    tree_status_line "$TREE_PREFIX" "${GREEN}" "${ICON_OK}" "Appwrite container is healthy"
                else
                    printf '%b%s%b\n' "${GREEN}${BOLD}" "✓ Appwrite container is healthy" "${NC}"
                fi
                return 0
            fi
        fi

        if docker compose --project-directory "$APPWRITE_DIR" exec -T appwrite php -r 'echo "ready";' >/dev/null 2>&1; then
            erase_status_line
            if [ -n "${TREE_PREFIX:-}" ]; then
                tree_status_line "$TREE_PREFIX" "${GREEN}" "${ICON_OK}" "Appwrite container is ready"
            else
                printf '%b%s%b\n' "${GREEN}${BOLD}" "✓ Appwrite container is ready" "${NC}"
            fi
            return 0
        fi

        frame=$(( (attempt - 1) % spinner_count ))
        if [ -n "${TREE_PREFIX:-}" ]; then
            printf '\r%b%s%b%b%s%b' "${SOFT}" "${TREE_PREFIX}" "${NC}" "${CYAN}" "${SPINNER_FRAMES[$frame]} Waiting for Appwrite container readiness" "${NC}"
            clear_line
        else
            printf '\r%b%s%b %s' "${CYAN}" "${SPINNER_FRAMES[$frame]}" "${NC}" 'Waiting for Appwrite container readiness'
        fi
        sleep "$delay_seconds"
    done

    printf '\n'
    error "Appwrite container did not become ready in time"
    return 1
}

get_running_appwrite_version() {
    docker compose --project-directory "$APPWRITE_DIR" exec -T appwrite php -r '
        $constants = @file_get_contents("/usr/src/code/app/init/constants.php");
        if (!is_string($constants) || $constants === "") {
            fwrite(STDERR, "Failed to read constants.php\n");
            exit(1);
        }

        if (!preg_match("/const APP_VERSION_STABLE = '\''([^'\'']+)'\''/m", $constants, $matches)) {
            fwrite(STDERR, "Could not determine Appwrite runtime version\n");
            exit(1);
        }

        echo $matches[1];
    '
}

assert_running_appwrite_version() {
    local expected_version="$1"
    local actual_version

    actual_version="$(get_running_appwrite_version)"
    actual_version="$(normalize_version "$actual_version")"

    if [ "$actual_version" != "$expected_version" ]; then
        error "Running Appwrite version ${actual_version} does not match expected step ${expected_version}"
        return 1
    fi

    log_plain "[OK] Confirmed running Appwrite version ${actual_version}"
    return 0
}

# ---------- Prerequisite / argument handling ----------
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -v|--version)
                if [ "$#" -lt 2 ]; then
                    error "$1 requires a version value"
                    exit 1
                fi
                TARGET_VERSION="$(normalize_version "$2")"
                shift 2
                ;;
            -d|--appwrite-dir)
                if [ "$#" -lt 2 ]; then
                    error "$1 requires a directory value"
                    exit 1
                fi
                APPWRITE_DIR="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -y|--yes)
                ASSUME_YES=true
                shift
                ;;
            --no-cleanup)
                NO_CLEANUP=true
                shift
                ;;
            --no-restart)
                NO_RESTART=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                print_help
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                print_help
                exit 1
                ;;
        esac
    done
}

check_prerequisites() {
    if command -v tput >/dev/null 2>&1; then
        HAS_TPUT=true
    fi

    if command -v locale >/dev/null 2>&1 && [ "$(locale charmap 2>/dev/null || true)" = 'UTF-8' ]; then
        HAS_UNICODE=true
    fi

    set_spinner_frames

    require_command docker 'Install Docker / Docker Desktop and ensure it is available in PATH.'
    require_command curl 'Install curl and ensure it is available in PATH.'
    require_command jq 'Install jq from https://jqlang.org/download/'

    APPWRITE_DIR="$(expand_path "$APPWRITE_DIR")"

    if [ ! -d "$APPWRITE_DIR" ] || [ ! -f "$APPWRITE_DIR/docker-compose.yml" ]; then
        error "Appwrite directory not detected"
        subtle "Missing compose file: $APPWRITE_DIR/docker-compose.yml"
        exit 1
    fi

    APPWRITE_DIR="$(cd "$APPWRITE_DIR" && pwd)"

    if [ "$DRY_RUN" = false ] && ! docker info >/dev/null 2>&1; then
        error "Docker daemon is not running"
        subtle "Start Docker before proceeding."
        exit 1
    fi
}

# ---------- Release / boundary discovery ----------
load_migration_boundaries() {
    local versions_json_content=''
    local local_versions_json="$SCRIPT_DIR/versions.json"

    if [ -f "$local_versions_json" ]; then
        versions_json_content="$(<"$local_versions_json")"
        MIGRATION_SOURCE="local"
    else
        versions_json_content="$(curl -fsSL "$REMOTE_VERSIONS_JSON_URL")" || {
            error "Failed to load versions.json from repository"
            exit 1
        }
        MIGRATION_SOURCE="remote"
    fi

    while IFS= read -r version; do
        [ -n "$version" ] && MIGRATION_BOUNDARIES+=("$(normalize_version "$version")")
    done < <(printf '%s' "$versions_json_content" | jq -r '.versions[]')

    if [ "${#MIGRATION_BOUNDARIES[@]}" -eq 0 ]; then
        error "No migration boundaries were found in versions.json"
        exit 1
    fi
}

github_api_get() {
    local url="$1"
    local body_file="$2"
    local headers_file="$3"

    local -a curl_args=(
        -fsSL
        -D "$headers_file"
        -H "Accept: application/vnd.github+json"
        -H "X-GitHub-Api-Version: 2022-11-28"
        -H "User-Agent: appwrite-updater"
    )

    if [ -n "${GITHUB_TOKEN:-}" ]; then
        curl_args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    fi

    curl "${curl_args[@]}" "$url" -o "$body_file"
}

collect_release_versions_to_file() {
    local output_file="$1"
    local headers_file="$2"
    local page=1
    local page_count tag
    local fetched=()
    local body_file
    body_file="$(mktemp -t appwrite-updater-releases-body)"

    while true; do
        : > "$headers_file"
        github_api_get "${RELEASES_API_URL}?per_page=100&page=${page}" "$body_file" "$headers_file" || {
            cleanup_temp_file "$body_file"
            return 1
        }
        page_count="$(jq 'length' "$body_file")"

        if [ "$page_count" -eq 0 ]; then
            break
        fi

        while IFS= read -r tag; do
            [ -n "$tag" ] && fetched+=("$(normalize_version "$tag")")
        done < <(jq -r '.[] | select(.prerelease == false and .draft == false) | .tag_name' "$body_file")

        if [ "$page_count" -lt 100 ]; then
            break
        fi

        page=$((page + 1))
    done

    printf '%s\n' "${fetched[@]}" > "$output_file"
    cleanup_temp_file "$body_file"
}

fetch_release_versions() {
    local data_file capture_file headers_file
    data_file="$(mktemp -t appwrite-updater-releases.data)"
    capture_file="$(mktemp -t appwrite-updater-releases.log)"
    headers_file="$(mktemp -t appwrite-updater-releases.headers)"

    local description='Fetching Appwrite releases'
    local status=0

    run_with_tree_spinner_capture \
        '  ├─ ' \
        "$description" \
        "$capture_file" \
        collect_release_versions_to_file "$data_file" "$headers_file" || status=$?

    if [ "$status" -ne 0 ]; then
        local rate_remaining rate_reset
        rate_remaining="$(grep -i '^x-ratelimit-remaining:' "$headers_file" | awk '{print $2}' | tr -d '\r' || true)"
        rate_reset="$(grep -i '^x-ratelimit-reset:' "$headers_file" | awk '{print $2}' | tr -d '\r' || true)"

        if [ "${rate_remaining:-}" = "0" ]; then
            warn "GitHub API rate limit exceeded"
            [ -n "$rate_reset" ] && subtle "GitHub rate limit reset epoch: $rate_reset"
        else
            warn "Live GitHub release lookup failed"
        fi

        show_failure_output "$capture_file"
        cleanup_temp_file "$data_file"
        cleanup_temp_file "$capture_file"
        cleanup_temp_file "$headers_file"
        return 1
    fi

    RELEASE_VERSIONS=()
    while IFS= read -r tag; do
        [ -n "$tag" ] && RELEASE_VERSIONS+=("$tag")
    done < <(awk '!seen[$0]++' "$data_file")

    if [ "${#RELEASE_VERSIONS[@]}" -gt 1 ]; then
        local sorted_versions=()
        while IFS= read -r tag; do
            [ -n "$tag" ] && sorted_versions+=("$tag")
        done < <(sort_versions_desc "${RELEASE_VERSIONS[@]}")
        RELEASE_VERSIONS=("${sorted_versions[@]}")
    fi

    cleanup_temp_file "$data_file"
    cleanup_temp_file "$capture_file"
    cleanup_temp_file "$headers_file"
    HAS_RELEASE_DISCOVERY=true

    tree_leaf "Fetched ${#RELEASE_VERSIONS[@]} stable releases"
}

# ---------- Current version / target selection ----------
get_current_version() {
    local compose_file="$APPWRITE_DIR/docker-compose.yml"
    local detected
    local resolved_images

    resolved_images="$(docker compose --project-directory "$APPWRITE_DIR" config --images 2>/dev/null || true)"
    detected="$(printf '%s\n' "$resolved_images" | sed -nE 's/.*appwrite\/appwrite:([^[:space:]"'"'"'`]+).*/\1/p' | head -n 1)"

    if [ -z "$detected" ]; then
        detected="$(sed -nE 's/.*appwrite\/appwrite:([^[:space:]"'"'"'`]+).*/\1/p' "$compose_file" | head -n 1)"
    fi

    if [ -z "$detected" ]; then
        error "Could not detect current Appwrite version"
        subtle "Checked: $compose_file and docker compose config --images"
        exit 1
    fi

    detected="$(normalize_version "$detected")"

    if [[ "$detected" == *"\${"* ]]; then
        error "Detected dynamic Appwrite image tag"
        subtle "Please pin the Appwrite image version first."
        exit 1
    fi

    CURRENT_VERSION="$detected"
}

select_target_version() {
    local version
    local newer_versions=()
    local source_versions=()
    local index=1
    local default_target
    local -a card_lines=()

    if [ -n "$TARGET_VERSION" ]; then
        RESOLVED_TARGET_VERSION="$TARGET_VERSION"
        return
    fi

    if [ "$DRY_RUN" = true ]; then
        while IFS= read -r version; do
            [ -n "$version" ] && source_versions+=("$version")
        done < <(sort_versions_desc "${MIGRATION_BOUNDARIES[@]}")
    else
        source_versions=("${RELEASE_VERSIONS[@]}")
    fi

    for version in "${source_versions[@]}"; do
        if version_gt "$version" "$CURRENT_VERSION"; then
            newer_versions+=("$version")
        fi
    done

    if [ "${#newer_versions[@]}" -eq 0 ]; then
        RESOLVED_TARGET_VERSION="$CURRENT_VERSION"
        return
    fi

    default_target="${newer_versions[0]}"

    if [ "$ASSUME_YES" = true ] || [ ! -t 0 ]; then
        RESOLVED_TARGET_VERSION="$default_target"
        return
    fi

    for version in "${newer_versions[@]}"; do
        if [ "$version" = "$default_target" ] && is_boundary_minor "$version"; then
            card_lines+=("  ${index}. ${GREEN}${BOLD}${version}${NC}  $(badge success 'recommended') $(badge warn 'migration')")
        elif [ "$version" = "$default_target" ]; then
            card_lines+=("  ${index}. ${GREEN}${BOLD}${version}${NC}  $(badge success 'recommended')")
        elif is_boundary_minor "$version"; then
            card_lines+=("  ${index}. ${GREEN}${BOLD}${version}${NC}  $(badge warn 'migration')")
        else
            card_lines+=("  ${index}. ${SOFT}${version}${NC}")
        fi
        index=$((index + 1))
    done

    card \
        "Choose Target" \
        "$(kv_row 'Current' "$CURRENT_VERSION")" \
        "$(kv_row 'Suggested' "$default_target")" \
        "" \
        "Pick a target release. The suggested target is highlighted. Migration steps are marked." \
        "" \
        "${card_lines[@]}"

    echo
    prompt_or_exit "Target [default ${default_target}]: " RESOLVED_TARGET_VERSION
    if [ -z "$RESOLVED_TARGET_VERSION" ]; then
        RESOLVED_TARGET_VERSION="$default_target"
    else
        RESOLVED_TARGET_VERSION="$(normalize_version "$RESOLVED_TARGET_VERSION")"
    fi
}

# ---------- Plan building / confirmation ----------
validate_target_version() {
    local latest_known_boundary="${MIGRATION_BOUNDARIES[${#MIGRATION_BOUNDARIES[@]} - 1]}"

    if version_lt "$RESOLVED_TARGET_VERSION" "$CURRENT_VERSION"; then
        error "Target version ${RESOLVED_TARGET_VERSION} is older than current version ${CURRENT_VERSION}"
        exit 1
    fi

    if version_eq "$RESOLVED_TARGET_VERSION" "$CURRENT_VERSION"; then
        if [ "$DRY_RUN" = true ]; then
            return 0
        fi
        success "Already on the selected version (${CURRENT_VERSION})"
        exit 0
    fi

    if [ "$HAS_RELEASE_DISCOVERY" = true ] && ! contains_normalized_value "$RESOLVED_TARGET_VERSION" "${RELEASE_VERSIONS[@]}"; then
        error "Target version ${RESOLVED_TARGET_VERSION} was not found in the GitHub release list"
        exit 1
    fi

    if version_gt "$RESOLVED_TARGET_VERSION" "$latest_known_boundary" && \
        [ "$(major_minor "$RESOLVED_TARGET_VERSION")" != "$(major_minor "$latest_known_boundary")" ]; then
        error "Target version ${RESOLVED_TARGET_VERSION} is beyond the latest known migration boundary (${latest_known_boundary})"
        subtle "Refresh versions.json before attempting this upgrade."
        exit 1
    fi
}

build_plan() {
    local boundary
    local current_minor target_minor

    current_minor="$(major_minor "$CURRENT_VERSION")"
    target_minor="$(major_minor "$RESOLVED_TARGET_VERSION")"

    PLAN_VERSIONS=()
    PLAN_MIGRATIONS=()

    for boundary in "${MIGRATION_BOUNDARIES[@]}"; do
        if version_gt "$boundary" "$CURRENT_VERSION" && version_lt "$boundary" "$RESOLVED_TARGET_VERSION"; then
            PLAN_VERSIONS+=("$boundary")
            PLAN_MIGRATIONS+=("yes")
        fi
    done

    if version_gt "$RESOLVED_TARGET_VERSION" "$CURRENT_VERSION"; then
        if [ "$current_minor" != "$target_minor" ] && is_boundary_minor "$RESOLVED_TARGET_VERSION"; then
            PLAN_VERSIONS+=("$RESOLVED_TARGET_VERSION")
            PLAN_MIGRATIONS+=("yes")
        elif [ "$current_minor" != "$target_minor" ] && ! is_boundary_minor "$RESOLVED_TARGET_VERSION"; then
            PLAN_VERSIONS+=("$RESOLVED_TARGET_VERSION")
            PLAN_MIGRATIONS+=("yes")
        else
            PLAN_VERSIONS+=("$RESOLVED_TARGET_VERSION")
            PLAN_MIGRATIONS+=("no")
        fi
    fi
}

print_plan() {
    local step_count=${#PLAN_VERSIONS[@]}
    local index version migrate_label line
    local lines=()

    lines+=("$(kv_row 'Directory' "$APPWRITE_DIR")")
    lines+=("$(kv_row 'Current' "$CURRENT_VERSION")")
    lines+=("$(kv_row 'Target' "$RESOLVED_TARGET_VERSION")")
    lines+=("$(kv_row 'Boundaries' "$MIGRATION_SOURCE")")
    lines+=("$(kv_row 'Cleanup images' "$([ "$NO_CLEANUP" = true ] && echo 'disabled' || echo 'enabled')")")
    lines+=("$(kv_row 'Final restart' "$([ "$NO_RESTART" = true ] && echo 'disabled' || echo 'enabled')")")
    lines+=("$(kv_row '1.6.x patch' "$(runtime_patch_plan_status)")")
    lines+=("")
    lines+=("${BOLD}Steps${NC}")

    if [ "$step_count" -eq 0 ]; then
        lines+=("No steps required.")
    else
        for ((index = 0; index < step_count; index++)); do
            version="${PLAN_VERSIONS[$index]}"
            migrate_label="${PLAN_MIGRATIONS[$index]}"

            if step_requires_16x_runtime_patch "$version" "$migrate_label"; then
                line="$(printf '%d. Upgrade to %-10s migration   runtime patch' "$((index + 1))" "$version")"
            elif [ "$migrate_label" = 'yes' ]; then
                line="$(printf '%d. Upgrade to %-10s migration' "$((index + 1))" "$version")"
            else
                line="$(printf '%d. Upgrade to %s' "$((index + 1))" "$version")"
            fi
            lines+=("$line")
        done
    fi

    card "Upgrade Plan" "${lines[@]}"
}

confirm_execution() {
    if [ "$ASSUME_YES" = true ] || [ ! -t 0 ]; then
        return 0
    fi

    local response
    echo
    prompt_or_exit "Apply this plan? [y/N] " response
    response="$(printf '%s' "$response" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    case "$response" in
        y|yes)
            return 0
            ;;
        *)
            warn "Update cancelled"
            exit 0
            ;;
    esac
}

# ---------- Upgrade / migration execution helpers ----------
upgrade_to_version() {
    local version="$1"
    run_command "Upgrading Appwrite to ${version}" \
        docker run -i --rm \
            --volume /var/run/docker.sock:/var/run/docker.sock \
            --volume "${APPWRITE_DIR}:/usr/src/code/appwrite:rw" \
            --entrypoint upgrade \
            "appwrite/appwrite:${version}" <<< 'Y'
}

remove_previous_image() {
    local previous_version="$1"

    if [ "$NO_CLEANUP" = true ]; then
        return 0
    fi

    CLEANUP_IMAGES+=("$previous_version")
}

cleanup_queued_images() {
    if [ "$NO_CLEANUP" = true ] || [ "${#CLEANUP_IMAGES[@]}" -eq 0 ]; then
        return 0
    fi

    local seen=()
    local deduped=()
    local version
    local index
    local total

    for version in "${CLEANUP_IMAGES[@]}"; do
        if [ "${#seen[@]}" -gt 0 ] && contains_normalized_value "$version" "${seen[@]}"; then
            continue
        fi
        seen+=("$version")
        deduped+=("$version")
    done

    total="${#deduped[@]}"
    for ((index = 0; index < total; index++)); do
        version="${deduped[$index]}"
        if [ -n "${TREE_PREFIX:-}" ]; then
            TREE_PREFIX="$(tree_prefix_for_index "$((index + 1))" "$total")"
        fi

        if docker rmi "appwrite/appwrite:${version}" >> "$LOG_FILE" 2>&1; then
            if [ -n "${TREE_PREFIX:-}" ]; then
                tree_status_line "$TREE_PREFIX" "${GREEN}" "${ICON_OK}" "Removed appwrite/appwrite:${version}"
            else
                success "Removed appwrite/appwrite:${version}"
            fi
        else
            if [ -n "${TREE_PREFIX:-}" ]; then
                tree_status_line "$TREE_PREFIX" "${YELLOW}" "${ICON_WARN}" "Could not remove appwrite/appwrite:${version}; leaving it in place"
            else
                warn "Could not remove appwrite/appwrite:${version}; leaving it in place"
            fi
        fi
    done

    CLEANUP_IMAGES=()
}

collect_cleanup_preview_versions() {
    local versions=()
    local seen=()
    local index
    local version

    if [ "$NO_CLEANUP" = true ] || [ "${#PLAN_VERSIONS[@]}" -eq 0 ]; then
        return 0
    fi

    versions+=("$CURRENT_VERSION")
    for ((index = 0; index < ${#PLAN_VERSIONS[@]} - 1; index++)); do
        versions+=("${PLAN_VERSIONS[$index]}")
    done

    for version in "${versions[@]}"; do
        if [ "${#seen[@]}" -gt 0 ] && contains_normalized_value "$version" "${seen[@]}"; then
            continue
        fi
        seen+=("$version")
        printf '%s\n' "$version"
    done
}

print_preview_tree_lines() {
    local -a lines=("$@")
    local count="${#lines[@]}"
    local index

    if [ "$count" -eq 0 ]; then
        return 0
    fi

    for ((index = 0; index < count; index++)); do
        if [ "$index" -eq $((count - 1)) ]; then
            tree_leaf "${lines[$index]}"
        else
            tree_line "${lines[$index]}"
        fi
    done
}

count_step_actions() {
    local version="$1"
    local should_migrate="$2"
    local count=3

    if [ "$should_migrate" = 'yes' ]; then
        count=$((count + 1))
        if step_requires_16x_runtime_patch "$version" "$should_migrate"; then
            count=$((count + 4))
        fi
    fi

    printf '%s\n' "$count"
}

preview_execution_plan() {
    local step_count="${#PLAN_VERSIONS[@]}"
    local index step_version should_migrate
    local performed_migration=false
    local -a actions=()

    section "Execution"
    if [ "$step_count" -eq 0 ]; then
        tree_leaf "No execution steps required."
        return 0
    fi

    for ((index = 0; index < step_count; index++)); do
        step_version="${PLAN_VERSIONS[$index]}"
        should_migrate="${PLAN_MIGRATIONS[$index]}"
        actions=()

        echo
        printf '%bStep %d/%d%b  %s\n' "${BOLD}${WHITE}" "$((index + 1))" "$step_count" "${NC}" "$step_version"

        actions+=("Upgrade Appwrite to ${step_version}")
        actions+=("Wait for Appwrite readiness")
        actions+=("Verify Appwrite runtime version ${step_version}")

        if [ "$should_migrate" = 'yes' ]; then
            if step_requires_16x_runtime_patch "$step_version" "$should_migrate"; then
                actions+=("Validate Appwrite ${step_version} migration runtime patch preconditions")
                actions+=("Patch Appwrite ${step_version} migration runtime")
                actions+=("Verify Appwrite ${step_version} migration runtime patch")
            fi

            actions+=("Run migration for ${step_version}")
            performed_migration=true

            if step_requires_16x_runtime_patch "$step_version" "$should_migrate"; then
                actions+=("Restore original Appwrite ${step_version} migration runtime")
            fi
        fi

        print_preview_tree_lines "${actions[@]}"
    done

    if [ "$performed_migration" = true ] && [ "$NO_RESTART" = false ]; then
        echo
        tree_leaf "Restart Appwrite services"
    fi
}

preview_cleanup_plan() {
    local cleanup_preview=()
    local -a cleanup_lines=()
    local version

    section "Cleanup"
    if [ "$NO_CLEANUP" = true ]; then
        tree_leaf "Old Appwrite images will be kept after the run."
        return 0
    fi

    while IFS= read -r version; do
        [ -n "$version" ] && cleanup_preview+=("$version")
    done < <(collect_cleanup_preview_versions)

    if [ "${#cleanup_preview[@]}" -eq 0 ]; then
        tree_leaf "No old Appwrite images queued for removal."
        return 0
    fi

    for version in "${cleanup_preview[@]}"; do
        cleanup_lines+=("Remove appwrite/appwrite:${version}")
    done
    print_preview_tree_lines "${cleanup_lines[@]}"
}

# ---------- 1.6.x migration runtime patch ----------
version_is_16x() {
    [ "$(major_minor "$1")" = '1.6' ]
}

step_requires_16x_runtime_patch() {
    local version="$1"
    local should_migrate="$2"

    [ "$should_migrate" = 'yes' ] && version_is_16x "$version"
}

plan_requires_16x_runtime_patch() {
    local index

    for ((index = 0; index < ${#PLAN_VERSIONS[@]}; index++)); do
        if step_requires_16x_runtime_patch "${PLAN_VERSIONS[$index]}" "${PLAN_MIGRATIONS[$index]}"; then
            return 0
        fi
    done

    return 1
}

runtime_patch_plan_status() {
    if plan_requires_16x_runtime_patch; then
        echo 'required'
    else
        echo 'not needed'
    fi
}

preflight_16x_sync_iterator_runtime_patch() {
    local expected_version="$1"
    local temp_script
    temp_script="$(mktemp -t appwrite-updater-16x-preflight.XXXXXX.php)"

    cat > "$temp_script" <<PHP
<?php
\$expectedVersion = '${expected_version}';
\$file = '/usr/src/code/src/Appwrite/Migration/Migration.php';
\$constantsFile = '/usr/src/code/app/init/constants.php';
\$backup = '${MIGRATION_RUNTIME_BACKUP_PATH}';

\$knownOriginalHashes = [
    '1.6.0' => '251e6a78f4f96e577f238aa88b6623b780088a2e04bba67f7fa471a9d6b92a32',
    '1.6.1' => '59d8ee0aae0c29c99b64245960dbe0c92aa9d2bd1741b751e2a69fb025512807',
    '1.6.2' => '44dfae138831aa9fc487cc555dc02088eeb3e470bb2380d5c17e832c14f619dd',
];

\$knownPatchedHashes = [
    '1.6.0' => 'ae295b24d6ce533dce763522c832b1b6936852da38c9d6ef557a3dac823277ba',
    '1.6.1' => '9feef0dac240359bd57508220c2c0321a19e2cb2e2690aeae475df48f064e3f9',
    '1.6.2' => '1a310a28622fa8317813dbd040f3e560cac0ed30ad08a2d82167f631d385e6ba',
];

if (!is_file(\$constantsFile)) {
    fwrite(STDERR, "Missing Appwrite constants file: {\$constantsFile}\\n");
    exit(1);
}

\$constants = file_get_contents(\$constantsFile);
if (\$constants === false) {
    fwrite(STDERR, "Failed to read {\$constantsFile}\\n");
    exit(1);
}

if (!preg_match("/const APP_VERSION_STABLE = '([^']+)'/m", \$constants, \$matches)) {
    fwrite(STDERR, "Could not determine Appwrite runtime version from constants.php\\n");
    exit(1);
}

\$runtimeVersion = \$matches[1];
if (!isset(\$knownOriginalHashes[\$runtimeVersion])) {
    fwrite(STDERR, "Unsupported Appwrite runtime version for 1.6.x patch: {\$runtimeVersion}\\n");
    exit(1);
}

if (\$runtimeVersion !== \$expectedVersion) {
    fwrite(STDERR, "Running Appwrite runtime version {\$runtimeVersion} does not match expected step {\$expectedVersion}\\n");
    exit(1);
}

if (!is_file(\$file)) {
    fwrite(STDERR, "Missing migration runtime file: {\$file}\\n");
    exit(1);
}

\$currentHash = hash_file('sha256', \$file);
if (\$currentHash === false) {
    fwrite(STDERR, "Failed to hash {\$file}\\n");
    exit(1);
}

\$expectedOriginal = \$knownOriginalHashes[\$runtimeVersion];
\$expectedPatched = \$knownPatchedHashes[\$runtimeVersion];

if (\$currentHash === \$expectedOriginal) {
    if (is_file(\$backup)) {
        \$backupHash = hash_file('sha256', \$backup);
        if (\$backupHash === false) {
            fwrite(STDERR, "Failed to hash migration runtime backup\\n");
            exit(1);
        }

        if (\$backupHash !== \$expectedOriginal) {
            fwrite(STDERR, "Migration runtime backup hash mismatch for {\$runtimeVersion}\\n");
            exit(1);
        }
    }

    fwrite(STDOUT, "Validated Appwrite {\$runtimeVersion} runtime in original state\\n");
    exit(0);
}

if (\$currentHash === \$expectedPatched) {
    if (!is_file(\$backup)) {
        fwrite(STDERR, "Runtime is already patched for {\$runtimeVersion} but original backup is missing\\n");
        exit(1);
    }

    \$backupHash = hash_file('sha256', \$backup);
    if (\$backupHash === false) {
        fwrite(STDERR, "Failed to hash migration runtime backup\\n");
        exit(1);
    }

    if (\$backupHash !== \$expectedOriginal) {
        fwrite(STDERR, "Patched runtime backup does not match the expected original file for {\$runtimeVersion}\\n");
        exit(1);
    }

    fwrite(STDOUT, "Validated Appwrite {\$runtimeVersion} runtime in patched state with original backup\\n");
    exit(0);
}

fwrite(STDERR, "Unexpected Migration.php hash for Appwrite {\$runtimeVersion}: {\$currentHash}\\n");
exit(1);
PHP

    docker compose --project-directory "$APPWRITE_DIR" exec -T appwrite php < "$temp_script"
    local status=$?
    cleanup_temp_file "$temp_script"
    return "$status"
}

patch_16x_sync_iterator_runtime() {
    local temp_script
    temp_script="$(mktemp -t appwrite-updater-16x-patch.XXXXXX.php)"

    cat > "$temp_script" <<PHP
<?php
\$file = '/usr/src/code/src/Appwrite/Migration/Migration.php';
\$backup = '${MIGRATION_RUNTIME_BACKUP_PATH}';
\$code = file_get_contents(\$file);
if (\$code === false) {
    fwrite(STDERR, "Failed to read {\$file}\\n");
    exit(1);
}

\$old = <<<'CODE'
            foreach (\$this->documentsIterator(\$collection['\$id']) as \$document) {
                go(function (Document \$document, callable \$callback) {
                    if (empty(\$document->getId()) || empty(\$document->getCollection())) {
                        return;
                    }

                    \$old = \$document->getArrayCopy();
                    \$new = call_user_func(\$callback, \$document);

                    if (is_null(\$new) || \$new->getArrayCopy() == \$old) {
                        return;
                    }

                    try {
                        \$this->projectDB->updateDocument(\$document->getCollection(), \$document->getId(), \$document);
                    } catch (\\Throwable \$th) {
                        Console::error('Failed to update document: ' . \$th->getMessage());
                        return;
                    }
                }, \$document, \$callback);
            }
CODE;

\$new = <<<'CODE'
            foreach (\$this->documentsIterator(\$collection['\$id']) as \$document) {
                if (empty(\$document->getId()) || empty(\$document->getCollection())) {
                    continue;
                }

                \$old = \$document->getArrayCopy();
                \$new = call_user_func(\$callback, \$document);

                if (is_null(\$new) || \$new->getArrayCopy() == \$old) {
                    continue;
                }

                try {
                    \$this->projectDB->updateDocument(\$document->getCollection(), \$document->getId(), \$document);
                } catch (\\Throwable \$th) {
                    Console::error('Failed to update document: ' . \$th->getMessage());
                    continue;
                }
            }
CODE;

if (str_contains(\$code, \$new)) {
    fwrite(STDOUT, "Patch already applied\\n");
    exit(0);
}

if (!str_contains(\$code, \$old)) {
    fwrite(STDERR, "Expected Appwrite 1.6.x migration iterator block not found\\n");
    exit(1);
}

if (!file_exists(\$backup) && file_put_contents(\$backup, \$code) === false) {
    fwrite(STDERR, "Failed to create migration runtime backup\\n");
    exit(1);
}

\$patched = str_replace(\$old, \$new, \$code, \$count);
if (\$count !== 1) {
    fwrite(STDERR, "Unexpected replacement count: {\$count}\\n");
    exit(1);
}

if (file_put_contents(\$file, \$patched) === false) {
    fwrite(STDERR, "Failed to write patched Migration.php\\n");
    exit(1);
}

fwrite(STDOUT, "Patched Migration.php successfully\\n");
PHP

    docker compose --project-directory "$APPWRITE_DIR" exec -T appwrite php < "$temp_script"
    local status=$?
    cleanup_temp_file "$temp_script"
    return "$status"
}

verify_16x_sync_iterator_runtime_patch() {
    local temp_script
    temp_script="$(mktemp -t appwrite-updater-16x-verify.XXXXXX.php)"

    cat > "$temp_script" <<'PHP'
<?php
$file = '/usr/src/code/src/Appwrite/Migration/Migration.php';
$code = file_get_contents($file);
if ($code === false) {
    fwrite(STDERR, "Failed to read {$file}\n");
    exit(1);
}

$old = <<<'CODE'
                go(function (Document $document, callable $callback) {
CODE;

$new = <<<'CODE'
                if (empty($document->getId()) || empty($document->getCollection())) {
                    continue;
                }
CODE;

if (str_contains($code, $old)) {
    fwrite(STDERR, "Coroutine iterator block is still present\n");
    exit(1);
}

if (!str_contains($code, $new)) {
    fwrite(STDERR, "Synchronous iterator block was not found\n");
    exit(1);
}

fwrite(STDOUT, "Verified patched Migration.php\n");
PHP

    docker compose --project-directory "$APPWRITE_DIR" exec -T appwrite php < "$temp_script"
    local status=$?
    cleanup_temp_file "$temp_script"
    return "$status"
}

restore_16x_sync_iterator_runtime() {
    docker compose --project-directory "$APPWRITE_DIR" exec -T appwrite sh -lc '
        backup="'"${MIGRATION_RUNTIME_BACKUP_PATH}"'"
        target="/usr/src/code/src/Appwrite/Migration/Migration.php"

        if [ ! -f "$backup" ]; then
            exit 0
        fi

        cp "$backup" "$target" && rm -f "$backup"
    '
}

restore_16x_sync_iterator_runtime_if_present() {
    local version="$1"
    if ! run_command "Restoring original Appwrite ${version} migration runtime" restore_16x_sync_iterator_runtime; then
        warn "Continuing with patched ${version} runtime because restore failed after a successful migration"
    fi
}

print_16x_patch_warning() {
    local runtime_patch_doc_url="https://github.com/ItzNotABug/appwriteupdaterscript/blob/master/RUNTIME-PATCH.md"

    if ! plan_requires_16x_runtime_patch; then
        return 0
    fi

    echo
    warn "1.6.x runtime patch will be applied automatically during the migration step"
    subtle "Docs: ${runtime_patch_doc_url}"
}

on_exit() {
    show_cursor
}

on_interrupt() {
    show_cursor
    printf '\n' >&2

    if [ -n "$ACTIVE_COMMAND_PID" ] && kill -0 "$ACTIVE_COMMAND_PID" >/dev/null 2>&1; then
        warn "Stopping active command: ${ACTIVE_COMMAND_DESCRIPTION:-background task}"
        kill -TERM "$ACTIVE_COMMAND_PID" >/dev/null 2>&1 || true
        sleep 1
        if kill -0 "$ACTIVE_COMMAND_PID" >/dev/null 2>&1; then
            kill -KILL "$ACTIVE_COMMAND_PID" >/dev/null 2>&1 || true
        fi
        wait "$ACTIVE_COMMAND_PID" 2>/dev/null || true
    fi

    ACTIVE_COMMAND_PID=''
    ACTIVE_COMMAND_DESCRIPTION=''
    warn "Interrupted"
    exit 130
}

restart_appwrite() {
    if [ "$NO_RESTART" = true ]; then
        return 0
    fi

    run_command "Restarting Appwrite services" docker compose --project-directory "$APPWRITE_DIR" restart
}

# ---------- Entrypoint ----------
main() {
    parse_args "$@"
    init_log_file
    trap on_exit EXIT
    trap on_interrupt INT TERM
    check_prerequisites
    print_banner

    section "Preflight"
    load_migration_boundaries
    get_current_version

    tree_line "Directory: $APPWRITE_DIR"
    tree_line "Current version: $CURRENT_VERSION"
    if [ "$NO_CLEANUP" = true ]; then
        tree_note "Old Appwrite images will be kept after the run."
    else
        tree_note "Old Appwrite images will be removed after the full run completes."
    fi

    if [ -n "$TARGET_VERSION" ]; then
        tree_leaf "Requested target: $TARGET_VERSION"
    else
        if [ "$DRY_RUN" = true ]; then
            :
        elif fetch_release_versions; then
            :
        else
            error "Could not fetch releases and no explicit --version was provided"
            exit 1
        fi
    fi

    section "Planning"
    select_target_version
    validate_target_version
    build_plan
    print_plan
    print_16x_patch_warning

    if [ "$DRY_RUN" = true ]; then
        preview_execution_plan
        preview_cleanup_plan

        echo
        print_summary_card \
            "Upgrade Complete" \
            "$(kv_row 'From' "$CURRENT_VERSION")" \
            "$(kv_row 'To' "$RESOLVED_TARGET_VERSION")" \
            "$(kv_row 'Log file' "disabled in dry-run")"

        echo
        success "Dry run complete"
        subtle "Preview only. No changes applied."
        exit 0
    fi

    confirm_execution

    local previous_version="$CURRENT_VERSION"
    local performed_migration=false
    local step_count=${#PLAN_VERSIONS[@]}
    local index step_version should_migrate
    local action_count action_index

    section "Execution"
    for ((index = 0; index < step_count; index++)); do
        step_version="${PLAN_VERSIONS[$index]}"
        should_migrate="${PLAN_MIGRATIONS[$index]}"
        action_count="$(count_step_actions "$step_version" "$should_migrate")"
        action_index=0

        echo
        printf '%bStep %d/%d%b  %s\n' "${BOLD}${WHITE}" "$((index + 1))" "$step_count" "${NC}" "$step_version"

        action_index=$((action_index + 1))
        TREE_PREFIX="$(tree_prefix_for_index "$action_index" "$action_count")"
        upgrade_to_version "$step_version"
        action_index=$((action_index + 1))
        TREE_PREFIX="$(tree_prefix_for_index "$action_index" "$action_count")"
        wait_for_appwrite_ready
        action_index=$((action_index + 1))
        TREE_PREFIX="$(tree_prefix_for_index "$action_index" "$action_count")"
        run_command "Verifying Appwrite runtime version ${step_version}" assert_running_appwrite_version "$step_version"

        if [ "$should_migrate" = 'yes' ]; then
            if step_requires_16x_runtime_patch "$step_version" "$should_migrate"; then
                action_index=$((action_index + 1))
                TREE_PREFIX="$(tree_prefix_for_index "$action_index" "$action_count")"
                run_command "Validating Appwrite ${step_version} migration runtime patch preconditions" preflight_16x_sync_iterator_runtime_patch "$step_version"

                action_index=$((action_index + 1))
                TREE_PREFIX="$(tree_prefix_for_index "$action_index" "$action_count")"
                run_command "Patching Appwrite ${step_version} migration runtime" patch_16x_sync_iterator_runtime

                action_index=$((action_index + 1))
                TREE_PREFIX="$(tree_prefix_for_index "$action_index" "$action_count")"
                run_command "Verifying Appwrite ${step_version} migration runtime patch" verify_16x_sync_iterator_runtime_patch
            fi

            action_index=$((action_index + 1))
            TREE_PREFIX="$(tree_prefix_for_index "$action_index" "$action_count")"
            run_migration_command "$step_version"
            performed_migration=true

            if step_requires_16x_runtime_patch "$step_version" "$should_migrate"; then
                action_index=$((action_index + 1))
                TREE_PREFIX="$(tree_prefix_for_index "$action_index" "$action_count")"
                restore_16x_sync_iterator_runtime_if_present "$step_version"
            fi
        fi

        remove_previous_image "$previous_version"
        TREE_PREFIX=''
        previous_version="$step_version"
    done

    if [ "$performed_migration" = true ]; then
        echo
        TREE_PREFIX='  └─ '
        restart_appwrite
        TREE_PREFIX=''
    fi

    if [ "$NO_CLEANUP" = false ] && [ "${#CLEANUP_IMAGES[@]}" -gt 0 ]; then
        section "Cleanup"
        TREE_PREFIX='  ├─ '
        cleanup_queued_images
        TREE_PREFIX=''
    fi

    print_summary_card \
        "Upgrade Complete" \
        "$(kv_row 'From' "$CURRENT_VERSION")" \
        "$(kv_row 'To' "$RESOLVED_TARGET_VERSION")" \
        "$(kv_row 'Log file' "$LOG_FILE")"

    success "Upgrade completed"
}

main "$@"
