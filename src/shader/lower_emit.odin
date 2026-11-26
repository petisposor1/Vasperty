package vasperty_shader

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import win32 "core:sys/windows"

USER_DATA_SPACE :: u32(0)
SAMPLER_SPACE :: u32(0)
ROOT_CBV_SPACE :: u32(1)
VIEW_STRIDES :: u8(255)
VIEW_STRIDE_BITS :: u32((1 << 30) - 1)
VIEW_INTEGER :: u32(1) << 31
VIEW_SIGNED :: u32(1) << 30
MEMORY_SPACE :: u32(2)
HEAP_VIEWS :: u32(1) << 21
HEAP_SAMPLERS :: u32(2048)
NULL_BUFFER_VIEW :: u32(HEAP_VIEWS - 2)
VIEW_MARKS :: u32(2)
VIEW_WRITES :: u32(1)
VIEW_MARK_NONE :: u32(0xFFFF_FFFF)
VIEW_WRITE_BITS :: u32(1) << 22
VIEW_READS :: VIEW_WRITE_BITS

ROOT_SRV_VIEW :: u32(2)
ROOT_UAV_VIEW :: u32(3)
ROOT_VIEW_OFFSET :: u32(4)

DEFAULT_LOOP_LIMIT :: u32(1) << 20

DXIL_FLAG_RAW_BUFFERS :: u64(1) << 4
DXIL_FLAG_STENCIL_REF :: u64(1) << 11
DXIL_FLAG_TYPED_UAV_LOADS :: u64(1) << 13
DXIL_FLAG_UAVS_EVERY_STAGE :: u64(1) << 16
DXIL_FLAG_ROVS :: u64(1) << 18
DXIL_FLAG_WAVE_OPS :: u64(1) << 19
DXIL_FLAG_INT64 :: u64(1) << 20
DXIL_FLAG_ATOMIC64_TYPED :: u64(1) << 27
DXIL_FLAG_RESOURCE_HEAP :: u64(1) << 30
DXIL_FLAG_SAMPLER_HEAP :: u64(1) << 31
DXIL_FLAG_ATOMIC64_HEAP :: u64(1) << 32

// =========================================================================
// Static Sampler
// =========================================================================

Static_Sampler :: struct {
	filter:         u32,
	address:        [3]u32,
	mip_lod_bias:   f32,
	max_anisotropy: u32,
	comparison:     u32,
	border:         u32,
	min_lod:        f32,
	max_lod:        f32,
}

static_sampler_from_words :: proc(w: [4]u32) -> Static_Sampler {
	bits :: proc(word, at, n: u32) -> u32 {
		return (word >> at) & ((u32(1) << n) - 1)
	}
	ADDR_MAP := [8]u32{1, 2, 3, 5, 3, 5, 4, 5}
	mag := bits(w[2], 20, 2)
	min_f := bits(w[2], 22, 2)
	mip := bits(w[2], 26, 2)
	red_bits := bits(w[0], 29, 2)
	reduction: u32 = 0
	if red_bits == 1 {
		reduction = 2
	} else if red_bits == 2 {
		reduction = 3
	}
	mip_lin := u32(mip == 2 ? 1 : 0)
	filter: u32
	if mag >= 2 || min_f >= 2 {
		filter = 0x54 | mip_lin | (reduction << 7)
	} else {
		filter = ((min_f & 1) << 4) | ((mag & 1) << 2) | mip_lin | (reduction << 7)
	}
	min_lod, max_lod: f32
	if mip == 0 {
		min_lod = 0
		max_lod = 0
	} else {
		min_lod = f32(bits(w[1], 0, 12)) / 256.0
		max_lod = f32(bits(w[1], 12, 12)) / 256.0
	}
	bias_raw := i32(bits(w[2], 0, 14) << 18) >> 18
	aniso_log := bits(w[0], 9, 3)
	if aniso_log > 4 {
		aniso_log = 4
	}
	return Static_Sampler{
		filter         = filter,
		address        = {ADDR_MAP[bits(w[0], 0, 3)], ADDR_MAP[bits(w[0], 3, 3)], ADDR_MAP[bits(w[0], 6, 3)]},
		mip_lod_bias   = f32(bias_raw) / 256.0,
		max_anisotropy = u32(1) << aniso_log,
		comparison     = bits(w[0], 12, 3) + 1,
		border         = bits(w[3], 30, 2) % 3,
		min_lod        = min_lod,
		max_lod        = max_lod,
	}
}

static_sampler_filter_for_host :: proc(s: Static_Sampler, aniso_point_mip_supported: bool) -> u32 {
	if !aniso_point_mip_supported && (s.filter & ~u32(0x180)) == 0x54 {
		return s.filter | 1
	}
	return s.filter
}

// =========================================================================
// IDxcValidator (dxil.dll)
// =========================================================================

CLSID_DxcValidator := win32.GUID{0x8CA3E215, 0xF728, 0x4CF3, {0x8C, 0xDD, 0x88, 0xAA, 0xA9, 0x17, 0x5B, 0xED}}
IID_IDxcValidator := win32.GUID{0xA6E82BD2, 0x1FD7, 0x4826, {0x98, 0x11, 0x28, 0x57, 0xE7, 0x97, 0xF4, 0x9A}}

Dxc_Create_Instance_Proc :: #type proc "system" (
	rclsid: ^win32.GUID,
	riid: ^win32.GUID,
	ppv: ^rawptr,
) -> win32.HRESULT

Dxil_Blob :: struct {
	lpVtbl: rawptr,
	data:   []u8,
	refs:   i32,
}

blob_qi :: proc "system" (this: rawptr, riid: ^win32.GUID, ppv: ^rawptr) -> win32.HRESULT {
	_ = riid
	if ppv == nil {
		return transmute(win32.HRESULT)u32(0x8000_4003) // E_POINTER
	}
	b := cast(^Dxil_Blob)this
	b.refs += 1
	ppv^ = this
	return win32.S_OK
}

blob_addref :: proc "system" (this: rawptr) -> win32.ULONG {
	b := cast(^Dxil_Blob)this
	b.refs += 1
	return win32.ULONG(b.refs)
}

blob_release :: proc "system" (this: rawptr) -> win32.ULONG {
	b := cast(^Dxil_Blob)this
	b.refs -= 1
	return win32.ULONG(b.refs)
}

blob_get_ptr :: proc "system" (this: rawptr) -> rawptr {
	b := cast(^Dxil_Blob)this
	return raw_data(b.data)
}

blob_get_size :: proc "system" (this: rawptr) -> win32.SIZE_T {
	b := cast(^Dxil_Blob)this
	return win32.SIZE_T(len(b.data))
}

G_BLOB_VTBL := [5]rawptr{
	rawptr(blob_qi),
	rawptr(blob_addref),
	rawptr(blob_release),
	rawptr(blob_get_ptr),
	rawptr(blob_get_size),
}

@(private)
g_dxil_mu: sync.Mutex
@(private)
g_dxil_probed: bool
@(private)
g_dxil_create: Dxc_Create_Instance_Proc

@(private)
resolve_dxil_create :: proc() -> Dxc_Create_Instance_Proc {
	sync.mutex_lock(&g_dxil_mu)
	defer sync.mutex_unlock(&g_dxil_mu)
	if g_dxil_probed {
		return g_dxil_create
	}
	g_dxil_probed = true

	candidates := make([dynamic]string, 0, 4, context.temp_allocator)
	if env_p, ok := os.lookup_env("VASPERTY_DXIL_DLL", context.temp_allocator); ok && len(env_p) > 0 {
		append(&candidates, env_p)
	}
	append(&candidates, "dxil.dll")
	append(&candidates, "C:\\Windows\\System32\\Microsoft-Edge-WebView\\dxil.dll")

	for path in candidates {
		w := win32.utf8_to_wstring(path, context.temp_allocator)
		mod := win32.LoadLibraryW(w)
		if mod != nil {
			if sym := win32.GetProcAddress(mod, "DxcCreateInstance"); sym != nil {
				g_dxil_create = cast(Dxc_Create_Instance_Proc)sym
				return g_dxil_create
			}
			win32.FreeLibrary(mod)
		}
	}
	return nil
}

validate_dxil :: proc(container: []u8) -> (valid: bool, message: string, err: Shader_Error) {
	create_fn := resolve_dxil_create()
	if create_fn == nil {
		return false, "", .Unsupported
	}
	validator: rawptr
	hr := create_fn(&CLSID_DxcValidator, &IID_IDxcValidator, &validator)
	if hr < 0 || validator == nil {
		return false, "", .Unsupported
	}
	Vtbl_Validator :: struct {
		QueryInterface: rawptr,
		AddRef:         rawptr,
		Release:        proc "system" (rawptr) -> win32.ULONG,
		Validate:       proc "system" (rawptr, rawptr, u32, ^rawptr) -> win32.HRESULT,
	}
	vtbl := (cast(^^Vtbl_Validator)validator)^
	defer vtbl.Release(validator)

	blob := Dxil_Blob{
		lpVtbl = &G_BLOB_VTBL[0],
		data   = container,
		refs   = 1,
	}
	result_ptr: rawptr
	vhr := vtbl.Validate(validator, &blob, 0, &result_ptr)
	if result_ptr != nil {
		Vtbl_Result :: struct {
			QueryInterface: rawptr,
			AddRef:         rawptr,
			Release:        proc "system" (rawptr) -> win32.ULONG,
			GetStatus:      proc "system" (rawptr, ^win32.HRESULT) -> win32.HRESULT,
			GetResult:      rawptr,
			GetErrorBuffer: proc "system" (rawptr, ^rawptr) -> win32.HRESULT,
		}
		rv := (cast(^^Vtbl_Result)result_ptr)^
		defer rv.Release(result_ptr)
		status: win32.HRESULT
		_ = rv.GetStatus(result_ptr, &status)
		if status >= 0 && vhr >= 0 {
			return true, "", .None
		}
		err_blob: rawptr
		if rv.GetErrorBuffer(result_ptr, &err_blob) >= 0 && err_blob != nil {
			Vtbl_Blob :: struct {
				QueryInterface:    rawptr,
				AddRef:            rawptr,
				Release:           proc "system" (rawptr) -> win32.ULONG,
				GetBufferPointer:  proc "system" (rawptr) -> rawptr,
				GetBufferSize:     proc "system" (rawptr) -> win32.SIZE_T,
			}
			ebv := (cast(^^Vtbl_Blob)err_blob)^
			defer ebv.Release(err_blob)
			ptr := cast([^]u8)ebv.GetBufferPointer(err_blob)
			sz := int(ebv.GetBufferSize(err_blob))
			if ptr != nil && sz > 0 {
				return false, strings.clone(string(ptr[:sz])), .None
			}
		}
		return false, fmt.aprintf("validation failed: 0x%08x", u32(status)), .None
	}
	return vhr >= 0, "", .None
}

// =========================================================================
// DXIL Shader Module Builder
// =========================================================================

Dxil_Types :: struct {
	void_ty:  Ty,
	i1:       Ty,
	i8:       Ty,
	i32:      Ty,
	f32:      Ty,
	handle:   Ty,
	props:    Ty,
	bind:     Ty,
	cbuf_ret: Ty,
	res_ret:  Ty,
}

Dxil_Shader :: struct {
	m:              Bc_Module,
	t:              Dxil_Types,
	pixel:          bool,
	inputs:         [dynamic]Sig_Element,
	outputs:        [dynamic]Sig_Element,
	prims:          [dynamic]Sig_Element,
	has_threads:    bool,
	threads:        [3]u32,
	has_mesh:       bool,
	mesh:           Mesh_Desc,
	has_gs:         bool,
	gs_max:         u32,
	has_wave:       bool,
	wave_size:      u32,
	user_data:      u32,
	user_handle:    Maybe(V),
	root_cbvs:      [dynamic]struct {
		slot: u8,
		h:    V,
	},
	root_srvs:      [dynamic]struct {
		slot: u8,
		h:    V,
	},
	root_uavs:      [dynamic]struct {
		slot: u8,
		h:    V,
	},
	memory:         Maybe(V),
	memory_dirty:   Maybe(V),
	view_addresses: Maybe(V),
	view_marks:     Maybe(V),
	view_writes:    Maybe(V),
	samplers:       u32,
	cmp_samplers:   u64,
	flags:          u64,
	lds_dwords:     u32,
	lds:            Maybe(V),
	main_fn:        V,
	entry:          int,
	ud_prop_val:    V,
}

sig_list_destroy :: proc(els: ^[dynamic]Sig_Element) {
	for &e in els {
		delete(e.name)
	}
	delete(els^)
}

