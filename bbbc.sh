#!/usr/bin/env bash
#
# BBBC 26 — BrunchBox Boot Creator
# Version: 2.6.2
# Creates a Brunch/ChromeOS USB drive on supported x86_64 UEFI PCs.
#

set -Eeuo pipefail
IFS=$'\n\t'

BBBC_VERSION="2.6.2"
BBBC_YEAR="26"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-${HOME:-/tmp}/Downloads/BBBC}"
BRUNCH_API="https://api.github.com/repos/sebanc/brunch/releases/latest"
GOOGLE_RECOVERY_MANIFEST="https://dl.google.com/dl/edgedl/chromeos/recovery/recovery.json"
MIN_TARGET_BYTES=16000000000 # 16 GB in decimal bytes, as stated by the Brunch install guide

# ---------- colors & messages ----------
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'

info()    { printf '%s%s%s\n' "$BLUE$BOLD" "$*" "$RESET"; }
success() { printf '%s%s%s\n' "$GREEN$BOLD" "$*" "$RESET"; }
warning() { printf '%s%s%s\n' "$YELLOW$BOLD" "$*" "$RESET"; }
error()   { printf '%s%s%s\n' "$RED$BOLD" "$*" "$RESET" >&2; }
die()     { error "$*"; exit 1; }
cleanup() {
    local rc=$?
    if (( rc != 0 )); then
        error "BBBC ${BBBC_VERSION} exited with error code ${rc}."
    fi
}
trap cleanup EXIT

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command missing: $1"
}

run_root() {
    if (( EUID == 0 )); then
        "$@"
    else
        command -v sudo >/dev/null 2>&1 || die "sudo is required for this operation."
        sudo "$@"
    fi
}

