# Claude Code 内核：BaoCode 侧的开发资料

面向在 BaoCode 上开发 Claude Code 适配的读本。代码位置 `lib/kernel/claude_code/`，
共享框架在 `lib/kernel/`。行号以本仓库 main 为准，改动后请自行校正。

先读这一段，能省掉后面很多摸索：

- BaoCode **没有自己的 agent**。Claude Code 才是 agent，BaoCode 只做它的界面。
  任何「让 BaoCode 自己推理」的想法都不在产品范围内。
- 两个产品如今住在两个仓库：本仓库发 BaoCode Claude（`baocode-claude.exe`，带
  Claude Code 内核），Codex 内核在 `poying2018/baocode-codex`（`baocode-codex.exe`）。
  产品名决定内核，数据目录、注册表、进程名都随之分开。见
  `lib/kernel/kernel_registry.dart:55-62` 与 `tool/set_product.dart`。
  **开发 Claude Code 内核时不要引入 Codex 依赖**。
- 内核通过**能力接口**（facet）暴露自己实现了什么，UI 只显示已声明的能力。
  加功能的第一步永远是「实现哪个接口」，而不是「改 UI」。

---

## 1. 分层与调用链

```
UI  chat/chat_session.dart
    │  KernelEvent 流（带 seq）＋ AgentKernel 能力接口
    ▼
ClaudeCodeKernel            lib/kernel/claude_code/claude_code_kernel.dart   （3612 行）
    │  进程生命周期 / 选项 / 权限 / 配额 / MCP / 目标 / 历史 / 回放
    ├──────────────► ClaudeTranslator   claude_code_translator.dart          （2003 行）
    │                 纯翻译：CLI 报文 → KernelEvent，不碰进程
    ├──────────────► ControlChannel      control_channel.dart                （96 行）
    │                 双向请求/响应配对，按 request_id
    └──────────────► ClaudeCodeTransport claude_code_transport.dart          （Adaptee）
                        ├─ ProcessTransport      process_transport_io.dart    本机 CLI 子进程
                        ├─ DartCoreTransport     dart_core_transport_io.dart 自研 bao_agent isolate
                        └─ RemoteClaudeTransport remote/remote_claude.dart    SSH 远端
```

一次完整的来回：

```
用户发消息
  ChatSession.send → ClaudeCodeKernel.send (L836)
    → _submit (L877) → _beginTurn (L990) → TurnStarted
    → _write (L932) → _whenReady (L707) → transport.write({'type':'user', ...})

CLI 输出
  ProcessTransport._line (process_transport_io.dart:180)
    → messages 流 → ClaudeCodeKernel._receive (L1660)
        ├─ type=control_response → ControlChannel.receive (control_channel.dart:54)
        └─ 其它 → _handle (L1671)
             ├─ assistant / stream_event → ClaudeTranslator.translate (L306)
             │      → ItemUpserted / TextDelta / ItemCompleted / FileEdited / TodosReported ...
             └─ result → _result (L1882) → _endTurn (L999) → TurnEnded

用户批准工具
  ChatSession.answer → ClaudeCodeKernel.answer (L1417)
    → ControlChannel.respond (control_channel.dart:74)
    → CLI 的 can_use_tool 收到 behavior / updatedInput / updatedPermissions
```

**改代码前先定位到层**：协议字段变了 → translator；交互流程变了 → kernel；
字节/进程变了 → transport。

---

## 2. 文件索引

### 协议与传输