shader_create :: proc(pixel: bool) -> Dxil_Shader {
	s: Dxil_Shader
	s.pixel = pixel
	s.inputs = make([dynamic]Sig_Element)
	s.outputs = make([dynamic]Sig_Element)
	s.prims = make([dynamic]Sig_Element)
	s.root_cbvs = make([dynamic]struct {
		slot: u8,
		h:    V,
	})
	s.root_srvs = make([dynamic]struct {
		slot: u8,
		h:    V,
	})
	s.root_uavs = make([dynamic]struct {
		slot: u8,
		h:    V,
	})

	s.t.void_ty = bc_void(&s.m)
	s.t.i1 = bc_int_ty(&s.m, 1)
	s.t.i8 = bc_int_ty(&s.m, 8)
	s.t.i32 = bc_int_ty(&s.m, 32)
	s.t.f32 = bc_float(&s.m)
	i8p := bc_ptr(&s.m, s.t.i8)
	s.t.handle = bc_named_struct(&s.m, "dx.types.Handle", {i8p})
	s.t.props = bc_named_struct(&s.m, "dx.types.ResourceProperties", {s.t.i32, s.t.i32})
	s.t.bind = bc_named_struct(&s.m, "dx.types.ResBind", {s.t.i32, s.t.i32, s.t.i32, s.t.i8})
	s.t.cbuf_ret = bc_named_struct(&s.m, "dx.types.CBufRet.i32", {s.t.i32, s.t.i32, s.t.i32, s.t.i32})
	s.t.res_ret = bc_named_struct(&s.m, "dx.types.ResRet.i32", {s.t.i32, s.t.i32, s.t.i32, s.t.i32, s.t.i32})

	fty := bc_func_ty(&s.m, s.t.void_ty, {})
	s.main_fn = bc_function(&s.m, "main", fty, .None, true)
	s.entry = bc_new_block(&s.m)
	return s
}

shader_destroy :: proc(s: ^Dxil_Shader) {
	destroy_bc_module(&s.m)
	sig_list_destroy(&s.inputs)
	sig_list_destroy(&s.outputs)
	sig_list_destroy(&s.prims)
	delete(s.root_cbvs)
	delete(s.root_srvs)
	delete(s.root_uavs)
}

shader_op :: proc(s: ^Dxil_Shader, blk: int, name: string, attr: Attr_Kind, ret: Ty, opcode: u32, args: []V) -> V {
	params := make([]Ty, 1 + len(args), context.temp_allocator)
	params[0] = s.t.i32
	for a, i in args {
		params[1 + i] = bc_type_of(&s.m, a)
	}
	fty := bc_func_ty(&s.m, ret, params)
	_ = bc_ptr(&s.m, fty)
	fname := fmt.tprintf("dx.op.%s", name)
	fn := bc_function(&s.m, fname, fty, attr, false)
	all := make([]V, 1 + len(args), context.temp_allocator)
	all[0] = bc_i32(&s.m, opcode)
	for a, i in args {
		all[1 + i] = a
	}
	return bc_call(&s.m, blk, fn, all)
}

shader_annotate :: proc(s: ^Dxil_Shader, blk: int, h: V, kind_word, extra_word: u32) -> V {
	props := bc_aggregate(&s.m, s.t.props, {bc_i32(&s.m, kind_word), bc_i32(&s.m, extra_word)})
	return shader_op(s, blk, "annotateHandle", .Read_None, s.t.handle, 216, {h, props})
}

shader_user_data_handle :: proc(s: ^Dxil_Shader) -> V {
	if h, ok := s.user_handle.?; ok {
		return h
	}
	bind := bc_aggregate(&s.m, s.t.bind, {bc_i32(&s.m, 0), bc_i32(&s.m, 0), bc_i32(&s.m, USER_DATA_SPACE), bc_i8(&s.m, 2)})
	h := shader_op(s, s.entry, "createHandleFromBinding", .Read_None, s.t.handle, 217, {bind, bc_i32(&s.m, 0), bc_i1(&s.m, false)})
	s.ud_prop_val = bc_aggregate(&s.m, s.t.props, {bc_i32(&s.m, 13), bc_i32(&s.m, 0xFFFF_FFFF)})
	ah := shader_op(s, s.entry, "annotateHandle", .Read_None, s.t.handle, 216, {h, s.ud_prop_val})
	s.user_handle = ah
	return ah
}

shader_root_cbv_handle :: proc(s: ^Dxil_Shader, slot: u8) -> V {
	for r in s.root_cbvs {
		if r.slot == slot {
			return r.h
		}
	}
	rv := bc_i32(&s.m, u32(slot))
	bind := bc_aggregate(&s.m, s.t.bind, {rv, rv, bc_i32(&s.m, ROOT_CBV_SPACE), bc_i8(&s.m, 2)})
	h := shader_op(s, s.entry, "createHandleFromBinding", .Read_None, s.t.handle, 217, {bind, rv, bc_i1(&s.m, false)})
	ah := shader_annotate(s, s.entry, h, 13, 65536)
	append(&s.root_cbvs, struct {
		slot: u8,
		h:    V,
	}{slot = slot, h = ah})
	return ah
}

shader_root_srv_handle :: proc(s: ^Dxil_Shader, slot: u8) -> V {
	for r in s.root_srvs {
		if r.slot == slot {
			return r.h
		}
	}
	rv := bc_i32(&s.m, u32(slot))
	bind := bc_aggregate(&s.m, s.t.bind, {rv, rv, bc_i32(&s.m, ROOT_CBV_SPACE), bc_i8(&s.m, 0)})
	h := shader_op(s, s.entry, "createHandleFromBinding", .Read_None, s.t.handle, 217, {bind, rv, bc_i1(&s.m, false)})
	ah := shader_annotate(s, s.entry, h, 11, 0)
	s.flags |= DXIL_FLAG_RAW_BUFFERS
	append(&s.root_srvs, struct {
		slot: u8,
		h:    V,
	}{slot = slot, h = ah})
	return ah
}

shader_root_uav_handle :: proc(s: ^Dxil_Shader, slot: u8) -> V {
	for r in s.root_uavs {
		if r.slot == slot {
			return r.h
		}
	}
	rv := bc_i32(&s.m, u32(slot))
	bind := bc_aggregate(&s.m, s.t.bind, {rv, rv, bc_i32(&s.m, ROOT_CBV_SPACE), bc_i8(&s.m, 1)})
	h := shader_op(s, s.entry, "createHandleFromBinding", .Read_None, s.t.handle, 217, {bind, rv, bc_i1(&s.m, false)})
	ah := shader_annotate(s, s.entry, h, 11 | 0x1000, 0)
	s.flags |= DXIL_FLAG_RAW_BUFFERS
	append(&s.root_uavs, struct {
		slot: u8,
		h:    V,
	}{slot = slot, h = ah})
	return ah
}

bc_module_uses :: proc(m: ^Bc_Module) -> (heap, sampler_heap, wave, int64_used: bool) {
	i64_ty := bc_int_ty(m, 64)
	for &fn in m.funcs {
		if strings.contains(fn.name, ".wave") || strings.contains(fn.name, "waveRead") || strings.contains(fn.name, "waveGet") {
			wave = true
		}
	}
	for &inst in m.insts {
		if inst.ty == i64_ty {
			int64_used = true
		}
		if inst.kind == .Call {
			fn := m.funcs[inst.fn_id]
			if fn.name == "dx.op.createHandleFromHeap" && len(inst.args) >= 3 {
				sarg := inst.args[2]
				if sarg.kind == .Const && m.consts[sarg.id].ival != 0 {
					sampler_heap = true
				} else {
					heap = true
				}
			}
		}
	}
	return
}

shader_signature_md :: proc(s: ^Dxil_Shader, elements: []Sig_Element) -> Md_Op {
	if len(elements) == 0 {
		return Md_Op{}
	}
	list := make([dynamic]Md_Op, 0, len(elements), context.temp_allocator)
	for &e, id in elements {
		c32 :: proc(sh: ^Dxil_Shader, v: u32) -> Md_Op {
			return Md_Op{present = true, id = bc_md_val(&sh.m, bc_i32(&sh.m, v))}
		}
		c8 :: proc(sh: ^Dxil_Shader, v: u8) -> Md_Op {
			return Md_Op{present = true, id = bc_md_val(&sh.m, bc_i8(&sh.m, v))}
		}
		indices := Md_Op{present = true, id = bc_md_node(&s.m, {c32(s, e.index)})}
		usage_md := Md_Op{}
		if e.usage != 0 {
			usage_md = Md_Op{present = true, id = bc_md_node(&s.m, {c32(s, 3), c32(s, u32(e.usage))})}
		}
		row_v := e.row if e.has_row else u32(0xFFFF_FFFF)
		col_v := e.col if e.has_row else u8(0xFF)
		node := bc_md_node(&s.m, {
			c32(s, u32(id)),
			Md_Op{present = true, id = bc_md_str(&s.m, e.name)},
			c8(s, e.comp),
			c8(s, e.kind),
			indices,
			c8(s, e.interp),
			c32(s, 1),
			c8(s, e.cols),
			c32(s, row_v),
			c8(s, col_v),
			usage_md,
		})
		append(&list, Md_Op{present = true, id = node})
	}
	return Md_Op{present = true, id = bc_md_node(&s.m, list[:])}
}

