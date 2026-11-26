package vasperty_hle

import "base:intrinsics"
import "core:math"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import win32 "core:sys/windows"
import vasperty_formats "vasperty:formats"

// xg, audio (acphal), dsp (chad), apu (xapu), gameinput, media (mfplat), d3d12x, fidelityfx.

// =============================================================================
// 1. xg (xg_xs.dll texture layout computer via vasperty:formats)
// =============================================================================

XG_Resource_Desc :: struct {
	dimension:      u32,
	alignment:      u64,
	width:          u64,
	height:         u32,
	depth_or_array: u16,
	mips:           u16,
	format:         u32,
	samples:        u32,
	quality:        u32,
	layout:         u32,
	flags:          u32,
}

XG_Mip_Out :: struct {
	size:           u64,
	offset:         u64,
	slice_size:     u64,
	pitch_texels:   u32,
	pitch_bytes:    u32,
	alignment:      u32,
	padded:         [3]u32,
	elements:       [2]u32,
	texels:         [2]u32,
	depth_or_array: u32,
	samples:        u32,
	swizzle:        u32,
	bank_rotation:  [2]u64,
	slice_depth:    u32,
	in_tail:        u32,
	tail_position:  u32,
}

XG_Plane_Out :: struct {
	usage:         u32,
	size:          u64,
	slice_size:    u64,
	offset:        u64,
	alignment:     u64,
	element_bytes: u32,
	standard_mips: u32,
	tail_mips:     u32,
	mips:          [15]XG_Mip_Out,
}

XG_Layout_Out :: struct {
	size:      u64,
	alignment: u64,
	mips:      u32,
	planes:    u32,
	plane:     [4]XG_Plane_Out,
	dimension: u32,
}

XG_Packed_Mips :: struct {
	standard: u8,
	packed:   u8,
	tiles:    u32,
	start:    u32,
}

XG_Subresource_Tiling :: struct {
	width:  u32,
	height: u16,
	depth:  u16,
	start:  u32,
}

XG_Computer :: struct {
	vtable: rawptr,
	refs:   u32,
	desc:   XG_Resource_Desc,
	mips:   u32,
	layout: vasperty_formats.Layout,
}

@(private) xg_suggested_swizzle :: proc(desc: ^XG_Resource_Desc) -> u32 {
	if desc.dimension == 2 { return vasperty_formats.SWIZZLE_LINEAR }
	if desc.flags & 2 != 0 { return vasperty_formats.SWIZZLE_64KB_Z_X }
	if desc.flags & 1 != 0 { return vasperty_formats.SWIZZLE_64KB_R_X }
	return vasperty_formats.SWIZZLE_4KB_S
}

XGSuggestSwizzleMode :: proc "system" (desc: ^XG_Resource_Desc, _flags: u32, out: ^u32) -> HRESULT {
	context = hle_context()
	if desc == nil || out == nil { return E_INVALIDARG }
	out^ = 0x100 | xg_suggested_swizzle(desc)
	return S_OK
}

