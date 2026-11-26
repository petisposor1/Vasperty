# Vasperty Architecture

Vasperty is organized into 12 cohesive native modules under `src/`, built and verified through the root `build.ps1` driver.

## Subsystem Map

- **`src/core`**: Configuration (`vasperty.toml`, `VASPERTY_*` env vars), strict outside-repo asset policy (`ensure_outside_repo`), and zero-allocation runtime telemetry (`Frame_Telemetry`).
- **`src/pe`**: PE32+ parser, section RVA mapping, import/export tables, TLS callbacks, and full `DllCharacteristics` decoding.
- **`src/formats`**: `BCPack` rANS/dictionary texture decoder (`bcpack-tables.bin`), RDNA2 `64KB_S` 2D/3D tiling/detiling (`XG`), and `XMA2` IMDCT audio decoding.
- **`src/game`**: `CityHash64`, zero-copy shared-read `MapViewOfFile` `RPF9` (`9FPR`) streaming scanner, `RDS5`/`TTPF` tiled texture archive prober, `SGD5` shader database unpacker, and `PS\0\9` pipeline reconstruction.
- **`src/pipeline`**: SHA-256 keyed atomic disk cache with Windows concurrent-rename race recovery and stale temp pruning.
- **`src/loader`**: Console PE32+ image preparation, memory publishing, dynamic IAT/EAT thunks, and TLS callback orchestration.
- **`src/hle`**: Xbox Series HLE runtime covering 16 console DLLs (`XAsync`/`XTaskQueue`, `XMem` with `< 4 GiB` 32-bit range enforcement, `DirectStorage`, `XGameSave`, `XG`, `ACPHAL`/`DSP`/`APU`, loopback sockets, `oleaut32.dll` host forwarding).
- **`src/shader`**: RDNA2/GFX10 ISA decoder, SSA CFG node-splitting + BDD structurisation, compressed FP16x2 `exp` unpacking, `s_buffer_load_dword` / heap `rawBufferLoad` lowering, adaptive `Wave16`/`Wave32`/`Wave64` metadata, LDS bounds & `bpermute` lane scoping, **Mesh Shader -> Compute + Pass-Through VS fallback** (`mesh_fallback.odin`), and cached `dxil.dll` (`IDxcValidator`) validation.
- **`src/gpu`**:
  - `host.odin`: Live D3D12/DXGI hardware capability prober (`ARCHITECTURE1` UMA/CacheCoherentUMA, `OPTIONS2` DepthBounds, `OPTIONS0` TypedUAV, `OPTIONS5/6/7/19`).
  - `vendor_profile.odin`: Dedicated profiles for **NVIDIA (`Wave32`, Async Compute, DXR, 3 frames in flight, 256 MiB pool)** and **Intel Integrated (`Wave16`, UMA 64 MiB pool, Mesh Fallback + `Mesh_Scratch_Ring`, 2 frames in flight)**, plus `Frame_Ring` and disk-backed `Pipeline_Library_Cache`.
  - `d3d12_exec.odin`: Real D3D12 `Host_Executor` (`ID3D12Device`, Direct + Async Compute `ID3D12CommandQueue`, per-slot `ID3D12CommandAllocator` ring, `ID3D12GraphicsCommandList`, `ID3D12Fence`).
  - `swapchain.odin`: `Swapchain_Engine` (HDR10/SDR config, multi-plane `PresentX` compositor, zero-alloc 64-frame `Frame_Pacer`).
  - `bvh_rt.odin`: `Bvh_Rt_Manager` routing ray-tracing BVH builds to hardware DXR or Compute BVH4 fallback with 256-byte D3D12 alignment.
  - `resources.odin` & `pipeline_bridge.odin`: 2-level page tables, `Dirty_Bitmap` (`u64` CTZ word-skip), branchless `u64`-stride `shadow_merge_writeback`, integer RT blend sanitization, and typed UAV format guards.
- **`src/app` & `src/cli`**: High-level orchestrator, multi-threaded work-stealing `translate --jobs N --limit N`, `probe --scan`, `doctor --json`, `census`, `inspect`, `run`, and `bench`.
- **`src/tests`**: Full leak-checked (`Tracking_Allocator`) verification suite asserting **0 leaks and 0 bad frees**.