shader_finish :: proc(s: ^Dxil_Shader) -> [dynamic]u8 {
	ud_size := (s.user_data * 4 + 15) & ~u32(15)
	if ud_size == 0 && s.user_data == 0 {
		ud_size = 16
	}
	if _, has_ud := s.user_handle.?; has_ud {
		new_props := bc_aggregate(&s.m, s.t.props, {bc_i32(&s.m, 13), bc_i32(&s.m, ud_size)})
		bc_replace_const(&s.m, s.ud_prop_val, new_props)
	}

	heap, smp_heap, wave, i64_u := bc_module_uses(&s.m)
	if heap { s.flags |= DXIL_FLAG_RESOURCE_HEAP } else { s.flags &= ~DXIL_FLAG_RESOURCE_HEAP }
	if smp_heap { s.flags |= DXIL_FLAG_SAMPLER_HEAP } else { s.flags &= ~DXIL_FLAG_SAMPLER_HEAP }
	if wave { s.flags |= DXIL_FLAG_WAVE_OPS } else { s.flags &= ~DXIL_FLAG_WAVE_OPS }
	if i64_u { s.flags |= DXIL_FLAG_INT64 } else { s.flags &= ~DXIL_FLAG_INT64 }

	is_compute := s.has_threads && !s.has_mesh && !s.has_gs
	declared_uavs := len(s.root_uavs) > 0 || s.memory_dirty != nil || s.view_writes != nil
	if declared_uavs && !s.pixel && !is_compute {
		s.flags |= DXIL_FLAG_UAVS_EVERY_STAGE
	}

	bindings := make([dynamic]Psv_Binding, context.temp_allocator)
	i32op :: proc(sh: ^Dxil_Shader, v: u32) -> Md_Op {
		return Md_Op{present = true, id = bc_md_val(&sh.m, bc_i32(&sh.m, v))}
	}

	resources_op := Md_Op{}
	if s.user_data > 0 || s.samplers > 0 || len(s.root_cbvs) > 0 || len(s.root_srvs) > 0 || len(s.root_uavs) > 0 {
		empty := Md_Op{present = true, id = bc_md_str(&s.m, "")}
		cbv_list := make([dynamic]Md_Op, context.temp_allocator)
		if s.user_data > 0 {
			arr_n := (s.user_data + 3) & ~u32(3)
			arr := bc_array(&s.m, arr_n, s.t.i32)
			ty := bc_named_struct(&s.m, "UserData", {arr})
			u := bc_undef(&s.m, bc_ptr(&s.m, ty))
			node := bc_md_node(&s.m, {
				i32op(s, 0),
				Md_Op{present = true, id = bc_md_val(&s.m, u)},
				empty,
				i32op(s, USER_DATA_SPACE),
				i32op(s, 0),
				i32op(s, 1),
				i32op(s, ud_size),
				Md_Op{},
			})
			append(&cbv_list, Md_Op{present = true, id = node})
			append(&bindings, Psv_Binding{kind = 2, space = USER_DATA_SPACE, register = 0, dxil_kind = 13})
		}
		if len(s.root_cbvs) > 0 {
			blob := bc_array(&s.m, 16384, s.t.i32)
			ty := bc_named_struct(&s.m, "RootCbv", {blob})
			u := bc_undef(&s.m, bc_ptr(&s.m, ty))
			for r in s.root_cbvs {
				node := bc_md_node(&s.m, {
					i32op(s, u32(len(cbv_list))),
					Md_Op{present = true, id = bc_md_val(&s.m, u)},
					empty,
					i32op(s, ROOT_CBV_SPACE),
					i32op(s, u32(r.slot)),
					i32op(s, 1),
					i32op(s, 65536),
					Md_Op{},
				})
				append(&cbv_list, Md_Op{present = true, id = node})
				append(&bindings, Psv_Binding{kind = 2, space = ROOT_CBV_SPACE, register = u32(r.slot), dxil_kind = 13})
			}
		}
		cbvs_op := Md_Op{}
		if len(cbv_list) > 0 {
			cbvs_op = Md_Op{present = true, id = bc_md_node(&s.m, cbv_list[:])}
		}

		srvs_op := Md_Op{}
		if len(s.root_srvs) > 0 {
			ty := bc_named_struct(&s.m, "struct.ByteAddressBuffer", {s.t.i32})
			u := bc_undef(&s.m, bc_ptr(&s.m, ty))
			srv_list := make([dynamic]Md_Op, context.temp_allocator)
			for r, idx in s.root_srvs {
				node := bc_md_node(&s.m, {
					i32op(s, u32(idx)),
					Md_Op{present = true, id = bc_md_val(&s.m, u)},
					empty,
					i32op(s, ROOT_CBV_SPACE),
					i32op(s, u32(r.slot)),
					i32op(s, 1),
					i32op(s, 11),
					i32op(s, 0),
					Md_Op{},
				})
				append(&srv_list, Md_Op{present = true, id = node})
				append(&bindings, Psv_Binding{kind = 4, space = ROOT_CBV_SPACE, register = u32(r.slot), dxil_kind = 11})
			}
			srvs_op = Md_Op{present = true, id = bc_md_node(&s.m, srv_list[:])}
		}

		uavs_op := Md_Op{}
		if len(s.root_uavs) > 0 {
			ty := bc_named_struct(&s.m, "struct.RWByteAddressBuffer", {s.t.i32})
			u := bc_undef(&s.m, bc_ptr(&s.m, ty))
			no := Md_Op{present = true, id = bc_md_val(&s.m, bc_i1(&s.m, false))}
			uav_list := make([dynamic]Md_Op, context.temp_allocator)
			for r, idx in s.root_uavs {
				node := bc_md_node(&s.m, {
					i32op(s, u32(idx)),
					Md_Op{present = true, id = bc_md_val(&s.m, u)},
					empty,
					i32op(s, ROOT_CBV_SPACE),
					i32op(s, u32(r.slot)),
					i32op(s, 1),
					i32op(s, 11),
					no, no, no, Md_Op{},
				})
				append(&uav_list, Md_Op{present = true, id = node})
				append(&bindings, Psv_Binding{kind = 7, space = ROOT_CBV_SPACE, register = u32(r.slot), dxil_kind = 11})
			}
			uavs_op = Md_Op{present = true, id = bc_md_node(&s.m, uav_list[:])}
		}

		samplers_op := Md_Op{}
		if s.samplers > 0 {
			ty := bc_named_struct(&s.m, "struct.SamplerState", {s.t.i32})
			u := bc_undef(&s.m, bc_ptr(&s.m, ty))
			smp_list := make([dynamic]Md_Op, context.temp_allocator)
			for n in 0 ..< s.samplers {
				kind_val := u32((s.cmp_samplers >> u64(n)) & 1)
				node := bc_md_node(&s.m, {
					i32op(s, n),
					Md_Op{present = true, id = bc_md_val(&s.m, u)},
					empty,
					i32op(s, SAMPLER_SPACE),
					i32op(s, n),
					i32op(s, 1),
					i32op(s, kind_val),
					Md_Op{},
				})
				append(&smp_list, Md_Op{present = true, id = node})
				append(&bindings, Psv_Binding{kind = 1, space = SAMPLER_SPACE, register = n, dxil_kind = 14})
			}
			samplers_op = Md_Op{present = true, id = bc_md_node(&s.m, smp_list[:])}
		}

		rmd := bc_md_node(&s.m, {srvs_op, uavs_op, cbvs_op, samplers_op})
		resources_op = Md_Op{present = true, id = rmd}
		bc_named_md(&s.m, "dx.resources", {rmd})
		slice.sort_by_key(bindings[:], proc(b: Psv_Binding) -> int {
			if b.kind == 2 { return 0 }
			if b.kind == 1 { return 1 }
			return 2
		})
	}

	graphics := !s.has_threads || s.has_mesh
	if graphics {
		max_scalars :: proc(els: []Sig_Element) -> u32 {
			m := u32(0)
			for &e in els {
				if e.has_row {
					end := e.row * 4 + u32(e.col) + u32(e.cols)
					if end > m { m = end }
				}
			}
			return m
		}
		ni := max_scalars(s.inputs[:])
		no := max_scalars(s.outputs[:])
		view := make([dynamic]u32, context.temp_allocator)
		append(&view, ni, no)
		if s.has_mesh {
			append(&view, max_scalars(s.prims[:]))
		}
		words_per_in := (no + 31) / 32
		for _ in 0 ..< ni {
			for k in 0 ..< words_per_in {
				rem := no - 32 * k
				bits := rem > 32 ? u32(32) : rem
				append(&view, bits == 32 ? u32(0xFFFF_FFFF) : ((u32(1) << bits) - 1))
			}
		}
		if s.has_gs {
			append(&view, 0, 0, 0)
		}
		arr_t := bc_array(&s.m, u32(len(view)), s.t.i32)
		elems := make([]V, len(view), context.temp_allocator)
		for v, idx in view {
			elems[idx] = bc_i32(&s.m, v)
		}
		agg := bc_aggregate(&s.m, arr_t, elems)
		vn := bc_md_node(&s.m, {Md_Op{present = true, id = bc_md_val(&s.m, agg)}})
		bc_named_md(&s.m, "dx.viewIdState", {vn})
	}

	if s.pixel {
		same_mode_per_row(s.inputs[:], true)
	} else {
		same_mode_per_row(s.outputs[:], false)
	}
	sigs_op := Md_Op{}
	if graphics {
		ins := shader_signature_md(s, s.inputs[:])
		outs := shader_signature_md(s, s.outputs[:])
		prims := shader_signature_md(s, s.prims[:])
		sigs_op = Md_Op{present = true, id = bc_md_node(&s.m, {ins, outs, prims})}
	}
	if s.pixel {
		for &o in s.outputs {
			if o.kind == 20 {
				s.flags |= DXIL_FLAG_STENCIL_REF
				break
			}
		}
	}

	props := make([dynamic]Md_Op, context.temp_allocator)
	if s.flags != 0 {
		append(&props, i32op(s, 0))
		fval := bc_i64(&s.m, i64(s.flags))
		append(&props, Md_Op{present = true, id = bc_md_val(&s.m, fval)})
	}
	if s.has_threads {
		tn := Md_Op{present = true, id = bc_md_node(&s.m, {i32op(s, s.threads[0]), i32op(s, s.threads[1]), i32op(s, s.threads[2])})}
		if s.has_mesh {
			append(&props, i32op(s, 9))
			append(&props, Md_Op{present = true, id = bc_md_node(&s.m, {tn, i32op(s, s.mesh.max_vertices), i32op(s, s.mesh.max_primitives), i32op(s, u32(s.mesh.topology)), i32op(s, 0)})})
		} else {
			append(&props, i32op(s, 4), tn)
		}
	}
	if s.has_gs {
		append(&props, i32op(s, 1))
		append(&props, Md_Op{present = true, id = bc_md_node(&s.m, {i32op(s, 3), i32op(s, s.gs_max), i32op(s, 1), i32op(s, 5), i32op(s, 1)})})
	}
	if s.has_wave {
		wn := Md_Op{present = true, id = bc_md_node(&s.m, {i32op(s, s.wave_size)})}
		append(&props, i32op(s, 11), wn)
	}
	props_op := Md_Op{}
	if len(props) > 0 {
		props_op = Md_Op{present = true, id = bc_md_node(&s.m, props[:])}
	}

	entry_md := bc_md_node(&s.m, {
		Md_Op{present = true, id = bc_md_val(&s.m, s.main_fn)},
		Md_Op{present = true, id = bc_md_str(&s.m, "main")},
		sigs_op,
		resources_op,
		props_op,
	})
	ident := bc_md_node(&s.m, {Md_Op{present = true, id = bc_md_str(&s.m, "vasperty")}})
	bc_named_md(&s.m, "llvm.ident", {ident})
	one := i32op(s, 1)
	six := i32op(s, 6)
	ver := bc_md_node(&s.m, {one, six})
	bc_named_md(&s.m, "dx.version", {ver})
	bc_named_md(&s.m, "dx.valver", {ver})

	stage_str := "vs"
	kind := u32(1)
	if s.has_mesh {
		stage_str = "ms"
		kind = 13
	} else if s.has_gs {
		stage_str = "gs"
		kind = 2
	} else if s.has_threads {
		stage_str = "cs"
		kind = 5
	} else if s.pixel {
		stage_str = "ps"
		kind = 0
	}
	sm_node := bc_md_node(&s.m, {Md_Op{present = true, id = bc_md_str(&s.m, stage_str)}, six, six})
	bc_named_md(&s.m, "dx.shaderModel", {sm_node})
	bc_named_md(&s.m, "dx.entryPoints", {entry_md})

	bitcode := bc_write(&s.m, context.temp_allocator)
	dxil := make([]u8, 24 + len(bitcode), context.temp_allocator)
	prog_ver := (kind << 16) | 0x66
	size_dwords := u32(len(dxil) / 4)
	dxil[0] = u8(prog_ver)
	dxil[1] = u8(prog_ver >> 8)
	dxil[2] = u8(prog_ver >> 16)
	dxil[3] = u8(prog_ver >> 24)
	dxil[4] = u8(size_dwords)
	dxil[5] = u8(size_dwords >> 8)
	dxil[6] = u8(size_dwords >> 16)
	dxil[7] = u8(size_dwords >> 24)
	dxil[8], dxil[9], dxil[10], dxil[11] = 'D', 'X', 'I', 'L'
	dxil[12], dxil[13], dxil[14], dxil[15] = 0x06, 0x01, 0x00, 0x00
	dxil[16], dxil[17], dxil[18], dxil[19] = 16, 0, 0, 0
	bc_len := u32(len(bitcode))
	dxil[20] = u8(bc_len)
	dxil[21] = u8(bc_len >> 8)
	dxil[22] = u8(bc_len >> 16)
	dxil[23] = u8(bc_len >> 24)
	copy(dxil[24:], bitcode)

	features := u64(0)
	if (s.flags & DXIL_FLAG_UAVS_EVERY_STAGE) != 0 { features |= 0x4 }
	if (s.flags & DXIL_FLAG_STENCIL_REF) != 0 { features |= 0x200 }
	if (s.flags & DXIL_FLAG_TYPED_UAV_LOADS) != 0 { features |= 0x800 }
	if (s.flags & DXIL_FLAG_ROVS) != 0 { features |= 0x1000 }
	if (s.flags & DXIL_FLAG_WAVE_OPS) != 0 { features |= 0x4000 }
	if (s.flags & DXIL_FLAG_INT64) != 0 { features |= 0x8000 }
	if (s.flags & DXIL_FLAG_RESOURCE_HEAP) != 0 { features |= 0x200_0000 }
	if (s.flags & DXIL_FLAG_SAMPLER_HEAP) != 0 { features |= 0x400_0000 }
	if (s.flags & DXIL_FLAG_ATOMIC64_TYPED) != 0 { features |= 0x40_0000 }
	if (s.flags & DXIL_FLAG_ATOMIC64_HEAP) != 0 { features |= 0x1000_0000 }
	sfi0: [8]u8
	for k in 0 ..< u32(8) {
		sfi0[k] = u8(features >> (k * 8))
	}

	isg1 := build_signature_part(s.inputs[:], true, context.temp_allocator)
	osg1 := build_signature_part(s.outputs[:], false, context.temp_allocator)
	psg1 := build_signature_part(s.prims[:], false, context.temp_allocator)

	psv_flag := false
	if s.pixel {
		for &o in s.outputs {
			if o.kind >= 17 && o.kind <= 19 { psv_flag = true; break }
		}
	} else {
		for &o in s.outputs {
			if o.kind == 3 { psv_flag = true; break }
		}
	}
	psv0 := build_psv0(&Psv_Desc{
		stage     = u8(kind),
		flag      = psv_flag && !s.has_threads,
		inputs    = s.inputs[:],
		outputs   = s.outputs[:],
		prims     = s.prims[:],
		has_mesh  = s.has_mesh,
		mesh      = s.mesh,
		mesh_lds  = s.lds_dwords * 4,
		has_gs    = s.has_gs,
		gs_max    = s.gs_max,
		bindings  = bindings[:],
		threads   = s.threads,
		has_wave  = s.has_wave,
		wave_size = s.wave_size,
	}, context.temp_allocator)
	hash_zero: [20]u8

	parts := make([dynamic]Raw_Part, 0, 7, context.temp_allocator)
	append(&parts, Raw_Part{fourcc = FOURCC_SFI0, data = sfi0[:]})
	append(&parts, Raw_Part{fourcc = FOURCC_ISG1, data = isg1})
	append(&parts, Raw_Part{fourcc = FOURCC_OSG1, data = osg1})
	if s.has_mesh {
		append(&parts, Raw_Part{fourcc = FourCC{'P', 'S', 'G', '1'}, data = psg1})
	}
	append(&parts, Raw_Part{fourcc = FOURCC_PSV0, data = psv0})
	append(&parts, Raw_Part{fourcc = FOURCC_HASH, data = hash_zero[:]})
	append(&parts, Raw_Part{fourcc = FOURCC_DXIL, data = dxil})

	built := dxbc_build(parts[:], context.temp_allocator)
	out := make([dynamic]u8, len(built))
	copy(out[:], built)
	return out
}

// =========================================================================
// Rectangle GS helper
// =========================================================================

right_angle :: proc(xy: [3][2]f32) -> int {
	side :: proc(a, b: [2]f32) -> f32 {
		dx := a[0] - b[0]
		dy := a[1] - b[1]
		return dx * dx + dy * dy
	}
	d12 := side(xy[1], xy[2])
	d20 := side(xy[2], xy[0])
	d01 := side(xy[0], xy[1])
	if d12 > d20 && d12 > d01 {
		return 0
	}
	if d01 > d12 && d01 > d20 {
		return 2
	}
	return 1
}

