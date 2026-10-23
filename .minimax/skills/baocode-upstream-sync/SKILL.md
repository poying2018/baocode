---
name: baocode-upstream-sync
description: |
  Bring the BaoCode fork (poying2018/baocode) up to date with upstream (baocode-dev/baocode):
  read the upstream release notes, fix the same defects in the fork with your own
  implementation, merge the upstream commits, repair the fork's release pipeline, and
  publish a verified release. Use when the user says "同步上游", "跟上上游", "看看上游更新日志",
  "修补上游修过的问题", "发版", "发布更新", or asks to bring the fork up to date with the
  upstream and publish. Do NOT use for ordinary feature work inside BaoCode, for debugging
  a single failing test, or for releasing a different project.
---

# BaoCode 上游同步与发布

把 fork 同步到上游，并发一个可用的版本。核心约束：**fork 有自己的发布链**（更新源是本仓库的
release、只发 Windows、签名私钥可 DPAPI 加密），所以"合上游"不等于"直接用上游的发布配置"。

## Inputs to collect

- **目标版本**：上游要同步到哪个 tag（默认取上游最新的 `v*` tag）
- **发布范围**：本 fork 当前只发 Windows 版（`.github/workflows/release.yml` 里 macos/linux job
  已删）。要发别的平台时先确认，再把对应 job 加回
- **破坏性确认**：删远端 release / tag / 改发布配置前，先说清范围（沿用本仓库的偏好：破坏性
  操作先确认，但不要问太多）

## 仓库现场（2026-10-22 实测）

| 项 | 值 |
|---|---|
| 仓库 | `F:\Projects\baocode`（origin=`poying2018/baocode`，upstream=`baocode-dev/baocode`）|
| 分支 | `main` = `dev`（发版前合流，发版后回灌 dev）|
| 工具 | Flutter 3.47.5 / Dart 3.13.4 在 `F:\Projects\tools\flutter` |
| 代理 | GitHub 访问优先直连（`HTTP_PROXY=''` + `NO_PROXY='*'`）；直连不通再找 Clash（`127.0.0.1:7897`），先 `Get-NetTCPConnection -LocalPort 7897 -State Listen` 确认它在跑 |
| 推送通道 | `ssh://git@ssh.github.com:443/poying2018/baocode.git`（HTTPS 的 schannel 握手会失败）|
| 签名私钥 | `F:\Projects\baocode-release-key\update-signing.key.enc`（DPAPI，本机账户绑定）|
| Secret | `BAOCODE_UPDATE_SIGNING_KEY`（本 fork 的名字；上游用 `UPDATE_SIGNING_KEY`）|
| 环境坑 | `TEMP=F:\Projects\tmp`；跑测试要 `NO_PROXY=*` 并清代理；原生资产需先注入 `vcvars64.bat` |

## Procedure

### 1. 读上游更新日志，列出要修的条目

```powershell
$env:HTTP_PROXY='http://127.0.0.1:7897'; $env:HTTPS_PROXY='http://127.0.0.1:7897'
gh api repos/baocode-dev/baocode/releases --jq '.[0:3][] | [.tag_name, .published_at] | @tsv'
gh api repos/baocode-dev/baocode/releases/tags/v1.5.0 --jq .body
```

对每条 **Fixed**，在本 fork 里定位是否同题存在。定位要落到根因（读代码、算坐标、查平台语义），
不能凭条目文字猜 —— 同一句描述在不同代码里根因常不同。定位不到就记为"该版本此条不适用"，
写清依据，不要硬凑一个改动。

### 2. 自己实现修复（不 cherry-pick 上游）

上游的修法只是参考。做法：读懂上游为何这样改，再在本 fork 的对应位置用**自己的实现**落地，
保持 fork 已有特性不丢。每处修复配一条回归测试；测试的断言要跨平台（Windows 上没有 `chmod`、
没有符号链接权限）。

已修过的三处（2026-10-22，勿重复劳动）：

| 上游条目 | 根因 | 修法 |
|---|---|---|
| 预览放大的图被裁在初始大小 | `InteractiveViewer` 的盒子 = 图片自身尺寸（1×1 时视口仅 1px）| viewer 铺满带边距的窗口、图片居中，箭头区仍在视口外 |
| 放大后标题栏按钮右缘点不到 | `_rect()` 的角点过了 zoom、尺寸没过（`box.size`）⇒ 上报的盒子比画的窄，右缘被系统当拖窗区 | 整矩形同过变换：`MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size)` |
| Windows 装语言服务器报"不是有效的 Win32 应用" | `which()` 把无扩展名候选排在 PATHEXT 前 ⇒ 命中 nvm 目录里 npm 的 Bash 脚本；`.cmd` 起的 node 在 cmd.exe 被杀后存活 | 只按 PATHEXT 匹配；npm 由 node 直跑 `npm-cli.js`；杀进程用 `taskkill /T` 收整棵树 |

