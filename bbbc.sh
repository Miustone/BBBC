#!/bin/bash

# BRUNCH - CHROME OS USB CREATION SCRIPT BY M1U5T0N3
# IF CGPT MAKES TROUBLE INSTALL THIS AUR PACKAGE:
# https://aur.archlinux.org/packages/chromeos-vboot-reference-git

# FLAGS
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'
USERNAME="$(whoami)"

# FUNCTION TO PRINT COLORED MESSAGES
info() {
    echo -e "${BLUE}${BOLD}$1${RESET}"
}

success() {
    echo -e "${GREEN}${BOLD}$1${RESET}"
}

warning() {
    echo -e "${YELLOW}${BOLD}$1${RESET}"
}

error() {
    echo -e "${RED}${BOLD}$1${RESET}"
}

# FUNCTION TO CHECK IF PACKAGE MANAGER IS AVAILABLE
check_package_manager() {
    if command -v apt &>/dev/null; then
        PACKAGE_MANAGER="apt"
    elif command -v pacman &>/dev/null; then
        PACKAGE_MANAGER="pacman"
    else
        error "Neither apt nor pacman package manager found. Please install one of them."
        exit 1
    fi
}

# CHECK THE PACKAGE MANAGER
info "Checking for package manager..."
check_package_manager

# FUNCTION TO CHECK AND INSTALL A PACKAGE IF NOT ALREADY INSTALLED
install_if_missing() {
    local pkg_name="$1"
    if ! command -v "$pkg_name" &>/dev/null; then
        warning "$pkg_name is not installed. Attempting to install it..."
        case "$PACKAGE_MANAGER" in
            apt)
                sudo apt update && sudo apt -y install "$pkg_name"
                ;;
            pacman)
                sudo pacman -Sy --noconfirm "$pkg_name"
                ;;
            *)
                error "Unsupported package manager. Please install $pkg_name manually."
                exit 1
                ;;
        esac
        success "$pkg_name installed successfully."
    else
        success "$pkg_name is already installed."
    fi
}

# ENSURE REQUIRED PACKAGES ARE INSTALLED
REQUIRED_PACKAGES=("pv" "cgpt" "tar" "unzip")
for pkg in "${REQUIRED_PACKAGES[@]}"; do
    install_if_missing "$pkg"
done

# BANNER
echo " "
echo "██████╗ ██████╗ ██████╗  ██████╗"
echo "██╔══██╗██╔══██╗██╔══██╗██╔════╝"
echo "██████╔╝██████╔╝██████╔╝██║     "
echo "██╔══██╗██╔══██╗██╔══██╗██║     "
echo "██████╔╝██████╔╝██████╔╝╚██████╗"
echo "╚═════╝ ╚═════╝ ╚═════╝  ╚═════╝"
echo " BrunchBox Boot Creator (BBBC)"
echo "A simple tool for creating a bootable"
echo " USB stick for ChromeOS using Brunch"

# PROMPT FOR CPU TYPE SELECTION
info "\nSelect your CPU type:"
info "1) Intel 8th & 9th gen Core CPUs (shyvana)"
info "2) Intel 8th & 9th gen Celeron CPUs (bobba)"
info "3) Intel 10th gen Core CPUs (jinlon)"
info "4) Intel 11th gen+ Core CPUs (voxel)"
info "5) AMD Ryzen CPUs (gumboz)"
read -p "$(info 'Enter the number corresponding to your CPU: ')" cpu_choice

# ASSIGN RECOVERY FILE NAME BASED ON CPU SELECTION
case $cpu_choice in
1) recovery_file="rammus_recovery_stable-channel_mp-v5.bin" ;;
2) recovery_file="octopus_recovery_stable-channel_mp-v35.bin" ;;
3) recovery_file="hatch_recovery_stable-channel_mp-v9.bin" ;;
4) recovery_file="volteer_recovery_stable-channel_mp-v11.bin" ;;
5) recovery_file="zork_recovery_stable-channel_mp-v10.bin" ;;
*)
    error "Invalid selection. Exiting."
    exit 1
    ;;
esac

# DEFINE FILE PATHS
recovery_file_path="/home/$USERNAME/Downloads/chromeos_16033.58.0_$recovery_file"
brunch_file_path="/home/$USERNAME/Downloads/brunch.tar.gz"

# CHECK AND DOWNLOAD CHROME OS RECOVERY IMAGE
info "\nChecking Chrome OS recovery file..."
if [ ! -f "$recovery_file_path" ]; then
    info "Downloading Chrome OS recovery for $recovery_file..."
    sudo curl -L -o "$recovery_file_path" "https://dl.google.com/dl/edgedl/chromeos/recovery/chromeos_16033.58.0_$recovery_file.zip"
    success "Chrome OS recovery file downloaded."
else
    warning "Chrome OS recovery file already exists. Skipping download."
fi

# CHECK AND DOWNLOAD BRUNCH
info "\nChecking Brunch file..."
if [ ! -f "$brunch_file_path" ]; then
    info "Downloading Brunch..."
    sudo curl -L -o "$brunch_file_path" "https://github.com/sebanc/brunch/releases/download/r130-stable-20241122/brunch_r130_stable_20241122.tar.gz"
    success "Brunch file downloaded."
else
    warning "Brunch file already exists. Skipping download."
fi

# EXTRACT THE DOWNLOADED FILES
info "\nExtracting Brunch archive..."
cd /home/$USERNAME/Downloads
if [ ! -d "brunch" ]; then
    sudo tar zxvf brunch.tar.gz
    success "Brunch archive extracted."
else
    warning "Brunch archive already extracted. Skipping extraction."
fi

info "\nExtracting Chrome OS recovery archive..."
if [ ! -f "chromeos_16033.58.0_$recovery_file" ]; then
    sudo unzip chromeos-recovery.bin.zip
    success "Chrome OS recovery archive extracted."
else
    warning "Chrome OS recovery archive already extracted. Skipping extraction."
fi

# CHOOSE TARGET DISK FOR INSTALLATION
info "\nListing available disks..."
lsblk -e7
read -p "$(info 'Enter the target disk (e.g., /dev/sdb): ')" target_disk

# CONFIRM INSTALLATION
warning "\nWARNING: This will erase all data on $target_disk. Are you sure you want to continue?"
read -p "$(info 'Type yes to confirm: ')" confirmation

if [ "$confirmation" != "yes" ]; then
    error "Installation aborted."
    exit 1
fi

# INSTALL BRUNCH
info "\nInstalling Chrome OS to $target_disk..."
sudo bash chromeos-install.sh -src chromeos_16033.58.0_$recovery_file -dst $target_disk
success "Installation complete. You can now boot BBBC."