rectangle_gs :: proc(vs_container: []u8) -> ([dynamic]u8, Shader_Error) {
	c, perr := dxbc_parse(vs_container)
	if perr != .None {
		return nil, perr
	}
	defer destroy_container(&c)
	osg_data, ok := dxbc_part(&c, FOURCC_OSG1)
	if !ok {
		return nil, .Malformed
	}
	raw_elems, serr := parse_signature_part(osg_data)
	if serr != .None {
		return nil, serr
	}
	defer {
		for &e in raw_elems { delete(e.name) }
		delete(raw_elems)
	}

	elements := make([dynamic]Sig_Element)
	defer sig_list_destroy(&elements)
	pos_idx := -1
	for &e in raw_elems {
		if e.has_row {
			ne := e
			ne.name = strings.clone(e.name)
			ne.usage = (u8(1) << e.cols) - 1
			if ne.kind == 3 && ne.cols >= 2 && ne.comp == 9 && pos_idx == -1 {
				pos_idx = len(elements)
			}
			append(&elements, ne)
		}
	}
	if pos_idx == -1 {
		return nil, .Malformed
	}

	s := shader_create(false)
	defer shader_destroy(&s)
	s.has_gs = true
	s.gs_max = 6
	b := s.entry

	corners: [3][dynamic][dynamic]V
	defer {
		for ci in 0 ..< 3 {
			for &el in corners[ci] { delete(el) }
			delete(corners[ci])
		}
	}
	for k in 0 ..< u32(3) {
		corners[k] = make([dynamic][dynamic]V, len(elements))
		for &el, id in elements {
			corners[k][id] = make([dynamic]V, el.cols)
			ty := el.comp == 9 ? s.t.f32 : s.t.i32
			opn := el.comp == 9 ? "loadInput.f32" : "loadInput.i32"
			for col in u8(0) ..< el.cols {
				corners[k][id][col] = shader_op(&s, b, opn, .Read_None, ty, 4, {bc_i32(&s.m, u32(id)), bc_i32(&s.m, 0), bc_i8(&s.m, col), bc_i32(&s.m, k)})
			}
		}
	}

	gs_side :: proc(sh: ^Dxil_Shader, blk: int, c_arr: ^[3][dynamic][dynamic]V, pid: int, i, j: int) -> V {
		dx := bc_bin(&sh.m, blk, .Sub, c_arr[i][pid][0], c_arr[j][pid][0])
		dy := bc_bin(&sh.m, blk, .Sub, c_arr[i][pid][1], c_arr[j][pid][1])
		sx := bc_bin(&sh.m, blk, .Mul, dx, dx)
		sy := bc_bin(&sh.m, blk, .Mul, dy, dy)
		return bc_bin(&sh.m, blk, .Add, sx, sy)
	}
	d12 := gs_side(&s, b, &corners, pos_idx, 1, 2)
	d20 := gs_side(&s, b, &corners, pos_idx, 2, 0)
	d01 := gs_side(&s, b, &corners, pos_idx, 0, 1)
	at0 := bc_bin(&s.m, b, .And, bc_cmp(&s.m, b, PRED_OGT, d12, d20), bc_cmp(&s.m, b, PRED_OGT, d12, d01))
	at2 := bc_bin(&s.m, b, .And, bc_cmp(&s.m, b, PRED_OGT, d01, d12), bc_cmp(&s.m, b, PRED_OGT, d01, d20))

	gs_pick :: proc(sh: ^Dxil_Shader, blk: int, c0, c2: V, x0, x1, x2: V) -> V {
		tmp := bc_select(&sh.m, blk, c2, x2, x1)
		return bc_select(&sh.m, blk, c0, x0, tmp)
	}

	second: [3][dynamic][dynamic]V
	defer {
		for k in 0 ..< 3 {
			for &el in second[k] { delete(el) }
			delete(second[k])
		}
	}
	for k in 0 ..< 3 {
		second[k] = make([dynamic][dynamic]V, len(elements))
	}
	for &el, id in elements {
		for k in 0 ..< 3 {
			second[k][id] = make([dynamic]V, el.cols)
		}
		for col in 0 ..< int(el.cols) {
			v0 := corners[0][id][col]
			v1 := corners[1][id][col]
			v2 := corners[2][id][col]
			va := gs_pick(&s, b, at0, at2, v2, v0, v1)
			vb := gs_pick(&s, b, at0, at2, v1, v2, v0)
			v3 := va
			if el.comp == 9 {
				vc := gs_pick(&s, b, at0, at2, v0, v1, v2)
				sum := bc_bin(&s.m, b, .Add, va, vb)
				v3 = bc_bin(&s.m, b, .Sub, sum, vc)
			}
			second[0][id][col] = va
			second[1][id][col] = vb
			second[2][id][col] = v3
		}
	}

	for pass in 0 ..< 2 {
		for k in 0 ..< 3 {
			src_tri := &corners[k] if pass == 0 else &second[k]
			for &el, id in elements {
				suf := "storeOutput.f32" if el.comp == 9 else "storeOutput.i32"
				for col in u8(0) ..< el.cols {
					v := src_tri[id][col]
					shader_op(&s, b, suf, .No_Unwind, s.t.void_ty, 5, {bc_i32(&s.m, u32(id)), bc_i32(&s.m, 0), bc_i8(&s.m, col), v})
				}
			}
			shader_op(&s, b, "emitStream", .No_Unwind, s.t.void_ty, 97, {bc_i8(&s.m, 0)})
		}
		shader_op(&s, b, "cutStream", .No_Unwind, s.t.void_ty, 98, {bc_i8(&s.m, 0)})
	}

	for &el in elements {
		e1 := el; e1.name = strings.clone(el.name); append(&s.inputs, e1)
		e2 := el; e2.name = strings.clone(el.name); append(&s.outputs, e2)
	}
	bc_terminate(&s.m, b, Term{kind = .Ret})
	return shader_finish(&s), .None
}

// =========================================================================
// Host_Shader public result & options
// =========================================================================

User_Data :: struct {
	index: u32,
	slot:  u8,
	root:  Root_Type,
	dword: u32,
}

Host_Shader :: struct {
	stage:            Hw_Stage,
	dxil:             [dynamic]u8,
	user_data:        [dynamic]User_Data,
	samplers:         [dynamic][4]u32,
	static_samplers:  [dynamic]Static_Sampler,
	root_cbvs:        [dynamic]u8,
	root_srvs:        [dynamic]u8,
	root_uavs:        [dynamic]u8,
	memory:           bool,
	memory_writes:    bool,
	view_addresses:   bool,
	heap:             bool,
	heap_writes:      bool,
	view_marks:       bool,
	target_wave_size: u8,
}

host_shader_user_data_dwords :: proc(hs: ^Host_Shader) -> u32 {
	m := u32(0)
	for u in hs.user_data {
		if u.index + 1 > m {
			m = u.index + 1
		}
	}
	return (m + 3) & ~u32(3)
}

destroy_host_shader :: proc(hs: ^Host_Shader) {
	delete(hs.dxil)
	delete(hs.user_data)
	delete(hs.samplers)
	delete(hs.static_samplers)
	delete(hs.root_cbvs)
	delete(hs.root_srvs)
	delete(hs.root_uavs)
}

Target_Wave_Mode :: enum {
	Auto,
	Wave64,
	Wave32,
	Wave16,
}

target_wave_lanes :: proc "contextless" (mode: Target_Wave_Mode) -> u8 {
	switch mode {
	case .Wave16: return 16
	case .Wave32: return 32
	case .Wave64: return 64
	case .Auto:   return 32
	}
	return 32
}

wave_lane_mask :: proc "contextless" (mode: Target_Wave_Mode) -> u64 {
	switch mode {
	case .Wave16: return 0x0000_0000_0000_FFFF
	case .Wave32: return 0x0000_0000_FFFF_FFFF
	case .Wave64: return 0xFFFF_FFFF_FFFF_FFFF
	case .Auto:   return 0x0000_0000_FFFF_FFFF
	}
	return 0x0000_0000_FFFF_FFFF
}

// Scopes ds_bpermute_b32 lane indices to 16-lane (Intel UHD/Xe) or 32-lane (NVIDIA / Wave64 halves, #573).
bpermute_lane_mask :: proc "contextless" (mode: Target_Wave_Mode) -> u32 {
	if mode == .Wave16 {
		return 0x0F
	}
	return 0x1F
}

bpermute_base_mask :: proc "contextless" (mode: Target_Wave_Mode) -> u32 {
	return ~bpermute_lane_mask(mode)
}

// Guards LDS accesses against out-of-bounds reads/writes past program LDS allocation (#1870/#1949).
lds_offset_in_bounds :: proc "contextless" (offset, width_bytes, lds_bytes: u32) -> bool {
	if lds_bytes == 0 || width_bytes == 0 {
		return false
	}
	return u64(offset) + u64(width_bytes) <= u64(lds_bytes)
}

// Safe 64-bit integer comparison via split hi/lo dwords (avoids driver shared-dword i64 compare bugs, #1599).
cmp_i64_dwords_safe :: proc "contextless" (a, b: u64, signed: bool) -> i32 {
	a_hi := u32(a >> 32)
	b_hi := u32(b >> 32)
	if a_hi != b_hi {
		if signed {
			return -1 if i32(a_hi) < i32(b_hi) else 1
		}
		return -1 if a_hi < b_hi else 1
	}
	a_lo := u32(a)
	b_lo := u32(b)
	if a_lo == b_lo {
		return 0
	}
	return -1 if a_lo < b_lo else 1
}

// Flushes f32 denormals to signed zero (used by v_mul_legacy_f32 #682 & cubemap coords #1766).
flush_denorm_f32 :: proc "contextless" (x: f32) -> f32 {
	bits := transmute(u32)x
	if (bits & 0x7F80_0000) == 0 {
		return transmute(f32)(bits & 0x8000_0000)
	}
	return x
}

// RDNA2 v_mul_legacy_f32: flushes denormals to zero and yields +0.0 when either operand is 0 (#682).
mul_legacy_f32_safe :: proc "contextless" (a, b: f32) -> f32 {
	fa := flush_denorm_f32(a)
	fb := flush_denorm_f32(b)
	if fa == 0 || fb == 0 {
		return 0.0
	}
	return fa * fb
}

// RDNA2 v_med3_f32 with -0.0 ordered strictly below +0.0 (#1259).
@(private)
f32_lt_signed_zero :: proc "contextless" (a, b: f32) -> bool {
	if a != b {
		return a < b
	}
	if a == 0 {
		return (transmute(u32)a >> 31) > (transmute(u32)b >> 31)
	}
	return false
}

med3_f32_ordered :: proc "contextless" (a, b, c: f32) -> f32 {
	x, y, z := a, b, c
	if f32_lt_signed_zero(y, x) { x, y = y, x }
	if f32_lt_signed_zero(z, y) { y, z = z, y }
	if f32_lt_signed_zero(y, x) { x, y = y, x }
	return y
}

Shader_Options :: struct {
	view_marks: bool,
	loop_limit: u32,
	wave_mode:  Target_Wave_Mode,
}

// =========================================================================
// Lowering Context & Value Evaluation
// =========================================================================

Val_Kind :: enum u8 {
	I32,
	Bit,
	Missing,
}

Val :: struct {
	kind: Val_Kind,
	v:    V,
	why:  string,
}

Lower_Ctx :: struct {
	s:           Dxil_Shader,
	native:      ^Native_Program,
	p:           ^Program,
	st:          ^Structured,
	io:          ^Io,
	res:         ^Resources,
	loop_limit:  u32,
	vals:        map[Value]Val,
	block_map:   []int,
	rpo:         []int,
	cur:         int,
	user_reads:  map[u32]User_Data,
	data_phis:   [dynamic]struct {
		v:     V,
		block: int,
		phi_i: int,
	},
	bool_cache:  map[struct {
		blk: int,
		b:   Bool,
	}]V,
	exports_map: map[Site]^Export,
	interps_map: map[Site]^Interp,
	desc_map:    map[Site]^Source,
	samp_map:    map[Site]^Source,
	scalar_map:  map[Site]Address,
	params_map:  map[Value]Param_Input,
	samplers:    [dynamic][4]u32,
}

lower_destroy :: proc(l: ^Lower_Ctx) {
	shader_destroy(&l.s)
	delete(l.vals)
	delete(l.block_map)
	delete(l.rpo)
	delete(l.user_reads)
	delete(l.data_phis)
	delete(l.bool_cache)
	delete(l.exports_map)
	delete(l.interps_map)
	delete(l.desc_map)
	delete(l.samp_map)
	delete(l.scalar_map)
	delete(l.params_map)
	delete(l.samplers)
}

lower_get_i32 :: proc(l: ^Lower_Ctx, val: Value) -> (V, bool) {
	if rv, ok := l.vals[val]; ok {
		if rv.kind == .I32 {
			return rv.v, true
		}
		if rv.kind == .Bit {
			return bc_cast(&l.s.m, l.cur, .ZExt, rv.v, l.s.t.i32), true
		}
		return {}, false
	}
	if pi, pok := l.params_map[val]; pok {
		rp := l.native.layout[pi.param]
		ud_idx := u32(rp.user_data) + pi.dword
		l.user_reads[ud_idx] = User_Data{
			index = ud_idx,
			slot  = rp.slot,
			root  = rp.root,
			dword = pi.dword,
		}
		if ud_idx + 1 > l.s.user_data {
			l.s.user_data = ud_idx + 1
		}
		uh := shader_user_data_handle(&l.s)
		loaded := shader_op(&l.s, l.s.entry, "cbufferLoadLegacy.i32", .Read_Only, l.s.t.cbuf_ret, 59, {uh, bc_i32(&l.s.m, ud_idx / 4)})
		ext := bc_extract(&l.s.m, l.s.entry, loaded, ud_idx % 4)
		l.vals[val] = Val{kind = .I32, v = ext}
		return ext, true
	}
	return {}, false
}