@(private) xg_add_ref :: proc "system" (c: ^XG_Computer) -> u32 { context = hle_context(); return intrinsics.atomic_add(&c.refs, 1) + 1 }
@(private) xg_release :: proc "system" (c: ^XG_Computer) -> u32 {
	context = hle_context()
	left := intrinsics.atomic_sub(&c.refs, 1) - 1
	if left == 0 {
		vasperty_formats.destroy_layout(&c.layout)
		free(c)
	}
	return left
}
@(private) xg_get_layout :: proc "system" (c: ^XG_Computer, out: ^XG_Layout_Out) -> HRESULT {
	context = hle_context()
	if c == nil || out == nil { return E_INVALIDARG }
	l := &c.layout
	out^ = XG_Layout_Out{
		size      = l.size,
		alignment = l.alignment,
		mips      = c.mips,
		planes    = 1,
		dimension = c.desc.dimension,
	}
	po := &out.plane[0]
	po^ = XG_Plane_Out{
		usage         = 1,
		size          = l.size,
		slice_size    = l.slice_size,
		offset        = 0,
		alignment     = l.alignment,
		element_bytes = l.desc.element_bytes,
		standard_mips = l.first_tail_mip,
		tail_mips     = c.mips - l.first_tail_mip,
	}
	for m, mi in l.mips {
		if mi >= 15 { break }
		bpe := u64(l.desc.element_bytes)
		sl_sz := u64(m.pitch) * u64(m.rows) * bpe
		po.mips[mi] = XG_Mip_Out{
			size           = sl_sz * u64(m.depth),
			offset         = m.offset,
			slice_size     = sl_sz,
			pitch_texels   = m.pitch * l.desc.block,
			pitch_bytes    = m.pitch * l.desc.element_bytes,
			alignment      = u32(l.alignment),
			padded         = {m.pitch, m.rows, m.depth_pitch if c.desc.dimension == 4 else u32(max(c.desc.depth_or_array, 1))},
			elements       = {m.width, m.height},
			texels         = {max(u32(c.desc.width >> uint(mi)), 1), max(c.desc.height >> uint(mi), 1)},
			depth_or_array = m.depth if c.desc.dimension == 4 else u32(max(c.desc.depth_or_array, 1)),
			samples        = l.desc.samples,
			swizzle        = l.desc.swizzle,
			slice_depth    = l.block[2],
			in_tail        = 1 if u32(mi) >= l.first_tail_mip else 0,
		}
	}
	return S_OK
}
@(private) xg_copy_args :: proc(c: ^XG_Computer, plane, sub, row, depth: u32) -> (^vasperty_formats.Layout, u32, u32, uint, uint, bool) {
	if c == nil || plane != 0 || c.mips == 0 {
		return nil, 0, 0, 0, 0, false
	}
	l := &c.layout
	mip := sub % c.mips
	sl := sub / c.mips
	if int(mip) >= len(l.mips) { return nil, 0, 0, 0, 0, false }
	m := l.mips[mip]
	req_lin := uint(depth) * uint(m.depth - 1) + uint(row) * uint(m.rows - 1) + uint(m.width) * uint(l.desc.element_bytes)
	if uint(row) < uint(m.pitch) * uint(l.desc.element_bytes) { return nil, 0, 0, 0, 0, false }
	return l, mip, sl, uint(l.size), req_lin, true
}
@(private) xg_copy_into :: proc "system" (c: ^XG_Computer, tiled: [^]u8, plane, sub: u32, linear: [^]u8, row, depth: u32) -> HRESULT {
	context = hle_context()
	if tiled == nil || linear == nil { return E_INVALIDARG }
	l, mip, sl, tsz, lsz, ok := xg_copy_args(c, plane, sub, row, depth)
	if !ok { return E_INVALIDARG }
	err := vasperty_formats.layout_tile(l, mem.byte_slice(tiled, int(tsz)), mip, sl, mem.byte_slice(linear, int(lsz)), int(row), int(depth))
	return S_OK if err == .None else E_FAIL
}
@(private) xg_copy_from :: proc "system" (c: ^XG_Computer, linear: [^]u8, plane, sub: u32, tiled: [^]u8, row, depth: u32) -> HRESULT {
	context = hle_context()
	if tiled == nil || linear == nil { return E_INVALIDARG }
	l, mip, sl, tsz, lsz, ok := xg_copy_args(c, plane, sub, row, depth)
	if !ok { return E_INVALIDARG }
	err := vasperty_formats.layout_detile(l, mem.byte_slice(tiled, int(tsz)), mip, sl, mem.byte_slice(linear, int(lsz)), int(row), int(depth))
	return S_OK if err == .None else E_FAIL
}
@(private) xg_tiling :: proc "system" (c: ^XG_Computer, tiles: ^u32, packed: ^XG_Packed_Mips, shape: ^[3]u32, cnt: ^u32, first: u32, out: [^]XG_Subresource_Tiling) -> HRESULT {
	context = hle_context()
	if c == nil { return E_INVALIDARG }
	TILE :: u64(64) << 10
	l := &c.layout
	if l.alignment != TILE { return E_FAIL }
	if l.thick { return E_NOTIMPL }
	if tiles != nil { tiles^ = u32(l.size / TILE) }
	if packed != nil {
		tail_tiles := l.slice_size / TILE if l.first_tail_mip == 0 else (l.mips[l.first_tail_mip - 1].offset / TILE if l.first_tail_mip < c.mips else 0)
		packed^ = XG_Packed_Mips{standard = u8(l.first_tail_mip), packed = u8(c.mips - l.first_tail_mip), tiles = u32(tail_tiles)}
	}
	if shape != nil { shape^ = {l.block[0] * l.desc.block, l.block[1] * l.desc.block, l.block[2]} }
	if cnt != nil {
		if out == nil { cnt^ = 0; return S_OK }
		slices := min(l.slices, 2) if l.first_tail_mip < c.mips else l.slices
		avail := l.first_tail_mip * slices
		wanted := min(avail - first, cnt^) if first < avail else 0
		for i in 0 ..< wanted {
			idx := first + i
			sl := idx / max(l.first_tail_mip, 1)
			mip := idx % max(l.first_tail_mip, 1)
			if l.first_tail_mip < c.mips && sl > 0 {
				out[i] = {}
			} else {
				m := l.mips[mip]
				out[i] = XG_Subresource_Tiling{width = m.width / max(l.block[0], 1), height = u16(m.height / max(l.block[1], 1)), depth = u16(m.depth / max(l.block[2], 1)), start = u32(m.offset / TILE)}
			}
		}
		cnt^ = wanted
	}
	return S_OK
}
@(private) xg_miss :: proc "system" (_: ^XG_Computer) -> HRESULT { context = hle_context(); return E_NOTIMPL }

XG_COMPUTER_VTABLE := [12]rawptr{
	rawptr(xg_miss), rawptr(xg_add_ref), rawptr(xg_release),
	rawptr(xg_get_layout), rawptr(xg_miss), rawptr(xg_miss), rawptr(xg_miss), rawptr(xg_miss),
	rawptr(xg_copy_into), rawptr(xg_copy_from), rawptr(xg_tiling), rawptr(xg_miss),
}

XGCreateTextureComputer :: proc "system" (desc: ^XG_Resource_Desc, out: ^^XG_Computer) -> HRESULT {
	context = hle_context()
	if desc == nil || out == nil { return E_INVALIDARG }
	dim: vasperty_formats.Dimension
	switch desc.dimension {
	case 2: dim = .Tex1d
	case 3: dim = .Tex2d
	case 4: dim = .Tex3d
	case: return E_INVALIDARG
	}
	sw: u32 = 0
	switch desc.layout {
	case 0: sw = xg_suggested_swizzle(desc)
	case 1: sw = vasperty_formats.SWIZZLE_LINEAR
	case:
		if desc.layout & ~u32(0xFF) != 0x100 { return E_INVALIDARG }
		sw = desc.layout & 0xFF
	}
	fmt_info := vasperty_formats.dxgi_format_info(desc.format)
	if !fmt_info.valid { return E_INVALIDARG }
	lay, err := vasperty_formats.new_layout(vasperty_formats.Desc{
		dimension     = dim,
		width         = u32(desc.width),
		height        = desc.height,
		depth         = max(u32(desc.depth_or_array), 1),
		mips          = max(u32(desc.mips), 1),
		element_bytes = fmt_info.bytes,
		block         = fmt_info.block,
		samples       = max(desc.samples, 1),
		swizzle       = sw,
	})
	if err != .None || len(lay.mips) > 15 {
		vasperty_formats.destroy_layout(&lay)
		return E_INVALIDARG
	}
	c := new(XG_Computer)
	c^ = XG_Computer{vtable = raw_data(XG_COMPUTER_VTABLE[:]), refs = 1, desc = desc^, mips = u32(len(lay.mips)), layout = lay}
	out^ = c
	return S_OK
}

