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
set -uo pipefail

# 出错时打印「哪一行、哪条命令」失败，方便定位（替代裸的 set -e）
set -e
trap 'rc=$?; echo -e "\033[1;31m[-] 脚本失败: 第 ${LINENO} 行, exit=$rc, 命令: ${BASH_COMMAND}\033[0m"; exit $rc' ERR

# ---------------- 可配置变量 ----------------
# KSU_FLAVOR: 选择要集成的 KernelSU 分支。
#   kowsu    = KOWX712/KernelSU      (KowSU,    管理器 com.kowx712.supermanager)
#   apkesu   = fixz232/ApkeSU        (ApkeSU,   基于官方+SukiSU-Ultra)
#   sukisu   = SukiSU-Ultra/SukiSU-Ultra
#   next     = KernelSU-Next/KernelSU-Next
#   official = tiann/KernelSU
#   custom   = 完全用 KSU_REPO / KSU_REF 自定义
KSU_FLAVOR="${KSU_FLAVOR:-kowsu}"
KMI_BRANCH="${KMI_BRANCH:-common-android12-5.10}"
KSU_REF="${KSU_REF:-main}"                                   # 分支/tag
ZTC_REPO="${ZTC_REPO:-https://github.com/ztc1997/android_gki_kernel_5.10_common}"
ZTC_BRANCH="${ZTC_BRANCH:-}"                                 # 留空=默认分支
KERNEL_COMPRESS="${KERNEL_COMPRESS:-gz}"                     # gz | lz4 | none
ENABLE_KSU="${ENABLE_KSU:-y}"                                # y=built-in, m=LKM模块
# SUSFS（内核级隐藏）开关与分支。分支需与内核版本对应：
#   5.10  -> gki-android12-5.10     5.15 -> gki-android13-5.15
#   6.1   -> gki-android14-6.1      6.6  -> gki-android15-6.6
ENABLE_SUSFS="${ENABLE_SUSFS:-0}"                            # 1=启用
SUSFS_BRANCH="${SUSFS_BRANCH:-gki-android12-5.10}"
# 注意：susfs4ksu 的官方仓库在 GitLab，不是 GitHub。
# 用 GitHub 地址会被当成「私有库」而要求输入用户名密码，CI 无终端即崩溃
# （典型报错：fatal: could not read Username for 'https://github.com'）。
# 这里保留一系列候选源，逐个探测，任一可用即采用。
SUSFS_REPO="${SUSFS_REPO:-}"
SUSFS_FALLBACK_REPOS="
https://gitlab.com/simonpunk/susfs4ksu
https://github.com/co2kernel/co2kernel_susfs
https://github.com/2025DeveloperTeamInStaff/susfs4ksu
"
JOBS="${JOBS:-$(nproc)}"
KSU_REPO="${KSU_REPO:-}"                                     # custom 时用（显式设置可覆盖 flavor 映射）

WORKDIR="$(pwd)"
TREE="$WORKDIR/gki"
COMMON="$TREE/common"
OUTDIR="$WORKDIR/out"

log()  { echo -e "\033[1;32m[+] $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
err()  { echo -e "\033[1;31m[-] $*\033[0m"; exit 1; }

# flavor -> 仓库地址映射（放在函数定义之后，才能调用 err）
case "$KSU_FLAVOR" in
  kowsu)    : "${KSU_REPO:=https://github.com/KOWX712/KernelSU}" ;;
  apkesu)   : "${KSU_REPO:=https://github.com/fixz232/ApkeSU}" ;;
  sukisu)   : "${KSU_REPO:=https://github.com/SukiSU-Ultra/SukiSU-Ultra}" ;;
  next)     : "${KSU_REPO:=https://github.com/KernelSU-Next/KernelSU-Next}" ;;
  official) : "${KSU_REPO:=https://github.com/tiann/KernelSU}" ;;
  # none: 不集成任何 KernelSU，只出「纯净内核」。
  # 用途：YukiSU 等仅支持 LKM(CONFIG_KSU=m) 的分支，需要先用干净内核铺路，
  #       再由管理器加载官方预编译的 kernelsu.ko（内置 KSU 优先级更高，会屏蔽 LKM）。
  resukisu) : "${KSU_REPO:=https://github.com/ReSukiSU/ReSukiSU}" ;;
  none)     KSU_REPO="" ;;
  custom)   if [ -z "$KSU_REPO" ]; then err "flavor=custom 时必须设置 KSU_REPO"; fi ;;
  *)        err "未知 flavor: $KSU_FLAVOR（可选: kowsu/apkesu/sukisu/next/official/none/custom）" ;;
