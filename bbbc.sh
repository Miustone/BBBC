#!/usr/bin/env bash
#
# BBBC 26 - BrunchBox Boot Creator
# Modern ChromeOS / Brunch installer for x86_64 PCs


set -Eeuo pipefail
IFS=$'\n\t'

BBBC_VERSION="2.6.1"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads/BBBC}"
BRUNCH_API="https://api.github.com/repos/sebanc/brunch/releases/latest"
GOOGLE_RECOVERY_MANIFEST="https://dl.google.com/dl/edgedl/chromeos/recovery/recovery.json"

# ---------- colors ----------
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'
MAGENTA=$'\033[0;35m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
RESET=$'\033[0m'

info()    { printf '%s%s%s\n' "$BLUE$BOLD" "$*" "$RESET"; }
success() { printf '%s%s%s\n' "$GREEN$BOLD" "$*" "$RESET"; }
warning() { printf '%s%s%s\n' "$YELLOW$BOLD" "$*" "$RESET"; }
error()   { printf '%s%s%s\n' "$RED$BOLD" "$*" "$RESET" >&2; }
die()     { error "$*"; exit 1; }

cleanup() {
    local rc=$?
    if (( rc != 0 )); then
        error "BBBC 26 exited with error code $rc."
    fi
}
trap cleanup EXIT

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required program missing: $1"
}

# ---------- package manager ----------
detect_pm() {
    if command -v pacman >/dev/null 2>&1; then
        PM="pacman"
    elif command -v apt-get >/dev/null 2>&1; then
        PM="apt"
    else
        PM=""
    fi
}

