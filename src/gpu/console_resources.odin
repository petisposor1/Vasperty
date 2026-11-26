package vasperty_gpu

import "base:intrinsics"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import win32 "core:sys/windows"
import vasperty_hle "vasperty:hle"
import vasperty_shader "vasperty:shader"

// =========================================================================
// Xbox D3D12.X Resource, Heap, Descriptor Heap, Pipeline, RootSig, Query, CmdSig
// =========================================================================

@(private)
resource_xmem_attributes :: proc "contextless" (size: u64, align: u64, heap_kind: u32) -> u64 {
	GRAPHICS_ALLOCATOR :: u64(128) << 16
	pages: u64 = 2 if size >= (2 << 20) else 1
	mem_type: u64 = 1 if heap_kind == 1 else 3
	a := max(align, u64(65536))
	align_log2 := u64(intrinsics.count_trailing_zeros(a))
	return GRAPHICS_ALLOCATOR | (pages << 14) | (align_log2 << 24) | (mem_type << 29)
}

// Allocate GPU-visible memory via XMemAlloc (honoring title's __XMemAllocationHooks__
// budget tracking) below 2^40, falling back to XMemVirtualAlloc/VirtualAlloc.
@(private)
alloc_gpu_memory :: proc(size: u64, align: u64 = 65536, heap_kind: u32 = 1) -> (rawptr, u64) {
	bytes := max(uint(size), 64 << 10)
	bytes = (bytes + 0xFFFF) & ~uint(0xFFFF)
	attrs := resource_xmem_attributes(u64(bytes), align, heap_kind)
	p := vasperty_hle.XMemAlloc(bytes, attrs)
	if p != nil {
		return p, attrs
	}
	p = vasperty_hle.XMemVirtualAlloc(
		nil,
		bytes,
		win32.MEM_RESERVE | win32.MEM_COMMIT,
		vasperty_hle.XMEM_GRAPHICS | vasperty_hle.XMEM_ADDRESS_32BIT,
		win32.PAGE_READWRITE,
	)
	if p != nil {
		return p, 0
	}
	return win32.VirtualAlloc(nil, bytes, win32.MEM_RESERVE | win32.MEM_COMMIT, win32.PAGE_READWRITE), 0
}

@(private)
free_gpu_memory :: proc(p: rawptr, attrs: u64 = 0) {
	if p == nil { return }
	if attrs != 0 {
		vasperty_hle.XMemFree(p, attrs)
	} else {
		_ = win32.VirtualFree(p, 0, win32.MEM_RELEASE)
	}
}

// =========================================================================
// Resource & Heap Descriptors
// =========================================================================

D3D12_RESOURCE_DESC :: struct {
	Dimension:        u32,
	Alignment:        u64,
	Width:            u64,
	Height:           u32,
	DepthOrArraySize: u16,
	MipLevels:        u16,
	Format:           u32,
	SampleCount:      u32,
	SampleQuality:    u32,
	Layout:           u32,
	Flags:            u32,
}

D3D12_RESOURCE_DESC1 :: struct {
	Desc:      D3D12_RESOURCE_DESC,
	MipRegion: [3]u32,
}

D3D12_HEAP_DESC :: struct {
	SizeInBytes: u64,
	Properties:  D3D12_HEAP_PROPERTIES,
	Alignment:   u64,
	Flags:       u32,
}

D3D12_RESOURCE_ALLOCATION_INFO :: struct {
	SizeInBytes: u64,
	Alignment:   u64,
}

D3D12_RESOURCE_ALLOCATION_INFO1 :: struct {
	Offset:      u64,
	Alignment:   u64,
	SizeInBytes: u64,
}

D3D12_SUBRESOURCE_FOOTPRINT :: struct {
	Format:   u32,
	Width:    u32,
	Height:   u32,
	Depth:    u32,
	RowPitch: u32,
}

D3D12_PLACED_SUBRESOURCE_FOOTPRINT :: struct {
	Offset:    u64,
	Footprint: D3D12_SUBRESOURCE_FOOTPRINT,
}

@(private)
dxgi_format_bpp :: proc "contextless" (format: u32) -> (bytes: u64, block: u32) {
	// Common DXGI formats: block-compressed (4x4) and uncompressed
	switch format {
	case 0: return 1, 1 // UNKNOWN (buffers)
	case 1..=4: return 16, 1 // R32G32B32A32
	case 5..=8: return 12, 1 // R32G32B32
	case 9..=14: return 8, 1 // R16G16B16A16
	case 15..=18: return 8, 1 // R32G32
	case 23..=32, 87..=93: return 4, 1 // R8G8B8A8 / B8G8R8A8 / R10G10B10A2 / R11G11B10F
	case 33..=45: return 4, 1 // R16G16 / R32 / D32 / D24S8
	case 48..=59: return 2, 1 // R8G8 / R16 / D16
	case 60..=66: return 1, 1 // R8 / A8
	case 70..=72, 79..=81: return 8, 4 // BC1 / BC4 (8 bytes per 4x4 block)
	case 73..=78, 82..=84, 94..=99: return 16, 4 // BC2 / BC3 / BC5 / BC6H / BC7 (16 bytes per 4x4 block)
	}
	return 4, 1
}

@(private)
estimate_resource_bytes :: proc "contextless" (d: D3D12_RESOURCE_DESC) -> (size: u64, align: u64) {
	align = d.Alignment if d.Alignment >= 65536 else 65536
	if d.Dimension == 1 { // BUFFER
		sz := max(d.Width, u64(1))
		return (sz + 0xFFFF) & ~u64(0xFFFF), align
	}
	bpp, blk := dxgi_format_bpp(d.Format)
	w := max(d.Width, u64(1))
	h := max(u64(d.Height), u64(1))
	slices := max(u64(d.DepthOrArraySize), u64(1))
	bw := (w + u64(blk) - 1) / u64(blk)
	bh := (h + u64(blk) - 1) / u64(blk)
	// RDNA 2 64 KiB macro-tile alignment for 2D textures (e.g. 128x128 for 4-byte pixels)
	if d.Dimension == 3 && d.Layout != 1 && blk == 1 {
		tile_w: u64 = 128
		tile_h: u64 = 128
		if bpp >= 8 { tile_w = 64 }
		if bpp <= 2 { tile_w = 256 }
		bw = (bw + tile_w - 1) & ~(tile_w - 1)
		bh = (bh + tile_h - 1) & ~(tile_h - 1)
	}
	row_pitch := (bw * bpp + 255) & ~u64(255)
	total := row_pitch * bh * slices
	if d.MipLevels != 1 {
		total = total + total / 3 + 65536
	}
	total = max(total, u64(65536))
	return (total + 0xFFFF) & ~u64(0xFFFF), align
}

