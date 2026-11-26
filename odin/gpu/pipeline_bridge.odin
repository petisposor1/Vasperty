package vasperty_gpu

import "core:path/filepath"
import "core:strings"
import "core:sync"
import vasperty_hle "vasperty:hle"
import vasperty_pipeline "vasperty:pipeline"
import vasperty_shader "vasperty:shader"

// =========================================================================
// Root Signature & Deserializer Hooks (strip console flags >= bit 24)
// =========================================================================

CONSOLE_ROOT_FLAGS :: u32(0xFF00_0000)

Root_Sig_Desc :: struct {
	parameter_count: u32,
	parameters:      rawptr,
	sampler_count:   u32,
	samplers:        rawptr,
	flags:           u32,
}

Versioned_Root_Sig_Desc :: struct {
	version: u32,
	desc:    Root_Sig_Desc,
}

root_desc_without_console_flags :: proc(d: Root_Sig_Desc) -> Root_Sig_Desc {
	out := d
	out.flags = d.flags & ~CONSOLE_ROOT_FLAGS
	return out
}

host_serialize_root_signature :: proc "system" (desc: rawptr, version: u32, blob, err_blob: ^rawptr) -> HRESULT {
	context = gpu_context()
	if desc == nil {
		return E_INVALIDARG
	}
	dlls := ensure_d3d12_dlls()
	if dlls.serialize_rs == nil {
		return E_NOTIMPL
	}
	clean := root_desc_without_console_flags((cast(^Root_Sig_Desc)desc)^)
	return dlls.serialize_rs(&clean, version, blob, err_blob)
}

host_serialize_versioned_root_signature :: proc "system" (desc: rawptr, blob, err_blob: ^rawptr) -> HRESULT {
	context = gpu_context()
	if desc == nil {
		return E_INVALIDARG
	}
	dlls := ensure_d3d12_dlls()
	if dlls.serialize_vrs == nil {
		return E_NOTIMPL
	}
	in_d := (cast(^Versioned_Root_Sig_Desc)desc)^
	clean := Versioned_Root_Sig_Desc{
		version = in_d.version,
		desc    = root_desc_without_console_flags(in_d.desc),
	}
	return dlls.serialize_vrs(&clean, blob, err_blob)
}

host_create_root_deserializer :: proc "system" (src: rawptr, src_len: uint, iid: ^vasperty_hle.Guid, out: ^rawptr) -> HRESULT {
	context = gpu_context()
	if src == nil || src_len == 0 || iid == nil || out == nil {
		return E_INVALIDARG
	}
	dlls := ensure_d3d12_dlls()
	if dlls.create_deser == nil {
		return E_NOTIMPL
	}
	return dlls.create_deser(src, src_len, cast(^Iid)iid, out)
}

// =========================================================================
// Command List & Queue Barrier Tracker
// =========================================================================

Command_Barrier :: struct {
	resource: uintptr,
	before:   u32,
	after:    u32,
}

Command_List :: struct {
	kind:     u32,
	barriers: [dynamic]Command_Barrier,
	states:   map[uintptr]u32,
	closed:   bool,
}

command_list_create :: proc(kind: u32) -> ^Command_List {
	cl := new(Command_List)
	cl.kind = kind
	cl.barriers = make([dynamic]Command_Barrier)
	cl.states = make(map[uintptr]u32)
	return cl
}

command_list_destroy :: proc(cl: ^Command_List) {
	if cl == nil {
		return
	}
	delete(cl.barriers)
	delete(cl.states)
	free(cl)
}

command_list_transition :: proc(cl: ^Command_List, res: uintptr, after_console: u32, is_texture := false) {
	if cl == nil || cl.closed {
		return
	}
	after := texture_state(after_console) if is_texture else pc_state(after_console)
	before, ok := cl.states[res]
	if !ok {
		before = 0 // COMMON
	}
	if before == after {
		return
	}
	append(&cl.barriers, Command_Barrier{resource = res, before = before, after = after})
	cl.states[res] = after
}

