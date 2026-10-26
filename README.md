# BBBC 26 - BrunchBox Boot Creator
Modern ChromeOS / Brunch installer for x86_64 PCs

sudo apt update && sudo apt install -y git cgpt pv tar unzip
git clone https://github.com/Miustone/BBBC.git
cd BBBC
sudo bash bbbc.sh

# 🐧 Running BBBC

> **BBBC (BrunchBox Boot Creator)** is a Linux-native Bash utility. 



# Changelog

All notable changes to the **BBBC (BrunchBox Boot Creator)** script are documented here:

---

## [2.6.1] - 2026-10-26

### Added

* **Ryzen 7000/8000 Support:** Added hardware detection for AMD Ryzen 7000 and 8000 series APUs (Zen 4 / Phoenix / Hawk Point) via `lscpu`.
* **Out-of-the-Box Chromebook Plus Setup:** Integrated `-options chromebook_plus` into `chromeos-install.sh` execution, enabling AI wallpapers, Magic Eraser, and Material You features automatically on first boot.
* **Embedded Python 3 Manifest Parser:** Replaced regex-based string manipulation with a robust Python 3 JSON parser to query Google's recovery manifest (`recovery.json`).
* **Board Fallback Chains:** Added automatic board resolution chains (`majestic` → `glinda` → `guybrush` → `gumboz` → `zork` → `skyrim`) if a specific board variant is missing from Google's manifest.
* **Automated Privilege Elevation:** Added self-elevation logic (`exec sudo bash "$0" "$@"`) when executed as a standard user.
* **Dependency Checking:** Added `python3` to required package installation checks across `apt` and `pacman`.

### Fixed

* **HTTP 404 Download Failures:** Replaced the defunct `cros.download` scraping URL with Google's official recovery manifest API (`[https://dl.google.com/dl/edgedl/chromeos/recovery/recovery.json](https://dl.google.com/dl/edgedl/chromeos/recovery/recovery.json)`).
* **Version Alignment Mismatches:** Fixed parsing logic to inspect ChromeOS milestone versions (`chrome_version`, e.g., `154.x`) instead of platform build numbers (e.g., `16805.x`).
* **Sudo Execution Blocker:** Removed the restrictive `[[ $EUID -ne 0 ]]` trap that previously killed script execution when running with administrative privileges.
* **`awk` Syntax Warnings:** Fixed regex escaping (`\.`) that generated warnings in newer shell environments.

### Changed

* **Full English Localization:** Translated all CLI prompts, banners, logs, warning messages, and post-installation instructions from German to English.
* **Updated Target Board Defaults:** Set `majestic` as the default target for Ryzen 7000/8000 and `kanix` for Intel 14th Gen / Core Ultra series.
* **Interactive Profile Selection:** Expanded the interactive installer menu to offer preset performance and feature profiles (`Balanced + Chromebook Plus`, `Performance + Hyperthreading`, and `Custom`).