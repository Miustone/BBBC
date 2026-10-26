#!/usr/bin/env bash
#
# BBBC 2.0 - BrunchBox Boot Creator
# Modern ChromeOS / Brunch installer for x86_64 PCs
#
# 2026 edition:
#   - Detects AMD Ryzen / Intel generation
#   - Uses Brunch's current recommended recovery families
#   - Keeps Brunch and ChromeOS recovery versions aligned
#   - Shows board capabilities (Android / kernel / Chromebook Plus hints)
#   - Supports optional performance-oriented kernel parameters
#   - Safer disk selection and resumable downloads
#
# Current Brunch guidance:
#   Intel 10th gen      -> jinlon
#   Intel 11th-13th gen -> voxel
#   Intel 14th+/Ultra   -> kanix
#   AMD Ryzen           -> gumboz
#
# IMPORTANT:
# Brunch is not official ChromeOS for arbitrary PCs. Hardware support depends
# heavily on Linux kernel support. dGPUs and ARM are unsupported by Brunch.
#

set -Eeuo pipefail
IFS=$'\n\t'

BBBC_VERSION="2.0.0"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads/BBBC}"
BRUNCH_API="https://api.github.com/repos/sebanc/brunch/releases/latest"
CROS_BOARD_BASE="https://cros.download/recovery"

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
        error "BBBC 2.0 beendet mit Fehlercode $rc."
    fi
}
trap cleanup EXIT

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Benötigtes Programm fehlt: $1"
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
    for cmd in curl unzip tar lsblk lscpu sha256sum awk sed grep numfmt; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    ((${#missing[@]} == 0)) && return

    [[ -n "$PM" ]] || die "Fehlende Programme: ${missing[*]}"

    warning "Installiere fehlende Basisprogramme: ${missing[*]}"
    if [[ "$PM" == "pacman" ]]; then
        sudo pacman -S --needed --noconfirm curl unzip tar util-linux coreutils gawk grep sed
    else
        sudo apt-get update
        sudo apt-get install -y curl unzip tar util-linux coreutils gawk grep sed
    fi
}

ensure_cgpt() {
    command -v cgpt >/dev/null 2>&1 && return

    warning "cgpt wurde nicht gefunden."
    if [[ "$PM" == "pacman" ]]; then
        if command -v paru >/dev/null 2>&1; then
            paru -S --needed --noconfirm chromeos-vboot-reference-git
        elif command -v yay >/dev/null 2>&1; then
            yay -S --needed --noconfirm chromeos-vboot-reference-git
        else
            die "Installiere unter Arch z.B. mit: paru -S chromeos-vboot-reference-git"
        fi
    else
        die "Bitte installiere das Paket, das 'cgpt' bereitstellt (vboot/cros-tools)."
    fi

    command -v cgpt >/dev/null 2>&1 || die "cgpt ist weiterhin nicht verfügbar."
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
        CPU_FAMILY="AMD Ryzen"
        BOARD="gumboz"
        BOARD_REASON="Brunch empfiehlt gumboz für Ryzen"
    elif [[ "$CPU_VENDOR" == *GenuineIntel* ]]; then
        PLATFORM="intel"
        if [[ "$CPU_MODEL" =~ (14th|15th|Core\(TM\).*Ultra|Ultra[[:space:]]) ]]; then
            CPU_FAMILY="Intel 14th Gen / Core Ultra oder neuer"
            BOARD="kanix"
            BOARD_REASON="Brunch empfiehlt kanix für Intel 14th Gen / Core Ultra+"
        elif [[ "$CPU_MODEL" =~ (13th|12th|11th|Core\(TM\).*-1[123]) ]]; then
            CPU_FAMILY="Intel 11th-13th Gen"
            BOARD="voxel"
            BOARD_REASON="Brunch empfiehlt voxel für Intel 11th-13th Gen"
        elif [[ "$CPU_MODEL" =~ (10th|Core\(TM\).*-10) ]]; then
            CPU_FAMILY="Intel 10th Gen"
            BOARD="jinlon"
            BOARD_REASON="Brunch empfiehlt jinlon für Intel 10th Gen"
        else
            CPU_FAMILY="Intel (Generation nicht sicher erkannt)"
            BOARD="voxel"
            BOARD_REASON="Fallback auf voxel; bitte bei unbekannter Generation prüfen"
        fi
    else
        PLATFORM="unknown"
        CPU_FAMILY="Unbekannte x86_64-CPU"
        BOARD="voxel"
        BOARD_REASON="Keine automatische Zuordnung möglich"
    fi
}

# ---------- Brunch metadata ----------
get_latest_brunch() {
    info "Suche aktuelle Brunch-Version..."

    local json
    json="$(curl --fail --location --retry 5 \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        "$BRUNCH_API")"

    BRUNCH_TAG="$(printf '%s' "$json" |
        sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"

    [[ -n "$BRUNCH_TAG" ]] || die "Brunch-Version konnte nicht ermittelt werden."

    BRUNCH_URL="$(printf '%s' "$json" |
        grep -oE '"browser_download_url":[[:space:]]*"[^"]+\.tar\.gz"' |
        head -n1 |
        sed -E 's/.*"browser_download_url":[[:space:]]*"([^"]+)".*/\1/')"

    [[ -n "$BRUNCH_URL" ]] || die "Brunch-TAR.GZ konnte nicht ermittelt werden."

    BRUNCH_ARCHIVE="${BRUNCH_URL##*/}"

    # Example: r152-stable-20260913 -> 152
    BRUNCH_MAJOR="$(printf '%s' "$BRUNCH_TAG" |
        sed -nE 's/^r([0-9]+).*/\1/p')"

    [[ -n "$BRUNCH_MAJOR" ]] || die "Konnte ChromeOS-Majorversion aus $BRUNCH_TAG nicht ermitteln."

    # SHA is published in the GitHub release body.
    BRUNCH_SHA="$(printf '%s' "$json" |
        grep -oE 'release_sha256sum=[0-9a-fA-F]{64}' |
        head -n1 |
        cut -d= -f2 || true)"

    info "Brunch: $BRUNCH_TAG / ChromeOS r$BRUNCH_MAJOR"
}

