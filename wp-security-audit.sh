#!/usr/bin/env bash
# =============================================================================
# WordPress Security Audit Script
# Version: 2.2.0
# Usage: sudo bash wp-security-audit.sh /path/to/wordpress [--full] [--verbose]
# =============================================================================

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m';   YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m';  BOLD='\033[1m';      DIM='\033[2m';    RESET='\033[0m'
BRED='\033[1;31m';  BGREEN='\033[1;32m'; BBLUE='\033[1;34m'
BYELLOW='\033[1;33m'

# ─── Globals ─────────────────────────────────────────────────────────────────
WP_PATH=""
REPORT_DIR="/tmp/wp-audit-$$"
LOG_FILE=""
VERBOSE=false
FULL_SCAN=false
SCAN_START=$(date +%s)
ISSUE_COUNT=0; WARN_COUNT=0; INFO_COUNT=0; CRITICAL_COUNT=0
WP_VERSION="unknown"; PHP_VERSION="unknown"
HAS_CURL=false; HAS_MYSQL=false; HAS_WPCLI=false
SPINNER_PID=""

# Per-section result buffers (written to log, shown in summary)
declare -a SECTION_NAMES
declare -a SECTION_STATUS   # OK | WARN | HIGH | CRITICAL
declare -a SECTION_COUNTS   # "C:0 H:1 W:2"

CURRENT_SECTION=""
CURRENT_CRITICAL=0; CURRENT_HIGH=0; CURRENT_WARN=0

# ─── Usage ───────────────────────────────────────────────────────────────────
usage() {
    echo -e "${BOLD}WordPress Security Audit v2.2.0${RESET}"
    echo ""
    echo "Usage: sudo bash $0 <wordpress-path> [options]"
    echo "  --full      Deep scan (all files including core)"
    echo "  --verbose   Show all findings as they happen (no progress UI)"
    echo "  --help      Show this help"
    exit 0
}

parse_args() {
    [[ $# -eq 0 ]] && usage
    for arg in "$@"; do
        case "$arg" in
            --help|-h)   usage ;;
            --full)      FULL_SCAN=true ;;
            --verbose)   VERBOSE=true ;;
            -*)          echo "Unknown option: $arg"; usage ;;
            *)           WP_PATH="${arg%/}" ;;
        esac
    done
    [[ -z "$WP_PATH" ]] && { echo "Error: path required."; usage; }
}

# ─── Spinner ──────────────────────────────────────────────────────────────────
spinner_start() {
    local label="$1"
    if $VERBOSE; then
        echo -e "\n${BBLUE}▶ ${BOLD}${label}${RESET}"
        return
    fi
    # Kill any existing spinner
    spinner_stop 2>/dev/null || true

    (
        local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
        local i=0
        while true; do
            printf "\r  ${CYAN}%s${RESET}  ${DIM}%-50s${RESET}" \
                "${frames[$((i % ${#frames[@]}))]}" "$label"
            sleep 0.1
            i=$((i+1))
        done
    ) &
    SPINNER_PID=$!
    disown "$SPINNER_PID" 2>/dev/null || true
}

spinner_stop() {
    if [[ -n "$SPINNER_PID" ]]; then
        kill "$SPINNER_PID" 2>/dev/null || true
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
        printf "\r%-70s\r" " "  # clear the line
    fi
}

# ─── Section Management ───────────────────────────────────────────────────────
section_start() {
    CURRENT_SECTION="$1"
    CURRENT_CRITICAL=0; CURRENT_HIGH=0; CURRENT_WARN=0
    echo "" >> "$LOG_FILE"
    echo "## $1" >> "$LOG_FILE"
    echo "$(printf '─%.0s' {1..64})" >> "$LOG_FILE"
    spinner_start "$1"
}

section_end() {
    spinner_stop

    # Determine worst severity for this section
    local status="OK"
    local label color
    [[ "$CURRENT_WARN" -gt 0 ]]     && status="WARN"
    [[ "$CURRENT_HIGH" -gt 0 ]]     && status="HIGH"
    [[ "$CURRENT_CRITICAL" -gt 0 ]] && status="CRITICAL"

    case "$status" in
        OK)       label="${GREEN}✓  PASS${RESET}";     color="$GREEN" ;;
        WARN)     label="${YELLOW}⚠  WARN${RESET}";    color="$YELLOW" ;;
        HIGH)     label="${RED}✗  ISSUES${RESET}";     color="$RED" ;;
        CRITICAL) label="${BRED}✗  CRITICAL${RESET}";  color="$BRED" ;;
    esac

    # Build counts string
    local counts=""
    [[ "$CURRENT_CRITICAL" -gt 0 ]] && counts+="${BRED}${CURRENT_CRITICAL} crit${RESET} "
    [[ "$CURRENT_HIGH" -gt 0 ]]     && counts+="${RED}${CURRENT_HIGH} high${RESET} "
    [[ "$CURRENT_WARN" -gt 0 ]]     && counts+="${YELLOW}${CURRENT_WARN} warn${RESET}"

    if ! $VERBOSE; then
        local section_short
        # Truncate section name to fit
        section_short=$(echo "$CURRENT_SECTION" | cut -c1-42)
        printf "  %-44s %s\n" "$section_short" "$(echo -e "$label")"
        [[ -n "$counts" ]] && printf "  ${DIM}%-44s %s${RESET}\n" "" "$(echo -e "$counts")"
    fi

    # Store for final summary
    SECTION_NAMES+=("$CURRENT_SECTION")
    SECTION_STATUS+=("$status")
    SECTION_COUNTS+=("C:${CURRENT_CRITICAL} H:${CURRENT_HIGH} W:${CURRENT_WARN}")
}

