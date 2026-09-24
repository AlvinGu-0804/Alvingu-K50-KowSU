#!/usr/bin/env bash
# =============================================================
# K50 (rubens / MTK) GKI 内核 + KowSU 构建脚本
# 内核源: ztc1997/android_gki_kernel_5.10_common (android12-5.10-lts)
# Root  : KowSU (KOWX712/KernelSU)
# 产物  : AnyKernel3 可刷 zip + 裸 boot 内核镜像
# 用法  : ./build.sh            (全部步骤)
#         ./build.sh sync       (只同步源码)
#         ./build.sh ksu        (只做 KowSU 集成)
#         ./build.sh kernel     (只编译内核)
# =============================================================
set -euo pipefail

# ---------------- 可配置变量 ----------------
KMI_BRANCH="${KMI_BRANCH:-common-android12-5.10}"
KSU_REF="${KSU_REF:-main}"                                   # KowSU 分支/tag
ZTC_REPO="${ZTC_REPO:-https://github.com/ztc1997/android_gki_kernel_5.10_common}"
ZTC_BRANCH="${ZTC_BRANCH:-}"                                 # 留空=默认分支
KERNEL_COMPRESS="${KERNEL_COMPRESS:-gz}"                     # gz | lz4 | none
ENABLE_KSU="${ENABLE_KSU:-y}"                                # y=built-in, m=LKM模块
JOBS="${JOBS:-$(nproc)}"

WORKDIR="$(pwd)"
TREE="$WORKDIR/gki"
COMMON="$TREE/common"
OUTDIR="$WORKDIR/out"

log()  { echo -e "\033[1;32m[+] $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
err()  { echo -e "\033[1;31m[-] $*\033[0m"; exit 1; }

# ---------------- 1. 同步 GKI manifest 树 ----------------
do_sync() {
  mkdir -p "$TREE" && cd "$TREE"

  if [ ! -d .repo ]; then
    log "repo init -b $KMI_BRANCH"
    repo init -u https://android.googlesource.com/kernel/manifest \
         -b "$KMI_BRANCH" --depth=1 2>/dev/null \
      || repo init -u https://android.googlesource.com/kernel/manifest \
         -b "deprecated/$KMI_BRANCH" --depth=1 \
      || err "repo init 失败，检查分支名与网络"
  fi

  log "repo sync (首次较慢，约 10~20 分钟)"
  repo sync -j"$JOBS" -c --no-tags --no-clone-bundle --prune 2>&1 | tail -5
  log "源码同步完成"
}

# ---------------- 2. 用 ztc1997 源码替换 common ----------------
do_replace_common() {
  cd "$TREE"
  [ -d common ] || err "未找到 common/ 目录，请先执行 sync"

  # 备份 GKI 官方构建配置（ztc 树里可能没有这些文件）
  mkdir -p "$WORKDIR/.gki_cfg_backup"
  cp -f common/build.config* "$WORKDIR/.gki_cfg_backup/" 2>/dev/null || true
  cp -rf common/android      "$WORKDIR/.gki_cfg_backup/" 2>/dev/null || true

  log "拉取 ztc1997 内核源码"
  rm -rf "$COMMON"
  if [ -n "$ZTC_BRANCH" ]; then
    git clone --depth=1 -b "$ZTC_BRANCH" "$ZTC_REPO" "$COMMON"
  else
    git clone --depth=1 "$ZTC_REPO" "$COMMON"
  fi

  # 缺什么补什么：把官方 GKI 构建配置拷回去
  cp -f "$WORKDIR"/.gki_cfg_backup/build.config* "$COMMON/" 2>/dev/null || true
  [ -d "$COMMON/android" ] || cp -rf "$WORKDIR/.gki_cfg_backup/android" "$COMMON/" 2>/dev/null || true

  log "内核源码就绪: $(cd "$COMMON" && git log -1 --format='%h %s' 2>/dev/null || echo unknown)"
}

# ---------------- 3. 集成 KowSU ----------------
do_ksu() {
  cd "$COMMON"

  # --- 3.1 清理可能已内置的官方 KernelSU（ZTC 源码常见） ---
  if [ -e drivers/kernelsu ] && [ ! -L drivers/kernelsu ]; then
    warn "检测到内置 KernelSU 目录，清理以避免冲突"
    rm -rf drivers/kernelsu
  fi
  sed -i '/kernelsu/d' drivers/Makefile
  sed -i '/kernelsu\/Kconfig/d' drivers/Kconfig

  # --- 3.2 跑 KowSU setup.sh ---
  log "集成 KowSU ($KSU_REF)"
  curl -LSs "https://raw.githubusercontent.com/KOWX712/KernelSU/main/kernel/setup.sh" | bash -s "$KSU_REF"

  [ -e drivers/kernelsu ] || err "KowSU 集成失败，未生成 drivers/kernelsu"
  log "已软链接 $(readlink drivers/kernelsu)"

  # --- 3.3 defconfig ---
  log "写入 CONFIG_KSU 配置"
  local DEFCONFIG="$COMMON/arch/arm64/configs/gki_defconfig"
  [ -f "$DEFCONFIG" ] || DEFCONFIG="$(ls "$COMMON"/arch/arm64/configs/*defconfig 2>/dev/null | head -1)"
  [ -f "$DEFCONFIG" ] || err "找不到 defconfig"

  grep -q "CONFIG_KSU=" "$DEFCONFIG" || cat >> "$DEFCONFIG" <<EOF

# KernelSU (KowSU)
CONFIG_KSU=$ENABLE_KSU
CONFIG_KPROBES=y
CONFIG_HAVE_KPROBES=y
CONFIG_KPROBE_EVENTS=y
CONFIG_KALLSYMS=y
CONFIG_KALLSYMS_ALL=y
EOF
  log "已写入 $DEFCONFIG"

  # --- 3.4 版本号兜底（防止回落 16 导致管理器报版本过低） ---
  if [ -f drivers/kernelsu/Makefile ]; then
    grep -q "KSU_VERSION" drivers/kernelsu/Makefile \
      || echo 'ccflags-y += -DKSU_VERSION=30000' >> drivers/kernelsu/Makefile
  fi
}

# ---------------- 4. 绕过 GKI 构建校验 ----------------
do_patch_build() {
  cd "$TREE"

  # check_defconfig: 改了 gki_defconfig 会触发校验失败
  if grep -qE '^[[:space:]]*check_defconfig[[:space:]]*$' build/build.sh; then
    log "禁用 check_defconfig"
    sed -i -E 's/^([[:space:]]*)check_defconfig[[:space:]]*$/\1: # check_defconfig disabled/' build/build.sh
  fi

  # 部分 Android 14 内核需移除受保护导出表，否则厂商模块过不了 modpost
  if [ -n "${REMOVE_ABI_EXPORTS:-}" ]; then
    log "移除 abi_gki_protected_exports"
    rm -f "$COMMON"/android/abi_gki_protected_exports_* 2>/dev/null || true
  fi
}

# ---------------- 5. 编译 ----------------
do_kernel() {
  cd "$TREE"
  log "开始编译 (LTO=thin, -j$JOBS)"
  LTO=thin BUILD_CONFIG=common/build.config.gki.aarch64 build/build.sh 2>&1 | tail -40

  mkdir -p "$OUTDIR"
  local IMG=""
  case "$KERNEL_COMPRESS" in
    gz)   IMG=$(find "$TREE/out" -name 'Image.gz'   -not -path '*-dtb*' | head -1) ;;
    lz4)  IMG=$(find "$TREE/out" -name 'Image.lz4'  -not -path '*-dtb*' | head -1) ;;
    *)    IMG=$(find "$TREE/out" -name 'Image'      -not -path '*.gz' -not -path '*.lz4' -not -path '*-dtb*' | head -1) ;;
  esac
  [ -n "$IMG" ] || IMG=$(find "$TREE/out" -name 'Image*' -type f | head -1)
  [ -n "$IMG" ] || err "未找到编译产物"

  cp -f "$IMG" "$OUTDIR/"
  log "内核产物: $OUTDIR/$(basename "$IMG")  ($(du -h "$IMG" | cut -f1))"

  # LKM 模式顺带产出 kernelsu.ko
  if [ "$ENABLE_KSU" = "m" ]; then
    find "$TREE/out" -name 'kernelsu.ko' -exec cp -f {} "$OUTDIR/" \; 2>/dev/null || true
  fi
}