// =========================================================================
// Console_Heap (ID3D12Heap)
// =========================================================================

Console_Heap :: struct {
	object: Gpu_Object,
	desc:   D3D12_HEAP_DESC,
	base:   rawptr,
	attrs:  u64,
}

@(private)
g_heap_vtable: [24]rawptr

@(private)
heap_qi :: proc "system" (this: This, iid: ^Iid, out: ^This) -> HRESULT {
	context = gpu_context()
	_ = iid
	return answer_interface(this, out)
}

@(private)
heap_release :: proc "system" (this: This) -> u32 {
	context = gpu_context()
	if this == nil { return 0 }
	rem := object_release_static(this)
	if rem == 0 {
		h := cast(^Console_Heap)this
		free_gpu_memory(h.base, h.attrs)
		free(h)
	}
	return rem
}

@(private)
heap_get_desc :: proc "system" (this: This, out: ^D3D12_HEAP_DESC) -> ^D3D12_HEAP_DESC {
	if out != nil && this != nil {
		out^ = (cast(^Console_Heap)this).desc
	}
	return out
}

@(private)
heap_stub :: proc "system" (this: This) -> HRESULT {
	context = gpu_context()
	_ = this
	off := decode_vtable_slot(intrinsics.return_address())
	fmt.printf("[d3d12x] Heap unimpl slot #%d (off=0x%X)\n", off / 8, off)
	return E_NOTIMPL
}

device_create_heap :: proc "system" (this: This, desc: ^D3D12_HEAP_DESC, iid: ^Iid, out: ^rawptr) -> HRESULT {
	context = gpu_context()
	_ = this; _ = iid
	if desc == nil || out == nil { return E_INVALIDARG }
	h := new(Console_Heap)
	h.object = Gpu_Object{functions = &g_heap_vtable[0], bits = u32(Object_Kind.Heap), refs = 1}
	h.desc = desc^
	h.base, h.attrs = alloc_gpu_memory(desc.SizeInBytes, desc.Alignment, desc.Properties.Type)
	if h.base == nil {
		free(h)
		return E_OUTOFMEMORY
	}
	out^ = rawptr(h)
	return S_OK
}

// =========================================================================
// Console_Resource (ID3D12Resource)
// =========================================================================

Console_Resource :: struct {
	object:      Gpu_Object,
	desc:        D3D12_RESOURCE_DESC,
	heap_props:  D3D12_HEAP_PROPERTIES,
	heap_flags:  u32,
	address:     u64,
	owns_mem:    bool,
	mem_attrs:   u64,
	parent_heap: This,
	host_tex:    rawptr,
	host_state:  u32,
	was_drawn:   bool,
}

@(private)
Host_Tex_Key :: struct {
	address:   u64,
	dimension: u32,
	width:     u64,
	height:    u32,
	format:    u32,
}

@(private)
Host_Tex_Entry :: struct {
	tex:   rawptr,
	state: u32,
}

@(private)
g_host_tex_mu: sync.Mutex
@(private)
g_host_tex_map: map[Host_Tex_Key]Host_Tex_Entry

@(private)
map_host_texture_format :: proc "contextless" (fmt_id: u32) -> u32 {
	switch fmt_id {
	case 0:
		return DXGI_FORMAT_R8G8B8A8_UNORM
	case 118: // Xbox D16_UNORM_S8_UINT -> D24_UNORM_S8_UINT
		return 45
	case 119: // Xbox R16_UNORM_X8_TYPELESS -> R24_UNORM_X8_TYPELESS
		return 46
	case 120: // Xbox X16_TYPELESS_G8_UINT -> X24_TYPELESS_G8_UINT
		return 47
	}
	if fmt_id > 115 {
		return DXGI_FORMAT_R8G8B8A8_UNORM
	}
	return fmt_id
}

fini_host_textures :: proc() {
	sync.mutex_lock(&g_host_tex_mu)
	defer sync.mutex_unlock(&g_host_tex_mu)
	for _, entry in g_host_tex_map {
		if entry.tex != nil {
			com_release(entry.tex)
		}
	}
	delete(g_host_tex_map)
	g_host_tex_map = nil
}

