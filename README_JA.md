# BaoCode

[English](README.md) · [简体中文](README_CN.md) · **日本語** · [Français](README_FR.md) · [Español](README_ES.md)

**[Claude Code](https://github.com/anthropics/claude-code) のためのオープンソースのコントロールプレーン。単なるインターフェースではありません。**

細部まで作り込んだ 360 FPS のインターフェースに加えて、別のマシン上の Claude Code、スマートフォンからの操作、Windows 向けの徹底した最適化、10 倍速いブラウザ操作、本格的なコードエディタ、任意のカスタム API、使用量の可視化、会話のオーケストレーション、そして Bot。

[公式サイト](https://baocode.dev) · [ダウンロード](https://baocode.dev/download) · [変更履歴](https://baocode.dev/changelog)

![BaoCode の Agent モード：複数マシン上のエージェント、進行中の会話とその使用量](https://baocode.dev/readme/agent.webp)

![BaoCode の IDE モード：ファイルツリーとエディタ、その横に会話](https://baocode.dev/readme/ide.webp)

![BaoCode でできること：360 FPS 描画、SSH 越しの Claude Code、ブラウザ操作、あらゆるモデル、Windows、使用量とコスト](https://baocode.dev/readme/features-en.webp)

> 英語 README の日本語版です。内容に相違がある場合は [English](README.md) を参照してください。リンク先のサイトや文書が日本語に対応しているとは限りません。

## 車輪の再発明はしない、自然に使えるものを

Claude Code はすでに十分に優れています。BaoCode は足りない部分だけを補います。すぐに使えて、新しい概念を覚える必要はなく、最初からこうあるべきだったと感じられる使い心地です。

**なぜ Claude Code なのか？** どのエージェントのコアをカスタマイズしても、突き詰めれば Claude Code と同じ形になります。同じツール、同じコンテキスト管理、同じスキルと MCP。遠回りして作り直すより、それをそのまま使い、他のモデルはプロトコル層でつなぐ。ひとつの設定ですべてのモデルが動きます。BaoCode はインストール済みの Claude Code を、あなたの設定、サインイン、`CLAUDE.md` のまま実行します。Claude Code がない環境では、同じ設定を読む BaoCode 内蔵のエージェントが、追加したモデルプロバイダーで動きます。

**ひとつの会話で全体を動かす。** オーケストレーション用のキャンバスはありません。内蔵の MCP を通じて、メインの会話が他のセッションやサブエージェントを、サーバーをまたいでも指揮します。複雑な流れは一度説明するだけ、あるいはスキルとして書いておけば何度でも使えます。

BaoCode は意図的に独自のエージェントを持ちません。Claude Code がエージェントです。Windows 版には Claude Code 本体が同梱されているため、別途インストールは不要です（すでに別のビルドをお持ちならそちらが使われます）。

## 機能

### GPU による 360 FPS のネイティブ描画

Electron も DOM のリフローもありません。BaoCode は GPU に直接インターフェースを描くネイティブアプリです。高速なトークンストリームもディスプレイのリフレッシュレートに追従し、スクロールは手の動きにぴったりついてきて、待機中は自動的に描画を抑えます。

| | BaoCode | VS Code | Cursor |
| --- | --- | --- | --- |
| 起動 | 約 0.18 秒 | 約 2〜3 秒 | 約 2〜3 秒 |
| メモリ（ウィンドウ 1 つ、アイドル時） | 約 120 MB | 約 970 MB | 約 1.9 GB |
| プロセス数（ウィンドウ 1 つ） | 2 | 8 | 13 |
| ダウンロードサイズ（Windows） | 約 16 MB | 約 244 MB | 約 214 MB |

| 指標 | BaoCode |
| --- | --- |
| 起動時間 | 約 0.18 秒 |
| 一つのウィンドウのアイドル時メモリ | 約 120 MB |
| 一つのウィンドウのプロセス数 | 2 |
| Windows のダウンロードサイズ | 約 114 MB |

Windows 版には Claude Code 本体が同梱されています。インストール後に另行入れるものはありません。

## 必要環境

- Windows 10 以降（x64）、または Linux：Ubuntu 22.04 以降とその他の Debian 系ディストリビューション（x64 と arm64 向けにそれぞれ .deb）。**この fork は Windows 版のみをビルド・配布します**。macOS アプリはここではビルドも配布もしていません。
- 別途インストールは不要：[Claude Code](https://github.com/anthropics/claude-code) は BaoCode に同梱されています。すでに別のビルドをお持ちならそちらが使われます。

## ソースからのビルド

BaoCode は Flutter アプリです（Dart SDK `^3.13.4`）。

```sh
flutter pub get
flutter run -d windows
```

リリース版を `build/installers/` にビルドするには：

```sh
dart run tool/build_windows.dart          # BaoCode-<version>-setup.exe（Inno Setup が必要）
flutter build linux --release && sh tool/package_linux_deb.sh   # BaoCode-<version>-linux-{amd64,arm64}.deb と .tar.gz（Ubuntu 上で）
dart run tool/build_remote_server.dart    # SSH リモートサーバー（Linux、macOS、Windows ホスト用）
```

テストスイート全体は時間がかかります。変更した部分のテストだけを実行してください（例：`flutter test test/update`）。

`v*` タグをプッシュすると、CI がリリースをビルドして公開します。バージョン、署名、公開先については [docs/release.md](docs/release.md) を参照してください。その他の文書は [docs/](docs) にあります：[自動更新](docs/auto-update.md)、[SSH リモート](docs/ssh-remote.md)、[Windows](docs/windows.md)、[スマートフォン接続](docs/mobile-link.md)（一部は中国語）。

## リポジトリ構成

| パス | 内容 |
| --- | --- |
| [lib/](lib) | アプリ本体 |
| [packages/bao_agent](packages/bao_agent) | 内蔵エージェント。Claude Code の stream-json プロトコルを話します |
| [packages/bao_editor](packages/bao_editor) | Flutter に移植した Monaco：エディタ、シンタックスハイライト、VS Code のテーマとキーバインド |
| [packages/bao_xterm](packages/bao_xterm) | xterm.js の Dart 移植 |
| [packages/bao_remote](packages/bao_remote) | SSH 経由で提供されるリモートホスト側 |
| [packages/bao_link](packages/bao_link)、[bao_iroh](packages/bao_iroh) | スマートフォンとの接続：QR ペアリング、iroh によるエンドツーエンド暗号化通信 |
| [packages/bao_markdown](packages/bao_markdown) | 入力しながら表示される Markdown エディタ |
| [packages/bao_websearch](packages/bao_websearch) | 検索 API を使わない、どのモデルでも使える Web 検索 |
| [browser_extension/](browser_extension) | ブラウザ拡張機能 |
| [tool/](tool) | ビルド、パッケージング、リリース用スクリプト |
| [site/](site) | 公式サイト [baocode.dev](https://baocode.dev) |
| [docs/](docs) | 設計メモ |

## フィードバック

Issue と Pull Request を歓迎します。変更を書く前に Issue で相談してください。大きな Pull Request や、事前に相談のない変更の Pull Request は受け付けません。詳しくは [CONTRIBUTING.md](CONTRIBUTING.md) を参照してください。

## ライセンス

BaoCode は [GNU General Public License v3.0](LICENSE)（GPL-3.0-only）でライセンスされています。[packages/](packages) 内のエディタとターミナルのパッケージ（bao_editor、bao_xterm、bao_pty）は MIT です。サードパーティのコンポーネントはそれぞれのライセンスに従い、ライセンスファイルはソースツリー内の各コンポーネントの隣にあります。

BaoCode は独立したプロジェクトであり、Anthropic とは提携しておらず、その承認も受けていません。
