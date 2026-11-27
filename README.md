# Vasperty

**Vasperty is not a casual fork — it has been brutally rebuilt from the ground up in 100% pure Odin.**

Engineered from scratch as a self-contained, zero-bloat Xbox Series (Scarlett) PE32+/DLL loader, HLE runtime, RDNA2/GFX10-to-DXIL Shader Model 6.6 compiler, and live D3D12.X virtualization engine tailored for **NVIDIA** and **Intel Integrated / Arc** GPUs.

> **100% Pure Native Odin (`0` `.rs` files):** Since our initial `origin/main` baseline (`c05c3c5`), over **123,000+ lines** of legacy code were stripped and replaced across **240+ files** with a clean, **Tracking-Allocator leak-verified** 12-module Odin engine compiling directly against core Windows libraries.

---

## Quantum Leap Since Last Push (`c05c3c5` -> `HEAD`)

At the previous baseline (`c05c3c5`), only the core config/PE scaffolding existed. Today, Vasperty boots complex Xbox Series binaries into live D3D12.X GPU rendering, video playback, interactive UI, and real-time multi-thousand-shader translation:

| Subsystem | Baseline (`c05c3c5`) | Now (`HEAD` — Pure Odin Rebuild) |
| :--- | :--- | :--- |
| **Core Engine** | Odin Phase 1 (`core` + `pe` skeleton) | **All 7 architecture phases complete** across 12 native modules (`0` legacy `.rs` files) |
| **GPU / D3D12.X** | Stub interfaces only | **Live host D3D12 execution**: 96-slot `Console_Device`, CommandLists/Queues/Fences, **Compute + Texture2D UAV dispatch**, 16 MiB persistent upload ring, multi-plane **4K `PresentX`** (`DXGI_SCALING_STRETCH`, HDR10, `VASPERTY_NO_VSYNC=1`), async `Frame_Ring`, incremental 64 KiB dirty-page copy-back |
| **Shader Compiler** | Offline prototype only | **Live RDNA2/GFX10 -> SM 6.6 DXIL**: MIMG NSA decoding, `image_store*`, `buffer_store*`, `image_get_resinfo`, `s_buffer_load_dword`, 35+ VALU/SALU/Image ops, **195 merged GS/ES/HS/LS** shaders unlocked, **5,000 / 5,000** `shaders.rpf` translation sweeps, BDD CFG structurisation with per-worker `Dynamic_Arena`, adaptive **`Wave16` / `Wave32` / `Wave64`** lowering |
| **HW Fallbacks** | None | **`Mesh -> Compute+VS` fallback (`Mesh_Scratch_Ring`)** & **`Bvh_Rt_Manager`** (DXR + Compute BVH4 fallback) for Intel iGPU & older NVIDIA cards, cached `dxil.dll` `IDxcValidator` |
| **Loader & ABI** | Basic PE header inspect | Full PE32+ relocatable mapping, TLS callbacks, **`DIR_EXPORT` parsing & automatic sibling DLL loading**, Win64 ABI fixes (`GetCustomHeapProperties` sret, `XMemAllocatePhysicalPages`, `XDspActivate`, `XGameSave`) |
| **CPU / HLE / Media** | Minimal stubs | **AMD SSE4a instruction emulation via VEH**, `<4 GiB` demand-commit `XMem`, `XAsync` / `XTaskQueue` completion & callbacks, `DirectStorage`, `XG` `64KB_S` tiling/detiling, `BCPack`, `XMA2` IMDCT, video decode acceleration |
| **Input & Live Window** | None | **Full `GameInput` stack**: 4-slot XInput + WinMM PlayStation/generic gamepads + full keyboard mapping + headless/fast-test automation flags |

---

## Key Architecture Highlights

- **Vendor-Adaptive GPU Execution**:
  - **NVIDIA GPUs (`Wave32`)**: Async compute scheduling, hardware DXR/BVH readiness, depth-bounds support, disk-backed `Pipeline_Library_Cache`, 3 frames in flight, 256 MiB transient pool.
  - **Intel Integrated GPUs (`UHD / Xe UMA Wave16`)**: UMA-aware 64 MiB transient budget, `Wave16` subgroup targeting with `Wave64` emulation guards, automatic mesh-shader fallback paths (`Mesh_Scratch_Ring`), low-RAM streaming archive probing (`RPF9` / `TTPF`), 2 frames in flight.
  - **Intel Arc / AMD RDNA / WARP**: Dedicated discrete Arc (`Xe-HPG`), AMD RDNA (`Wave64`/`Wave32`), and Microsoft WARP fallback profiles.
- **Asynchronous Multi-Frame Scheduler (`Frame_Ring`)**: Monotonic fence tracking + 16 MiB persistent upload ring + incremental 64 KiB dirty-page copy-back (`shadow_copy_back_pages`) eliminating per-frame CPU/GPU stalls.
- **Native RDNA2 / GFX10 -> SM 6.6 Compiler (`vasperty:shader`)**:
  - Zero-copy `MapViewOfFile` streaming readers for `RPF9` (`9FPR`), `TTPF`, `SGD5`, `PS\0\9`, `ACCC`, `XDAT`, and embedded PE DLL DXBC containers.
  - Multi-threaded work-stealing `translate --jobs N` with lock-free per-worker `Dynamic_Arena` allocation.