# ---------- package manager / dependencies ----------
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
    local missing=() cmd
    for cmd in curl unzip tar pv lsblk lscpu sha256sum awk sed grep python3 findmnt; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    ((${#missing[@]} == 0)) && return 0
    [[ -n "$PM" ]] || die "Missing commands: ${missing[*]}. Install them with your distro's package manager."

    warning "Installing missing dependencies: ${missing[*]}"
    if [[ "$PM" == "pacman" ]]; then
        run_root pacman -S --needed --noconfirm curl unzip tar pv util-linux coreutils gawk grep sed python
    else
        run_root apt-get update
        run_root apt-get install -y curl unzip tar pv util-linux coreutils gawk grep sed python3 ca-certificates
    fi

    for cmd in curl unzip tar pv lsblk lscpu sha256sum awk sed grep python3 findmnt; do
        command -v "$cmd" >/dev/null 2>&1 || die "Required command is still missing after package installation: $cmd"
    done
}

ensure_cgpt() {
    command -v cgpt >/dev/null 2>&1 && return 0
    warning "cgpt was not found; Brunch requires it."
    if [[ "$PM" == "pacman" ]]; then
        if (( EUID == 0 )); then
            die "On Arch, install cgpt as a normal user, for example: paru -S chromeos-vboot-reference-git; then rerun BBBC."
        elif command -v paru >/dev/null 2>&1; then
            paru -S --needed chromeos-vboot-reference-git
        elif command -v yay >/dev/null 2>&1; then
            yay -S --needed chromeos-vboot-reference-git
        else
            die "On Arch, install cgpt (for example from AUR: chromeos-vboot-reference-git) and rerun BBBC."
        fi
    elif [[ "$PM" == "apt" ]]; then
        run_root apt-get install -y cgpt || true
        if ! command -v cgpt >/dev/null 2>&1; then
            run_root apt-get install -y vboot-utils || die "Could not install cgpt. Install the package providing cgpt/vboot tools and rerun BBBC."
        fi
    else
        die "Please install cgpt (the package providing ChromeOS vboot tools) and rerun BBBC."
    fi
    command -v cgpt >/dev/null 2>&1 || die "cgpt is still unavailable after installation."
}

# ---------- hardware detection ----------
detect_hardware() {
    [[ "$(uname -m)" == "x86_64" ]] || die "Brunch requires an x86_64 host. Detected architecture: $(uname -m)"

    CPU_VENDOR="$(LC_ALL=C lscpu | awk -F: '/Vendor ID/ {gsub(/^[ \t]+/,"",$2); print $2; exit}')"
    CPU_MODEL="$(LC_ALL=C lscpu | awk -F: '/Model name/ {gsub(/^[ \t]+/,"",$2); print $2; exit}')"
    CPU_THREADS="$(nproc --all 2>/dev/null || nproc)"
    CPU_CORES="$(LC_ALL=C lscpu | awk -F: '/^Core\(s\) per socket/ {gsub(/^[ \t]+/,"",$2); print $2; exit}')"
    CPU_SOCKETS="$(LC_ALL=C lscpu | awk -F: '/^Socket\(s\)/ {gsub(/^[ \t]+/,"",$2); print $2; exit}')"
    RAM_KIB="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)"
    RAM_GIB="$(awk -v k="${RAM_KIB:-0}" 'BEGIN {printf "%.1f", k/1048576}')"
    GPU_INFO="Not detected (lspci not installed)"
    if command -v lspci >/dev/null 2>&1; then
        GPU_INFO="$(lspci 2>/dev/null | grep -Ei 'VGA compatible controller|3D controller|Display controller' || true)"
        [[ -n "$GPU_INFO" ]] || GPU_INFO="No display controller found by lspci"
    fi

    # Official Brunch mapping from sebanc/brunch README:
    # Ryzen -> gumboz; Intel 10th -> jinlon; 11th-13th -> voxel; 14th/Core Ultra -> kanix.
    if [[ "$CPU_VENDOR" == *AuthenticAMD* ]]; then
        PLATFORM="amd"
        if [[ "$CPU_MODEL" =~ [Rr]yzen ]]; then
            CPU_FAMILY="AMD Ryzen"
            BOARD="gumboz"
            BOARD_REASON="Official Brunch mapping: AMD Ryzen -> gumboz"
        elif [[ -n "${BBBC_BOARD:-}" ]]; then
            CPU_FAMILY="AMD CPU (manual board override)"
            BOARD="$BBBC_BOARD"
            BOARD_REASON="Manual override supplied; hardware/board compatibility must be verified by the user"
        else
            die "AMD CPU did not identify as Ryzen; automatic Brunch recovery mapping is not safe. Set BBBC_BOARD only after verifying compatibility."
        fi
    elif [[ "$CPU_VENDOR" == *GenuineIntel* ]]; then
        PLATFORM="intel"
        if [[ "$CPU_MODEL" =~ [Cc]ore.*[Uu]ltra|[Cc]ore[[:space:]]*[Uu]ltra|[Uu]ltra[[:space:]] ]]; then
            CPU_FAMILY="Intel Core Ultra"
            BOARD="kanix"
            BOARD_REASON="Official Brunch mapping: Intel Core Ultra -> kanix"
        elif [[ "$CPU_MODEL" =~ (14th|15th|16th|17th)|i[3579]-1[4567][0-9]{3} ]]; then
            CPU_FAMILY="Intel 14th Gen or newer"
            BOARD="kanix"
            BOARD_REASON="Official Brunch mapping: Intel 14th Gen / Core Ultra -> kanix"
        elif [[ "$CPU_MODEL" =~ (11th|12th|13th)|i[3579]-1[123][0-9]{3} ]]; then
            CPU_FAMILY="Intel 11th-13th Gen"
            BOARD="voxel"
            BOARD_REASON="Official Brunch mapping: Intel 11th-13th Gen -> voxel"
        elif [[ "$CPU_MODEL" =~ (10th)|i[3579]-10[0-9]{3} ]]; then
            CPU_FAMILY="Intel 10th Gen"
            BOARD="jinlon"
            BOARD_REASON="Official Brunch mapping: Intel 10th Gen -> jinlon"
        elif [[ -n "${BBBC_BOARD:-}" ]]; then
            CPU_FAMILY="Intel CPU (manual board override)"
            BOARD="$BBBC_BOARD"
            BOARD_REASON="Manual override supplied; hardware/board compatibility must be verified by the user"
        else
            die "Intel generation could not be detected safely from: ${CPU_MODEL:-unknown}. Set BBBC_BOARD only after verifying compatibility; BBBC will not guess."
        fi
    elif [[ -n "${BBBC_BOARD:-}" ]]; then
        PLATFORM="unknown"
        CPU_FAMILY="Unrecognized CPU (manual board override)"
        BOARD="$BBBC_BOARD"
        BOARD_REASON="Manual override supplied; hardware/board compatibility must be verified by the user"
    else
        die "Unsupported or unrecognized CPU vendor: ${CPU_VENDOR:-unknown}. Use BBBC_BOARD only after verifying compatibility."
    fi

    if [[ -n "${BBBC_BOARD:-}" ]]; then
        case "$BBBC_BOARD" in
            gumboz|jinlon|voxel|kanix)
                BOARD="$BBBC_BOARD"
                BOARD_REASON="Manual override via BBBC_BOARD=$BBBC_BOARD (verify compatibility yourself)"
                ;;
            *) die "Invalid BBBC_BOARD='$BBBC_BOARD'. Allowed documented board IDs: gumboz, jinlon, voxel, kanix." ;;
        esac
    fi
}