### 3. 合并上游，保留 fork 特性

```powershell
git fetch upstream
git checkout dev
git merge upstream/main --no-edit --no-verify
```

合并后必查这几项（合并冲突和"静默丢失"都发生在这里）：

- **版本号**：pubspec 与 `lib/update/version.dart` 必须一致（`test/update/version_test.dart` 守这条）
- **更新源**：`lib/update/update_manifest.dart` 的 `defaultManifestUrl` 要指向**本仓库**的
  `releases/latest/download/latest.json`；`update_service.dart`、`update_controller.dart` 同理
- **下载链接基址**：`tool/release_manifest.dart` 的 `_releasesBase` 指本仓库的
  `releases/download`，且链接用 `version.marketing`（`v1.5.1`）——用 `toString()` 会得到
  `1.5.1+16`，而 tag 里没有 `+16`，链接会 404
- **DPAPI 私钥支持**：上游新版 `release_manifest.dart` 不认 `dpapi:` 前缀了，要把自己的
  `_dpapi()` / `--encrypt-key` / `--decrypt-key` 加回去
- **推广位**：上游可能带回来 `site/channels.json` 的第三方条目与资源文件，按用户要求删干净
  （条目 + 资源 + `site/featured/upstreams.json` 的列表 + 相关测试夹具）

冲突解决的原则：两边**同题**时取实现更完整的一方（本例里上游独立修好了标题栏 zoom，
修法与我的完全一致，直接取上游版）；只有一方有实现时保留自己那方。

**合并后必查 `tool/release_manifest.dart` 的选项解析**：上游的 `_parse` 不认
`--encrypt-key` / `--decrypt-key`，合并时若取了上游的解析器，这两个选项就**静默消失** ——
`_dpapiPrefix` 常量、`_readKey`、usage 文本都还在，看起来一切正常，但真去加密私钥时
"unknown option"。所以合并后要确认 `main()` 里还有：

```dart
if (options['encrypt-key'] case final path?) return _encryptKey(path, options['out']);
if (options['decrypt-key'] case final path?) return _decryptKey(path, options['out']);
```

（`test/tool/release_manifest_test.dart` 覆盖这两个选项，别删。）

### 4. 修好发布链（本 fork 不能直接用上游的）

上游的 `release.yml` 把成品发到官方 CDN `dl.baocode.dev`（Cloudflare R2），用上游的 Secret。
本 fork 没有 CDN 权限，Secret 名字也不同，**tag push 会全失败**。要改成：

- 上传改用 `gh release create` / `gh release upload`（本仓库的 release）
- Secret 改 `BAOCODE_UPDATE_SIGNING_KEY`
- 版本比较（"不旧于已发布版本"）读本仓库的 `releases/latest/download/latest.json`
- `share` job（测试者发 CDN）整段删掉
- manifest 只列实际要发布的平台（只发 Windows 时只 `--windows`）
- 上传步骤要传**全部** edition 的文件（`for file in out/BaoCode-*`），否则 channel 版的链接 404
- 远程服务端的 `.gz` 与 `servers.json` 也要上传（老版本应用按 VERSION 回溯下载）

`remote.yml`（reusable workflow）的 publish job 用 `environment: release` 拿写权限，
**不要**换成 `permissions:` —— 那样 GitHub 在解析期就报 `startup_failure`（tag push 一个
job 都不创建，而手动 dispatch 正常，因为那条路不跑 publish job）。

合并上游后要复查这两个 workflow 有没有被改回 CDN（上游的版本会）：

```powershell
Select-String -LiteralPath '.github/workflows/release.yml' -Pattern 'dl\.baocode\.dev|R2_|aws s3'
Select-String -LiteralPath '.github/workflows/remote.yml'   -Pattern 'dl\.baocode\.dev|R2_|aws s3'
```

有输出就是被改回去了（注释里的除外）。

改完用 actionlint 校验（比 YAML 解析严格，能查出 needs 悬空引用）：

```powershell
node <skill-creator目录>\scripts\lint-skill.js  # 只用于 skill 自身
actionlint .github/workflows/release.yml .github/workflows/remote.yml
```

### 5. 版本号与 tag

```powershell
dart run tool/bump_version.dart patch   # 1.5.0+15 -> 1.5.1+16（同时改 pubspec 与 version.dart）
```