# ─── Finding Logger ───────────────────────────────────────────────────────────
finding() {
    local severity="$1"
    local message="$2"
    local detail="${3:-}"

    case "$severity" in
        CRITICAL)
            CRITICAL_COUNT=$((CRITICAL_COUNT+1))
            ISSUE_COUNT=$((ISSUE_COUNT+1))
            CURRENT_CRITICAL=$((CURRENT_CRITICAL+1))
            echo "  [CRITICAL] $message" >> "$LOG_FILE"
            $VERBOSE && echo -e "  ${BRED}[CRITICAL]${RESET} $message"
            ;;
        HIGH)
            ISSUE_COUNT=$((ISSUE_COUNT+1))
            CURRENT_HIGH=$((CURRENT_HIGH+1))
            echo "  [HIGH]     $message" >> "$LOG_FILE"
            $VERBOSE && echo -e "  ${RED}[HIGH]${RESET}     $message"
            ;;
        WARN)
            WARN_COUNT=$((WARN_COUNT+1))
            CURRENT_WARN=$((CURRENT_WARN+1))
            echo "  [WARN]     $message" >> "$LOG_FILE"
            $VERBOSE && echo -e "  ${YELLOW}[WARN]${RESET}     $message"
            ;;
        INFO)
            INFO_COUNT=$((INFO_COUNT+1))
            echo "  [INFO]     $message" >> "$LOG_FILE"
            $VERBOSE && echo -e "  ${CYAN}[INFO]${RESET}     $message"
            ;;
        OK)
            echo "  [OK]       $message" >> "$LOG_FILE"
            $VERBOSE && echo -e "  ${GREEN}[OK]${RESET}       $message"
            ;;
    esac

    if [[ -n "$detail" ]]; then
        echo "             └─ $detail" >> "$LOG_FILE"
        $VERBOSE && echo -e "  ${DIM}            └─ $detail${RESET}"
    fi
}

log_detail() {
    echo "             └─ $1" >> "$LOG_FILE"
    $VERBOSE && echo -e "  ${DIM}            └─ $1${RESET}"
}

# ─── Setup ────────────────────────────────────────────────────────────────────
setup() {
    mkdir -p "$REPORT_DIR"
    local TS; TS=$(date '+%Y%m%d_%H%M%S')
    LOG_FILE="${REPORT_DIR}/wp-audit-${TS}.txt"
    {
        echo "================================================================"
        echo " WordPress Security Audit Report"
        echo " Generated : $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo " Host      : $(hostname -f 2>/dev/null || hostname)"
        echo " Scan Path : ${WP_PATH}"
        echo " Mode      : $(if $FULL_SCAN; then echo 'Full'; else echo 'Standard'; fi)"
        echo " Script    : wp-security-audit.sh v2.2.0"
        echo "================================================================"
    } > "$LOG_FILE"
}

print_banner() {
    clear 2>/dev/null || true
    echo ""
    echo -e "${BBLUE}  ╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BBLUE}  ║   ${BOLD}WordPress Security Audit${RESET}${BBLUE}  v2.2.0                     ║${RESET}"
    echo -e "${BBLUE}  ╚══════════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "  ${DIM}Path:  ${WP_PATH}${RESET}"
    echo -e "  ${DIM}Mode:  $(if $FULL_SCAN; then echo 'Full scan'; else echo 'Standard scan'; fi)${RESET}"
    echo ""
    echo -e "  ${DIM}$(printf '─%.0s' {1..56})${RESET}"
    echo ""
}

# ─── Checks ───────────────────────────────────────────────────────────────────

check_deps() {
    section_start "Dependencies & Tools"
    local missing=()
    for dep in find grep awk sed stat php; do
        command -v "$dep" &>/dev/null || missing+=("$dep")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        finding CRITICAL "Missing required tools: ${missing[*]}"
        section_end; exit 1
    fi
    finding OK "Core tools available"
    command -v curl   &>/dev/null && { HAS_CURL=true;  finding OK  "curl found"; } \
                                  || finding INFO "curl not found — remote checks limited"
    command -v mysql  &>/dev/null && { HAS_MYSQL=true; finding OK  "MySQL client found"; } \
                                  || finding INFO "MySQL client not found — DB checks skipped"
    command -v wp     &>/dev/null && { HAS_WPCLI=true; finding OK  "WP-CLI found"; } \
                                  || finding INFO "WP-CLI not found — some checks limited"
    section_end
}

check_wp_path() {
    section_start "WordPress Installation"
    [[ ! -d "$WP_PATH" ]] && { finding CRITICAL "Path does not exist: ${WP_PATH}"; section_end; exit 1; }
    if [[ ! -f "${WP_PATH}/wp-login.php" ]] || [[ ! -f "${WP_PATH}/wp-config.php" ]]; then
        finding HIGH "wp-login.php or wp-config.php missing"
    else
        finding OK "Valid WordPress installation"
    fi
    [[ -f "${WP_PATH}/wp-includes/version.php" ]] && \
        WP_VERSION=$(grep "\$wp_version" "${WP_PATH}/wp-includes/version.php" 2>/dev/null \
                     | head -1 | cut -d"'" -f2 || echo "unknown")
    PHP_VERSION=$(php -r 'echo PHP_VERSION;' 2>/dev/null || echo "unknown")
    finding INFO "WordPress ${WP_VERSION} / PHP ${PHP_VERSION}"
    [[ "$(id -u)" -ne 0 ]] && finding WARN "Not running as root — some checks may be incomplete"
    section_end
}