ensure_host_texture :: proc(r: ^Console_Resource) -> (rawptr, u32) {
	if r == nil {
		return nil, 0
	}
	if r.host_tex != nil {
		return r.host_tex, r.host_state
	}
	if r.desc.Dimension == 1 || r.desc.Dimension < 2 || r.desc.Dimension > 4 {
		return nil, 0
	}
	if r.desc.Width == 0 || r.desc.Height == 0 {
		return nil, 0
	}

	sync.mutex_lock(&g_host_tex_mu)
	defer sync.mutex_unlock(&g_host_tex_mu)

	if r.host_tex != nil {
		return r.host_tex, r.host_state
	}

	key := Host_Tex_Key{
		address   = r.address,
		dimension = r.desc.Dimension,
		width     = r.desc.Width,
		height    = r.desc.Height,
		format    = r.desc.Format,
	}
	if r.address != 0 && g_host_tex_map != nil {
		if entry, ok := g_host_tex_map[key]; ok && entry.tex != nil {
			_ = com_add_ref(entry.tex)
			r.host_tex = entry.tex
			r.host_state = entry.state
			return r.host_tex, r.host_state
		}
	}

	hdev := ensure_host_device()
	if hdev == nil {
		return nil, 0
	}

	flags := r.desc.Flags & 0xF
	if (flags & 0x2) != 0 {
		// Depth-stencil resources cannot carry ALLOW_UNORDERED_ACCESS (or ALLOW_RENDER_TARGET).
		flags &= ~u32(0x4 | 0x1)
	} else {
		// DENY_SHADER_RESOURCE is only valid alongside ALLOW_DEPTH_STENCIL on PC D3D12.
		flags &= ~u32(0x8)
	}

	sample_count := max(r.desc.SampleCount, u32(1))
	sample_quality := r.desc.SampleQuality if sample_count > 1 else u32(0)
	mip_levels := u16(1) if sample_count > 1 else r.desc.MipLevels
	height := u32(1) if r.desc.Dimension == 2 else max(r.desc.Height, u32(1))

	pc_desc := D3D12_RESOURCE_DESC{
		Dimension        = r.desc.Dimension,
		Alignment        = 0,
		Width            = max(r.desc.Width, u64(1)),
		Height           = height,
		DepthOrArraySize = max(r.desc.DepthOrArraySize, u16(1)),
		MipLevels        = mip_levels,
		Format           = map_host_texture_format(r.desc.Format),
		SampleCount      = sample_count,
		SampleQuality    = sample_quality,
		Layout           = 0,
		Flags            = flags,
	}
	heap_props := D3D12_HEAP_PROPERTIES{
		Type                 = 1, // D3D12_HEAP_TYPE_DEFAULT
		CreationNodeMask     = 1,
		VisibleNodeMask      = 1,
	}

	dvt := (cast(^^Win_Dev_Vtbl)hdev)^
	res_iid := IID_ID3D12Resource_G
	tex: rawptr
	hr := dvt.CreateCommittedResource(hdev, &heap_props, 0, &pc_desc, 0, nil, &res_iid, &tex)
	if (hr < 0 || tex == nil) && pc_desc.Flags != 0 && (pc_desc.Flags & 0x2) == 0 {
		// Fallback for non-depth formats that reject ALLOW_RENDER_TARGET or ALLOW_UNORDERED_ACCESS.
		pc_desc.Flags = 0
		tex = nil
		hr = dvt.CreateCommittedResource(hdev, &heap_props, 0, &pc_desc, 0, nil, &res_iid, &tex)
	}
	if hr < 0 || tex == nil {
		return nil, 0
	}

	if r.address != 0 {
		if g_host_tex_map == nil {
			g_host_tex_map = make(map[Host_Tex_Key]Host_Tex_Entry)
		}
		g_host_tex_map[key] = Host_Tex_Entry{tex = tex, state = 0}
		_ = com_add_ref(tex) // map holds 1 ref; r.host_tex owns the other
	}
	r.host_tex = tex
	r.host_state = 0
	return r.host_tex, r.host_state
}

@(private)
g_resource_vtable: [32]rawptr

@(private)
res_qi :: proc "system" (this: This, iid: ^Iid, out: ^This) -> HRESULT {
	context = gpu_context()
	_ = iid
	return answer_interface(this, out)
}

@(private)
res_release :: proc "system" (this: This) -> u32 {
	context = gpu_context()
	if this == nil { return 0 }
	rem := object_release_static(this)
	if rem == 0 {
		r := cast(^Console_Resource)this
		if r.host_tex != nil {
			com_release(r.host_tex)
			r.host_tex = nil
		}
		if r.owns_mem && r.address != 0 {
			free_gpu_memory(rawptr(uintptr(r.address)), r.mem_attrs)
		}
		if r.parent_heap != nil {
			heap_release(r.parent_heap)
		}
		free(r)
	}
	return rem
}

@(private)
res_map :: proc "system" (this: This, sub: u32, read_range: rawptr, out_data: ^rawptr) -> HRESULT {
	_ = sub; _ = read_range
	if this == nil { return E_INVALIDARG }
	if out_data != nil {
		r := cast(^Console_Resource)this
		out_data^ = rawptr(uintptr(r.address))
	}
	return S_OK
}

@(private)
res_unmap :: proc "system" (this: This, sub: u32, written_range: rawptr) {
	_ = this; _ = sub; _ = written_range
}

@(private)
res_get_desc :: proc "system" (this: This, out: ^D3D12_RESOURCE_DESC) -> ^D3D12_RESOURCE_DESC {
	if out != nil && this != nil {
		out^ = (cast(^Console_Resource)this).desc
	}
	return out
}

@(private)
res_gpu_address :: proc "system" (this: This) -> u64 {
	if this == nil { return 0 }
	return (cast(^Console_Resource)this).address
}

@(private)
res_heap_properties :: proc "system" (this: This, props: ^D3D12_HEAP_PROPERTIES, flags: ^u32) -> HRESULT {
	if this == nil { return E_INVALIDARG }
	r := cast(^Console_Resource)this
	if props != nil { props^ = r.heap_props }
	if flags != nil { flags^ = r.heap_flags }
	return S_OK
}

@(private)
res_stub :: proc "system" (this: This) -> HRESULT {
	context = gpu_context()
	_ = this
	off := decode_vtable_slot(intrinsics.return_address())
	fmt.printf("[d3d12x] Resource unimpl slot #%d (off=0x%X)\n", off / 8, off)
	return E_NOTIMPL
}

@(private)
make_console_resource :: proc(desc: D3D12_RESOURCE_DESC, props: D3D12_HEAP_PROPERTIES, hflags: u32, addr: u64, owns: bool, parent_heap: This, out: ^rawptr) -> HRESULT {
	if out == nil { return E_POINTER }
	r := new(Console_Resource)
	r.object = Gpu_Object{functions = &g_resource_vtable[0], bits = u32(Object_Kind.Resource), refs = 1}
	r.desc = desc
	r.heap_props = props
	r.heap_flags = hflags
	r.address = addr
	r.owns_mem = owns
	r.parent_heap = parent_heap
	if parent_heap != nil {
		_ = object_add_ref(parent_heap)
	}
	out^ = rawptr(r)
	return S_OK
}

device_get_alloc_info :: proc "system" (out: ^D3D12_RESOURCE_ALLOCATION_INFO, this: This, visible: u32, count: u32, descs: [^]D3D12_RESOURCE_DESC) -> ^D3D12_RESOURCE_ALLOCATION_INFO {
	context = gpu_context()
	_ = this; _ = visible
	if out != nil {
		total: u64 = 0
		max_align: u64 = 65536
		if descs != nil {
			for i in 0 ..< count {
				sz, al := estimate_resource_bytes(descs[i])
				if al > max_align { max_align = al }
				total = (total + al - 1) & ~(al - 1)
				total += sz
			}
		}
		out^ = D3D12_RESOURCE_ALLOCATION_INFO{SizeInBytes = total, Alignment = max_align}
	}
	return out
}