install_basic_packages() {
    local missing=()
    local cmd
    for cmd in curl unzip tar lsblk lscpu sha256sum awk sed grep numfmt python3; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    ((${#missing[@]} == 0)) && return

    [[ -n "$PM" ]] || die "Missing packages: ${missing[*]}"

    warning "Installing missing basic packages: ${missing[*]}"
    if [[ "$PM" == "pacman" ]]; then
        sudo pacman -S --needed --noconfirm curl unzip tar util-linux coreutils gawk grep sed python
    else
        sudo apt-get update
        sudo apt-get install -y curl unzip tar util-linux coreutils gawk grep sed python3
    fi
}

ensure_cgpt() {
    command -v cgpt >/dev/null 2>&1 && return

    warning "cgpt was not found."
    if [[ "$PM" == "pacman" ]]; then
        if command -v paru >/dev/null 2>&1; then
            paru -S --needed --noconfirm chromeos-vboot-reference-git
        elif command -v yay >/dev/null 2>&1; then
            yay -S --needed --noconfirm chromeos-vboot-reference-git
        else
            die "On Arch Linux, install it e.g. with: paru -S chromeos-vboot-reference-git"
        fi
    else
        die "Please install the package providing 'cgpt' (vboot/cros-tools)."
    fi

    command -v cgpt >/dev/null 2>&1 || die "cgpt is still not available."
}

# ---------- hardware detection ----------
detect_hardware() {
    CPU_VENDOR="$(lscpu | awk -F: '/Vendor ID/ {gsub(/^[ \t]+/,"",$2); print $2; exit}')"
    CPU_MODEL="$(lscpu | awk -F: '/Model name/ {gsub(/^[ \t]+/,"",$2); print $2; exit}')"
    CPU_THREADS="$(nproc)"
    CPU_CORES="$(lscpu | awk -F: '/Core\(s\) per socket/ {gsub(/^[ \t]+/,"",$2); print $2; exit}')"
    CPU_SOCKETS="$(lscpu | awk -F: '/Socket\(s\)/ {gsub(/^[ \t]+/,"",$2); print $2; exit}')"

    if [[ "$CPU_VENDOR" == *AuthenticAMD* ]]; then
        PLATFORM="amd"
        if [[ "$CPU_MODEL" =~ (7[0-9]{3}|8[0-9]{3}|Phoenix|Hawk|Zen[[:space:]]*4) ]]; then
            CPU_FAMILY="AMD Ryzen 7000 / 8000 Series (Zen 4)"
            BOARD="majestic"
            BOARD_REASON="Brunch recommends majestic for Ryzen 7000/8000 series"
        elif [[ "$CPU_MODEL" =~ (5[0-9]{3}|6[0-9]{3}|Cezanne|Barcelo|Rembrandt) ]]; then
            CPU_FAMILY="AMD Ryzen 5000 / 6000 Series"
            BOARD="guybrush"
            BOARD_REASON="Brunch recommends guybrush for Ryzen 5000/6000 series"
        else
            CPU_FAMILY="AMD Ryzen (General / Mendocino / Legacy)"
            BOARD="gumboz"
            BOARD_REASON="Brunch recommends gumboz / zork for general AMD Ryzen"
        fi
    elif [[ "$CPU_VENDOR" == *GenuineIntel* ]]; then
        PLATFORM="intel"
        if [[ "$CPU_MODEL" =~ (14th|15th|Core\(TM\).*Ultra|Ultra[[:space:]]) ]]; then
            CPU_FAMILY="Intel 14th Gen / Core Ultra or newer"
            BOARD="kanix"
            BOARD_REASON="Brunch recommends kanix for Intel 14th Gen / Core Ultra+"
        elif [[ "$CPU_MODEL" =~ (13th|12th|11th|Core\(TM\).*-1[123]) ]]; then
            CPU_FAMILY="Intel 11th-13th Gen"
            BOARD="voxel"
            BOARD_REASON="Brunch recommends voxel for Intel 11th-13th Gen"
        elif [[ "$CPU_MODEL" =~ (10th|Core\(TM\).*-10) ]]; then
            CPU_FAMILY="Intel 10th Gen"
            BOARD="jinlon"
            BOARD_REASON="Brunch recommends jinlon for Intel 10th Gen"
        else
            CPU_FAMILY="Intel (Generation not confidently detected)"
            BOARD="voxel"
            BOARD_REASON="Fallback to voxel; please verify if generation is unknown"
        fi
    else
        PLATFORM="unknown"
        CPU_FAMILY="Unknown x86_64 CPU"
        BOARD="voxel"
        BOARD_REASON="No automatic mapping available"
    fi
}

# ---------- Brunch metadata ----------
get_latest_brunch() {
    info "Searching for latest Brunch version..."

    local json
    json="$(curl --fail --location --retry 5 \
        -A "BBBC-Installer/26" \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        "$BRUNCH_API")"

    BRUNCH_TAG="$(printf '%s' "$json" |
        sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"

    [[ -n "$BRUNCH_TAG" ]] || die "Could not determine Brunch version from GitHub."

    BRUNCH_URL="$(printf '%s' "$json" |
        grep -oE '"browser_download_url":[[:space:]]*"[^"]+\.tar\.gz"' |
        head -n1 |
        sed -E 's/.*"browser_download_url":[[:space:]]*"([^"]+)".*/\1/')"

    [[ -n "$BRUNCH_URL" ]] || die "Could not determine Brunch TAR.GZ URL."

    BRUNCH_ARCHIVE="${BRUNCH_URL##*/}"
    BRUNCH_MAJOR="$(printf '%s' "$BRUNCH_TAG" | sed -nE 's/^r([0-9]+).*/\1/p')"

    [[ -n "$BRUNCH_MAJOR" ]] || die "Could not determine ChromeOS major version from $BRUNCH_TAG."

    BRUNCH_SHA="$(printf '%s' "$json" |
        grep -oE 'release_sha256sum=[0-9a-fA-F]{64}' |
        head -n1 |
        cut -d= -f2 || true)"

    info "Brunch: $BRUNCH_TAG / ChromeOS r$BRUNCH_MAJOR"
}

# ---------- recovery metadata ----------
get_recovery_page() {
    RECOVERY_PAGE="$DOWNLOAD_DIR/recovery.json"
    mkdir -p "$DOWNLOAD_DIR"

    info "Fetching official Google ChromeOS recovery manifest..."
    curl --fail --location --retry 5 \
        -o "$RECOVERY_PAGE" \
        "$GOOGLE_RECOVERY_MANIFEST"
}

find_matching_recovery() {
    info "Matching ChromeOS recovery image for board '$BOARD'..."

    local py_output
    py_output="$(python3 -c '
import json, sys

manifest_file, target_board, target_major = sys.argv[1], sys.argv[2].lower(), sys.argv[3]

with open(manifest_file, "r", encoding="utf-8") as f:
    data = json.load(f)

aliases = [target_board]
if target_board in ["majestic", "glinda", "gumboz", "guybrush", "zork", "skyrim"]:
    aliases = [target_board, "majestic", "glinda", "guybrush", "gumboz", "zork", "skyrim"]
elif target_board in ["kanix", "rex"]:
    aliases = [target_board, "kanix", "rex", "voxel"]

matched_entry = None
matched_board = target_board

for b in aliases:
    entries = [
        e for e in data
        if b in e.get("board", "").lower() or b in e.get("file", "").lower() or b in e.get("url", "").lower()
    ]
    if not entries:
        continue
    
    matched_board = b
    for e in entries:
        cros_v = e.get("chrome_version") or e.get("chromeos_version") or ""
        if cros_v.startswith(f"{target_major}."):
            matched_entry = e
            break
    
    if not matched_entry and entries:
        matched_entry = entries[-1]
        
    if matched_entry:
        break

if matched_entry:
    url = matched_entry.get("url", "")
    cros_v = matched_entry.get("chrome_version") or matched_entry.get("chromeos_version") or matched_entry.get("version", "")
    print(f"{url}|{cros_v}|{matched_board}")
' "$RECOVERY_PAGE" "$BOARD" "$BRUNCH_MAJOR")"

    [[ -n "$py_output" ]] || die "No matching recovery image found in Google manifest."

    IFS='|' read -r RECOVERY_URL RECOVERY_VERSION RESOLVED_BOARD <<< "$py_output"
    BOARD="$RESOLVED_BOARD"

    RECOVERY_ARCHIVE="${RECOVERY_URL##*/}"
    RECOVERY_BIN="${RECOVERY_ARCHIVE%.zip}"
    RECOVERY_MAJOR="${RECOVERY_VERSION%%.*}"

    if [[ "$RECOVERY_MAJOR" != "$BRUNCH_MAJOR" ]]; then
        warning "Brunch major version (r$BRUNCH_MAJOR) and available ChromeOS Recovery version (r$RECOVERY_MAJOR / $RECOVERY_VERSION) differ."
        VERSION_MISMATCH=1
    else
        VERSION_MISMATCH=0
    fi
}

# ---------- capability information ----------
show_capabilities() {
    echo
    info "Detected ChromeOS Base"
    printf '  Board:             %s\n' "$BOARD"
    printf '  Recovery:          %s\n' "$RECOVERY_VERSION"
    printf '  Brunch:            %s\n' "$BRUNCH_TAG"
    printf '  CPU Family:        %s\n' "$CPU_FAMILY"
    printf '  CPU Threads:       %s\n' "$CPU_THREADS"
    printf '  Mapping:           %s\n' "$BOARD_REASON"

    case "$BOARD" in
        majestic|glinda)
            printf '  Platform Family:   AMD Ryzen 7000 / 8000 Series (Zen 4 / Phoenix / Hawk Point)\n'
            printf '  Android Base:      Android 13 / 14 on current builds\n'
            printf '  Plus Potential:    Native support via chromebook_plus option\n'
            ;;
        gumboz|guybrush|zork|skyrim)
            printf '  Platform Family:   AMD Ryzen / guybrush / zork / skyrim\n'
            printf '  Android Base:      Typically Android 13\n'
            ;;
        voxel)
            printf '  Platform Family:   Intel 11th-13th Gen / voxel\n'
            printf '  Android Base:      Android 13 on current builds\n'
            ;;
        kanix)
            printf '  Platform Family:   Intel 14th Gen / Core Ultra / rex\n'
            printf '  Android Base:      Android 13 on current builds\n'
            ;;
        jinlon)
            printf '  Platform Family:   Intel 10th Gen\n'
            ;;
    esac
}