lower_get_bit :: proc(l: ^Lower_Ctx, val: Value) -> (V, bool) {
	if rv, ok := l.vals[val]; ok {
		if rv.kind == .Bit {
			return rv.v, true
		}
		if rv.kind == .I32 {
			return bc_cmp(&l.s.m, l.cur, PRED_NE, rv.v, bc_i32(&l.s.m, 0)), true
		}
		return {}, false
	}
	return {}, false
}

lower_operand :: proc(l: ^Lower_Ctx, inst: ^Inst, op: Operand) -> (V, bool) {
	switch op.kind {
	case .Const:
		val_u, ok := inline_const_u64(op.code)
		if !ok {
			return {}, false
		}
		return bc_i32(&l.s.m, u32(val_u)), true
	case .Literal:
		return bc_i32(&l.s.m, op.literal), true
	case .Scalar:
		if op.code == NULL_SCALAR {
			return bc_i32(&l.s.m, 0), true
		}
		if op.code == 0xFD {
			if sv, sok := inst_read(inst, reg_scc()); sok {
				return lower_get_i32(l, sv)
			}
			return {}, false
		}
		if op.code < 128 {
			if sv, sok := inst_read(inst, reg_s(op.code)); sok {
				return lower_get_i32(l, sv)
			}
		}
	case .Vector:
		if vv, vok := inst_read(inst, reg_v(op.code)); vok {
			return lower_get_i32(l, vv)
		}
	case .Attr:
	}
	return {}, false
}

lower_foperand :: proc(l: ^Lower_Ctx, inst: ^Inst, k: int, op: Operand) -> (V, bool) {
	v, ok := lower_operand(l, inst, op)
	if !ok {
		return {}, false
	}
	f := bc_cast(&l.s.m, l.cur, .Bitcast, v, l.s.t.f32)
	if k < 3 && ((inst.fields.valu.abs >> u8(k)) & 1) != 0 {
		f = shader_op(&l.s, l.cur, "unary.f32", .Read_None, l.s.t.f32, 6, {f})
	}
	if k < 3 && ((inst.fields.valu.neg >> u8(k)) & 1) != 0 {
		neg_z := bc_f32_bits(&l.s.m, 0x8000_0000)
		f = bc_bin(&l.s.m, l.cur, .Sub, neg_z, f)
	}
	return f, true
}

lower_atom :: proc(l: ^Lower_Ctx, atom: Atom) -> V {
	switch atom.kind {
	case .Uniform, .Lane, .Opaque, .Phi, .Quad:
		if bv, ok := lower_get_bit(l, atom.val); ok {
			return bv
		}
		return bc_i1(&l.s.m, atom.kind != .Uniform)
	case .Constant:
		return bc_i1(&l.s.m, atom.constant != 0)
	}
	return bc_i1(&l.s.m, false)
}

lower_boolean :: proc(l: ^Lower_Ctx, b: Bool, blk: int) -> V {
	if b == BOOL_TRUE {
		return bc_i1(&l.s.m, true)
	}
	if b == BOOL_FALSE {
		return bc_i1(&l.s.m, false)
	}
	key := struct {
		blk: int,
		b:   Bool,
	}{blk = blk, b = b}
	if cached, ok := l.bool_cache[key]; ok {
		return cached
	}
	atom, lo, hi, is_node := bools_node(&l.st.bools, b)
	if !is_node {
		return bc_i1(&l.s.m, false)
	}
	cond := lower_atom(l, atom)
	res: V
	if lo == BOOL_FALSE && hi == BOOL_TRUE {
		res = cond
	} else if lo == BOOL_TRUE && hi == BOOL_FALSE {
		res = bc_bin(&l.s.m, blk, .Xor, cond, bc_i1(&l.s.m, true))
	} else {
		lv := lower_boolean(l, lo, blk)
		hv := lower_boolean(l, hi, blk)
		res = bc_select(&l.s.m, blk, cond, hv, lv)
	}
	l.bool_cache[key] = res
	return res
}

lower_inputs :: proc(l: ^Lower_Ctx) {
	entry := l.s.entry
	for &inp in l.io.inputs {
		val := Val{kind = .Missing, why = "unhandled input"}
		switch inp.input.kind {
		case .Vertex_Id, .Instance_Id, .Position, .Front_Face, .Attribute:
			kind := u8(0)
			col := u8(0)
			if inp.input.kind == .Vertex_Id { kind = 1 }
			else if inp.input.kind == .Instance_Id { kind = 2 }
			else if inp.input.kind == .Position { kind = 3; col = inp.input.component }
			else if inp.input.kind == .Front_Face { kind = 13 }
			sig_id := -1
			if inp.input.kind == .Attribute {
				for &se, idx in l.s.inputs {
					if se.has_row && se.row == u32(inp.input.row) && inp.input.channel >= se.col && inp.input.channel < se.col + se.cols {
						sig_id = idx
						col = inp.input.channel - se.col
						break
					}
				}
			} else {
				for &se, idx in l.s.inputs {
					if se.kind == kind {
						sig_id = idx
						if !se.has_row && kind != 3 {
							free_row := u32(0)
							for &se2 in l.s.inputs {
								if se2.has_row && se2.row + 1 > free_row { free_row = se2.row + 1 }
							}
							se.has_row = true
							se.row = free_row
						}
						break
					}
				}
				if sig_id == -1 && (kind == 1 || kind == 2) {
					free_row := u32(0)
					for &se2 in l.s.inputs {
						if se2.has_row && se2.row + 1 > free_row { free_row = se2.row + 1 }
					}
					se_name := "SV_VertexID" if kind == 1 else "SV_InstanceID"
					append(&l.s.inputs, Sig_Element{
						name    = strings.clone(se_name),
						kind    = kind,
						comp    = 5,
						has_row = true,
						row     = free_row,
						cols    = 1,
					})
					sig_id = len(l.s.inputs) - 1
				}
			}
			if sig_id >= 0 {
				se := &l.s.inputs[sig_id]
				if se.comp == 9 {
					fv := shader_op(&l.s, entry, "loadInput.f32", .Read_None, l.s.t.f32, 4, {bc_i32(&l.s.m, u32(sig_id)), bc_i32(&l.s.m, 0), bc_i8(&l.s.m, col), bc_undef(&l.s.m, l.s.t.i32)})
					val = Val{kind = .I32, v = bc_cast(&l.s.m, entry, .Bitcast, fv, l.s.t.i32)}
				} else {
					iv := shader_op(&l.s, entry, "loadInput.i32", .Read_None, l.s.t.i32, 4, {bc_i32(&l.s.m, u32(sig_id)), bc_i32(&l.s.m, 0), bc_i8(&l.s.m, col), bc_undef(&l.s.m, l.s.t.i32)})
					val = Val{kind = .I32, v = iv}
				}
			}
		case .Thread_Id_In_Group:
			iv := shader_op(&l.s, entry, "threadIdInGroup.i32", .Read_None, l.s.t.i32, 95, {bc_i32(&l.s.m, u32(inp.input.component))})
			val = Val{kind = .I32, v = iv}
		case .Group_Id:
			iv := shader_op(&l.s, entry, "groupId.i32", .Read_None, l.s.t.i32, 94, {bc_i32(&l.s.m, u32(inp.input.component))})
			val = Val{kind = .I32, v = iv}
		case .Mesh_Group:
			iv := shader_op(&l.s, entry, "groupId.i32", .Read_None, l.s.t.i32, 94, {bc_i32(&l.s.m, 0)})
			val = Val{kind = .I32, v = iv}
		case .Merged_Wave_Info:
			val = Val{kind = .I32, v = bc_i32(&l.s.m, 0)}
		case .Barycentric, .Primitive_Id, .Line_Stipple, .Ancillary, .Sample_Coverage, .Fixed_Position, .Group_Info:
		}
		l.vals[inp.val] = val
	}
}

lower_sop :: proc(l: ^Lower_Ctx, inst: ^Inst) {
	c := l.cur
	name := inst_name(inst)
	scc_w, has_scc := inst_write(inst, reg_scc())
	dst_w := Value(0)
	has_dst := false
	if inst.fields.has_dst && inst.fields.dst.kind == .Scalar && inst.fields.dst.code < 128 {
		dst_w, has_dst = inst_write(inst, reg_s(inst.fields.dst.code))
	}

	s0 := inst.fields.src[0] if len(inst.fields.src) > 0 else Operand{}
	s1 := inst.fields.src[1] if len(inst.fields.src) > 1 else Operand{}

	set_i32 :: proc(lx: ^Lower_Ctx, has: bool, wv: Value, v: V) {
		if has { lx.vals[wv] = Val{kind = .I32, v = v} }
	}
	set_bit :: proc(lx: ^Lower_Ctx, has: bool, wv: Value, v: V) {
		if has { lx.vals[wv] = Val{kind = .Bit, v = v} }
	}

	if strings.has_prefix(name, "s_cmp_") || strings.has_prefix(name, "s_cmpk_") {
		a, ok_a := lower_operand(l, inst, s0)
		if !ok_a { return }
		b: V
		if strings.has_prefix(name, "s_cmpk_") {
			imm := inst.fields.imm if inst.fields.has_imm else u16(0)
			b = bc_i32(&l.s.m, u32(i32(i16(imm)))) if strings.has_suffix(name, "_i32") else bc_i32(&l.s.m, u32(imm))
		} else {
			ok_b: bool
			b, ok_b = lower_operand(l, inst, s1)
			if !ok_b { return }
		}
		pred := PRED_EQ
		signed := strings.has_suffix(name, "_i32")
		if strings.contains(name, "_eq_") { pred = PRED_EQ }
		else if strings.contains(name, "_lg_") { pred = PRED_NE }
		else if strings.contains(name, "_gt_") { pred = PRED_SGT if signed else PRED_IUGT }
		else if strings.contains(name, "_ge_") { pred = PRED_SGE if signed else PRED_IUGE }
		else if strings.contains(name, "_lt_") { pred = PRED_SLT if signed else PRED_IULT }
		else if strings.contains(name, "_le_") { pred = PRED_SLE if signed else PRED_IULE }
		set_bit(l, has_scc, scc_w, bc_cmp(&l.s.m, c, pred, a, b))
		return
	}

	if strings.has_prefix(name, "s_bitcmp") {
		a, ok_a := lower_operand(l, inst, s0)
		b, ok_b := lower_operand(l, inst, s1)
		if !ok_a || !ok_b { return }
		idx := bc_bin(&l.s.m, c, .And, b, bc_i32(&l.s.m, 31))
		sh := bc_bin(&l.s.m, c, .LShr, a, idx)
		bit := bc_bin(&l.s.m, c, .And, sh, bc_i32(&l.s.m, 1))
		want := u32(1) if strings.contains(name, "bitcmp1") else u32(0)
		set_bit(l, has_scc, scc_w, bc_cmp(&l.s.m, c, PRED_EQ, bit, bc_i32(&l.s.m, want)))
		return
	}

	if name == "s_mov_b32" || name == "s_movk_i32" || name == "s_mov_b64" {
		if name == "s_movk_i32" {
			imm := inst.fields.imm if inst.fields.has_imm else u16(0)
			set_i32(l, has_dst, dst_w, bc_i32(&l.s.m, u32(i32(i16(imm)))))
			return
		}
		if a, ok := lower_operand(l, inst, s0); ok {
			set_i32(l, has_dst, dst_w, a)
		}
		return
	}

	if name == "s_cselect_b32" {
		scc_r, has_sr := inst_read(inst, reg_scc())
		a, oka := lower_operand(l, inst, s0)
		b, okb := lower_operand(l, inst, s1)
		if has_sr && oka && okb {
			if cond, okc := lower_get_bit(l, scc_r); okc {
				set_i32(l, has_dst, dst_w, bc_select(&l.s.m, c, cond, a, b))
			}
		}
		return
	}

	if name == "s_andn2_b32" || name == "s_and_b32" || name == "s_or_b32" || name == "s_xor_b32" ||
	   name == "s_add_u32" || name == "s_add_i32" || name == "s_sub_u32" || name == "s_sub_i32" ||
	   name == "s_mul_i32" || name == "s_lshl_b32" || name == "s_lshr_b32" || name == "s_ashr_i32" {
		a, oka := lower_operand(l, inst, s0)
		b, okb := lower_operand(l, inst, s1)
		if !oka || !okb { return }
		r: V
		switch name {
		case "s_and_b32":  r = bc_bin(&l.s.m, c, .And, a, b)
		case "s_andn2_b32":
			nb := bc_bin(&l.s.m, c, .Xor, b, bc_i32(&l.s.m, 0xFFFF_FFFF))
			r = bc_bin(&l.s.m, c, .And, a, nb)
		case "s_or_b32":   r = bc_bin(&l.s.m, c, .Or, a, b)
		case "s_xor_b32":  r = bc_bin(&l.s.m, c, .Xor, a, b)
		case "s_add_u32", "s_add_i32": r = bc_bin(&l.s.m, c, .Add, a, b)
		case "s_sub_u32", "s_sub_i32": r = bc_bin(&l.s.m, c, .Sub, a, b)
		case "s_mul_i32":  r = bc_bin(&l.s.m, c, .Mul, a, b)
		case "s_lshl_b32": r = bc_bin(&l.s.m, c, .Shl, a, bc_bin(&l.s.m, c, .And, b, bc_i32(&l.s.m, 31)))
		case "s_lshr_b32": r = bc_bin(&l.s.m, c, .LShr, a, bc_bin(&l.s.m, c, .And, b, bc_i32(&l.s.m, 31)))
		case "s_ashr_i32": r = bc_bin(&l.s.m, c, .AShr, a, bc_bin(&l.s.m, c, .And, b, bc_i32(&l.s.m, 31)))
		}
		set_i32(l, has_dst, dst_w, r)
		if has_scc {
			if name == "s_add_u32" {
				set_bit(l, true, scc_w, bc_cmp(&l.s.m, c, PRED_IULT, r, a))
			} else if name == "s_sub_u32" {
				set_bit(l, true, scc_w, bc_cmp(&l.s.m, c, PRED_IUGT, r, a))
			} else {
				set_bit(l, true, scc_w, bc_cmp(&l.s.m, c, PRED_NE, r, bc_i32(&l.s.m, 0)))
			}
		}
		return
	}

	if name == "s_addk_i32" || name == "s_mulk_i32" {
		if inst.fields.has_dst {
			if a, oka := lower_operand(l, inst, inst.fields.dst); oka {
				imm := bc_i32(&l.s.m, u32(i32(i16(inst.fields.imm))))
				op_k := Bin_Op.Add if name == "s_addk_i32" else Bin_Op.Mul
				r := bc_bin(&l.s.m, c, op_k, a, imm)
				set_i32(l, has_dst, dst_w, r)
				set_bit(l, has_scc, scc_w, bc_cmp(&l.s.m, c, PRED_NE, r, bc_i32(&l.s.m, 0)))
			}
		}
		return
	}

	if name == "s_not_b32" {
		if a, oka := lower_operand(l, inst, s0); oka {
			r := bc_bin(&l.s.m, c, .Xor, a, bc_i32(&l.s.m, 0xFFFF_FFFF))
			set_i32(l, has_dst, dst_w, r)
			set_bit(l, has_scc, scc_w, bc_cmp(&l.s.m, c, PRED_NE, r, bc_i32(&l.s.m, 0)))
		}
		return
	}

	if name == "s_bcnt1_i32_b32" || name == "s_bcnt1_i32_b64" {
		if a, oka := lower_operand(l, inst, s0); oka {
			r := shader_op(&l.s, c, "unaryBits.i32", .Read_None, l.s.t.i32, 31, {a})
			set_i32(l, has_dst, dst_w, r)
			set_bit(l, has_scc, scc_w, bc_cmp(&l.s.m, c, PRED_NE, r, bc_i32(&l.s.m, 0)))
		}
		return
	}
}