device_get_alloc_info2 :: proc "system" (out: ^D3D12_RESOURCE_ALLOCATION_INFO, this: This, visible: u32, count: u32, descs: [^]D3D12_RESOURCE_DESC1, each: [^]D3D12_RESOURCE_ALLOCATION_INFO1) -> ^D3D12_RESOURCE_ALLOCATION_INFO {
	context = gpu_context()
	_ = this; _ = visible
	if out != nil {
		total: u64 = 0
		max_align: u64 = 65536
		if descs != nil {
			for i in 0 ..< count {
				sz, al := estimate_resource_bytes(descs[i].Desc)
				if al > max_align { max_align = al }
				total = (total + al - 1) & ~(al - 1)
				if each != nil {
					each[i] = D3D12_RESOURCE_ALLOCATION_INFO1{Offset = total, Alignment = al, SizeInBytes = sz}
				}
				total += sz
			}
		}
		out^ = D3D12_RESOURCE_ALLOCATION_INFO{SizeInBytes = total, Alignment = max_align}
	}
	return out
}

device_create_committed :: proc "system" (this: This, heap_props: ^D3D12_HEAP_PROPERTIES, heap_flags: u32, desc: ^D3D12_RESOURCE_DESC, state: u32, clear: rawptr, iid: ^Iid, out: ^rawptr) -> HRESULT {
	context = gpu_context()
	_ = this; _ = state; _ = clear; _ = iid
	if desc == nil || out == nil { return E_INVALIDARG }
	sz, al := estimate_resource_bytes(desc^)
	props := heap_props^ if heap_props != nil else D3D12_HEAP_PROPERTIES{Type = 1, CreationNodeMask = 1, VisibleNodeMask = 1}
	mem_ptr, attrs := alloc_gpu_memory(sz, al, props.Type)
	if mem_ptr == nil { return E_OUTOFMEMORY }
	hr := make_console_resource(desc^, props, heap_flags, u64(uintptr(mem_ptr)), true, nil, out)
	if hr >= 0 && out^ != nil {
		(cast(^Console_Resource)out^).mem_attrs = attrs
	}
	return hr
}

device_create_committed3 :: proc "system" (this: This, heap_props: ^D3D12_HEAP_PROPERTIES, heap_flags: u32, desc: ^D3D12_RESOURCE_DESC, layout: u32, clear: rawptr, protected_sess: rawptr, cast_cnt: u32, cast_fmts: rawptr, iid: ^Iid, out: ^rawptr) -> HRESULT {
	_ = layout; _ = protected_sess; _ = cast_cnt; _ = cast_fmts
	return device_create_committed(this, heap_props, heap_flags, desc, 0, clear, iid, out)
}

device_create_placed :: proc "system" (this: This, heap: This, offset: u64, desc: ^D3D12_RESOURCE_DESC, state: u32, clear: rawptr, iid: ^Iid, out: ^rawptr) -> HRESULT {
	context = gpu_context()
	_ = this; _ = state; _ = clear; _ = iid
	if heap == nil || desc == nil || out == nil { return E_INVALIDARG }
	h := cast(^Console_Heap)heap
	addr := u64(uintptr(h.base)) + offset
	return make_console_resource(desc^, h.desc.Properties, h.desc.Flags, addr, false, heap, out)
}

device_create_at_address :: proc "system" (this: This, address: u64, desc: ^D3D12_RESOURCE_DESC, layout: u32, clear: rawptr, iid: ^Iid, out: ^rawptr) -> HRESULT {
	context = gpu_context()
	_ = this; _ = layout; _ = clear; _ = iid
	if address == 0 || desc == nil || out == nil { return E_INVALIDARG }
	props := D3D12_HEAP_PROPERTIES{Type = 4, CPUPageProperty = 3, MemoryPoolPreference = 1, CreationNodeMask = 1, VisibleNodeMask = 1}
	return make_console_resource(desc^, props, 0, address, false, nil, out)
}

device_copyable_footprints :: proc "system" (this: This, desc: ^D3D12_RESOURCE_DESC, first: u32, count: u32, base_offset: u64, layouts: [^]D3D12_PLACED_SUBRESOURCE_FOOTPRINT, rows: [^]u32, row_sizes: [^]u64, total_bytes: ^u64) {
	_ = this
	if desc == nil {
		if total_bytes != nil { total_bytes^ = 0 }
		return
	}
	d := desc^
	bpp, blk := dxgi_format_bpp(d.Format)
	mips := max(u32(d.MipLevels), u32(1))
	offset := base_offset
	for i in 0 ..< count {
		sub := first + i
		mip := sub % mips
		w := max(u32(d.Width) >> mip, u32(1))
		h := max(d.Height >> mip, u32(1))
		dep := max(u32(d.DepthOrArraySize) >> mip, u32(1)) if d.Dimension == 4 else u32(1)
		bw := (w + blk - 1) / blk
		bh := (h + blk - 1) / blk
		row_bytes := u64(bw) * bpp
		row_pitch := u32((row_bytes + 255) & ~u64(255))
		offset = (offset + 511) & ~u64(511)
		if layouts != nil {
			layouts[i] = D3D12_PLACED_SUBRESOURCE_FOOTPRINT{
				Offset = offset,
				Footprint = D3D12_SUBRESOURCE_FOOTPRINT{
					Format   = d.Format,
					Width    = w,
					Height   = h,
					Depth    = dep,
					RowPitch = row_pitch,
				},
			}
		}
		if rows != nil { rows[i] = bh }
		if row_sizes != nil { row_sizes[i] = row_bytes }
		offset += u64(row_pitch) * u64(bh) * u64(dep)
	}
	if total_bytes != nil { total_bytes^ = offset - base_offset }
}

// Page pool registration (slots 74 & 75)
@(private)
g_page_pool_seq: uintptr = 1

device_register_page_pool :: proc "system" (this: This, address: u64, pages: u32, out_handle: ^uintptr) -> HRESULT {
	_ = this; _ = address; _ = pages
	if out_handle == nil || pages == 0 { return E_INVALIDARG }
	out_handle^ = intrinsics.atomic_add(&g_page_pool_seq, 1)
	return S_OK
}

