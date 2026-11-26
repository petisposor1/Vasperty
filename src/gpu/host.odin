package vasperty_gpu

import "core:strings"
import "core:sync"
import win32 "core:sys/windows"

LOAD_LIBRARY_SEARCH_SYSTEM32 :: u32(0x00000800)

foreign import kernel32_gpu "system:Kernel32.lib"
@(default_calling_convention = "system")
foreign kernel32_gpu {
	LoadLibraryExW :: proc(lpLibFileName: win32.LPCWSTR, hFile: win32.HANDLE, dwFlags: win32.DWORD) -> win32.HMODULE ---
}

foreign import user32_gpu "system:User32.lib"
@(default_calling_convention = "system")
foreign user32_gpu {
	EnumDisplaySettingsW :: proc(lpszDeviceName: win32.LPCWSTR, iModeNum: u32, lpDevMode: rawptr) -> win32.BOOL ---
}

// =========================================================================
// State masks & Power-of-two Buffer Pool
// =========================================================================

pc_state :: proc "contextless" (state: u32) -> u32 {
	return state & 0x01FF_FFFF
}

texture_state :: proc "contextless" (state: u32) -> u32 {
	BUFFER_ONLY :: u32(0x1 | 0x2 | 0x100 | 0x200)
	return pc_state(state) & ~BUFFER_ONLY
}

POOL_MAX_TOTAL_BYTES :: u64(128 << 20)
POOL_MAX_ENTRY_BYTES :: u64(32 << 20)

Pool_Entry :: struct {
	capacity: u64,
	handle:   rawptr,
	mapped:   uintptr,
}

Buffer_Pool :: struct {
	mu:              sync.Mutex,
	total_bytes:     u64,
	max_total_bytes: u64,
	entries:         [dynamic]Pool_Entry,
}

buffer_pool_init :: proc(max_bytes := POOL_MAX_TOTAL_BYTES) -> Buffer_Pool {
	return Buffer_Pool{
		max_total_bytes = max_bytes,
		entries         = make([dynamic]Pool_Entry),
	}
}

buffer_pool_destroy :: proc(bp: ^Buffer_Pool) {
	sync.mutex_lock(&bp.mu)
	defer sync.mutex_unlock(&bp.mu)
	for e in bp.entries {
		if e.handle != nil {
			com_release(e.handle)
		}
	}
	delete(bp.entries)
	bp.entries = nil
	bp.total_bytes = 0
}

buffer_pool_bucket :: proc(min_bytes: u64) -> u64 {
	v := max(min_bytes, u64(4096))
	// next power of two
	p := u64(4096)
	for p < v && p < (u64(1) << 62) {
		p <<= 1
	}
	return p
}

buffer_pool_take :: proc(bp: ^Buffer_Pool, min_bytes: u64) -> (Pool_Entry, bool) {
	need := max(min_bytes, u64(1))
	max_accept := max(need, u64(4096)) * 2
	sync.mutex_lock(&bp.mu)
	defer sync.mutex_unlock(&bp.mu)
	best := -1
	best_cap := u64(0)
	for e, idx in bp.entries {
		if e.capacity >= need && e.capacity <= max_accept {
			if best == -1 || e.capacity < best_cap {
				best = idx
				best_cap = e.capacity
			}
		}
	}
	if best < 0 {
		return {}, false
	}
	entry := bp.entries[best]
	unordered_remove(&bp.entries, best)
	if bp.total_bytes >= entry.capacity {
		bp.total_bytes -= entry.capacity
	} else {
		bp.total_bytes = 0
	}
	return entry, true
}

buffer_pool_put :: proc(bp: ^Buffer_Pool, entry: Pool_Entry) {
	if entry.capacity == 0 || entry.capacity > POOL_MAX_ENTRY_BYTES || entry.capacity > bp.max_total_bytes {
		if entry.handle != nil {
			com_release(entry.handle)
		}
		return
	}
	sync.mutex_lock(&bp.mu)
	defer sync.mutex_unlock(&bp.mu)
	bp.total_bytes += entry.capacity
	append(&bp.entries, entry)
	for bp.total_bytes > bp.max_total_bytes && len(bp.entries) > 0 {
		evicted := bp.entries[0]
		ordered_remove(&bp.entries, 0)
		if evicted.handle != nil {
			com_release(evicted.handle)
		}
		if bp.total_bytes >= evicted.capacity {
			bp.total_bytes -= evicted.capacity
		} else {
			bp.total_bytes = 0
		}
	}
}