XG_DLLS := [?]string{"xg_xs.dll"}
XG_EXPORTS := [?]Hle_Export{
	{name = "XGCreateTextureComputer", address = uintptr(rawptr(XGCreateTextureComputer))},
	{name = "XGSuggestSwizzleMode", address = uintptr(rawptr(XGSuggestSwizzleMode))},
}

// =============================================================================
// 2. audio (acphal.dll + XMA decode)
// =============================================================================

APU_BLOCK :: struct {
	ptr:  rawptr,
	apu:  u32,
	size: uint,
}

@(private)
audio_state: struct {
	mu:       sync.Mutex,
	heap_on:  bool,
	next_apu: u32,
	blocks:   [dynamic]APU_BLOCK,
}

fini_audio :: proc() {
	sync.mutex_lock(&audio_state.mu)
	defer sync.mutex_unlock(&audio_state.mu)
	for b in audio_state.blocks {
		_ = win32.VirtualFree(b.ptr, 0, win32.MEM_RELEASE)
	}
	delete(audio_state.blocks)
	audio_state.blocks = nil
	audio_state.heap_on = false
}

ApuCreateHeap :: proc "system" (_cached, _non_cached: u32) -> HRESULT {
	context = hle_context()
	sync.mutex_lock(&audio_state.mu)
	defer sync.mutex_unlock(&audio_state.mu)
	if !audio_state.heap_on {
		audio_state.heap_on = true
		audio_state.next_apu = 0x10000
	}
	return S_OK
}

ApuAlloc :: proc "system" (out: ^rawptr, apu: ^u32, size, align: u32, _flags: u32) -> HRESULT {
	context = hle_context()
	if out == nil || size == 0 || align < 4 || (align & (align - 1)) != 0 { return E_INVALIDARG }
	_ = ApuCreateHeap(0, 0)
	p := win32.VirtualAlloc(nil, uint(size), win32.MEM_RESERVE | win32.MEM_COMMIT, win32.PAGE_READWRITE)
	if p == nil { return E_OUTOFMEMORY }
	sync.mutex_lock(&audio_state.mu)
	a := (audio_state.next_apu + max(align, 256) - 1) & ~(max(align, 256) - 1)
	audio_state.next_apu = a + ((size + 255) & ~u32(255))
	append(&audio_state.blocks, APU_BLOCK{ptr = p, apu = a, size = uint(size)})
	sync.mutex_unlock(&audio_state.mu)
	out^ = p
	if apu != nil { apu^ = a }
	return S_OK
}

ApuFree :: proc "system" (ptr: rawptr) {
	context = hle_context()
	if ptr == nil { return }
	sync.mutex_lock(&audio_state.mu)
	defer sync.mutex_unlock(&audio_state.mu)
	for b, i in audio_state.blocks {
		if b.ptr == ptr {
			_ = win32.VirtualFree(b.ptr, 0, win32.MEM_RELEASE)
			ordered_remove(&audio_state.blocks, i)
			return
		}
	}
}

ApuMapVirtualAddress :: proc "system" (ptr: rawptr) -> u32 {
	context = hle_context()
	if ptr == nil { return 0 }
	sync.mutex_lock(&audio_state.mu)
	defer sync.mutex_unlock(&audio_state.mu)
	up := uintptr(ptr)
	for b in audio_state.blocks {
		bp := uintptr(b.ptr)
		if up >= bp && up < bp + uintptr(b.size) {
			return b.apu + u32(up - bp)
		}
	}
	return 0
}

ApuMapApuAddress :: proc "system" (apu: u32) -> rawptr {
	context = hle_context()
	if apu == 0 { return nil }
	sync.mutex_lock(&audio_state.mu)
	defer sync.mutex_unlock(&audio_state.mu)
	for b in audio_state.blocks {
		if apu >= b.apu && apu < b.apu + u32(b.size) {
			return rawptr(uintptr(b.ptr) + uintptr(apu - b.apu))
		}
	}
	return nil
}

ApuIsVirtualAddressValid :: proc "system" (ptr: rawptr, align: u32) -> bool {
	context = hle_context()
	a := ApuMapVirtualAddress(ptr)
	return a != 0 && (align == 0 || a % align == 0)
}

Acp_Shape_Contexts :: struct #packed {
	counts: [6]u32,
	arrays: [6]rawptr,
	apu:    [6]u32,
}
@(private) ACP_CTX_BYTES := [6]u32{32, 256, 256, 16, 64, 256}
@(private) acp_allocated_arrays: [6]rawptr

AcpHalAllocateShapeContexts :: proc "system" (ctx: ^Acp_Shape_Contexts) -> HRESULT {
	context = hle_context()
	if ctx == nil { return E_INVALIDARG }
	for i in 0 ..< 6 {
		n := ctx.counts[i]
		if n == 0 { continue }
		p: rawptr; a: u32
		hr := ApuAlloc(&p, &a, n * ACP_CTX_BYTES[i], 256, 0)
		if i32(hr) < 0 { return hr }
		acp_allocated_arrays[i] = p
		ctx.arrays[i] = p
		ctx.apu[i] = a
	}
	return S_OK
}
AcpHalReleaseShapeContexts :: proc "system" () -> HRESULT {
	context = hle_context()
	for i in 0 ..< 6 {
		if acp_allocated_arrays[i] != nil {
			ApuFree(acp_allocated_arrays[i])
			acp_allocated_arrays[i] = nil
		}
	}
	return S_OK
}