command_list_reset :: proc(cl: ^Command_List) {
	if cl == nil {
		return
	}
	clear(&cl.barriers)
	clear(&cl.states)
	cl.closed = false
}

// =========================================================================
// Shader Translation Cache (vasperty:pipeline + vasperty:shader)
// =========================================================================

SHADER_CACHE_FORMAT_VERSION :: u32(1)

@(private)
g_sc_mu: sync.Mutex
@(private)
g_sc_dir: string
@(private)
g_sc_has_cache: bool
@(private)
g_sc_hits: u64
@(private)
g_sc_misses: u64
@(private)
g_sc_mem: map[[32]u8]Cached_Shader_Entry

Cached_Shader_Entry :: struct {
	ok:         bool,
	host:       vasperty_shader.Host_Shader,
	err_reason: string,
}

use_shader_cache :: proc(dir: string) {
	sync.mutex_lock(&g_sc_mu)
	defer sync.mutex_unlock(&g_sc_mu)
	if g_sc_dir != "" {
		delete(g_sc_dir)
	}
	sub, _ := filepath.join({dir, "vasperty-dxil-v1"}, context.temp_allocator)
	g_sc_dir = strings.clone(sub)
	g_sc_has_cache = true
	if g_sc_mem == nil {
		g_sc_mem = make(map[[32]u8]Cached_Shader_Entry)
	}
}

fini_shader_cache :: proc() {
	sync.mutex_lock(&g_sc_mu)
	defer sync.mutex_unlock(&g_sc_mu)
	for _, &e in g_sc_mem {
		if e.ok {
			vasperty_shader.destroy_host_shader(&e.host)
		} else if e.err_reason != "" {
			delete(e.err_reason)
		}
	}
	delete(g_sc_mem)
	g_sc_mem = nil
	if g_sc_dir != "" {
		delete(g_sc_dir)
		g_sc_dir = ""
	}
	g_sc_has_cache = false
}

shader_cache_counts :: proc() -> (hits, misses: u64) {
	sync.mutex_lock(&g_sc_mu)
	defer sync.mutex_unlock(&g_sc_mu)
	return g_sc_hits, g_sc_misses
}