| 文件 | 职责 | 关键符号 |
| --- | --- | --- |
| `claude_code_transport.dart` | Adaptee 契约 + 启动参数模型 | `ClaudeCodeTransport`(L12)、`ClaudeExit`(L30)、`ClaudeLaunch`(L47)、`ClaudeTransportFactory`(L334) |
| `control_channel.dart` | 控制通道：请求/响应按 id 配对 | `ControlChannel`(L17)：`request`(L26)、`receive`(L54)、`respond`(L74)、`refuse`(L83)、`failAll`(L89) |
| `process_transport_io.dart` | 本机子进程 | `ProcessTransport`(L19)：`start`(L94)、`_line`(L180)、`_finish`(L213)、`_endTree`(L248)；`ClaudeProcessRegistry`(L260) |
| `dart_core_transport_io.dart` | 内置 bao_agent 核心（isolate） | `DartCoreTransport`、`engineOptions()` |
| `local_claude_io.dart` | 本机 CLI 的定位/下载/安装 | `LocalClaude`(L25)：`locate`(L72)、`status`(L50)、`rejectTooOld`(L90) |
| `mock_claude_code_transport.dart` | 按真实 CLI 报文回放的假传输 | `MockClaudeCodeTransport`(L11)：`_control`(L125)、`_script`(L566) |

### 配置 / 认证 / 存储

| 文件 | 职责 | 关键符号 |
| --- | --- | --- |
| `claude_core_setting.dart` | 「内核」开关：内置核心 or CLI | `ClaudeCore`(L5)、`settingKey='claudeCode.core'` |
| `claude_path_setting.dart` | `claudeCode.path` 与状态类型 | `ClaudePathSetting`(L6)、`LocalClaudeStatus` 家族 |
| `claude_install_progress.dart` | 下载进度通知 | `LocalClaudeInstall`(L25) |
| `claude_onboarding_io.dart` | 原子改写 `~/.claude.json` 的 onboarding 标志 | `prepareClaudeOnboarding()`(L12) |
| `claude_storage_io.dart` | 会话目录（`SessionCatalog`） | `ClaudeStorage`(L9)：`projects`/`sessionsIn`/`goal`/`fork` |
| `turn_stats_io.dart` | 每轮耗时/用量落盘（CLI 自己不记） | `TurnStats`(L13)、`TurnStatsFiles` |

### 功能子模块

| 文件 | 职责 |
| --- | --- |
| `claude_code_translator.dart` | **报文 → KernelEvent 的全部语义**。工具映射、diff 生成、任务/子代理、计划、目标 |
| `claude_goal.dart` | `/goal` 状态机的纯函数层：`hookedGoal`/`keptGoal`/`goalInEffect` |
| `claude_elicitation.dart` | MCP elicitation 的 schema → 问题 → 回值 |
| `claude_sdk_tools.dart` | 应用自有 MCP 工具（浏览器、图像）注入与应答 |
| `claude_haiku.dart` | 小任务的一次性 Haiku 调用（提交信息、标题） |
| `usage_limit.dart` | 限额重置时间的文本解析 |
| `local_time_zone_io.dart` | 本机 IANA 时区（Windows 返回 null） |

### 远程

`lib/remote/remote_claude.dart`：`startClaude`、`readClaudeHistory(Page)`、
`readClaudeGoal`、`forkClaudeSession`、`askRemoteHaiku`、`remoteModelEnvironment`、
`ClaudeCatalog`、`RemoteClaudeTransport`。

### 2.5 内置的 Claude Code（随包分发）

应用自带一份 Claude Code，装好即有，用户不用另装、也不用等第一次对话时的下载。

| 文件 | 职责 |
| --- | --- |
| `lib/kernel/claude_code/claude_bundle.dart` | **在哪找**这份内置副本（应用侧，路径与平台相关） |
| `packages/bao_remote/.../claude_release.dart` | `BundledClaude`：一份副本长什么样（`VERSION` + 二进制） |
| `packages/bao_remote/.../claude_runtime.dart` | **选哪一份**、以及太旧时怎么办 |
| `tool/build_windows.dart` | **怎么打进去**：`_claudeVersion` / `_claudeSha256` / `_putClaude()` |

**在哪找**（`ClaudeBundle.find()`，顺序与 `bundledServerBinaries` 一致）：

1. 环境变量 `BAOCODE_CLAUDE_BUNDLE_DIR`
2. macOS：`<app>/Contents/Resources/claude`
3. 可执行文件旁边的 `claude/`（**Windows 安装后就是这里**）
4. 可执行文件旁边的 `data/claude/`
5. 当前目录下的 `build/claude/`
6. 可执行文件所在的、名为 `build` 的上级目录下的 `claude/`（debug 构建）