# ---------- Brunch options & performance configuration ----------
select_performance() {
    BRUNCH_OPTIONS="chromebook_plus"
    PERFORMANCE_MODE="balanced"

    echo
    info "Performance & Feature Profile"
    echo "  1) Balanced + Chromebook Plus (Recommended - Out-of-the-Box Plus Experience)"
    echo "  2) Performance + Chromebook Plus (Enforces Hyperthreading)"
    echo "  3) Custom (No pre-configured options)"
    echo

    read -r -p "Selection [1]: " choice
    choice="${choice:-1}"

    case "$choice" in
        1)
            BRUNCH_OPTIONS="chromebook_plus"
            PERFORMANCE_MODE="balanced"
            ;;
        2)
            BRUNCH_OPTIONS="chromebook_plus,enforce_hyperthreading"
            PERFORMANCE_MODE="performance"
            ;;
        3)
            BRUNCH_OPTIONS=""
            PERFORMANCE_MODE="custom"
            ;;
        *) die "Invalid selection." ;;
    esac

    if [[ -n "$BRUNCH_OPTIONS" ]]; then
        info "Pre-configuring Brunch options: $BRUNCH_OPTIONS"
    fi
}

# ---------- downloads ----------
download() {
    local url="$1"
    local out="$2"
    local tmp="${out}.part"

    mkdir -p "$(dirname "$out")"

    if [[ -s "$out" ]]; then
        success "Already exists: $(basename "$out")"
        return
    fi

    info "Download: $(basename "$out")"
    curl --fail --location --retry 6 --retry-delay 2 \
        --connect-timeout 20 --continue-at - \
        -o "$tmp" "$url"

    mv -f "$tmp" "$out"
    success "Download complete: $(basename "$out")"
}