# ---------- recovery metadata ----------
get_recovery_page() {
    RECOVERY_PAGE="$DOWNLOAD_DIR/recovery-${BOARD}.html"
    mkdir -p "$DOWNLOAD_DIR"

    curl --fail --location --retry 5 \
        -o "$RECOVERY_PAGE" \
        "$CROS_BOARD_BASE/$BOARD"
}

find_matching_recovery() {
    local filename version candidate

    # Prefer the recovery whose Chrome major matches Brunch.
    candidate="$(grep -oE 'chromeos_[0-9]+\.[0-9]+\.[0-9]+_[^"<> ]+_recovery_[^"<> ]+\.bin\.zip' "$RECOVERY_PAGE" |
        grep -E "chromeos_${BRUNCH_MAJOR}\." |
        head -n1 || true)"

    if [[ -z "$candidate" ]]; then
        warning "Keine Recovery mit exakt passender Major-Version r$BRUNCH_MAJOR gefunden."
        warning "Suche stattdessen die neueste verfügbare Stable-Recovery."
        candidate="$(grep -oE 'chromeos_[0-9]+\.[0-9]+\.[0-9]+_[^"<> ]+_recovery_stable-channel_[^"<> ]+\.bin\.zip' "$RECOVERY_PAGE" |
            head -n1 || true)"
    fi

    [[ -n "$candidate" ]] || die "Keine passende Recovery für Board $BOARD gefunden."

    RECOVERY_ARCHIVE="$candidate"
    RECOVERY_BIN="${candidate%.zip}"
    RECOVERY_MAJOR="$(printf '%s' "$candidate" | sed -nE 's/^chromeos_([0-9]+)\..*/\1/p')"
    RECOVERY_VERSION="$(printf '%s' "$candidate" | sed -nE 's/^chromeos_([0-9]+\.[0-9]+\.[0-9]+)_.*/\1/p')"

    RECOVERY_URL="https://dl.google.com/dl/edgedl/chromeos/recovery/$RECOVERY_ARCHIVE"

    if [[ "$RECOVERY_MAJOR" != "$BRUNCH_MAJOR" ]]; then
        warning "Brunch r$BRUNCH_MAJOR und Recovery r$RECOVERY_MAJOR sind nicht versionsgleich."
        warning "Installation wird nur nach deiner ausdrücklichen Bestätigung fortgesetzt."
        VERSION_MISMATCH=1
    else
        VERSION_MISMATCH=0
    fi
}

