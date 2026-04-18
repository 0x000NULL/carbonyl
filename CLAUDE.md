# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Carbonyl is a Chromium-based web browser that renders directly to a terminal (no window server needed, runs over SSH). It is split into two build artifacts:

- **Core** — `libcarbonyl`, a Rust `cdylib` containing all the terminal I/O, rendering/quantization, and input handling. Source: `src/`, output under `build/<triple>/release/`.
- **Runtime** — a patched Chromium `headless_shell` that dynamically loads `libcarbonyl` via a C FFI bridge. Built from a full Chromium checkout under `chromium/src/`.

Almost all day-to-day work happens in the Rust core. Touching the runtime requires a full Chromium checkout (~100 GB, ~1 hour build) and is only necessary when changing C++ glue or patching Blink/Skia/WebRTC.

## Core crate (Rust)

```shell
cargo build                 # debug libcarbonyl
cargo build --release
```

There is no test suite — `cargo test` builds nothing meaningful. Don't claim tests pass unless you actually added them.

`build.rs` only wires up the Chromium-provided Debian sysroot for x86_64/x86 Linux links; it is a no-op on macOS/arm64 and prints a warning (not an error) if `chromium/src/build/linux/debian_bullseye_*-sysroot` is missing. That warning is expected when building the Rust core standalone.

To iterate on Rust changes against a shipped binary, build `libcarbonyl.{so,dylib}` and drop it next to `headless_shell` in a release build of Carbonyl — no Chromium rebuild needed.

## Runtime (Chromium)

All runtime operations go through the scripts in `scripts/`, which wrap `gclient`, `gn`, and `ninja` with the right `CARBONYL_ROOT` / `CHROMIUM_SRC` env. The `chromium/depot_tools` submodule is auto-fetched by `scripts/env.sh` when `INSTALL_DEPOT_TOOLS=true` (set by the wrapper scripts that need it).

```shell
./scripts/gclient.sh sync           # fetch Chromium tree into chromium/src
./scripts/patches.sh apply          # apply carbonyl patches to chromium/skia/webrtc
./scripts/gn.sh args out/Default    # opens editor for build args (see readme.md for args)
./scripts/build.sh Default          # builds libcarbonyl, copies into out/Default, runs ninja
./scripts/run.sh Default <url>
./scripts/docker-build.sh Default {amd64|arm64}
```

`build.sh <target> <cpu>` cross-compiles: it runs `cargo build --target $(scripts/platform-triple.sh $cpu) --release`, copies the produced dylib/so into `$CHROMIUM_SRC/out/$target/`, then runs `ninja headless:headless_shell`. Set `CARBONYL_SKIP_CARGO_BUILD=1` to skip the Rust step and only re-link Chromium.

### Patch workflow

`scripts/patches.sh` manages three patch stacks pinned to specific upstream SHAs (`chromium_upstream`, `skia_upstream`, `webrtc_upstream` in the script):

- `apply` — stashes local changes in each tree, checks out the pinned SHA, and `git am`s the patches from `chromium/patches/{chromium,skia,webrtc}/`. **This reverts any unsaved changes in the Chromium tree.**
- `save` — regenerates those patch directories from the current state of each tree via `git format-patch` relative to the pinned SHA. Run this after modifying Chromium/Skia/WebRTC source before committing.

When bumping Chromium, update the three `*_upstream` SHAs in `patches.sh` and re-save.

## FFI bridge

`src/browser/bridge.rs` + `src/browser/bridge.{cc,h}` is the boundary: all `#[repr(C)]` structs (`CSize`, `CPoint`, `CRect`, `CColor`, `CText`, `RendererBridge`) and exported `extern "C"` functions must stay in sync with the C++ side. `src/browser/BUILD.gn` declares four Chromium components — `mojom`, `bridge`, `viz`, `renderer` — and links the Rust static lib via the `lib` config, which hardcodes the path `//carbonyl/build/$target/release`. That path expectation is why `build.sh` cross-compiles into `build/<triple>/release/` specifically.

The IPC contract between the C++ `viz`/`renderer` components and Blink is defined in `src/browser/carbonyl.mojom`.

## Source layout (Rust)

- `src/browser/` — FFI bridge to Chromium (Rust + C++ + mojom).
- `src/cli/` — argv parsing and usage text (`usage.txt` is embedded).
- `src/gfx/` — geometry primitives (`Point`, `Rect`, `Size`, `Vector`, `Color`, `Cast`).
- `src/input/` — terminal input: TTY raw mode, keyboard/mouse parsing, DCS escape sequences.
- `src/output/` — rendering pipeline: `RenderThread`, `Window`, painter, quad, kd-tree + quantizer (color → terminal cell), xterm backend, frame sync.
- `src/ui/navigation.rs` — navigation actions surfaced through the bridge.
- `src/utils/` — logging and small helpers.

## Conventions

- Commits follow Conventional Commits; `cliff.toml` drives changelog generation. `chore:` is skipped in the changelog, `fix:` / `feat:` / `perf:` / `doc:` are grouped.
- `package.json` only exists so the prebuilt binary can be published to npm — it is not a Node project. `scripts/npm-package.{sh,mjs}` and `scripts/npm-publish.sh` drive the release.
- Carbonyl is primarily tested on Linux and macOS. The build and patch scripts are bash and rely on Unix tools (`install_name_tool`, `cp`, POSIX paths). On Windows, run them from WSL or Git Bash.
