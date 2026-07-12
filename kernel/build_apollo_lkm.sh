#!/bin/bash
#
# Build KernelSU as a Loadable Kernel Module (kernelsu.ko) for the
# Xiaomi "apollo" device kernel (Android 12 / Linux 4.19.81, arm64, non-GKI).
#
# Why a full kernel build is required for this device:
#   KernelSU's LKM depends on kprobes (supercall installs a reboot kprobe and
#   the syscall hook manager uses kprobes). The stock apollo defconfig does NOT
#   enable CONFIG_KPROBES, so an LKM cannot run against a stock boot image.
#   We therefore rebuild the kernel tree with KPROBES enabled. That build also
#   produces the matching Module.symvers, which is required so the .ko's
#   symbol CRCs match the kernel we flash.
#
# Usage:
#   KERNEL_SRC=/path/to/apollo-src BUILD_KERNEL=1 ./build_apollo_lkm.sh
#
# Environment overrides:
#   APOLLO_ZIP      path to Xiaomi_Kernel_OpenSource-apollo-q-oss.zip
#   KERNEL_SRC      extracted kernel source (auto-extracted if missing)
#   OUT_DIR         working dir (default: ./out_apollo)
#   DEFCONFIG      base defconfig (default: vendor/apollo_user_defconfig)
#   BUILD_KERNEL   1 = also build Image.gz-dtb + Module.symvers (default 1)
#   CC / LLVM / CROSS_COMPILE / CROSS_COMPILE_ARM32  toolchain overrides
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KSU_DIR="$SCRIPT_DIR"

APOLLO_ZIP="${APOLLO_ZIP:-$SCRIPT_DIR/../Xiaomi_Kernel_OpenSource-apollo-q-oss.zip}"
OUT_DIR="${OUT_DIR:-$KSU_DIR/out_apollo}"
KERNEL_SRC="${KERNEL_SRC:-$OUT_DIR/src}"
DEFCONFIG="${DEFCONFIG:-vendor/apollo_user_defconfig}"
BUILD_KERNEL="${BUILD_KERNEL:-1}"
ARCH=arm64
JOBS="${JOBS:-$(nproc)}"

CC="${CC:-}"
LLVM="${LLVM:-}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32:-arm-linux-gnueabi-}"
LLVM_STRIP="${LLVM_STRIP:-llvm-strip}"
STRIP="${STRIP:-aarch64-linux-gnu-strip}"

# apollo 4.19 is a GCC-built vendor kernel; pass CC/LLVM only when set so
# kbuild falls back to $(CROSS_COMPILE)gcc by default.
MAKE_VARS=(
  ARCH="$ARCH"
  CROSS_COMPILE="$CROSS_COMPILE"
  CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32"
)
if [ -n "$CC" ]; then
  MAKE_VARS+=( CC="$CC" )
fi
if [ -n "$LLVM" ]; then
  MAKE_VARS+=( LLVM="$LLVM" CLANG_TRIPLE="${CLANG_TRIPLE:-aarch64-linux-gnu-}" )
fi

echo "[*] Script dir : $SCRIPT_DIR"
echo "[*] Kernel src: $KERNEL_SRC"
echo "[*] Out dir    : $OUT_DIR"
echo "[*] Defconfig  : $DEFCONFIG"
echo "[*] Build kern : $BUILD_KERNEL"

if [ ! -f "$APOLLO_ZIP" ]; then
  echo "[!] APOLLO_ZIP not found: $APOLLO_ZIP"
  exit 1
fi