device_unregister_page_pool :: proc "system" (this: This, handle: uintptr) -> HRESULT {
	_ = this; _ = handle
	return S_OK
}

// =========================================================================
// Console_Descriptor_Heap (ID3D12DescriptorHeap)
// =========================================================================

D3D12_DESCRIPTOR_HEAP_DESC :: struct {
	Type:           u32,
	NumDescriptors: u32,
	Flags:          u32,
	NodeMask:       u32,
}

D3D12X_DESCRIPTOR_HEAP_PLACEMENT :: struct {
	Address: u64,
	Size:    u64,
}

Console_Descriptor_Heap :: struct {
	object:   Gpu_Object,
	desc:     D3D12_DESCRIPTOR_HEAP_DESC,
	start:    u64,
	owns_mem: bool,
}

@(private)
g_desc_heap_vtable: [24]rawptr

@(private)
dheap_qi :: proc "system" (this: This, iid: ^Iid, out: ^This) -> HRESULT {
	context = gpu_context()
	_ = iid
	return answer_interface(this, out)
}

@(private)
dheap_release :: proc "system" (this: This) -> u32 {
	context = gpu_context()
	if this == nil { return 0 }
	rem := object_release_static(this)
	if rem == 0 {
		dh := cast(^Console_Descriptor_Heap)this
		if dh.owns_mem && dh.start != 0 {
			free_gpu_memory(rawptr(uintptr(dh.start)))
		}
		free(dh)
	}
	return rem
}

@(private)
dheap_get_desc :: proc "system" (this: This, out: ^D3D12_DESCRIPTOR_HEAP_DESC) -> ^D3D12_DESCRIPTOR_HEAP_DESC {
	if out != nil && this != nil {
		out^ = (cast(^Console_Descriptor_Heap)this).desc
	}
	return out
}

@(private)
dheap_start :: proc "system" (this: This) -> u64 {
	if this == nil { return 0 }
	return (cast(^Console_Descriptor_Heap)this).start
}

@(private)
dheap_stub :: proc "system" (this: This) -> HRESULT {
	context = gpu_context()
	_ = this
	off := decode_vtable_slot(intrinsics.return_address())
	fmt.printf("[d3d12x] DescHeap unimpl slot #%d (off=0x%X)\n", off / 8, off)
	return E_NOTIMPL
}

device_create_console_desc_heap :: proc "system" (this: This, desc_ptr: ^D3D12_DESCRIPTOR_HEAP_DESC, iid: ^Iid, out: ^rawptr) -> HRESULT {
	context = gpu_context()
	_ = this; _ = iid
	if desc_ptr == nil || out == nil { return E_INVALIDARG }
	desc := desc_ptr^
	inc := u64(descriptor_increment(desc.Type))
	if inc == 0 { inc = 32 }
	size := inc * u64(max(desc.NumDescriptors, u32(1)))

	start: u64 = 0
	owns := false
	if g_newer_device {
		// Newer titles may place (Address, Size) right after D3D12_DESCRIPTOR_HEAP_DESC.
		// Guard tightly against stack garbage when a plain D3D12_DESCRIPTOR_HEAP_DESC is passed.
		placement := (cast(^D3D12X_DESCRIPTOR_HEAP_PLACEMENT)rawptr(uintptr(desc_ptr) + size_of(D3D12_DESCRIPTOR_HEAP_DESC)))^
		if placement.Address >= 0x100000 && placement.Address < (u64(1) << 44) && placement.Size == size {
			start = placement.Address
		}
	}
	if start == 0 {
		mem_ptr, _ := alloc_gpu_memory(size, 65536, 1)
		if mem_ptr == nil { return E_OUTOFMEMORY }
		start = u64(uintptr(mem_ptr))
		owns = true
	}

	dh := new(Console_Descriptor_Heap)
	dh.object = Gpu_Object{functions = &g_desc_heap_vtable[0], bits = u32(Object_Kind.Descriptor_Heap), refs = 1}
	dh.desc = desc
	dh.start = start
	dh.owns_mem = owns
	out^ = rawptr(dh)
	return S_OK
}

// Descriptor creation & copy methods on ID3D12Device
device_create_cbv :: proc "system" (this: This, desc: rawptr, handle: u64) {
	_ = this
	if handle < 0x10000 { return }
	if uintptr(desc) >= 0x10000 {
		mem.copy(rawptr(uintptr(handle)), desc, 16)
	}
}

SRV_RECORD_TAG :: u32(0x56525376) // "vSRV"

Srv_Record :: struct {
	tag:      u32,
	format:   u32,
	resource: This,
	view_dim: u32,
	_pad:     u32,
}

#assert(size_of(Srv_Record) == 24)

device_create_srv :: proc "system" (this: This, resource: This, desc: rawptr, handle: u64) {
	_ = this
	if handle < 0x10000 { return }
	rec := cast(^Srv_Record)rawptr(uintptr(handle))
	fmt_val: u32 = 0
	dim_val: u32 = 0
	if uintptr(desc) >= 0x10000 {
		d := cast([^]u32)desc
		fmt_val = d[0]
		dim_val = d[1]
	}
	rec^ = Srv_Record{
		tag      = SRV_RECORD_TAG,
		format   = fmt_val,
		resource = resource,
		view_dim = dim_val,
	}
}

device_create_uav :: proc "system" (this: This, resource: This, counter: This, desc: rawptr, handle: u64) {
	_ = this; _ = counter
	if handle < 0x10000 { return }
	dst := cast(^[4]u64)rawptr(uintptr(handle))
	dst[0] = u64(uintptr(resource))
	dst[1] = u64(uintptr(desc))
}

RTV_RECORD_TAG :: u32(0x56545276) // "vRTV"
DSV_RECORD_TAG :: u32(0x56534476) // "vDSV"

Rtv_Record :: struct {
	tag:       u32,
	described: u32,
	resource:  This,
	desc:      [6]u32,
}

#assert(size_of(Rtv_Record) == 40)
#assert(size_of(Rtv_Record{}.desc) == 24)

