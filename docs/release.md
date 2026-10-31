# 版本与发布

BaoCode 的版本号怎么定、一个版本怎么发出去、发到哪里、已安装的应用怎么拿到它，以及第一次发布前要准备什么。应用这一侧怎么检查、下载、校验、安装，见 [auto-update.md](auto-update.md)。

> **这个 fork 只发 Windows 版。** 下面的流程是上游的（`dl.baocode.dev`、Cloudflare R2、
> macOS 与 Linux 的构建、官网在 `baocode.dev`）；这个仓库改成了用自己的 GitHub Release
> 发 Windows 安装包，更新源是本仓库的 `releases/latest/download/latest.json`。
> 文中讲 macOS 构建、签名、公证的部分**在这里不做**：`macos/` 目录与
> `tool/build_macos.dart` 已删掉，`tool/release_manifest.dart` 也不再收 `--macos-*` 与
> `--dmg-*` 选项。远程服务端的 macOS 版仍在（`remote.yml` 在 Mac 上编译）—— 那是装在
> SSH 主机上的服务端，与应用的平台无关。

- 下载与更新：本仓库自己的 GitHub Releases（`releases/latest/download/latest.json`）。
  `dl.baocode.dev` 是上游的域名，这个 fork 不用它
- 官网：`https://baocode.dev` 是上游的（`site/` 目录里的源码随本仓库走，但没地方部署）；应用里给出的地址都是本仓库的。仓库的 GitHub Pages 倒是开着（source 是 main 的 `/docs`），把这份文档部署在 `https://poying2018.github.io/baocode/`；`site/` 不在其中——更新日志页仍无处可看，只有 `latest.json` 的纯文本
- 构建与发布：GitHub Actions，`.github/workflows/release.yml`
- 工具：`tool/bump_version.dart`、`tool/build_windows.dart`、`tool/build_remote_server.dart`、`tool/release_manifest.dart`

## 目录

