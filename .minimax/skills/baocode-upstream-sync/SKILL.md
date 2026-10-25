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

#### 怎么核对"上游日志里的每一条，在 fork 里都实现了"

合并后别只看"提交合进来了" —— **fork 自己的改动可能盖掉了上游的实现**。用这个办法逐条查：

```powershell
# 1. fork 相对上游 main 的所有差异（只删不改的量 = 上游可能丢的东西）
git diff --numstat upstream/main HEAD -- lib/ packages/ tool/
# 2. 那些删除行，逐行看：地址替换、等价重构、自己的增强，还是真丢了实现
git diff upstream/main HEAD -- lib/ packages/ tool/ | Select-String '^-' | Where-Object { $_.Line -notmatch '^---' }
# 3. 上游 v1.6.0 之后又改过的文件（我们的合并也包含了，但要确认合并结果与 upstream/main 一致）
git diff --name-only v1.6.0 upstream/main
# 4. 某处两边同题（各自有修法）时，看合并后的代码是不是把两边的修法都保住了
git diff v1.6.0 HEAD -- <那个文件>
```

判读：`+` 多于 `-`，且删除行里没有"上游的功能逻辑"，就是**没丢**；反过来（有实质逻辑被删）
要逐条查清是被上游有意删掉的（如上游自己删了一个特性），还是合并出错。

**上游的日志不一定涵盖 tag 之后的提交** —— `git log v<上游tag>..upstream/main` 里的那些修复
也要写进自己的发布说明，否则用户看不到。

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

- **所有 workflow 都触发不了，报 `Actions has been disabled for this repository`（HTTP 422）**：
  这是 **fork 被 GitHub 禁用 Actions** 的状态（GitHub 为省算力，会自动禁用 fork 上的 workflow）。
  三个容易误判的地方：
  - `GET /repos/{owner}/{repo}/actions/permissions` 仍返回 `enabled: true` —— **不可信**
  - 仓库设置页（Settings → Actions → General）里**没有**启用开关 —— 别在那儿找
  - 推上去的**新 workflow 不会被注册**（workflow 列表里没有它）—— 这是最可靠的判据
  真正的入口在**仓库的 Actions 页**（`https://github.com/{owner}/{repo}/actions`）：页首有横幅
  **"Workflows on this fork have been disabled"**，里面是一个 `POST /{owner}/{repo}/actions/enable`
  的表单，按钮写着 "I understand my workflows, go ahead and re-enable them"。
  启用后 dispatch 与 tag push 都恢复。**这会消耗账户的 Actions 额度**（GitHub 每月给免费额度；
  账户的额度用完时 GitHub 会拒绝启动 run，报同一个错）。
  账户的额度与预算在 `https://github.com/settings/billing/usage` 与
  `https://github.com/settings/billing/budgets` —— 后者里每个产品的预算若是 $0，会显示
  "Usage blocked"，那就会把用量整个卡住（改预算需要有效的支付方式，GitHub Free 账户改不了）。
- **只发标准版时，渠道版的资产要一起清**：`release.yml` 对普通 tag（`v1.6.0`）默认
  `editions='["standard","channel"]'`，**两个版本都会建、都上传**。只删渠道版的安装包资产
  是不够的 —— `latest.json` 里还留着 `windows-x64-channel` 条目，它指向被删掉的资产，
  用户点了就是 404。要用本地工具重新生成再覆盖上传：
  ```powershell
  # 只传 --windows（不带 -channel），就只会有 windows-x64 一个 key
  dart run tool/release_manifest.dart --windows <安装包> --version <版本> `
      --notes-zh release-notes\<版本>.zh.md --notes-en release-notes\<版本>.en.md `
      --manifest latest.json
  gh release upload v<版本> latest.json --repo poying2018/baocode --clobber
  ```
  （渠道版的 `remote-latest.json` 一并删掉。）下次若只要标准版，用
  `workflow_dispatch` 传 `editions: standard`，省掉这一步善后。
- **CI 某个 job 因网络失败**（`curl: (56) Recv failure: Connection reset by peer` 之类），
  下游的 job 会全变 skipped、一个 release 都没发。`gh run rerun <run-id> --failed` 重跑那个
  job 即可，不必重来整条流水线。
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

## 备用路线：没有浏览器桥接时，用 CDP 自己开浏览器

DSH 的浏览器工具需要桥接（dsh-chrome 侧栏）连上才好用。连不上时，可以**自己起一个
Chrome 并用 CDP 协议驱动**（Node 24 自带 WebSocket，不用装包）：

```powershell
$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
Start-Process $chrome -ArgumentList @(
  '--remote-debugging-port=9222',
  "--user-data-dir=$env:LOCALAPPDATA\Google\Chrome\User Data",   # 复用登录态
  '--no-first-run', '--no-default-browser-check',
  '--proxy-server=http://127.0.0.1:7897',
  'https://github.com/settings/billing/budgets')
```

然后用 `http://127.0.0.1:9222/json/list` 拿标签页的 `webSocketDebuggerUrl`，用 WebSocket
发 `Runtime.evaluate`（求值 JS）与 `Page.navigate` / `Page.reload`。

要点：

- **React 的输入框**用 `Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,
  'value').set` 赋值，再派发 `input`/`change` 事件 —— 直接写 `.value` 不会触发框架更新。
- **同一 profile 只能起一个 Chrome**：第二个实例会被第一个接管、端口失效。换个 profile
  目录也会被合并 —— 要独立 profile 就先把所有 chrome 进程停掉。
- **GitHub 会因出口 IP 变化而使 session 失效**（页面出现 "You signed in with another tab
  or window" / "You can't perform that action at this time"）。Clash 的「自动选择」组会
  在多个节点间漂，IP 从 .193 变成 .194 就触发。**每次操作前先 `Page.reload`**，让页面拿到
  最新的 session，然后立刻操作。
- **GitHub 的设备码页**（`/login/device`）在已登录的浏览器里是 8 个单字符输入框
  （`user-code-0` … `user-code-8`，第 4 个是固定的 `-`），填完后要**点那个表单自己的
  Continue**（`form[action*="/login/device/confirmation"]` 里的 submit），不是页面上任意
  一个同名按钮 —— header 的搜索区也有 Continue。
- **token 不能当网页密码用**了（GitHub 已不支持），所以在干净 profile 里登录不了；
  要用有登录态的 profile。

## Examples

**输入**："看看上游更新日志，修一下我们这边对应的问题，然后发版"

**要点**：读上游 `v1.5.0` 的 body → 对每条 Fixed 在 fork 里定位根因 → 找到同题的自己实现修复
（不 cherry-pick）→ 合并 `upstream/main`（冲突逐个解，保留更新源/DPAPI/推广位这些 fork 特性）→
改 `release.yml` 让它发到本仓库而不是官方 CDN → `bump_version` + 写双语发布说明 + 打
`v1.5.1` → 发布 → 按第 7 步逐项验证 → 更新开发上下文简报。