device_create_rtv :: proc "system" (this: This, resource: This, desc: rawptr, handle: u64) {
	_ = this
	if handle < 0x10000 { return }
	rec := cast(^Rtv_Record)rawptr(uintptr(handle))
	rec^ = Rtv_Record{
		tag      = RTV_RECORD_TAG,
		resource = resource,
	}
	if uintptr(desc) >= 0x10000 {
		rec.described = 1
		mem.copy(&rec.desc[0], desc, size_of(rec.desc))
	}
}

device_create_dsv :: proc "system" (this: This, resource: This, desc: rawptr, handle: u64) {
	_ = this
	if handle < 0x10000 { return }
	rec := cast(^Rtv_Record)rawptr(uintptr(handle))
	rec^ = Rtv_Record{
		tag      = DSV_RECORD_TAG,
		resource = resource,
	}
	if uintptr(desc) >= 0x10000 {
		rec.described = 1
		mem.copy(&rec.desc[0], desc, size_of(rec.desc))
	}
}

device_create_sampler :: proc "system" (this: This, desc: rawptr, handle: u64) {
	_ = this
	if handle >= 0x10000 && uintptr(desc) >= 0x10000 {
		mem.copy(rawptr(uintptr(handle)), desc, 32)
	}
}

device_create_sampler_x :: proc "system" (this: This, desc: rawptr, handle: u64) {
	_ = this
	if handle >= 0x10000 && uintptr(desc) >= 0x10000 {
		mem.copy(rawptr(uintptr(handle)), desc, 32)
	}
}

device_create_placed_view :: proc "system" (this: This, res_desc: rawptr, view_desc: rawptr, handle: u64) {
	_ = this
	if handle < 0x10000 { return }
	dst := cast(^[4]u64)rawptr(uintptr(handle))
	dst[0] = u64(uintptr(res_desc))
	dst[1] = u64(uintptr(view_desc))
}

device_copy_descriptors_simple :: proc "system" (this: This, count: u32, dst: u64, src: u64, kind: u32) {
	context = gpu_context()
	_ = this
	if dst == 0 || src == 0 || count == 0 { return }
	step := u64(descriptor_increment(kind))
	if step == 0 { return }
	mem.copy(rawptr(uintptr(dst)), rawptr(uintptr(src)), int(u64(count) * step))
}

device_copy_descriptors :: proc "system" (
	this: This,
	dst_ranges: u32, dst_starts: [^]u64, dst_sizes: [^]u32,
	src_ranges: u32, src_starts: [^]u64, src_sizes: [^]u32,
	kind: u32,
) {
	context = gpu_context()
	_ = this
	if dst_ranges == 0 || src_ranges == 0 || dst_starts == nil || src_starts == nil { return }
	step := u64(descriptor_increment(kind))
	if step == 0 { return }
	di, si := u32(0), u32(0)
	doff, soff := u32(0), u32(0)
	for di < dst_ranges && si < src_ranges {
		dlen := dst_sizes[di] if dst_sizes != nil else u32(1)
		slen := src_sizes[si] if src_sizes != nil else u32(1)
		if doff >= dlen { di += 1; doff = 0; continue }
		if soff >= slen { si += 1; soff = 0; continue }
		n := min(dlen - doff, slen - soff)
		dptr := dst_starts[di] + u64(doff) * step
		sptr := src_starts[si] + u64(soff) * step
		if dptr != 0 && sptr != 0 {
			mem.copy(rawptr(uintptr(dptr)), rawptr(uintptr(sptr)), int(u64(n) * step))
		}
		doff += n
		soff += n
	}
}

// =========================================================================
// Console_Pipeline, RootSignature, QueryHeap, CommandSignature
// =========================================================================

D3D12_INPUT_ELEMENT_DESC :: struct {
	SemanticName:         cstring,
	SemanticIndex:        u32,
	Format:               u32,
	InputSlot:            u32,
	AlignedByteOffset:    u32,
	InputSlotClass:       u32,
	InstanceDataStepRate: u32,
}
#assert(size_of(D3D12_INPUT_ELEMENT_DESC) == 32)

Host_Root_Binding :: struct {
	param_idx: u32,
	kind:      u8, // 0=CBV, 1=SRV, 2=UAV
	slot:      u8,
}

Console_Pipeline :: struct #align(16) {
	object:         Gpu_Object,
	packet:         [8]u32, // +0x10..+0x30 (copied via 16-byte aligned vmovaps by title state flush!)
	is_compute:     bool,
	vs_bytes:       []u8,
	ps_bytes:       []u8,
	cs_bytes:       []u8,
	input_elems:    [dynamic]D3D12_INPUT_ELEMENT_DESC,
	input_names:    [dynamic]cstring,
	rt_formats:     [8]u32,
	num_rts:        u32,
	dsv_format:     u32,
	topology_type:  u32,
	has_blend:      bool,
	blend_desc:     D3D12_BLEND_DESC,
	has_depth:      bool,
	depth_desc:     D3D12_DEPTH_STENCIL_DESC,
	has_rast:       bool,
	rast_desc:      D3D12_RASTERIZER_DESC,
	vs_ud_param:    i32,
	vs_ud_dwords:   u32,
	ps_ud_param:        i32,
	ps_ud_dwords:       u32,
	ps_tex_table_param: i32,
	root_bindings:      [dynamic]Host_Root_Binding,
	host_attempted: bool,
	host_root:      rawptr,
	host_pso:       rawptr,
	vs_shader:      vasperty_shader.Host_Shader,
	ps_shader:      vasperty_shader.Host_Shader,
	cs_shader:      vasperty_shader.Host_Shader,
	mu:             sync.Mutex,
}

#assert(offset_of(Console_Pipeline, packet) == 0x10)

MAX_SHADER_BYTECODE :: uint(32 << 20)

Shader_Bytecode :: struct {
	code: [^]u8,
	size: uint,
}

Graphics_Head :: struct {
	root: rawptr,
	vs:   Shader_Bytecode,
	ps:   Shader_Bytecode,
	ds:   Shader_Bytecode,
	hs:   Shader_Bytecode,
	gs:   Shader_Bytecode,
}

Compute_Head :: struct {
	root: rawptr,
	cs:   Shader_Bytecode,
}

Pso_Stream_Desc :: struct {
	size:   uint,
	stream: [^]u8,
}