**选哪一份**（`ClaudeRuntime.locate()`，从新到旧）：

```
设置里指定的路径 (claudeCode.path)
  → 用户自己装的（其中新的优先）
  → 应用内置的那份
  → BaoCode 下载的那份
```

- 内置的那份**不自我更新**（`DISABLE_AUTOUPDATER=1`，否则它会往用户的 `~/.local`
  里塞一份），也不会触发每日检查更新的下载。
- 用户自己装的那份**优先于**内置的：用户装了新版就用他的。
- 只要内置的那份在，就**永远不会走到下载**。

**太旧时怎么办**（`ClaudeRuntime.rejectTooOld()`）：内置的那份拒绝了 BaoCode 传的
选项（`--include-partial-messages`、`--thinking-display` 等）时，它没法被替换
（它在安装包里），于是**下载一份新的**来用，并把内置那份的版本记为下限
（`_floor`），以后不再选它。

**构建时怎么打进去**（Windows，`tool/build_windows.dart`）：

- 版本钉在 `_claudeVersion`，SHA-256 钉在 `_claudeSha256`：构建只会带上那一份。
- 下载一次缓存到 `build\claude\`，之后直接用缓存。
- 落到 `<bundle>\claude\claude.exe` + `<bundle>\claude\VERSION`；Inno Setup 整包收进
  `{app}`，所以装好就在 `%LOCALAPPDATA%\Programs\BaoCode\claude\claude.exe`。
- **codex 产品不带它**（那个产品没有 Claude Code 可带）。

**版本怎么跟上上游**（`tool/bump_claude_version.dart`）：

```
dart tool/bump_claude_version.dart          只说现状；落后时退出码 1
dart tool/bump_claude_version.dart --write  把渠道上的当前版本写进 pin
```

- 读的是 `tool/build_windows.dart` 里那两个常量，写的也是它们。
- SHA-256 取自官方 manifest（`downloads.claude.ai/claude-code-releases/<版本>/manifest.json`
  的 `platforms.win32-x64.checksum`），**不必下载那 283 MB** 就能拿到；真正的二进制仍由
  构建时下载并按 pin 校验。
- `BAOCODE_CLAUDE_RELEASES` 指向别处（测试用）。
- CI：`.github/workflows/claude-version.yml` 每天跑 `--write` 并在 `main` 上提交；
  发版时 `release.yml` 的 `check` 任务再跑一次兜底，落后就发不下去。

---

## 3. 协议契约

**这份契约在源码里是散落的裸字符串，没有集中的常量表。** 下表是当前的完整清单，
改动 CLI 协议时先对照这里。

### 3.1 CLI 启动参数（`claude_code_transport.dart:240-290`）

```
claude -p --input-format stream-json --output-format stream-json --verbose
       --include-partial-messages --replay-user-messages
       --permission-prompt-tool stdio --thinking-display summarized
       [--prompt-suggestions] [--permission-mode X] [--model M] [--effort E]
       [--autocompact N] [--resume ID] [--add-dir D]...
       [--settings <json|文件>] [--no-session-persistence]
       [--mcp-config ... --allowedTools ...]
       --append-system-prompt <citing_code + file_links + 工作区说明>
