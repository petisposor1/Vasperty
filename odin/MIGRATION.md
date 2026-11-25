# Vasperty Odin Rewrite Roadmap

> **Baseline:** Synced against `Marvisak/VIctory` commit `13f91ca` (GTA VI prologue reached at ~1 fps) plus all Vasperty enhancements.

This document tracks the progressive, module-by-module rewrite of Vasperty from Rust (`crates/`, ~112k LOC across 10 workspace crates) to **Odin** (`odin/`) with zero-dependency core subsystems, explicit memory ownership verified under `mem.Tracking_Allocator`, and aggressive data-oriented layout.

## Native Build Pipeline (`odin/build.ps1`)

Because developers on Windows often run without Visual Studio or Windows SDK libs installed (relying on LLVM-MinGW UCRT), `odin/build.ps1` automatically supports both environments:
1. Checks every package cleanly with `odin check <pkg> -collection:vasperty=odin -vet`.
2. When Windows SDK libraries are present, invokes `odin build` directly.
3. Otherwise, compiles via `odin build -ignore-vs-search -build-mode:obj -use-single-module` and links natively with `llvm-mingw` `clang.exe -municode` + minimal CRT shims (`_fltused`, `__chkstk` -> `___chkstk_ms`) against UCRT & Win32 import libraries (`kernel32`, `bcrypt`, `synchronization`, `ntdll`, `user32`, `advapi32`, `shell32`, `ws2_32`, `ole32`, `uuid`).

## Subsystem Migration Status

| Phase | Rust Crate (`crates/`) | Odin Package (`odin/`) | Status | Highlights |
|-------|-------------------------|------------------------|--------|------------|
| **1** | `victory-core` | `vasperty:core` (`core/`) | **Implemented** | `.victory-root` containment guard (`ensure_outside_repo`), TOML + env `Config` resolver |
| **1** | `victory-pe` | `vasperty:pe` (`pe/`) | **Implemented** | Bounds-checked PE32+ parser: sections, imports, delay-imports, exports, TLS callbacks, RVA-to-offset |
| **1** | `victory-game` (hash/pack) | `vasperty:game` (`game/`) | **Implemented** | Bit-exact CityHash64 v1.1 + zero-copy `PS\0\x09` `ShaderPack` parser |
| **1** | `victory-formats` (texture) | `vasperty:formats` (`formats/`) | **Implemented** | RDNA2/GFX10.3 `Swizzle`, `Desc`, `Layout`, `offset`, multi-threaded `tile` & `detile` |
| **1** | `victory-pipeline` | `vasperty:pipeline` (`pipeline/`) | **Implemented** | Streaming SHA-256 multipart `CacheKey`, atomic staging & rename, `stats`, `prune_stale_temps` |
| **1** | `apps/victory` (tools) | `vasperty:cli` (`cli/`) | **Implemented** | Native `vasperty.exe` (`status`, `doctor`, `inspect`, `bench`) |
| **1** | Unit/Integration tests | `vasperty:tests` (`tests/`) | **Implemented** | Native `mem.Tracking_Allocator` harness asserting 0 leaks & 0 bad frees |
| **2** | `victory-formats` (`bcpack`, `xma`) | `vasperty:formats` (`formats/`) | **Implemented (100%)** | Compile-time `#load` BCPack rANS tables + BC1/3/4/5/6H/7 + parallel `bcpack_decode_batch`, full XMA2 packets/VLC/IMDCT decoder |
| **2** | `victory-game` (`pipelines`, `sgd5`) | `vasperty:game` (`game/`) | **Implemented (100%)** | Parallel CityHash64 raster/depth-stencil state resolvers, PSO stream builder, multi-core SGD5 raw-deflate unpacker |
| **3** | `victory-loader` | `vasperty:loader` (`loader/`) | **Implemented** | PE prepare (`IMAGE_FILE_DLL`/TLS/relocs), atomic staging publish, x64 import thunk stubs, static TLS redirection, Win32 `LoadLibraryExW` + eager IAT binding |
| **4** | `victory-hle` | `vasperty:hle` | Planned | Kernel/XMem/DirectStorage worker pool, GameInput rumble/battery, APU/XMA2 audio |
| **5** | `victory-shader` | `vasperty:shader` | Planned | RDNA2 scalar/vector/export decoder, CFG/SSA lowering, DXIL SM 6.6 bitcode emitter |
| **6** | `victory-gpu` | `vasperty:gpu` | Planned | Direct3D 12 host backend (`vendor:directx/d3d12`), placed heaps, barriers, shadow copy-back, swapchain |
| **7** | `apps/victory` (full host) | `vasperty:app` | Planned | Full end-to-end Odin runtime parity replacing the Rust host wrapper |