# ---------- Brunch metadata ----------
get_latest_brunch() {
    info "Fetching the latest official Brunch release..."
    local result
    result="$(curl --fail --silent --show-error --location --retry 5 --retry-delay 2 \
        --connect-timeout 20 --max-time 120 \
        -A "BBBC/${BBBC_VERSION}" -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' "$BRUNCH_API" |
        python3 -c '
import json, re, sys
r = json.load(sys.stdin)
assets = r.get("assets", [])
asset = next((a for a in assets if a.get("name", "").endswith(".tar.gz") and a.get("browser_download_url")), None)
if not asset:
    raise SystemExit("Latest Brunch release has no .tar.gz asset")
tag = r.get("tag_name", "")
if not re.match(r"^r\d+", tag):
    raise SystemExit("Could not parse Brunch release tag")
body = r.get("body", "") or ""
m = re.search(r"release_sha256sum\s*=\s*([0-9a-fA-F]{64})", body)
print("|".join([tag, asset["browser_download_url"], m.group(1).lower() if m else ""]))
')" || die "Could not retrieve or parse Brunch release metadata."

    IFS='|' read -r BRUNCH_TAG BRUNCH_URL BRUNCH_SHA <<< "$result"
    BRUNCH_ARCHIVE="${BRUNCH_URL##*/}"
    BRUNCH_ARCHIVE="${BRUNCH_ARCHIVE%%\?*}"
    BRUNCH_MAJOR="$(printf '%s' "$BRUNCH_TAG" | sed -nE 's/^r([0-9]+).*/\1/p')"
    [[ -n "$BRUNCH_MAJOR" && -n "$BRUNCH_ARCHIVE" ]] || die "Incomplete Brunch release metadata."
    success "Brunch release: $BRUNCH_TAG (ChromeOS base r$BRUNCH_MAJOR)"
}

# ---------- ChromeOS recovery metadata ----------
get_recovery_manifest() {
    mkdir -p "$DOWNLOAD_DIR"
    RECOVERY_PAGE="$DOWNLOAD_DIR/recovery.json"
    local tmp="${RECOVERY_PAGE}.part"
    info "Fetching Google's ChromeOS recovery manifest..."
    curl --fail --silent --show-error --location --retry 5 --retry-delay 2 \
        --connect-timeout 20 --max-time 120 -o "$tmp" "$GOOGLE_RECOVERY_MANIFEST" \
        || die "Could not download Google's recovery manifest."
    python3 - "$tmp" <<'PY' || { rm -f "$tmp"; die "Google recovery manifest is not valid JSON."; }
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
if not isinstance(data, (list, dict)):
    raise SystemExit(1)
PY
    mv -f "$tmp" "$RECOVERY_PAGE"
}