prepare_files() {
    mkdir -p "$DOWNLOAD_DIR"

    BRUNCH_PATH="$DOWNLOAD_DIR/$BRUNCH_ARCHIVE"
    RECOVERY_ZIP_PATH="$DOWNLOAD_DIR/$RECOVERY_ARCHIVE"
    RECOVERY_PATH="$DOWNLOAD_DIR/$RECOVERY_BIN"

    download "$BRUNCH_URL" "$BRUNCH_PATH"
    download "$RECOVERY_URL" "$RECOVERY_ZIP_PATH"

    if [[ -n "${BRUNCH_SHA:-}" ]]; then
        local actual
        actual="$(sha256sum "$BRUNCH_PATH" | awk '{print $1}')"
        if [[ "$actual" != "$BRUNCH_SHA" ]]; then
            die "Brunch SHA256 check failed!"
        fi
        success "Brunch SHA256 verified."
    else
        warning "No SHA256 hash found for this release response."
    fi

    if [[ ! -f "$RECOVERY_PATH" ]]; then
        info "Unpacking ChromeOS Recovery..."
        unzip -o "$RECOVERY_ZIP_PATH" -d "$DOWNLOAD_DIR"
    fi

    [[ -f "$RECOVERY_PATH" ]] || die "Recovery BIN not found."
    success "Recovery prepared."
}

extract_brunch() {
    BRUNCH_DIR="$DOWNLOAD_DIR/brunch"

    if [[ -f "$BRUNCH_DIR/chromeos-install.sh" ]]; then
        return
    fi

    info "Unpacking Brunch..."
    rm -rf "$BRUNCH_DIR.tmp"
    mkdir -p "$BRUNCH_DIR.tmp"
    tar -xzf "$BRUNCH_PATH" -C "$BRUNCH_DIR.tmp"

    local installer
    installer="$(find "$BRUNCH_DIR.tmp" -type f -name chromeos-install.sh -print -quit)"

    [[ -n "$installer" ]] || die "chromeos-install.sh not found in Brunch archive."

    rm -rf "$BRUNCH_DIR"
    mkdir -p "$BRUNCH_DIR"
    cp -a "$(dirname "$installer")"/. "$BRUNCH_DIR"/
    rm -rf "$BRUNCH_DIR.tmp"

    [[ -f "$BRUNCH_DIR/chromeos-install.sh" ]] || die "Brunch installer missing."
}

# ---------- disk safety ----------
select_disk() {
    echo
    info "Available Drives"
    lsblk -e7 -o NAME,SIZE,TYPE,MODEL,TRAN,FSTYPE,MOUNTPOINTS
    echo

    read -r -p "Target device (e.g. /dev/sdb or /dev/nvme1n1): " TARGET

    [[ -b "$TARGET" ]] || die "$TARGET is not a block device."
    [[ "$(lsblk -dn -o TYPE "$TARGET")" == "disk" ]] ||
        die "Please specify the entire drive, not a partition."

    ROOT_SOURCE="$(findmnt -no SOURCE /)"
    ROOT_DISK="$(lsblk -no PKNAME "$ROOT_SOURCE" 2>/dev/null || true)"

    if [[ -n "$ROOT_DISK" && "/dev/$ROOT_DISK" == "$TARGET" ]]; then
        die "The active system drive cannot be used as the target."
    fi
}

