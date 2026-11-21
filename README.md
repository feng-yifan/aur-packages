# aur-packages

`feng-yifan` 的 AUR 包管理仓库（PKGBUILD 为单一事实来源，配 GitHub Actions 自动同步到 AUR）。

## 已管理的包

| 包名 | 版本 | 上游 | 说明 |
|------|------|------|------|
| `twilight-echo-bin` | 2.0.2-1 | [Px-asen/Twilight_Echo](https://github.com/Px-asen/Twilight_Echo) | Twilight Echo 音乐播放器的二进制重打包（官方 Linux `.deb`）。非官方包。 |

## 目录结构

```
.
├── twilight-echo-bin/            # 每个 AUR 包一个目录（PKGBUILD/.SRCINFO/.install）
├── scripts/
│   ├── check-upstream.sh         # 检测上游新版本 + 外科式更新 PKGBUILD + 重生成 .SRCINFO
│   ├── build-verify.sh           # 非 root 构建 + namcap 校验
│   ├── aur-publish.sh            # 同步到 AUR（默认 dry-run，--push 真推）
│   └── pipeline.sh               # 编排：check / publish 两种模式
└── .github/workflows/
    ├── upstream-check.yml        # 每天 06:00 UTC 巡检上游，自动更新与发布
    └── publish-aur.yml           # push(main) 或手动触发：构建并发布
```

## 本地构建

需要 Arch Linux，`base-devel`、`namcap`。

```bash
cd twilight-echo-bin
makepkg -si          # 构建并安装（安装需 sudo）
# 或只构建：
makepkg -f
```

## 发布到 AUR（手动）

```bash
cd twilight-echo-bin
makepkg --printsrcinfo > .SRCINFO   # 改了 PKGBUILD 后必须重生成
../scripts/aur-publish.sh twilight-echo-bin            # dry-run，仅打印
../scripts/aur-publish.sh twilight-echo-bin --push     # 真正推送（首次推送即在 AUR 创建包）
```

AUR 仓库使用 `master` 分支，脚本已处理。

## 自动化流水线

### 对账模型
`upstream-check` 每天 UTC 06:00 运行，把三方对齐：**上游 latest Release → 本仓库 PKGBUILD → AUR 已发布版本**。
- 有新上游版本 → 更新 `pkgver`/`pkgrel`/`sha256sums`、重生成 `.SRCINFO`、构建 + `namcap` 校验 → 提交 GitHub →（开关开启时）发布 AUR。
- 上次发布失败（AUR 落后）→ 下次运行自动补发。
- 脚本只改动 `pkgver=` / `pkgrel=` / `sha256sums_x86_64=(...)` 三处锚点，**保留其余人工修改**。

### 版本与 pkgrel 语义
| 情况 | 动作 |
|------|------|
| 上游版本更高 | `pkgver=新, pkgrel=1`，更新校验和 |
| 同版本、校验和不变 | 跳过（不碰 `pkgrel`，人工热修不受影响）|
| 同版本、上游重传（校验和变）| `pkgrel+1`，更新校验和 |
| 上游版本回退 | 报警，不动作 |
| GitHub 版本 > AUR 已发布 | 构建并补发（含人工热修 / 失败重试）|

因此可安全地发布 `2.0.2-1` 后，人工把 `pkgrel` 改成 `2` 修 bug（`2.0.2-2`）；定时任务不会把它重置，而下次上游发 `2.0.3` 时会正确重置 `pkgrel=1`。

### 发布闸门 `AUR_AUTOPUBLISH`
仓库变量 `AUR_AUTOPUBLISH`（`true`/`false`）控制全自动发布：
- `false`（默认）：定时任务只更新 GitHub 并开 Issue 提示，不写 AUR；push 触发的 `publish-aur` 也跳过。
- `true`：全自动发布。
- 手动 `workflow_dispatch` 触发 `publish-aur` 不受闸门限制（显式发布）。

### 需要的 Secrets / Variables
在仓库 **Settings → Secrets and variables → Actions** 配置：
- Secret `AUR_SSH_PRIVATE_KEY`：AUR 账户的 SSH 私钥（对应公钥需已在 AUR 账户登记）。
- Secret `AUR_KNOWN_HOSTS`（可选）：`ssh-keyscan aur.archlinux.org` 的结果，用于固定主机指纹。
- Variable `AUR_AUTOPUBLISH`：`false`（默认）或 `true`。

## 热修流程（同版本修 bug）

```bash
cd twilight-echo-bin
# 修改 PKGBUILD（如补依赖/修路径），并把 pkgrel 从 1 改成 2
makepkg --printsrcinfo > .SRCINFO
git add PKGBUILD .SRCINFO && git commit -m "twilight-echo-bin: 2.0.2-2 fix ..."
git push
```
若 `AUR_AUTOPUBLISH=true`，push 会自动构建并发布 `2.0.2-2` 到 AUR；否则手动触发 `publish-aur` 工作流。

## 免责声明
本仓库为非官方打包，仅重打包上游发布产物。上游版权与许可证见各自项目（Twilight Echo 为 Apache-2.0）。