find_matching_recovery() {
    info "Selecting a stable recovery for board '$BOARD'..."
    local result
    result="$(python3 - "$RECOVERY_PAGE" "$BOARD" "$BRUNCH_MAJOR" <<'PY'
import json, re, sys
path, target, brunch_major = sys.argv[1], sys.argv[2].lower(), int(sys.argv[3])
with open(path, encoding="utf-8") as f:
    data = json.load(f)
if isinstance(data, dict):
    data = data.get("devices", data.get("recoveries", data.get("items", [])))
if not isinstance(data, list):
    raise SystemExit("Unexpected recovery manifest structure")

def ver(e):
    value = str(e.get("chrome_version") or e.get("chromeos_version") or e.get("version") or "")
    nums = tuple(int(x) for x in re.findall(r"\d+", value))
    return value, nums

def token_match(value):
    return re.search(r"(?<![a-z0-9])" + re.escape(target) + r"(?![a-z0-9])", str(value).lower()) is not None

matches = []
for e in data:
    if not isinstance(e, dict):
        continue
    url = str(e.get("url") or e.get("download_url") or "")
    if not url.startswith("https://"):
        continue
    board_field = str(e.get("board") or "")
    filename_field = str(e.get("file") or e.get("filename") or "")
    other_match = token_match(filename_field) or token_match(url)
    board_match = token_match(board_field)
    if not (board_match or other_match):
        continue
    version, numbers = ver(e)
    if not numbers:
        continue
    channel = str(e.get("channel") or e.get("channel_name") or "")
    channel_text = (channel + " " + url + " " + filename_field).lower()
    stable = channel.strip().lower() in ("stable", "stable-channel") or "stable-channel" in channel_text
    rank = 2 if board_field.strip().lower() == target else (1 if board_match else 0)
    matches.append({"url": url, "version": version, "numbers": numbers, "channel": channel, "stable": stable, "rank": rank})

if not matches:
    raise SystemExit("No recovery entry for board " + target)
# Prefer stable-channel recoveries when any are available, and prefer an exact
# board-field match over a loose filename/URL match.
stable_matches = [e for e in matches if e["stable"]]
pool = stable_matches if stable_matches else matches
best_rank = max(e["rank"] for e in pool)
pool = [e for e in pool if e["rank"] == best_rank]
# If the Brunch major has a recovery, prefer it. The official Brunch guide also
# allows the latest available recovery if no same-major recovery is published.
same_major = [e for e in pool if e["numbers"][0] == brunch_major]
selection_basis = "same-major stable" if same_major else "latest available stable"
if same_major:
    pool = same_major
chosen = max(pool, key=lambda e: e["numbers"])
print("|".join([chosen["url"], chosen["version"], chosen["channel"] or ("stable" if chosen["stable"] else "channel unspecified"), selection_basis]))
PY
)" || die "No suitable recovery was found for '$BOARD'. Refusing to guess a different board."

    IFS='|' read -r RECOVERY_URL RECOVERY_VERSION RECOVERY_CHANNEL RECOVERY_MATCH <<< "$result"
    RECOVERY_ARCHIVE="${RECOVERY_URL##*/}"
    RECOVERY_ARCHIVE="${RECOVERY_ARCHIVE%%\?*}"
    [[ "$RECOVERY_ARCHIVE" == *.zip ]] || die "Recovery URL did not point to a .zip archive: $RECOVERY_URL"
    RECOVERY_BIN="${RECOVERY_ARCHIVE%.zip}"
    RECOVERY_MAJOR="${RECOVERY_VERSION%%.*}"
    [[ -n "$RECOVERY_VERSION" && -n "$RECOVERY_BIN" ]] || die "Recovery version or filename is missing."

    info "Recovery choice: $RECOVERY_VERSION ($RECOVERY_MATCH; channel: $RECOVERY_CHANNEL)"
    info "The official Brunch Linux guide says the latest available recovery is typically acceptable; a release-number match is not mandatory."
}