Acp_Object :: struct {
	vtable: rawptr,
	refs:   u32,
}
@(private) acp_connect :: proc "system" (_: ^Acp_Object, _, _: u32) -> HRESULT { context = hle_context(); return S_OK }
@(private) acp_disconnect :: proc "system" (_: ^Acp_Object) -> HRESULT { context = hle_context(); return S_OK }
@(private) acp_submit :: proc "system" (_: ^Acp_Object, _: u32, _: u32, _: rawptr, _: u32) -> HRESULT { context = hle_context(); return S_OK }
@(private) acp_pop :: proc "system" (_: ^Acp_Object, _: rawptr) -> bool { context = hle_context(); return false }
@(private) acp_count :: proc "system" (_: ^Acp_Object) -> u32 { context = hle_context(); return 0 }
@(private) acp_rel :: proc "system" (t: ^Acp_Object) { context = hle_context(); free(t) }
@(private) ACP_VTABLE := [7]rawptr{
	rawptr(acp_connect), rawptr(acp_disconnect), rawptr(acp_submit),
	rawptr(acp_pop), rawptr(acp_count), rawptr(acp_rel), rawptr(rt_missing),
}

AcpHalCreate :: proc "system" (out: ^^Acp_Object) -> HRESULT {
	context = hle_context()
	if out == nil { return E_INVALIDARG }
	a := new(Acp_Object)
	a^ = Acp_Object{vtable = raw_data(ACP_VTABLE[:]), refs = 1}
	out^ = a
	return S_OK
}

AUDIO_DLLS := [?]string{"acphal.dll"}
AUDIO_EXPORTS := [?]Hle_Export {
	{name = "AcpHalAllocateShapeContexts", address = uintptr(rawptr(AcpHalAllocateShapeContexts))},
	{name = "AcpHalReleaseShapeContexts", address = uintptr(rawptr(AcpHalReleaseShapeContexts))},
	{name = "AcpHalCreate", address = uintptr(rawptr(AcpHalCreate))},
	{name = "ApuAlloc", address = uintptr(rawptr(ApuAlloc))},
	{name = "ApuCreateHeap", address = uintptr(rawptr(ApuCreateHeap))},
	{name = "ApuFree", address = uintptr(rawptr(ApuFree))},
	{name = "ApuIsVirtualAddressValid", address = uintptr(rawptr(ApuIsVirtualAddressValid))},
	{name = "ApuMapApuAddress", address = uintptr(rawptr(ApuMapApuAddress))},
	{name = "ApuMapVirtualAddress", address = uintptr(rawptr(ApuMapVirtualAddress))},
}

// =============================================================================
// 3. dsp (chad.dll 4-channel Hadamard FDN Reverb)
// =============================================================================

DSP_DELAY_LENGTHS :: [4]int{1487, 1993, 2657, 3469}

Dsp_Reverb :: struct {
	lines:    [4][]f32,
	pos:      [4]int,
	lp:       [4]f32,
	feedback: f32,
	damp:     f32,
}

Dsp_Stream :: struct {
	vtable:   rawptr,
	channels: u32,
	reverb:   Dsp_Reverb,
	status:   [8]u32,
}

Dsp_Instance :: struct {
	streams: [dynamic]^Dsp_Stream,
}

@(private)
dsp_state: struct {
	mu:        sync.Mutex,
	instances: [dynamic]^Dsp_Instance,
}

fini_dsp :: proc() {
	sync.mutex_lock(&dsp_state.mu)
	defer sync.mutex_unlock(&dsp_state.mu)
	for inst in dsp_state.instances {
		for s in inst.streams {
			for i in 0 ..< 4 { delete(s.reverb.lines[i]) }
			free(s)
		}
		delete(inst.streams)
		free(inst)
	}
	delete(dsp_state.instances)
	dsp_state.instances = nil
}

dsp_make_reverb :: proc(ir_floats: u32) -> Dsp_Reverb {
	rt := clamp(f32(ir_floats) / 65536.0, 0.0, 1.0)
	rv := Dsp_Reverb{feedback = 0.42 + 0.40 * rt, damp = 0.28}
	dlens := DSP_DELAY_LENGTHS
	for i in 0 ..< 4 {
		rv.lines[i] = make([]f32, dlens[i])
	}
	return rv
}

