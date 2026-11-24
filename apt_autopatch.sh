#!/usr/bin/env bash

# Exit on error, undefined vars, pipe failures
set -eEuo pipefail

# Colors
YW="\033[33m"
BL="\033[36m"
RD="\033[01;31m"
GN="\033[1;92m"
CL="\033[m"

# Temporary directory for parallel changelog fetching (auto-cleaned on exit)
TMP_CL_DIR=$(mktemp -d /tmp/apt_changelogs_XXXXXX)
trap 'rm -rf "$TMP_CL_DIR"' EXIT

# Display selection dialog (safe with set -e)
if ! whiptail --backtitle "Automatic Update" --title "System Patch" --yesno "The system will be patched automatically. Proceed?" 10 58; then
    exit 0
fi
clear
echo

# Show hostname & free disk space
echo -e "${GN}Hostname:${CL}        $HOSTNAME"
echo -e "${GN}Free space (/):${CL}  $(df -h / | awk 'NR==2 {print $4 " of " $2 " (" $5 " used)"}')"
echo

# Wait if another apt/dpkg process holds a lock
while pgrep -x 'apt|apt-get|dpkg|unattended-upgr' >/dev/null 2>&1; do
    echo -e "${YW}Waiting for background package manager (apt/dpkg) to finish...${CL}"
    sleep 3
done

# Update package lists
echo -e "${BL}--- Updating package list ---${CL}"
sudo apt update
echo

# Collect upgradeable packages including old -> new versions
echo -e "${BL}--- Upgradeable packages & details ---${CL}"
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

if [ ${#UPGRADE_LINES[@]} -gt 0 ]; then
    PKG_NAMES=$(printf '%s\n' "${UPGRADE_LINES[@]}" | cut -d'|' -f1)

    # 1. Fetch all package descriptions in ONE single apt-cache call
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

    # 2. Fetch changelogs in parallel (8 concurrent workers, 10s timeout per package)
    echo -e "${BL}Fetching changelogs for ${#UPGRADE_LINES[@]} package(s) in parallel...${CL}"
    echo
    export TMP_CL_DIR
    printf '%s\n' $PKG_NAMES | xargs -r -n 1 -P 8 bash -c '
        PKG="$1"
        CL_TEXT=$(timeout 10 apt-get changelog "$PKG" 2>/dev/null | sed -e "/^ -- /q" | grep -E "^[[:space:]]+\*" | head -n 6 || true)
        if [ -n "$CL_TEXT" ]; then
            printf "%s\n" "$CL_TEXT" > "$TMP_CL_DIR/$PKG"
        else
            echo "  No changelog available (e.g. third-party repo)." > "$TMP_CL_DIR/$PKG"
        fi
    ' _

    # 3. Display formatted results
    for ENTRY in "${UPGRADE_LINES[@]}"; do
        IFS='|' read -r PKG OLD_VER NEW_VER <<< "$ENTRY"
        DESC="${PKG_DESC[$PKG]:-No description available.}"

        echo -e "${YW}Package:${CL} ${PKG}  (${RD}${OLD_VER}${CL} -> ${GN}${NEW_VER}${CL})"
        echo -e "${GN}Purpose:${CL} ${DESC}"
        echo -e "${BL}Changes:${CL}"
        if [ -f "$TMP_CL_DIR/$PKG" ]; then
            cat "$TMP_CL_DIR/$PKG"
        else
            echo "  No details available."
        fi
        echo "------------------------------------------------------------------------"
    done

    echo -e "${YW}Total upgradeable packages: ${#UPGRADE_LINES[@]}${CL}"
    echo "Press [ENTER] or any key to start upgrade (CTRL+C to cancel)..."
    read -r -n 1 -s
    echo
else
    echo -e "${GN}NO upgradeable packages found.${CL}"
    echo
fi

# Upgrade the system
echo -e "${YW}--- Upgrading system ---${CL}"
sudo apt full-upgrade
echo

# Clean up the system
echo -e "${BL}--- Cleaning up system ---${CL}"
sudo apt --purge autoremove && sudo apt clean
echo

# Trim file system (non-fatal on VMs/containers without discard support)
echo -e "${BL}--- Trimming file system ---${CL}"
sudo fstrim -av || echo -e "${YW}fstrim skipped or not supported on this filesystem.${CL}"
echo

# Check if a reboot is required
if [ -f /var/run/reboot-required ]; then
    echo -e "${RD}Finished - Reboot IS required.${CL}"
    if [ -f /var/run/reboot-required.pkgs ]; then
        echo -e "${YW}Triggered by:${CL} $(sort -u /var/run/reboot-required.pkgs | paste -sd ', ' -)"
    fi
    echo

    while true; do
        read -r -p "Reboot now (N), at a specific time (T), or abort (A)? [N/T/A]: " choice
        case "$choice" in
            [Nn])
                echo -e "${GN}System is rebooting now...${CL}"
                sleep 2
                sudo shutdown -r now
                break
                ;;
            [Tt])
                read -r -p "Enter reboot time (HH:MM): " time
                if [[ "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
                    echo
                    sudo shutdown -r "$time"
                    echo -e "${GN}Reboot scheduled for $time.${CL}"
                    sleep 2
                    break
                else
                    echo -e "${RD}Invalid time format '$time'. Please use HH:MM (00:00 - 23:59).${CL}"
                fi
                ;;
            [Aa])
                echo -e "${RD}Reboot canceled. Exiting...${CL}"
                exit 0
                ;;
            *)
                echo -e "${RD}Invalid input. Please enter N, T, or A.${CL}"
                ;;
        esac
    done
else
    echo -e "${GN}Finished - NO reboot required.${CL}"
    sleep 1
fi
