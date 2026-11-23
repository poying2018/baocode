# BaoCode

[English](README.md) · [简体中文](README_CN.md) · [日本語](README_JA.md) · **Français** · [Español](README_ES.md)

**Le plan de contrôle open source pour [Claude Code](https://github.com/anthropics/claude-code). Bien plus qu'une interface.**

Au-delà d'une interface à 360 FPS soignée jusque dans les détails : Claude Code sur vos autres machines, le contrôle depuis votre téléphone, une optimisation poussée pour Windows, un pilotage du navigateur 10× plus rapide, un éditeur de code complet, n'importe quelle API personnalisée, le suivi de la consommation, l'orchestration des conversations et des Bots.

[Site web](https://baocode.dev) · [Télécharger](https://baocode.dev/download) · [Historique des versions](https://baocode.dev/changelog)

![BaoCode en mode Agent : des agents sur plusieurs machines, une conversation en cours et sa consommation](https://baocode.dev/readme/agent.webp)

![BaoCode en mode IDE : l'arborescence et l'éditeur, avec la conversation à côté](https://baocode.dev/readme/ide.webp)

![Ce que fait BaoCode : rendu à 360 FPS, Claude Code via SSH, le navigateur, tous les modèles, Windows, usage et coût](https://baocode.dev/readme/features-en.webp)

> Présentation française du README anglais. En cas de différence, consultez la version [English](README.md). Les sites et documents liés ne sont pas nécessairement traduits en français.

## Ne pas réinventer la roue, juste ce qui marche

Claude Code est déjà très bon ; BaoCode n'ajoute que ce qui lui manque. Il fonctionne dès l'installation, sans rien de nouveau à apprendre, et se comporte comme il aurait toujours dû.

**Pourquoi Claude Code ?** Poussez assez loin la personnalisation de n'importe quel moteur d'agent, et il finit par ressembler à Claude Code : les mêmes outils, la même gestion du contexte, les mêmes skills et le même MCP. Plutôt que de le reconstruire par un long détour, BaoCode l'utilise directement et relie les autres modèles au niveau du protocole : une seule configuration les fait tous fonctionner. Il lance le Claude Code que vous avez déjà, avec vos réglages, votre connexion et votre `CLAUDE.md` ; là où Claude Code n'est pas installé, l'agent intégré de BaoCode lit les mêmes réglages et tourne sur un fournisseur de modèles que vous ajoutez.

**Une conversation dirige le reste.** Pas de canevas d'orchestration. Grâce au MCP intégré, la conversation principale pilote les autres sessions et sous-agents, y compris sur d'autres serveurs ; décrivez une fois un flux complexe, ou écrivez-le sous forme de skill pour le réutiliser.

BaoCode n'intègre volontairement aucun agent propre : Claude Code est l'agent. Le téléchargement Windows contient Claude Code lui-même ; le vôtre, si vous en avez un, est utilisé à sa place.

## Fonctionnalités

### Rendu natif GPU à 360 FPS

Pas d'Electron, pas de reflow du DOM. BaoCode est une application native qui dessine son interface directement sur le GPU : les flux de tokens rapides suivent la fréquence de rafraîchissement de votre écran, le défilement suit votre main, et l'application ralentit d'elle-même pendant les attentes.

| | BaoCode | VS Code | Cursor |
| --- | --- | --- | --- |
| Lancement | ≈ 0,18 s | ≈ 2–3 s | ≈ 2–3 s |
| Mémoire, une fenêtre au repos | ≈ 120 Mo | ≈ 970 Mo | ≈ 1,9 Go |
| Processus, une fenêtre | 2 | 8 | 13 |
| Taille du téléchargement, Windows | ≈ 16 Mo | ≈ 244 Mo | ≈ 214 Mo |

| Indicateur | BaoCode |
| --- | --- |
| Démarrage | ≈ 0,18 s |
| Mémoire, une fenêtre inactive | ≈ 120 MB |
| Processus, une fenêtre | 2 |
| Taille du téléchargement Windows | ≈ 114 MB |

Le téléchargement pour Windows contient Claude Code lui-même : il n'y a rien à installer ensuite.

## Prérequis

- Windows 10 ou ultérieur (x64), ou Linux : Ubuntu 22.04 ou ultérieur et les autres distributions basées sur Debian (un .deb pour x64, un pour arm64). **Ce fork ne compile et ne publie que la version Windows** ; l'application macOS n'y est ni compilée ni publiée.
- Rien à installer : [Claude Code](https://github.com/anthropics/claude-code) est fourni avec BaoCode. Le vôtre, si vous en avez un, est utilisé à sa place.

## Compilation depuis les sources

BaoCode est une application Flutter (Dart SDK `^3.13.4`).

```sh
flutter pub get
flutter run -d windows
```

Pour compiler les versions publiées, dans `build/installers/` :

```sh
dart run tool/build_windows.dart          # BaoCode-<version>-setup.exe (nécessite Inno Setup)
flutter build linux --release && sh tool/package_linux_deb.sh   # BaoCode-<version>-linux-{amd64,arm64}.deb et .tar.gz, sous Ubuntu
dart run tool/build_remote_server.dart    # le serveur distant SSH, pour les hôtes Linux, macOS et Windows
```

La suite de tests complète est lente ; lancez les tests liés à vos modifications, par exemple `flutter test test/update`.

Les versions sont compilées et publiées par la CI lorsqu'un tag `v*` est poussé ; les numéros de version, la signature et la destination des publications sont décrits dans [docs/release.md](docs/release.md). Plus de documents dans [docs/](docs) : [mise à jour automatique](docs/auto-update.md), [SSH distant](docs/ssh-remote.md), [Windows](docs/windows.md), [la liaison avec le téléphone](docs/mobile-link.md) (certains sont en chinois).

## Structure du dépôt

| Chemin | Contenu |
| --- | --- |
| [lib/](lib) | L'application |
| [packages/bao_agent](packages/bao_agent) | L'agent intégré, qui parle le protocole stream-json de Claude Code |
| [packages/bao_editor](packages/bao_editor) | Monaco, porté sur Flutter : l'éditeur, sa coloration syntaxique, les thèmes et raccourcis de VS Code |
| [packages/bao_xterm](packages/bao_xterm) | Un portage de xterm.js en Dart |
| [packages/bao_remote](packages/bao_remote) | L'hôte distant servi via SSH |
| [packages/bao_link](packages/bao_link), [bao_iroh](packages/bao_iroh) | La liaison avec votre téléphone : appairage par QR code, connexions chiffrées de bout en bout via iroh |
| [packages/bao_markdown](packages/bao_markdown) | Un éditeur Markdown qui affiche le rendu pendant la frappe |
| [packages/bao_websearch](packages/bao_websearch) | La recherche web pour tous les modèles, sans API de recherche |
| [browser_extension/](browser_extension) | L'extension de navigateur |
| [tool/](tool) | Scripts de compilation, d'empaquetage et de publication |
| [site/](site) | Le site web, [baocode.dev](https://baocode.dev) |
| [docs/](docs) | Notes de conception |

## Retours

Les issues et les pull requests sont les bienvenues. Discutez d'une modification dans une issue avant de l'écrire ; les grosses pull requests, et celles qui portent sur des changements non discutés au préalable, ne sont pas acceptées. Voir [CONTRIBUTING.md](CONTRIBUTING.md).

## Licence

BaoCode est distribué sous la [GNU General Public License v3.0](LICENSE) (GPL-3.0-only). Les paquets d'éditeur et de terminal dans [packages/](packages) (bao_editor, bao_xterm, bao_pty) sont sous licence MIT. Les composants tiers conservent leurs propres licences, placées à côté d'eux dans l'arborescence des sources.

BaoCode est un projet indépendant, ni affilié à Anthropic ni approuvé par Anthropic.