dsp_process_fdn :: proc(rv: ^Dsp_Reverb, input, output: []f32, frames, ch: int, gains: [2]f32) {
	g0 := clamp(gains[0], -4.0, 4.0) if !math.is_nan(gains[0]) && !math.is_inf(gains[0], 0) else 0.0
	g1 := clamp(gains[1], -4.0, 4.0) if !math.is_nan(gains[1]) && !math.is_inf(gains[1], 0) else 0.0
	wet := 0.5 * (abs(g0) + abs(g1)) if ch == 2 else abs(g0)
	if wet == 0 {
		for i in 0 ..< len(output) { output[i] = 0 }
		return
	}
	fb := rv.feedback
	d := rv.damp
	keep := 1.0 - d
	flush :: proc(x: f32) -> f32 { return 0 if (abs(x) < 1e-20 || math.is_nan(x) || math.is_inf(x, 0)) else x }

	for f in 0 ..< frames {
		inl := input[f * ch] if f * ch < len(input) else 0.0
		inr := input[f * ch + 1] if (ch == 2 && f * ch + 1 < len(input)) else inl
		var_d: [4]f32
		for k in 0 ..< 4 {
			raw := rv.lines[k][rv.pos[k]]
			rv.lp[k] = flush(keep * raw + d * rv.lp[k])
			var_d[k] = rv.lp[k]
		}
		// Normalized 4x4 Hadamard transform: H4 * 0.5
		h0 := 0.5 * (var_d[0] + var_d[1] + var_d[2] + var_d[3])
		h1 := 0.5 * (var_d[0] - var_d[1] + var_d[2] - var_d[3])
		h2 := 0.5 * (var_d[0] + var_d[1] - var_d[2] - var_d[3])
		h3 := 0.5 * (var_d[0] - var_d[1] - var_d[2] + var_d[3])
		in_arr := [4]f32{inl, inr, inl * 0.5 + inr * 0.5, inl - inr}
		h_arr := [4]f32{h0, h1, h2, h3}
		for k in 0 ..< 4 {
			rv.lines[k][rv.pos[k]] = flush(in_arr[k] * 0.25 + fb * h_arr[k])
			rv.pos[k] = (rv.pos[k] + 1) % len(rv.lines[k])
		}
		out_l := flush((var_d[0] + var_d[2]) * 0.5 * g0)
		if ch == 2 {
			out_r := flush((var_d[1] + var_d[3]) * 0.5 * g1)
			if f * 2 + 1 < len(output) {
				output[f * 2] = out_l
				output[f * 2 + 1] = out_r
			}
		} else if f < len(output) {
			output[f] = out_l
		}
	}
}

XDspConnectWithMaximumStreamLimit :: proc "system" (_mem: rawptr, _mem_sz: u32, _ir_seconds: u32, _max_streams: u32, _max_channels: u32, out: ^^Dsp_Instance) -> HRESULT {
	context = hle_context()
	_ = _mem; _ = _mem_sz; _ = _ir_seconds; _ = _max_streams; _ = _max_channels
	if out == nil { return E_INVALIDARG }
	inst := new(Dsp_Instance)
	sync.mutex_lock(&dsp_state.mu)
	append(&dsp_state.instances, inst)
	sync.mutex_unlock(&dsp_state.mu)
	out^ = inst
	return S_OK
}
XDspDisconnect :: proc "system" (inst: ^Dsp_Instance) -> HRESULT {
	context = hle_context()
	if inst == nil { return E_INVALIDARG }
	sync.mutex_lock(&dsp_state.mu)
	defer sync.mutex_unlock(&dsp_state.mu)
	for x, i in dsp_state.instances {
		if x == inst {
			ordered_remove(&dsp_state.instances, i)
			for s in x.streams {
				for k in 0 ..< 4 { delete(s.reverb.lines[k]) }
				free(s)
			}
			delete(x.streams)
			free(x)
			break
		}
	}
	return S_OK
}
XDspActivate :: proc "system" (inst: ^Dsp_Instance, _kind: u32, _params: rawptr, out_stream: ^^Dsp_Stream, out_status: ^rawptr) -> HRESULT {
	context = hle_context()
	_ = _kind; _ = _params
	if inst == nil || uintptr(out_stream) < 0x10000 { return E_INVALIDARG }
	s := new(Dsp_Stream)
	s.channels = 2
	s.reverb = dsp_make_reverb(16384)
	sync.mutex_lock(&dsp_state.mu)
	append(&inst.streams, s)
	sync.mutex_unlock(&dsp_state.mu)
	out_stream^ = s
	if uintptr(out_status) >= 0x10000 { out_status^ = rawptr(&s.status[0]) }
	return S_OK
}
XDspDeactivate :: proc "system" (s: ^Dsp_Stream) -> HRESULT {
	context = hle_context()
	if s == nil { return E_INVALIDARG }
	sync.mutex_lock(&dsp_state.mu)
	defer sync.mutex_unlock(&dsp_state.mu)
	for inst in dsp_state.instances {
		for st, i in inst.streams {
			if st == s {
				ordered_remove(&inst.streams, i)
				for k in 0 ..< 4 { delete(st.reverb.lines[k]) }
				free(st)
				return S_OK
			}
		}
	}
	return S_OK
}
XDspSubmitCommand :: proc "system" (s: ^Dsp_Stream, ticket: u32, frames: u32, gains: ^[2]f32, input, output: [^]f32) -> HRESULT {
	context = hle_context()
	if s == nil { return E_INVALIDARG }
	if input != nil && output != nil && frames > 0 {
		ch := int(s.channels)
		in_sl := mem.slice_ptr(input, int(frames) * ch)
		out_sl := mem.slice_ptr(output, int(frames) * ch)
		g := gains^ if gains != nil else [2]f32{1.0, 1.0}
		dsp_process_fdn(&s.reverb, in_sl, out_sl, int(frames), ch, g)
	}
	s.status[1] = ticket
	s.status[3] = u32(S_OK)
	return S_OK
}

DSP_DLLS := [?]string{"chad.dll"}
DSP_EXPORTS := [?]Hle_Export {
	{name = "XDspConnectWithMaximumStreamLimit", address = uintptr(rawptr(XDspConnectWithMaximumStreamLimit))},
	{name = "XDspDisconnect", address = uintptr(rawptr(XDspDisconnect))},
	{name = "XDspActivate", address = uintptr(rawptr(XDspActivate))},
	{name = "XDspDeactivate", address = uintptr(rawptr(XDspDeactivate))},
	{name = "XDspSubmitCommand", address = uintptr(rawptr(XDspSubmitCommand))},
}