// =========================================================================
// Dynamic D3D12 & DXGI loader + Host Capabilities Probe
// =========================================================================

IID_ID3D12Device :: Iid{0xF1, 0x19, 0x98, 0x18, 0xB6, 0x1D, 0x57, 0x4B, 0xBE, 0x54, 0x18, 0x21, 0x33, 0x9B, 0x85, 0xF7}
IID_IDXGIFactory4 :: Iid{0xEC, 0xE6, 0xC6, 0x1B, 0xE3, 0x0A, 0x44, 0x46, 0xB8, 0x8C, 0xF5, 0xE1, 0xA8, 0xE8, 0xD3, 0xB3} // {1BC6EA02... wait: use exact GUID
IID_IDXGIAdapter1 := guid(0x29038f61, 0x3839, 0x4626, {0x91, 0xfd, 0x08, 0x68, 0x79, 0x01, 0x1a, 0x05})
IID_IDXGIFactory4_G := guid(0x1bc6ea02, 0xef36, 0x464f, {0xbf, 0x0c, 0x21, 0xca, 0x39, 0xe5, 0x16, 0x8a})
IID_IDXGIFactory5_G := guid(0x7632e1f5, 0xee65, 0x4dca, {0x87, 0xfd, 0x84, 0xcd, 0x75, 0xf8, 0x83, 0x8d})

com_release :: proc(obj: rawptr) -> u32 {
	if obj == nil {
		return 0
	}
	IUnk_Vtbl :: struct {
		QueryInterface: rawptr,
		AddRef:         rawptr,
		Release:        proc "system" (rawptr) -> u32,
	}
	vt := (cast(^^IUnk_Vtbl)obj)^
	return vt.Release(obj)
}

com_query :: proc(obj: rawptr, iid: ^Iid) -> rawptr {
	if obj == nil {
		return nil
	}
	IUnk_Vtbl :: struct {
		QueryInterface: proc "system" (rawptr, ^Iid, ^rawptr) -> HRESULT,
	}
	vt := (cast(^^IUnk_Vtbl)obj)^
	res: rawptr
	if vt.QueryInterface(obj, iid, &res) >= 0 {
		return res
	}
	return nil
}

D3D12_Dll_Procs :: struct {
	loaded:            bool,
	d3d12_mod:         win32.HMODULE,
	dxgi_mod:          win32.HMODULE,
	create_device:     proc "system" (adapter: rawptr, min_fl: u32, iid: ^Iid, out: ^rawptr) -> HRESULT,
	serialize_rs:      proc "system" (desc: rawptr, ver: u32, blob, err: ^rawptr) -> HRESULT,
	serialize_vrs:     proc "system" (desc: rawptr, blob, err: ^rawptr) -> HRESULT,
	create_deser:      proc "system" (src: rawptr, sz: uint, iid: ^Iid, out: ^rawptr) -> HRESULT,
	create_dxgi_fac2:  proc "system" (flags: u32, iid: ^Iid, out: ^rawptr) -> HRESULT,
}

@(private)
g_dll_mu: sync.Mutex
@(private)
g_dlls: D3D12_Dll_Procs

ensure_d3d12_dlls :: proc() -> ^D3D12_Dll_Procs {
	sync.mutex_lock(&g_dll_mu)
	defer sync.mutex_unlock(&g_dll_mu)
	if g_dlls.loaded {
		return &g_dlls
	}
	g_dlls.loaded = true
	d3d_w := win32.utf8_to_wstring("d3d12.dll", context.temp_allocator)
	dxgi_w := win32.utf8_to_wstring("dxgi.dll", context.temp_allocator)
	g_dlls.d3d12_mod = LoadLibraryExW(d3d_w, nil, LOAD_LIBRARY_SEARCH_SYSTEM32)
	g_dlls.dxgi_mod = LoadLibraryExW(dxgi_w, nil, LOAD_LIBRARY_SEARCH_SYSTEM32)
	if g_dlls.d3d12_mod != nil {
		g_dlls.create_device = cast(type_of(g_dlls.create_device))win32.GetProcAddress(g_dlls.d3d12_mod, "D3D12CreateDevice")
		g_dlls.serialize_rs = cast(type_of(g_dlls.serialize_rs))win32.GetProcAddress(g_dlls.d3d12_mod, "D3D12SerializeRootSignature")
		g_dlls.serialize_vrs = cast(type_of(g_dlls.serialize_vrs))win32.GetProcAddress(g_dlls.d3d12_mod, "D3D12SerializeVersionedRootSignature")
		g_dlls.create_deser = cast(type_of(g_dlls.create_deser))win32.GetProcAddress(g_dlls.d3d12_mod, "D3D12CreateRootSignatureDeserializer")
	}
	if g_dlls.dxgi_mod != nil {
		g_dlls.create_dxgi_fac2 = cast(type_of(g_dlls.create_dxgi_fac2))win32.GetProcAddress(g_dlls.dxgi_mod, "CreateDXGIFactory2")
	}
	return &g_dlls
}