check_file_permissions() {
    section_start "File & Directory Permissions"

    # wp-config.php
    if [[ -f "${WP_PATH}/wp-config.php" ]]; then
        local perm; perm=$(stat -c '%a' "${WP_PATH}/wp-config.php" 2>/dev/null || echo "???")
        case "$perm" in
            600|640) finding OK "wp-config.php permissions: ${perm}" ;;
            644)     finding WARN "wp-config.php is world-readable (${perm}) — use chmod 640" ;;
            *)       finding HIGH "wp-config.php unsafe permissions: ${perm}" ;;
        esac
    fi

    # World-writable PHP outside uploads
    local ww
    ww=$(find "$WP_PATH" -type f -name "*.php" -perm -0002 ! -path "*/uploads/*" 2>/dev/null || true)
    local wwc; wwc=$(echo "$ww" | grep -c . 2>/dev/null || echo 0)
    if [[ -n "$ww" ]] && [[ "$wwc" -gt 0 ]]; then
        finding HIGH "World-writable PHP files outside uploads: ${wwc}"
        echo "$ww" | head -10 | while IFS= read -r f; do log_detail "$f"; done
    else
        finding OK "No world-writable PHP files outside uploads"
    fi

    # 777 directories
    local bad777; bad777=$(find "$WP_PATH" -type d -perm 777 2>/dev/null | head -20 || true)
    if [[ -n "$bad777" ]]; then
        local b77c; b77c=$(echo "$bad777" | grep -c . || echo 0)
        finding HIGH "Directories with 777 permissions: ${b77c}"
        echo "$bad777" | while IFS= read -r d; do log_detail "$d"; done
    else
        finding OK "No 777 directories"
    fi

    # PHP in uploads
    local uploads_dir="${WP_PATH}/wp-content/uploads"
    if [[ -d "$uploads_dir" ]]; then
        local phpup; phpup=$(find "$uploads_dir" -type f -name "*.php" 2>/dev/null || true)
        local phpupc; phpupc=$(echo "$phpup" | grep -c . 2>/dev/null || echo 0)
        if [[ -n "$phpup" ]] && [[ "$phpupc" -gt 0 ]]; then
            finding CRITICAL "PHP files in uploads/: ${phpupc} (RCE risk!)"
            echo "$phpup" | head -10 | while IFS= read -r f; do log_detail "$f"; done
        else
            finding OK "No PHP files in uploads/"
        fi
    fi

    section_end
}

check_wpconfig() {
    section_start "wp-config.php Security"
    local cfg="${WP_PATH}/wp-config.php"
    [[ ! -f "$cfg" ]] && { finding WARN "wp-config.php not found"; section_end; return; }

    local kc; kc=$(grep -c "define.*_KEY\|define.*_SALT" "$cfg" 2>/dev/null || echo 0)
    [[ "$kc" -ge 8 ]] && finding OK "All secret keys/salts defined" \
                      || finding HIGH "Only ${kc}/8 secret keys defined"

    grep -q "put your unique phrase here" "$cfg" 2>/dev/null && \
        finding CRITICAL "Default placeholder secret keys still in use!"

    grep -q "define.*WP_DEBUG.*true" "$cfg" 2>/dev/null && \
        finding WARN "WP_DEBUG enabled on production" || finding OK "WP_DEBUG is off"

    grep -q "define.*WP_DEBUG_DISPLAY.*true" "$cfg" 2>/dev/null && \
        finding HIGH "WP_DEBUG_DISPLAY=true — errors exposed to visitors"

    local prefix; prefix=$(grep "^\$table_prefix" "$cfg" 2>/dev/null | head -1 | cut -d"'" -f2 || echo "wp_")
    [[ "$prefix" == "wp_" ]] && finding WARN "Default DB prefix 'wp_' in use" \
                              || finding OK "Custom table prefix: ${prefix}"

    grep -q "define.*DISALLOW_FILE_EDIT.*true" "$cfg" 2>/dev/null && \
        finding OK "DISALLOW_FILE_EDIT = true" || \
        finding WARN "DISALLOW_FILE_EDIT not set — PHP editable from WP admin"

    grep -q "define.*FORCE_SSL_ADMIN.*true" "$cfg" 2>/dev/null && \
        finding OK "FORCE_SSL_ADMIN enabled" || \
        finding WARN "FORCE_SSL_ADMIN not set"

    section_end
}

check_core_integrity() {
    section_start "Core File Integrity"

    if $HAS_WPCLI; then
        local out; out=$(cd "$WP_PATH" && wp core verify-checksums --allow-root 2>&1 || true)
        if echo "$out" | grep -qiE "modified|added|Error"; then
            finding HIGH "Modified/added core files detected:"
            echo "$out" | grep -iE "modified|added|Error" | head -20 | while IFS= read -r l; do log_detail "$l"; done
        else
            finding OK "WP-CLI core checksum verification passed"
        fi
    fi

    if $HAS_CURL && [[ "$WP_VERSION" != "unknown" ]]; then
        local cfile="${REPORT_DIR}/checksums.json"
        if curl -sf --max-time 15 \
            "https://api.wordpress.org/core/checksums/1.0/?version=${WP_VERSION}&locale=en_US" \
            -o "$cfile" 2>/dev/null; then

            # Extra PHP files in wp-includes root
            local extra=""
            while IFS= read -r f; do
                local bn; bn=$(basename "$f")
                grep -q "\"wp-includes/${bn}\"" "$cfile" 2>/dev/null || extra="${extra}${f}\n"
            done < <(find "${WP_PATH}/wp-includes" -maxdepth 1 -name "*.php" 2>/dev/null)

            if [[ -n "$extra" ]]; then
                finding HIGH "Unknown PHP files in wp-includes (not in core):"
                echo -e "$extra" | grep -v '^$' | while IFS= read -r f; do log_detail "$f"; done
            else
                finding OK "No unexpected files in wp-includes"
            fi
        else
            finding INFO "Could not fetch checksums from WordPress.org"
        fi
    fi

    # Files modified after version.php
    local vfile="${WP_PATH}/wp-includes/version.php"
    if [[ -f "$vfile" ]]; then
        local newer; newer=$(find "${WP_PATH}/wp-admin" "${WP_PATH}/wp-includes" \
            -type f -name "*.php" -newer "$vfile" ! -name "version.php" 2>/dev/null | head -20 || true)
        if [[ -n "$newer" ]]; then
            local nc; nc=$(echo "$newer" | grep -c . || echo 0)
            finding WARN "${nc} core PHP file(s) modified after version.php"
            echo "$newer" | head -15 | while IFS= read -r f; do log_detail "$f"; done
        else
            finding OK "No core files modified after version.php"
        fi
    fi

    section_end
}