# ---------- display / profile ----------
show_capabilities() {
    echo
    info "Detected Hardware / Install Plan"
    printf '  CPU:             %s\n' "${CPU_MODEL:-unknown}"
    printf '  CPU vendor:      %s\n' "${CPU_VENDOR:-unknown}"
    printf '  Cores/socket:    %s\n' "${CPU_CORES:-unknown}"
    printf '  Sockets:         %s\n' "${CPU_SOCKETS:-unknown}"
    printf '  Logical CPUs:    %s\n' "${CPU_THREADS:-unknown}"
    printf '  RAM:             %s GiB\n' "${RAM_GIB:-unknown}"
    printf '  GPU(s):          %s\n' "${GPU_INFO:-unknown}"
    printf '  Brunch board:    %s\n' "$BOARD"
    printf '  Board mapping:   %s\n' "$BOARD_REASON"
    printf '  ChromeOS image:  %s (%s)\n' "$RECOVERY_VERSION" "$RECOVERY_CHANNEL"
    printf '  Brunch release:  %s\n' "$BRUNCH_TAG"
    echo

    if grep -qi 'NVIDIA' <<< "${GPU_INFO:-}"; then
        warning "An NVIDIA display adapter was detected. Current official Brunch documentation does not support dedicated GPUs (dGPUs)."
        warning "If boot stops at the white ChromeOS logo, try disabling the dGPU / selecting the integrated AMD or Intel GPU in firmware settings."
    fi

    if [[ "${CPU_MODEL,,}" =~ ryzen[[:space:]]+[3579][[:space:]]+([5-9][0-9]{3}|[1-9][0-9]{4})|12th|13th|14th|15th|16th|17th|core.*ultra ]]; then
        PLUS_CPU_NOTE="CPU appears to meet the broad Chromebook Plus CPU baseline"
    else
        PLUS_CPU_NOTE="CPU baseline is unknown or below the documented Chromebook Plus-class threshold"
    fi
    if (( ${RAM_KIB:-0} >= 8 * 1024 * 1024 )); then
        PLUS_RAM_NOTE="RAM >= 8 GiB"
    else
        PLUS_RAM_NOTE="RAM < 8 GiB"
    fi
    info "Hardware capability notes (not official Chromebook Plus certification)"
    printf '  CPU:             %s\n' "$PLUS_CPU_NOTE"
    printf '  Memory:          %s\n' "$PLUS_RAM_NOTE"
    printf '  Display/webcam:  not automatically verified by BBBC\n'
    printf '  Note:            PC hardware alone does not guarantee Chromebook Plus features.\n'
}

select_profile() {
    echo
    info "Preferred system profile"
    echo "  1) Desktop Performance (default; no experimental boot parameters injected)"
    echo "  2) Balanced"
    echo "  3) Compatibility / troubleshooting (keep first boot as close to stock as possible)"
    echo
    read -r -p "Profile [1]: " choice
    choice="${choice:-1}"
    case "$choice" in
        1) PERFORMANCE_MODE="Desktop Performance" ;;
        2) PERFORMANCE_MODE="Balanced" ;;
        3) PERFORMANCE_MODE="Compatibility / troubleshooting" ;;
        *) die "Invalid profile selection." ;;
    esac
    info "Selected profile preference: $PERFORMANCE_MODE"
    warning "This profile records your preference and post-boot guidance; it intentionally does not alter the boot image or write custom options."
    warning "No undocumented framework options are written to the boot partition. Configure supported Brunch options after a successful first boot."
    info "SMT note: BBBC leaves the standard Brunch behavior unchanged. The optional enforce_hyperthreading=1 parameter trades away a ChromeOS security mitigation and is not injected automatically."
}

# ---------- download helpers ----------
download() {
    local url="$1" out="$2" expected_sha="${3:-}" tmp="${out}.part" actual
    mkdir -p "$(dirname "$out")"

    if [[ -s "$out" ]]; then
        if [[ -n "$expected_sha" ]]; then
            actual="$(sha256sum "$out" | awk '{print tolower($1)}')"
            if [[ "$actual" != "${expected_sha,,}" ]]; then
                warning "Cached file failed SHA256 validation; downloading it again: $(basename "$out")"
                rm -f "$out"
            fi
        fi
        if [[ -s "$out" ]]; then
            success "Using cached file: $(basename "$out")"
            return 0
        fi
    fi

    info "Downloading: $(basename "$out")"
    curl --fail --show-error --location --retry 6 --retry-delay 2 \
        --connect-timeout 20 --max-time 0 --continue-at - \
        -o "$tmp" "$url" || die "Download failed: $url"
    [[ -s "$tmp" ]] || die "Downloaded file is empty: $url"

    if [[ -n "$expected_sha" ]]; then
        actual="$(sha256sum "$tmp" | awk '{print tolower($1)}')"
        if [[ "$actual" != "${expected_sha,,}" ]]; then
            rm -f "$tmp"
            die "SHA256 verification failed for $(basename "$out"). Expected $expected_sha, got $actual."
        fi
        success "SHA256 verified: $(basename "$out")"
    fi
    mv -f "$tmp" "$out"
    success "Download complete: $(basename "$out")"
}

