# Codex 内核：BaoCode Codex 侧的开发资料

面向在 BaoCode Codex 上开发的读本。代码位置 `lib/kernel/codex/`，共享框架在
`lib/kernel/`，产品身份在 `packages/bao_remote/lib/src/platform/product.dart`。

> **两个产品现在住在两个仓库**：本仓库（`poying2018/baocode`）发 BaoCode Claude；
> BaoCode Codex 在 `poying2018/baocode-codex`，它自己的发布链与版本号（见
> [release.md 4.1](release.md#41-一个仓库一个产品)）。两仓同源，共享的代码靠
> cherry-pick 同步——本文讲的内核机制两边都成立，行号以各自仓库为准，改动后自行校正。

先读这一段，能省掉后面很多摸索：

- **一份源码，两个产品**：`baocode-claude.exe` 是 BaoCode Claude（Claude Code 内核），
  `baocode-codex.exe` 是 BaoCode Codex（Codex 内核）。**产品由可执行文件的名字决定**，
  其它一切（数据目录、窗口类、注册表、更新通道、URL scheme、Stash、钥匙串、
  远端服务器）都从这一个事实派生。见 `product.dart` 与
  `windows/runner/app_identity.cpp`——原生侧读的是同一个名字，两边不会各说各话。
- **Codex 才是 agent**：这个应用自己没有推理能力，Codex CLI 才是。应用做的是
  `codex app-server`（JSON-RPC 2.0 over stdio）的界面。**想「让应用自己推理」不在
  产品范围内。**
- **协议是散落的裸字符串**：没有集中的常量表。改协议前先读 §3，那是当前的完整清单；
  官方 schema 在 `F:\Projects\tmp\codex-schema\`（不在仓库里）。

---

## 1. 分层与调用链

```
UI  chat/chat_session.dart
    │  KernelEvent 流（带 seq）＋ AgentKernel 能力接口
    ▼
CodexKernel              lib/kernel/codex/codex_kernel.dart   （2860 行）
    │  进程生命周期 / 选项 / 权限 / 配额 / MCP / 目标 / 历史 / 回放
    ├──────────────► CodexTransport   codex_transport.dart   （Adaptee 契约）
    │                 一条消息一个 JSON 对象：`{id, method, params}`
    │                 响应 `{id, result}`，通知 `{method, params}`，
    │                 服务端的请求 `{id, method, params}`（审批、提问）
    └──────────────► CodexTransportFactory   codex_transport_factory.dart
                      ├─ ProcessCodexTransport   codex_process_transport_io.dart
                      │    本机 `codex app-server --stdio` 子进程
                      └─ RemoteCodexTransport    lib/remote/remote_codex.dart
                           远端主机上的同一个 app-server
```

一次完整的来回：

```
用户发消息
  ChatSession.send → CodexKernel.send
    → _begin → _start → _ensureThread（thread/start 或 thread/resume）
    → _turnRequest → turn/start
    → _request（transport.request）等 {turn:{id}}

CLI 输出
  ProcessCodexTransport._line（codex_process_transport_io.dart:308）
    → transport.messages 流
    → CodexKernel._receive（L1719）
        ├─ 带 method → 通知：turn/started、item/*、thread/tokenUsage/updated …
        └─ 带 id + method → 服务端的请求：_serverRequest（L2058）
             └─ InteractionRequested → UI 的审批卡片
用户批准
  ChatSession.answer → CodexKernel.answer（L1143）
    → 写回 {'id': <rpcId>, 'result': {'decision': 'accept' | 'acceptForSession' | 'decline'}}
```

**改代码前先定位到层**：协议字段变了 → 传输层（`CodexTransport`）；交互流程变了 →
内核；报文语义变了 → 内核里的分派（`_receive` 的 `switch`）。

---

## 2. 文件索引

### 协议与传输

| 文件 | 职责 | 关键符号 |
| --- | --- | --- |
| `codex_transport.dart` | Adaptee 契约 + 启动参数 | `CodexTransport`(L4)、`CodexLaunch`(L47)、`CodexUnavailable`、`CodexRequestError` |
| `codex_transport_factory.dart` | 传输的共享与启动时机 | `CodexTransportFactory`(L16)：`of(context)`(L54)、`stopAll()`(L37)、`_home()`(L78)、`_seed()`(L83) |
| `codex_process_transport_io.dart` | 本机子进程 | `ProcessCodexTransport`(L11)：`start`(L46)、`_line`(L308)、`_endTree`(L414)；`locateCodex()`(L119) |
| `remote_codex.dart` | 远端主机的同一个服务器 | `startRemoteCodex`(L12)、`RemoteCodexTransport`(L47) |
| `mock_codex_transport.dart` | 按真实报文的假传输 | `MockCodexTransport`(L10) |

### 会话与目录

| 文件 | 职责 |
| --- | --- |
| `codex_catalog.dart` | 服务器上的会话目录（`thread/list`、`thread/delete`） |
| `lib/remote/remote_codex.dart` | 远端会话 |

### 产品身份

| 文件 | 职责 |
| --- | --- |
| `packages/bao_remote/lib/src/platform/product.dart` | **两个产品的全部身份**：名字、scheme、AppId、注册表键、清单文件、安装包文件名、浏览器宿主名、钥匙串服务名、是否带 Claude Code |
| `windows/runner/app_identity.cpp` | 原生侧：窗口类、标题、注册表键、单实例互斥量 |
| `tool/set_product.dart` | 把 `windows/CMakeLists.txt` 的 `BINARY_NAME` 写成这个产品的 |

---

## 3. 协议契约

**这份契约在源码里是散落的裸字符串，没有集中的常量表。** 下表是当前的完整清单，
改动 CLI 协议时先对照这里。

### 3.1 客户端 → 服务端的请求（内核发的）

| method | 参数 | 位置 | 用途 |
| --- | --- | --- | --- |
| `initialize` | `clientInfo`、`capabilities.experimentalApi` | `codex_process_transport_io.dart:53` | 握手；**服务端的 `initialized` 通知在收到结果后发** |
| `thread/start` | `cwd`、`model`、`serviceTier`、`developerInstructions` | L657、L1393 | 新会话 |
| `thread/resume` | 同上 + `threadId`、`excludeTurns:true` | L642 | 继续旧会话（历史另取，见下） |
| `thread/fork` | `threadId`、`lastTurnId?`、`cwd`、`excludeTurns:true` | L1320 | 复制会话 |
| `thread/name/set` | `threadId`、`name` | L1332、L1357 | 改名 |
| `thread/revert` | `threadId`、`beforeTurnId` | L1411 | 回退到某一轮 |
| `thread/turns/list` | `threadId`、`limit`、`cursor?`、`itemsView:'full'`、`sortDirection` | L934、L956 | 读历史（分页） |
| `thread/list` | `cwd?`、`limit`、`sortKey` | `codex_catalog.dart:84` | 会话目录 |
| `thread/delete` | `threadId` | `codex_catalog.dart:72` | 删会话 |
| `turn/start` | 见下 | L569 | 开始一轮 |
| `turn/interrupt` | `threadId`、`turnId` | L746 | 打断 |
| `review/start` | `threadId`、`delivery:'inline'`、`target` | L558 | `/review` |
| `thread/compact/start` | `threadId` | L549 | `/compact` |
| `model/list` | `limit`、`cursor?` | L757 | 模型目录（分页） |
| `mcpServerStatus/list` | `threadId?` | L1439 | MCP 服务器 |
| `mcpServer/oauth/login` | `name`、`threadId` | L1513 | 给 MCP 服务器登录 |
| `config/value/write` | `keyPath`、`mergeStrategy`、`value` | L1484 | 改配置（如启停 MCP） |
| `config/mcpServer/reload` | — | L1489 | 重载 MCP |
| `account/rateLimits/read` | — | L1591 | 账号配额 |
| `fuzzyFileSearch` | `query`、`roots` | L1547 | `@` 文件建议 |

`turn/start` 的参数（`codex_kernel.dart:569`）：

```
threadId, clientUserMessageId, input[], model, effort?, serviceTierForTurn?,
approvalPolicy, sandboxPolicy
```

- `input[]` 是 `UserInput[]`：`{'type':'text','text':…}` 与
  `{'type':'image','url':'data:…;base64,…'}`。**计划模式的说明也是一条 text**
  （`_planNote`，见 §4）。
- `approvalPolicy` 是 `untrusted | on-request | never`；本应用只发 `on-request`
  与 `never`。
- `sandboxPolicy` 是 `{'type':'readOnly','networkAccess':false}` /
  `{'type':'workspaceWrite','networkAccess':false,'writableRoots':[…]}` /
  `{'type':'dangerFullAccess'}`。

### 3.2 服务端 → 客户端的请求（要回答的）

| method | 内核怎么处理 | 回写的形状 |
| --- | --- | --- |
| `item/commandExecution/requestApproval` | 审批卡片（L2064） | `{'decision':'accept'|'acceptForSession'|'decline'}` |
| `item/fileChange/requestApproval` | 审批卡片（L2079） | 同上 |
| `item/permissions/requestApproval` | 审批卡片（L2108） | `{'permissions':{…},'scope':'turn'|'session'}` |
| `item/tool/requestUserInput` | 提问卡片（L2121） | `{'answers':{id:{'answers':[…]}}}` |
| `mcpServer/elicitation/request` | 表单卡片（L2165） | `{'action':'accept'|'decline'|'cancel','content':{…}}` |
| `item/tool/call` | 本应用不为服务器跑工具（L2167） | `{'success':false,'contentItems':[…]}` |
| `account/chatgptAuthTokens/refresh` | 本应用不持有 ChatGPT 令牌（L2183） | JSON-RPC 错误 |
| 其它 | 一律回 `-32601`（L2194） | **不留悬挂请求** |

### 3.3 服务端 → 客户端的通知

_receive`（`codex_kernel.dart:1719`）分派：

| method | 处理 |
| --- | --- |
| `turn/started` / `turn/completed` | 轮次的开始与结束；`status` 是 `completed/interrupted/failed/inProgress` |
| `error` | `willRetry:true` 是警告，否则是错误 |
| `thread/name/updated` | 改名 |
| `thread/settings/updated` | 模型、上游、effort、tier、协作模式、沙箱与审批策略 |
| `serverRequest/resolved` | 服务器自己把一个请求解决了：**关掉卡片，不要回写**（L1770） |
| `thread/deleted` / `thread/closed` | 会话没了：内核失败（L1775） |
| `turn/plan/updated` | 计划步骤 |
| `thread/goal/updated` / `thread/goal/cleared` | 目标 |
| `thread/prediction/updated` | 下一条提示建议 |
| `item/started` / `item/completed` | 条目：`agentMessage`、`reasoning`、`plan`、`commandExecution`、`fileChange`、`mcpToolCall`、`webSearch`、`collabAgentToolCall`、`imageGeneration`、`contextCompaction` |
| `item/agentMessage/delta` | 助手的字 |
| `item/reasoning/summaryTextDelta` | 思考的**摘要** |
| `item/reasoning/textDelta` | 思考的**正文**（L1849） |
| `item/plan/delta` | 计划的字 |
| `item/commandExecution/outputDelta` | 命令的输出 |
| `thread/tokenUsage/updated` | 上下文窗口、token 数 |
| `account/rateLimits/updated` | 账号配额（服务器推来的） |
| `warning` / `guardianWarning` / `deprecationNotice` | 提示 |
| `mcpServer/startupStatus/updated` | 一个 MCP 服务器的状态 |

**没有处理的（约 70 个）**：实时语音、插件、市场、hook、fs、command/exec 等。
它们只是不用，UI 也没有依赖它们的表面。

### 3.4 报文的形状

- `thread/tokenUsage/updated`：`tokenUsage.total/last.totalTokens`、
  `modelContextWindow`、`inputTokens`、`cachedInputTokens`、`cacheWriteInputTokens`。
- `turn/completed`：`turn.id`、`turn.status`、`turn.error.message`、`turn.error.codexErrorInfo`。
- `item/completed`（`commandExecution`）：`command`、`commandActions`、`aggregatedOutput`、
  `exitCode`、`status`（`inProgress/completed/failed/declined`——**`declined` 也是终态**，
  否则卡片会一直显示「在运行」）。
- `item/completed`（`fileChange`）：`changes[].path`、`changes[].diff`、
  `changes[].kind.type`（`add/delete/update`）。
- `item/completed`（`reasoning`）：`summary[]` 与 `content`；直播时先到的是 delta，
  结束时以缓冲里的为准。

---

## 4. 能力接口矩阵

`CodexKernel` 声明的接口（`codex_kernel.dart:23`）。**UI 按接口显示功能，没声明就没入口。**

| 接口 | 用途 | Claude Code | Codex |
| --- | --- | --- | --- |
| `AgentKernel` | 基础生命周期 | ✅ | ✅ |
| `SelectsModel` / `SelectsMode` / `SelectsPermission` | 模型/模式/权限选择器 | ✅ | ✅ |
| `SelectsEffort` / `SelectsFast` | 思考强度、Fast 档 | ✅ | ✅ |
| `SelectsContextSize` | 200K / 1M 窗口 | ✅ | ❌ |
| `StartsPlans` | 计划卡片「开始构建」 | ✅ | ✅（见下） |
| `ProvidesCommands` | `/` 命令列表 | ✅ | ✅ |
| `SuggestsFiles` | `@` 文件建议 | ✅ | ✅ |
| `ReportsContext` / `ReportsUsage` / `ReportsUsageLimit` | 上下文/用量/限额 | ✅ | ✅ |
| `SuggestsPrompts` | 下一条提示建议 | ✅ | ✅ |
| `ManagesMcpServers` | MCP 列表与管理 | ✅ | ✅ |
| `QueuesMessages` | 排队消息的撤回/插队 | ✅ | ✅ |
| `RewindsConversation` / `ForksConversation` / `RenamesSession` | 回退/分叉/改名 | ✅ | ✅ |
| `LoadsHistory` | 长会话按需读更早 | ✅ | ✅ |
| `AcceptsImages` | 带图消息 | ✅ | ✅ |
| `RunsBackgroundTasks` | 后台任务卡片 | ✅ | ❌ |
| `RevertsChanges` | 回退文件改动 | ✅ | ❌ |
| `ConfirmsModelSwitch` | 切模型会重启时先问 | ✅ | ❌ |

**没有的三个是有原因的**：Codex 没有后台任务，不能把文件放回去；切模型不重启会话。

### 计划模式（`plan`）

**app-server 没有「协作模式」这个参数**（`turn/start` 里没有 `collaborationMode`，
也没有 `collaborationMode/list` 这个方法）。所以计划是这样做的：

- 选「Plan」时，这一轮用**只读沙箱**（`readOnly`）与 `approvalPolicy:'never'`，
  并且消息里多一条说明（`_planNote`，L621）：「想清楚怎么做，别改文件」。
- 用户点「开始构建」→ `startBuilding()`（L1246）把模式改回 `agent`，
  并把计划标为已批准；**下一条消息**带上 `_buildNote`（L627），告诉它照着做。
- 这个模式曾经是坏的（发的参数服务器不认），现在是对的了。

---

## 5. 选项与设置键

### settings.json

| 键 | 作用 |
| --- | --- |
| `chat.queuedMessages` | 排队消息何时取用（`afterTurn` / `duringTurn`），`lib/kernel/queued_messages.dart` |
| `chat.promptSuggestions` | 是否请求下一条提示建议 |
| `chat.commitAttribution` | 提交/PR 署名 |

**Codex 产品没有自己的设置项**：它没有 Claude Code 的那两组（内核、路径），
也没有「模型目录」那类——模型由服务器说。

### 每模型独立的选项记忆

键格式 `<kind>@<model>`（`agent_kernel.dart:160`）：`effort@<model>`、
`fast@<model>`。Codex 的 effort 档由 `model/list` 的 `supportedReasoningEfforts`
给出（`codex_kernel.dart:777`），Fast 档是 `serviceTiers`。

### 模式与审批档位

- 工作模式：`agent` / `ask` / `plan`
- 审批模式：`ask` / `readOnly` / `auto` / `fullAccess`

映射到协议：`approvalPolicy`（`never` 或 `on-request`）与 `sandboxPolicy`
（`readOnly` / `workspaceWrite` / `dangerFullAccess`）。见 `_turnRequest`（L544）。

---

## 6. 扩展点：常见任务改哪里

| 想做的事 | 改哪里 |
| --- | --- |
| 支持一种新工具的卡片样式 | `_itemStarted` / `_itemCompleted` 的 `switch (item['type'])` |
| CLI 报文的种新 type/subtype | `_receive` 的 `switch (method)`；语义复杂的放 `_itemCompleted` |
| 新的交互（提问/审批/表单） | `_serverRequest` 加分支 → `InteractionRequested` → `answer()` 加回写分支 |
| 服务端要审批的新东西 | `_serverRequest` 加分支 + `answer()` 的回写形状 |
| 换一个 Codex 来跑 | 环境变量 `BAOCODE_CODEX_COMMAND`（`codex_process_transport_io.dart:139`）：一行命令，如 `dart F:\path\tool\codex_stub.dart` |
| 换个产品的身份 | `packages/bao_remote/lib/src/platform/product.dart`（一处） |

---

## 7. 测试

```sh
flutter test test/kernel/codex_kernel_test.dart   # 内核的小件
flutter test test/kernel_test.dart                 # 内核的主体（Codex adapter 那一组）
flutter test test/codex_stub_test.dart             # 对着真进程跑一整轮
flutter test test/settings/product_table_test.dart  # 两个产品的身份
flutter test test/codex_live_test.dart             # 对着真的 Codex（CODEX_LIVE=1）
```

| 文件 | 覆盖 |
| --- | --- |
| `test/kernel_test.dart`（Codex adapter 那一组） | 选项、权限、计划、审批、回放、配额、MCP |
| `test/kernel/codex_kernel_test.dart` | 项目目录没了之后的通知 |
| `test/codex_stub_test.dart` | **真进程**：握手、模型、一轮、审批、回复 |
| `test/settings/product_table_test.dart` | 两个产品的身份 |
| `test/codex_live_test.dart` | 打真的 Codex CLI（需 `CODEX_LIVE=1` 与装好的 Codex） |

**`tool/codex_stub.dart` 是这个仓库里最要紧的一件测试工具**：它照着 app-server
的协议说话（JSON-RPC over stdio），所以适配器可以在**没有 Codex** 的机器上跑起来。
它也是「产品能不能用」的证据：改完协议，跑它。

按 `CLAUDE.md` 的约定：**只跑跟改动相关的测试**，全量套件慢。

---

## 8. 已知陷阱

写这块代码时，这些坑已经在源码里留了痕迹。

### 8.1 id 的空间是共用的

服务器数它自己的 id，我们的请求也带 id，而**协议里 id 既可以是字符串也可以是
整数**。曾经内核把「带整数 id 的消息」一律当成自己请求的答复，于是服务器的一次
审批（id 恰好撞上）就把我们的请求答复掉了——模型列表拿不到，整个初始化失败，
而审批永远等不到回答，一轮挂死。

现在：**本应用的请求用字符串 id**（`baocode-<n>`），**一条消息是不是答复，看它的
形状**（有 `result`/`error` 而没有 `method`），不靠数字。（`codex_process_transport_io.dart:308`、
`remote_codex.dart:117`）

### 8.2 协议里没有的参数会让整个请求失败

`runtimeWorkspaceRoots`（`thread/start`）与 `collaborationMode`（`turn/start`）
都不在协议里。发了前者，`thread/start` 可能整个失败——**这个应用就起不来了**。
改这两个请求时，先对着 `F:\Projects\tmp\codex-schema\` 的 schema 看一眼。

### 8.3 静态全局状态

`_accountLimits` / `_limitsState` / `_limitsFetchedAt`（L386）是**所有会话共用的**
（账号级的配额本就一样），但测试里要记得它们是全局的。`_live`（L390）也一样。

### 8.4 判据不一致

- `usageLimitApplies` 看**选中的模型**的上游，`_modelProvider` 是服务器报的那个。
- 计划模式没有服务器自己的开关，靠消息里的一条说明——所以它**只在会话里有效**，
  不是服务器的状态。

### 8.5 消息与状态

- `answer()` 先把审批项从 `_interactions` 里拿走，再回写。进程刚死时回写不到，
  UI 已经以为答复过了。
- `_endTurn`（L2665）把还在流的思考与计划**结掉**：计划结的时候带上它的字
  （否则卡片是空的），思考结的时候用缓冲里的字。
- 被拒绝的命令（`status:'declined'`）是**终态**：卡片不能停在「在运行」。

### 8.6 复杂度债

`codex_kernel.dart` 2860 行承担生命周期、选项、权限、配额、MCP、目标、历史、回放
十类职责；协议的类型是散落各处的裸字符串，**没有集中的常量表**——改协议要全局搜索。

---

## 9. 产品身份：codex 产品与 BaoCode Claude 的分别

两个产品是**两份程序**，不是一份程序的两个开关。改了任何一处与身份有关的地方，
问一句「BaoCode Claude 那边还成立吗」。

| 方面 | BaoCode Claude（`poying2018/baocode`） | BaoCode Codex（`poying2018/baocode-codex`） |
| --- | --- | --- |
| 可执行文件 | `baocode-claude.exe` | `baocode-codex.exe` |
| 数据目录 | `%APPDATA%\baocode` | `%APPDATA%\baocode-codex` |
| 窗口类 / 标题 | `FLUTTER_RUNNER_WIN32_WINDOW_claude` / BaoCode Claude | `…_codex` / BaoCode Codex |
| 注册表 | `Software\BaoCode` | `Software\BaoCodeCodex` |
| 安装 | AppId `{6fdd732b-…}`，目录 `BaoCode` | AppId `{3c9e2b14-…}`，目录 `BaoCodeCodex` |
| 安装包文件名 | `BaoCodeClaude-<版本>-setup.exe` | `BaoCodeCodex-<版本>-setup.exe` |
| URL scheme | `baocode://` | `baocode-codex://` |
| 更新清单 | `latest.json` | `latest-codex.json` |
| 浏览器宿主 | `dev.baocode.browser` | `dev.baocode-codex.browser` |
| Stash | `~/BaoCode/Stash` | `~/BaoCodeCodex/Stash` |
| 钥匙串服务 | `BaoCode` | `BaoCode Codex` |
| 远端服务器 | `baocode-server-*` | `baocode-codex-server-*` |
| 内核 | Claude Code | Codex |

**版本号也从分家起各走各的**：BaoCode Claude 在本仓库从 1.9.x 起步，
Codex 在它自己的仓库里（它已发布过 1.7.x）——两边的 build 号不再共用一条序列。

**BaoCode Claude 改过名字**：它以前叫 BaoCode，可执行文件是 `baocode.exe`。
改名只改了**名字**（显示名、可执行文件名、安装包文件名），
**没有改**它的安装 id、数据目录、更新通道、链接与钥匙串——
所以 1.7.0 是它的一次**升级**，不是旁边多了一个程序。
（原生侧因此有两处「例外」：注册表键与单实例互斥量对 Claude Code 产品**保持原样**，
否则旧版留下的设置会被丢在后面。）

**这些都从一处来**：`packages/bao_remote/lib/src/platform/product.dart`。
原生侧（窗口类、注册表键、单实例互斥量）读的是同一个可执行文件的名字
（`windows/runner/app_identity.cpp`），所以两边不会各说各话。

**开发时的两个坑**：

- `tool/set_product.dart` 写的是 `windows/CMakeLists.txt` 的 `set(BINARY_NAME …)`，
  **换产品后要清 CMake 缓存**（`tool/build_windows.dart` 自动做），否则报
  “No target baocode”。
- 清理开发进程**只能按路径**：`Get-Process baocode-codex | Where-Object { $_.Path
  -like 'F:\Projects\baocode\build\*' }`——按名字杀会杀掉用户自己装的那一份。

---

## 10. 代码风格

本仓库的注释是「意图说明书」而非「代码复述」：解释**为什么这样写**、**踩过什么坑**、
**什么情况下会失效**。写新代码时沿用这个密度 —— 一个 `switch` 分支的注释应当回答
「为什么这个 case 和别的不同」，而不是复述 case 的名字。

其它约定：

- 面向用户的文案走 `lib/l10n/`，不要在 kernel 里硬编码中文/英文。
- 路径处理统一用 `package:path`；远程路径一律 `p.posix`。
- 跨进程边界的对象不要强转：`as Map` / `as int` 之前先判类型，服务端返回类型会变。
- 新增能力接口记得同时更新 `lib/chat/chat_session.dart` 的能力探测分支，
  否则 UI 不会显示。