check_malware() {
    section_start "Malware & Code Injection"
    local sdir="${WP_PATH}/wp-content"
    $FULL_SCAN && sdir="$WP_PATH"

    # Phase 1 — dangerous eval/exec patterns
    local p1="${REPORT_DIR}/p1.txt"; > "$p1"
    grep -rlP 'eval\s*\(\s*(base64_decode|gzinflate|gzuncompress|str_rot13|rawurldecode|hex2bin)' \
        --include="*.php" "$sdir" 2>/dev/null >> "$p1" || true
    grep -rlP '(passthru|shell_exec|system|exec|popen|proc_open)\s*\(\s*\$_(GET|POST|COOKIE|REQUEST)' \
        --include="*.php" "$sdir" 2>/dev/null >> "$p1" || true
    grep -rlP 'assert\s*\(\s*\$_(GET|POST|COOKIE|REQUEST|SERVER)' \
        --include="*.php" "$sdir" 2>/dev/null >> "$p1" || true
    grep -rlP '\$_(GET|POST|COOKIE|REQUEST)\s*\[\s*['"'"'"](cmd|c|shell|pass|exec)['"'"'"]\s*\]' \
        --include="*.php" "$sdir" 2>/dev/null >> "$p1" || true
    grep -rlP 'create_function\s*\(' \
        --include="*.php" "$sdir" 2>/dev/null >> "$p1" || true
    grep -rlP '(include|require)(_once)?\s*['"'"'"](https?|ftp)://' \
        --include="*.php" "$sdir" 2>/dev/null >> "$p1" || true
    sort -u "$p1" -o "$p1"
    local p1c; p1c=$(wc -l < "$p1" 2>/dev/null || echo 0)
    if [[ "$p1c" -gt 0 ]]; then
        finding CRITICAL "Dangerous PHP patterns in ${p1c} file(s):"
        head -20 "$p1" | while IFS= read -r f; do log_detail "$f"; done
        [[ "$p1c" -gt 20 ]] && log_detail "... and $((p1c-20)) more — see report"
    else
        finding OK "No dangerous eval/exec patterns found"
    fi

    # Phase 2 — known backdoor signatures
    local p2="${REPORT_DIR}/p2.txt"; > "$p2"
    grep -rlP 'c99shell|r57shell|b374k|FilesMan|weevely|WSO\s*[Ss]hell' \
        --include="*.php" "$sdir" 2>/dev/null >> "$p2" || true
    grep -rlP 'wp_create_user.{0,60}administrator' \
        --include="*.php" "$sdir" 2>/dev/null >> "$p2" || true
    grep -rlP '<?php\s{0,5}eval\s*\(' \
        --include="*.php" "$sdir" 2>/dev/null >> "$p2" || true
    grep -rlP 'coinhive|cryptoloot|coin-hive|minero\.cc' \
        --include="*.php" --include="*.js" "$sdir" 2>/dev/null >> "$p2" || true
    grep -rlP '@error_reporting\(0\).{0,30}@ini_set' \
        --include="*.php" "$sdir" 2>/dev/null >> "$p2" || true
    sort -u "$p2" -o "$p2"
    local p2c; p2c=$(wc -l < "$p2" 2>/dev/null || echo 0)
    if [[ "$p2c" -gt 0 ]]; then
        finding CRITICAL "Known backdoor signatures in ${p2c} file(s):"
        head -20 "$p2" | while IFS= read -r f; do log_detail "$f"; done
    else
        finding OK "No known backdoor signatures"
    fi

    # Phase 3 — JS obfuscation
    local p3="${REPORT_DIR}/p3.txt"; > "$p3"
    grep -rlP 'document\.write\s*\(\s*unescape\s*\(' \
        --include="*.php" --include="*.js" "$sdir" 2>/dev/null >> "$p3" || true
    grep -rlP 'eval\s*\(\s*String\.fromCharCode' \
        --include="*.php" --include="*.js" "$sdir" 2>/dev/null >> "$p3" || true
    grep -rlP '<iframe[^>]{0,80}display\s*:\s*none' \
        --include="*.php" --include="*.html" "$sdir" 2>/dev/null >> "$p3" || true
    grep -rlP 'window\[atob\(' \
        --include="*.php" --include="*.js" "$sdir" 2>/dev/null >> "$p3" || true
    sort -u "$p3" -o "$p3"
    local p3c; p3c=$(wc -l < "$p3" 2>/dev/null || echo 0)
    if [[ "$p3c" -gt 0 ]]; then
        finding HIGH "Suspicious JS obfuscation in ${p3c} file(s):"
        head -15 "$p3" | while IFS= read -r f; do log_detail "$f"; done
    else
        finding OK "No JS obfuscation patterns found"
    fi

    # Phase 4 — suspicious file names
    local weird; weird=$(find "$WP_PATH" -type f -name "*.php" 2>/dev/null \
        | grep -P '(shell|hack|r57|c99|b374|wso|cmd|eval|xmr|miner|gate|crypt)' | head -20 || true)
    local hexn; hexn=$(find "$WP_PATH" -type f -name "*.php" 2>/dev/null \
        | grep -P '/[a-f0-9]{8,}\.php$' | head -10 || true)
    if [[ -n "$weird" ]] || [[ -n "$hexn" ]]; then
        finding HIGH "Suspiciously named PHP files:"
        echo "$weird" | grep -v '^$' | while IFS= read -r f; do log_detail "$f"; done
        echo "$hexn"  | grep -v '^$' | while IFS= read -r f; do log_detail "$f (hex-named)"; done
    else
        finding OK "No suspiciously named PHP files"
    fi

    # mu-plugins
    local mudir="${WP_PATH}/wp-content/mu-plugins"
    if [[ -d "$mudir" ]]; then
        local muf; muf=$(find "$mudir" -name "*.php" 2>/dev/null || true)
        local mufc; mufc=$(echo "$muf" | grep -c . 2>/dev/null || echo 0)
        if [[ -n "$muf" ]] && [[ "$mufc" -gt 0 ]]; then
            finding WARN "mu-plugins has ${mufc} PHP file(s) — auto-loaded, verify:"
            echo "$muf" | head -10 | while IFS= read -r f; do log_detail "$f"; done
        else
            finding OK "mu-plugins is empty"
        fi
    fi

    section_end
}

