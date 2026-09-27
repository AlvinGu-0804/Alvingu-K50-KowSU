# K50-GKI-Kernel-Builder

红米 K50（rubens / 天玑8100）GKI 内核构建器，内核源为 `ztc1997/android_gki_kernel_5.10_common`，
Root 方案可在多个 KernelSU 分支间切换，并可选集成 SUSFS。

- 内核源：`ztc1997/android_gki_kernel_5.10_common`（android12-5.10-lts）
- Root 分支：ReSukiSU / KowSU / ApkeSU / SukiSU-Ultra / KernelSU-Next / 官方 / 纯净
- 可选：SUSFS 内核级隐藏
- 产物：AnyKernel3 可刷 zip + 裸内核镜像

---

## 一、云端构建（推荐，零环境配置）

1. Fork 本仓库到你自己的 GitHub 账号
2. 进入 **Actions** 页面，首次需点确认启用工作流
3. 左侧选 **Build K50 GKI Kernel (KernelSU 多分支)** → 右侧 **Run workflow**
4. 填写参数后点绿色按钮运行（约 40~90 分钟）

### 构建参数

| 参数 | 说明 | 建议 |
|---|---|---|
| `ksu_flavor` | Root 分支 | `resukisu` / `kowsu` / `apkesu` / `none` |
| `ksu_repo` | 自定义仓库（仅 flavor=custom） | 留空 |
| `ksu_ref` | 分支/tag | `main` |
| `enable_susfs` | 集成 SUSFS | ReSukiSU 时勾选 |
| `susfs_branch` | SUSFS 补丁分支 | **5.10 选 `gki-android12-5.10`** |
| `kernel_compress` | 内核压缩格式 | **必须与原厂 boot 一致**，小米多为 `gz` |
| `ksu_mode` | `y`=编进内核，`m`=LKM 模块 | `y` |
| `ztc_branch` | ztc 内核分支 | 留空用默认 |
| `remove_abi_exports` | 移除 GKI 受保护符号表 | 厂商模块加载失败才勾 |

5. 运行结束后在 Summary 底部下载 `K50-kernel-output`

### flavor 对照表

| flavor | 仓库 | 配套管理器 | 备注 |
|---|---|---|---|
| `resukisu` | ReSukiSU/ReSukiSU | ReSukiSU（也支持多管理器） | **支持 SUSFS**，默认推荐 |
| `kowsu` | KOWX712/KernelSU | com.kowx712.supermanager | 主打 LKM |
| `apkesu` | fixz232/ApkeSU | 需自行确认 | 管理器侧分支，无 Release |
| `sukisu` | SukiSU-Ultra | com.sukisu.ultra | 支持 KPM |
| `next` | KernelSU-Next | — | 内核 4.4–6.6 |
| `official` | tiann/KernelSU | me.weishu.kernelsu | 最稳 |
| `none` | — | — | 纯净内核，供 YukiSU 等 LKM 方案加载 .ko |

---

## 二、本地构建（WSL2 / Ubuntu 22.04）

```bash
sudo apt install -y bc bison build-essential ccache curl flex git \
  libelf-dev libssl-dev lzop python3 rsync unzip zip zlib1g-dev repo ccache

git clone <你的仓库> K50-KowSU-Builder && cd K50-KowSU-Builder
chmod +x build.sh

./build.sh            # 全流程
./build.sh sync       # 只同步源码
./build.sh replace    # 只替换内核源码
./build.sh ksu        # 只做 KernelSU 集成
./build.sh susfs      # 只打 SUSFS 补丁
./build.sh patch      # 只绕过 GKI 校验
./build.sh kernel     # 只编译
./build.sh pack       # 只打包
```

可用环境变量：

```bash
KSU_FLAVOR=resukisu \
KSU_REF=main \
ENABLE_SUSFS=1 \
SUSFS_BRANCH=gki-android12-5.10 \
KMI_BRANCH=common-android12-5.10 \
ZTC_BRANCH= \
KERNEL_COMPRESS=gz \
ENABLE_KSU=y \
REMOVE_ABI_EXPORTS=1 \
./build.sh
```

---

## 三、刷入（务必按顺序）

```bash
# 1. 先备份原厂 boot（救命用，存到电脑）
adb pull /dev/block/by-name/boot ./stock_boot.img    # 或 fastboot 从固件提取

# 2. 先临时启动，不写分区 —— 出问题重启即可，数据还在
fastboot boot <内核镜像或由 AK3 解出的 boot.img>

# 3. 确认能进系统、Wi-Fi / 触控 / 基带 / 相机都正常后，才永久写入
fastboot flash boot boot.img
```

AnyKernel3 zip 也可在系统内用 Kernel Flasher / Horizon Kernel Flasher 刷，或进 recovery 刷。

### 救砖

```bash
fastboot flash boot stock_boot.img
```

---

## 四、脚本做了什么（便于排查）

| 步骤 | 动作 |
|---|---|
| `sync` | `repo init/sync` 拉 AOSP GKI manifest 树（含 `build/`、`prebuilts/clang`），自带 `deprecated/` 分支回退 |
| `replace` | 删掉官方 `common/`，clone ztc1997 源码入内；把官方 `build.config*` 补回去 |
| `ksu` | 清理可能内置的官方 KernelSU → 跑所选分支的 `setup.sh`（依次尝试 ref/main/master）→ 追加 defconfig → 版本号兜底 |
| `susfs` | 拉 `susfs4ksu` 指定分支 → 拷 `fs/`、`include/linux/` → 打内核侧 `50_add_susfs_in_*.patch` → 打 KSU 侧 `10_enable_susfs_for_ksu.patch`（缺失则跳过） |
| `patch` | 禁用 `check_defconfig`（改 gki_defconfig 必触发），可选移除 ABI 导出表 |
| `kernel` | `LTO=thin BUILD_CONFIG=common/build.config.gki.aarch64 build/build.sh` |
| `pack` | 拉 AnyKernel3 → 替换 `anykernel.sh` → 打 zip |

---

## 五、已知坑

1. **ZTC 源码可能已内置官方 KernelSU** — 脚本会自动检测并清理真实目录（软链接不误删）。若仍冲突，手动删 `common/drivers/kernelsu` 后重跑 `./build.sh ksu`。
2. **内核压缩格式错** — 直接不开机。先用 `magiskboot unpack stock_boot.img` 看原厂是 `Image` / `Image.gz` / `Image.lz4`。
3. **版本号回落 16** — 管理器报"版本过低"。脚本已兜底写 `KSU_VERSION=30000`，如需精确值自行改。
4. **MTK 平台风险（重点）** — K50 是天玑8100，部分驱动为 vendor 分区闭源 `.ko`。刷 GKI 通用核可能导致 Wi-Fi / 触控 / 基带失效。**必须 `fastboot boot` 验证通过再永久刷入**。若硬件缺失，需改用小米官方 `rubens-s-oss` 源码树（非 GKI 通用核）重新编译。
5. **KernelSU 3.0+ 需 metamodule** — 刷好 root 后必须装 `meta-overlayfs`，否则改 /system 的模块装了也不挂载。
6. **SUSFS 分支必须匹配内核版本** — 5.10 树一定要选 `gki-android12-5.10`；选错补丁打不上，`do_susfs` 会直接报错终止。
7. **ReSukiSU 支持多管理器** — 内核驱动是 ReSukiSU，但可用 KowSU / SukiSU / 官方管理器操作；反馈 bug 时请用 ReSukiSU 管理器提交日志。
8. **SUSFS 的 NonGKI 分支已弃用** — 官方标注 deprecated，非 GKI 内核需自行 backport。