Host_Capabilities :: struct {
	available:              bool,
	adapter_name:           string,
	vendor_id:              u32,
	device_id:              u32,
	dedicated_video_memory: u64,
	shared_system_memory:   u64,
	highest_shader_model:   string,
	mesh_shaders:           bool,
	mesh_shader_tier:       u32,
	depth_bounds:           bool,
	typed_uav_additional:   bool,
	uma:                    bool,
	cache_coherent_uma:     bool,
	tile_based_renderer:    bool,
	heap_atomics64:         bool,
	wave_ops:               bool,
	wave_lane_count_min:    u32,
	wave_lane_count_max:    u32,
	resource_binding_tier:  u32,
	resource_heap_tier:     u32,
	raytracing_tier:        u32,
	vrs_tier:               u32,
	aniso_point_mip:        bool,
	allow_tearing:          bool,
	display_mode_count:     int,
	max_refresh_hz:         u32,
}

destroy_host_capabilities :: proc(hc: ^Host_Capabilities) {
	delete(hc.adapter_name)
	delete(hc.highest_shader_model)
	hc^ = {}
}

DXGI_ADAPTER_DESC1 :: struct {
	Description:           [128]u16,
	VendorId:              u32,
	DeviceId:              u32,
	SubSysId:              u32,
	Revision:              u32,
	DedicatedVideoMemory:  uint,
	DedicatedSystemMemory: uint,
	SharedSystemMemory:    uint,
	AdapterLuid:           i64,
	Flags:                 u32,
}

DEVMODEW_PARTIAL :: struct {
	dmDeviceName:       [32]u16,
	dmSpecVersion:      u16,
	dmDriverVersion:    u16,
	dmSize:             u16,
	dmDriverExtra:      u16,
	dmFields:           u32,
	_pos_or_orient:     [16]u8,
	dmColor:            i16,
	dmDuplex:           i16,
	dmYResolution:      i16,
	dmTTOption:         i16,
	dmCollate:          i16,
	dmFormName:         [32]u16,
	dmLogPixels:        u16,
	dmBitsPerPel:       u32,
	dmPelsWidth:        u32,
	dmPelsHeight:       u32,
	dmDisplayFlags:     u32,
	dmDisplayFrequency: u32,
	_tail:              [64]u8,
}

shader_model_label :: proc(raw: u32) -> string {
	switch raw {
	case 0x60: return strings.clone("SM 6.0")
	case 0x61: return strings.clone("SM 6.1")
	case 0x62: return strings.clone("SM 6.2")
	case 0x63: return strings.clone("SM 6.3")
	case 0x64: return strings.clone("SM 6.4")
	case 0x65: return strings.clone("SM 6.5")
	case 0x66: return strings.clone("SM 6.6")
	case 0x67: return strings.clone("SM 6.7")
	case 0x68: return strings.clone("SM 6.8")
	case:      return strings.clone("< SM 6.0")
	}
}