@(private)
copy_shader_bytecode :: proc(bc: Shader_Bytecode) -> []u8 {
	if bc.size == 0 || bc.size >= MAX_SHADER_BYTECODE || uintptr(bc.code) < 0x10000 {
		return nil
	}
	out := make([]u8, int(bc.size))
	mem.copy(&out[0], bc.code, int(bc.size))
	return out
}

@(private)
pso_stream_subobject_size :: proc "contextless" (tag: u32) -> uint {
	switch tag {
	case 0:
		return 16
	case 1 ..= 6, 23, 24:
		return 24
	case 7:
		return 40
	case 8:
		return 336
	case 9:
		return 8
	case 10:
		return 48
	case 11:
		return 56
	case 12:
		return 24
	case 13, 14:
		return 8
	case 15:
		return 40
	case 16:
		return 8
	case 17:
		return 16
	case 18, 20:
		return 8
	case 19:
		return 24
	case 21:
		return 64
	case 22:
		return 32
	}
	return 0
}

Console_Generic_Child :: struct {
	object: Gpu_Object,
	kind:   Object_Kind,
}

@(private)
g_pipeline_vtable: [24]rawptr
@(private)
g_child_vtable: [24]rawptr

@(private)
child_qi :: proc "system" (this: This, iid: ^Iid, out: ^This) -> HRESULT {
	context = gpu_context()
	_ = iid
	return answer_interface(this, out)
}

@(private)
pipeline_release :: proc "system" (this: This) -> u32 {
	context = gpu_context()
	if this == nil { return 0 }
	rem := object_release_static(this)
	if rem == 0 {
		p := cast(^Console_Pipeline)this
		if p.host_pso != nil {
			com_release(p.host_pso)
			p.host_pso = nil
		}
		if p.host_root != nil {
			com_release(p.host_root)
			p.host_root = nil
		}
		delete(p.vs_bytes)
		delete(p.ps_bytes)
		delete(p.cs_bytes)
		for s in p.input_names {
			delete(s)
		}
		delete(p.input_names)
		delete(p.input_elems)
		delete(p.root_bindings)
		vasperty_shader.destroy_host_shader(&p.vs_shader)
		vasperty_shader.destroy_host_shader(&p.ps_shader)
		vasperty_shader.destroy_host_shader(&p.cs_shader)
		free(p)
	}
	return rem
}

@(private)
child_release :: proc "system" (this: This) -> u32 {
	context = gpu_context()
	if this == nil { return 0 }
	rem := object_release_static(this)
	if rem == 0 {
		free(cast(^Console_Generic_Child)this)
	}
	return rem
}

@(private)
child_stub :: proc "system" (this: This) -> HRESULT {
	context = gpu_context()
	_ = this
	off := decode_vtable_slot(intrinsics.return_address())
	fmt.printf("[d3d12x] Child unimpl slot #%d (off=0x%X)\n", off / 8, off)
	return S_OK
}

@(private)
make_console_pipeline :: proc(out: ^rawptr) -> HRESULT {
	if out == nil { return E_POINTER }
	p := new(Console_Pipeline)
	p.object = Gpu_Object{functions = &g_pipeline_vtable[0], bits = u32(Object_Kind.Pipeline), refs = 1}
	out^ = rawptr(p)
	return S_OK
}

@(private)
make_console_child :: proc(kind: Object_Kind, out: ^rawptr) -> HRESULT {
	if out == nil { return E_POINTER }
	c := new(Console_Generic_Child)
	c.object = Gpu_Object{functions = &g_child_vtable[0], bits = u32(kind), refs = 1}
	c.kind = kind
	out^ = rawptr(c)
	return S_OK
}

device_create_graphics_pso :: proc "system" (this: This, desc: rawptr, iid: ^Iid, out: ^rawptr) -> HRESULT {
	context = gpu_context()
	_ = this; _ = iid
	hr := make_console_pipeline(out)
	if hr < 0 || out == nil || out^ == nil {
		return hr
	}
	p := cast(^Console_Pipeline)out^
	p.is_compute = false
	if uintptr(desc) >= 0x10000 {
		head := (cast(^Graphics_Head)desc)^
		p.vs_bytes = copy_shader_bytecode(head.vs)
		p.ps_bytes = copy_shader_bytecode(head.ps)
	}
	return S_OK
}

device_create_compute_pso :: proc "system" (this: This, desc: rawptr, iid: ^Iid, out: ^rawptr) -> HRESULT {
	context = gpu_context()
	_ = this; _ = iid
	hr := make_console_pipeline(out)
	if hr < 0 || out == nil || out^ == nil {
		return hr
	}
	p := cast(^Console_Pipeline)out^
	p.is_compute = true
	if uintptr(desc) >= 0x10000 {
		head := (cast(^Compute_Head)desc)^
		p.cs_bytes = copy_shader_bytecode(head.cs)
	}
	return S_OK
}

device_create_compute_pso_x :: proc "system" (this: This, desc: rawptr, ext_cnt: u32, ext: rawptr, iid: ^Iid, out: ^rawptr) -> HRESULT {
	context = gpu_context()
	_ = this; _ = ext_cnt; _ = ext; _ = iid
	hr := make_console_pipeline(out)
	if hr < 0 || out == nil || out^ == nil {
		return hr
	}
	p := cast(^Console_Pipeline)out^
	p.is_compute = true
	if uintptr(desc) >= 0x10000 {
		head := (cast(^Compute_Head)desc)^
		p.cs_bytes = copy_shader_bytecode(head.cs)
	}
	return S_OK
}