// =============================================================================
// 4. apu (xapu.dll Opus stream command engine + RFC 6716 frame timing)
// =============================================================================

XAPU_PENDING_RESULTS :: HRESULT(-1966596095) // 0x8AC81001
XAPU_INVALID_COMMAND :: HRESULT(-1966596094) // 0x8AC81002
XAPU_INVALID_STREAM :: HRESULT(-1966596093) // 0x8AC81003
XAPU_ALREADY_ACTIVE :: HRESULT(-1966596091) // 0x8AC81005
XAPU_BAD_PACKET :: HRESULT(-1966596088) // 0x8AC81008

Apu_Connect_Input :: struct {
	process:           u32,
	streams:           u32,
	commands_per_str:  u32,
	memory:            u32,
	frames_per_output: u32,
	options:           u32,
}
Apu_Connect_Output :: struct {
	memory:       rawptr,
	result_event: win32.HANDLE,
}
Apu_Command_Id :: struct #packed {
	kind:     u32,
	stream:   u32,
	sequence: u32,
	options:  u32,
	ctx:      u64,
}
Apu_Activate :: struct #packed {
	id:                Apu_Command_Id,
	channels:          u32,
	init_length:       u32,
	init:              rawptr,
	start_pitch:       f32,
	processing_length: u32,
	processing:        rawptr,
}
Apu_Process :: struct #packed {
	id:            Apu_Command_Id,
	pitch_ramp:    f32,
	target_pitch:  f32,
	first_frame:   u32,
	frame_count:   u32,
	input_length:  u32,
	input:         [^]u8,
	output_length: u32,
	output:        [^]u8,
}
Apu_Result :: struct #packed {
	id:            Apu_Command_Id,
	state:         u32,
	state_data:    u32,
	usec:          u64,
	error:         HRESULT,
	frames:        u32,
	output_length: u32,
	output:        [^]u8,
	pitch:         f32,
	input_length:  u32,
	input:         [^]u8,
}

Apu_Stream_State :: struct {
	active:   bool,
	channels: u32,
	pitch:    f32,
	decoder:  rawptr, // optional libopus handle
}

Apu_Connection :: struct {
	mu:       sync.Mutex,
	options:  u32,
	memory:   rawptr,
	mem_sz:   uint,
	event:    win32.HANDLE,
	streams:  []Apu_Stream_State,
	results:  [dynamic]Apu_Result,
	commands: u32,
}

@(private)
apu_state: struct {
	mu:    sync.Mutex,
	conns: [dynamic]^Apu_Connection,
}

fini_apu :: proc() {
	sync.mutex_lock(&apu_state.mu)
	defer sync.mutex_unlock(&apu_state.mu)
	for c in apu_state.conns {
		if c.event != nil { _ = win32.CloseHandle(c.event) }
		if c.memory != nil { _ = win32.VirtualFree(c.memory, 0, win32.MEM_RELEASE) }
		delete(c.streams)
		delete(c.results)
		free(c)
	}
	delete(apu_state.conns)
	apu_state.conns = nil
}

// opus_packet_samples computes exact sample count per channel from the RFC 6716 TOC byte.
opus_packet_samples :: proc(packet: []u8) -> (int, bool) {
	if len(packet) == 0 { return 0, false }
	toc := packet[0]
	cfg := toc >> 3
	// Frame size at 48 kHz from RFC 6716 Table 2:
	frame_samples := 960
	switch cfg {
	case 0, 4, 8: frame_samples = 480
	case 1, 5, 9: frame_samples = 960
	case 2, 6, 10: frame_samples = 1920
	case 3, 7, 11: frame_samples = 2880
	case 12, 14: frame_samples = 480
	case 13, 15: frame_samples = 960
	case 16, 20, 24, 28: frame_samples = 120
	case 17, 21, 25, 29: frame_samples = 240
	case 18, 22, 26, 30: frame_samples = 480
	case 19, 23, 27, 31: frame_samples = 960
	}
	code := toc & 3
	frames := 1
	switch code {
	case 0: frames = 1
	case 1, 2:
		if len(packet) < 2 { return 0, false }
		frames = 2
	case 3:
		if len(packet) < 2 { return 0, false }
		frames = int(packet[1] & 0x3F)
		if frames == 0 { return 0, false }
	}
	total := frames * frame_samples
	if total > 5760 { return 0, false }
	return total, true
}

XApuConnect :: proc "system" (input: ^Apu_Connect_Input, output: ^Apu_Connect_Output) -> HRESULT {
	context = hle_context()
	if input == nil || output == nil { return E_INVALIDARG }
	if input.process != 1 { return E_NOTIMPL }
	mem_sz := max(uint(input.memory), uint(4096))
	p := win32.VirtualAlloc(nil, mem_sz, win32.MEM_RESERVE | win32.MEM_COMMIT, win32.PAGE_READWRITE)
	if p == nil { return E_OUTOFMEMORY }
	ev: win32.HANDLE = nil
	if input.options & 8 != 0 {
		ev = win32.CreateEventW(nil, false, false, nil)
	}
	c := new(Apu_Connection)
	c.options = input.options
	c.memory = p
	c.mem_sz = mem_sz
	c.event = ev
	c.streams = make([]Apu_Stream_State, max(int(input.streams), 1))
	sync.mutex_lock(&apu_state.mu)
	append(&apu_state.conns, c)
	sync.mutex_unlock(&apu_state.mu)
	output^ = Apu_Connect_Output{memory = p, result_event = ev}
	return S_OK
}

