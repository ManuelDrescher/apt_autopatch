#!/usr/bin/env bash

# Exit on error, undefined vars, pipe failures
set -eEuo pipefail

# --- COLORS & SYMBOLS (consistent across terminal clients) ---
C_ACCENT="\033[1;36m"   # Bold cyan (borders, steps, accents)
C_BOLD="\033[1;37m"     # Bold white (titles, package names)
C_DIM="\033[2;37m"      # Dim gray (dividers, secondary info)
C_OK="\033[1;32m"       # Bold green (success, new version)
C_WARN="\033[1;33m"     # Bold yellow (notices, prompts, upgrade)
C_ERR="\033[1;31m"      # Bold red (errors, old version, reboot)
C_RESET="\033[0m"

ICON_OK="✔"
ICON_ERR="✖"
ICON_WARN="⚠"
ICON_ARROW="▸"

TMP_CL_DIR=$(mktemp -d /tmp/apt_changelogs_XXXXXX)
SPINNER_PID=""

cleanup() {
    [ -n "$SPINNER_PID" ] && kill "$SPINNER_PID" 2>/dev/null || true
    tput cnorm 2>/dev/null || true
    rm -rf "$TMP_CL_DIR"
}
trap cleanup EXIT

# --- LAYOUT HELPER FUNCTIONS ---
print_step() {
    local STEP_NUM="$1"
    local STEP_TITLE="$2"
    echo ""
    echo -e "${C_ACCENT}━━ [${STEP_NUM}] ${C_BOLD}${STEP_TITLE}${C_RESET}"
}