device_create_pso_stream :: proc "system" (this: This, desc: rawptr, iid: ^Iid, out: ^rawptr) -> HRESULT {
	context = gpu_context()
	_ = this; _ = iid
	hr := make_console_pipeline(out)
	if hr < 0 || out == nil || out^ == nil {
		return hr
	}
	p := cast(^Console_Pipeline)out^
	if uintptr(desc) >= 0x10000 {
		sd := (cast(^Pso_Stream_Desc)desc)^
		if sd.size >= 8 && sd.size < (16 << 20) && uintptr(sd.stream) >= 0x10000 {
			off := uint(0)
			for off + 8 <= sd.size {
				base := uintptr(sd.stream) + uintptr(off)
				tag := (cast(^u32)rawptr(base))^
				sub_size := pso_stream_subobject_size(tag)
				if sub_size == 0 || off + sub_size > sd.size {
					break
				}
				switch tag {
				case 1: // VS
					if len(p.vs_bytes) == 0 {
						bc := (cast(^Shader_Bytecode)rawptr(base + 8))^
						p.vs_bytes = copy_shader_bytecode(bc)
					}
				case 2: // PS
					if len(p.ps_bytes) == 0 {
						bc := (cast(^Shader_Bytecode)rawptr(base + 8))^
						p.ps_bytes = copy_shader_bytecode(bc)
					}
				case 6: // CS
					if len(p.cs_bytes) == 0 {
						bc := (cast(^Shader_Bytecode)rawptr(base + 8))^
						p.cs_bytes = copy_shader_bytecode(bc)
					}
				case 8: // BlendState
					p.blend_desc = (cast(^D3D12_BLEND_DESC)rawptr(base + 4))^
					p.has_blend = true
				case 10: // RasterizerState
					p.rast_desc = (cast(^D3D12_RASTERIZER_DESC)rawptr(base + 4))^
					p.has_rast = true
				case 11: // DepthStencilState
					p.depth_desc = (cast(^D3D12_DEPTH_STENCIL_DESC)rawptr(base + 4))^
					p.has_depth = true
				case 21: // DepthStencilState1 (first fields match D3D12_DEPTH_STENCIL_DESC)
					p.depth_desc = (cast(^D3D12_DEPTH_STENCIL_DESC)rawptr(base + 4))^
					p.has_depth = true
				case 12: // InputLayout (D3D12_INPUT_LAYOUT_DESC at +8)
					il_ptr := (cast(^rawptr)rawptr(base + 8))^
					il_cnt := (cast(^u32)rawptr(base + 16))^
					if uintptr(il_ptr) >= 0x10000 && il_cnt > 0 && il_cnt <= 32 {
						elems := cast([^]D3D12_INPUT_ELEMENT_DESC)il_ptr
						for ei in 0 ..< il_cnt {
							e := elems[ei]
							e.Format = map_host_texture_format(e.Format)
							if uintptr(rawptr(e.SemanticName)) >= 0x10000 {
								cs := strings.clone_to_cstring(string(e.SemanticName))
								append(&p.input_names, cs)
								e.SemanticName = cs
							}
							append(&p.input_elems, e)
						}
					}
				case 14: // PrimitiveTopologyType
					p.topology_type = (cast(^u32)rawptr(base + 4))^
				case 15: // RTFormats
					fmts := (cast(^[8]u32)rawptr(base + 4))^
					n_rts := (cast(^u32)rawptr(base + 36))^
					p.rt_formats = fmts
					p.num_rts = min(n_rts, u32(8))
				case 16: // DSVFormat
					p.dsv_format = (cast(^u32)rawptr(base + 4))^
				}
				off += sub_size
			}
		}
		if len(p.cs_bytes) > 0 && len(p.vs_bytes) == 0 && len(p.ps_bytes) == 0 {
			p.is_compute = true
		}
	}
	return S_OK
}

device_create_console_root_sig :: proc "system" (this: This, node_mask: u32, blob: rawptr, blob_len: uint, iid: ^Iid, out: ^rawptr) -> HRESULT {
	context = gpu_context()
	_ = this; _ = node_mask; _ = blob; _ = blob_len; _ = iid
	return make_console_child(.Root_Signature, out)
}

device_create_query_heap :: proc "system" (this: This, desc: rawptr, iid: ^Iid, out: ^rawptr) -> HRESULT {
	context = gpu_context()
	_ = this; _ = desc; _ = iid
	return make_console_child(.Query_Heap, out)
}

device_create_cmd_sig :: proc "system" (this: This, desc: rawptr, root_sig: rawptr, iid: ^Iid, out: ^rawptr) -> HRESULT {
	context = gpu_context()
	_ = this; _ = desc; _ = root_sig; _ = iid
	return make_console_child(.Command_Signature, out)
}

// =========================================================================
// Vtable Initialization
// =========================================================================

@(init)
init_console_resource_vtables :: proc "contextless" () {
	// Heap
	for i in 0 ..< len(g_heap_vtable) { g_heap_vtable[i] = rawptr(heap_stub) }
	fill_d3d12_object_slots(g_heap_vtable[:], rawptr(heap_qi), rawptr(heap_release))
	g_heap_vtable[7] = rawptr(object_parent_device)
	g_heap_vtable[8] = rawptr(heap_get_desc)

	// Resource
	for i in 0 ..< len(g_resource_vtable) { g_resource_vtable[i] = rawptr(res_stub) }
	fill_d3d12_object_slots(g_resource_vtable[:], rawptr(res_qi), rawptr(res_release))
	g_resource_vtable[7] = rawptr(object_parent_device)
	g_resource_vtable[8] = rawptr(res_map)
	g_resource_vtable[9] = rawptr(res_unmap)
	g_resource_vtable[10] = rawptr(res_get_desc)
	g_resource_vtable[11] = rawptr(res_gpu_address)
	g_resource_vtable[14] = rawptr(res_heap_properties)

	// Descriptor Heap
	for i in 0 ..< len(g_desc_heap_vtable) { g_desc_heap_vtable[i] = rawptr(dheap_stub) }
	fill_d3d12_object_slots(g_desc_heap_vtable[:], rawptr(dheap_qi), rawptr(dheap_release))
	g_desc_heap_vtable[7] = rawptr(object_parent_device)
	g_desc_heap_vtable[8] = rawptr(dheap_get_desc)
	g_desc_heap_vtable[9] = rawptr(dheap_start)
	g_desc_heap_vtable[10] = rawptr(dheap_start)

	// Pipeline & Generic Child
	for i in 0 ..< len(g_pipeline_vtable) {
		g_pipeline_vtable[i] = rawptr(child_stub)
		g_child_vtable[i] = rawptr(child_stub)
	}
	fill_d3d12_object_slots(g_pipeline_vtable[:], rawptr(child_qi), rawptr(pipeline_release))
	g_pipeline_vtable[7] = rawptr(object_parent_device)
	fill_d3d12_object_slots(g_child_vtable[:], rawptr(child_qi), rawptr(child_release))
	g_child_vtable[7] = rawptr(object_parent_device)
}