# ---------- capability information ----------
show_capabilities() {
    echo
    info "Ermittelte ChromeOS-Basis"
    printf '  Board:             %s\n' "$BOARD"
    printf '  Recovery:          %s\n' "$RECOVERY_VERSION"
    printf '  Brunch:            %s\n' "$BRUNCH_TAG"
    printf '  CPU-Familie:       %s\n' "$CPU_FAMILY"
    printf '  CPU-Threads:       %s\n' "$CPU_THREADS"
    printf '  Zuordnung:         %s\n' "$BOARD_REASON"

    case "$BOARD" in
        gumboz|zork)
            printf '  Plattformfamilie:  AMD Ryzen / zork\n'
            printf '  Android-Basis:     typischerweise Android 13\n'
            printf '  Hinweis:            Kein offizielles Chromebook-Plus-Board\n'
            ;;
        voxel)
            printf '  Plattformfamilie:  Intel 11th-13th Gen / voxel\n'
            printf '  Android-Basis:     Android 13 auf aktuellen Builds\n'
            printf '  Plus-Potenzial:     hoch bei entsprechender Chromebook-Basis\n'
            ;;
        kanix)
            printf '  Plattformfamilie:  Intel 14th Gen / Core Ultra / rex\n'
            printf '  Android-Basis:     Android 13 auf aktuellen Builds\n'
            printf '  Plus-Potenzial:     sehr hoch; moderne Chromebook-Plus-Geräte\n'
            ;;
        jinlon)
            printf '  Plattformfamilie:  Intel 10th Gen\n'
            ;;
    esac

    echo
    warning "Android-/Chromebook-Plus-Funktionen sind nicht allein vom Recovery-Board abhängig."
    warning "Brunch emuliert ein generisches ChromeOS-System; Google-Gerätefeatures können fehlen."
}

# ---------- Brunch performance configuration ----------
select_performance() {
    PERFORMANCE_MODE="balanced"

    echo
    info "Performance-Profil"
    echo "  1) Balanced (empfohlen)"
    echo "  2) Performance (mehr CPU-Leistung, geringere Sicherheits-/Energieoptimierung)"
    echo "  3) Custom (Brunch-Konfiguration nach der Installation selbst wählen)"
    echo

    read -r -p "Auswahl [1]: " choice
    choice="${choice:-1}"

    case "$choice" in
        1) PERFORMANCE_MODE="balanced" ;;
        2) PERFORMANCE_MODE="performance" ;;
        3) PERFORMANCE_MODE="custom" ;;
        *) die "Ungültige Auswahl." ;;
    esac

    if [[ "$PERFORMANCE_MODE" == "performance" ]]; then
        warning "Performance-Modus gewählt."
        warning "Brunchs enforce_hyperthreading=1 kann Sicherheitsmechanismen umgehen."
        warning "Das wird NICHT blind in das Image geschrieben; du bekommst die Empfehlung nach dem Boot."
    fi
}

# ---------- downloads ----------
download() {
    local url="$1"
    local out="$2"
    local tmp="${out}.part"

    mkdir -p "$(dirname "$out")"

    if [[ -s "$out" ]]; then
        success "Bereits vorhanden: $(basename "$out")"
        return
    fi

    info "Download: $(basename "$out")"
    curl --fail --location --retry 6 --retry-delay 2 \
        --connect-timeout 20 --continue-at - \
        -o "$tmp" "$url"

    mv -f "$tmp" "$out"
    success "Download abgeschlossen: $(basename "$out")"
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
            die "Brunch SHA256-Prüfung fehlgeschlagen!"
        fi
        success "Brunch SHA256 verifiziert."
    else
        warning "Für diese Release-Antwort wurde keine SHA256 gefunden."
    fi

    if [[ ! -f "$RECOVERY_PATH" ]]; then
        info "Entpacke ChromeOS Recovery..."
        unzip -o "$RECOVERY_ZIP_PATH" -d "$DOWNLOAD_DIR"
    fi

    [[ -f "$RECOVERY_PATH" ]] || die "Recovery-BIN nicht gefunden."
    success "Recovery vorbereitet."
}

extract_brunch() {
    BRUNCH_DIR="$DOWNLOAD_DIR/brunch"

    if [[ -f "$BRUNCH_DIR/chromeos-install.sh" ]]; then
        return
    fi

    info "Entpacke Brunch..."
    rm -rf "$BRUNCH_DIR.tmp"
    mkdir -p "$BRUNCH_DIR.tmp"
    tar -xzf "$BRUNCH_PATH" -C "$BRUNCH_DIR.tmp"

    # Archives may contain a top-level directory.
    local installer
    installer="$(find "$BRUNCH_DIR.tmp" -type f -name chromeos-install.sh -print -quit)"

    [[ -n "$installer" ]] || die "chromeos-install.sh nicht im Brunch-Archiv gefunden."

    rm -rf "$BRUNCH_DIR"
    mkdir -p "$BRUNCH_DIR"
    cp -a "$(dirname "$installer")"/. "$BRUNCH_DIR"/
    rm -rf "$BRUNCH_DIR.tmp"

    [[ -f "$BRUNCH_DIR/chromeos-install.sh" ]] || die "Brunch-Installer fehlt."
}