prepare_files() {
    mkdir -p "$DOWNLOAD_DIR"
    BRUNCH_PATH="$DOWNLOAD_DIR/$BRUNCH_ARCHIVE"
    RECOVERY_ZIP_PATH="$DOWNLOAD_DIR/$RECOVERY_ARCHIVE"
    RECOVERY_PATH="$DOWNLOAD_DIR/$RECOVERY_BIN"

    download "$BRUNCH_URL" "$BRUNCH_PATH" "${BRUNCH_SHA:-}"
    if [[ -n "$BRUNCH_SHA" ]]; then
        local actual
        actual="$(sha256sum "$BRUNCH_PATH" | awk '{print tolower($1)}')"
        [[ "$actual" == "${BRUNCH_SHA,,}" ]] || die "Brunch archive failed SHA256 validation."
    else
        warning "GitHub release metadata did not provide a SHA256 value; Brunch checksum could not be verified."
    fi

    if [[ -s "$RECOVERY_ZIP_PATH" ]] && ! unzip -tq "$RECOVERY_ZIP_PATH" >/dev/null 2>&1; then
        warning "Cached ChromeOS recovery archive is corrupt; deleting it for a fresh download."
        rm -f "$RECOVERY_ZIP_PATH"
    fi
    download "$RECOVERY_URL" "$RECOVERY_ZIP_PATH"
    unzip -tq "$RECOVERY_ZIP_PATH" >/dev/null 2>&1 || die "ChromeOS recovery ZIP failed integrity testing."

    if [[ ! -s "$RECOVERY_PATH" ]]; then
        local temp_dir found_bin
        temp_dir="$DOWNLOAD_DIR/recovery-extract.tmp"
        rm -rf "$temp_dir"
        mkdir -p "$temp_dir"
        info "Extracting ChromeOS recovery image..."
        unzip -q "$RECOVERY_ZIP_PATH" -d "$temp_dir" || die "Failed to extract ChromeOS recovery image."
        found_bin="$(find "$temp_dir" -type f -name '*.bin' -print -quit)"
        [[ -n "$found_bin" ]] || die "No .bin recovery image was found inside the recovery archive."
        cp -f "$found_bin" "$RECOVERY_PATH"
        rm -rf "$temp_dir"
    fi
    [[ -s "$RECOVERY_PATH" ]] || die "ChromeOS recovery BIN is missing or empty."
    success "Recovery image prepared: $(basename "$RECOVERY_PATH")"
}

extract_brunch() {
    BRUNCH_DIR="$DOWNLOAD_DIR/brunch"
    if [[ -f "$BRUNCH_DIR/chromeos-install.sh" && -f "$BRUNCH_DIR/.bbbc-release-tag" ]] \
        && [[ "$(cat "$BRUNCH_DIR/.bbbc-release-tag")" == "$BRUNCH_TAG" ]]; then
        success "Using cached Brunch extraction for $BRUNCH_TAG."
        return 0
    fi

    # A directory from an older Brunch tag must never be reused for the newest archive.
    rm -rf "$BRUNCH_DIR"
    info "Extracting Brunch framework..."
    local temp_dir installer
    temp_dir="$DOWNLOAD_DIR/brunch-extract.tmp"
    rm -rf "$temp_dir"
    mkdir -p "$temp_dir"
    tar -tzf "$BRUNCH_PATH" >/dev/null || die "Brunch archive failed tar integrity testing."
    tar -xzf "$BRUNCH_PATH" -C "$temp_dir" || die "Failed to extract Brunch archive."
    installer="$(find "$temp_dir" -type f -name chromeos-install.sh -print -quit)"
    [[ -n "$installer" ]] || die "chromeos-install.sh was not found in the Brunch archive."

    rm -rf "$BRUNCH_DIR"
    mkdir -p "$BRUNCH_DIR"
    cp -a "$(dirname "$installer")"/. "$BRUNCH_DIR"/
    rm -rf "$temp_dir"
    [[ -f "$BRUNCH_DIR/chromeos-install.sh" ]] || die "Brunch installer is missing after extraction."
    printf '%s\n' "$BRUNCH_TAG" > "$BRUNCH_DIR/.bbbc-release-tag"
    success "Brunch framework prepared for $BRUNCH_TAG."
}

