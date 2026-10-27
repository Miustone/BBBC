# BBBC 26 - BrunchBox Boot Creator
Modern ChromeOS / Brunch installer for x86_64 PCs

sudo apt update && sudo apt install -y git cgpt pv tar unzip python3 && git clone https://github.com/Miustone/BBBC.git && cd BBBC && bash bbbc.sh

# 🐧 Running BBBC

> **BBBC (BrunchBox Boot Creator)** is a Linux-native Bash utility. 



# Changelog

All notable changes to the **BBBC (BrunchBox Boot Creator)** script are documented here:

---

## [2.6.2] — 2026-10-27

### Fixed
- Corrected AMD Ryzen recovery selection to use the board mapping documented by the official Brunch project: `gumboz`.
- Removed the overly broad AMD generation heuristics that selected `majestic` or `guybrush` based only on CPU model-number patterns.
- Recovery selection now prefers the exact documented board, stable-channel images, and the newest suitable version. If a recovery matching the Brunch major version exists, it is preferred; otherwise the latest suitable recovery is selected.
- Removed the dangerous fallback behavior that could pick an unrelated recovery entry simply because it appeared last in the manifest.
- Prevented stale extracted Brunch files from being reused after the GitHub API returns a newer release. The extraction directory is tagged with its Brunch release.
- Made cached Brunch downloads subject to SHA256 validation when the release publishes a checksum.
- Added ChromeOS recovery ZIP integrity validation and Brunch TAR integrity validation.
- Improved handling of interrupted downloads by keeping resumable `.part` files and validating completed downloads.
- Improved root-disk detection and refusal to erase a target with mounted partitions.
- Enforced the Brunch guide's 16 GB minimum target size.
- Forced `LC_ALL=C` for CPU detection so localized Linux output does not break the CPU/board mapping.

### Changed
- The documented official board mapping is now the only automatic mapping:
  - AMD Ryzen → `gumboz`
  - Intel 10th Gen → `jinlon`
  - Intel 11th–13th Gen → `voxel`
  - Intel 14th Gen / Core Ultra → `kanix`
- Unknown CPU generations no longer silently fall back to `voxel`. A manual `BBBC_BOARD` override is available only for users who have independently verified compatibility.
- Removed automatic writing of undocumented `chromebook_plus` and `enforce_hyperthreading` options to the boot partition.
- The performance profile is now a preference/reporting choice and does not inject experimental boot settings before the first successful boot.
- Added a hardware/install report at `~/Downloads/BBBC/BBBC-hardware-profile.txt` (or under the configured `DOWNLOAD_DIR`).
- Added clearer post-install diagnostics for UEFI/CSM, Secure Boot, NVIDIA/dedicated GPUs, verbose boot, and long first boots.
- Chromebook Plus information is presented as a non-certifying hardware note; BBBC does not spoof device eligibility or guarantee Chromebook Plus features.

### Safety
- The target must be a whole disk, not a partition.
- The active system disk and disks with mounted partitions are rejected.
- The user must type `ERASE` before disk writing, then confirm the target again in Brunch's own installer.
- BBBC does not claim NVIDIA dGPU support. Current official Brunch documentation states that dGPUs are unsupported.

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