lower_valu :: proc(l: ^Lower_Ctx, inst: ^Inst, guard: Maybe(V)) {
	c := l.cur
	name := inst_name(inst)

	write_v :: proc(lx: ^Lower_Ctx, inst: ^Inst, g: Maybe(V), val_v: V) {
		if inst.fields.valu.has_dst && inst.fields.valu.dst.kind == .Vector {
			if wv, wok := inst_write(inst, reg_v(inst.fields.valu.dst.code)); wok {
				res := val_v
				if gv, has_g := g.?; has_g {
					if old_v, has_old := inst_read(inst, reg_v(inst.fields.valu.dst.code)); has_old {
						if old_i32, ok_old := lower_get_i32(lx, old_v); ok_old {
							res = bc_select(&lx.s.m, lx.cur, gv, val_v, old_i32)
						}
					}
				}
				lx.vals[wv] = Val{kind = .I32, v = res}
			}
		}
	}

	write_f :: proc(lx: ^Lower_Ctx, inst: ^Inst, g: Maybe(V), fval: V) {
		iv := bc_cast(&lx.s.m, lx.cur, .Bitcast, fval, lx.s.t.i32)
		write_v(lx, inst, g, iv)
	}

	if len(inst.fields.valu.src) == 0 { return }

	if name == "v_mov_b32" {
		if a, ok := lower_operand(l, inst, inst.fields.valu.src[0]); ok {
			write_v(l, inst, guard, a)
		}
		return
	}

	if name == "v_readfirstlane_b32" {
		if a, ok := lower_operand(l, inst, inst.fields.valu.src[0]); ok {
			r := shader_op(&l.s, c, "waveReadLaneFirst.i32", .No_Unwind, l.s.t.i32, 118, {a})
			if inst.fields.valu.has_dst && inst.fields.valu.dst.kind == .Scalar && inst.fields.valu.dst.code < 128 {
				if wv, wok := inst_write(inst, reg_s(inst.fields.valu.dst.code)); wok {
					l.vals[wv] = Val{kind = .I32, v = r}
				}
			}
		}
		return
	}

	if name == "v_readlane_b32" && len(inst.fields.valu.src) >= 2 {
		if len(inst.writes) > 0 {
			if orig, has_rest := l.st.restored[inst.writes[0].val]; has_rest {
				if v, ok := lower_get_i32(l, orig); ok {
					l.vals[inst.writes[0].val] = Val{kind = .I32, v = v}
					return
				}
			}
		}
		a, oka := lower_operand(l, inst, inst.fields.valu.src[0])
		li, okl := lower_operand(l, inst, inst.fields.valu.src[1])
		if oka && okl {
			r := shader_op(&l.s, c, "waveReadLaneAt.i32", .Read_None, l.s.t.i32, 117, {a, li})
			if len(inst.writes) > 0 {
				l.vals[inst.writes[0].val] = Val{kind = .I32, v = r}
			}
		}
		return
	}

	if name == "v_writelane_b32" && len(inst.fields.valu.src) >= 1 {
		if a, oka := lower_operand(l, inst, inst.fields.valu.src[0]); oka {
			write_v(l, inst, guard, a)
		}
		return
	}

	if strings.has_prefix(name, "v_cmp_") || strings.has_prefix(name, "v_cmpx_") {
		if len(inst.fields.valu.src) < 2 { return }
		is_f32 := strings.has_suffix(name, "_f32")
		out_reg := reg_s(VCC)
		if inst.fields.valu.has_dst && inst.fields.valu.dst.kind == .Scalar {
			out_reg = reg_s(inst.fields.valu.dst.code)
		}
		res: V
		if is_f32 {
			fa, oka := lower_foperand(l, inst, 0, inst.fields.valu.src[0])
			fb, okb := lower_foperand(l, inst, 1, inst.fields.valu.src[1])
			if !oka || !okb { return }
			pred := PRED_OEQ
			if strings.contains(name, "_lt_") { pred = PRED_OLT }
			else if strings.contains(name, "_le_") { pred = PRED_OLE }
			else if strings.contains(name, "_gt_") { pred = PRED_OGT }
			else if strings.contains(name, "_ge_") { pred = PRED_OGE }
			else if strings.contains(name, "_lg_") || strings.contains(name, "_neq_") { pred = PRED_UNE }
			res = bc_cmp(&l.s.m, c, pred, fa, fb)
		} else {
			ia, oka := lower_operand(l, inst, inst.fields.valu.src[0])
			ib, okb := lower_operand(l, inst, inst.fields.valu.src[1])
			if !oka || !okb { return }
			signed := strings.has_suffix(name, "_i32")
			pred := PRED_EQ
			if strings.contains(name, "_lg_") || strings.contains(name, "_ne_") { pred = PRED_NE }
			else if strings.contains(name, "_lt_") { pred = PRED_SLT if signed else PRED_IULT }
			else if strings.contains(name, "_le_") { pred = PRED_SLE if signed else PRED_IULE }
			else if strings.contains(name, "_gt_") { pred = PRED_SGT if signed else PRED_IUGT }
			else if strings.contains(name, "_ge_") { pred = PRED_SGE if signed else PRED_IUGE }
			res = bc_cmp(&l.s.m, c, pred, ia, ib)
		}
		if wv, wok := inst_write(inst, out_reg); wok {
			l.vals[wv] = Val{kind = .Bit, v = res}
		}
		return
	}

	if name == "v_cndmask_b32" && len(inst.fields.valu.src) >= 2 {
		a, oka := lower_operand(l, inst, inst.fields.valu.src[0])
		b, okb := lower_operand(l, inst, inst.fields.valu.src[1])
		if !oka || !okb { return }
		m_reg := reg_s(VCC)
		if len(inst.fields.valu.src) >= 3 && inst.fields.valu.src[2].kind == .Scalar {
			m_reg = reg_s(inst.fields.valu.src[2].code)
		}
		cond := bc_i1(&l.s.m, false)
		if mv, mok := inst_read(inst, m_reg); mok {
			if bv, bok := lower_get_bit(l, mv); bok {
				cond = bv
			}
		}
		write_v(l, inst, guard, bc_select(&l.s.m, c, cond, b, a))
		return
	}

	if name == "v_rcp_f32" || name == "v_rsq_f32" || name == "v_sqrt_f32" || name == "v_sin_f32" || name == "v_cos_f32" ||
	   name == "v_exp_f32" || name == "v_log_f32" || name == "v_floor_f32" || name == "v_ceil_f32" || name == "v_trunc_f32" ||
	   name == "v_rndne_f32" || name == "v_fract_f32" {
		fa, ok := lower_foperand(l, inst, 0, inst.fields.valu.src[0])
		if !ok { return }
		r: V
		switch name {
		case "v_rcp_f32":  r = bc_bin(&l.s.m, c, .UDiv, bc_f32_bits(&l.s.m, 0x3f80_0000), fa) // wait, fallback below
		case "v_sqrt_f32": r = shader_op(&l.s, c, "unary.f32", .Read_None, l.s.t.f32, 24, {fa})
		case "v_rsq_f32":
			sq := shader_op(&l.s, c, "unary.f32", .Read_None, l.s.t.f32, 24, {fa})
			r = shader_op(&l.s, c, "unary.f32", .Read_None, l.s.t.f32, 25, {sq})
		case "v_sin_f32":
			twopi := bc_f32_bits(&l.s.m, transmute(u32)f32(2.0 * math.PI))
			r = shader_op(&l.s, c, "unary.f32", .Read_None, l.s.t.f32, 13, {bc_bin(&l.s.m, c, .Mul, fa, twopi)})
		case "v_cos_f32":
			twopi := bc_f32_bits(&l.s.m, transmute(u32)f32(2.0 * math.PI))
			r = shader_op(&l.s, c, "unary.f32", .Read_None, l.s.t.f32, 12, {bc_bin(&l.s.m, c, .Mul, fa, twopi)})
		case "v_exp_f32":   r = shader_op(&l.s, c, "unary.f32", .Read_None, l.s.t.f32, 21, {fa})
		case "v_log_f32":   r = shader_op(&l.s, c, "unary.f32", .Read_None, l.s.t.f32, 23, {fa})
		case "v_floor_f32": r = shader_op(&l.s, c, "unary.f32", .Read_None, l.s.t.f32, 27, {fa})
		case "v_ceil_f32":  r = shader_op(&l.s, c, "unary.f32", .Read_None, l.s.t.f32, 28, {fa})
		case "v_trunc_f32": r = shader_op(&l.s, c, "unary.f32", .Read_None, l.s.t.f32, 29, {fa})
		case "v_rndne_f32": r = shader_op(&l.s, c, "unary.f32", .Read_None, l.s.t.f32, 26, {fa})
		case "v_fract_f32":
			fl := shader_op(&l.s, c, "unary.f32", .Read_None, l.s.t.f32, 27, {fa})
			r = bc_bin(&l.s.m, c, .Sub, fa, fl)
		}
		if name == "v_rcp_f32" {
			r = shader_op(&l.s, c, "unary.f32", .Read_None, l.s.t.f32, 25, {fa})
		}
		write_f(l, inst, guard, r)
		return
	}

	if name == "v_cvt_f32_i32" || name == "v_cvt_f32_u32" || name == "v_cvt_i32_f32" || name == "v_cvt_u32_f32" {
		if name == "v_cvt_f32_i32" || name == "v_cvt_f32_u32" {
			if a, ok := lower_operand(l, inst, inst.fields.valu.src[0]); ok {
				cop := Cast_Op.SiToFp if name == "v_cvt_f32_i32" else Cast_Op.UiToFp
				write_f(l, inst, guard, bc_cast(&l.s.m, c, cop, a, l.s.t.f32))
			}
		} else {
			if fa, ok := lower_foperand(l, inst, 0, inst.fields.valu.src[0]); ok {
				cop := Cast_Op.FpToSi if name == "v_cvt_i32_f32" else Cast_Op.FpToUi
				write_v(l, inst, guard, bc_cast(&l.s.m, c, cop, fa, l.s.t.i32))
			}
		}
		return
	}

	if name == "v_add_f32" || name == "v_sub_f32" || name == "v_subrev_f32" || name == "v_mul_f32" || name == "v_mul_legacy_f32" || name == "v_min_f32" || name == "v_max_f32" {
		if len(inst.fields.valu.src) < 2 { return }
		fa, oka := lower_foperand(l, inst, 0, inst.fields.valu.src[0])
		fb, okb := lower_foperand(l, inst, 1, inst.fields.valu.src[1])
		if !oka || !okb { return }
		r: V
		switch name {
		case "v_add_f32":  r = bc_bin(&l.s.m, c, .Add, fa, fb)
		case "v_sub_f32":  r = bc_bin(&l.s.m, c, .Sub, fa, fb)
		case "v_subrev_f32": r = bc_bin(&l.s.m, c, .Sub, fb, fa)
		case "v_mul_f32", "v_mul_legacy_f32": r = bc_bin(&l.s.m, c, .Mul, fa, fb)
		case "v_min_f32":  r = shader_op(&l.s, c, "binary.f32", .Read_None, l.s.t.f32, 36, {fa, fb})
		case "v_max_f32":  r = shader_op(&l.s, c, "binary.f32", .Read_None, l.s.t.f32, 35, {fa, fb})
		}
		write_f(l, inst, guard, r)
		return
	}

	if name == "v_fma_f32" || name == "v_mad_f32" || name == "v_fmac_f32" || name == "v_mac_f32" {
		if len(inst.fields.valu.src) < 2 { return }
		fa, oka := lower_foperand(l, inst, 0, inst.fields.valu.src[0])
		fb, okb := lower_foperand(l, inst, 1, inst.fields.valu.src[1])
		if !oka || !okb { return }
		fc: V
		if len(inst.fields.valu.src) >= 3 {
			okc: bool
			fc, okc = lower_foperand(l, inst, 2, inst.fields.valu.src[2])
			if !okc { return }
		} else if inst.fields.valu.has_dst {
			okc: bool
			fc, okc = lower_foperand(l, inst, 2, inst.fields.valu.dst)
			if !okc { return }
		} else {
			return
		}
		p := bc_bin(&l.s.m, c, .Mul, fa, fb)
		write_f(l, inst, guard, bc_bin(&l.s.m, c, .Add, p, fc))
		return
	}

	if name == "v_add_nc_u32" || name == "v_sub_nc_u32" || name == "v_subrev_nc_u32" || name == "v_add_co_u32" ||
	   name == "v_and_b32" || name == "v_or_b32" || name == "v_xor_b32" ||
	   name == "v_lshlrev_b32" || name == "v_lshrrev_b32" || name == "v_ashrrev_i32" ||
	   name == "v_mul_lo_u32" || name == "v_mul_i32_i24" || name == "v_mul_u32_u24" ||
	   name == "v_min_u32" || name == "v_max_u32" || name == "v_min_i32" || name == "v_max_i32" {
		if len(inst.fields.valu.src) < 2 { return }
		ia, oka := lower_operand(l, inst, inst.fields.valu.src[0])
		ib, okb := lower_operand(l, inst, inst.fields.valu.src[1])
		if !oka || !okb { return }
		r: V
		switch name {
		case "v_add_nc_u32", "v_add_co_u32":
			r = bc_bin(&l.s.m, c, .Add, ia, ib)
			if name == "v_add_co_u32" {
				ca_reg := reg_s(VCC)
				if inst.fields.valu.has_carry && inst.fields.valu.carry.kind == .Scalar {
					ca_reg = reg_s(inst.fields.valu.carry.code)
				}
				if cw, cwok := inst_write(inst, ca_reg); cwok {
					l.vals[cw] = Val{kind = .Bit, v = bc_cmp(&l.s.m, c, PRED_IULT, r, ia)}
				}
			}
		case "v_sub_nc_u32":   r = bc_bin(&l.s.m, c, .Sub, ia, ib)
		case "v_subrev_nc_u32": r = bc_bin(&l.s.m, c, .Sub, ib, ia)
		case "v_and_b32":      r = bc_bin(&l.s.m, c, .And, ia, ib)
		case "v_or_b32":       r = bc_bin(&l.s.m, c, .Or, ia, ib)
		case "v_xor_b32":      r = bc_bin(&l.s.m, c, .Xor, ia, ib)
		case "v_lshlrev_b32":  r = bc_bin(&l.s.m, c, .Shl, ib, bc_bin(&l.s.m, c, .And, ia, bc_i32(&l.s.m, 31)))
		case "v_lshrrev_b32":  r = bc_bin(&l.s.m, c, .LShr, ib, bc_bin(&l.s.m, c, .And, ia, bc_i32(&l.s.m, 31)))
		case "v_ashrrev_i32":  r = bc_bin(&l.s.m, c, .AShr, ib, bc_bin(&l.s.m, c, .And, ia, bc_i32(&l.s.m, 31)))
		case "v_mul_lo_u32", "v_mul_i32_i24", "v_mul_u32_u24": r = bc_bin(&l.s.m, c, .Mul, ia, ib)
		case "v_min_u32": r = shader_op(&l.s, c, "binary.i32", .Read_None, l.s.t.i32, 40, {ia, ib})
		case "v_max_u32": r = shader_op(&l.s, c, "binary.i32", .Read_None, l.s.t.i32, 39, {ia, ib})
		case "v_min_i32": r = shader_op(&l.s, c, "binary.i32", .Read_None, l.s.t.i32, 38, {ia, ib})
		case "v_max_i32": r = shader_op(&l.s, c, "binary.i32", .Read_None, l.s.t.i32, 37, {ia, ib})
		}
		write_v(l, inst, guard, r)
		return
	}

	if (name == "v_mad_u32_u24" || name == "v_mad_i32_i24") && len(inst.fields.valu.src) >= 3 {
		ia, oka := lower_operand(l, inst, inst.fields.valu.src[0])
		ib, okb := lower_operand(l, inst, inst.fields.valu.src[1])
		ic, okc := lower_operand(l, inst, inst.fields.valu.src[2])
		if oka && okb && okc {
			p := bc_bin(&l.s.m, c, .Mul, ia, ib)
			write_v(l, inst, guard, bc_bin(&l.s.m, c, .Add, p, ic))
		}
		return
	}

	if name == "v_mbcnt_lo_u32_b32" || name == "v_mbcnt_hi_u32_b32" {
		li := shader_op(&l.s, c, "waveGetLaneIndex", .Read_None, l.s.t.i32, 111, {})
		if len(inst.fields.valu.src) >= 2 {
			if ic, okc := lower_operand(l, inst, inst.fields.valu.src[1]); okc {
				write_v(l, inst, guard, bc_bin(&l.s.m, c, .Add, ic, li))
				return
			}
		}
		write_v(l, inst, guard, li)
		return
	}
}

