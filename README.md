<h1 align="center">
  <img src="extra/images/logo.png" width=200 height=200/><br>
  Lapce Personal
</h1>

<h4 align="center">My personal build of the Lightning-fast And Powerful Code Editor</h4>

<br/>

> **Note:** This is a personal fork of [Lapce](https://github.com/lapce/lapce) that I maintain for my own use.
> It is not an official release and is not intended for distribution or use by others. Things may be changed,
> broken, or removed at any time to suit my own workflow. If you want the real thing, head to the
> [upstream project](https://github.com/lapce/lapce).

## About

Lapce is a code editor written in pure Rust, with a UI built on [Floem](https://github.com/lapce/floem). It is
designed with [Rope Science](https://xi-editor.io/docs/rope_science_00.html) from the
[Xi-Editor](https://github.com/xi-editor/xi-editor), enabling lightning-fast computation, and leverages
[wgpu](https://github.com/gfx-rs/wgpu) for rendering.

## Features

* Built-in LSP ([Language Server Protocol](https://microsoft.github.io/language-server-protocol/)) support for intelligent code features such as completion, diagnostics and code actions
* Modal editing support as a first-class citizen (Vim-like, and toggleable)
* Built-in remote development support inspired by [VSCode Remote Development](https://code.visualstudio.com/docs/remote/remote-overview)
* Plugins can be written in programming languages that can compile to the [WASI](https://wasi.dev/) format (C, Rust, [AssemblyScript](https://www.assemblyscript.org/))
* Built-in terminal, so you can execute commands in your workspace without leaving the editor

## Building

This is a Rust workspace. With a recent Rust toolchain installed (see `rust-version` in `Cargo.toml`):

```sh
# Quick check
cargo check --workspace

# Run the editor
cargo run --bin lapce

# Optimised local build
cargo run --profile fastdev --bin lapce

# Full release build
cargo install --path . --bin lapce --profile release-lto --locked
```

Platform-specific build dependencies are documented in [`docs/building-from-source.md`](docs/building-from-source.md).

## Project layout

| Crate | Responsibility |
| --- | --- |
| `lapce-app` | The editor application: UI (Floem), windows, panels, editor views, config, keymaps |
| `lapce-core` | Core editing primitives: buffer, syntax, movement, selections |
| `lapce-proxy` | Backend process that handles LSP, plugins (WASI), terminal and filesystem work |
| `lapce-rpc` | Shared RPC types and protocol used between the app and the proxy |

See [`Plan.md`](Plan.md) for a fuller write-up of how everything fits together and notes on maintenance.

## License

Based on Lapce, which is released under the Apache License Version 2. See [`LICENSE`](LICENSE) for the full text.
