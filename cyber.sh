#!/usr/bin/env bash
#
# Cybertron Kernel Build Script (cyber.sh)
# Targets: Motorola SM6150
#   - Motorola One Fusion+ [liber]
#   - Motorola Moto G40/G60 [hanoip]
#   - Motorola Moto G9 Plus [odessa]
# Base: Linux 4.14.357-openela (Cybertron Kernel v20 - ccache accelerated)
# Maintainer: cool585 (DhineshCool)
#

set -eo pipefail

# ANSI color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Dynamically determine Script and Kernel Root Directories
SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [ -h "${SCRIPT_SOURCE}" ]; do
    SCRIPT_DIR="$(cd -P "$(dirname "${SCRIPT_SOURCE}")" && pwd)"
    SCRIPT_SOURCE="$(readlink "${SCRIPT_SOURCE}")"
    [[ ${SCRIPT_SOURCE} != /* ]] && SCRIPT_SOURCE="${SCRIPT_DIR}/${SCRIPT_SOURCE}"
done
SCRIPT_DIR="$(cd -P "$(dirname "${SCRIPT_SOURCE}")" && pwd)"

# Find Kernel Root (directory containing Makefile and Kconfig)
if [ -f "${SCRIPT_DIR}/Makefile" ] && [ -f "${SCRIPT_DIR}/Kconfig" ]; then
    KERNEL_ROOT="${SCRIPT_DIR}"
elif [ -f "$(pwd)/Makefile" ] && [ -f "$(pwd)/Kconfig" ]; then
    KERNEL_ROOT="$(pwd)"
else
    SEARCH_DIR="${SCRIPT_DIR}"
    while [ "${SEARCH_DIR}" != "/" ] && [ -n "${SEARCH_DIR}" ]; do
        if [ -f "${SEARCH_DIR}/Makefile" ] && [ -f "${SEARCH_DIR}/Kconfig" ]; then
            KERNEL_ROOT="${SEARCH_DIR}"
            break
        fi
        SEARCH_DIR="$(dirname "${SEARCH_DIR}")"
    done
fi
KERNEL_ROOT="${KERNEL_ROOT:-$(pwd)}"

# Ensure valid kernel root
if [ ! -f "${KERNEL_ROOT}/Makefile" ] || [ ! -f "${KERNEL_ROOT}/Kconfig" ]; then
    echo -e "${RED}[ERROR]: Valid Linux kernel root not found (missing Makefile or Kconfig in ${KERNEL_ROOT})!${NC}"
    exit 1
fi

# Default Build Variables
TARGET_DEVICES=()
CLEAN_BUILD=0
MENUCONFIG=0
UPDATE_TC=0
ENABLE_KSU=${ENABLE_KSU:-0}

# Parse Command-Line Arguments
show_help() {
    echo -e "${BOLD}Usage:${NC} $0 [DEVICE...] [OPTIONS]"
    echo ""
    echo -e "${BOLD}Supported Devices:${NC}"
    echo "  liber     - Motorola One Fusion+ (vendor/liber_defconfig) [default]"
    echo "  hanoip    - Motorola Moto G40/G60 (vendor/hanoip_defconfig)"
    echo "  odessa    - Motorola Moto G9 Plus (vendor/odessa_defconfig)"
    echo "  all       - Build all 3 devices sequentially (liber, hanoip, odessa)"
    echo ""
    echo -e "${BOLD}Options:${NC}"
    echo "  -d, --device <dev>      Target device(s) (comma-separated or repeated)"
    echo "  -c, --clean             Clean out directory before building"
    echo "  -k, --ksu               Build kernel with KernelSU (manipvlator/KernelSU)"
    echo "  -m, --menuconfig        Launch kernel menuconfig interface (single-device only)"
    echo "  -u, --update-toolchain  Update Neutron-Clang toolchain via antman"
    echo "  -h, --help              Show this help message"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo "  $0 liber"
    echo "  $0 hanoip --clean"
    echo "  $0 odessa --ksu"
    echo "  $0 all"
    echo "  $0 liber hanoip"
    echo "  $0 -d liber,odessa -k"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        liber|hanoip|odessa)
            TARGET_DEVICES+=("$1")
            shift
            ;;
        all|both)
            TARGET_DEVICES=("liber" "hanoip" "odessa")
            shift
            ;;
        -d|--device)
            IFS=',' read -ra DEVS <<< "$2"
            for d in "${DEVS[@]}"; do
                d_trim="$(echo "${d}" | xargs)"
                if [ "${d_trim}" = "all" ] || [ "${d_trim}" = "both" ]; then
                    TARGET_DEVICES=("liber" "hanoip" "odessa")
                elif [ -n "${d_trim}" ]; then
                    TARGET_DEVICES+=("${d_trim}")
                fi
            done
            shift 2
            ;;
        -d=*|--device=*)
            RAW_DEVS="${1#*=}"
            IFS=',' read -ra DEVS <<< "${RAW_DEVS}"
            for d in "${DEVS[@]}"; do
                d_trim="$(echo "${d}" | xargs)"
                if [ "${d_trim}" = "all" ] || [ "${d_trim}" = "both" ]; then
                    TARGET_DEVICES=("liber" "hanoip" "odessa")
                elif [ -n "${d_trim}" ]; then
                    TARGET_DEVICES+=("${d_trim}")
                fi
            done
            shift
            ;;
        -c|--clean)
            CLEAN_BUILD=1
            shift
            ;;
        -k|--ksu)
            ENABLE_KSU=1
            shift
            ;;
        -m|--menuconfig)
            MENUCONFIG=1
            shift
            ;;
        -u|--update-toolchain)
            UPDATE_TC=1
            shift
            ;;
        -h|--help)
            show_help
            ;;
        *)
            echo -e "${YELLOW}[WARN]: Unknown argument '$1'. Ignored.${NC}"
            shift
            ;;
    esac
done

# Fallback to liber if no device specified
if [ "${#TARGET_DEVICES[@]}" -eq 0 ]; then
    TARGET_DEVICES=("liber")
fi

# Remove duplicates while preserving order
UNIQUE_DEVICES=()
for dev in "${TARGET_DEVICES[@]}"; do
    skip=0
    for u in "${UNIQUE_DEVICES[@]}"; do
        if [ "$u" = "$dev" ]; then
            skip=1
            break
        fi
    done
    [ $skip -eq 0 ] && UNIQUE_DEVICES+=("$dev")
done
TARGET_DEVICES=("${UNIQUE_DEVICES[@]}")

# Validate single device when menuconfig is requested
if [ "${MENUCONFIG}" -eq 1 ] && [ "${#TARGET_DEVICES[@]}" -gt 1 ]; then
    echo -e "${RED}[ERROR]: Menuconfig can only be launched for a single device, not multiple!${NC}"
    exit 1
fi

# Detect Target Branch (from environment or git repository)
DETECTED_BRANCH="${TARGET_BRANCH:-${BRANCH:-${GITHUB_REF_NAME:-}}}"
if [ -z "${DETECTED_BRANCH}" ] && [ -d "${KERNEL_ROOT}/.git" ]; then
    DETECTED_BRANCH="$(git -C "${KERNEL_ROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
fi

# Automatically enable KernelSU if branch name ends with 'ksu' (case-insensitive)
if [[ "${DETECTED_BRANCH,,}" == *ksu ]] || [ "${KSU:-0}" -eq 1 ]; then
    ENABLE_KSU=1
fi

# Derive kernel version tag from branch name (e.g. v19, v20, v21)
CLEAN_VER="${DETECTED_BRANCH}"
if [[ "${CLEAN_VER,,}" == *-ksu ]]; then
    CLEAN_VER="${CLEAN_VER%-*}"
elif [[ "${CLEAN_VER,,}" == *_ksu ]]; then
    CLEAN_VER="${CLEAN_VER%_*}"
elif [[ "${CLEAN_VER,,}" == *ksu ]] && [ "${#CLEAN_VER}" -gt 3 ]; then
    CLEAN_VER="${CLEAN_VER%[kK][sS][uU]}"
fi

# Fallback to v20 if branch is detached or empty
if [ -z "${CLEAN_VER}" ] || [ "${CLEAN_VER}" = "HEAD" ]; then
    CLEAN_VER="v20"
fi

PARENT_DIR="$(cd "${KERNEL_ROOT}/.." && pwd)"
OUT_DIR="${KERNEL_ROOT}/out"
BUILD_DIR="${KERNEL_ROOT}/build"

export KBUILD_BUILD_USER="cool585"
export KBUILD_BUILD_HOST="cybertron"
export ARCH=arm64
export SUBARCH=arm64

echo -e "${CYAN}${BOLD}"
echo "=================================================="
echo "          Cybertron Kernel Builder (${CLEAN_VER})          "
echo "=================================================="
echo -e "${NC}"
echo -e " Target Device(s) : ${GREEN}${BOLD}${TARGET_DEVICES[*]}${NC}"
echo -e " Kernel Root      : ${KERNEL_ROOT}"
echo -e " Kernel Ver       : ${GREEN}${CLEAN_VER}${NC}"
echo -e " Out Directory    : ${OUT_DIR}"
echo -e " KernelSU         : $([ "${ENABLE_KSU}" -eq 1 ] && echo -e "${GREEN}${BOLD}Enabled (manipvlator/KernelSU)${NC}" || echo -e "${YELLOW}Disabled${NC}")"
echo -e " Build Threads    : $(nproc --all)"
echo "--------------------------------------------------"

# Initialize/update git submodules if inside a git repository
if [ -d "${KERNEL_ROOT}/.git" ]; then
    echo -e "${BLUE}[INFO]: Updating git submodules...${NC}"
    git -C "${KERNEL_ROOT}" submodule update --init --recursive &>/dev/null || true
fi

# Install requirements if not previously verified
REQ_FILE="/tmp/.cybertron_kernel_requirements"
if [ ! -f "${REQ_FILE}" ]; then
    echo -e "${BLUE}[INFO]: Checking build requirements...${NC}"
    PKGS=(
        git device-tree-compiler lz4 xz-utils zlib1g-dev gcc g++ python3
        python-is-python3 p7zip-full build-essential zip curl libc6-dev
        libncurses-dev make bc grep tofrodos libxml2-utils xsltproc
        cpio kmod openssl libelf-dev libssl-dev zstd
    )
    if command -v apt-get &>/dev/null && sudo -n true 2>/dev/null; then
        sudo apt-get update -qq && sudo apt-get install -y --no-install-recommends "${PKGS[@]}" || true
    fi
    touch "${REQ_FILE}" 2>/dev/null || true
fi

# Create needed directories
mkdir -p "${OUT_DIR}" "${BUILD_DIR}"
mkdir -p "${HOME}/toolchains" 2>/dev/null || true

# Dynamically locate Toolchains Root
if [ -d "${PARENT_DIR}/toolchains/neutron-clang" ]; then
    TOOLCHAINS_ROOT="${PARENT_DIR}/toolchains"
else
    TOOLCHAINS_ROOT="${TOOLCHAIN_DIR:-${HOME}/toolchains}"
fi

# Setup Neutron-Clang Toolchain
NEUTRON_DIR="${NEUTRON_DIR:-${TOOLCHAINS_ROOT}/neutron-clang}"
if [ ! -d "${NEUTRON_DIR}" ] || [ ! -f "${NEUTRON_DIR}/bin/clang" ] || ! "${NEUTRON_DIR}/bin/clang" --version &>/dev/null; then
    echo -e "${YELLOW}[INFO]: Initializing Neutron-Clang Toolchain via antman...${NC}"
    rm -rf "${NEUTRON_DIR}"
    mkdir -p "${NEUTRON_DIR}"
    cd "${NEUTRON_DIR}"
    curl -sSLo antman "https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman"
    chmod +x antman
    ./antman -S --noconfirm
    ./antman --patch=glibc
    cd "${KERNEL_ROOT}"
elif [ "${UPDATE_TC}" -eq 1 ]; then
    echo -e "${YELLOW}[INFO]: Updating Neutron-Clang Toolchain...${NC}"
    cd "${NEUTRON_DIR}"
    ./antman -u --noconfirm || true
    ./antman --patch=glibc || true
    cd "${KERNEL_ROOT}"
fi

# Setup ARM GNU Toolchain (for 64-bit cross-compile binutils/libgcc)
GCC_DIR="${GCC_DIR:-${TOOLCHAINS_ROOT}/gcc/arm-gnu-toolchain-14.2.rel1-x86_64-aarch64-none-linux-gnu}"
if [ ! -d "${GCC_DIR}" ] || [ ! -f "${GCC_DIR}/bin/aarch64-none-linux-gnu-gcc" ] || ! "${GCC_DIR}/bin/aarch64-none-linux-gnu-gcc" --version &>/dev/null; then
    echo -e "${YELLOW}[INFO]: Downloading ARM GNU Toolchain 14.2.rel1...${NC}"
    rm -rf "${GCC_DIR}"
    mkdir -p "${TOOLCHAINS_ROOT}/gcc"
    cd "${TOOLCHAINS_ROOT}/gcc"
    curl -LO "https://developer.arm.com/-/media/Files/downloads/gnu/14.2.rel1/binrel/arm-gnu-toolchain-14.2.rel1-x86_64-aarch64-none-linux-gnu.tar.xz"
    tar -xf arm-gnu-toolchain-14.2.rel1-x86_64-aarch64-none-linux-gnu.tar.xz
    rm -f arm-gnu-toolchain-14.2.rel1-x86_64-aarch64-none-linux-gnu.tar.xz
    cd "${KERNEL_ROOT}"
fi

# Export Toolchain Environment Variables
export PATH="${TOOLCHAINS_ROOT}/bin:${NEUTRON_DIR}/bin:${GCC_DIR}/bin:${PATH}"
export NEUTRON_PATH="${NEUTRON_DIR}/bin"
export LD_LIBRARY_PATH="${NEUTRON_DIR}/lib:${LD_LIBRARY_PATH}"

BUILD_CROSS_COMPILE="${GCC_DIR}/bin/aarch64-none-linux-gnu-"

# Compiler & Ccache Configuration
if command -v ccache &>/dev/null; then
    CCACHE_BIN_DIR="${OUT_DIR}/.ccache_bin"
    mkdir -p "${CCACHE_BIN_DIR}"
    cat << 'EOF' > "${CCACHE_BIN_DIR}/clang"
#!/usr/bin/env bash
exec ccache "${NEUTRON_PATH}/clang" "$@"
EOF
    cat << 'EOF' > "${CCACHE_BIN_DIR}/clang++"
#!/usr/bin/env bash
exec ccache "${NEUTRON_PATH}/clang++" "$@"
EOF
    chmod +x "${CCACHE_BIN_DIR}/clang" "${CCACHE_BIN_DIR}/clang++"

    if [ -w "${HOME}/.ccache" ] || ([ ! -e "${HOME}/.ccache" ] && [ -w "${HOME}" ]); then
        export CCACHE_DIR="${HOME}/.ccache"
    else
        export CCACHE_DIR="/tmp/.ccache"
    fi
    export CCACHE_MAXSIZE="4G"
    export CCACHE_COMPRESS=1
    export CCACHE_COMPRESSLEVEL=6
    export CCACHE_SLOPPINESS="file_macro,time_macros,include_file_mtime"
    export USE_CCACHE=1

    CC_BIN="${CCACHE_BIN_DIR}/clang"
    HOSTCC_BIN="${CCACHE_BIN_DIR}/clang"
    HOSTCXX_BIN="${CCACHE_BIN_DIR}/clang++"
    echo -e "${BLUE}[INFO]: Accelerated builds enabled via ccache (${CC_BIN}).${NC}"
else
    CC_BIN="${NEUTRON_PATH}/clang"
    HOSTCC_BIN="${NEUTRON_PATH}/clang"
    HOSTCXX_BIN="${NEUTRON_PATH}/clang++"
fi

# Assemble Build Options
BUILD_OPTIONS=(
    -C "${KERNEL_ROOT}"
    O="${OUT_DIR}"
    -j"$(nproc --all)"
    ARCH=arm64
    CROSS_COMPILE="${BUILD_CROSS_COMPILE}"
    CC="${CC_BIN}"
    CLANG_TRIPLE=aarch64-linux-gnu-
    LLVM=1
    LLVM_IAS=1
    AR="${NEUTRON_PATH}/llvm-ar"
    NM="${NEUTRON_PATH}/llvm-nm"
    LD="${NEUTRON_PATH}/ld.lld"
    STRIP="${NEUTRON_PATH}/llvm-strip"
    OBJCOPY="${NEUTRON_PATH}/llvm-objcopy"
    OBJDUMP="${NEUTRON_PATH}/llvm-objdump"
    READELF="${NEUTRON_PATH}/llvm-readelf"
    HOSTCC="${HOSTCC_BIN}"
    HOSTCXX="${HOSTCXX_BIN}"
    DTC_EXT="$(command -v dtc || echo /usr/bin/dtc)"
)

# Optional Clean Build
if [ "${CLEAN_BUILD}" -eq 1 ]; then
    echo -e "${YELLOW}[INFO]: Cleaning output directory...${NC}"
    rm -rf "${OUT_DIR}"/*
fi

# Setup KernelSU if enabled
if [ "${ENABLE_KSU}" -eq 1 ]; then
    echo -e "${CYAN}${BOLD}[INFO]: Setting up KernelSU (manipvlator/KernelSU)...${NC}"
    if [ ! -d "${KERNEL_ROOT}/KernelSU" ]; then
        echo -e "${YELLOW}[INFO]: Cloning KernelSU from https://github.com/manipvlator/KernelSU.git...${NC}"
        git clone --depth=1 https://github.com/manipvlator/KernelSU.git "${KERNEL_ROOT}/KernelSU"
    fi

    if [ ! -L "${KERNEL_ROOT}/drivers/kernelsu" ] && [ ! -d "${KERNEL_ROOT}/drivers/kernelsu" ]; then
        echo -e "${BLUE}[INFO]: Creating symlink drivers/kernelsu -> ../KernelSU/kernel...${NC}"
        ln -sf ../KernelSU/kernel "${KERNEL_ROOT}/drivers/kernelsu"
    fi

    if ! grep -q "kernelsu" "${KERNEL_ROOT}/drivers/Makefile"; then
        echo -e "${BLUE}[INFO]: Adding kernelsu driver entry to drivers/Makefile...${NC}"
        printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> "${KERNEL_ROOT}/drivers/Makefile"
    fi

    if ! grep -q "drivers/kernelsu/Kconfig" "${KERNEL_ROOT}/drivers/Kconfig"; then
        echo -e "${BLUE}[INFO]: Sourcing drivers/kernelsu/Kconfig in drivers/Kconfig...${NC}"
        sed -i '/endmenu/i\source "drivers/kernelsu/Kconfig"' "${KERNEL_ROOT}/drivers/Kconfig"
    fi
else
    # Non-KSU build: ensure missing kernelsu does not cause Kconfig parse error
    if [ ! -e "${KERNEL_ROOT}/drivers/kernelsu" ]; then
        if grep -q "kernelsu" "${KERNEL_ROOT}/drivers/Makefile"; then
            sed -i '/kernelsu/d' "${KERNEL_ROOT}/drivers/Makefile"
        fi
        if grep -q "drivers/kernelsu/Kconfig" "${KERNEL_ROOT}/drivers/Kconfig"; then
            sed -i '/drivers\/kernelsu\/Kconfig/d' "${KERNEL_ROOT}/drivers/Kconfig"
        fi
    fi
fi

# Track generated packages
SUCCESSFUL_BUILDS=()

# Main Build Loop for Target Devices
for CURRENT_DEVICE in "${TARGET_DEVICES[@]}"; do
    echo -e "\n${BLUE}${BOLD}=================================================="
    echo "  Starting Build for Target: ${CURRENT_DEVICE}"
    echo "==================================================${NC}\n"

    # Set Device-Specific Variables
    case "${CURRENT_DEVICE}" in
        liber)
            DEFCONFIG="vendor/liber_defconfig"
            DEVICE_NAME="Motorola One Fusion+ (liber)"
            ZIP_NAME_DEFAULT="anykernel"
            DTB_PATTERN="sdmmagpie-liber-base.dtb"
            DEVICE_NAMES=("liber" "liber" "" "" "")
            ;;
        hanoip)
            DEFCONFIG="vendor/hanoip_defconfig"
            DEVICE_NAME="Motorola Moto G40/G60 (hanoip)"
            ZIP_NAME_DEFAULT="anykernel-hanoip"
            DTB_PATTERN="sdmmagpie-hanoi-base.dtb"
            DEVICE_NAMES=("hanoip" "hanoi" "" "" "")
            ;;
        odessa)
            DEFCONFIG="vendor/odessa_defconfig"
            DEVICE_NAME="Motorola Moto G9 Plus (odessa)"
            ZIP_NAME_DEFAULT="anykernel-odessa"
            DTB_PATTERN="sdmmagpie-odessa-base.dtb"
            DEVICE_NAMES=("odessa" "odessapr" "moto g(9) plus" "moto g 9 plus" "")
            ;;
        *)
            echo -e "${RED}[ERROR]: Unsupported target device '${CURRENT_DEVICE}'! Skipping.${NC}"
            continue
            ;;
    esac

    # Dynamically resolve AnyKernel Directory
    TARGET_ZIP_DIR=""
    if [ -n "${ZIP_DIR:-}" ]; then
        if [ -d "${ZIP_DIR}_${CURRENT_DEVICE}" ]; then
            TARGET_ZIP_DIR="${ZIP_DIR}_${CURRENT_DEVICE}"
        elif [ -d "${ZIP_DIR}" ]; then
            TARGET_ZIP_DIR="${ZIP_DIR}"
        fi
    fi

    if [ -z "${TARGET_ZIP_DIR}" ]; then
        if [ -d "${PARENT_DIR}/${ZIP_NAME_DEFAULT}" ]; then
            TARGET_ZIP_DIR="${PARENT_DIR}/${ZIP_NAME_DEFAULT}"
        elif [ -d "${KERNEL_ROOT}/${ZIP_NAME_DEFAULT}" ]; then
            TARGET_ZIP_DIR="${KERNEL_ROOT}/${ZIP_NAME_DEFAULT}"
        elif [ -d "${PARENT_DIR}/anykernel" ]; then
            TARGET_ZIP_DIR="${PARENT_DIR}/anykernel"
        elif [ -d "${HOME}/${ZIP_NAME_DEFAULT}" ]; then
            TARGET_ZIP_DIR="${HOME}/${ZIP_NAME_DEFAULT}"
        else
            TARGET_ZIP_DIR="${PARENT_DIR}/${ZIP_NAME_DEFAULT}"
        fi
    fi

    # Auto-clone AnyKernel3 if missing
    if [ ! -d "${TARGET_ZIP_DIR}" ]; then
        echo -e "${YELLOW}[INFO]: AnyKernel directory not found at ${TARGET_ZIP_DIR}. Cloning AnyKernel3...${NC}"
        git clone --depth=1 -b "${CURRENT_DEVICE}" https://github.com/DhineshCool/AnyKernel3.git "${TARGET_ZIP_DIR}" 2>/dev/null || \
        git clone --depth=1 -b liber https://github.com/DhineshCool/AnyKernel3.git "${TARGET_ZIP_DIR}" 2>/dev/null || \
        git clone --depth=1 https://github.com/DhineshCool/AnyKernel3.git "${TARGET_ZIP_DIR}" 2>/dev/null || \
        git clone https://github.com/osm0sis/AnyKernel3.git "${TARGET_ZIP_DIR}"
    fi

    # Step 1: Clean stale config data and load Defconfig
    echo -e "${BLUE}[INFO]: Loading ${DEFCONFIG} for ${DEVICE_NAME}...${NC}"
    rm -f "${OUT_DIR}/kernel/config_data"* "${OUT_DIR}/.config"*
    make "${BUILD_OPTIONS[@]}" "${DEFCONFIG}"

    # Apply KernelSU configuration
    if [ "${ENABLE_KSU}" -eq 1 ]; then
        echo -e "${BLUE}[INFO]: Enabling CONFIG_KSU in kernel configuration...${NC}"
        "${KERNEL_ROOT}/scripts/config" --file "${OUT_DIR}/.config" --enable CONFIG_KSU
        make "${BUILD_OPTIONS[@]}" olddefconfig
    fi

    # Step 2: Interactive Menuconfig if requested
    if [ "${MENUCONFIG}" -eq 1 ]; then
        echo -e "${CYAN}[INFO]: Launching menuconfig...${NC}"
        make "${BUILD_OPTIONS[@]}" menuconfig
        echo -e "${GREEN}[INFO]: Menuconfig finished. Exiting.${NC}"
        exit 0
    fi

    # Step 3: Compile Kernel Image, DTBs, and Modules
    START_TIME=$(date +%s)
    echo -e "\n${BLUE}[INFO]: Building Kernel Image, Device Tree Blobs (DTBs), and Modules for ${CURRENT_DEVICE}...${NC}\n"

    make "${BUILD_OPTIONS[@]}" Image.gz dtbs modules

    # Verify Image generation
    KERNEL_IMG="${OUT_DIR}/arch/arm64/boot/Image.gz"
    if [ ! -f "${KERNEL_IMG}" ]; then
        if [ -f "${OUT_DIR}/arch/arm64/boot/Image" ]; then
            echo -e "${YELLOW}[INFO]: Compressing raw Image to Image.gz...${NC}"
            gzip -k -9 "${OUT_DIR}/arch/arm64/boot/Image"
        else
            echo -e "\n${RED}[ERROR]: Kernel compilation failed for ${CURRENT_DEVICE}! No Image found in ${OUT_DIR}/arch/arm64/boot/${NC}"
            exit 1
        fi
    fi

    END_TIME=$(date +%s)
    BUILD_DURATION=$((END_TIME - START_TIME))
    MINUTES=$((BUILD_DURATION / 60))
    SECONDS=$((BUILD_DURATION % 60))

    echo -e "\n${GREEN}${BOLD}[SUCCESS]: Kernel compilation for ${CURRENT_DEVICE} completed in ${MINUTES}m ${SECONDS}s!${NC}\n"

    # Step 4: Copy Artifacts to Build Directory
    cp -f "${KERNEL_IMG}" "${BUILD_DIR}/Image.gz"
    if [ -f "${OUT_DIR}/arch/arm64/boot/Image" ]; then
        cp -f "${OUT_DIR}/arch/arm64/boot/Image" "${BUILD_DIR}/Image"
        cp -f "${OUT_DIR}/arch/arm64/boot/Image" "${BUILD_DIR}/Image-${CURRENT_DEVICE}"
    fi

    # Step 5: Packaging with AnyKernel3
    TIMESTAMP=$(date +"%Y%m%d-%H%M")
    if [ "${ENABLE_KSU}" -eq 1 ]; then
        ZIP_NAME="Cybertron-${CLEAN_VER}-${CURRENT_DEVICE}-KSU-${TIMESTAMP}.zip"
        ZIP_ALIAS="${CURRENT_DEVICE}-ksu.zip"
    else
        ZIP_NAME="Cybertron-${CLEAN_VER}-${CURRENT_DEVICE}-${TIMESTAMP}.zip"
        ZIP_ALIAS="${CURRENT_DEVICE}.zip"
    fi

    if [ -d "${TARGET_ZIP_DIR}" ]; then
        echo -e "${BLUE}[INFO]: Packaging AnyKernel3 flashable zip in ${TARGET_ZIP_DIR}...${NC}"
        cd "${TARGET_ZIP_DIR}"
        
        # Clean previous build artifacts in AnyKernel directory
        rm -f *.zip Image.gz dtb *.dtb Image
        rm -rf modules

        # Copy Kernel Image (prefer raw uncompressed Image for bootloader compatibility)
        if [ -f "${BUILD_DIR}/Image" ]; then
            cp -f "${BUILD_DIR}/Image" "${TARGET_ZIP_DIR}/Image"
        elif [ -f "${BUILD_DIR}/Image.gz" ]; then
            cp -f "${BUILD_DIR}/Image.gz" "${TARGET_ZIP_DIR}/Image.gz"
        fi

        # Concatenate or copy DTB matching device pattern
        DTB_DIR="${OUT_DIR}/arch/arm64/boot/dts/qcom"
        if [ -d "${DTB_DIR}" ]; then
            MATCHED_DTBS=$(find "${DTB_DIR}" -maxdepth 1 -name "${DTB_PATTERN}" 2>/dev/null || true)
            if [ -z "${MATCHED_DTBS}" ]; then
                MATCHED_DTBS=$(find "${DTB_DIR}" -maxdepth 1 -name "*${CURRENT_DEVICE}*.dtb" 2>/dev/null || true)
            fi

            if [ -n "${MATCHED_DTBS}" ]; then
                echo -e "${BLUE}[INFO]: Packaging DTB for ${CURRENT_DEVICE} (${MATCHED_DTBS})...${NC}"
                cat ${MATCHED_DTBS} > "${TARGET_ZIP_DIR}/dtb" 2>/dev/null || true
                cp -f "${TARGET_ZIP_DIR}/dtb" "${BUILD_DIR}/dtb" 2>/dev/null || true
                cp -f "${TARGET_ZIP_DIR}/dtb" "${BUILD_DIR}/dtb-${CURRENT_DEVICE}" 2>/dev/null || true
            else
                echo -e "${YELLOW}[WARN]: No DTB found matching '${DTB_PATTERN}' in ${DTB_DIR}!${NC}"
            fi
        fi

        # Collect and package built loadable kernel modules (.ko)
        MODULES=$(find "${OUT_DIR}" -name "*.ko" 2>/dev/null || true)
        if [ -n "${MODULES}" ]; then
            echo -e "${BLUE}[INFO]: Packaging built kernel modules into AnyKernel3...${NC}"
            MODULES_DIR="${TARGET_ZIP_DIR}/modules/vendor/lib/modules"
            mkdir -p "${MODULES_DIR}"
            for mod in ${MODULES}; do
                mod_base="$(basename "${mod}")"
                echo -e "  -> ${mod_base}"
                "${STRIP}" --strip-unneeded "${mod}" -o "${MODULES_DIR}/${mod_base}" 2>/dev/null || \
                    cp -f "${mod}" "${MODULES_DIR}/${mod_base}"
            done
            if [ -f "anykernel.sh" ]; then
                sed -i "s/do.modules=.*/do.modules=1/g" anykernel.sh
                sed -i "s/do.systemless=.*/do.systemless=0/g" anykernel.sh
            fi
        else
            if [ -f "anykernel.sh" ]; then
                sed -i "s/do.modules=.*/do.modules=0/g" anykernel.sh
            fi
        fi

        # Update version file if present
        if [ -f "version" ]; then
            if [ "${ENABLE_KSU}" -eq 1 ]; then
                sed -i "s/\"Cybertron[^\"]*\"/\"Cybertron-${CLEAN_VER}-KSU\"/g" version 2>/dev/null || true
            else
                sed -i "s/\"Cybertron[^\"]*\"/\"Cybertron-${CLEAN_VER}\"/g" version 2>/dev/null || true
            fi
            sed -i "s/For [a-zA-Z0-9_-]\+/For ${CURRENT_DEVICE}/g" version 2>/dev/null || true
        fi

        # Configure anykernel.sh dynamically
        if [ -f "anykernel.sh" ]; then
            for i in 1 2 3 4 5; do
                idx=$((i - 1))
                val="${DEVICE_NAMES[idx]:-}"
                sed -i "s/device.name${i}=.*/device.name${i}=${val}/g" anykernel.sh
            done

            # Ensure slot and partition settings are auto-detected for Motorola A/B architecture
            sed -i "s/^IS_SLOT_DEVICE=.*/IS_SLOT_DEVICE=auto;/g" anykernel.sh || true
            sed -i "s/^RAMDISK_COMPRESSION=.*/RAMDISK_COMPRESSION=auto;/g" anykernel.sh || true
            sed -i "s/^PATCH_VBMETA_FLAG=.*/PATCH_VBMETA_FLAG=auto;/g" anykernel.sh || true

            VER_NUM="${CLEAN_VER//[!0-9]/}"
            [ -z "${VER_NUM}" ] && VER_NUM="1"

            if [ "${ENABLE_KSU}" -eq 1 ]; then
                sed -i "s/kernel\.string=.*/kernel.string=Cybertron Kernel ${CLEAN_VER} (KernelSU) by cool585/g" anykernel.sh
                sed -i "s/^version=.*/version=${CLEAN_VER}-KSU/g" anykernel.sh
            else
                sed -i "s/kernel\.string=.*/kernel.string=Cybertron Kernel ${CLEAN_VER} by cool585/g" anykernel.sh
                sed -i "s/^version=.*/version=${CLEAN_VER}/g" anykernel.sh
            fi
            sed -i "s/^versionCode=.*/versionCode=${VER_NUM}/g" anykernel.sh
        fi

        # Create flashable zip package
        zip -r9 "${ZIP_NAME}" ./* -x .git* README.md ./*placeholder &>/dev/null

        # Create copy aliases
        cp -f "${ZIP_NAME}" "${BUILD_DIR}/${ZIP_NAME}"
        cp -f "${ZIP_NAME}" "${TARGET_ZIP_DIR}/${ZIP_ALIAS}"
        cp -f "${ZIP_NAME}" "${BUILD_DIR}/${ZIP_ALIAS}"
        cp -f "${ZIP_NAME}" "${TARGET_ZIP_DIR}/${CURRENT_DEVICE}.zip"
        cp -f "${ZIP_NAME}" "${BUILD_DIR}/${CURRENT_DEVICE}.zip"

        ZIP_SIZE=$(du -h "${BUILD_DIR}/${ZIP_NAME}" | cut -f1)

        echo -e "\n${GREEN}${BOLD}=================================================="
        echo "            FLASHABLE ZIP GENERATED!             "
        echo "==================================================${NC}"
        echo -e " Device     : ${GREEN}${BOLD}${DEVICE_NAME}${NC}"
        echo -e " File       : ${CYAN}${BOLD}${ZIP_NAME}${NC} (${ZIP_SIZE})"
        echo -e " Location   : ${GREEN}${BUILD_DIR}/${ZIP_NAME}${NC}"
        echo -e " Alias      : ${GREEN}${BUILD_DIR}/${CURRENT_DEVICE}.zip${NC}"
        echo -e " Total Time : ${BOLD}${MINUTES}m ${SECONDS}s${NC}"
        echo "=================================================="

        SUCCESSFUL_BUILDS+=("${CURRENT_DEVICE}: ${ZIP_NAME} (${ZIP_SIZE}) in ${MINUTES}m ${SECONDS}s")
    else
        echo -e "${YELLOW}[WARN]: ZIP_DIR (${TARGET_ZIP_DIR}) not found. Flashable zip skipped for ${CURRENT_DEVICE}.${NC}"
        echo -e "Kernel Image is available at: ${GREEN}${BUILD_DIR}/Image.gz${NC}"
    fi

    cd "${KERNEL_ROOT}"
done

# Print final multi-device summary if more than one device was built
if [ "${#SUCCESSFUL_BUILDS[@]}" -gt 1 ]; then
    echo -e "\n${CYAN}${BOLD}=================================================="
    echo "            ALL BUILDS COMPLETED!                "
    echo "==================================================${NC}"
    for summary in "${SUCCESSFUL_BUILDS[@]}"; do
        echo -e "  * ${GREEN}${summary}${NC}"
    done
    echo -e "${CYAN}==================================================${NC}\n"
fi

# Display Ccache Performance Statistics if enabled
if command -v ccache &>/dev/null && [ -d "${CCACHE_DIR:-${HOME}/.ccache}" ]; then
    echo -e "${CYAN}${BOLD}=== Ccache Performance Stats ===${NC}"
    ccache -s || true
    echo "================================"
fi

exit 0