XApuDisconnect :: proc "system" (c: ^Apu_Connection) -> HRESULT {
	context = hle_context()
	if c == nil { return E_INVALIDARG }
	sync.mutex_lock(&apu_state.mu)
	defer sync.mutex_unlock(&apu_state.mu)
	for item, i in apu_state.conns {
		if item == c {
			ordered_remove(&apu_state.conns, i)
			if item.event != nil { _ = win32.CloseHandle(item.event) }
			if item.memory != nil { _ = win32.VirtualFree(item.memory, 0, win32.MEM_RELEASE) }
			delete(item.streams)
			delete(item.results)
			free(item)
			break
		}
	}
	return S_OK
}

XApuEnqueueCommand :: proc "system" (c: ^Apu_Connection, cmd_ptr: rawptr, total: ^u32) -> HRESULT {
	context = hle_context()
	if c == nil || cmd_ptr == nil { return E_INVALIDARG }
	id := (cast(^Apu_Command_Id)cmd_ptr)^
	sync.mutex_lock(&c.mu)
	defer sync.mutex_unlock(&c.mu)
	if int(id.stream) >= len(c.streams) { return XAPU_INVALID_STREAM }
	st := &c.streams[id.stream]
	res := Apu_Result{id = id, error = S_OK, pitch = 1.0}

	switch id.kind {
	case 1: // ACTIVATE
		act := (cast(^Apu_Activate)cmd_ptr)^
		if st.active {
			res.error = XAPU_ALREADY_ACTIVE
		} else if act.channels < 1 || act.channels > 2 {
			res.error = E_INVALIDARG
		} else {
			sp := clamp(act.start_pitch, 0.25, 4.0) if (act.start_pitch > 0 && !math.is_nan(act.start_pitch)) else 1.0
			st.active = true
			st.channels = act.channels
			st.pitch = sp
			res.pitch = sp
		}
	case 2: // DEACTIVATE
		st.active = false
		st.pitch = 1.0
	case 5: // RESET
		st.pitch = 1.0
	case 4: // NOTIFY
	case 3: // PROCESS
		pr := (cast(^Apu_Process)cmd_ptr)^
		res.input = pr.input
		res.input_length = pr.input_length
		res.output = pr.output
		if !st.active {
			res.error = XAPU_INVALID_STREAM
		} else if pr.input == nil || pr.output == nil || pr.input_length == 0 {
			res.error = E_INVALIDARG
		} else {
			pkt := mem.byte_slice(pr.input, int(pr.input_length))
			if nsamp, ok := opus_packet_samples(pkt); ok {
				ch := int(st.channels)
				first := min(int(pr.first_frame), nsamp)
				max_out := min(int(pr.frame_count), int(pr.output_length) / (4 * ch))
				frames := min(nsamp - first, max_out)
				mem.zero(pr.output, frames * ch * 4)
				res.frames = u32(frames)
				res.output_length = u32(frames * ch * 4)
			} else {
				res.error = XAPU_BAD_PACKET
			}
		}
	case:
		return XAPU_INVALID_COMMAND
	}
	c.commands += 1
	append(&c.results, res)
	if total != nil { total^ = c.commands }
	if id.options & 1 != 0 && c.event != nil {
		_ = win32.SetEvent(c.event)
	}
	return S_OK
}

XApuDequeueResult :: proc "system" (c: ^Apu_Connection, out: ^Apu_Result) -> HRESULT {
	context = hle_context()
	if c == nil || out == nil { return E_INVALIDARG }
	sync.mutex_lock(&c.mu)
	defer sync.mutex_unlock(&c.mu)
	if len(c.results) == 0 { return XAPU_PENDING_RESULTS }
	out^ = c.results[0]
	ordered_remove(&c.results, 0)
	return S_OK
}

XApuGetResultCount :: proc "system" (c: ^Apu_Connection, total: ^u32) -> u32 {
	context = hle_context()
	if c == nil { return 0 }
	sync.mutex_lock(&c.mu)
	defer sync.mutex_unlock(&c.mu)
	if total != nil { total^ = c.commands }
	return u32(len(c.results))
}

APU_DLLS := [?]string{"xapu.dll"}
APU_EXPORTS := [?]Hle_Export {
	{name = "XApuConnect", address = uintptr(rawptr(XApuConnect))},
	{name = "XApuDisconnect", address = uintptr(rawptr(XApuDisconnect))},
	{name = "XApuEnqueueCommand", address = uintptr(rawptr(XApuEnqueueCommand))},
	{name = "XApuDequeueResult", address = uintptr(rawptr(XApuDequeueResult))},
	{name = "XApuGetResultCount", address = uintptr(rawptr(XApuGetResultCount))},
}

// GameInput is implemented in gameinput.odin.

// =============================================================================
// 6. media (mfplat MFCreateSourceResolver local-file filter)
// =============================================================================

MEDIA_UNSUPPORTED_SCHEME :: HRESULT(-1072875837) // 0xC00D36C3