check_recent_files() {
    section_start "Recently Modified Files (7 days)"
    local recent; recent=$(find "$WP_PATH" -type f \( -name "*.php" -o -name "*.js" \) \
        ! -path "*/cache/*" ! -path "*/.git/*" ! -path "*/node_modules/*" \
        -mtime -7 2>/dev/null | sort || true)
    local rc; rc=$(echo "$recent" | grep -c . 2>/dev/null || echo 0)
    if [[ -n "$recent" ]] && [[ "$rc" -gt 0 ]]; then
        finding WARN "${rc} PHP/JS file(s) modified in last 7 days — review if unexpected"
        echo "$recent" | head -30 | while IFS= read -r f; do
            local mt; mt=$(stat -c '%y' "$f" 2>/dev/null | cut -d'.' -f1 || echo "?")
            log_detail "[${mt}] $f"
        done
        [[ "$rc" -gt 30 ]] && log_detail "... and $((rc-30)) more"
    else
        finding OK "No unexpected recent file modifications"
    fi
    section_end
}

check_wp_hardening() {
    section_start "WordPress Hardening"

    [[ -f "${WP_PATH}/xmlrpc.php" ]] && \
        finding WARN "xmlrpc.php present — block if not needed" || \
        finding OK "xmlrpc.php not present"

    [[ -f "${WP_PATH}/readme.html" ]] && \
        finding WARN "readme.html discloses WP version — delete it" || \
        finding OK "readme.html not present"

    [[ -f "${WP_PATH}/wp-admin/install.php" ]] && \
        finding WARN "wp-admin/install.php accessible"

    if $HAS_WPCLI; then
        local admins; admins=$(cd "$WP_PATH" && wp user list --role=administrator \
            --field=user_login --allow-root 2>/dev/null || echo "")
        echo "$admins" | grep -qix "admin" && \
            finding HIGH "Username 'admin' exists — rename it" || \
            finding OK "No default 'admin' username"
        local acount; acount=$(echo "$admins" | grep -c . 2>/dev/null || echo 0)
        [[ "$acount" -gt 3 ]] && \
            finding WARN "${acount} admin accounts — review for unauthorized users"

        local op; op=$(cd "$WP_PATH" && wp plugin list --update=available \
            --format=count --allow-root 2>/dev/null || echo 0)
        [[ "$op" -gt 0 ]] && finding HIGH "${op} plugin(s) need updates" \
                           || finding OK "All plugins up to date"

        local ia; ia=$(cd "$WP_PATH" && wp plugin list --status=inactive \
            --format=count --allow-root 2>/dev/null || echo 0)
        [[ "$ia" -gt 0 ]] && finding WARN "${ia} inactive plugin(s) — remove unused ones"

        local tu; tu=$(cd "$WP_PATH" && wp theme list --update=available \
            --format=count --allow-root 2>/dev/null || echo 0)
        [[ "$tu" -gt 0 ]] && finding WARN "${tu} theme(s) need updates" \
                           || finding OK "All themes up to date"
    fi

    section_end
}

check_htaccess() {
    section_start ".htaccess Configuration"
    local ht="${WP_PATH}/.htaccess"
    if [[ ! -f "$ht" ]]; then
        finding INFO ".htaccess not present (nginx?)"
        section_end; return
    fi

    local sus=false
    for p in 'SetHandler.*application/x-httpd-php' 'AddHandler.*\.php' \
             'auto_prepend_file' 'auto_append_file' \
             'RewriteRule.*\.(jpg|gif|png).*\.php'; do
        grep -qiP "$p" "$ht" 2>/dev/null && { finding HIGH "Suspicious .htaccess rule: ${p}"; sus=true; }
    done
    $sus || finding OK ".htaccess looks clean"

    local uht="${WP_PATH}/wp-content/uploads/.htaccess"
    if [[ -f "$uht" ]]; then
        grep -qiP 'deny|Deny|php_flag|php_admin' "$uht" 2>/dev/null && \
            finding OK "uploads/.htaccess blocks PHP" || \
            finding WARN "uploads/.htaccess may not block PHP execution"
    else
        finding WARN "No .htaccess in uploads/ — PHP execution not blocked"
    fi

    section_end
}

