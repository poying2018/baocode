# BaoCode


[English](README.md) · **简体中文** · [日本語](README_JA.md) · [Français](README_FR.md) · [Español](README_ES.md)

**开源 [Claude Code](https://github.com/anthropics/claude-code) 控制面，不仅仅是界面。**

细节拉满的 360FPS 界面之外，还有远程其他电脑的 Claude Code、手机随时接管、Windows 深度优化、10 倍效率的浏览器操控、完整代码编辑器、任意自定义 API、用量洞察、对话编排与 Bot。

[官网](https://baocode.dev/zh/) · [下载](https://baocode.dev/zh/download) · [更新日志](https://baocode.dev/zh/changelog)

![BaoCode 的 Agent 模式：多台机器上的智能体、进行中的对话及其用量](https://baocode.dev/readme/agent.webp)

![BaoCode 的 IDE 模式：文件树和编辑器，旁边是对话](https://baocode.dev/readme/ide.webp)

![BaoCode 能做什么：360 FPS 渲染、SSH 远程 Claude Code、浏览器操控、全模型接入、Windows 优化、用量与费用](https://baocode.dev/readme/features-zh.webp)

## 不重复造轮子，简单自然才好用

Claude Code 已经足够好，BaoCode 只补它缺的那部分。开箱即用，不用学新概念，用起来就像它本该如此。

**为什么是 Claude Code？** 无论基于哪个内核定制，做到最后都会长成 Claude Code 的样子：同样的工具、同样的上下文管理、同样的 Skill 与 MCP。与其绕一圈重造，不如直接用它，再在协议层接入其他模型，一套配置通用全部。BaoCode 运行你已经装好的 Claude Code，沿用你的设置、登录和 `CLAUDE.md`；没装 Claude Code 的地方，由 BaoCode 内置的智能体读取同样的设置，跑在你添加的模型供应商上。

**一个对话就能调度全部。** 不做复杂的编排画布。主对话通过内置 MCP 直接调度其他会话和子代理，跨服务器也一样；复杂的流程口述一遍，或写成 Skill 就能反复用。

BaoCode 有意不包含自己的智能体——Claude Code 才是智能体。Windows 安装包自带 Claude Code，装完不用再装别的；你若已装了别的版本，就用你那份。

## 功能

### GPU 360FPS 原生绘制

彻底放弃 Electron 与 DOM 重排。BaoCode 是原生应用，界面直接用 GPU 绘制：高吞吐流式输出稳锁高刷，滚动跟手，思考等待时自动降频。

| | BaoCode | VS Code | Cursor |
| --- | --- | --- | --- |
| 启动 | 约 0.18 秒 | 约 2–3 秒 | 约 2–3 秒 |
| 单窗口空闲内存 | 约 120 MB | 约 970 MB | 约 1.9 GB |
| 单窗口进程数 | 2 | 8 | 13 |
| Windows 下载大小 | 约 16 MB | 约 244 MB | 约 214 MB |

| 指标 | BaoCode |
| --- | --- |
| 启动时间 | 约 0.18 秒 |
| 单窗口空闲内存占用 | 约 120 MB |
| 单窗口进程数 | 2 |
| Windows 下载大小 | 约 114 MB |

Windows 版自带 Claude Code，装完不用再装别的。

## 系统要求

- Windows 10 或更新版本（x64），或 Linux：Ubuntu 22.04 或更新版本及其他基于 Debian 的发行版（x64 和 arm64 各一个 .deb）。**本 fork 只构建并发布 Windows 版**，macOS 应用在这里既不构建也不发布。
- 不用另外安装：[Claude Code](https://github.com/anthropics/claude-code) 随 BaoCode 一起提供。你若已装了别的版本，就用你那份。

## 从源码构建

BaoCode 是 Flutter 应用（Dart SDK `^3.13.4`）。

```sh
flutter pub get
flutter run -d windows
```

构建发行版本，产物写入 `build/installers/`：

```sh
dart run tool/build_windows.dart          # BaoCode-<version>-setup.exe（需要 Inno Setup）
flutter build linux --release && sh tool/package_linux_deb.sh   # BaoCode-<version>-linux-{amd64,arm64}.deb 和 .tar.gz，在 Ubuntu 上
dart run tool/build_remote_server.dart    # SSH 远程服务端，用于 Linux、macOS 和 Windows 主机
```

完整测试套件很慢，只跑和改动相关的测试，例如 `flutter test test/update`。

推送 `v*` 标签后，CI 会构建并发布。版本号、签名和发布位置见 [docs/release.md](docs/release.md)。更多文档在 [docs/](docs)：[自动更新](docs/auto-update.md)、[SSH 远程](docs/ssh-remote.md)、[Windows](docs/windows.md)、[手机连接](docs/mobile-link.md)。

## 仓库结构

| 路径 | 内容 |
| --- | --- |
| [lib/](lib) | 应用代码 |
| [packages/bao_agent](packages/bao_agent) | 内置智能体，使用 Claude Code 的 stream-json 协议 |
| [packages/bao_editor](packages/bao_editor) | 移植到 Flutter 的 Monaco：编辑器、语法高亮、VS Code 主题和快捷键 |
| [packages/bao_xterm](packages/bao_xterm) | xterm.js 的 Dart 移植 |
| [packages/bao_pty](packages/bao_pty)、[bao_conpty](packages/bao_conpty) | Dart 伪终端：macOS、Linux 用 forkpty，Windows 用 ConPTY |
| [packages/bao_remote](packages/bao_remote) | 通过 SSH 提供服务的远程端 |
| [packages/bao_link](packages/bao_link)、[bao_iroh](packages/bao_iroh) | 和手机的连接：扫码配对，经 iroh 端到端加密 |
| [packages/bao_markdown](packages/bao_markdown) | 所见即所得的 Markdown 编辑器 |
| [packages/bao_websearch](packages/bao_websearch) | 不用搜索 API 的网页搜索，任何模型都能用 |
| [browser_extension/](browser_extension) | 浏览器扩展 |
| [tool/](tool) | 构建、打包及发布脚本 |
| [site/](site) | 官网 [baocode.dev](https://baocode.dev/zh/) 的源码 |
| [docs/](docs) | 设计文档 |

## 反馈

欢迎提交 Issue 和 Pull Request。改动请先在 Issue 里讨论；太大的 PR、未经讨论的 PR，不会被接受。详见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证

BaoCode 使用 [GNU General Public License v3.0](LICENSE)（GPL-3.0-only）许可证。[packages/](packages) 中的编辑器和终端相关包（bao_editor、bao_xterm、bao_pty）使用 MIT 许可证。第三方组件保留其自身许可证，具体文件位于对应源码旁。

BaoCode 是独立项目，与 Anthropic 无隶属关系，也未获得其背书。

<img width="720" height="1094" alt="image" src="https://github.com/user-attachments/assets/317028c7-4baa-4009-9ca4-6a900ba200a8" />