esac

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

  # 缺什么补什么：只补不覆盖（-n），保留 ztc 自己的构建配置
  for f in "$WORKDIR"/.gki_cfg_backup/build.config*; do
    [ -f "$f" ] || continue
    cp -n "$f" "$COMMON/" 2>/dev/null || true
  done
  [ -d "$COMMON/android" ] || cp -rf "$WORKDIR/.gki_cfg_backup/android" "$COMMON/" 2>/dev/null || true

  log "内核源码就绪: $(cd "$COMMON" && git log -1 --format='%h %s' 2>/dev/null || echo unknown)"
}

# ---------------- 3. 集成 KernelSU 分支 ----------------
do_ksu() {
  cd "$COMMON"
  local REPO_PATH="${KSU_REPO#https://github.com/}"
  REPO_PATH="${REPO_PATH%/}"
  log "flavor=$KSU_FLAVOR  仓库=${REPO_PATH:-<无>}  分支=$KSU_REF"

  # --- 3.1 清理可能已内置的官方 KernelSU（ZTC 源码常见） ---
  # 无论选哪个 flavor 都要先清场，否则内置 KSU 会屏蔽后续加载的 LKM。
  if [ -e drivers/kernelsu ] && [ ! -L drivers/kernelsu ]; then
    warn "检测到内置 KernelSU 目录，清理以避免冲突"
    rm -rf drivers/kernelsu
  fi
  sed -i '/kernelsu/d' drivers/Makefile
  sed -i '/kernelsu\/Kconfig/d' drivers/Kconfig

  # --- 3.1b 纯净内核模式：清完就收工，不走后面的集成 ---
  if [ "$KSU_FLAVOR" = "none" ]; then
    # 顺带把 defconfig 里可能残留的 KSU 配置去掉，确保内核真的「无 root」
    local DC
    for DC in "$COMMON"/arch/arm64/configs/*defconfig; do
      [ -f "$DC" ] || continue
      sed -i -E '/^CONFIG_KSU[=_]/d' "$DC"
    done
    log "纯净内核模式：已移除内置 KSU 与 CONFIG_KSU，不集成任何 KernelSU"
    log "  → 刷入后请自行用管理器加载 LKM（如 YukiSU 官方预编译 kernelsu.ko）"
    return 0
  fi

  # --- 3.2 定位 setup.sh（依次尝试 指定分支 -> main -> master） ---
  local SETUP_URL="" SETUP_BR="" cand tried="" url
  for cand in "$KSU_REF" main master; do
    [ -n "$cand" ] || continue
    case " $tried " in *" $cand "*) continue;; esac
    tried="$tried $cand"
    url="https://raw.githubusercontent.com/$REPO_PATH/$cand/kernel/setup.sh"
    log "尝试下载 setup.sh: $cand"
    if curl -fsSL --max-time 60 "$url" -o "$COMMON/.ksu_setup.sh" 2>/dev/null; then
      SETUP_URL="$url"; SETUP_BR="$cand"; break
    fi
  done

  [ -n "$SETUP_URL" ] || err "在 $REPO_PATH 的 [$ tried ] 分支下都没找到 kernel/setup.sh。
  请检查：
    1) 仓库地址是否正确（当前 KSU_REPO=$KSU_REPO）
    2) 分支名是否存在（当前 KSU_REF=$KSU_REF，可试 main / master）
    3) 该仓库是否包含 kernel/ 目录（有些分支只有管理器代码，没有内核侧）"

  log "已获取 setup.sh (分支 $SETUP_BR)"
  bash "$COMMON/.ksu_setup.sh" "$KSU_REF"
  rm -f "$COMMON/.ksu_setup.sh"

  [ -e drivers/kernelsu ] || err "集成失败，未生成 drivers/kernelsu"
  log "已软链接 $(readlink drivers/kernelsu)"

  # --- 3.3 defconfig ---
  log "写入 CONFIG_KSU 配置"
  local DEFCONFIG="$COMMON/arch/arm64/configs/gki_defconfig"
  [ -f "$DEFCONFIG" ] || DEFCONFIG="$(ls "$COMMON"/arch/arm64/configs/*defconfig 2>/dev/null | head -1)"
  [ -f "$DEFCONFIG" ] || err "找不到 defconfig"

  # 逐项补齐：setup.sh 可能已写入部分配置，这里只补缺的、并校正 CONFIG_KSU 的值，
  # 避免"已有 CONFIG_KSU 就整段跳过"导致 kprobe 相关项缺失。
  local kv key
  for kv in "CONFIG_KSU=$ENABLE_KSU" \
            "CONFIG_KPROBES=y" \
            "CONFIG_HAVE_KPROBES=y" \
            "CONFIG_KPROBE_EVENTS=y" \
            "CONFIG_KALLSYMS=y" \
            "CONFIG_KALLSYMS_ALL=y"; do
    key="${kv%%=*}"
    if grep -qE "^${key}=" "$DEFCONFIG"; then
      # 已存在则校正取值（只对 CONFIG_KSU 强制对齐构建方式）
      if [ "$key" = "CONFIG_KSU" ]; then
        sed -i "s|^${key}=.*|${kv}|" "$DEFCONFIG"
      fi
    else
      echo "$kv" >> "$DEFCONFIG"
      log "  追加 $kv"
    fi
  done

  # --- 3.3b SUSFS 相关 defconfig（仅在 ENABLE_SUSFS=1 时） ---
  # ReSukiSU 官方集成文档要求：CONFIG_KSU=y + CONFIG_KSU_SUSFS=y
  if [ "$ENABLE_SUSFS" = "1" ]; then
    grep -q '^CONFIG_KSU_SUSFS=' "$DEFCONFIG" \
      || echo 'CONFIG_KSU_SUSFS=y' >> "$DEFCONFIG"
    log "  追加 CONFIG_KSU_SUSFS=y"
  fi
  log "defconfig 就绪: $DEFCONFIG"

  # --- 3.4 版本号兜底（防止回落 16 导致管理器报版本过低） ---
  if [ -f drivers/kernelsu/Makefile ]; then
    grep -q "KSU_VERSION" drivers/kernelsu/Makefile \
      || echo 'ccflags-y += -DKSU_VERSION=30000' >> drivers/kernelsu/Makefile
  fi
}

# ---------------- 3.5 集成 SUSFS（内核级隐藏） ----------------
# 流程依据 susfs4ksu 官方 README：
#   1) 拷 fs/susfs.c + include/linux/susfs*.h 到内核源码
#   2) 打内核侧补丁 50_add_susfs_in_<ver>.patch（进 common/）
#   3) 打 KernelSU 侧补丁 10_enable_susfs_for_ksu.patch（进 KSU 源码目录）
# 注意：分支自带 SUSFS 时（如 SukiSU-Ultra builtin）第 3 步会自动跳过。
do_susfs() {
  [ "$ENABLE_SUSFS" = "1" ] || { log "SUSFS: 未启用，跳过"; return 0; }

  cd "$COMMON"

  # --- 定位 KernelSU 源码根目录（setup.sh 通常软链接 drivers/kernelsu -> ../<KSU>/kernel） ---
  local KSU_SRC=""
  if [ -L drivers/kernelsu ]; then
    KSU_SRC="$(cd "$(dirname "$(readlink -f drivers/kernelsu)")/.." && pwd)"
  fi
  if [ -z "$KSU_SRC" ] && [ -d "$COMMON/KernelSU" ]; then
    KSU_SRC="$COMMON/KernelSU"
  fi
  [ -n "$KSU_SRC" ] || err "找不到 KernelSU 源码目录，无法打 SUSFS 补丁"

  log "SUSFS: 分支=$SUSFS_BRANCH  KSU源码=$KSU_SRC"

  # --- 下载 susfs4ksu：按候选源逐个探测，第一个成功即用 ---
  local SUSFS_DIR="$COMMON/.susfs4ksu"
  rm -rf "$SUSFS_DIR"

  # 组装候选列表：显式指定的排最前，其后是内置备选
  local CANDIDATES="$SUSFS_REPO $SUSFS_FALLBACK_REPOS"
  local REPO="" OK=0 LASTERR=""

  for REPO in $CANDIDATES; do
    [ -n "$REPO" ] || continue
    log "SUSFS: 探测 $REPO (分支 $SUSFS_BRANCH)"

    # 禁用终端交互，避免 GitHub 弹用户名/密码提示把 CI 卡死
    if ! GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code --heads \
         "$REPO" "refs/heads/$SUSFS_BRANCH" >/dev/null 2>/tmp/susfs_probe.log; then
      LASTERR="$(tail -3 /tmp/susfs_probe.log | tr '\n' ' ')"
      warn "  不可用：$REPO — $LASTERR"
      continue
    fi

    log "  分支存在，开始克隆"
    if GIT_TERMINAL_PROMPT=0 git clone --depth=1 -b "$SUSFS_BRANCH" \
         "$REPO" "$SUSFS_DIR" 2>/tmp/susfs_clone.log; then
      OK=1
      log "SUSFS: 使用源 $REPO"
      break
    fi
    LASTERR="$(tail -3 /tmp/susfs_clone.log | tr '\n' ' ')"
    warn "  克隆失败：$REPO — $LASTERR"
    rm -rf "$SUSFS_DIR"
  done

  [ "$OK" = "1" ] || err "所有 susfs4ksu 源均不可用（分支=$SUSFS_BRANCH）。
  最后错误：$LASTERR
  排查方向：
    1) 分支名是否与内核版本匹配（5.10 树用 gki-android12-5.10）
    2) 所有候选源是否都不可达（可临时自建镜像后用 SUSFS_REPO 指定）"

  SUSFS_REPO="$REPO"

  # --- 1) 拷贝 susfs 源码文件 ---
  [ -d "$SUSFS_DIR/kernel_patches/fs" ] || err "susfs4ksu 缺少 kernel_patches/fs"
  cp -f "$SUSFS_DIR"/kernel_patches/fs/* "$COMMON/fs/" 2>/dev/null || true
  cp -f "$SUSFS_DIR"/kernel_patches/include/linux/* "$COMMON/include/linux/" 2>/dev/null || true
  log "SUSFS: 已拷贝 fs/ 与 include/linux/ 下的 susfs 文件"

  # --- 2) 内核侧补丁（进 common/） ---
  local KPATCH
  KPATCH=$(ls "$SUSFS_DIR"/kernel_patches/50_add_susfs_in_*.patch 2>/dev/null | head -1)
  [ -n "$KPATCH" ] || err "未找到 50_add_susfs_in_*.patch"

  cd "$COMMON"
  if patch -p1 --forward --no-backup-if-mismatch -i "$KPATCH" > /tmp/susfs_k.log 2>&1; then
    log "SUSFS: 内核侧补丁已应用 $(basename "$KPATCH")"
  elif grep -qE 'Reversed|previously applied|already exists' /tmp/susfs_k.log; then
    warn "SUSFS: 内核侧补丁似已应用，跳过"
  else
    warn "SUSFS 内核侧补丁应用异常，日志尾部："; tail -20 /tmp/susfs_k.log
    err "SUSFS 内核侧补丁失败（详见上方日志）"
  fi

  # --- 3) KernelSU 侧补丁（进 KSU 源码目录） ---
  local SPATCH="$SUSFS_DIR/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch"
  if [ ! -f "$SPATCH" ]; then
    warn "SUSFS: 未找到 KSU 侧补丁，跳过（该分支可能已内置 SUSFS）"
  else
    cd "$KSU_SRC"
    if patch -p1 --forward --no-backup-if-mismatch -i "$SPATCH" > /tmp/susfs_s.log 2>&1; then
      log "SUSFS: KSU 侧补丁已应用"
    elif grep -qE 'Reversed|previously applied' /tmp/susfs_s.log; then
      warn "SUSFS: KSU 侧补丁似已应用，跳过"
    else
      warn "SUSFS: KSU 侧补丁失败，尝试 git apply --3way"
      git apply --3way "$SPATCH" 2>&1 | tail -20 || warn "SUSFS: KSU 侧补丁最终未应用（内核可能仍可编译，但 SUSFS 功能或不完整）"
    fi
  fi

  rm -rf "$SUSFS_DIR"
  log "SUSFS 集成步骤结束"
}

# ---------------- 4. 绕过 GKI 构建校验 ----------------
do_patch_build() {
  cd "$TREE"

  # 本步骤全是「文本替换」类操作，grep 找不到内容会返回 1，
  # 属于正常情况，绝不能让脚本因此退出。整段临时关闭 errexit。
  set +e

  # ---- 4.1 彻底干掉 check_defconfig ----
  # 三种存在形式都要覆盖：
  #   a) build.config* 里的  POST_DEFCONFIG_CMDS="check_defconfig"
  #   b) build.sh 里的       check_defconfig          (可带参数、可顶格)
  #   c) build.config 中被 eval 展开的调用
  # 做法：除「函数定义行」外，所有 check_defconfig 一律替换成 true，
  #       这样既保留 POST_DEFCONFIG_CMDS 里的其它命令，又不破坏语法。

  local f
  # a) build.config*（common/ 下 + 树根下的都要处理）
  for f in "$COMMON"/build.config* "$TREE"/build.config*; do
    [ -f "$f" ] || continue
    if grep -q 'check_defconfig' "$f"; then
      log "清理 $f 中的 check_defconfig"
      sed -i 's/\bcheck_defconfig\b/true/g' "$f"
    fi
  done

  # b) build.sh：跳过函数定义行，其余替换成 true
  if [ -f build/build.sh ] && grep -q 'check_defconfig' build/build.sh; then
    log "清理 build/build.sh 中的 check_defconfig"
    sed -i -E '/^[[:space:]]*(function[[:space:]]+)?check_defconfig[[:space:]]*\(\)?[[:space:]]*\{/! s/\bcheck_defconfig\b/true/g' build/build.sh
  fi

  # c) 兜底：BUILD_CONFIG 末尾强制清空，确保后面没人再把它塞回来
  local BC="$COMMON/build.config.gki.aarch64"
  if [ -f "$BC" ]; then
    grep -q 'KOW_CUSTOM_MARKER' "$BC" || cat >> "$BC" <<'EOF'

# KOW_CUSTOM_MARKER
POST_DEFCONFIG_CMDS="${POST_DEFCONFIG_CMDS:-true}"
CHECK_DEFCONFIG=
EOF
  fi

  # 自检
  if grep -rn 'check_defconfig' "$COMMON"/build.config* build/build.sh 2>/dev/null \
     | grep -v 'true' | grep -q .; then
    warn "仍有 check_defconfig 残留："
    grep -rn 'check_defconfig' "$COMMON"/build.config* build/build.sh 2>/dev/null | head
  else
    log "check_defconfig 已全部禁用"
  fi

  # ---- 4.2 剔除 LLVM 17+ 专属编译参数 ----
  # 现象：clang r416183b(LLVM 14) 报
  #   Unknown command line argument '-regalloc-enable-advisor=release'
  # 该参数只是寄存器分配优化提示，去掉不影响功能与稳定性。
  local cf
  for cf in \
      "$COMMON/Makefile" \
      "$COMMON/arch/arm64/Makefile" \
      "$COMMON/arch/arm64/Makefile.postlink" \
      "$COMMON/build.config.common" \
      "$COMMON/build.config.aarch64" \
      "$COMMON/build.config.gki" ; do
    [ -f "$cf" ] || continue
    if grep -q 'regalloc-enable-advisor' "$cf"; then
      log "清理 $cf 中的 -regalloc-enable-advisor"
      sed -i -E 's/(-mllvm[[:space:]]+)?--?regalloc-enable-advisor=[A-Za-z0-9_-]+//g' "$cf"
    fi
  done
  # 兜底：全树再扫一遍常见的构建脚本（不用管道，避免 grep 无匹配返回 1）
  for cf in "$COMMON"/Makefile* "$COMMON"/build.config* "$COMMON"/arch/arm64/Makefile*; do
    [ -f "$cf" ] || continue
    grep -q 'regalloc-enable-advisor' "$cf" || continue
    log "清理(兜底) $cf"
    sed -i -E 's/(-mllvm[[:space:]]+)?--?regalloc-enable-advisor=[A-Za-z0-9_-]+//g' "$cf"
  done

  # ---- 4.3 可选：移除 GKI 受保护符号导出表 ----
  if [ -n "${REMOVE_ABI_EXPORTS:-}" ]; then
    log "移除 abi_gki_protected_exports"
    rm -f "$COMMON"/android/abi_gki_protected_exports_* 2>/dev/null || true
  fi

  # 恢复 errexit，并确认本步骤确实成功
  set -e
  log "patch 步骤完成"
  return 0
}

# ---------------- 5. 编译 ----------------
do_kernel() {
  cd "$TREE"
  mkdir -p "$OUTDIR"
  log "开始编译 (LTO=thin, -j$JOBS)，完整日志: out/build.log"

  # 完整日志落盘 + 屏幕只留尾部，方便 CI 里无论成败都能取回
  set +e
  LTO=thin BUILD_CONFIG=common/build.config.gki.aarch64 build/build.sh \
      > "$OUTDIR/build.log" 2>&1
  local RC=$?
  set -e

  # 把真正的报错行单独抽出来，直接显示在控制台
  if [ "$RC" -ne 0 ]; then
    warn "编译失败 (exit $RC)。错误上下文："
    grep -nE '(error:|Error [0-9]+|undefined reference|No such file|fatal error|Killed|modpost)' \
        "$OUTDIR/build.log" | head -40
    warn "完整日志已保存到 out/build.log"
    exit $RC
  fi
  tail -20 "$OUTDIR/build.log"

  # GKI 默认产出 Image.lz4，但 magiskboot repack 会按原厂格式自动重压，
  # 因此优先取「未压缩的 Image」最稳妥；取不到再退回压缩版。
  local IMG=""
  IMG=$(find "$TREE/out" -path '*/arch/arm64/boot/Image' -type f | head -1)

  if [ -z "$IMG" ]; then
    case "$KERNEL_COMPRESS" in
      gz)  IMG=$(find "$TREE/out" -name 'Image.gz'  -not -path '*-dtb*' | head -1) ;;
      lz4) IMG=$(find "$TREE/out" -name 'Image.lz4' -not -path '*-dtb*' | head -1) ;;
    esac
  fi
  [ -n "$IMG" ] || IMG=$(find "$TREE/out" -path '*/arch/arm64/boot/Image*' -type f \
                          -not -name '*.dtb*' | head -1)
  [ -n "$IMG" ] || err "未找到编译产物"

  cp -f "$IMG" "$OUTDIR/"
  # 同时保留一份「未压缩内核」副本，命名 kernel，方便 magiskboot 直接替换
  [ "$IMG" = "$TREE/out"*/arch/arm64/boot/Image ] || true
  log "内核产物: $OUTDIR/$(basename "$IMG")  ($(du -h "$IMG" | cut -f1))"
  log "提示: magiskboot repack 会按原厂格式(gzip)自动重压，直接改名为 kernel 替换即可"

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

  # 命名带上 flavor 与 SUSFS 标记，避免多个包下载后分不清
  local SUF=""
  [ "$ENABLE_SUSFS" = "1" ] && SUF="-susfs"
  sed -i "s|kernel.string=.*|kernel.string=K50-${KSU_FLAVOR}${SUF} GKI $(date +%Y%m%d)|" "$WORKDIR/ak3/anykernel.sh"

  cd "$WORKDIR/ak3"
  local ZIPNAME="K50-${KSU_FLAVOR}${SUF}-android12-5.10-$(date +%Y%m%d-%H%M).zip"
  zip -r9 "$WORKDIR/out/$ZIPNAME" ./* -x .git .gitignore README.md
  log "刷机包: out/$ZIPNAME"
}

# ---------------- 入口 ----------------
case "${1:-all}" in
  sync)    do_sync ;;
  replace) do_replace_common ;;
  ksu)     do_ksu ;;
  susfs)   do_susfs ;;
  patch)   do_patch_build ;;
  kernel)  do_kernel ;;
  pack)    do_pack ;;
  all)
    do_sync
    do_replace_common
    do_ksu
    do_susfs
    do_patch_build
    do_kernel
    do_pack
    log "全部完成，产物在 out/"
    ;;
  *) echo "用法: $0 [all|sync|replace|ksu|susfs|patch|kernel|pack]" ; exit 1 ;;
esac