1. [全貌](#1-全貌)
2. [版本号](#2-版本号)
3. [发一个版本](#3-发一个版本)
4. [CI 做了什么](#4-ci-做了什么)
5. [服务端（本仓库的 GitHub Releases）](#5-服务端本仓库的-github-releases)
6. [更新的数据流](#6-更新的数据流)
7. [第一次发布前的准备](#7-第一次发布前的准备)
8. [出了问题](#8-出了问题)
9. [不用 CI，手动发布](#9-不用-ci手动发布)
10. [手机版](#10-手机版)
11. [浏览器扩展](#11-浏览器扩展)

---

## 1. 全貌

```
 你的机器                     GitHub                                Cloudflare
 ─────────                    ──────                                ──────────
 tool/bump_version.dart
 改版本号、写更新日志
 git push / git push 标签 ──▶ Actions：release.yml
                               ├ check    版本号对不对，不比已发布的旧
                               ├ remote   远程服务端（remote.yml）：在 Mac 上编译一次（Linux、macOS
                               │          各两种架构），Linux 版在 Docker 里跑一遍
                               └ windows  构建、打安装包（Windows 机器）
                               └ publish  签 latest.json ────▶ 本仓库的 GitHub Release
                                          （gh release create/upload）        │
                                                                              ▼
                                              已安装的 BaoCode：启动 10 秒后读
                                              一次，之后每 5 分钟读一次
                                              releases/latest/download/latest.json，
                                              按清单里的链接下载安装包
```

- **网站和安装包分开放**：上游有官网（Worker + R2），这个 fork 没有——`site/` 目录的源码在仓库里，没有地方部署。安装包只在 GitHub Releases 上，推送 `v*` 标签时由 CI 发布。
- **旧地址**：`site/_redirects` 把 `baocode.dev/releases/*` 302 到 `dl.baocode.dev/releases/*`，是上游的机制，本 fork 两头都不部署。

## 2. 版本号

**写法**：`主.次.修订+build`，例如 `1.2.0+12`。写在两处，必须一样（`test/update/version_test.dart` 会检查，CI 也会检查）：

- `pubspec.yaml`：`version: 1.2.0+12`
- `lib/update/version.dart`：`const appVersionString = '1.2.0+12';`

**规则**

- `主.次.修订` 是给人看的版本（marketing 版本），按 semver：修 bug 加修订号，加功能加次版本号，不兼容的大改加主版本号。
- `+build` 是给机器比较的序号，**每次发布都加 1，永远不回退**。应用只接受比自己新的版本（先比 `主.次.修订`，再比 build），build 号没涨，用户就收不到。
- **标签**：`v` + marketing 版本，例如 `v1.2.0`。CI 会核对标签和 pubspec.yaml 是否一致。
- **同一个版本可以重新发布**（比如发出去才发现包有问题，修好后把标签挪到新提交上重推，见第 3 节）。下载链接末尾带着文件哈希（`?sha256=<前 16 位>`），重新发布后是新的地址，CDN 不会给出旧文件。但已经装上这个版本的用户不会再收到它（版本号没变），所以只适合还没人装上、或者问题不影响已装用户的时候；否则发 `1.2.1`。
- **预发布版**（`1.2.0-beta.1`）目前不支持：只有一个更新渠道，所有用户读同一份 `latest.json`，发 beta 就是发给所有人。以后要做的话见 [auto-update.md 第 13 节](auto-update.md#13-已知限制与待办)。

**改版本号用工具**，两处一起改，build 号自动加 1：

```sh
dart run tool/bump_version.dart patch    # 1.2.0+12 → 1.2.1+13
dart run tool/bump_version.dart minor    # 1.2.0+12 → 1.3.0+13
dart run tool/bump_version.dart major    # 1.2.0+12 → 2.0.0+13
dart run tool/bump_version.dart 1.4.0    # 1.2.0+12 → 1.4.0+13
```

**更新日志**：`release-notes/<版本>.en.md` 和 `release-notes/<版本>.zh.md`，是唯一的来源，不另外维护 CHANGELOG.md。它们会出现在：

- `latest.json`：设置 → 更新里显示（纯文本，按应用语言选）
- 网站的更新日志页 `baocode.dev/changelog`、`baocode.dev/zh/changelog`：`tool/build_changelog.dart` 生成 `site/changelog.html`、`site/zh/changelog.html`，跟 notes 一起提交（网站没有构建步骤，Cloudflare 原样发布 `site/`）。更新通知里的「更新日志」按钮直接打开这一页对应版本的位置（`#v1.2.0`）
- GitHub Release 的说明（英文那份）

`bump_version.dart` 会顺手生成草稿（`tool/draft_release_notes.dart`，也可以单独跑）：上一个标签以来的 `feat` / `perf` / `fix` 提交标题，分到「New / Improved / Fixed」（中文「新功能 / 改进 / 修复」）下面，不含 `site`、`ci` 的提交。提交标题是写给开发者的，**草稿要改写成用户看得懂的话**，每版十行左右，中文那份写中文。格式只用普通段落和 `-` 列表：设置页按纯文本显示，标题、加粗之类的 Markdown 符号会原样露出来。

没有 notes 也能发，但 CI 会给出警告：通知里没有「更新日志」按钮，网站上也没有这个版本，GitHub Release 改用自动生成的提交列表。`test/tool/build_changelog_test.dart` 会检查网站页面是不是最新的。

## 3. 发一个版本

以发布 `1.2.0` 为例：

```sh
dart run tool/bump_version.dart minor          # 1.1.3+12 → 1.2.0+13，并生成更新日志草稿
# 改写 release-notes/1.2.0.en.md、release-notes/1.2.0.zh.md
dart run tool/build_changelog.dart             # 生成网站的更新日志页
flutter test test/update/version_test.dart test/tool/build_changelog_test.dart
git add pubspec.yaml lib/update/version.dart release-notes/ site/changelog.html site/zh/changelog.html
git commit -m "chore: release 1.2.0"
git push origin main
git tag v1.2.0
git push origin v1.2.0                          # 从这里开始 CI 接手
```

然后在 GitHub 的 Actions → Release 里看进度（如果给 `release` 环境设了审批人，要点一下 Approve）。macOS 公证要等几分钟，整个流程大约 20～30 分钟。

完成后确认：

- [ ] `curl -s https://github.com/poying2018/baocode/releases/latest/download/latest.json` 是新版本
- [ ] 仓库的 Releases 页有这个版本，安装包能下载
- [ ] 装着旧版本的机器上点“检查更新”，能发现、下载、重启装上

**重新发布同一个版本**（标签挪到新提交上）：

```sh
git push origin :refs/tags/v1.2.0                # 删掉远端的标签
git tag -f v1.2.0 && git push origin v1.2.0      # 打在现在的提交上，重新推
```

CI 会照常构建，删掉旧的 GitHub Release 再重建，把文件重新传上。两件事要心里有数：

- **`releases/latest/download/latest.json` 会短暂落回上一个版本**：release 被删后，
  "latest" 指针退回上一个还存在的 release，安装包跟着不可达，直到新 release 的
  清单传完。已安装的应用在这窗口里读到旧清单，显示「已是最新」——不是坏，只是慢。
  新清单永远最后传（见第 4 节），窗口以分钟计。
- **`test-*` 与 `server-*` 标签不受影响**：它们不建这个 release（test 的产物在
  Artifacts 里）。

**只想试一下构建**：Actions → Release → Run workflow。只构建、不发布，产物在这次运行的 Artifacts 里（要登录 GitHub 才能下载）。

**打测试包给别人**：在要测的提交上打一个 `test-` 开头的标签并推送：

```sh
git tag test-upstream-import && git push origin test-upstream-import
```

CI 照常构建，但**不发布**：安装包留在这次运行的 Artifacts 里（`windows-baocode-claude`、
`remote-baocode-claude`、`symbols-windows-baocode-claude`），要登录 GitHub 才能下载，
把 Artifacts 页的链接发给测试的人即可。不建 GitHub Release、不动 `latest.json`，
已安装的应用不会收到它。同一个标签再测一次：`git tag -f … && git push -f origin …`。

- `test-channel-*` 标签构建的是 channel 版（`lib/channel/`），`test-*` 是标准版。
- 版本号就是分支上 `pubspec.yaml` 的版本。测试的人之后会照常收到比它新的正式版。
- 测试包连 SSH 主机时要远程服务端：正式发版（`v*`）会把各平台的 `.gz` 传到 release
  资产里，按服务端的 VERSION 对号下载（docs/ssh-remote.md 9.3）。

**单独发布远程服务端**：在要发的提交上打一个 `server-` 开头的标签并推送：

```sh
git tag server-1.0.7-ssh-fix && git push origin server-1.0.7-ssh-fix
```

`.github/workflows/remote.yml` 编译四个平台的服务端、在 macOS 和 Docker 里的 Linux 上各跑一遍，然后把 `.gz` 和 `servers.json` 传到 `releases/remote/<VERSION>/`，最后更新 `releases/remote/latest.json`（指向这份）。不构建应用、不动应用的 `latest.json`，已安装的应用不受影响。用途是**本机打的包**：本机编出来的服务端 `VERSION` 和 CI 的对不上，线上没有，连主机会报 404；打包时改用已发布的那份：

```sh
dart run tool/build_windows.dart --remote-release            # 最新发布的服务端
dart run tool/build_windows.dart --remote-release <VERSION>  # 指定的那份
```

脚本用 `tool/fetch_remote_server.dart` 取 `servers.json`、确认每个 `.gz` 都能下载，放进 `build/remote-release/` 再打包。应用和服务端是严格一一对应的内部协议（docs/ssh-remote.md），**服务端要从和应用相同（至少 `packages/bao_remote` 相同）的提交发布**，否则连上后可能出错。正式发版（`v*`）也会把 `servers.json`、`remote-latest-<产品>.json` 传进 release 资产。

## 4. CI 做了什么

`.github/workflows/release.yml`，推送 `v*` 标签时运行：

| Job | 机器 | 做什么 |
| --- | --- | --- |
| `check` | Ubuntu | pubspec.yaml 和 `version.dart` 一致；版本是 `x.y.z+build`；标签是 `v<x.y.z>`；不比本仓库 `releases/latest/download/latest.json` 里已发布的版本旧（一样就是重新发布，给个提示） |
| `tests` | Ubuntu | 跑**全部测试套**（`flutter test`）。它不在任何发布任务的 `needs` 里——红了不拦发版，但在运行的页面上是一面旗：测试失败的东西别装给用户。全套约 5 分钟（本机）/ 10-25 分钟（CI），Linux 上全绿 |
| `remote` | | 调用 `remote.yml`（推 `server-*` 标签时它也单独运行并发布，见第 3 节），下面两步 |
| `remote` › `build` | macOS 15 | 下载和 Flutter 同版本的 x64 Dart SDK → 编译远程服务端（`--all`：Linux x64/arm64 交叉编译；macOS arm64 用本机的 dart，macOS x64 用 x64 的 dart 经 Rosetta，`dart compile exe` 只能在 Mac 上、按 dart 自己的架构编 macOS 版）→ `tool/test_remote_server_macos.sh`：在这台 Mac 上把两份 macOS 版各跑一遍 → 上传 `remote`（`VERSION`、`servers.json`、`.gz`）和 `remote-linux`（Linux 的两个二进制）两个产物 |
| `remote` › `linux` | Ubuntu | `tool/test_remote_server.sh`：在 Docker 里的 Ubuntu 20.04 / 24.04、Debian 12、Rocky Linux 8 上，两种架构各跑一遍（arm64 用 QEMU 模拟），要能启动、回答 `initialize`、列出目录 |
| `windows` | Windows | 装 Inno Setup → `tool/build_windows.dart --remote-built`：构建、放进 `servers.json`、放进 Claude Code（下载并按 SHA-256 校验，见下）、打安装包 |
| `publish` | Ubuntu | 汇总产物 → 用更新私钥签 `latest.json`（`tool/release_manifest.dart`）→ 上传远程服务端 → 上传安装包 → 建 GitHub Release → **最后**上传 `latest.json`（重新发布时先删掉旧的 release） |

几个设计上的考虑：

- **`latest.json` 最后传**：应用一读到新清单就会去下载，安装包必须先就位。
- **远程服务端只编译一次**：`remote` 任务编译，Windows 应用带的是同一份 `servers.json`（四个平台都有），一个 release 里只有一份服务端资产。
- **下载链接带哈希**：`latest.json` 里每个链接末尾是 `?sha256=<文件哈希前 16 位>`。GitHub 的资产地址带文件名，重新发布时同一地址内容会变，所以链接里的哈希同时防 CDN 缓存给出旧文件；应用取文件名时只看路径。
- **`downloads`**：`latest.json` 里多了这一项，是上游给网站下载页用的（本 fork 没有部署下载页），应用不读它。
- **Claude Code 随包分发**：Windows 安装包带上 Claude Code 自己（`claude\claude.exe` 和 `claude\VERSION`），用户不用另装、也不用等第一次对话时的下载。
  - 版本在 `tool/build_windows.dart` 里钉死（`_claudeVersion`），并按 `_claudeSha256` 校验：**构建只会带上那一份**，换版本时两个常量一起改。
  - 下载一次就缓存到 `build\claude\`，以后再构建直接用缓存。
  - 这个二进制是 Anthropic 自己签过名的（Authenticode，带时间戳），Windows 不用重签，SmartScreen 也认。
  - 应用侧的顺序：设置里指定的路径 → 用户自己装的（新的优先）→ **包里的** → 下载的。包里的那份**不自我更新**（它不能往用户的 `~/.local` 里塞东西），它太旧、拒绝了 BaoCode 传的选项时，改为下载一份新的来用。
  - **codex 产品不带它**：那个产品没有 Claude Code 可带。
  - **版本漂移由 CI 自动处理**：`.github/workflows/claude-version.yml` 每天跑一次，把渠道上的当前版本和它的 SHA-256 写进 `_claudeVersion` / `_claudeSha256`，在 `main` 上提交一个 `ci(claude): bump Claude Code to <版本>`。发版时 `check` 任务再跑一遍 `tool/bump_claude_version.dart` 兜底：落后了**发不下去**，并把该改的两行打在错误里；读不到那个源时只警告，不挡发版。日常 PR 不跑这两步。
    - 工具：`dart tool/bump_claude_version.dart`（只说现状，落后时退出码 1）、`--write`（写进 pin）。SHA-256 取自官方 manifest，不必下载那 283 MB 就能拿到；真正的二进制仍由构建时下载并按 pin 校验。
    - 那个工作流直接往 `main` 提交。**若仓库对 `main` 设了保护而拒绝 bot 的推送，第一次跑会失败**——那时改成开 PR，或给 bot 直推权限。
  - 代价：安装包大了不少（Claude Code 的二进制约 283 MB，压缩后安装包约 114 MB；1.6.2 是 21 MB）。
- **密钥只在 `release` 环境里**，只有 `v*` 标签能用（见 7.2）。PR 和手动运行拿不到。
- Flutter 版本固定在工作流的 `FLUTTER_VERSION`，升级 Flutter 时一起改。

### 4.1 一个仓库一个产品

这个仓库只出**一个程序**：BaoCode Claude（Claude Code 内核）。一个 `v<版本>` 标签
发的就是它，没有产品矩阵可选。

**BaoCode Codex 在它自己的仓库**（`poying2018/baocode-codex`）：那份代码树是从这里
分出去的，发布链、版本号序列、更新通道（`latest-codex.json`）完全独立——一个仓库
只发自己的产品，谁也不替谁发布，版本号也不互相消耗。两边共享的代码靠 cherry-pick
来同步。

| | BaoCode Claude（本仓库） | BaoCode Codex（`poying2018/baocode-codex`） |
| --- | --- | --- |
| 安装包 | `BaoCodeClaude-<版本>-setup.exe` | `BaoCodeCodex-<版本>-setup.exe` |
| 更新清单 | `latest.json` | `latest-codex.json` |
| 远端服务端 | `baocode-server-*` | `baocode-codex-server-*` |

- 产品的身份由**可执行文件的名字**决定（`baocode-claude.exe` / `baocode-codex.exe`），
  一处说清两个产品的分别：`packages/bao_remote/lib/src/platform/product.dart`。
  原生侧读同一个名字（`windows/runner/app_identity.cpp`），两边不会各说各话。
  源码树里两个产品都认识，但 **CI 只构建、发布本仓库的那一个**（矩阵写死
  `product: [baocode-claude]`，`publish` 里是 `PRODUCT: baocode-claude`）；
  本地开发时 `windows/CMakeLists.txt` 的默认产品也是它，要构建另一个产品用
  `dart run tool/set_product.dart codex`。
- **架构只有 Windows x64**。上游的 workflow 带 x64 + arm64 双架构矩阵（arm64 的
  Flutter 克隆、Inno 安装、无 patched-engine 的处理，见上游同文件的历史版本），
  `tool/build_windows.dart --arch arm64` 也还在，但合并进这个 fork 时矩阵的 arch
  维度没有跟过来，**本仓库从来不发 arm64**——渠道里所有版本的清单都只有
  `windows-x64`。要恢复的话把那个矩阵搬回来，并按 [auto-update.md 12 节](auto-update.md#12-修改指南)
  的「加一个平台」走完清单。
- `publish` 任务签**一份清单**（`tool/release_manifest.dart --product baocode-claude
  --manifest out/latest.json`），**清单最后传**。
- 名字之外有一样**不跟着可执行名走**：浏览器的 native messaging host。它按自己的
  名字找应用写的端口文件，而端口文件按**产品 id** 命名，商店里已发布的扩展也只认
  那个名字 ⇒ Claude Code 产品的 host 仍是 `baocode-browser-host.exe` /
  `dev.baocode.browser`（`windows/CMakeLists.txt` 与 `windows/BrowserBridge/CMakeLists.txt`
  两处说的必须是同一个名字，安装步骤装的就是前者点名的目标）。

## 5. 服务端（本仓库的 GitHub Releases）

本仓库没有 R2、没有自定义域名：发布物就是仓库自己的 GitHub Releases 资产。一个
`v<版本>` 标签一个 release，资产一层平铺（清单核对过的实际名字）：

```
releases/latest/download/latest.json      应用读的清单（指针指向最新 release）
releases/download/v1.2.0/                 一个版本一个标签
  latest.json                             同一份清单，也是这个 release 的资产
  BaoCodeClaude-1.2.0-setup.exe           Windows：首次安装和自动更新
  baocode-server-<平台>.gz                远程服务端，应用连远程主机时按需下载
  servers.json                              （docs/ssh-remote.md 第 9.3 节）
  remote-latest-baocode-claude.json       最近一次发布的服务端版本记录
```

- **旧版本一直保留**：旧 release 里的服务端还有旧版本的用户在用，删了他们连不上远程主机。
- **`releases/latest/download/<资产>` 指向最新 release 的同名资产**：清单上传是发版的
  最后一步，之前安装包必须先就位；`gh release delete` + 重建会让指针短暂落回上一个版本。
- 清单格式、链接规则见 [auto-update.md 第 5 节](auto-update.md#5-服务端约定)。

## 6. 更新的数据流

**发布时**（CI 的 `publish`）：

1. 对每个平台的安装包算 SHA-256，用 Ed25519 私钥签 `baocode-update-v1 / 版本 / 平台 / 大小 / SHA-256` 这段文本。
2. 写出 `latest.json`：版本、日期、更新日志、每个平台的 `url / size / sha256 / signature`。
3. 安装包上传到 `releases/<版本>/`，`latest.json` 覆盖 `releases/latest.json`。

**已安装的应用**（`update.mode` 是默认的“自动检查并下载”时）：

1. 启动 10 秒后、之后每 5 分钟，GET 本仓库的
   `https://github.com/poying2018/baocode/releases/latest/download/latest.json`。
2. 解析清单；下载链接必须在 github.com（或其重定向主机 githubusercontent.com）上。
   版本不比自己新，或者没有本平台的条目 → 已是最新，结束。
3. 后台下载本平台的安装包（Windows x64 的 setup.exe，见 [auto-update.md 5.2](auto-update.md#52-latestjson-格式)）到 `<数据目录>/updates/<版本>/`，支持断点续传。
4. 依次校验大小 → SHA-256 → Ed25519 签名（公钥内置在应用里）。任何一项不过就删掉，报错。
5. 主窗口右下角弹通知。用户点“立即重启更新”后，走和平时退出一样的确认（未保存的文件、运行中的 agent 和终端），确认了才安装：
   - Windows：应用退出后，带 `/SILENT /RELAUNCH` 运行新的 setup.exe，覆盖安装到原来的位置，再重新打开。
6. 新版本启动时清理 `updates/` 里旧版本的下载。

设置和对话放在数据目录里，不在安装目录里，更新不会动它们。

**官网**（`baocode.dev`，上游的）：`site/` 目录里的源码随本仓库走，但这个 fork 没有部署它的 Worker 和域名，所以没有可用的官网与下载页；应用无法自己更新时打开的是仓库的 Releases 页（见 `ManualUpdateRequired.downloadPage`）。上游那段「浏览器读同一份清单、`/dl/*` 由 Worker 302 到安装包」的机制在本 fork 没有对应物——上面第 5 节的扁平资产就是全部。

**两把“钥匙”管的是不同的事**：

| | 防的是什么 | 没有它会怎样 |
| --- | --- | --- |
| 更新签名私钥（Ed25519） | 有人篡改 `dl.baocode.dev` 上的文件或劫持网络，给所有用户推恶意更新 | 发不了更新；泄露的话，后果见 [auto-update.md 6.3](auto-update.md#63-保管) |
| Apple Developer ID + 公证 | macOS 的 Gatekeeper 拦截从网上下载的未知应用 | 用户第一次打开 dmg 里的应用时被拦：“已损坏，无法打开” |
| Windows 代码签名（还没做） | SmartScreen 的“未知发布者”警告 | 第一次安装时多点一次“仍要运行” |

自动更新只依赖第一把：应用自己下载的文件不带隔离属性，不经过 Gatekeeper 和 SmartScreen。

## 7. 第一次发布前的准备

全部是一次性的。**这些值都直接填进 GitHub 或 Cloudflare 的后台，不要发到聊天里，也不要提交到仓库。**

### 7.1 GitHub（应用发版需要的全部）

1. **环境**：Settings → Environments → New environment，名字 `release`。
   - Deployment branches and tags → Selected branches and tags → 加三条 **Tag**，规则 `v*`、`test-*` 和 `server-*`。只有这几种标签触发的运行能用这个环境里的密钥。
   - 可选：Required reviewers 加上你自己。每次发布要你在 Actions 里点一下批准，多一道保险。
2. **环境密钥**（`release` 环境 → Environment secrets）：

   | 名字 | 值 |
   | --- | --- |
   | `BAOCODE_UPDATE_SIGNING_KEY` | 更新签名私钥文件（一行 base64 的 seed，或 `dpapi:` 开头的加密文件——CI 在 ubuntu 上只认前者） |
   | 下面 7.3 的六个 | 有 Apple 开发者账号之后再加（本 fork 只发 Windows，暂时用不上） |

3. **保护标签**：Settings → Rules → Rulesets → New tag ruleset，目标 `v*`，限制创建、更新、删除，只允许你自己绕过。这样只有你能发版。

4. **Claude Code 版本的每日 bump**：`.github/workflows/claude-version.yml` 每天
   03:37 UTC 自动把渠道当前版本写进 `_claudeVersion` / `_claudeSha256`（发版的
   check 任务再兜底：pin 落旧了发不出去）。**GitHub 的 schedule 在高峰时会延迟
   甚至丢弃**——这个 workflow 就连续两天在错过的窗口里没跑；也观察到配置 03:37
   却在 09:55 才跑的纯延迟（结果一样，bump 照常落）。发现 pin 落后时，
   手动触发一次即可，与计划运行完全等价：

   ```sh
   # gh 登录时
   gh workflow run "Claude Code version" --repo poying2018/baocode --ref main
   # 或用 API（token 要 repo 权限）
   curl -X POST \
     -H "Authorization: Bearer <token>" \
     https://api.github.com/repos/poying2018/baocode/actions/workflows/claude-version.yml/dispatches \
     -d '{"ref":"main"}'
   ```

   跑完看结果：pin 已是当前版时它什么都不提交（正常）；有新版本时在 `main` 上
   落一个 `ci(claude): bump Claude Code to <版本>` 提交。

应用更新的服务端就是这个仓库的 Releases，没有别的要准备。更新签名私钥放进 GitHub 之后，本机和离线备份仍然要留着（见 [auto-update.md 6.3](auto-update.md#63-保管)）。

### 7.2 Cloudflare（只有扩展和手机版用）

`extension.yml` 与 `mobile.yml` 把扩展和 APK 传到 R2（`dl.baocode.dev`，上游的桶）；**应用
的更新不走那里**。要发这两样才需要，一次性的：

1. **R2 存储桶**：R2 → Create bucket，名字比如 `baocode-downloads`。
2. **自定义域名**：存储桶 → Settings → Custom Domains → Connect Domain → `dl.baocode.dev`。不要开 `r2.dev` 公共地址。
3. **CORS**（给下载页读 `latest.json`）：存储桶 → Settings → CORS Policy：
   ```json
   [
     {
       "AllowedOrigins": ["https://baocode.dev"],
       "AllowedMethods": ["GET", "HEAD"],
       "AllowedHeaders": ["*"],
       "MaxAgeSeconds": 3600
     }
   ]
   ```
4. **API 令牌**：R2 → Manage R2 API Tokens → Create API token，权限 **Object Read & Write**，范围**只选这个存储桶**。记下 Access Key ID 和 Secret Access Key（只显示一次），以及页面上的 Account ID。对应的 secret：`R2_ACCOUNT_ID`、`R2_ACCESS_KEY_ID`、`R2_SECRET_ACCESS_KEY`，环境变量 `R2_BUCKET`（存 Action variables）。
5. **网站**：Worker `baocode`，静态资源是 `site/`（`_headers`、`_redirects` 照常生效），Settings → Builds 连着 GitHub 仓库（生产分支 `main`），自定义域名 `baocode.dev`。

### 7.3 Apple（macOS 签名与公证）

> **本 fork 不发 macOS 版**（见第 1 节免责声明）：没有 `macos/` 构建任务，`tool/build_macos.dart`
> 已删。下面这节是上游的记录，留着给以后万一恢复 macOS 发布时参考；本仓库的 CI
> 不读这些 secret。

**需要 Apple 开发者账号吗？** 要。没有的话应用照样能构建、能自动更新，但新用户第一次从网上下载打开时会被 Gatekeeper 拦下（“BaoCode 已损坏，无法打开”），只能在终端里运行 `xattr -dr com.apple.quarantine` 才能打开。对外发布基本绕不过去。

1. **加入 Apple Developer Program**（每年 99 美元）：<https://developer.apple.com/programs/enroll/>
   - 我们**以个人身份**加入：用本人的 Apple ID（要开双重认证）。中国大陆的表单要求填身份证上的中文姓名和身份证号。在 iPhone 或 Mac 的 Apple Developer App 里注册最快，要拍证件做身份验证；也可以在网页上注册。付款后一般一两天内通过。
   - 证书上显示的是个人姓名（`Developer ID Application: <姓名> (<Team ID>)`），用户在签名信息里能看到，双击打开时的提示里看不到。
   - 以后想改成组织：可以联系 Apple 把个人账号转成组织账号（需要 D-U-N-S 编号）。转换前向 Apple 确认 Team ID 不变，否则见下面的注意。
2. **Developer ID Application 证书**：只有账号持有人（Account Holder）能创建。
   - 在 Mac 上打开 Xcode → Settings → Accounts → 登录 Apple ID → Manage Certificates → 左下角 `+` → **Developer ID Application**。
   - 打开“钥匙串访问” → 登录 → 我的证书 → 找到 “Developer ID Application: <名字> (<Team ID>)” → 右键导出为 `.p12`，设一个密码。
   - 终端运行 `security find-identity -v -p codesigning`，复制那一行开头的 40 位十六进制指纹（也可以用引号里的完整名字，但名字里有中文时用指纹更稳）。
3. **公证用的 API 密钥**：App Store Connect → 用户和访问 → 集成 → App Store Connect API → 团队密钥 → `+`，访问权限选 **Developer**。下载 `.p8` 文件（只能下载一次），记下 Key ID 和页面上方的 Issuer ID。
4. **填进 `release` 环境的密钥**：

   | 名字 | 值 |
   | --- | --- |
   | `MACOS_CERTIFICATE` | `base64 -i 证书.p12 \| pbcopy` 复制出来的内容 |
   | `MACOS_CERTIFICATE_PASSWORD` | 导出 `.p12` 时设的密码 |
   | `MACOS_SIGN_IDENTITY` | 第 2 步复制的指纹，例如 `1A2B3C…`（40 位）；或完整名字 `Developer ID Application: <姓名> (<Team ID>)` |
   | `NOTARY_KEY` | `.p8` 文件的全部内容（包括 `-----BEGIN PRIVATE KEY-----` 那两行） |
   | `NOTARY_KEY_ID` | Key ID |
   | `NOTARY_ISSUER` | Issuer ID |

5. 先用 Actions → Release → Run workflow 试一次：手动运行拿不到密钥，所以这一步只验证构建本身。要验证签名，就发一个真实版本，或在本机按第 9 节手动跑 `tool/build_windows.dart`。

**注意**

- **Team 一旦用上就别换**：应用正式签名之后，只接受同一个 Team 签名的更新（`lib/update/installer_io.dart`）。从 ad hoc 签名的版本（现在的 1.0.0）更新到第一个正式签名的版本没问题；之后换 Team（比如另注册一个组织账号），老用户就得手动重装一次。
- **证书有效期 5 年**：到期前在同一个 Team 下新建一张，换掉 `MACOS_CERTIFICATE` 等密钥即可，Team 不变，老用户不受影响。已经公证过的版本过期后仍然能打开。
- **不需要提供给我**：证书、密码、密钥都只填在 GitHub 里。脚本和工作流已经按上面这些名字写好了，填好就能用。

## 8. 出了问题

| 情况 | 怎么办 |
| --- | --- |
| `check` 失败：版本不一致 / 标签不对 | 按报错改，删掉远端标签（`git push origin :refs/tags/v1.2.0`），重新打标签推送 |
| `check` 失败：比已发布的旧 | `tool/bump_version.dart` 加到比已发布的新 |
| `remote` › `linux` 失败：Docker 里跑不起来 | 日志里有每个系统、每种架构的结果和服务端的输出。在本机用 `dart run tool/build_remote_server.dart && tool/test_remote_server.sh` 复现（需要 Docker） |
| `remote` › `build` 失败：macOS 版没编出来或跑不起来 | 多半是下载 x64 Dart SDK 失败（Flutter 带的 Dart 版本在 dart-archive 上没有对应的包），或 Rosetta 没装上。在 Apple silicon 的 Mac 上用 `dart run tool/build_remote_server.dart --all --macos-x64-dart <x64 sdk>/bin/dart && tool/test_remote_server_macos.sh` 复现 |
| `publish` 在上传 `latest.json` 之前失败 | 用户什么都看不到。修好后按第 3 节重新发布同一个版本即可 |
| 发出去的版本有问题 | 尽快发一个修复版（版本号更高）。也可以把上一版的 `latest.json` 传回去，让还没更新的人停在旧版，但已经更新的人不会被降级。见 [auto-update.md 5.5](auto-update.md#55-撤回一个版本) |
| 用户报“检查更新失败” | 见 [auto-update.md 第 10 节](auto-update.md#10-故障排查) |

## 9. 不用 CI，手动发布

CI 不可用时的备用办法，步骤和 CI 一样（Windows 上）。**前提：本机要装 Inno Setup**
（CI 的 runner 是现装的；本机没有时 `winget install --id JRSoftware.InnoSetup`，或从
<https://jrsoftware.org/isdl.php> 下载——缺了它，构建会在「Compiling the installer」
一步报 `ISCC.exe (the Inno Setup compiler) was not found.`）：

```powershell
# 远程服务端：本机没有 Mac，编不了 macOS 版——工具会在 Mac 的两个平台上跳过并提示
# "Only a Mac builds it."，servers.json 只写编出的平台。要四个平台齐全，从最近一次
# 发版的资产里取（releases/download/<服务端版本>/，tool/fetch_remote_server.dart 取），
# 或在 Mac 上编好后拷过来。
dart run tool\build_remote_server.dart --out build\remote

# 构建并打安装包（装到 build\installers\；--skip-build 跳过重编应用本体）
dart run tool\build_windows.dart --remote-built

# 有私钥的机器上：签出清单（BaoCodeClaude-<版本>-setup.exe 在 build\installers\）。
# BAOCODE_UPDATE_SIGNING_KEY 是**密钥文件的路径**；加密的文件内容以 dpapi: 开头，
# 工具在本机解密——不是把 dpapi: 写进环境变量。
$env:BAOCODE_UPDATE_SIGNING_KEY = 'F:\Projects\baocode-release-key\update-signing.key.enc'
dart run tool\release_manifest.dart `
  --version 1.2.0+12 `
  --windows build\installers\BaoCodeClaude-1.2.0-setup.exe `
  --notes-en release-notes/1.2.0.en.md --notes-zh release-notes/1.2.0.zh.md `
  --manifest build\installers\latest.json
```

然后按顺序传到仓库的 release（`gh release create v1.2.0` 先建，或让 CI 的标签运行建）：

1. 远程服务端：`build\remote\<VERSION>\*`（`.gz` 与 `servers.json`）——先传，清单会点名它们
2. 安装包 `BaoCodeClaude-1.2.0-setup.exe`
3. 确认资产能下载、大小对
4. **最后** `latest.json`（`gh release upload v1.2.0 build\installers\latest.json --clobber`）

## 10. 手机版

手机版（Android 的 APK、iOS 走 TestFlight）由 `.github/workflows/mobile.yml` 构建，和桌面版分开发布，版本号也分开（手机版 `pubspec.yaml` 里的版本，`0.x` 算 Beta）。官网下载页的 Android 按钮是 `/dl/android`，由 `site-worker/index.js` 按 `releases/mobile/latest.json` 跳转到当前版本。

```sh
git tag mobile-v0.1.0 && git push origin mobile-v0.1.0      # 发布：标签要和手机版的版本一致
git tag mobile-test-foo && git push origin mobile-test-foo  # 测试包：APK 传到 dl.baocode.dev/test/mobile-…，iOS 照样传 TestFlight
```

CI 从 `baocode-dev/mobile` 的 main 取代码（放在本仓库旁边，`../monad` 的包照常能找到），分两台机器构建：

- **Android**（Ubuntu）：`flutter build apk --release`，用发布密钥签名。每个版本都要用**同一把密钥**，否则装不上旧版之上，只能卸载重装。
- **iOS**（`macos-26`，要 Xcode 26：App Store Connect 只收 iOS 26 SDK 编的包）：导入 Apple Distribution 证书和 App Store 描述文件 → 把工程里 Runner 目标的 Release 配置改成手动签名（工程本身是自动签名，要登录开发者账号，CI 上没有；只改 Runner，Pods 的目标不能带描述文件）→ `flutter build ipa`，build 号用本工作流的 run number（TestFlight 不收重复的 build 号）→ `xcrun altool --upload-app` 用 App Store Connect API Key 上传到 TestFlight。**`mobile-test-*` 也上传**：iOS 的测试员走 TestFlight。上传后苹果要处理几分钟，测试员才看得到。

APK 上传时用 `--content-type` 说明类型（`application/vnd.android.package-archive`）。

发布时 APK 传到 `releases/mobile/<版本>/`，最后写 `releases/mobile/latest.json`（`version`、`pubDate`、`beta`、`downloads.android` 的 `url / size / sha256`）。桌面版的 `latest.json` 不受影响。

iOS 在 App Store Connect 上的 App 是 **BaoCode**（Apple ID `6825371537`，Bundle ID `dev.baocode.mobile`，Team `77SLP2NCVR`）。证书和描述文件一年一换：到期前用 App Store Connect API（或开发者网站）新建 Apple Distribution 证书、用它重做 App Store 描述文件，换掉下面三个密钥。

TestFlight 上每个 build 都要回答出口合规（加密）问题，否则停在「缺少合规证明」；在手机版的 `Info.plist` 里加 `ITSAppUsesNonExemptEncryption` 就不用每次回答。

**`release` 环境里要有的**（7.2 那些之外）：

| 名字 | 是什么 |
| --- | --- |
| `MOBILE_DEPLOY_KEY` | 读 `baocode-dev/mobile` 的部署密钥（私钥）。公钥加在那个仓库的 Settings → Deploy keys，只读即可 |
| `ANDROID_KEYSTORE` | Android 发布密钥库（`.jks`）的 base64 |
| `ANDROID_KEYSTORE_PASSWORD` | 它的密码（密钥别名 `baocode`，密钥密码与之相同） |
| `IOS_CERTIFICATE` | Apple Distribution 证书 `.p12` 的 base64 |
| `IOS_CERTIFICATE_PASSWORD` | 它的密码 |
| `IOS_PROFILE` | `dev.baocode.mobile` 的 App Store 描述文件（`.mobileprovision`）的 base64 |

上传 TestFlight 用的是 7.3 公证用的那把 App Store Connect API Key（`NOTARY_KEY`、`NOTARY_KEY_ID`、`NOTARY_ISSUER`），它的职能是 App 管理，两件事都够用。

环境的部署规则里要允许 `mobile-*` 标签。

下载页这两张卡片各带一个二维码（`site/qr/android.svg`、`site/qr/ios.svg`，鼠标悬停或点击卡片时显示）：码里是卡片自己那个按钮的链接，也就是 `/dl/android`、`/dl/ios`，扫到就跳到当时最新的那版安装包。链接变了就先跑 `dart run tool/make_download_qr.dart` 重新生成（`test/tool/download_qr_test.dart` 会检查页面、按钮和码三者一致）。**别把 `dl.baocode.dev` 上带哈希的直链写进码里**：那地址每次发版都换，码是要能一直用的。`latest.json` 里已经没有 iOS 的包：`/dl/ios` 跳到 TestFlight 公开测试的链接（`site-worker/index.js` 的 `TESTFLIGHT`，App Store Connect → BaoCode → TestFlight → Public beta），每个 build 都是这一个，上了 App Store 再换。Android 的卡片暂时下线（`MOBILE_OFFLINE`），`/dl/android` 跳回下载页。

> 发布密钥库丢了就再也发不了能覆盖安装的 APK：本机和 CI 之外务必另存一份。

## 11. 浏览器扩展

浏览器扩展（`browser_extension/`，原理见 `lib/browser/browser_bridge.dart`）由 `.github/workflows/extension.yml` 打包发布，版本号就是 `manifest.json` 里的 `version`，和应用、手机版都分开。用户有两种装法，官网下载页「浏览器扩展」一节两个按钮都有：

- **Chrome 应用商店**（`/dl/chrome-web-store`）：自动更新。
- **开发者模式**（`/dl/browser-extension`）：下载 zip，解压后在 `chrome://extensions` 里「加载已解压的扩展程序」。不会自动更新。

两种装法的扩展 ID 一样，都是 `jfjagocghaaheooicmdnhcholmgdkngk`：开发者模式的 zip 里 `manifest.json` 带着 `key`，商店版是第一次上传时带上私钥 `key.pem` 定下的（见 [docs/browser-extension-store](browser-extension-store/README.md#第一次上传)）。应用只认这个 ID（`BrowserBridge.extensionIds`），CI 会检查 `key` 算出来的 ID 和它一致。私钥在 `~/.baocode-signing/browser-extension.pem`，丢了也不影响已上架的扩展（商店有自己的签名），但开发者模式的 ID 就没法再算出来了，务必另存一份。

```sh
# 先改 browser_extension/manifest.json 的 version（商店要求每次上传版本号都更大）
git tag extension-v0.2.0 && git push origin extension-v0.2.0         # 发布：标签要和 manifest 的版本一致
git tag extension-test-foo && git push origin extension-test-foo     # 只打包，传到 dl.baocode.dev/test/extension-…
```

本地打包：`tool/pack_browser_extension.sh`，产物在 `build/browser_extension/`。

CI 做的事：

| Job | 做什么 |
| --- | --- |
| `pack` | 标签和版本一致；`node --check` 检查 `background.js`；`key` 算出的 ID 等于应用认的 ID；manifest 里提到的文件都在；打两个 zip。改了扩展的 PR 也会跑这一步 |
| `share` | `extension-test-*`：两个 zip 都传到 `test/` |
| `publish` | 开发者模式的 zip 传到 `releases/extension/<版本>/`，最后写 `releases/extension/latest.json`（`version`、`pubDate`、`id`、`store`、`downloads.browser-extension`） |
| `store` | 用 Chrome Web Store API 上传商店的 zip 并提交审核，审核通过后自动上架。没配凭据就跳过，提示手动上传（凭据怎么拿见 [docs/browser-extension-store](browser-extension-store/README.md#ci-自动提交之后每个版本)） |

商店地址由官网维护：`latest.json` 的 `store`，默认是用 ID 拼出来的 `https://chromewebstore.google.com/detail/<ID>`，要换别的就在 `release` 环境的变量 `CHROME_WEB_STORE_URL` 里填，再推一次标签（或手动改 `latest.json`），不用发新版应用。官网的 `/dl/chrome-web-store` 跳过去（读不到 `latest.json` 时也跳 ID 地址）；应用里的按钮（`lib/browser/extension_store.dart`）每次运行拉一次，存在缓存目录的 `browser/store`，拉不到用上次存的，从没拉到过就用 ID 地址。

环境的部署规则里要允许 `extension-*` 标签。

**少发扩展**：扩展只做应用做不了的事：通信、共享标签页的边界（应用的任何请求都越不过它）、工具栏按钮。页面里的一切走 DevTools 协议原样转发（`cdp`，带 `sessionId` 时是页面里 iframe、worker 的会话，事件也带 `sessionId`）；标签页、窗口、分组走 `call`（`chrome.tabs.*`、`chrome.windows.*`、`chrome.tabGroups.*`，只能碰共享的标签页，返回的也只有共享的）和 `subscribe`（这几类的事件，只报共享标签页的）；行为开关走 `configure`（如 `followOpeners`：共享标签页打开的新标签页自动共享，默认开）。所以新功能基本只改应用。只有要新的浏览器权限（manifest 的 `permissions`）时才必须发新版扩展，而且用户要重新同意，尽量少加。

**能力和协议版本**：扩展新增的方法写进 `background.js` 的 `CAPABILITIES`，在握手时告诉应用，应用用 `BrowserConnection.can('…')` 判断后再用，旧扩展照样能连。只有改了已有消息的含义、旧的一方会理解错时，才把 `background.js` 的 `BRIDGE` 和 `BrowserBridge.protocol` 一起加一。版本对不上的连接，应用不用它，并在 设置 → 浏览器 里提示用户更新扩展或更新 BaoCode。商店版扩展会自动更新，通常比应用新；所以改协议时尽量让应用同时兼容旧版，先发应用、再发扩展。

**应用这边的 host**：浏览器按 native messaging 启动应用自带的 host，host 再去连应用。macOS 是 `macos/BrowserBridge/host.c`，Xcode 编进 `Contents/MacOS`，应用每次启动把 manifest 写进各浏览器的 `NativeMessagingHosts` 目录，经 Unix socket 连接。Windows 是 `windows/BrowserBridge/host.cpp`，`flutter build windows` 时编成 `baocode-browser-host.exe`，和 manifest `dev.baocode.browser.json` 一起放在 `baocode.exe` 旁边；安装包在 Chrome、Edge、Chromium 的注册表键里指向这个 manifest，卸载时删掉（Brave、Vivaldi 等读 Chrome 的键）。Windows 上 Dart 没有 Unix socket，应用改为监听 127.0.0.1 的随机端口，端口和每次启动新生成的 token 写在临时目录的 `baocode-browser.port`，host 握手时必须带上 token，否则应用直接断开。没经过安装包的本地构建没有注册表键，要测就手动加一条：`reg add HKCU\Software\Google\Chrome\NativeMessagingHosts\dev.baocode.browser /ve /d <构建目录>\dev.baocode.browser.json /f`。改扩展 ID 时 Windows 的 manifest 要一起改，`test/browser/browser_bridge_test.dart` 会检查两边一致。Linux 用的也是 `host.c`：`linux/BrowserBridge/CMakeLists.txt` 在 `flutter build linux` 时把它编成 `baocode-browser-host`，放在 `baocode` 旁边（deb 里是 `/opt/baocode/`）；应用每次启动把 manifest 写进 `~/.config/<浏览器>/NativeMessagingHosts`（设了 `XDG_CONFIG_HOME` 就用它）。socket 放在 `$XDG_RUNTIME_DIR`（只有本用户能进），没有才退回 `$TMPDIR` 或 `/tmp`；`/tmp` 是所有用户共用的，所以 host 连上后会用 `SO_PEERCRED` 核对对方是不是同一个用户，不是就断开，免得别的用户抢先占住 socket、截走浏览器的消息。Snap 版 Chromium 和 Flatpak 装的浏览器有沙箱，启动不了沙箱外的 host，暂不支持，设置 → 浏览器 里会提示改用官方 deb/rpm 包。CI 的 Linux 任务装上 deb 启动后，会检查 manifest 写对了位置，并真的跑一遍 host 连上应用。