---

## Modules (`src/`)

| Module | Responsibility |
| :--- | :--- |
| `src/core` | TOML/env config (`VASPERTY_*` / `vasperty.toml`), repo-root detection, strict outside-repo asset policy |
| `src/pe` | Zero-allocation PE32+ parser, section RVA mapping, imports/exports, TLS, exceptions |
| `src/formats` | `BCPack` rANS + dictionary decoder (`bcpack-tables.bin`), `XG` RDNA2 `64KB_S` tiling/detiling, `XMA2` IMDCT audio |
| `src/game` | `CityHash64`, streaming `RPF9` (`9FPR`) & `TTPF` readers, `SGD5` databases, `PS\0\9` pipeline reconstruction |
| `src/pipeline` | SHA-256 keyed pipeline cache with atomic write/temp pruning |
| `src/loader` | Console PE32+ image preparation, sibling DLL autoloading, IAT/EAT thunks, TLS orchestration |
| `src/hle` | Xbox Series runtime (`XAsync`, `XMem`, `DirectStorage`, `XGameSave`, `XG`, `ACPHAL`/`DSP`/`APU`, `GameInput`, loopback sockets) |
| `src/shader` | RDNA2/GFX10 decoder (incl. MIMG NSA & merged GS/HS), BDD structurisation, adaptive `Wave16`/`Wave32`/`Wave64` lowering, SM 6.6 DXIL emitter |
| `src/gpu` | Live D3D12.X host virtualization (`Console_Device`, Compute/UAV dispatch, `PresentX` 4K swapchain, `Frame_Ring`, BVH/Mesh fallbacks) |
| `src/app` | High-level runtime orchestrator, VEH CPU/SSE4a handler, hardware doctor, symbol census, batch translator, microbenchmarks |
| `src/cli` | Native `build\vasperty.exe` command-line entrypoint |
| `src/tests` | Leak-checked (`Tracking_Allocator`: `0 leaks, 0 bad frees`) unit & integration test suite |

---

## Quick Start (Windows)

```powershell
# Run type-check + asset policy + leak-checked tests + release build + diagnostics + benchmarks
.\build.ps1 all

# Individual targets
.\build.ps1 check    # Type-check all 12 modules with -vet
.\build.ps1 policy   # Audit repository against strict asset separation policy
.\build.ps1 test     # Execute test suite (verifies 0 leaks, 0 bad frees)
.\build.ps1 build    # Build optimized build\vasperty.exe (-o:speed)
.\build.ps1 doctor   # Inspect detected GPU profile, wave lane capabilities, and cache health
.\build.ps1 bench    # Run CityHash64, RDNA2 tile/detile, XMA2 IMDCT, PSO, and IR/BDD benchmarks
```

---

## CLI Reference (`build\vasperty.exe`)

```text
vasperty.exe status
vasperty.exe config
vasperty.exe doctor [--prune-cache] [--json]
vasperty.exe inspect <pe-path> [--imports] [--exports]
vasperty.exe census <paths...> [--strict] [--missing]
vasperty.exe translate <paths...> [--validate] [--wave16|--wave32|--wave64] [--jobs N] [--limit N]
vasperty.exe probe <archives...> [--scan]
vasperty.exe run <exe-path> [--strict] [--zero] [--execute] [--series-s]
vasperty.exe bench [seconds]
```

### Runtime Environment Toggles
- `VASPERTY_NO_VSYNC=1`: Uncaps swapchain presentation (`SyncInterval=0`) for high-throughput testing.
- `VASPERTY_SCREENSHOT_DIR` / `VASPERTY_SCREENSHOT_PREFIX`: Captures host swapchain frames externally without touching the repository tree.
- `VASPERTY_GAME_DIR` / `VASPERTY_CACHE_DIR` / `VASPERTY_DATA_DIR`: Redirects runtime assets and shader/PSO caches outside the repository (defaults to `%LOCALAPPDATA%\Vasperty`).

---

## Configuration & Asset Policy

Vasperty strictly separates engine code from user-supplied runtime assets. No proprietary binaries, dumps, captures, logs, or local machine paths may ever reside inside the repository tree.

1. Copy `vasperty.example.toml` to `vasperty.toml` (already gitignored) or configure `VASPERTY_*` environment variables.
2. Verify repository cleanliness at any time with:
   ```powershell
   .\build.ps1 policy
   ```
   See [docs/asset-policy.md](docs/asset-policy.md) for the full policy specification.

---

## Lineage & Acknowledgments

Initial Xbox Series reverse-engineering research began with [Marvisak/VIctory](https://github.com/Marvisak/VIctory). **Vasperty** has since undergone a complete, ground-up architectural rewrite in pure Odin focused on real-time host D3D12.X virtualization, NVIDIA/Intel vendor optimization, live RDNA2-to-SM6.6 shader compilation, and strict leak-free native execution.