probe_capabilities :: proc(allow_warp := true) -> Host_Capabilities {
	caps: Host_Capabilities
	dlls := ensure_d3d12_dlls()

	// Display mode enumeration works even headless/without D3D12
	mode_idx := u32(0)
	for mode_idx < 4096 {
		dev: DEVMODEW_PARTIAL
		dev.dmSize = size_of(DEVMODEW_PARTIAL) - 64 // standard DEVMODEW size (~220 bytes on x64)
		if !EnumDisplaySettingsW(nil, mode_idx, &dev) {
			break
		}
		caps.display_mode_count += 1
		if dev.dmDisplayFrequency > caps.max_refresh_hz && dev.dmDisplayFrequency < 1000 {
			caps.max_refresh_hz = dev.dmDisplayFrequency
		}
		mode_idx += 1
	}

	if dlls.create_device == nil {
		caps.adapter_name = strings.clone("D3D12 Unavailable")
		caps.highest_shader_model = strings.clone("N/A")
		return caps
	}

	D3D_FEATURE_LEVEL_12_0 :: u32(0xC000)
	dev_iid := guid(0x189819f1, 0x1db6, 0x4b57, {0xbe, 0x54, 0x18, 0x21, 0x33, 0x9b, 0x85, 0xf7})
	device: rawptr
	hr := dlls.create_device(nil, D3D_FEATURE_LEVEL_12_0, &dev_iid, &device)
	if (hr < 0 || device == nil) && allow_warp && dlls.create_dxgi_fac2 != nil {
		fac: rawptr
		f4_iid := IID_IDXGIFactory4_G
		if dlls.create_dxgi_fac2(0, &f4_iid, &fac) >= 0 && fac != nil {
			defer com_release(fac)
			Fac4_Vtbl :: struct {
				_pad:            [27]rawptr,
				EnumWarpAdapter: proc "system" (rawptr, ^Iid, ^rawptr) -> HRESULT,
			}
			fvt := (cast(^^Fac4_Vtbl)fac)^
			warp_adp: rawptr
			adp_iid := IID_IDXGIAdapter1
			if fvt.EnumWarpAdapter(fac, &adp_iid, &warp_adp) >= 0 && warp_adp != nil {
				defer com_release(warp_adp)
				hr = dlls.create_device(warp_adp, D3D_FEATURE_LEVEL_12_0, &dev_iid, &device)
			}
		}
	}
	if hr < 0 || device == nil {
		caps.adapter_name = strings.clone("No D3D12 Hardware/WARP Adapter")
		caps.highest_shader_model = strings.clone("N/A")
		return caps
	}
	defer com_release(device)
	caps.available = true

	// ID3D12Device vtable offsets (IUnknown=0..2, ID3D12Object=3..6, ID3D12Device=7..)
	// Slot 13: CheckFeatureSupport(this, Feature, pFeatureSupportData, FeatureSupportDataSize)
	// Slot 37: GetAdapterLuid(this, pOutLuid) -> Note: MSVC/mingw struct return vs out param!
	// Query adapter info via IDXGIAdapter1 from factory.EnumAdapters1(0) safely, matching LUID if needed.
	Dev_Vtbl :: struct {
		_unk_obj_pad:        [13]rawptr,
		CheckFeatureSupport: proc "system" (rawptr, u32, rawptr, u32) -> HRESULT,
	}
	dvt := (cast(^^Dev_Vtbl)device)^

	// Query Shader Model (D3D12_FEATURE_SHADER_MODEL = 7)
	sm := u32(0x68)
	if dvt.CheckFeatureSupport(device, 7, &sm, size_of(u32)) >= 0 {
		caps.highest_shader_model = shader_model_label(sm)
	} else {
		sm = 0x66
		if dvt.CheckFeatureSupport(device, 7, &sm, size_of(u32)) >= 0 {
			caps.highest_shader_model = shader_model_label(sm)
		} else {
			caps.highest_shader_model = strings.clone("< SM 6.6")
		}
	}

	// D3D12_FEATURE_D3D12_OPTIONS (0)
	opt0: [16]u32
	if dvt.CheckFeatureSupport(device, 0, &opt0[0], size_of(opt0)) >= 0 {
		caps.typed_uav_additional = opt0[5] != 0
		caps.resource_binding_tier = opt0[3]
		caps.resource_heap_tier = opt0[7]
	}
	// D3D12_FEATURE_D3D12_OPTIONS1 (8)
	opt1: [6]u32
	if dvt.CheckFeatureSupport(device, 8, &opt1[0], size_of(opt1)) >= 0 {
		caps.wave_ops = opt1[0] != 0
		caps.wave_lane_count_min = opt1[1]
		caps.wave_lane_count_max = opt1[2]
	}
	// D3D12_FEATURE_ARCHITECTURE1 (16): NodeIndex, TileBasedRenderer, UMA, CacheCoherentUMA, IsolatedMMU
	arch1: [5]u32
	if dvt.CheckFeatureSupport(device, 16, &arch1[0], size_of(arch1)) >= 0 {
		caps.tile_based_renderer = arch1[1] != 0
		caps.uma = arch1[2] != 0
		caps.cache_coherent_uma = arch1[3] != 0
	}
	// D3D12_FEATURE_D3D12_OPTIONS2 (18): DepthBoundsTestSupported, ProgrammableSamplePositionsTier
	opt2: [2]u32
	if dvt.CheckFeatureSupport(device, 18, &opt2[0], size_of(opt2)) >= 0 {
		caps.depth_bounds = opt2[0] != 0
	}
	// D3D12_FEATURE_D3D12_OPTIONS5 (27) -> raytracing tier
	opt5: [4]u32
	if dvt.CheckFeatureSupport(device, 27, &opt5[0], size_of(opt5)) >= 0 {
		caps.raytracing_tier = opt5[2]
	}
	// D3D12_FEATURE_D3D12_OPTIONS6 (30) -> VRS tier
	opt6: [6]u32
	if dvt.CheckFeatureSupport(device, 30, &opt6[0], size_of(opt6)) >= 0 {
		caps.vrs_tier = opt6[2]
	}
	// D3D12_FEATURE_D3D12_OPTIONS7 (32) -> mesh shader tier
	opt7: [4]u32
	if dvt.CheckFeatureSupport(device, 32, &opt7[0], size_of(opt7)) >= 0 {
		caps.mesh_shader_tier = opt7[0]
		caps.mesh_shaders = caps.mesh_shader_tier >= 10
	}
	// D3D12_FEATURE_D3D12_OPTIONS11 (40) -> AtomicInt64OnDescriptorHeapResourceSupported
	opt11: u32
	if dvt.CheckFeatureSupport(device, 40, &opt11, size_of(u32)) >= 0 {
		caps.heap_atomics64 = opt11 != 0
	}
	// D3D12_FEATURE_D3D12_OPTIONS19 (48) -> AnisotropicFilterWithPointMipSupported (first BOOL)
	opt19: [4]u32
	if dvt.CheckFeatureSupport(device, 48, &opt19[0], size_of(opt19)) >= 0 {
		caps.aniso_point_mip = opt19[0] != 0
	}

	// DXGI adapter name & tearing check
	if dlls.create_dxgi_fac2 != nil {
		fac: rawptr
		f4_iid := IID_IDXGIFactory4_G
		if dlls.create_dxgi_fac2(0, &f4_iid, &fac) >= 0 && fac != nil {
			defer com_release(fac)
			Fac_Vtbl :: struct {
				_pad:          [12]rawptr,
				EnumAdapters1: proc "system" (rawptr, u32, ^rawptr) -> HRESULT,
			}
			fvt := (cast(^^Fac_Vtbl)fac)^
			adp: rawptr
			if fvt.EnumAdapters1(fac, 0, &adp) >= 0 && adp != nil {
				defer com_release(adp)
				Adp1_Vtbl :: struct {
					_pad:     [10]rawptr,
					GetDesc1: proc "system" (rawptr, ^DXGI_ADAPTER_DESC1) -> HRESULT,
				}
				avt := (cast(^^Adp1_Vtbl)adp)^
				adp_desc: DXGI_ADAPTER_DESC1
				if avt.GetDesc1(adp, &adp_desc) >= 0 {
					end := 0
					for end < 128 && adp_desc.Description[end] != 0 {
						end += 1
					}
					s, _ := win32.utf16_to_utf8(adp_desc.Description[:end], context.temp_allocator)
					caps.adapter_name = strings.clone(s)
					caps.vendor_id = adp_desc.VendorId
					caps.device_id = adp_desc.DeviceId
					caps.dedicated_video_memory = u64(adp_desc.DedicatedVideoMemory)
					caps.shared_system_memory = u64(adp_desc.SharedSystemMemory)
				}
			}
			// IDXGIFactory5 :: CheckFeatureSupport (slot 28)
			f5_iid := IID_IDXGIFactory5_G
			fac5 := com_query(fac, &f5_iid)
			if fac5 != nil {
				defer com_release(fac5)
				Fac5_Vtbl :: struct {
					_pad:                [28]rawptr,
					CheckFeatureSupport: proc "system" (rawptr, u32, rawptr, u32) -> HRESULT,
				}
				f5vt := (cast(^^Fac5_Vtbl)fac5)^
				tear := u32(0)
				if f5vt.CheckFeatureSupport(fac5, 0, &tear, size_of(u32)) >= 0 {
					caps.allow_tearing = tear != 0
				}
			}
		}
	}

	if caps.adapter_name == "" {
		caps.adapter_name = strings.clone("D3D12 Device")
	}
	return caps
}