tag **不带 build 号**：上游 1.5.0 起是 `v1.5.1`。workflow 校验 `GITHUB_REF_NAME == "v$marketing"`，
带 `+16` 会直接失败。发布说明手写 `release-notes/<版本>.en.md` 与 `.zh.md`（工具生成的是提交
标题直译，不可直接用），然后 `dart run tool/build_changelog.dart` 重新生成站点 changelog。

### 6. 发布

```powershell
git checkout main; git merge dev --no-edit --no-verify
git push ssh://git@ssh.github.com:443/poying2018/baocode.git main:main
git push ssh://git@ssh.github.com:443/poying2018/baocode.git dev:dev
git tag -f v1.5.1 HEAD
git push --force ssh://git@ssh.github.com:443/poying2018/baocode.git refs/tags/v1.5.1
```

tag push 触发 `Release` workflow。跑完把 `main` 的提交回灌 `dev`，两分支保持一致。

### 7. 验证（发完必做，不做等于没发）

```powershell
# 资产
gh api repos/poying2018/baocode/releases/tags/v1.5.1 --jq '.assets[].name'
# manifest
Invoke-RestMethod 'https://github.com/poying2018/baocode/releases/latest/download/latest.json'
# 每个链接可下载且大小一致
curl.exe -sIL --max-time 60 <url>   # 取最后一个 content-length
# 远程服务端的资产也要在（老版本应用按 VERSION 回溯下载）
curl.exe -sIL --max-time 60 'https://github.com/poying2018/baocode/releases/download/v1.5.1/baocode-server-linux-x64.gz'
```

再用仓库自己的代码做三件事（比肉眼看 JSON 可靠）：

1. **签名有效**：`UpdateSignature.verify(payload: UpdateSignature.payload(version:, platform:,
   size:, sha256:), signature:)` —— publicKey 用 `lib/update/update_signature.dart` 里内置的那个
2. **URL 策略放行**：`const UpdateUrlPolicy().allows(asset.url)` 必须为 true
3. **版本比较**：旧版（1.2.0+12 / 1.3.1+17 / 1.5.0+15）对已发布版本应 `newer: true`

## Output contract

- 一条合并提交（上游同步）+ 若干修复提交 + 一个发布提交；`main` 与 `dev` 指向同一 commit
- tag `v<版本>`（不带 build 号）指向发布提交
- release 在本仓库：Windows 安装包（standard + channel）+ 远程服务端资产 + `latest.json`
- 一份验证结果：资产清单、manifest 内容、每个链接的大小核对、签名有效性、版本比较
- 更新 `F:\Projects\_baocode开发上下文.md`（仓库现场表、发布链改造记录、踩过的坑）

## Failure handling

- **tag push 报 `startup_failure`**：多半是 reusable workflow 的权限写法（`permissions:` 替了
  `environment: release`）。先看 job 是否一个都没创建；再对比"同 commit 打不同 tag 名"排除
  tag 状态问题
- **CI 卡在某平台**：Linux arm64 在 QEMU 下启动冒烟测试偶发超时（15 秒），重跑该 job 即可
- **测试失败**：先分辨是回归还是平台限制。Windows 上 `chmod` 不存在、符号链接需要
  `SeCreateSymbolicLink` 权限 —— 用上游代码跑同一测试作基线对比，基线也失败就不是回归
- **合并后编译错**：多半是冲突解析时两段代码都留下了（括号/语句重复）。`flutter analyze`
  比肉眼快
- **下载链接 404**：manifest 列了但 release 里没那个资产（常见于 channel 版漏传）
- **改了 `.github/workflows/*.yml` 后 `git diff` 出现整文件变化**：多半是行尾变了
  （`core.autocrlf=true`，index 里是 LF、工作区是 CRLF），检查文件末尾换行与 mode
  （`git update-index --chmod=+x`）
- **改 `.minimax/skills/*/SKILL.md` 后 lint 报 "frontmatter.name is missing"**：文件被写成
  CRLF 了，lint 的 YAML 解析器按 `\n` 切行会认不出 `---`。改成 LF：

  ```powershell
  $f = '<skill 路径>/SKILL.md'
  [System.IO.File]::WriteAllText($f, [System.IO.File]::ReadAllText($f).Replace("`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
  ```

## Examples

**输入**："看看上游更新日志，修一下我们这边对应的问题，然后发版"

**要点**：读上游 `v1.5.0` 的 body → 对每条 Fixed 在 fork 里定位根因 → 找到同题的自己实现修复
（不 cherry-pick）→ 合并 `upstream/main`（冲突逐个解，保留更新源/DPAPI/推广位这些 fork 特性）→
改 `release.yml` 让它发到本仓库而不是官方 CDN → `bump_version` + 写双语发布说明 + 打
`v1.5.1` → 发布 → 按第 7 步逐项验证 → 更新开发上下文简报。