```

固定注入的环境变量（`claude_code_transport.dart:327-330`）：
`CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING=1`（宿主可回滚文件）、
`CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS=1`（CLI 报 `session_state_changed`）。

### 3.2 control_request subtype 全表（我们发给 CLI）

| subtype | 参数 | 位置 | 用途 |
| --- | --- | --- | --- |
| `initialize` | `promptSuggestions`, `sdkMcpServers` | L593 | 握手；回答里带命令目录、模型、权限模式 |
| `set_permission_mode` | `mode` | L600, L3284 | 切权限模式 |
| `set_model` | `model` | L2743, L2898, L3391, L3450 | 切模型 |
| `apply_flag_settings` | 见各处 | L2884, L2982, L3313, L3419 | 改 thinking / effort / modelPicker / attribution 等 flag 设置 |
| `get_settings` | — | L2775 | 读回当前设置（用于确认已生效） |
| `get_usage` | 见 L2208 | L2208 | 查账号配额（无活进程时另起一个进程问） |
| `get_context_usage` | 见 L2362 | L2362 | 查上下文占用 |
| `get_hooks_listing` | — | L1993 | 读 `/goal` 的 Stop hook（10s 超时） |
| `file_suggestions` | `query` | L626, L1401 | `@` 文件建议 |
| `interrupt` | — | L1054 | 打断当前轮次 |
| `cancel_async_message` | 见 L1078 | L1078 | 撤回排队的消息 |
| `rename_session` | `title`, `source:'host'` | L633, L1265 | 改名 |
| `rewind_conversation` | 见 L1149 | L1149 | 回退对话 |
| `rewind_files` | `user_message_id` | L1233 | 回退文件改动 |
| `stop_task` | `task_id` | L1269 | 停后台任务 |
| `background_tasks` | `tool_use_id` | L1273 | 把任务移到后台 |
| `mcp_status` | — | L1287, L1329 | MCP 服务器列表 |
| `mcp_toggle` | `serverName`, `enabled` | L1300 | 启停 MCP 服务器 |
| `mcp_reconnect` | `serverName` | L1306 | 重连 |
| `mcp_authenticate` | 见 L1311 | L1311 | 触发 OAuth |

`ControlChannel.request` 默认 60s 超时，超时后主动 `refuse` 并抛 `ControlError`，
不让对端永远等答复（`control_channel.dart:39-50`）。

### 3.3 入站消息 type / subtype 全表（CLI 给我们）

`ClaudeCodeKernel._handle`（L1671-1774）分派：

| type | subtype | 处理 |
| --- | --- | --- |
| `transport_exit` | — | `_exited`(L2404)：分类失败、可能自动重跑一次 |
| `control_request` | — | `_controlRequest`(L1776) |
| `control_cancel_request` | — | 撤销对应的 `InteractionResolved` |
| `system` | `init` | 取 `session_id`/`model`/`effort`/`permissionMode`/`mcp_servers`/`terminal_slash_commands` |
| `system` | `status` | 同步权限模式；`status=='requesting'` 且无轮次时开一个 **unprompted** 轮次 |
| `system` | `compact_boundary` | 压缩通知 + 刷新上下文用量 |
| `system` | `session_state_changed` | `_cliWorking`；空闲时同步 goal、必要时 `release()` |
| `system` | `session_title_changed` | 区分「宿主改的名」与「CLI 自己改的名」（`_sentTitles`） |
| `system` | `commands_changed` | 更新命令目录 |
| `assistant` | — | 统计缓存 token；`rate_limit` 错误 → `_limitSaid`；转 translator |
| `result` | — | `_result`(L1882)：成本、模型窗口、错误、结束轮次 |
| `rate_limit_event` | — | `_rateLimits`(L2084) |
| `command_lifecycle` | `started`/`cancelled` | `_lifecycle`(L1850) |
| `prompt_suggestion` | — | 下一条提示建议 |
| 其它 | — | 一律转 translator |

`control_request` 的三种 subtype（L1781-1790）：
`can_use_tool` → `_permission`(L1470)；`elicitation` → `_elicitation`(L1815)；
`mcp_message` → `_mcpMessage`(L1795)。**其它一律 `refuse`，不留悬挂请求。**

### 3.4 translator 认的报文（`claude_code_translator.dart:306-321`）

顶层只有 5 类：`stream_event`、`assistant`、`user`、`system`、`attachment`（回放时）。

`stream_event` 的子事件（L460-568）：

| 事件 | 产出 |
| --- | --- |
| `message_start` / `message_delta` / `message_stop` | 记 message id、累加 usage、`OutputMeter` 计时 |
| `content_block_start` `thinking`/`redacted_thinking` | `ItemUpserted(ThinkingItem, streaming:true)` |
| `content_block_start` `text` | `ItemUpserted(AssistantTextItem, streaming:true)` |
| `content_block_start` `tool_use` | 先占位，等全量报文补 input |
| `content_block_delta` `thinking_delta` | `TextDelta` + token 估算 |
| `content_block_delta` `text_delta` | `TextDelta`（带 offset，幂等） |
| `content_block_stop` | 思考/文本 → `ItemCompleted` |

`system` 的子类型（L1504-1691）：`status`、`compact_boundary`、`api_retry`、
`informational`、`notification`、`local_command_output`、`permission_denied`、
`thinking_tokens`、`task_started`、`task_progress`、`task_updated`、
`task_notification`、`background_tasks_changed`。

### 3.5 工具名 → ToolKind 映射（`claude_code_translator.dart:1010-1174`）

| CLI 工具 | 结果 |
| --- | --- |
| `Read` | `ToolCallItem(read)`，detail 显示 `Lx-y`，图片作为 `images` |
| `Grep` | `ToolCallItem(grep)` |
| `Glob` | `ToolCallItem(search)` |
| `LS` | `ToolCallItem(listDir)` |
| `Edit` / `MultiEdit` / `Write` / `NotebookEdit` | `ToolCallItem(edit)`；有结构化 patch 时升级为 `CodeDiffItem` |
| `Bash` | `TerminalItem`（`run_in_background` → 后台任务） |
| `BashOutput` / `TaskOutput` | `ToolCallItem(command)` |
| `KillShell` / `KillBash` / `TaskStop` | `ToolCallItem(command)` |
| `WebFetch` / `WebSearch` | `ToolCallItem(web)` |
| `Skill` | `ToolCallItem(other)` |
| `ToolSearch` | `ToolCallItem(search)` |
| `TodoWrite` / `TaskCreate` / `TaskUpdate` / `TaskList` / `TaskGet` | `ToolCallItem(todo)` + `TodosReported` |
| `AskUserQuestion` | `ToolCallItem(question)` |
| `SendMessage` | `ToolCallItem(message)` |
| `ProposeGoal` | `ToolCallItem(goal)`（目标由用户点按钮设置） |
| `EnterPlanMode` / `ExitPlanMode` | `ToolCallItem(other)` |
| `mcp__<server>__<tool>` | `ToolCallItem(mcp)` |
| `mcp__baocode__*` | 走 `ClaudeSdkTools.called()`，label/target 由 `summary` 生成 |
| 其它 | `ToolCallItem(other)` |

结果状态（`_toolResultOf` L1199）：`_denied` 或 AskUserQuestion 收到
`unattendedAnswer` → `denied`；`is_error` → `failed`；否则 `done`。
输出裁剪：成功截前 2000 字（`_short`），失败留末 4000 字（`_tail`）。

---

## 4. 能力接口矩阵

`ClaudeCodeKernel` 声明的 21 个接口（`claude_code_kernel.dart:91-114`）。
**UI 按接口显示功能，没声明就没入口。**

| 接口 | 用途 | Claude Code | Codex |
| --- | --- | --- | --- |
| `AgentKernel` | 基础生命周期 | ✅ | ✅ |
| `SelectsModel` / `SelectsMode` / `SelectsPermission` | 模型/模式/权限选择器 | ✅ | ✅ |
| `SelectsEffort` / `SelectsFast` | 思考强度、Fast 档 | ✅ | ✅ |
| `SelectsContextSize` | 200K / 1M 窗口 | ✅ | ❌ |
| `StartsPlans` | 计划卡片「开始构建」 | ✅ | ✅ |
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

---

## 5. 选项与设置键

### settings.json

| 键 | 文件 | 作用 |
| --- | --- | --- |
| `claudeCode.core` | `claude_core_setting.dart:16` | `builtin`（内置 bao_agent）或 `cli` |
| `claudeCode.path` | `claude_path_setting.dart:7` | 指定 CLI 路径；空 = 用本机最新，没有则自动下载 |
| `claudeCode.models` | `claude_code_kernel.dart:308` | 模型目录缓存（GlobalStorage） |
| `chat.queuedMessages` | `lib/kernel/queued_messages.dart:12` | 排队消息何时取用（`afterTurn` / `duringTurn`） |
| `chat.promptSuggestions` | `lib/kernel/prompt_suggestions.dart:7` | 是否请求下一条提示建议 |
| `chat.commitAttribution` | `lib/kernel/commit_attribution.dart:16` | 提交/PR 署名 |

### 每模型独立的选项记忆

键格式 `<kind>@<model>`，由 `modelSettingKey()`（`agent_kernel.dart:160`）约定：

- `effort@<model>` — 思考强度
- `context@<model>` — 上下文窗口
- `fast@<model>` — Fast 档

解析在 `claude_code_kernel.dart:155-167`；通用键（`effort`/`context`/`fast`）是兜底。

### 模式与审批档位

- 工作模式 `_works`（L3167）：`agent` / `ask` / `plan`
- 审批模式 `_approvals`（L3188）：`default` / `acceptEdits` / `auto` / `dontAsk` /
  `bypassPermissions`（后者 `caution: true`）

映射到 CLI：`_mode`(L3244) 与 `_cliApproval`(L3250)。**`bypassPermissions` 会被降级为
`acceptEdits` 再发给 CLI**（CLI 拒绝以 root 切到 bypass），实际放行在 `_permission`
本地判定（`_askedInFullAccess` L3257）。

Ask 模式用两条 system-reminder 注入（`_askNote` L3224 / `_askEndedNote` L3231），
只追加在消息尾部，**不污染用户输入的文本**。

---

## 6. 扩展点：常见任务改哪里

| 想做的事 | 改哪里 |
| --- | --- |
| 支持一种新工具的卡片样式 | `claude_code_translator.dart:1010` 的 `switch (name)` |
| CLI 报文的种新 type/subtype | `claude_code_kernel.dart:1671` `_handle`；语义复杂就放 translator |
| 新的交互（提问/审批/表单） | `kernel_types.dart` 加类型 → kernel 加分支 → `answer()` 加回写分支 |
| 新的设置项 | `lib/settings/` 加页 → 读它的类加 `settingKey` 常量（参照 `claude_path_setting.dart`） |
| 给 agent 加应用自有工具 | `ClaudeSdkTools.register/unregister/instruct`（参照 `lib/browser/browser_tools.dart:86`、`lib/images/image_tools.dart:46`） |
| 换模型/换上游后重启会话 | `_change([...])`（L2750）+ `_applyWindow()`（L798） |
| 加一个 `/` 命令 | `commands` 目录 + CLI 侧 `_commandsFrom`（L2678） |

---

## 7. 测试

```sh
flutter test test/kernel            # 内核与能力
flutter test test/kernel_ui_test.dart
flutter test test/claude_process_test.dart
flutter test test/claude_runtime_test.dart
flutter test test/e2e_claude_real_test.dart
```

按 `CLAUDE.md` 的约定：**只跑跟改动相关的测试**，全量套件慢。

| 文件 | 覆盖 |
| --- | --- |
| `test/kernel_test.dart`（223KB） | 内核主体：选项、权限、队列、回放、配额 |
| `test/kernel_ui_test.dart`（64KB） | UI 侧与能力的接线 |
| `test/claude_process_test.dart` | 本机进程传输、进程树清理 |
| `test/claude_runtime_test.dart` | CLI 定位、版本、下载 |
| `test/e2e_claude_real_test.dart` | 打真实 CLI 的端到端 |
| `test/kernel/claude_haiku_test.dart` | Haiku 调用 |
| `test/kernel/claude_sdk_tools_test.dart` | 自有 MCP 工具 |
| `test/kernel/turn_stats_test.dart` | 轮次统计落盘 |
| `test/kernel/usage_limit_kernel_test.dart` | 限额 |
| `test/remote/remote_claude_install_test.dart` | 远端安装 |
| `test/kernel/kernel_product_test.dart` | 两个产品的内核隔离 |

Mock 传输 `mock_claude_code_transport.dart` 的报文录自真实 CLI 2.1.281，覆盖 20 余种
control subtype。**改协议后要同步更新 mock**，否则测试会静默走不到新路径。

---

## 8. 已知陷阱

写这块代码时，这些坑已经在源码里留了痕迹。

### 8.1 静态全局状态（跨会话共享）

- `_last` / `_lastCatalog`（L293-296）：上一个会话的模型/命令目录会留给新会话当占位，
  多会话并行时命令列表可能串味。
- `_limits` / `_limitsState` / `_limitsOffBy`（L2140-2248）：账号级配额本就一致，
  但 `_updateLimits`(L2130) 只按 label 合并、**已消失的窗口永不清理**。
- `_modelCache` / `turnStats`：需要 `forgetAccount()`(L2166) 之类的钩子做测试隔离。

### 8.2 判据不一致

- `usageLimitApplies` 看**当前选中**模型的 provider（L2040），
  `_limitHit` 看**运行中**进程的 provider（L2048）。切换 provider 的瞬间两者结论相反。
- `_reported(mode)`(L3294) 把 CLI 报来的 mode 名直接写进 `_approval`；CLI 引入新
  mode 名时，选择器会出现「不在列表里的选中项」。

### 8.3 依赖 CLI 私有字段

`_askedInFullAccess`(L3257) 依赖 `classifier_approvable`、`decision_reason_type`、
`matched_ask_rule`、`requires_user_interaction`、`decision_reason_code` ——
**这些不是公开契约，CLI 改字段即失效**。`_tooOld()`(L2523) 只靠 stderr 含
`unknown option '--` 判断版本过旧。