confirm_disk() {
    local model size
    model="$(lsblk -dn -o MODEL "$TARGET" | xargs)"
    size="$(lsblk -dn -o SIZE "$TARGET" | xargs)"

    echo
    printf '%s%s%s\n' "$RED$BOLD" \
        "WARNING: The entire target drive will be overwritten!" "$RESET"
    printf '  Device:     %s\n' "$TARGET"
    printf '  Model:      %s\n' "${model:-unknown}"
    printf '  Size:       %s\n' "${size:-unknown}"
    printf '  Board:      %s\n' "$BOARD"
    printf '  ChromeOS:   %s\n' "$RECOVERY_VERSION"
    printf '  Brunch:     %s\n' "$BRUNCH_TAG"
    printf '  Options:    %s\n' "${BRUNCH_OPTIONS:-None}"
    echo

    read -r -p "To permanently erase, type exactly ERASE: " answer
    [[ "$answer" == "ERASE" ]] || die "Aborted."
}

# ---------- install & post-configuration ----------
install_brunch() {
    cd "$BRUNCH_DIR"

    info "Installing Brunch to $TARGET..."
    sudo bash ./chromeos-install.sh \
        -src "$RECOVERY_PATH" \
        -dst "$TARGET"

    if [[ -n "${BRUNCH_OPTIONS:-}" ]]; then
        echo
        info "Writing Brunch options ($BRUNCH_OPTIONS) to target drive Partition 12..."
        local boot_part
        if [[ "$TARGET" == *nvme* || "$TARGET" == *mmcblk* ]]; then
            boot_part="${TARGET}p12"
        else
            boot_part="${TARGET}12"
        fi

        local mnt_dir="/tmp/brunch_efi_mnt"
        mkdir -p "$mnt_dir"

        if mount "$boot_part" "$mnt_dir" 2>/dev/null; then
            mkdir -p "$mnt_dir/brunch"
            echo "$BRUNCH_OPTIONS" | tr ',' '\n' > "$mnt_dir/brunch/options"
            umount "$mnt_dir"
            rm -rf "$mnt_dir"
            success "Brunch options successfully applied to $boot_part!"
        else
            warning "Could not automatically mount $boot_part. Options can still be enabled after boot via Brunch settings."
        fi
    fi
}

post_install_advice() {
    echo
    success "BBBC 26 installation completed."
    echo
    info "Recommended steps after first boot:"
    echo "  1. Boot ChromeOS and log into your account."
    echo "  2. Go to chrome://flags and enable '#feature-management-chromebook-plus'."
    echo "  3. Restart the browser to access Magic Eraser, AI Wallpapers, and Help Me Write."
    echo
}

# ---------- main ----------
main() {
    clear 2>/dev/null || true

    printf '%s%s%s\n' "$CYAN$BOLD" \
        "╔══════════════════════════════════════════════════╗" "$RESET"
    printf '%s%s%s\n' "$CYAN$BOLD" \
        "║         BBBC 26 - Modern Brunch Creator         ║" "$RESET"
    printf '%s%s%s\n' "$CYAN$BOLD" \
        "╚══════════════════════════════════════════════════╝" "$RESET"
    printf 'Version: %s\n\n' "$BBBC_VERSION"

    if [[ $EUID -ne 0 ]]; then
        info "Requesting administrative privileges for disk management..."
        exec sudo bash "$0" "$@"
    fi

    detect_pm
    install_basic_packages
    ensure_cgpt
    need_cmd sudo
    need_cmd findmnt

    detect_hardware
    get_latest_brunch

    mkdir -p "$DOWNLOAD_DIR"
    get_recovery_page
    find_matching_recovery

    show_capabilities
    select_performance

    if (( VERSION_MISMATCH )); then
        echo
        read -r -p "Continue despite version mismatch? [y/N]: " answer
        [[ "$answer" =~ ^[YyJj]$ ]] || die "Aborted."
    fi

    prepare_files
    extract_brunch

    echo
    success "All files are prepared."
    printf '  CPU:       %s\n' "$CPU_MODEL"
    printf '  Board:     %s\n' "$BOARD"
    printf '  Recovery:  %s\n' "$RECOVERY_VERSION"
    printf '  Brunch:    %s\n' "$BRUNCH_TAG"
    printf '  Options:   %s\n' "${BRUNCH_OPTIONS:-None}"
    echo

    select_disk
    confirm_disk
    install_brunch
    post_install_advice
}

main "$@"