host_shader_from_container :: proc(container: []u8, view_marks := true) -> (res: vasperty_shader.Host_Shader, cached: bool, err: vasperty_shader.Shader_Error) {
	parts := [1][]u8{container}
	key := vasperty_pipeline.cache_key_from_parts("vasperty-shader-sm66", SHADER_CACHE_FORMAT_VERSION, parts[:])

	sync.mutex_lock(&g_sc_mu)
	if g_sc_mem == nil {
		g_sc_mem = make(map[[32]u8]Cached_Shader_Entry)
	}
	if ent, found := g_sc_mem[key.digest]; found {
		g_sc_hits += 1
		sync.mutex_unlock(&g_sc_mu)
		if !ent.ok {
			return {}, true, .Unsupported
		}
		// Clone Host_Shader slices for independent caller ownership
		cp := vasperty_shader.Host_Shader{
			stage           = ent.host.stage,
			dxil            = make([dynamic]u8, len(ent.host.dxil)),
			user_data       = make([dynamic]vasperty_shader.User_Data, len(ent.host.user_data)),
			samplers        = make([dynamic][4]u32, len(ent.host.samplers)),
			static_samplers = make([dynamic]vasperty_shader.Static_Sampler, len(ent.host.static_samplers)),
			root_cbvs       = make([dynamic]u8, len(ent.host.root_cbvs)),
			root_srvs       = make([dynamic]u8, len(ent.host.root_srvs)),
			root_uavs       = make([dynamic]u8, len(ent.host.root_uavs)),
			memory          = ent.host.memory,
			memory_writes   = ent.host.memory_writes,
			view_addresses  = ent.host.view_addresses,
			heap             = ent.host.heap,
			heap_writes      = ent.host.heap_writes,
			view_marks       = ent.host.view_marks,
			target_wave_size = ent.host.target_wave_size,
		}
		copy(cp.dxil[:], ent.host.dxil[:])
		copy(cp.user_data[:], ent.host.user_data[:])
		copy(cp.samplers[:], ent.host.samplers[:])
		copy(cp.static_samplers[:], ent.host.static_samplers[:])
		copy(cp.root_cbvs[:], ent.host.root_cbvs[:])
		copy(cp.root_srvs[:], ent.host.root_srvs[:])
		copy(cp.root_uavs[:], ent.host.root_uavs[:])
		return cp, true, .None
	}
	g_sc_misses += 1
	sync.mutex_unlock(&g_sc_mu)

	opts := vasperty_shader.Shader_Options{view_marks = view_marks}
	hs, terr := vasperty_shader.translate_with(container, opts)

	sync.mutex_lock(&g_sc_mu)
	if _, already := g_sc_mem[key.digest]; !already {
		if terr == .None {
			store := vasperty_shader.Host_Shader{
				stage           = hs.stage,
				dxil            = make([dynamic]u8, len(hs.dxil)),
				user_data       = make([dynamic]vasperty_shader.User_Data, len(hs.user_data)),
				samplers        = make([dynamic][4]u32, len(hs.samplers)),
				static_samplers = make([dynamic]vasperty_shader.Static_Sampler, len(hs.static_samplers)),
				root_cbvs       = make([dynamic]u8, len(hs.root_cbvs)),
				root_srvs       = make([dynamic]u8, len(hs.root_srvs)),
				root_uavs       = make([dynamic]u8, len(hs.root_uavs)),
				memory          = hs.memory,
				memory_writes   = hs.memory_writes,
				view_addresses  = hs.view_addresses,
				heap             = hs.heap,
				heap_writes      = hs.heap_writes,
				view_marks       = hs.view_marks,
				target_wave_size = hs.target_wave_size,
			}
			copy(store.dxil[:], hs.dxil[:])
			copy(store.user_data[:], hs.user_data[:])
			copy(store.samplers[:], hs.samplers[:])
			copy(store.static_samplers[:], hs.static_samplers[:])
			copy(store.root_cbvs[:], hs.root_cbvs[:])
			copy(store.root_srvs[:], hs.root_srvs[:])
			copy(store.root_uavs[:], hs.root_uavs[:])
			g_sc_mem[key.digest] = Cached_Shader_Entry{ok = true, host = store}
		} else {
			g_sc_mem[key.digest] = Cached_Shader_Entry{ok = false}
		}
	}
	sync.mutex_unlock(&g_sc_mu)

	return hs, false, terr
}

// =========================================================================
// HLE GPU Hook Registration Bridge
// =========================================================================

gpu_init :: proc() {
	init_gpu_objects()
	init_watch()
}

gpu_fini :: proc() {
	unregister_gpu_hooks()
	fini_shader_cache()
	fini_watch()
	fini_gpu_objects()
}

register_gpu_hooks :: proc() {
	gpu_init()
	hooks := vasperty_hle.Gpu_Hooks{
		kernel_will_write                  = watch_kernel_will_write,
		kernel_end_write                   = watch_kernel_end_write,
		title_memory_remapped              = watch_memory_remapped,
		title_memory_aliased               = watch_memory_aliased,
		configure_virtual_memory           = console_configure_virtual_memory,
		create_device                      = console_create_device,
		serialize_root_signature           = host_serialize_root_signature,
		serialize_versioned_root_signature = host_serialize_versioned_root_signature,
		create_root_deserializer           = host_create_root_deserializer,
		use_shader_cache                   = use_shader_cache,
		iid_d3d12_device                   = IID_ID3D12Device,
	}
	vasperty_hle.set_gpu_hooks(hooks)
}

unregister_gpu_hooks :: proc() {
	vasperty_hle.set_gpu_hooks(vasperty_hle.Gpu_Hooks{})
}
