## 💾 apt_autopatch for Debian/Debian-based OS

* This simple, but effective script contains:
  * Show hostname
  * Show free disk space on /
  * Update package list (`apt update`)
  * Show upgradeable packages (only if present)
    * A key must be pressed if upgradeable packages are available
    * This allows you to preview the packages before patching
  * Upgrade the system (`apt full-upgrade`)
  * Clean up the system (`apt --purge autoremove && sudo apt clean`)
  * Trim the file system (`fstrim -av`)
  * Check if a reboot is required, if yes:
    * Reboot now
    * Reboot to a specific time
    * Do nothing

---
This script is not complex and you can modify it to your needs
---

## ⚠️ Information

* The optional script `apt_autopatch_assume_yes.sh` adds an "assume yes / -y" to `apt full-upgrade` and `apt --purge autoremove && sudo apt clean`
  