# ---------- disk safety ----------
select_disk() {
    echo
    info "Available drives (choose the entire USB/disk, not a partition)"
    lsblk -e7 -o NAME,SIZE,TYPE,MODEL,TRAN,FSTYPE,MOUNTPOINTS
    echo
    read -r -p "Target device (e.g. /dev/sdb or /dev/nvme1n1): " TARGET
    [[ -b "$TARGET" ]] || die "'$TARGET' is not a block device."
    [[ "$(lsblk -dn -o TYPE "$TARGET" | xargs)" == "disk" ]] || die "Please select the entire disk, not a partition."

    TARGET_REAL="$(readlink -f "$TARGET")"
    local target_bytes
    target_bytes="$(lsblk -bdn -o SIZE "$TARGET" | awk '{print $1}')"
    [[ "$target_bytes" =~ ^[0-9]+$ ]] || die "Could not read the target disk size."
    (( target_bytes >= MIN_TARGET_BYTES )) || die "Target disk is smaller than 16 GB. Current Brunch instructions require at least a 16 GB target."

    # Do not allow a disk that contains the mounted root filesystem or any mounted partition.
    local root_source root_dev ancestor ancestor_real
    root_source="$(findmnt -nro SOURCE -T / | sed 's/\[.*$//')"
    root_dev="${root_source%%\[*}"
    if [[ "$root_dev" == /dev/* ]]; then
        while IFS= read -r ancestor; do
            [[ -n "$ancestor" ]] || continue
            ancestor_real="$(readlink -f "$ancestor" 2>/dev/null || printf '%s' "$ancestor")"
            [[ "$ancestor_real" != "$TARGET_REAL" ]] || die "The selected disk contains the active root filesystem and cannot be overwritten."
        done < <(lsblk -s -npo NAME "$root_dev" 2>/dev/null || true)
    fi

    if lsblk -nrpo MOUNTPOINTS "$TARGET" | grep -q '[^[:space:]]'; then
        die "The target disk has mounted partitions. Unmount them and rerun BBBC; the script will not erase mounted filesystems."
    fi
}

confirm_disk() {
    local model size answer
    model="$(lsblk -dn -o MODEL "$TARGET" | xargs)"
    size="$(lsblk -dn -o SIZE "$TARGET" | xargs)"
    echo
    printf '%s%s%s\n' "$RED$BOLD" "WARNING: ALL DATA ON THE TARGET DISK WILL BE ERASED." "$RESET"
    printf '  Device:        %s\n' "$TARGET"
    printf '  Model:         %s\n' "${model:-unknown}"
    printf '  Size:          %s\n' "${size:-unknown}"
    printf '  Board:         %s\n' "$BOARD"
    printf '  ChromeOS:      %s\n' "$RECOVERY_VERSION"
    printf '  Brunch:        %s\n' "$BRUNCH_TAG"
    printf '  Profile:       %s\n' "$PERFORMANCE_MODE"
    echo
    read -r -p "To permanently erase this disk, type exactly ERASE: " answer
    [[ "$answer" == "ERASE" ]] || die "Installation cancelled."
}

write_hardware_report() {
    local report="$DOWNLOAD_DIR/BBBC-hardware-profile.txt"
    {
        printf 'BBBC version: %s\n' "$BBBC_VERSION"
        printf 'Date (UTC): %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S')"
        printf 'CPU: %s\n' "${CPU_MODEL:-unknown}"
        printf 'CPU vendor: %s\n' "${CPU_VENDOR:-unknown}"
        printf 'Logical CPUs: %s\n' "${CPU_THREADS:-unknown}"
        printf 'RAM GiB: %s\n' "${RAM_GIB:-unknown}"
        printf 'GPU(s):\n%s\n' "${GPU_INFO:-unknown}"
        printf 'Board: %s\n' "$BOARD"
        printf 'Board reason: %s\n' "$BOARD_REASON"
        printf 'Brunch: %s\n' "$BRUNCH_TAG"
        printf 'Recovery version: %s\n' "$RECOVERY_VERSION"
        printf 'Recovery channel: %s\n' "$RECOVERY_CHANNEL"
        printf 'Recovery selection: %s\n' "$RECOVERY_MATCH"
        printf 'Profile preference: %s\n' "$PERFORMANCE_MODE"
        printf 'Target device: %s\n' "$TARGET"
    } > "$report"
    success "Hardware/install report saved to: $report"
}

# ---------- install & post-install checks ----------
install_brunch() {
    cd "$BRUNCH_DIR"
    echo
    info "Starting official Brunch installer for $TARGET."
    info "Brunch will ask for its own confirmation; type 'yes' when the displayed target is correct."
    run_root bash ./chromeos-install.sh -src "$RECOVERY_PATH" -dst "$TARGET"
    sync
    success "Brunch installer returned successfully."

    if command -v cgpt >/dev/null 2>&1; then
        echo
        info "Post-install GPT layout check:"
        if ! run_root cgpt show "$TARGET"; then
            warning "cgpt could not read the final partition table. Check the installer output before rebooting."
        fi
    fi
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS "$TARGET" || true
}

post_install_advice() {
    echo
    success "BBBC ${BBBC_VERSION}: installation procedure completed."
    echo
    info "Before the first boot"
    echo "  1. In UEFI firmware, enable UEFI boot and disable Legacy/CSM mode."
    echo "  2. Select the USB explicitly from the firmware's one-time boot menu."
    echo "  3. If Secure Boot blocks startup, disable Secure Boot or enroll brunch.der when shown by the Brunch shim."
    echo "  4. A first boot may take a long time (occasionally up to an hour); do not assume it has frozen at the Brunch logo."
    echo
    info "If it still will not boot"
    echo "  • No USB/GRUB entry: re-check UEFI mode, USB boot order, and whether the USB was written to the whole disk."
    echo "  • Blue 'Verification failed' screen: Secure Boot key enrollment / firmware setting."
    echo "  • Stuck at the white ChromeOS logo: check dedicated GPU compatibility; Brunch does not currently support dGPUs."
    echo "  • Immediate reboot: use Brunch Verbose Mode / the 'ChromeOS (Settings)' entry and capture the last visible error."
    echo "  • Keep the USB connected for all boot attempts and use a fast USB 3.x drive/port if possible."
    echo
    info "After a successful first boot"
    echo "  Open 'ChromeOS (Settings)' to configure documented Brunch framework options."
    echo "  BBBC deliberately does not write undocumented Chromebook Plus flags or experimental kernel parameters before first boot."
    echo "  Chromebook Plus hardware notes are informational only; BBBC cannot confer official device eligibility/certification."
    echo
}

main() {
    clear 2>/dev/null || true
    printf '%s%s%s\n' "$CYAN$BOLD" "╔══════════════════════════════════════════════════════╗" "$RESET"
    printf '%s%s%s\n' "$CYAN$BOLD" "║                 BBBC ${BBBC_YEAR}                    ║" "$RESET"
    printf '%s%s%s\n' "$CYAN$BOLD" "╚══════════════════════════════════════════════════════╝" "$RESET"
    printf 'Version: %s\n\n' "$BBBC_VERSION"

    detect_pm
    install_basic_packages
    ensure_cgpt
    need_cmd curl
    need_cmd python3
    need_cmd lsblk
    need_cmd findmnt

    detect_hardware
    get_latest_brunch
    mkdir -p "$DOWNLOAD_DIR"
    get_recovery_manifest
    find_matching_recovery
    show_capabilities
    select_profile

    prepare_files
    extract_brunch
    echo
    success "All required files are prepared and checked."
    printf '  CPU:       %s\n' "$CPU_MODEL"
    printf '  Board:     %s\n' "$BOARD"
    printf '  Recovery:  %s (%s)\n' "$RECOVERY_VERSION" "$RECOVERY_MATCH"
    printf '  Brunch:    %s\n' "$BRUNCH_TAG"
    printf '  Profile:   %s\n\n' "$PERFORMANCE_MODE"

    select_disk
    confirm_disk
    write_hardware_report
    install_brunch
    post_install_advice
}

main "$@"