# ---------- disk safety ----------
select_disk() {
    echo
    info "Verfügbare Laufwerke"
    lsblk -e7 -o NAME,SIZE,TYPE,MODEL,TRAN,FSTYPE,MOUNTPOINTS
    echo

    read -r -p "Zielgerät (z.B. /dev/sdb oder /dev/nvme1n1): " TARGET

    [[ -b "$TARGET" ]] || die "$TARGET ist kein Blockgerät."
    [[ "$(lsblk -dn -o TYPE "$TARGET")" == "disk" ]] ||
        die "Bitte das komplette Laufwerk angeben, keine Partition."

    ROOT_SOURCE="$(findmnt -no SOURCE /)"
    ROOT_DISK="$(lsblk -no PKNAME "$ROOT_SOURCE" 2>/dev/null || true)"

    if [[ -n "$ROOT_DISK" && "/dev/$ROOT_DISK" == "$TARGET" ]]; then
        die "Das aktive Systemlaufwerk darf nicht als Ziel verwendet werden."
    fi
}

confirm_disk() {
    local model size
    model="$(lsblk -dn -o MODEL "$TARGET" | xargs)"
    size="$(lsblk -dn -o SIZE "$TARGET" | xargs)"

    echo
    printf '%s%s%s\n' "$RED$BOLD" \
        "WARNUNG: Das komplette Ziellaufwerk wird überschrieben!" "$RESET"
    printf '  Gerät:      %s\n' "$TARGET"
    printf '  Modell:     %s\n' "${model:-unbekannt}"
    printf '  Größe:      %s\n' "${size:-unbekannt}"
    printf '  Board:      %s\n' "$BOARD"
    printf '  ChromeOS:   %s\n' "$RECOVERY_VERSION"
    printf '  Brunch:     %s\n' "$BRUNCH_TAG"
    echo

    read -r -p "Zum endgültigen Löschen exakt ERASE eingeben: " answer
    [[ "$answer" == "ERASE" ]] || die "Abgebrochen."
}

# ---------- install ----------
install_brunch() {
    cd "$BRUNCH_DIR"

    info "Installiere Brunch auf $TARGET..."
    sudo bash ./chromeos-install.sh \
        -src "$RECOVERY_PATH" \
        -dst "$TARGET"
}

post_install_advice() {
    echo
    success "BBBC 2.0 Installation abgeschlossen."
    echo
    info "Empfohlene Schritte nach dem ersten Boot:"
    echo "  1. ChromeOS vollständig starten und Updates einspielen."
    echo "  2. 'ChromeOS (settings)' im Brunch-Bootmenü öffnen."
    echo "  3. Hardware-spezifische Optionen nur bei Bedarf aktivieren."
    echo "  4. CPU-/GPU-/Audio-/WLAN-Funktion prüfen."
    echo

    if [[ "$PERFORMANCE_MODE" == "performance" ]]; then
        warning "Performance-Profil:"
        echo "  Falls du maximale CPU-Leistung testen willst, öffne die Brunch-Konfiguration"
        echo "  und prüfe 'enforce_hyperthreading=1'."
        echo "  Diese Option bewusst nur aktivieren, wenn du den Sicherheits-/Stromverbrauchs-"
        echo "  Kompromiss akzeptierst."
        echo
    fi

    warning "Wichtig: Brunch unterstützt keine dGPUs. Eine dedizierte GPU wird daher"
    warning "nicht automatisch zur ChromeOS-GPU."
}

# ---------- main ----------
main() {
    clear 2>/dev/null || true

    printf '%s%s%s\n' "$CYAN$BOLD" \
        "╔══════════════════════════════════════════════════╗" "$RESET"
    printf '%s%s%s\n' "$CYAN$BOLD" \
        "║       BBBC 2.0 - Modern Brunch Creator         ║" "$RESET"
    printf '%s%s%s\n' "$CYAN$BOLD" \
        "╚══════════════════════════════════════════════════╝" "$RESET"
    printf 'Version: %s\n\n' "$BBBC_VERSION"

    [[ $EUID -ne 0 ]] || die "BBBC bitte ohne sudo starten."

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
        read -r -p "Trotz Versionsabweichung fortfahren? [y/N]: " answer
        [[ "$answer" =~ ^[YyJj]$ ]] || die "Abgebrochen."
    fi

    prepare_files
    extract_brunch

    echo
    success "Alle Dateien sind vorbereitet."
    printf '  CPU:       %s\n' "$CPU_MODEL"
    printf '  Board:     %s\n' "$BOARD"
    printf '  Recovery:  %s\n' "$RECOVERY_VERSION"
    printf '  Brunch:    %s\n' "$BRUNCH_TAG"
    printf '  Profil:    %s\n' "$PERFORMANCE_MODE"
    echo

    select_disk
    confirm_disk
    install_brunch
    post_install_advice
}

main "$@"
