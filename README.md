# Vasperty

**Vasperty** is a pure-Odin runtime, Xbox Series PE/DLL loader, HLE layer, RDNA2/GFX10-to-DXIL Shader Model 6.6 compiler, and Direct3D 12 virtualization layer built specifically for high-throughput host execution on **NVIDIA** and **Intel Integrated / Arc** GPUs.

---

## Key Capabilities

- **Zero External Build Baggage**: Pure Odin codebase (`odin/`) linking natively with LLVM-MinGW or MSVC SDK — no Cargo/Rust workspace overhead.
- **Vendor-Adaptive GPU Execution**:
  - **NVIDIA GPUs (`Wave32`)**: Async compute scheduling, hardware DXR/BVH readiness, depth-bounds support, persistent pipeline library caching, 3 frames in flight, and a 256 MiB transient buffer pool.
  - **Intel Integrated GPUs (`UHD / Xe UMA Wave16`)**: UMA-aware 64 MiB transient buffer budgeting, `Wave16` subgroup targeting with `Wave64 -> Wave16` emulation, automatic mesh-shader fallback paths, and 2 frames in flight to prevent shared-memory saturation.
  - **Intel Arc / AMD RDNA / WARP**: Dedicated discrete Arc (`Xe-HPG`), AMD RDNA (`Wave64`/`Wave32`), and Microsoft WARP software fallback profiles.
- **Asynchronous Multi-Frame Scheduler (`Frame_Ring`)**: Eliminates per-submission CPU/GPU pipeline stalls via monotonic fence tracking and 64 KiB dirty-page copy-back coalescing.
- **RDNA2 / GFX10 -> SM 6.6 DXIL Compiler (`vasperty:shader`)**:
  - Parses raw `DXBC`, `ACCC` (FSPX upscaler), `XDAT` (Xbox BVH / compute metadata), `SGD5` shader databases, `PS\0\9` shader packs, and embedded DXBC containers directly inside PE DLLs.
  - Decodes GFX10/RDNA2 ISA, performs CFG node-splitting + BDD structurisation, emits SM 6.6 LLVM 3.7 bitcode, and validates via host `dxil.dll` (`IDxcValidator`).
- **Complete Xbox Series HLE & Loader (`vasperty:loader` + `vasperty:hle`)**:
  - Relocatable PE32+ image preparation, TLS callback execution, dynamic IAT/EAT thunk binding, 16 emulated system/title DLLs, `XAsync`/`XTaskQueue`, `XGameSave`, `DirectStorage`, `XG` texture tiling/detiling (`BCPack` + RDNA2 `64KB_S`), and `XMA2` audio decoding.

---

## Pure-Odin Architecture

All engine subsystems live under `odin/`:

| Package | Responsibility |
| :--- | :--- |
| `vasperty:core` | TOML/env config (`VASPERTY_*` / `vasperty.toml`), repo-root detection, strict outside-repo asset policy |
| `vasperty:pe` | Zero-allocation PE32+ parser, section RVA mapping, imports/exports, TLS, exceptions |
| `vasperty:formats` | `BCPack` rANS + dictionary decoder (`bcpack-tables.bin`), `XG` RDNA2 `64KB_S` tiling/detiling, `XMA2` IMDCT audio |
| `vasperty:game` | `CityHash64`, `RPF9` (`9FPR`) streaming archive header reader, `SGD5` databases, `PS\0\9` pipeline state reconstruction |
| `vasperty:pipeline` | SHA-256 keyed pipeline cache with atomic write/temp pruning |
| `vasperty:loader` | Console PE32+ image preparation, memory publishing, import thunks, TLS orchestration |
| `vasperty:hle` | Xbox Series runtime (`XAsync`, `XMem`, `DirectStorage`, `XGameSave`, `XG`, `ACPHAL`/`DSP`/`APU`, loopback sockets) |
| `vasperty:shader` | RDNA2/GFX10 decoder, BDD structurisation, adaptive `Wave16`/`Wave32`/`Wave64` lowering, SM 6.6 DXIL emitter, embedded DXBC scanner |
| `vasperty:gpu` | D3D12/DXGI capability prober, NVIDIA/Intel tuning profiles, async `Frame_Ring`, 2-level page tables, barrier coalescer, shader cache bridge |
| `vasperty:app` | High-level runtime orchestrator, hardware doctor, symbol census, batch shader translator, microbenchmarks |
| `vasperty:cli` | Native `vasperty.exe` command-line entrypoint |
| `vasperty:tests` | Leak-checked (`Tracking_Allocator`) unit & integration test suite |

---

## Quick Start (Windows)

### Prerequisites
- [Odin Compiler](https://odin-lang.org/) (`odin.exe` in `PATH` or installed via WinGet)
- LLVM-MinGW UCRT (`clang.exe`) or Visual Studio Windows SDK

### Build, Verify & Benchmark
```powershell
# Run full check + asset policy + leak-checked tests + release build + diagnostics + benchmarks
.\odin\build.ps1 all

# Individual targets
.\odin\build.ps1 check    # Type-check all 12 packages with -vet
.\odin\build.ps1 policy   # Audit repository against strict asset separation policy
.\odin\build.ps1 test     # Execute test suite (verifies 0 leaks, 0 bad frees)
.\odin\build.ps1 build    # Build optimized odin\build\vasperty.exe (-o:speed)
.\odin\build.ps1 doctor   # Inspect detected GPU profile, wave lane capabilities, and cache health
.\odin\build.ps1 bench    # Run CityHash64, RDNA2 tile/detile, XMA2 IMDCT, PSO, and IR/BDD benchmarks
```

---

## CLI Reference (`odin\build\vasperty.exe`)

```text
vasperty.exe status
vasperty.exe config
vasperty.exe doctor [--prune-cache]
vasperty.exe inspect <pe-path> [--imports] [--exports]
vasperty.exe census <paths...> [--strict] [--missing]
vasperty.exe translate <paths...> [--validate] [--wave16|--wave32|--wave64]
vasperty.exe run <exe-path> [--strict] [--zero] [--execute] [--series-s]
vasperty.exe bench [seconds]
```

- `translate` accepts raw `.dxbc` blobs, `SGD5` shader databases, `PS\0\9` shader packs, **and PE DLLs containing embedded DXBC/`ACCC`/`XDAT` shaders**, automatically scanning and translating all embedded containers.

---

## Configuration & Asset Policy

Vasperty strictly separates engine code from user-supplied runtime assets. No proprietary binaries, dumps, or title files may ever reside inside the repository tree.

1. Copy `vasperty.example.toml` to `vasperty.toml` (already gitignored) or set environment variables:
   - `VASPERTY_CONFIG` (path to `.toml`)
   - `VASPERTY_GAME_DIR` (external title directory)
   - `VASPERTY_CACHE_DIR` (defaults to `%LOCALAPPDATA%\Vasperty\cache`)
   - `VASPERTY_DATA_DIR` (defaults to `%LOCALAPPDATA%\Vasperty\data`)
   - `VASPERTY_FIDELITYFX_DIR` (optional host FidelityFX override)
2. Verify repository cleanliness at any time with:
   ```powershell
   .\odin\build.ps1 policy
   ```
   See [docs/asset-policy.md](docs/asset-policy.md) for the full policy specification.

---

## Acknowledgments

Initial Xbox Series reverse-engineering research lineage began with [Marvisak/VIctory](https://github.com/Marvisak/VIctory). Vasperty is now an independent, pure-Odin project focused on native GPU vendor optimization (NVIDIA & Intel iGPU), asynchronous multi-frame execution, and self-contained shader translation.
