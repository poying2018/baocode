# BaoCode

[English](README.md) · [简体中文](README_CN.md) · [日本語](README_JA.md) · [Français](README_FR.md) · **Español**

**El plano de control de código abierto para [Claude Code](https://github.com/anthropics/claude-code). Mucho más que una interfaz.**

Más allá de una interfaz a 360 FPS cuidada hasta el último detalle: Claude Code en tus otras máquinas, control desde el móvil, una optimización a fondo para Windows, control del navegador 10× más rápido, un editor de código completo, cualquier API personalizada, el seguimiento del consumo, la orquestación de conversaciones y Bots.

[Sitio web](https://baocode.dev) · [Descargar](https://baocode.dev/download) · [Historial de cambios](https://baocode.dev/changelog)

![BaoCode en modo Agent: agentes en varias máquinas, una conversación en curso y su consumo](https://baocode.dev/readme/agent.webp)

![BaoCode en modo IDE: el árbol de archivos y el editor, con la conversación al lado](https://baocode.dev/readme/ide.webp)

![Lo que hace BaoCode: renderizado a 360 FPS, Claude Code por SSH, el navegador, cualquier modelo, Windows, uso y coste](https://baocode.dev/readme/features-en.webp)

> Presentación en español del README en inglés. Si hay diferencias, consulta [English](README.md). Los sitios y documentos enlazados no necesariamente están traducidos al español.

## Sin reinventar la rueda, solo lo que funciona

Claude Code ya es muy bueno; BaoCode solo añade lo que le falta. Funciona nada más instalarlo, sin nada nuevo que aprender, y se siente como siempre debió ser.

**¿Por qué Claude Code?** Personaliza lo suficiente cualquier núcleo de agente y acabará con la forma de Claude Code: las mismas herramientas, la misma gestión del contexto, los mismos skills y el mismo MCP. En lugar de reconstruirlo dando un rodeo, BaoCode lo usa directamente y conecta los demás modelos en la capa del protocolo, así que una sola configuración sirve para todos. Ejecuta el Claude Code que ya tienes, con tus ajustes, tu sesión iniciada y tu `CLAUDE.md`; donde Claude Code no está instalado, el agente integrado de BaoCode lee los mismos ajustes y funciona con un proveedor de modelos que añadas.

**Una conversación dirige el resto.** Sin lienzo de orquestación. A través del MCP integrado, la conversación principal dirige otras sesiones y subagentes, también en otros servidores; describe un flujo complejo una vez, o escríbelo como skill para reutilizarlo.

BaoCode no tiene agente propio: Claude Code es el agente. La descarga para Windows incluye el propio Claude Code, así que no hay nada que instalar; si ya tienes tu propia versión, se usa esa.

## Funciones

### Renderizado nativo por GPU a 360 FPS

Sin Electron, sin reflujo del DOM. BaoCode es una aplicación nativa que dibuja su interfaz directamente en la GPU: los flujos rápidos de tokens siguen la frecuencia de refresco de tu pantalla, el desplazamiento sigue tu mano y la aplicación se frena sola mientras espera.

| | BaoCode | VS Code | Cursor |
| --- | --- | --- | --- |
| Arranque | ≈ 0,18 s | ≈ 2–3 s | ≈ 2–3 s |
| Memoria, una ventana en reposo | ≈ 120 MB | ≈ 970 MB | ≈ 1,9 GB |
| Procesos, una ventana | 2 | 8 | 13 |
| Tamaño de descarga, Windows | ≈ 16 MB | ≈ 244 MB | ≈ 214 MB |

| Indicador | BaoCode |
| --- | --- |
| Inicio | ≈ 0,18 s |
| Memoria, una ventana inactiva | ≈ 120 MB |
| Procesos, una ventana | 2 |
| Tamaño de descarga para Windows | ≈ 114 MB |

La descarga para Windows incluye el propio Claude Code: no hay nada que instalar después.

## Requisitos

- Windows 10 o posterior (x64), o Linux: Ubuntu 22.04 o posterior y otras distribuciones basadas en Debian (un .deb para x64 y otro para arm64). **Este fork solo compila y publica la versión de Windows**; la aplicación de macOS no se compila ni se publica aquí.
- Nada que instalar: [Claude Code](https://github.com/anthropics/claude-code) viene incluido con BaoCode. Si ya tienes tu propia versión, se usa esa.

## Compilar desde el código fuente

BaoCode es una aplicación Flutter (Dart SDK `^3.13.4`).

```sh
flutter pub get
flutter run -d windows
```

Para compilar lo que se publica, en `build/installers/`:

```sh
dart run tool/build_windows.dart          # BaoCode-<version>-setup.exe (requiere Inno Setup)
flutter build linux --release && sh tool/package_linux_deb.sh   # BaoCode-<version>-linux-{amd64,arm64}.deb y .tar.gz, en Ubuntu
dart run tool/build_remote_server.dart    # el servidor remoto SSH, para equipos Linux, macOS y Windows
```

La suite de pruebas completa es lenta; ejecuta las pruebas de lo que hayas cambiado, por ejemplo `flutter test test/update`.

La CI compila y publica las versiones cuando se sube una etiqueta `v*`; las versiones, la firma y el destino de las publicaciones se explican en [docs/release.md](docs/release.md). Más documentación en [docs/](docs): [actualización automática](docs/auto-update.md), [SSH remoto](docs/ssh-remote.md), [Windows](docs/windows.md), [el enlace con el móvil](docs/mobile-link.md) (algunos están en chino).

## Estructura del repositorio

| Ruta | Qué es |
| --- | --- |
| [lib/](lib) | La aplicación |
| [packages/bao_agent](packages/bao_agent) | El agente integrado, que habla el protocolo stream-json de Claude Code |
| [packages/bao_editor](packages/bao_editor) | Monaco, portado a Flutter: el editor, su resaltado de sintaxis, los temas y atajos de VS Code |
| [packages/bao_xterm](packages/bao_xterm) | Un port de xterm.js a Dart |
| [packages/bao_remote](packages/bao_remote) | El equipo remoto servido por SSH |
| [packages/bao_link](packages/bao_link), [bao_iroh](packages/bao_iroh) | El enlace con tu móvil: emparejamiento por QR, conexiones cifradas de extremo a extremo sobre iroh |
| [packages/bao_markdown](packages/bao_markdown) | Un editor de Markdown que muestra el resultado mientras escribes |
| [packages/bao_websearch](packages/bao_websearch) | Búsqueda web para cualquier modelo, sin API de búsqueda |
| [browser_extension/](browser_extension) | La extensión de navegador |
| [tool/](tool) | Scripts de compilación, empaquetado y publicación |
| [site/](site) | El sitio web, [baocode.dev](https://baocode.dev) |
| [docs/](docs) | Notas de diseño |

## Comentarios

Las issues y las pull requests son bienvenidas. Comenta un cambio en una issue antes de escribirlo; no se aceptan pull requests grandes ni pull requests de cambios que no se hayan comentado antes. Consulta [CONTRIBUTING.md](CONTRIBUTING.md).

## Licencia

BaoCode se distribuye bajo la [GNU General Public License v3.0](LICENSE) (GPL-3.0-only). Los paquetes de editor y terminal en [packages/](packages) (bao_editor, bao_xterm, bao_pty) son MIT. Los componentes de terceros mantienen sus propias licencias, que se encuentran junto a ellos en el árbol de código fuente.

BaoCode es un proyecto independiente, no afiliado a Anthropic ni respaldado por Anthropic.
