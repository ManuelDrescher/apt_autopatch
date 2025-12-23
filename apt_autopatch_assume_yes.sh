#!/usr/bin/env bash

# Define shell behavior (exit on error, undefined vars, pipe failures)
set -eEuo pipefail

# Define available colors and symbols
YW=$(echo "\033[33m")
BL=$(echo "\033[36m")
RD=$(echo "\033[01;31m")
CM='\xE2\x9C\x94\033'
GN=$(echo "\033[1;92m")
CL=$(echo "\033[m")

# Display graphical selection menu
whiptail --backtitle "Automatic Update" --title "" --yesno "The system will be patched automatically. Proceed?" 10 58
if [ $? -ne 0 ]; then
  exit
fi
clear
sleep 1
echo

# Show hostname
echo -e "${GN}Hostname is:${CL}"
echo $HOSTNAME
echo

# Show free disk space on /
echo -e "${GN}Free disk space on /:${CL}"
df -h / | awk 'NR==2 {print $4}'
echo
sleep 1

# Update package lists
echo -e "${BL}--- Updating package list ---${CL}"
sleep 1
sudo apt update
echo

# Show upgradeable packages (only if present)
echo -e "${BL}--- Upgradeable packages ---${CL}"
sleep 1
UPGRADEABLE_PACKAGES=$(sudo apt list --upgradeable 2>/dev/null)
echo "$UPGRADEABLE_PACKAGES"
echo
if [ $(echo "$UPGRADEABLE_PACKAGES" | wc -l) -gt 1 ]; then
    echo "Press [ENTER] or any key to continue (CTRL+C to cancel)"
    read -r -n 1 -s
    echo
else
    echo -e "${GN}NO upgradeable packages found.${CL}"
    echo
fi
echo

# Upgrade the system
echo -e "${YW}--- Upgrading system ---${CL}"
sleep 1
sudo apt full-upgrade -y
echo

# Clean up the system
echo -e "${BL}--- Cleaning up system ---${CL}"
sleep 1
sudo apt --purge autoremove -y && sudo apt clean
echo

# Trim file system (SSD optimization)
echo -e "${BL}--- Trimming file system ---${CL}"
sleep 1
sudo fstrim -av
echo
sleep 1

# Check if a reboot is required
if [ -f /var/run/reboot-required ]; then
  echo -e "${RD}Finished - Reboot IS required.${CL}"
  sleep 1
  while true; do
  read -p "Reboot now (N), at a specific time (T), or abort (A)? [N/T/A]: " choice
  case "$choice" in
    [Nn]*)
      echo -e "${GN}System is rebooting now....${CL}"
      sleep 2
      sudo shutdown -r now
      break 
      ;;
    [Tt]*)
      read -p "Enter reboot time (HH:MM): " time
      echo
      sudo shutdown -r $time
      echo -e "${GN}Reboot scheduled for $time.${CL}"
      echo
      echo "Exiting..."
      sleep 2
      break
      ;;
    [Aa]*)
      echo -e "${RD}Reboot canceled. Exiting...${CL}"
      sleep 1
      exit 0
      ;;
    *)
      echo -e "${RD}Invalid input. Please try again.${CL}"
      ;;
  esac
done
else
  echo -e "${GN}Finished - NO reboot required.${CL}"
  sleep 1
fi