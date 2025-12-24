## 💾 apt_autopatch for Debian/Debian-based OS

* This simple, but effective script contains:
  * Show hostname
  * Show free disk space on /
  * Update package list (`sudo apt update`)
  * Show upgradeable packages (only if present)
    * A key must be pressed if upgradeable packages are available
    * This allows you to preview the packages before patching
  * Upgrade the system (`sudo apt full-upgrade`)
  * Clean up the system (`sudo apt --purge autoremove && sudo apt clean`)
  * Trim the file system (`sudo fstrim -av`)
  * Check if a reboot is required, if yes:
    * Reboot now
    * Reboot to a specific time
    * Do nothing

---
* This script is not complex and can easily be modified to your needs
* The script can be aborted on every step
---

## ⚠️ Information

* The optional script `apt_autopatch_assume_yes.sh` adds an "assume yes / -y" to `sudo apt full-upgrade`  
  and `sudo apt --purge autoremove && sudo apt clean`
  