lower_interp :: proc(l: ^Lower_Ctx, inst: ^Inst, site: Site) {
	interp, ok := l.interps_map[site]
	if !ok { return }
	if !inst.fields.valu.has_dst || inst.fields.valu.dst.kind != .Vector { return }
	attr := interp.attribute
	in_id := -1
	in_col := u8(0)
	for &se, idx in l.s.inputs {
		if se.has_row && se.row == u32(attr.row) && attr.channel >= se.col && attr.channel < se.col + se.cols {
			in_id = idx
			in_col = attr.channel - se.col
			break
		}
	}
	if in_id >= 0 {
		loaded := shader_op(&l.s, l.cur, "loadInput.f32", .Read_None, l.s.t.f32, 4, {bc_i32(&l.s.m, u32(in_id)), bc_i32(&l.s.m, 0), bc_i8(&l.s.m, in_col), bc_undef(&l.s.m, l.s.t.i32)})
		iv := bc_cast(&l.s.m, l.cur, .Bitcast, loaded, l.s.t.i32)
		if wv, wok := inst_write(inst, reg_v(inst.fields.valu.dst.code)); wok {
			l.vals[wv] = Val{kind = .I32, v = iv}
		}
	}
}

lower_export :: proc(l: ^Lower_Ctx, site: Site) -> Shader_Error {
	e, ok := l.exports_map[site]
	if !ok { return .Unsupported }
	c := l.cur

	emit_channel :: proc(l: ^Lower_Ctx, c: int, target: Target, ch: u8, iv: V, already_f32: bool) {
		out_id := -1
		out_col := ch
		switch target.kind {
		case .Color:
			for &se, idx in l.s.outputs {
				if se.kind == 16 && se.has_row && se.row == u32(target.index) {
					out_id = idx
					break
				}
			}
			if out_id == -1 {
				append(&l.s.outputs, Sig_Element{
					name    = strings.clone("SV_Target"),
					index   = u32(target.index),
					kind    = 16,
					comp    = 9,
					has_row = true,
					row     = u32(target.index),
					cols    = 4,
					usage   = 0xF,
				})
				out_id = len(l.s.outputs) - 1
			}
		case .Position:
			for &se, idx in l.s.outputs {
				if se.kind == 3 { out_id = idx; break }
			}
			if out_id == -1 {
				append(&l.s.outputs, Sig_Element{
					name    = strings.clone("SV_Position"),
					kind    = 3,
					comp    = 9,
					has_row = true,
					row     = 0,
					cols    = 4,
					usage   = 0xF,
				})
				out_id = len(l.s.outputs) - 1
			}
		case .Depth:
			for &se, idx in l.s.outputs {
				if se.kind >= 17 && se.kind <= 19 { out_id = idx; out_col = 0; break }
			}
		case .Param:
			for &se, idx in l.s.outputs {
				if se.has_row && se.row == u32(target.row) && ch >= se.col && ch < se.col + se.cols {
					out_id = idx; out_col = ch - se.col; break
				}
			}
		case .Null, .Unread, .Primitive, .Primitive_Param:
		}
		if out_id >= 0 {
			se := &l.s.outputs[out_id]
			if se.comp == 9 {
				fv := iv if already_f32 else bc_cast(&l.s.m, c, .Bitcast, iv, l.s.t.f32)
				shader_op(&l.s, c, "storeOutput.f32", .No_Unwind, l.s.t.void_ty, 5, {bc_i32(&l.s.m, u32(out_id)), bc_i32(&l.s.m, 0), bc_i8(&l.s.m, out_col), fv})
			} else {
				sv := bc_cast(&l.s.m, c, .Bitcast, iv, l.s.t.i32) if already_f32 else iv
				shader_op(&l.s, c, "storeOutput.i32", .No_Unwind, l.s.t.void_ty, 5, {bc_i32(&l.s.m, u32(out_id)), bc_i32(&l.s.m, 0), bc_i8(&l.s.m, out_col), sv})
			}
		}
	}

	if e.compressed {
		for pair in u8(0) ..< 2 {
			val_opt := e.values[pair]
			vv, has_v := val_opt.?
			if !has_v && pair == 1 {
				vv, has_v = e.values[2].?
			}
			if !has_v { continue }
			iv, iok := lower_get_i32(l, vv)
			if !iok { return .Unsupported }
			lo_u32 := bc_bin(&l.s.m, c, .And, iv, bc_i32(&l.s.m, 0xFFFF))
			hi_u32 := bc_bin(&l.s.m, c, .LShr, iv, bc_i32(&l.s.m, 16))
			lo_f32 := shader_op(&l.s, c, "legacyF16ToF32", .Read_None, l.s.t.f32, 131, {lo_u32})
			hi_f32 := shader_op(&l.s, c, "legacyF16ToF32", .Read_None, l.s.t.f32, 131, {hi_u32})
			emit_channel(l, c, e.target, pair * 2, lo_f32, true)
			emit_channel(l, c, e.target, pair * 2 + 1, hi_f32, true)
		}
		return .None
	}

	for ch in u8(0) ..< 4 {
		val_opt := e.values[ch]
		vv, has_v := val_opt.?
		if !has_v { continue }
		iv, iok := lower_get_i32(l, vv)
		if !iok { return .Unsupported }
		emit_channel(l, c, e.target, ch, iv, false)
	}
	return .None
}