check_database() {
    section_start "Database Security"
    local cfg="${WP_PATH}/wp-config.php"
    [[ ! -f "$cfg" ]] && { finding WARN "wp-config.php missing"; section_end; return; }

    local DB_NAME DB_USER DB_PASS DB_HOST DB_PREFIX
    DB_NAME=$(grep "define.*DB_NAME"     "$cfg" 2>/dev/null | head -1 | cut -d"'" -f4 || echo "")
    DB_USER=$(grep "define.*DB_USER"     "$cfg" 2>/dev/null | head -1 | cut -d"'" -f4 || echo "")
    DB_PASS=$(grep "define.*DB_PASSWORD" "$cfg" 2>/dev/null | head -1 | cut -d"'" -f4 || echo "")
    DB_HOST=$(grep "define.*DB_HOST"     "$cfg" 2>/dev/null | head -1 | cut -d"'" -f4 || echo "localhost")
    DB_PREFIX=$(grep "^\$table_prefix"   "$cfg" 2>/dev/null | head -1 | cut -d"'" -f2 || echo "wp_")

    [[ -z "$DB_NAME" ]] && { finding WARN "Could not parse DB credentials"; section_end; return; }
    finding INFO "DB: ${DB_NAME} @ ${DB_HOST}"

    if ! $HAS_MYSQL; then
        finding INFO "MySQL client not available — skipping live DB checks"
        section_end; return
    fi

    local MC="mysql -u${DB_USER} -p${DB_PASS} -h${DB_HOST} ${DB_NAME} --silent --batch"
    if ! $MC -e "SELECT 1" &>/dev/null 2>&1; then
        finding WARN "DB connection failed — skipping DB checks"
        section_end; return
    fi
    finding OK "Database connection successful"

    # Injected code in options
    local bo; bo=$($MC -e "SELECT option_name FROM ${DB_PREFIX}options \
        WHERE option_value REGEXP 'eval|base64_decode|shell_exec|passthru' \
        AND autoload='yes' LIMIT 10;" 2>/dev/null || echo "")
    [[ -n "$bo" ]] && { finding CRITICAL "Malicious code in wp_options:"; \
        echo "$bo" | while IFS= read -r l; do log_detail "$l"; done; } || \
        finding OK "No malicious code in wp_options"

    # Unauthorized admins
    local admins; admins=$($MC -e "SELECT u.user_login, u.user_email, u.user_registered \
        FROM ${DB_PREFIX}users u INNER JOIN ${DB_PREFIX}usermeta m ON u.ID=m.user_id \
        WHERE m.meta_key='${DB_PREFIX}capabilities' AND m.meta_value LIKE '%administrator%' \
        ORDER BY u.user_registered DESC;" 2>/dev/null || echo "")
    [[ -n "$admins" ]] && { finding INFO "Admin accounts (verify all are legitimate):"; \
        echo "$admins" | while IFS= read -r l; do log_detail "$l"; done; }

    # Injected posts
    local bp; bp=$($MC -e "SELECT ID, post_title FROM ${DB_PREFIX}posts \
        WHERE (post_content LIKE '%eval(base64%' OR post_content LIKE '%document.write(unescape%' \
            OR post_content REGEXP '<(script|iframe)[^>]+src=') \
        AND post_status != 'trash' LIMIT 10;" 2>/dev/null || echo "")
    [[ -n "$bp" ]] && { finding HIGH "Injected content in posts:"; \
        echo "$bp" | while IFS= read -r l; do log_detail "$l"; done; } || \
        finding OK "No injected scripts in posts"

    # SEO spam
    local spam; spam=$($MC -e "SELECT option_name FROM ${DB_PREFIX}options \
        WHERE option_value REGEXP 'viagra|casino|poker|pharmacy|pills|cialis' LIMIT 5;" \
        2>/dev/null || echo "")
    [[ -n "$spam" ]] && { finding HIGH "SEO spam keywords in options:"; \
        echo "$spam" | while IFS= read -r l; do log_detail "$l"; done; } || \
        finding OK "No SEO spam in options"

    section_end
}