### 8.4 消息与状态

- `answer()`(L1417) 先移除权限项再回写；此时 `_control` 为 null（进程刚死）的话，
  UI 已发 `InteractionResolved` 而 CLI 永远收不到答复。
- `_endTurn` 只在成功时写 turn stats（L1033），被中断的轮次不落盘，恢复会话时该轮
  耗时/用量只能靠时间戳猜测。
- `_toolResult` 的 `_slim`(L1193) 丢弃 `content`/`new_string`/`old_string`/`patch`，
  之后无法重放或再审该次编辑。
- `_exited` 的自动重跑上限是 1 次且只在干净轮次后归零（L2404-2486），一轮内连崩两次
  即直接失败。

### 8.5 平台

- Windows 无 IANA 时区（`local_time_zone_io.dart:12` 恒返回 null），限额重置时间无法
  校验时区，远程主机的时间可能被当成本机时间接受。
- `process_transport_io.dart:129` 只在 Windows 带 `includeParentEnvironment`；
  macOS/Linux 依赖 `cli.environment`（登录 shell 环境）。

### 8.6 复杂度债

- `claude_code_kernel.dart` 3612 行承担生命周期、选项、权限、配额、MCP、目标、历史、
  回放十类职责；`claude_code_translator.dart` 2003 行承担全部报文语义。
- 协议 subtype 是散落各处的裸字符串，**没有集中常量表** —— 改协议需全局搜索。

---

## 9. 代码风格

本仓库的注释是「意图说明书」而非「代码复述」：解释**为什么这样写**、**踩过什么坑**、
**什么情况下会失效**。写新代码时沿用这个密度 —— 一个 `switch` 分支的注释应当回答
「为什么这个 case 和别的不同」，而不是复述 case 的名字。

其它约定：

- 面向用户的文案走 `lib/l10n/`，不要在 kernel 里硬编码中文/英文。
- 路径处理统一用 `package:path`；远程路径一律 `p.posix`。
- 跨进程边界的对象不要强转：`as Map` / `as int` 之前先判类型，服务端返回类型会变。
- 平台相关代码用条件导出：`_io.dart` / `_stub.dart`（web 端抛异常）。
- 新增能力接口记得同时更新 `lib/chat/chat_session.dart` 的能力探测分支，
  否则 UI 不会显示。