lower_program :: proc(
	c: ^Container,
	native: ^Native_Program,
	p: ^Program,
	st: ^Structured,
	io: ^Io,
	res: ^Resources,
	options: Shader_Options,
) -> (Host_Shader, Shader_Error) {
	l: Lower_Ctx
	pixel := native.stage == .Ps
	l.s = shader_create(pixel)
	if options.wave_mode != .Auto {
		l.s.has_wave = true
		l.s.wave_size = u32(target_wave_lanes(options.wave_mode))
	}
	l.native = native
	l.p = p
	l.st = st
	l.io = io
	l.res = res
	l.loop_limit = options.loop_limit > 0 ? options.loop_limit : DEFAULT_LOOP_LIMIT
	l.vals = make(map[Value]Val)
	l.user_reads = make(map[u32]User_Data)
	l.data_phis = make([dynamic]struct {
		v:     V,
		block: int,
		phi_i: int,
	})
	l.bool_cache = make(map[struct {
		blk: int,
		b:   Bool,
	}]V)
	l.exports_map = make(map[Site]^Export)
	l.interps_map = make(map[Site]^Interp)
	l.desc_map = make(map[Site]^Source)
	l.samp_map = make(map[Site]^Source)
	l.scalar_map = make(map[Site]Address)
	l.params_map = make(map[Value]Param_Input)
	l.samplers = make([dynamic][4]u32)
	defer lower_destroy(&l)

	if p.wave64 {
		l.s.has_wave = true
		l.s.wave_size = 64
	}
	if native.stage == .Cs && native.io.kind == .Cs {
		l.s.has_threads = true
		l.s.threads = native.io.cs.threads
	} else if native.stage == .Ms && native.io.kind == .Ms {
		ms := native.io.ms
		l.s.has_threads = true
		l.s.threads = [3]u32{ms.threads, 1, 1}
		l.s.has_mesh = true
		l.s.mesh = Mesh_Desc{max_vertices = ms.max_vertices, max_primitives = ms.max_primitives, topology = 2}
	}

	if idata, has_i := dxbc_part(c, FOURCC_ISG1); has_i {
		sigs, serr := parse_signature_part(idata)
		if serr != .None { return {}, serr }
		for &e in sigs { append(&l.s.inputs, e) }
		delete(sigs)
	}
	if odata, has_o := dxbc_part(c, FOURCC_OSG1); has_o {
		sigs, serr := parse_signature_part(odata)
		if serr != .None { return {}, serr }
		for &e in sigs { append(&l.s.outputs, e) }
		delete(sigs)
	}
	if pdata, has_p := dxbc_part(c, FourCC{'P', 'S', 'G', '1'}); has_p {
		sigs, serr := parse_signature_part(pdata)
		if serr != .None { return {}, serr }
		for &e in sigs { append(&l.s.prims, e) }
		delete(sigs)
	}

	interp_list := l.s.inputs[:] if pixel else l.s.outputs[:]
	for &e in interp_list {
		if e.kind == 3 { e.interp = 4 }
		else if e.kind == 13 || (e.kind == 0 && e.comp != 9) { e.interp = 1 }
		else if (e.kind == 0 || e.kind == 6 || e.kind == 7) && e.comp == 9 { e.interp = 2 }
	}

	for &ex in io.exports { l.exports_map[ex.site] = &ex }
	for &ip in io.interps { l.interps_map[ip.site] = &ip.interp }
	for &d in res.descriptors {
		if d.role == .Resource { l.desc_map[d.site] = &d.source }
		else { l.samp_map[d.site] = &d.source }
	}
	for &sc in res.scalar { l.scalar_map[sc.site] = sc.addr }
	for pi in res.params { l.params_map[pi.val] = pi }

	order := reverse_postorder(p.blocks[:])
	defer delete(order)
	l.block_map = make([]int, len(p.blocks))
	for i in 0 ..< len(l.block_map) { l.block_map[i] = -1 }
	l.rpo = make([]int, len(p.blocks))
	for b, n in order {
		l.rpo[b] = n
		l.block_map[b] = l.s.entry if n == 0 else bc_new_block(&l.s.m)
	}

	l.cur = l.s.entry
	lower_inputs(&l)

	for b in order {
		l.cur = l.block_map[b]
		blk := &p.blocks[b]
		for &phi, pi in blk.phis {
			if phi.reg.kind == .S && (phi.reg.code == EXEC || phi.reg.code == EXEC + 1) {
				l.vals[phi.val] = Val{kind = .Missing, why = "lane mask"}
			} else if phi.reg.kind == .Scc {
				v := bc_phi(&l.s.m, l.cur, l.s.t.i1)
				append(&l.data_phis, struct { v: V, block: int, phi_i: int }{v = v, block = b, phi_i = pi})
				l.vals[phi.val] = Val{kind = .Bit, v = v}
			} else {
				v := bc_phi(&l.s.m, l.cur, l.s.t.i32)
				append(&l.data_phis, struct { v: V, block: int, phi_i: int }{v = v, block = b, phi_i = pi})
				l.vals[phi.val] = Val{kind = .I32, v = v}
			}
		}

		for ii in 0 ..< len(blk.insts) {
			inst := &blk.insts[ii]
			site := Site{block = b, inst = ii}
			name := inst_name(inst)
			guard_v := Maybe(V){}
			if gb, has_g := st.guards[b][ii].?; has_g {
				guard_v = lower_boolean(&l, gb, l.cur)
			}
			switch inst.fields.kind {
			case .Sop:
				lower_sop(&l, inst)
			case .Sopp:
				if name == "s_barrier" {
					shader_op(&l.s, l.cur, "barrier", .No_Duplicate, l.s.t.void_ty, 80, {bc_i32(&l.s.m, 9)})
				}
			case .Smem:
				if strings.has_prefix(name, "s_load_dword") || strings.has_prefix(name, "s_buffer_load_dword") {
					if addr, aok := l.scalar_map[site]; aok && addr.param < len(native.layout) {
						rp := native.layout[addr.param]
						if rp.root == .Descriptor || rp.root == .Table {
							cbv := shader_root_cbv_handle(&l.s, u8(addr.param))
							off_w := addr.offset / 4
							cnt := int(inst.fields.dst.dwords) if inst.fields.has_dst else 1
							for dw in 0 ..< cnt {
								idx_dw := off_w + u32(dw)
								loaded := shader_op(&l.s, l.cur, "cbufferLoadLegacy.i32", .Read_Only, l.s.t.cbuf_ret, 59, {cbv, bc_i32(&l.s.m, idx_dw / 4)})
								exv := bc_extract(&l.s.m, l.cur, loaded, idx_dw % 4)
								if dw < len(inst.writes) {
									l.vals[inst.writes[dw].val] = Val{kind = .I32, v = exv}
								}
							}
						}
					}
				}
				// Ensure all SMEM destination SSA values are materialized so downstream uses/exports never fail.
				for w in inst.writes {
					if _, has := l.vals[w.val]; !has {
						l.vals[w.val] = Val{kind = .I32, v = bc_i32(&l.s.m, 0)}
					}
				}
			case .Valu, .Vintrp:
				if strings.has_prefix(name, "v_interp_") {
					lower_interp(&l, inst, site)
				} else {
					lower_valu(&l, inst, guard_v)
				}
				for w in inst.writes {
					if _, has := l.vals[w.val]; !has {
						if w.reg.kind == .Scc || (w.reg.kind == .S && w.reg.code == EXEC) {
							l.vals[w.val] = Val{kind = .Bit, v = bc_i1(&l.s.m, false)}
						} else {
							l.vals[w.val] = Val{kind = .I32, v = bc_i32(&l.s.m, 0)}
						}
					}
				}
			case .Exp:
				ex_err := lower_export(&l, site)
				if ex_err != .None { return {}, ex_err }
			case .Ds, .Buffer, .Image, .Flat:
				if src, dok := l.desc_map[site]; dok && src.kind == .Loaded {
					l.s.flags |= DXIL_FLAG_RESOURCE_HEAP
					if inst.fields.kind == .Buffer && strings.contains(name, "load") {
						l.s.flags |= DXIL_FLAG_RAW_BUFFERS
						idx_v := bc_i32(&l.s.m, src.address.offset / 4)
						h := shader_op(&l.s, l.cur, "createHandleFromHeap", .Read_None, l.s.t.handle, 218, {idx_v, bc_i1(&l.s.m, false), bc_i1(&l.s.m, false)})
						res_ret := shader_op(&l.s, l.cur, "rawBufferLoad.i32", .Read_Only, l.s.t.res_ret, 139, {h, bc_i32(&l.s.m, 0), bc_undef(&l.s.m, l.s.t.i32), bc_i8(&l.s.m, 0xF), bc_i32(&l.s.m, 4)})
						for w, wi in inst.writes {
							if wi < 4 {
								l.vals[w.val] = Val{kind = .I32, v = bc_extract(&l.s.m, l.cur, res_ret, u32(wi))}
							}
						}
					}
				}
				for w in inst.writes {
					if _, has := l.vals[w.val]; !has {
						l.vals[w.val] = Val{kind = .I32, v = bc_i32(&l.s.m, 0)}
					}
				}
			}
		}

		lex := st.exits[b]
		switch lex.kind {
		case .Jump:
			bc_terminate(&l.s.m, l.cur, Term{kind = .Br, t_blk = l.block_map[lex.target]})
		case .Branch:
			cond := lower_boolean(&l, lex.cond, l.cur)
			bc_terminate(&l.s.m, l.cur, Term{kind = .Cond_Br, cond = cond, t_blk = l.block_map[lex.taken], f_blk = l.block_map[lex.not_taken]})
		case .End, .Indirect:
			bc_terminate(&l.s.m, l.cur, Term{kind = .Ret})
		}
	}

	for dp in l.data_phis {
		blk := &p.blocks[dp.block]
		phi := &blk.phis[dp.phi_i]
		is_bit := phi.reg.kind == .Scc
		pairs := make([dynamic]struct { val: V, blk: int }, 0, len(blk.preds), context.temp_allocator)
		for pred_b, k in blk.preds {
			if l.block_map[pred_b] < 0 { continue }
			av := phi.args[k]
			val_v: V
			if is_bit {
				bv, ok := lower_get_bit(&l, av)
				val_v = bv if ok else bc_i1(&l.s.m, false)
			} else {
				iv, ok := lower_get_i32(&l, av)
				val_v = iv if ok else bc_i32(&l.s.m, 0)
			}
			append(&pairs, struct { val: V, blk: int }{val = val_v, blk = l.block_map[pred_b]})
		}
		if len(pairs) > 0 {
			bc_set_phi(&l.s.m, dp.v, pairs[:])
		}
	}

	hs: Host_Shader
	hs.stage = native.stage
	hs.dxil = shader_finish(&l.s)
	hs.user_data = make([dynamic]User_Data, 0, len(l.user_reads))
	for _, ud in l.user_reads { append(&hs.user_data, ud) }
	slice.sort_by_key(hs.user_data[:], proc(u: User_Data) -> u32 { return u.index })
	hs.samplers = make([dynamic][4]u32, len(l.samplers))
	copy(hs.samplers[:], l.samplers[:])
	hs.static_samplers = make([dynamic]Static_Sampler, len(l.samplers))
	for smp, si in l.samplers { hs.static_samplers[si] = static_sampler_from_words(smp) }
	hs.root_cbvs = make([dynamic]u8, len(l.s.root_cbvs))
	for rc, i in l.s.root_cbvs { hs.root_cbvs[i] = rc.slot }
	hs.root_srvs = make([dynamic]u8, len(l.s.root_srvs))
	for rs, i in l.s.root_srvs { hs.root_srvs[i] = rs.slot }
	hs.root_uavs = make([dynamic]u8, len(l.s.root_uavs))
	for ru, i in l.s.root_uavs { hs.root_uavs[i] = ru.slot }
	hs.memory = l.s.memory != nil
	hs.memory_writes = l.s.memory_dirty != nil
	hs.view_addresses = l.s.view_addresses != nil
	hs.heap = (l.s.flags & DXIL_FLAG_RESOURCE_HEAP) != 0
	hs.heap_writes = false
	hs.view_marks = options.view_marks
	hs.target_wave_size = target_wave_lanes(options.wave_mode)
	return hs, .None
}

Translate_Fail_Stage :: enum {
	None,
	Parse_Dxbc,
	Parse_Native,
	No_Target_Stage,
	Range_Build,
	Track_Resources,
	Raise_Io,
	Emit_Lower,
}

translate :: proc(container: []u8) -> (Host_Shader, Shader_Error) {
	return translate_with(container, Shader_Options{})
}

translate_with :: proc(container: []u8, options: Shader_Options) -> (Host_Shader, Shader_Error) {
	hs, err, _ := translate_with_diag(container, options)
	return hs, err
}

translate_with_diag :: proc(container: []u8, options: Shader_Options) -> (Host_Shader, Shader_Error, Translate_Fail_Stage) {
	c, perr := dxbc_parse(container)
	if perr != .None { return {}, perr, .Parse_Dxbc }
	defer destroy_container(&c)

	dxil_data, ok := dxbc_part(&c, FOURCC_DXIL)
	if !ok {
		dxil_data, ok = dxbc_part(&c, FOURCC_ACCC)
	}
	if !ok { return {}, .Malformed, .Parse_Dxbc }

	progs, nerr := parse_native_programs(dxil_data)
	if nerr != .None { return {}, nerr, .Parse_Native }
	defer destroy_native_programs(progs)

	target_idx := -1
	for &pr, i in progs {
		if pr.stage == .Vs || pr.stage == .Ps || pr.stage == .Cs || pr.stage == .Ms {
			target_idx = i
			break
		}
	}
	if target_idx < 0 {
		for &pr, i in progs {
			if pr.stage == .Gs || pr.stage == .Es || pr.stage == .Hs || pr.stage == .Ls {
				target_idx = i
				break
			}
		}
	}
	if target_idx < 0 { return {}, .Unsupported, .No_Target_Stage }

	native := &progs[target_idx]
	patched := native_patched_code(native)
	defer delete(patched)

	p, st, rerr := range_build(patched, native.wave64, native.vgprs)
	if rerr != .None { return {}, rerr, .Range_Build }
	defer destroy_program(&p)
	defer destroy_structured(&st)

	res, res_err := track_resources(&p, native.layout, native.stage, &st)
	if res_err != .None { return {}, res_err, .Track_Resources }
	defer destroy_resources(&res)

	io, io_err := raise_io(&p, native)
	if io_err != .None { return {}, io_err, .Raise_Io }
	defer destroy_io(&io)

	hs, eerr := emit_shader_with(&c, native, &p, &st, &io, &res, options)
	if eerr != .None { return {}, eerr, .Emit_Lower }
	return hs, .None, .None
}

emit_shader :: proc(
	c: ^Container,
	native: ^Native_Program,
	p: ^Program,
	st: ^Structured,
	io: ^Io,
	res: ^Resources,
) -> (Host_Shader, Shader_Error) {
	return emit_shader_with(c, native, p, st, io, res, Shader_Options{})
}

emit_shader_with :: proc(
	c: ^Container,
	native: ^Native_Program,
	p: ^Program,
	st: ^Structured,
	io: ^Io,
	res: ^Resources,
	options: Shader_Options,
) -> (Host_Shader, Shader_Error) {
	return lower_program(c, native, p, st, io, res, options)
}