check_ssl() {
    section_start "SSL & HTTP Security Headers"
    if ! $HAS_CURL; then
        finding INFO "curl not available — skipping"
        section_end; return
    fi

    local site_url=""
    $HAS_WPCLI && site_url=$(cd "$WP_PATH" && wp option get siteurl --allow-root 2>/dev/null || echo "")
    [[ -z "$site_url" ]] && [[ -f "${WP_PATH}/wp-config.php" ]] && \
        site_url=$(grep "define.*WP_SITEURL\|define.*WP_HOME" "${WP_PATH}/wp-config.php" \
            2>/dev/null | head -1 | cut -d"'" -f4 || echo "")

    if [[ -z "$site_url" ]]; then
        finding INFO "Could not determine site URL — skipping live header checks"
        section_end; return
    fi

    [[ "$site_url" != https://* ]] && finding WARN "Site URL is not HTTPS: ${site_url}" \
                                   || finding OK "Site uses HTTPS"

    local domain; domain=$(echo "$site_url" | sed 's|https\?://||;s|/.*||')
    local headers; headers=$(curl -sI --max-time 10 "https://${domain}" 2>/dev/null || \
                             curl -sI --max-time 10 "http://${domain}"  2>/dev/null || echo "")

    if [[ -z "$headers" ]]; then
        finding WARN "Could not reach ${domain}"
        section_end; return
    fi

    echo "$headers" | grep -qi "Strict-Transport-Security" && \
        finding OK "HSTS header present" || finding WARN "HSTS header missing"
    echo "$headers" | grep -qi "X-Frame-Options" && \
        finding OK "X-Frame-Options present" || finding WARN "X-Frame-Options missing"
    echo "$headers" | grep -qi "X-Content-Type-Options" && \
        finding OK "X-Content-Type-Options present" || finding WARN "X-Content-Type-Options missing"
    echo "$headers" | grep -qi "Content-Security-Policy" && \
        finding OK "Content-Security-Policy present" || finding INFO "Content-Security-Policy missing"
    echo "$headers" | grep -qiP "^X-Powered-By:|^Server:.*PHP" && \
        finding WARN "PHP version exposed in headers" || finding OK "PHP version not exposed in headers"

    section_end
}

check_login() {
    section_start "Login & Brute Force Exposure"

    local twofa_plugins=("two-factor" "wordfence" "google-authenticator"
                         "miniOrange-2-factor-authentication" "wp-2fa" "melapress-login-security")
    local twofa=false
    for p in "${twofa_plugins[@]}"; do
        [[ -d "${WP_PATH}/wp-content/plugins/${p}" ]] && { twofa=true; break; }
    done
    $twofa && finding OK "2FA/login security plugin detected" \
           || finding WARN "No 2FA plugin found"

    [[ -f "${WP_PATH}/xmlrpc.php" ]] && \
        finding WARN "xmlrpc.php present — brute-force vector if not blocked"

    for logf in /var/log/nginx/access.log /var/log/apache2/access.log \
                /var/log/httpd/access_log /var/log/auth.log; do
        [[ -f "$logf" ]] || continue
        local bfc; bfc=$(grep -c "wp-login.*POST\|POST.*wp-login" "$logf" 2>/dev/null || echo 0)
        [[ "$bfc" -gt 200 ]] && finding HIGH "High brute-force volume in ${logf}: ${bfc} POST requests"
        [[ "$bfc" -gt 20 && "$bfc" -le 200 ]] && \
            finding WARN "${bfc} wp-login.php POST requests in ${logf}"
    done

    section_end
}

check_sensitive() {
    section_start "Sensitive File Exposure"

    local dangerous=(".env" ".env.local" ".env.production"
        "wp-config.php.bak" "wp-config.bak" "wp-config.old" "wp-config.php.orig"
        "debug.log" "error_log"
        ".git/config" ".git/HEAD"
        "phpinfo.php" "info.php" "test.php" "i.php"
        "adminer.php" "adminer" "phpmyadmin" "pma"
        "dump.sql" "backup.sql" "database.sql"
        "composer.json" "composer.lock")

    for f in "${dangerous[@]}"; do
        [[ -e "${WP_PATH}/${f}" ]] || continue
        case "$f" in
            .env*|.git/*)    finding CRITICAL "Exposed: ${f}" ;;
            adminer*|pma)    finding CRITICAL "DB admin tool exposed: ${f}" ;;
            *.bak|*.old|*.sql) finding HIGH "Backup/sensitive file: ${f}" ;;
            phpinfo*|*.php)  finding HIGH "Debug file exposed: ${f}" ;;
            debug.log|error_log) finding WARN "Log file in web root: ${f}" ;;
            *)               finding WARN "Sensitive file: ${f}" ;;
        esac
    done

    # Archive scan
    local arcs; arcs=$(find "$WP_PATH" -maxdepth 3 -type f \
        \( -name "*.zip" -o -name "*.tar.gz" -o -name "*.tgz" -o -name "*.sql" \) \
        2>/dev/null | head -10 || true)
    if [[ -n "$arcs" ]]; then
        local ac; ac=$(echo "$arcs" | grep -c . || echo 0)
        finding HIGH "${ac} archive/backup file(s) in web root"
        echo "$arcs" | while IFS= read -r f; do log_detail "$f"; done
    fi

    [[ -d "${WP_PATH}/.git" ]] && \
        finding CRITICAL ".git in web root — full source downloadable!" || \
        finding OK "No .git directory in web root"

    section_end
}

check_plugins() {
    section_start "Plugins & Themes"
    local pdir="${WP_PATH}/wp-content/plugins"
    local tdir="${WP_PATH}/wp-content/themes"

    if [[ -d "$pdir" ]]; then
        local pc; pc=$(find "$pdir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l || echo 0)
        finding INFO "Plugins installed: ${pc}"
        [[ "$pc" -gt 30 ]] && finding WARN "High plugin count (${pc}) — remove unused"
    fi

    local risky=("file-manager" "wp-file-manager" "wp-automatic" "bricks"
                 "startklar-elementor-addons" "givewp" "wp-dbmanager")
    for p in "${risky[@]}"; do
        [[ -d "${pdir}/${p}" ]] && finding WARN "High-risk plugin: ${p} — verify fully patched"
    done

    if [[ -d "$pdir" ]]; then
        local psus; psus=$(find "$pdir" -name "*.php" -size +0c 2>/dev/null \
            | xargs grep -lP 'eval\s*\(\s*base64_decode|shell_exec\s*\(\s*\$|passthru\s*\(\s*\$' \
              2>/dev/null | head -15 || true)
        if [[ -n "$psus" ]]; then
            finding HIGH "Suspicious code in plugin files:"
            echo "$psus" | while IFS= read -r f; do log_detail "$f"; done
        else
            finding OK "No suspicious code in plugin files"
        fi
    fi

    if $HAS_WPCLI; then
        local at; at=$(cd "$WP_PATH" && wp theme list --status=active \
            --field=name --allow-root 2>/dev/null | head -1 || echo "")
        if [[ -n "$at" ]]; then
            local tsus; tsus=$(find "${tdir}/${at}" -name "*.php" 2>/dev/null \
                | xargs grep -lP 'eval\s*\(\s*base64_decode|shell_exec|passthru' \
                  2>/dev/null | head -5 || true)
            [[ -n "$tsus" ]] && { finding HIGH "Suspicious code in active theme (${at}):"; \
                echo "$tsus" | while IFS= read -r f; do log_detail "$f"; done; } || \
                finding OK "Active theme (${at}) looks clean"
        fi
    fi

    local nulled; nulled=$(find "${WP_PATH}/wp-content" -type f -name "*.php" 2>/dev/null \
        | xargs grep -liP 'nulled|warez|cracked' 2>/dev/null | head -5 || true)
    [[ -n "$nulled" ]] && { finding HIGH "Possible nulled/pirated plugin or theme:"; \
        echo "$nulled" | while IFS= read -r f; do log_detail "$f"; done; }

    section_end
}

# ─── Final Summary ────────────────────────────────────────────────────────────
write_summary() {
    local elapsed=$(( $(date +%s) - SCAN_START ))
    local final; final="$(pwd)/wp-audit-$(date '+%Y%m%d_%H%M%S').txt"

    # Write summary block to log
    {
        echo ""
        echo "================================================================"
        echo " SUMMARY"
        echo "================================================================"
        printf " Duration:    %ss\n"  "$elapsed"
        printf " WordPress:   %s\n"   "$WP_VERSION"
        printf " PHP:         %s\n"   "$PHP_VERSION"
        echo ""
        printf " CRITICAL:    %s\n"   "$CRITICAL_COUNT"
        printf " HIGH:        %s\n"   "$((ISSUE_COUNT - CRITICAL_COUNT))"
        printf " WARN:        %s\n"   "$WARN_COUNT"
        printf " INFO:        %s\n"   "$INFO_COUNT"
        echo ""
        echo " REMEDIATION STEPS"
        echo " 1.  Update WP core, all plugins and themes immediately"
        echo " 2.  Remove PHP files from wp-content/uploads/"
        echo " 3.  Replace modified core files with fresh WP download"
        echo " 4.  Change all admin passwords + DB password"
        echo " 5.  Regenerate secret keys: https://api.wordpress.org/secret-key/1.1/salt/"
        echo " 6.  chmod 640 wp-config.php"
        echo " 7.  Add: define('DISALLOW_FILE_EDIT', true); to wp-config.php"
        echo " 8.  Block PHP in uploads/ with .htaccess"
        echo " 9.  Remove readme.html, license.txt, xmlrpc.php"
        echo "10.  Add HSTS, X-Frame-Options, X-Content-Type-Options headers"
        echo "11.  Enable 2FA for all admin accounts"
        echo "12.  Delete .env, .git, phpinfo.php, adminer.php from web root"
        echo "13.  Review all administrator accounts in DB"
        echo "14.  If malware found: rotate ALL credentials, scan DB"
        echo "================================================================"
    } >> "$LOG_FILE"

    cp "$LOG_FILE" "$final"

    # Print terminal summary
    echo ""
    echo -e "  ${DIM}$(printf '─%.0s' {1..56})${RESET}"
    echo ""
    echo -e "  ${BOLD}Scan Results${RESET}   (${elapsed}s  ·  WP ${WP_VERSION}  ·  PHP ${PHP_VERSION})"
    echo ""

    local overall="OK"
    [[ "$WARN_COUNT"     -gt 0 ]] && overall="WARN"
    [[ "$ISSUE_COUNT"    -gt 0 ]] && overall="HIGH"
    [[ "$CRITICAL_COUNT" -gt 0 ]] && overall="CRITICAL"

    # Score bar
    local total=$(( CRITICAL_COUNT + (ISSUE_COUNT - CRITICAL_COUNT) + WARN_COUNT ))
    if [[ "$total" -eq 0 ]]; then
        echo -e "  ${BGREEN}● CLEAN — No significant issues found${RESET}"
    else
        [[ "$CRITICAL_COUNT" -gt 0 ]] && echo -e "  ${BRED}● ${CRITICAL_COUNT} CRITICAL${RESET}"
        [[ "$((ISSUE_COUNT - CRITICAL_COUNT))" -gt 0 ]] && \
            echo -e "  ${RED}● $((ISSUE_COUNT - CRITICAL_COUNT)) HIGH${RESET}"
        [[ "$WARN_COUNT" -gt 0 ]] && echo -e "  ${YELLOW}● ${WARN_COUNT} WARNINGS${RESET}"
    fi

    echo ""
    echo -e "  ${DIM}$(printf '─%.0s' {1..56})${RESET}"
    echo ""
    echo -e "  ${BOLD}Full report:${RESET} ${final}"
    echo ""

    case "$overall" in
        CRITICAL) echo -e "  ${BRED}⚠  Immediate action required — see report for details${RESET}" ;;
        HIGH)     echo -e "  ${RED}⚠  Issues found — review report and remediate${RESET}" ;;
        WARN)     echo -e "  ${YELLOW}ℹ  Warnings found — review report${RESET}" ;;
        OK)       echo -e "  ${BGREEN}✓  Site looks healthy — keep monitoring${RESET}" ;;
    esac
    echo ""
}

# ─── Main ────────────────────────────────────────────────────────────────────
main() {
    parse_args "$@"
    setup
    print_banner

    check_deps
    check_wp_path
    check_file_permissions
    check_wpconfig
    check_core_integrity
    check_malware
    check_recent_files
    check_wp_hardening
    check_htaccess
    check_database
    check_ssl
    check_login
    check_sensitive
    check_plugins

    write_summary
}

main "$@"