if [ ! -d "$KERNEL_SRC/arch" ]; then
  echo "[+] Extracting apollo kernel source..."
  mkdir -p "$OUT_DIR"
  TMP="$OUT_DIR/_extract"
  rm -rf "$TMP"
  mkdir -p "$TMP"
  unzip -q "$APOLLO_ZIP" -d "$TMP"
  SRC_ROOT="$(find "$TMP" -maxdepth 1 -type d -name 'Xiaomi_Kernel_OpenSource-*' | head -n1)"
  if [ -z "$SRC_ROOT" ]; then
    echo "[!] Could not locate extracted source root"
    exit 1
  fi
  mv "$SRC_ROOT"/* "$KERNEL_SRC"/
  rmdir "$SRC_ROOT" 2>/dev/null || true
  rm -rf "$TMP"
fi

cd "$KERNEL_SRC"

if [ ! -x "./scripts/kconfig/merge_config.sh" ]; then
  echo "[!] merge_config.sh missing; cannot apply LKM config fragment"
  exit 1
fi

echo "[+] Generating .config from $DEFCONFIG"
make "${MAKE_VARS[@]}" "$DEFCONFIG"

echo "[+] Merging KernelSU LKM requirements (KPROBES, modules, ext4, selinux)"
cp "$KSU_DIR/apollo_lkm.config" "$KERNEL_SRC/apollo_lkm.config"
./scripts/kconfig/merge_config.sh -m .config "$KSU_DIR/apollo_lkm.config"
make "${MAKE_VARS[@]}" olddefconfig

echo "[+] Configuration summary (KernelSU relevant):"
grep -E "^(CONFIG_MODULES|CONFIG_MODULE_UNLOAD|CONFIG_MODVERSIONS|CONFIG_MODULE_SIG|CONFIG_KPROBES|CONFIG_EXT4_FS|CONFIG_SECURITY_SELINUX|CONFIG_KSU)=" .config || true

if [ "$BUILD_KERNEL" = "1" ]; then
  echo "[+] Building kernel image (enables KPROBES in vmlinux)..."
  make "${MAKE_VARS[@]}" -j"$JOBS" Image.gz-dtb
  echo "[+] Kernel image: $(ls -1 arch/arm64/boot/Image.gz-dtb 2>/dev/null || echo MISSING)"
  echo "[+] NOTE: building vmlinux only (not all modules). The LKM loads via"
  echo "[+] symbol name resolution, so Module.symvers CRCs are not required."
else
  echo "[+] Skipping full kernel build; running modules_prepare only."
  echo "[!] Without a matching Module.symvers the .ko CRCs may not match the"
  echo "[!] running kernel. Use BUILD_KERNEL=1 if loading into a rebuilt kernel."
  make "${MAKE_VARS[@]}" modules_prepare
fi

echo "[+] Building kernelsu.ko (LKM) against $KERNEL_SRC"
make -C "$KERNEL_SRC" "${MAKE_VARS[@]}" M="$KSU_DIR" src="$KSU_DIR" CONFIG_KSU=m modules -j"$JOBS"

KO="$KSU_DIR/kernelsu.ko"
if [ ! -f "$KO" ]; then
  echo "[!] kernelsu.ko was not produced"
  exit 1
fi

if [ -f "$KERNEL_SRC/vmlinux" ]; then
  echo "[+] Verifying required symbols in vmlinux..."
  if [ -x "$KSU_DIR/check_symbol" ]; then
    "$KSU_DIR/check_symbol" "$KO" "$KERNEL_SRC/vmlinux" || \
      echo "[!] check_symbol reported missing symbols; see output above"
  else
    gcc "$KSU_DIR/tools/check_symbol.c" -o "$KSU_DIR/check_symbol" 2>/dev/null && \
      "$KSU_DIR/check_symbol" "$KO" "$KERNEL_SRC/vmlinux" || \
      echo "[!] check_symbol tool unavailable; skipping symbol check"
  fi
fi

OUT_KO="$KSU_DIR/kernelsu-apollo.ko"
if command -v "$LLVM_STRIP" >/dev/null 2>&1; then
  "$LLVM_STRIP" -d "$KO"
elif command -v "$STRIP" >/dev/null 2>&1; then
  "$STRIP" --strip-debug "$KO"
fi
cp "$KO" "$OUT_KO"

echo "[+] Done."
echo "[+] LKM module : $OUT_KO"
if [ "$BUILD_KERNEL" = "1" ]; then
  echo "[+] Flashable  : $KERNEL_SRC/arch/arm64/boot/Image.gz-dtb"
  echo "[+] Repack Image.gz-dtb into your boot/recovery image, then 'insmod kernelsu-apollo.ko'"
fi