start_spinner() {
    local MSG="$1"
    tput civis 2>/dev/null || true
    (
        local FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
        local i=0
        while true; do
            printf "\r  ${C_ACCENT}%s${C_RESET} %s" "${FRAMES[$i]}" "$MSG"
            i=$(( (i + 1) % ${#FRAMES[@]} ))
            sleep 0.1
        done
    ) &
    SPINNER_PID=$!
}

stop_spinner() {
    if [ -n "$SPINNER_PID" ]; then
        kill "$SPINNER_PID" 2>/dev/null || true
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
    fi
    printf "\r\033[K"
    tput cnorm 2>/dev/null || true
}

# ==============================================================================
# START HEADER & SYSTEM OVERVIEW
# ==============================================================================
clear
OS_PRETTY=$(awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null || echo "Linux")
KERNEL_VER=$(uname -r)
DISK_INFO=$(df -h / | awk 'NR==2 {print $4 " free of " $2 " (" $5 " used)"}')

echo ""
echo -e "${C_ACCENT}╭──────────────────────────────────────────────────────────────────────╮${C_RESET}"
echo -e "${C_ACCENT}│${C_RESET}  ${C_BOLD}SYSTEM AUTO-PATCH & MAINTENANCE${C_RESET}                                     ${C_ACCENT}│${C_RESET}"
echo -e "${C_ACCENT}╰──────────────────────────────────────────────────────────────────────╯${C_RESET}"
echo -e "  ${C_DIM}Host:${C_RESET}      ${C_BOLD}${HOSTNAME}${C_RESET}"
echo -e "  ${C_DIM}System:${C_RESET}    ${OS_PRETTY} (${KERNEL_VER})"
echo -e "  ${C_DIM}Disk (/):${C_RESET}  ${DISK_INFO}"
echo ""

read -r -p "$(echo -e "  ${C_WARN}${ICON_ARROW}${C_RESET} Automatically update and clean the system now? ${C_BOLD}[Y/n]${C_RESET}: ")" START_CONF
if [[ -n "$START_CONF" && ! "$START_CONF" =~ ^[Yy]$ ]]; then
    echo -e "\n  ${C_DIM}Operation canceled.${C_RESET}\n"
    exit 0
fi

# Wait if another apt/dpkg process holds a lock
while pgrep -x 'apt|apt-get|dpkg|unattended-upgr' >/dev/null 2>&1; do
    echo -e "\n  ${C_WARN}${ICON_WARN} Background package manager active – waiting for lock release...${C_RESET}"
    sleep 3
done

# ==============================================================================
# STEP 1: UPDATE PACKAGE LISTS
# ==============================================================================
print_step "1/5" "Updating package lists (apt update)"
sudo apt update

# ==============================================================================
# STEP 2: ANALYZE AVAILABLE UPDATES & CHANGELOGS
# ==============================================================================
print_step "2/5" "Analyzing available package updates"

mapfile -t UPGRADE_LINES < <(
    LC_ALL=C apt list --upgradeable 2>/dev/null | awk '
        NR > 1 && NF > 0 {
            split($1, p, "/")
            pkg = p[1]
            new_ver = $2
            old_ver = "unknown"
            if (match($0, /\[upgradable from: [^]]+\]/)) {
                old_ver = substr($0, RSTART + 18, RLENGTH - 19)
            }
            print pkg "|" old_ver "|" new_ver
        }
    ' | sort
)

TOTAL_PKGS=${#UPGRADE_LINES[@]}

if [ "$TOTAL_PKGS" -gt 0 ]; then
    PKG_NAMES=$(printf '%s\n' "${UPGRADE_LINES[@]}" | cut -d'|' -f1)

    # 1. Fetch all package descriptions in a single apt-cache call
    declare -A PKG_DESC
    while IFS='|' read -r P_NAME P_DESC; do
        if [ -n "$P_NAME" ] && [ -z "${PKG_DESC[$P_NAME]:-}" ]; then
            PKG_DESC["$P_NAME"]="$P_DESC"
        fi
    done < <(
        LC_ALL=C apt-cache show $PKG_NAMES 2>/dev/null | awk '
            /^Package: / { pkg = substr($0, 10) }
            /^Description(-en)?: / {
                if (pkg != "") {
                    desc = $0
                    sub(/^Description(-en)?: /, "", desc)
                    print pkg "|" desc
                    pkg = ""
                }
            }
        '
    )

    # 2. Fetch changelogs in parallel (8 workers, 10s timeout) with live spinner
    start_spinner "Fetching changelogs for ${TOTAL_PKGS} package(s) in parallel..."
    export TMP_CL_DIR
    printf '%s\n' $PKG_NAMES | xargs -r -n 1 -P 8 bash -c '
        PKG="$1"
        CL_TEXT=$(timeout 10 apt-get changelog "$PKG" 2>/dev/null | sed -e "/^ -- /q" | grep -E "^[[:space:]]+\*" | head -n 6 || true)
        if [ -n "$CL_TEXT" ]; then
            printf "%s\n" "$CL_TEXT" > "$TMP_CL_DIR/$PKG"
        else
            echo "  * No changelog details available (e.g., third-party repo)." > "$TMP_CL_DIR/$PKG"
        fi
    ' _
    stop_spinner

    echo -e "  ${C_OK}${ICON_OK}${C_RESET} ${C_BOLD}${TOTAL_PKGS} package(s)${C_RESET} ready for upgrade:\n"

    # 3. Display formatted package cards
    IDX=1
    for ENTRY in "${UPGRADE_LINES[@]}"; do
        IFS='|' read -r PKG OLD_VER NEW_VER <<< "$ENTRY"
        DESC="${PKG_DESC[$PKG]:-No description available.}"

        echo -e "  ${C_ACCENT}┌─ [${IDX}/${TOTAL_PKGS}]${C_RESET} ${C_BOLD}${PKG}${C_RESET}  ${C_DIM}(${C_RESET}${C_ERR}${OLD_VER}${C_RESET} ${C_DIM}→${C_RESET} ${C_OK}${NEW_VER}${C_RESET}${C_DIM})${C_RESET}"
        echo -e "  ${C_ACCENT}│${C_RESET}  ${C_DIM}Purpose:${C_RESET} ${DESC}"
        echo -e "  ${C_ACCENT}│${C_RESET}  ${C_DIM}Changes:${C_RESET}"
        if [ -f "$TMP_CL_DIR/$PKG" ]; then
            while IFS= read -r CL_LINE; do
                echo -e "  ${C_ACCENT}│${C_RESET}  ${CL_LINE}"
            done < "$TMP_CL_DIR/$PKG"
        fi
        echo -e "  ${C_ACCENT}└────────────────────────────────────────────────────────────────────${C_RESET}"
        IDX=$((IDX + 1))
    done

    echo ""
    read -r -n 1 -s -p "$(echo -e "  ${C_WARN}${ICON_ARROW}${C_RESET} Press any key to start the upgrade ${C_DIM}(CTRL+C to cancel)${C_RESET}...")"
    echo ""
else
    echo -e "  ${C_OK}${ICON_OK} System is already up to date – no package updates available.${C_RESET}"
fi

# ==============================================================================
# STEP 3: UPGRADE SYSTEM
# ==============================================================================
print_step "3/5" "Upgrading system (apt full-upgrade)"
sudo apt full-upgrade

# ==============================================================================
# STEP 4: CLEAN UP SYSTEM
# ==============================================================================
print_step "4/5" "Removing unused packages & cleaning cache"
sudo apt --purge autoremove && sudo apt clean

# ==============================================================================
# STEP 5: OPTIMIZE FILE SYSTEM (SSD TRIM)
# ==============================================================================
print_step "5/5" "Optimizing file system (fstrim)"
sudo fstrim -av || echo -e "  ${C_DIM}fstrim skipped (not supported on this file system/container).${C_RESET}"

# ==============================================================================
# COMPLETION & REBOOT CHECK
# ==============================================================================
echo ""
if [ -f /var/run/reboot-required ]; then
    echo -e "${C_ERR}╭──────────────────────────────────────────────────────────────────────╮${C_RESET}"
    echo -e "${C_ERR}│  ${ICON_WARN}  FINISHED — SYSTEM REBOOT REQUIRED                                │${C_RESET}"
    echo -e "${C_ERR}╰──────────────────────────────────────────────────────────────────────╯${C_RESET}"
    if [ -f /var/run/reboot-required.pkgs ]; then
        TRIGGERS=$(sort -u /var/run/reboot-required.pkgs | paste -sd ', ' -)
        echo -e "  ${C_WARN}Triggered by:${C_RESET} ${TRIGGERS}"
    fi
    echo ""

    while true; do
        read -r -p "$(echo -e "  ${C_WARN}${ICON_ARROW}${C_RESET} Reboot: ${C_BOLD}[N]${C_RESET} Now  |  ${C_BOLD}[T]${C_RESET} Time (HH:MM)  |  ${C_BOLD}[A]${C_RESET} Abort: ")" choice
        case "$choice" in
            [Nn])
                echo -e "\n  ${C_OK}${ICON_OK} System is rebooting now...${C_RESET}\n"
                sleep 2
                sudo shutdown -r now
                break
                ;;
            [Tt])
                read -r -p "$(echo -e "  ${C_ACCENT}${ICON_ARROW}${C_RESET} Desired reboot time ${C_DIM}(HH:MM)${C_RESET}: ")" time
                if [[ "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
                    echo ""
                    sudo shutdown -r "$time"
                    echo -e "  ${C_OK}${ICON_OK} Reboot scheduled for ${C_BOLD}${time}${C_RESET}${C_OK}.${C_RESET}\n"
                    sleep 2
                    break
                else
                    echo -e "  ${C_ERR}${ICON_ERR} Invalid time format '$time'. Please enter HH:MM (00:00 - 23:59).${C_RESET}"
                fi
                ;;
            [Aa])
                echo -e "\n  ${C_WARN}${ICON_WARN} Reboot postponed. Please reboot manually soon.${C_RESET}\n"
                exit 0
                ;;
            *)
                echo -e "  ${C_ERR}${ICON_ERR} Invalid input. Please choose N, T, or A.${C_RESET}"
                ;;
        esac
    done
else
    echo -e "${C_OK}╭──────────────────────────────────────────────────────────────────────╮${C_RESET}"
    echo -e "${C_OK}│  ${ICON_OK}  FINISHED — NO REBOOT REQUIRED                                    │${C_RESET}"
    echo -e "${C_OK}╰──────────────────────────────────────────────────────────────────────╯${C_RESET}"
    echo ""
fi
