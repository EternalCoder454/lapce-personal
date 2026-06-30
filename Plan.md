# Lapce Personal — Project Plan & Notes

> Personal working notes for my fork of [Lapce](https://github.com/lapce/lapce).
> Covers what the project is, how it's put together, how to build/run it, and a vetted
> plan for keeping dependencies and the toolchain up to date.

_Last reviewed: 2026-06-29. Baseline `cargo check --workspace` passes cleanly (Rust 1.96.0)._

---

## 1. What this is

Lapce is a desktop code editor written entirely in Rust. The UI is built on **Floem**
(a reactive, signal-based UI framework) and renders on the GPU through **wgpu**. The
text engine descends from Xi-Editor's "rope science" — text is stored in an immutable
**rope** data structure, which makes edits, undo/redo, and large-file handling cheap.

Headline features:

- Built-in **LSP** support (completion, diagnostics, hover, definitions, references, rename, formatting…)
- **Modal (Vim-like) editing** as a first-class, toggleable mode
- **Remote development** (SSH / WSL) where the backend runs on the remote host
- **WASI plugins** — plugins compile to WebAssembly and run sandboxed
- **Built-in terminal** (Alacritty's emulation core)
- **Debugging** via the Debug Adapter Protocol (DAP)
- **Git** integration (via `git2`)

---

## 2. Workspace layout

It's a Cargo workspace with four member crates plus a thin root binary.

| Crate | Role |
| --- | --- |
| **`lapce-app`** | The UI client. Windows, tabs, panels, the editor view, config, keymaps, command palette, completion/hover UI, terminal UI, git/debug panels. Built on Floem. |
| **`lapce-core`** | UI-free text logic. Re-exports rope/buffer primitives from `floem-editor-core`, plus tree-sitter syntax highlighting, language detection, encoding, directory scanning. |
| **`lapce-proxy`** | The backend process. Does file I/O, runs LSP servers, hosts WASI plugins (via `wasmtime`), drives terminals (PTYs), and watches the filesystem. Can run **locally or on a remote host**. |
| **`lapce-rpc`** | Shared, serializable types and the JSON-RPC protocol used between the app and the proxy. The contract that lets the proxy run remotely. |

Root `Cargo.toml` builds two binaries: `lapce` (the app, entry `lapce-app/src/bin/lapce.rs`)
and `lapce-proxy` (the backend, entry `lapce-proxy/src/bin/lapce-proxy.rs`).

```
lapce (root binary)
  └─ app::launch()
       ├─ lapce-app  ── depends on ── lapce-rpc, lapce-core, lapce-proxy, floem
       └─ lapce-proxy (separate process)
                       └─ depends on ── lapce-rpc, lapce-core, wasmtime, alacritty_terminal, git2
            ▲                                   ▲
            └──────── JSON-RPC over stdio ──────┘
                 (same protocol works over SSH for remote dev)
```

---

## 3. How it works

### The app ↔ proxy split

This is the central design idea. The **app** is pure UI; anything that touches the OS,
the network, language servers, or plugins happens in the **proxy**, a separate process.
They talk over JSON-RPC (`lapce-rpc`):

- **App → Proxy:** `ProxyRequest` (file ops, LSP queries, search, plugin install, terminal input…)
- **Proxy → App:** `ProxyResponse` (request replies) and `CoreNotification` (diagnostics, terminal output, file-changed events, plugin lifecycle…)

Because the boundary is a serializable RPC channel, the proxy can run on a **remote machine**
over SSH while the UI stays local — that's how remote development works for "free."

### Startup

1. `lapce` parses CLI args, builds `AppData` (windows, config, file watchers, signals), and starts the Floem event loop.
2. Opening a window spawns a **proxy** process and the RPC handler threads, then sends an `initialize` notification (workspace, plugins, window/tab ids).
3. The proxy loads plugins and language servers; the app builds the window → tab → split → editor view tree.

### Input → render data flow (typing a character)

```
Floem key event → EditorData.receive_char()
   ├─ rope insert (new immutable rope + RopeDelta + bumped revision)
   ├─ incremental tree-sitter re-parse (syntax styles)
   ├─ async LSP completion request → proxy → language server → CoreNotification back
   └─ signals update → Floem recomputes layout → wgpu renders the frame
```

Everything in the UI is driven by Floem **reactive signals** (`RwSignal`/`ReadSignal`):
mutating state automatically invalidates and re-renders only the affected views.

### Subsystems at a glance

- **Editor/buffer** — `lapce-app/src/editor.rs`, `lapce-app/src/doc.rs`. `Doc` wraps a rope; `DocContent` distinguishes File/Local/History/Scratch buffers; undo/redo and diagnostics live here.
- **LSP** — UI helpers in `lapce-app/src/lsp.rs`; the real client is in `lapce-proxy/src/plugin/lsp.rs`. One language server per language; requests routed by file/language.
- **Plugins (WASI)** — `lapce-proxy/src/plugin/wasi.rs` runs each plugin in an isolated `wasmtime` instance; they speak the Plugin Server Protocol (`psp-types`) and can spawn language servers, register debuggers, run shell commands, or make HTTP calls. Discovered from `volt.toml` manifests.
- **Terminal** — UI in `lapce-app/src/terminal/`, PTY + Alacritty emulation in `lapce-proxy/src/terminal.rs`. Keystrokes go app→proxy→PTY; output comes back as `UpdateTerminal` notifications.
- **Syntax highlighting** — `lapce-core/src/syntax/`. Tree-sitter, incremental on edits, emits per-line style spans; LSP semantic tokens can override.
- **Commands & keymaps** — `lapce-app/src/command.rs`, `lapce-app/src/keypress/`. Key events resolve against TOML keymaps (`lapce-app/defaults/keymaps-*.toml`) with modal/focus conditions, then dispatch to the focused component. Modal editing tracked via motion modes.
- **Config & themes** — `lapce-app/src/config/`. Layered defaults → system → workspace → plugin, hot-reloaded by a file watcher. Color/icon themes are TOML.
- **Find/replace** — `lapce-app/src/find.rs` (regex, case modes, whole-word).
- **Source control** — `lapce-app/src/source_control.rs` + `git2` in the proxy; diffs rendered in `lapce-app/src/editor/diff.rs`.
- **Debug (DAP)** — `lapce-app/src/debug.rs` + `lapce-proxy/src/plugin/dap.rs`.

---

## 4. Building & running

Rust **1.96.0** is installed locally (at `~/.cargo/bin`). The workspace pins
`rust-version = 1.87.0` and uses the **2024 edition**, so the installed toolchain is fine.

> Note: after installing Rust, `cargo`/`rustc` may not be on the shell PATH until the
> machine (or terminal) is restarted. Until then, invoke them via `~/.cargo/bin/cargo`.

```sh
cargo check --workspace                              # fast type-check (verified passing)
cargo run --bin lapce                                # debug run
cargo run --profile fastdev --bin lapce              # deps optimised, our code in debug (good dev loop)
cargo install --path . --bin lapce --profile release-lto --locked   # full optimised install
```

Build profiles defined in `Cargo.toml`:
- `release-lto` — full LTO, single codegen unit (release artifacts).
- `fastdev` — our crates in dev mode, all dependencies at `opt-level = 3`. Best day-to-day profile.

Platform build deps (Linux) are in [`docs/building-from-source.md`](docs/building-from-source.md).
On Windows the standard MSVC toolchain is sufficient.

---

## 5. Update plan

### Current state

- ✅ **Baseline verified.** `cargo check --workspace` compiles cleanly with no errors against the committed `Cargo.lock`.
- The toolchain (1.96.0) is well ahead of the pinned minimum (1.87.0) — no action needed there.
- A `cargo update --dry-run` shows a **large number** of available patch/minor bumps across the dependency tree (e.g. `anyhow 1.0.69→1.0.103`, `bytes 1.5→1.12`, `cc 1.0.99→1.2.65`, `bitflags 2.9→2.13`, and many more).

### Important constraint: pinned git revisions & patches

`Cargo.toml` deliberately pins several dependencies to **exact git revisions** and applies
`[patch.crates-io]` overrides. These are intentional and must **not** be casually bumped:

- `floem` / `floem-editor-core` — pinned git rev. The whole UI is built on this; the API moves fast. Upgrading is a dedicated task, not a routine bump.
- `tracing*` — pinned to a git rev (all four crates must move together).
- `alacritty_terminal`, `psp-types`, `structdesc`, `wasi-experimental-http`, `vger-rs`, `muda`, `locale_config` — pinned git revs.
- `[patch]` on `lsp-types` (locked for a debug-message feature), `regalloc2`, and `dpi` (works around a cargo-vendor duplicate). `lsp-types` is noted in-file as "lock to patch versions only."
- `toml = "*"` — currently an unbounded version; worth pinning for reproducibility.

### Stage 1 — DONE (2026-06-29)

Ran a full `cargo update` (353 packages refreshed within their semver constraints) and
verified the result. One genuine break surfaced and was fixed:

- **Break:** the unpinned git dep `wasi-experimental-http-wasmtime` declares `wasmtime = "*"`.
  Once `cargo update` made wasmtime **37.0.3** available, that wildcard grabbed it (nothing
  else in the tree wanted 37), and wasmtime 37's stricter `Linker::func_wrap` (`T: 'static`)
  failed to compile the crate (5× `E0310`).
- **Fix (forward, not a downgrade):** vendored that crate into
  [`third_party/wasi-experimental-http-wasmtime`](third_party/wasi-experimental-http-wasmtime),
  changed its `wasmtime = "*"` → `"14"`, added the `T: 'static` bound to `add_to_linker`, and
  repointed `lapce-proxy` at the local path (excluded from the workspace). The proxy stays on
  the **latest 14.x (14.0.4)** and wasmtime 37 is gone from the tree entirely.
- **Verified green:** `cargo fmt --all --check`, `cargo check --all-targets`,
  `cargo clippy --all-targets` (warnings only, pre-existing), and `cargo test` — **38 tests
  pass, 0 fail**. Baseline-vs-updated logs captured during the run.
- **Note:** moving the proxy to wasmtime **37** is out of scope — it would require rewriting
  `lapce-proxy/src/plugin/wasi.rs` against ~23 majors of API change. Separate project.

### Recommended staged approach

Do these one stage at a time, running `cargo check --workspace` (and ideally a real
`cargo run --bin lapce` smoke test) after **each** stage, committing only when green.

1. **Stage 1 — safe in-semver refresh.** Run `cargo update` (registry crates only; this respects the version constraints in `Cargo.toml` and leaves the pinned git revs alone). Re-check, run the app briefly, commit the new `Cargo.lock`. This captures the bulk of the available updates with the lowest risk.
2. **Stage 2 — pin the loose dep.** Change `toml = "*"` to a concrete version (whatever Stage 1 resolved to). Re-check, commit.
3. **Stage 3 — workspace dependency bumps (optional).** Bump explicit minor versions in `[workspace.dependencies]` (e.g. `git2`, `reqwest`, `regex`, `clap`) one cluster at a time. These can pull breaking changes despite semver, so isolate them. Re-check after each.
4. **Stage 4 — git-pinned crates (advanced, separate effort).** Updating `floem`/`tracing`/etc. to newer revisions can break compilation and behaviour. Only attempt deliberately, one crate at a time, with a full build + manual testing. Treat as its own project, not part of routine maintenance.

### Verification checklist for any update

- [ ] `cargo check --workspace` is clean
- [ ] `cargo clippy --workspace` has no new warnings (CONTRIBUTING expects fmt + clippy)
- [ ] `cargo fmt --all --check` is clean
- [ ] `cargo run --bin lapce` launches; open a file, type, save, open the terminal, trigger completion
- [ ] `Cargo.lock` committed alongside the `Cargo.toml` change
- [ ] Note the change in `CHANGELOG.md` under "Unreleased" if meaningful

### Things to leave alone

- The `[patch.crates-io]` block and pinned git revs unless you're intentionally doing Stage 4.
- The `lsp-types` version (locked on purpose — see the comment in `Cargo.toml`).
- The `lsp-types` version (locked on purpose — see the comment in `Cargo.toml`).

---

## 5b. Performance & memory notes (2026-06-29)

Measured on Windows 11, idle (no workspace open), using Task Manager's metric
(private working set):

| Build | RAM |
| --- | --- |
| `cargo run` (**debug**) | ~324 MB |
| `cargo build --release` | **~226 MB** |
| Upstream Lapce (reference) | ~240 MB |

**Conclusion: the single biggest lever is building in release.** The debug binary
carries ~100 MB of extra RAM (no optimisation + debug assertions + debuginfo). The
release build idles *below* the upstream reference, so there's no bloat from our
changes. For daily use, run/install a release build:

```sh
cargo run --release --bin lapce            # or --profile fastdev for dev iteration
cargo install --path . --bin lapce --profile release-lto --locked
```

At ~226 MB the residency is dominated by the wgpu GPU renderer (glyph atlas,
swapchain, embedded font/icon data) plus any LSP **child processes** (counted as
separate processes — e.g. `rust-analyzer.exe` — and not reducible from here).

### Startup time (optimised 2026-06-29)

Profiled with `LAPCE_STARTUP_TRACE=1` (prints per-phase ms to stderr; release build,
`--new --wait`, warm). Per-phase cost *before*:

| Phase | This phase |
| --- | --- |
| fonts (embedded DejaVu) | ~12 ms |
| **shell_env** (`load_shell_env`) | **~125 ms** |
| db (`LapceDb::new`) | ~6 ms |
| config (`LapceConfig::load`) | ~10 ms |
| windows (`create_windows`) | ~9 ms |
| floem/wgpu first frame | ~20 ms |
| **time-to-window** | **~187 ms** |

`load_shell_env()` spawns **PowerShell** (`Get-ChildItem env:`) to read the shell
environment — on Windows that's redundant (a GUI process already inherits the full
user/system env from the registry) and dominates startup. Worse, on the normal
double-click path it ran **twice** (the parent process runs it, then relaunches
itself with `--wait` and the child runs it again).

**Fix:** skip the PowerShell probe on Windows by default (opt back in with
`LAPCE_LOAD_SHELL_ENV=1`). Result: `shell_env` ~125 ms → ~4 ms, **time-to-window
~187 ms → ~62 ms (~3x)**. Non-Windows behaviour is unchanged.

Remaining startup is fonts (~12 ms) + floem/wgpu first frame (~20 ms); both are
inherent and not worth chasing.

### Edit / layout latency

The `visual_line` criterion bench (`cargo bench -p lapce-app --bench visual_line`)
is the regression guard for editor layout. Baseline hot paths: last-vline 17 ns,
vline-of-offset 2.3 µs, and the wrapping cases 76–104 µs. These live in **floem's
editor core** (a pinned git dep), so they're a measurement baseline rather than a
place we can optimise without forking floem. Keystroke→buffer edits go through the
rope (immutable, cheap) and incremental tree-sitter; nothing in our code stood out
as wasteful, and edit latency is already in the µs range.

**Ruled out (would hurt more than help):**
- `panic = "abort"` — a panic in any worker thread (plugin/LSP/terminal/watcher)
  would take down the whole editor instead of just that thread. Frontend-stability risk.
- Stripping symbols (`strip = true`) — release already emits no debuginfo; this would
  only drop the symbol table, degrading panic backtraces in the custom crash logger
  for a disk-size-only saving (no RAM benefit).
- `mimalloc` global allocator — possible small private-RAM win, but we're already under
  the reference, so not worth the dependency/risk. Revisit only if a real regression appears.

**Windows-only cleanup:** removed non-Windows packaging/CI artifacts (`docker-bake.hcl`,
`.dockerignore`, `lapce.spec`, `extra/linux/`, `extra/macos/`, `extra/entitlements.plist`).
This is repo hygiene only — it does **not** change the Windows binary or its RAM, because
that code/data is already excluded by `#[cfg]`/target gates. Note: `extra/proxy.sh` is
**kept** even on Windows — it's `include_bytes!`'d into the binary and uploaded to remote
*Unix* hosts during remote development.

---

## 5c. Security audit (2026-06-29)

Ran `cargo audit` (RustSec advisory DB) against `Cargo.lock`. 21 advisories initially;
the actionable picture:

- **wasmtime / wasi ecosystem (~17, incl. 2 "critical")** — **RESOLVED** by the
  wasmtime 14 → 46 upgrade (see below). All wasmtime/wasi advisories cleared; the
  remaining audit findings are git2 and the unmaintained-crate warnings.
- **`time` (RUSTSEC-2026-0009, medium DoS)** — **FIXED.** Bumped MSRV 1.87 → 1.88 so the
  resolver could take `time` 0.3.51 (≥ 0.3.47).
- **`git2` ×2 (potential UB)** — **no patched release exists yet** (no `Solution:` in the
  advisory). Nothing to upgrade to; revisit when upstream ships a fix.
- **~11 "unmaintained" warnings** (`bincode`, `ttf-parser`, `paste`, `mach`, `fxhash`,
  `rustls-pemfile`, …) — all transitive via floem/wasmtime, not directly fixable here, low risk.

Re-run `cargo audit` after dependency changes. To regenerate: `cargo install cargo-audit`
then `cargo audit`. The project also ships a `deny.toml` for `cargo deny` if you want
license/ban checks too.

> MSRV note: the bump to **1.88** means newer crate versions are now selectable. A future
> blanket `cargo update` could therefore pull more than before — keep updates staged and
> verified (see §5).

## 5d. wasmtime 14 → 46 upgrade (2026-06-29)

Upgraded the WASM plugin runtime from wasmtime **14.0.4** to **46.0.1** (latest stable).
Motivation: it clears all outstanding wasmtime/wasi security advisories (~17, incl. 2
critical). The WASI API was rewritten between these versions, so this touched two places:

- **`lapce-proxy/src/plugin/wasi.rs`** — ported to the wasmtime 46 preview1 API:
  `Store<WasiP1Ctx>`, `p1::add_to_linker_sync`, `WasiCtxBuilder::build_p1()`,
  `preopened_dir(path, "/", DirPerms, FilePerms)`. The old `wasi_common` shared
  `ReadPipe`/`WritePipe` were replaced by a custom `WasiPipe` that implements the 46
  stream traits (`InputStream`/`OutputStream`/`Pollable`/`StdinStream`/`StdoutStream`)
  directly over a shared `VecDeque`. An empty read returns `StreamError::Closed`, which
  preview1 maps to a 0-byte read (EOF-per-call, fd stays open) — matching the old pipe.
- **`third_party/wasi-experimental-http-wasmtime`** — only needed the `wasmtime = "46"`
  bump (its `Caller`/`Memory`/`func_wrap` usage is stable); the `T: 'static` bound added
  earlier still applies. Dropped its unused `wasmtime-wasi`/`wasi-common` deps.
- Removed the `[patch.crates-io] regalloc2` pin (it was for wasmtime 14's cranelift).
- New `lapce-proxy` deps: `wasmtime-wasi-io`, `bytes`, `tokio` (io-util).

**Verified:** compiles + links, 38 tests pass, clippy clean (for this code). **Runtime:**
launched the debug build on a Go project with the real `panekj.lapce-go` WASM plugin — it
instantiated, read its env, and ran the JSON-RPC initialize handshake through the new
pipes (`fd_read fd=0` / `fd_write fd=1` in the logs) with zero traps/panics.

> Note: the MSRV bump to 1.88 makes clippy's `collapsible_if` fire on the codebase's
> `if let X { if y }` patterns (let-chains are now stable) — a separate, mechanical
> cleanup (`cargo clippy --fix`), unrelated to this upgrade.

## 5e. CPU / parallelism perf (2026-06-29)

Targeting CPU/throughput (RAM is already good). Measured with the `visual_line`
bench and a new `search` bench (`cargo bench -p lapce-proxy --bench search`).

**Done & measured:**
- **`target-cpu=x86-64-v3`** (`.cargo/config.toml`) — lets the compiler use AVX2/FMA/
  BMI, a SIMD baseline every Win11-capable CPU supports (portable, not host-locked).
  ~3–5% on the heavier `visual_line` layout ops; noise on trivial ns-scale ones.
- **mimalloc** as `#[global_allocator]` for both bins — faster than the Windows system
  heap on allocation-heavy paths (rope/syntax/search/fuzzy). (Not captured by the
  benches, which are separate binaries without the global allocator.)
- **Parallel global search** (`lapce-proxy/src/dispatch.rs` `search_in_path`) — files are
  searched independently across the rayon pool (`par_iter().map_init(|| Searcher, …)`),
  results collected in path order. **3.32 ms → 755 µs (~4.4×)** on lapce-app/src;
  scales further on bigger trees. Per-file logic is byte-for-byte identical to the old
  sequential version, so results are unchanged.

**Why not "more async":** the proxy is OS-thread + crossbeam based (≈tens of threads:
one per LSP/terminal/plugin). Async (tokio) wins when you juggle *thousands* of idle I/O
waits — Lapce has ~10, so converting would be a huge rewrite for no speedup. The lever is
**parallelism** (rayon over CPU-bound, independent work), not async.

**Measured and rejected:**
- **Parallel directory walk** (`ignore::Walk` → `WalkBuilder::build_parallel`).
  Benchmarked seq vs parallel over the repo tree: **4.23 ms sequential vs 5.22 ms
  parallel (~23% slower)**. Listing files is syscall-bound and the `ignore` crate's
  sequential walk is already well-optimized; thread-coordination overhead makes the
  parallel version a regression for typical trees. Reading file *contents* (search)
  is the expensive part, and that is parallelized. Left sequential on purpose.

**Candidate next steps (not done — risk/▽value):**
- **PGO** (profile-guided optimization): a working build script ships at
  `scripts/build-pgo.ps1` (instrument → train on benches + a graceful editor session →
  rebuild with the profile). **Measured on the search hot path: 755 µs non-PGO vs 786 µs
  PGO — no benefit (slightly slower, within noise).** Expected: that path is I/O-bound and
  already parallel + SIMD-optimized, so there's little branch/layout for PGO to win. It's
  kept as an opt-in script (not baked into the default build, which would also hurt
  reproducibility); it may still help CPU-bound editing/syntax paths under a real-usage
  training run — worth trying with your own workflow as the profile.
- Allocation trims in search result building, `Cow<str>` for symbol parents,
  `SmallVec` for palette match indices — small, local wins.

## 6. Personalisation backlog (ideas)

Since this is a personal fork, candidate tweaks to make it mine:

- Default keymaps/settings baked into `lapce-app/defaults/` to match my workflow.
- Trim CI / packaging files I don't use.
- Pin a default color/icon theme.
- Keep this file and the README current as I diverge from upstream.

---

## 7. Quick file reference

| Area | Path |
| --- | --- |
| App entry | `lapce-app/src/bin/lapce.rs` → `lapce-app/src/app.rs` |
| Proxy entry | `lapce-proxy/src/bin/lapce-proxy.rs` → `lapce-proxy/src/lib.rs` |
| RPC contract | `lapce-rpc/src/proxy.rs`, `lapce-rpc/src/core.rs` |
| Editor / document | `lapce-app/src/editor.rs`, `lapce-app/src/doc.rs` |
| LSP client | `lapce-proxy/src/plugin/lsp.rs` |
| Plugins (WASI) | `lapce-proxy/src/plugin/wasi.rs`, `lapce-proxy/src/plugin/catalog.rs` |
| Terminal | `lapce-proxy/src/terminal.rs`, `lapce-app/src/terminal/` |
| Syntax | `lapce-core/src/syntax/mod.rs` |
| Keymaps | `lapce-app/src/keypress/`, `lapce-app/defaults/keymaps-*.toml` |
| Config | `lapce-app/src/config/` |
| Workspace manifest | `Cargo.toml` |