# ---------------- 6. 打 AnyKernel3 包 ----------------
do_pack() {
  cd "$WORKDIR"
  local KIMG
  KIMG=$(find "$OUTDIR" -name 'Image*' -type f | head -1)
  [ -n "$KIMG" ] || err "out/ 下没有内核镜像，先编译"

  rm -rf "$WORKDIR/ak3" && git clone --depth=1 https://github.com/osm0sis/AnyKernel3 "$WORKDIR/ak3"
  cp -f "$WORKDIR/anykernel.sh" "$WORKDIR/ak3/anykernel.sh"
  cp -f "$KIMG" "$WORKDIR/ak3/"

  sed -i "s|kernel.string=.*|kernel.string=K50-KowSU GKI $(date +%Y%m%d)|" "$WORKDIR/ak3/anykernel.sh"

  cd "$WORKDIR/ak3"
  local ZIPNAME="K50-KowSU-android12-5.10-$(date +%Y%m%d-%H%M).zip"
  zip -r9 "$WORKDIR/out/$ZIPNAME" ./* -x .git .gitignore README.md
  log "刷机包: out/$ZIPNAME"
}

# ---------------- 入口 ----------------
case "${1:-all}" in
  sync)    do_sync ;;
  replace) do_replace_common ;;
  ksu)     do_ksu ;;
  patch)   do_patch_build ;;
  kernel)  do_kernel ;;
  pack)    do_pack ;;
  all)
    do_sync
    do_replace_common
    do_ksu
    do_patch_build
    do_kernel
    do_pack
    log "全部完成，产物在 out/"
    ;;
  *) echo "用法: $0 [all|sync|replace|ksu|patch|kernel|pack]" ; exit 1 ;;
esac