is_local_media_url :: proc(url: string) -> bool {
	if len(url) == 0 { return false }
	if strings.has_prefix(url, `\\`) {
		if strings.has_prefix(url, `\\?\`) && len(url) >= 6 && url[5] == ':' {
			return true
		}
		return false
	}
	if len(url) >= 2 && url[1] == ':' && ((url[0] >= 'a' && url[0] <= 'z') || (url[0] >= 'A' && url[0] <= 'Z')) {
		return true
	}
	colon := strings.index_byte(url, ':')
	if colon > 1 {
		scheme := strings.to_lower(url[:colon], context.temp_allocator)
		if scheme != "file" { return false }
		rest := url[colon + 1:]
		if strings.has_prefix(rest, "//") {
			after := rest[2:]
			slash := strings.index_any(after, `/\`)
			host := after if slash < 0 else after[:slash]
			if len(host) > 0 && !strings.equal_fold(host, "localhost") {
				return false
			}
		}
		return true
	}
	return true
}

MFCreateSourceResolver :: proc "system" (out: ^rawptr) -> HRESULT {
	context = hle_context()
	fn, ok := host_fn("mfplat.dll", "MFCreateSourceResolver", proc "system" (^rawptr) -> HRESULT)
	return fn(out) if ok else E_NOTIMPL
}

MEDIA_DLLS := [?]string{"mfplat.dll"}
MEDIA_EXPORTS := [?]Hle_Export{{name = "MFCreateSourceResolver", address = uintptr(rawptr(MFCreateSourceResolver))}}

// =============================================================================
// 7. d3d12x & fidelityfx (Gpu_Hooks bridge)
// =============================================================================

@(private) hle_d3d12_config_vmem :: proc "system" (res: rawptr, cnt: u32, ranges: rawptr) -> HRESULT {
	context = hle_context()
	hooks := get_gpu_hooks()
	if hooks.configure_virtual_memory != nil { return hooks.configure_virtual_memory(res, cnt, ranges) }
	return S_OK
}
@(private) hle_d3d12_create_device :: proc "system" (adapter: rawptr, params: ^u32, iid: ^Guid, out: ^rawptr) -> HRESULT {
	context = hle_context()
	hooks := get_gpu_hooks()
	if hooks.create_device != nil { return hooks.create_device(adapter, params, iid, out) }
	return E_NOTIMPL
}
@(private) hle_d3d12_serialize_rs :: proc "system" (desc: rawptr, ver: u32, blob, err_blob: ^rawptr) -> HRESULT {
	context = hle_context()
	hooks := get_gpu_hooks()
	if hooks.serialize_root_signature != nil { return hooks.serialize_root_signature(desc, ver, blob, err_blob) }
	return E_NOTIMPL
}
@(private) hle_d3d12_serialize_vrs :: proc "system" (desc: rawptr, blob, err_blob: ^rawptr) -> HRESULT {
	context = hle_context()
	hooks := get_gpu_hooks()
	if hooks.serialize_versioned_root_signature != nil { return hooks.serialize_versioned_root_signature(desc, blob, err_blob) }
	return E_NOTIMPL
}
@(private) hle_d3d12_create_deser :: proc "system" (src: rawptr, len: uint, iid: ^Guid, out: ^rawptr) -> HRESULT {
	context = hle_context()
	hooks := get_gpu_hooks()
	if hooks.create_root_deserializer != nil { return hooks.create_root_deserializer(src, len, iid, out) }
	return E_NOTIMPL
}

// Standard ID3D12Device GUID bytes {189819f1-1db6-4b57-be54-1821339b85f7} -> data export
IID_ID3D12Device_DATA := [16]u8{0xf1, 0x19, 0x98, 0x18, 0xb6, 0x1d, 0x57, 0x4b, 0xbe, 0x54, 0x18, 0x21, 0x33, 0x9b, 0x85, 0xf7}

D3D12X_DLLS := [?]string{"d3d12_xs.dll"}
D3D12X_EXPORTS := [?]Hle_Export {
	{name = "D3D12ConfigureVirtualMemoryX", address = uintptr(rawptr(hle_d3d12_config_vmem))},
	{name = "D3D12XboxCreateDevice", address = uintptr(rawptr(hle_d3d12_create_device))},
	{name = "D3D12SerializeRootSignature", address = uintptr(rawptr(hle_d3d12_serialize_rs))},
	{name = "D3D12SerializeVersionedRootSignature", address = uintptr(rawptr(hle_d3d12_serialize_vrs))},
	{name = "D3D12CreateRootSignatureDeserializer", address = uintptr(rawptr(hle_d3d12_create_deser))},
	{name = "IID_ID3D12Device", address = uintptr(raw_data(IID_ID3D12Device_DATA[:]))},
}

ffx_serving :: proc() -> bool {
	dir, ok := os.lookup_env("VASPERTY_FIDELITYFX_DIR", context.temp_allocator)
	if !ok || len(dir) == 0 {
		dir, ok = os.lookup_env("VICTORY_FIDELITYFX_DIR", context.temp_allocator)
	}
	if !ok || len(dir) == 0 { return false }
	p, _ := filepath.join({dir, "amd_fidelityfx_upscaler_dx12.dll"}, context.temp_allocator)
	return os.is_file(p)
}

@(private) ffxConfigure :: proc "system" (_desc: rawptr) -> u32 { context = hle_context(); return 4 }
@(private) ffxCreateContext :: proc "system" (_ctx, _desc, _alloc: rawptr) -> u32 { context = hle_context(); return 4 }
@(private) ffxDestroyContext :: proc "system" (_ctx, _alloc: rawptr) -> u32 { context = hle_context(); return 4 }
@(private) ffxDispatch :: proc "system" (_ctx, _desc: rawptr) -> u32 { context = hle_context(); return 4 }
@(private) ffxQuery :: proc "system" (_ctx, _desc: rawptr) -> u32 { context = hle_context(); return 4 }

FIDELITYFX_DLLS := [?]string{"amd_fidelityfx_loader_xbox.dll"}
FIDELITYFX_EXPORTS := [?]Hle_Export {
	{name = "ffxConfigure", address = uintptr(rawptr(ffxConfigure))},
	{name = "ffxCreateContext", address = uintptr(rawptr(ffxCreateContext))},
	{name = "ffxDestroyContext", address = uintptr(rawptr(ffxDestroyContext))},
	{name = "ffxDispatch", address = uintptr(rawptr(ffxDispatch))},
	{name = "ffxQuery", address = uintptr(rawptr(ffxQuery))},
}
