package vasperty_gpu

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:sync"
import vasperty_hle "vasperty:hle"

HRESULT :: vasperty_hle.HRESULT
S_OK :: vasperty_hle.S_OK
S_FALSE :: HRESULT(1)
E_NOTIMPL :: vasperty_hle.E_NOTIMPL
E_NOINTERFACE :: vasperty_hle.E_NOINTERFACE
E_POINTER :: vasperty_hle.E_POINTER
E_INVALIDARG :: vasperty_hle.E_INVALIDARG
E_OUTOFMEMORY :: vasperty_hle.E_OUTOFMEMORY
DXGI_ERROR_NOT_FOUND :: HRESULT(-2005270526) // 0x887A0002
DXGI_ERROR_MORE_DATA :: HRESULT(-2005270525) // 0x887A0003
DXGI_ERROR_UNSUPPORTED :: HRESULT(-2005270524) // 0x887A0004

Iid :: [16]u8

guid :: proc "contextless" (a: u32, b, c: u16, d: [8]u8) -> Iid {
	return Iid{
		u8(a), u8(a >> 8), u8(a >> 16), u8(a >> 24),
		u8(b), u8(b >> 8),
		u8(c), u8(c >> 8),
		d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7],
	}
}

guid_text :: proc(g: Iid, allocator := context.allocator) -> string {
	a := u32(g[0]) | (u32(g[1]) << 8) | (u32(g[2]) << 16) | (u32(g[3]) << 24)
	b := u16(g[4]) | (u16(g[5]) << 8)
	c := u16(g[6]) | (u16(g[7]) << 8)
	return fmt.aprintf(
		"%08x-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x",
		a, b, c,
		g[8], g[9], g[10], g[11], g[12], g[13], g[14], g[15],
		allocator = allocator,
	)
}

IID_IUNKNOWN :: Iid{0, 0, 0, 0, 0, 0, 0, 0, 0xC0, 0, 0, 0, 0, 0, 0, 0x46}

Object_Kind :: enum u8 {
	Device,
	Dxgi_Device,
	Adapter,
	Factory,
	Output,
	Queue,
	Allocator,
	List,
	Fence,
	Descriptor_Heap,
	Heap,
	Resource,
	Root_Signature,
	Pipeline,
	Query_Heap,
	Command_Signature,
}

Gpu_Object :: struct {
	functions: ^rawptr,
	bits:      u32,
	refs:      u32,
}

This :: ^Gpu_Object

is_iid :: proc(iid: ^Iid, known: []Iid) -> bool {
	if iid == nil {
		return false
	}
	v := iid^
	if v == IID_IUNKNOWN {
		return true
	}
	for k in known {
		if k == v {
			return true
		}
	}
	return false
}

object_add_ref :: proc "system" (this: This) -> u32 {
	if this == nil {
		return 0
	}
	return intrinsics.atomic_add(&this.refs, 1) + 1
}

object_release_static :: proc "system" (this: This) -> u32 {
	if this == nil {
		return 0
	}
	for {
		cur := intrinsics.atomic_load(&this.refs)
		if cur == 0 {
			return 0
		}
		_, ok := intrinsics.atomic_compare_exchange_weak(&this.refs, cur, cur - 1)
		if ok {
			return cur - 1
		}
	}
}

answer_interface :: proc(found: This, out: ^This) -> HRESULT {
	if out == nil {
		return E_POINTER
	}
	if found != nil {
		object_add_ref(found)
		out^ = found
		return S_OK
	}
	out^ = nil
	return E_NOINTERFACE
}

// =========================================================================
// Allocator context for "system" callbacks & cleanup state
// =========================================================================

@(private)
g_gpu_alloc: runtime.Allocator

gpu_set_allocator :: proc(alloc: runtime.Allocator) {
	g_gpu_alloc = alloc
}

@(private)
gpu_context :: proc "contextless" () -> runtime.Context {
	ctx := runtime.default_context()
	if g_gpu_alloc.procedure != nil {
		ctx.allocator = g_gpu_alloc
	}
	return ctx
}

// Private data store keyed by (object pointer, Iid)
Private_Key :: struct {
	obj: uintptr,
	id:  Iid,
}

@(private)
g_priv_mu: sync.Mutex
@(private)
g_priv_data: map[Private_Key][dynamic]u8

init_gpu_objects :: proc() {
	g_gpu_alloc = context.allocator
	sync.mutex_lock(&g_priv_mu)
	defer sync.mutex_unlock(&g_priv_mu)
	if g_priv_data == nil {
		g_priv_data = make(map[Private_Key][dynamic]u8)
	}
}

fini_gpu_objects :: proc() {
	sync.mutex_lock(&g_priv_mu)
	defer sync.mutex_unlock(&g_priv_mu)
	for _, buf in g_priv_data {
		delete(buf)
	}
	delete(g_priv_data)
	g_priv_data = nil
}

object_set_private_data :: proc "system" (this: This, id: ^Iid, data_size: u32, data: rawptr) -> HRESULT {
	context = gpu_context()
	if uintptr(id) < 0x10000 {
		return E_INVALIDARG
	}
	key := Private_Key{obj = uintptr(this), id = id^}
	sync.mutex_lock(&g_priv_mu)
	defer sync.mutex_unlock(&g_priv_mu)
	if g_priv_data == nil {
		g_priv_data = make(map[Private_Key][dynamic]u8)
	}
	if prev, ok := g_priv_data[key]; ok {
		delete(prev)
		delete_key(&g_priv_data, key)
	}
	if data_size == 0 || data == nil {
		return S_OK
	}
	buf := make([dynamic]u8, int(data_size))
	src := ([^]u8)(data)[:int(data_size)]
	copy(buf[:], src)
	g_priv_data[key] = buf
	return S_OK
}

object_set_private_data_interface :: proc "system" (this: This, id: ^Iid, iface: rawptr) -> HRESULT {
	_ = this; _ = id; _ = iface
	return S_OK
}

object_set_name :: proc "system" (this: This, name: rawptr) -> HRESULT {
	_ = this; _ = name
	return S_OK
}

object_parent_device :: proc "system" (this: This, iid: ^Iid, out: ^This) -> HRESULT {
	context = gpu_context()
	_ = this
	return device_qi(cast(This)&g_device, iid, out)
}

object_get_private_data :: proc "system" (this: This, id: ^Iid, data_size: ^u32, data: rawptr) -> HRESULT {
	context = gpu_context()
	if id == nil || data_size == nil {
		return E_INVALIDARG
	}
	key := Private_Key{obj = uintptr(this), id = id^}
	sync.mutex_lock(&g_priv_mu)
	defer sync.mutex_unlock(&g_priv_mu)
	buf, ok := g_priv_data[key]
	if !ok {
		data_size^ = 0
		return DXGI_ERROR_NOT_FOUND
	}
	need := u32(len(buf))
	room := data_size^
	data_size^ = need
	if data == nil {
		return S_OK
	}
	if room < need {
		return DXGI_ERROR_MORE_DATA
	}
	copy(([^]u8)(data)[:int(need)], buf[:])
	return S_OK
}

// =========================================================================
// Title memory dirty-page & alias tracking (`watch`)
// =========================================================================

GPU_PAGE_BYTES :: uint(64 << 10)
DIRTY_WORDS :: 1 << 10 // 65536 trackers across 1K u64s

@(private)
g_watch_mu: sync.Mutex
@(private)
g_watch_dirty: [DIRTY_WORDS]u64
@(private)
g_watch_aliases: map[uintptr][dynamic]uintptr
@(private)
g_watch_guards: map[uintptr]uint // guarded base -> byte span

init_watch :: proc() {
	sync.mutex_lock(&g_watch_mu)
	defer sync.mutex_unlock(&g_watch_mu)
	for i in 0 ..< DIRTY_WORDS {
		g_watch_dirty[i] = 0
	}
	if g_watch_aliases == nil {
		g_watch_aliases = make(map[uintptr][dynamic]uintptr)
	}
	if g_watch_guards == nil {
		g_watch_guards = make(map[uintptr]uint)
	}
}

fini_watch :: proc() {
	sync.mutex_lock(&g_watch_mu)
	defer sync.mutex_unlock(&g_watch_mu)
	for _, list in g_watch_aliases {
		delete(list)
	}
	delete(g_watch_aliases)
	g_watch_aliases = nil
	delete(g_watch_guards)
	g_watch_guards = nil
}

watch_set_bit :: proc(bit: u32, dirty: bool) {
	if bit >= u32(DIRTY_WORDS * 64) {
		return
	}
	w := &g_watch_dirty[bit / 64]
	mask := u64(1) << (bit % 64)
	if dirty {
		intrinsics.atomic_or(w, mask)
	} else {
		intrinsics.atomic_and(w, ~mask)
	}
}

watch_clean_bit :: proc(bit: u32) -> bool {
	if bit >= u32(DIRTY_WORDS * 64) {
		return false
	}
	w := intrinsics.atomic_load(&g_watch_dirty[bit / 64])
	return ((w >> (bit % 64)) & 1) == 0
}

watch_kernel_will_write :: proc(addr: uintptr, span: uint) -> uintptr {
	sync.mutex_lock(&g_watch_mu)
	defer sync.mutex_unlock(&g_watch_mu)
	// Record guarded region touched so copy tracking stays coherent
	page_base := addr & ~uintptr(GPU_PAGE_BYTES - 1)
	if g_watch_guards != nil {
		g_watch_guards[page_base] = max(g_watch_guards[page_base], span)
	}
	return page_base
}

watch_kernel_end_write :: proc(token: uintptr) {
	_ = token
}

watch_memory_remapped :: proc(base: uintptr, span: uint) {
	sync.mutex_lock(&g_watch_mu)
	defer sync.mutex_unlock(&g_watch_mu)
	if g_watch_guards != nil {
		g_watch_guards[base] = span
	}
}

watch_memory_aliased :: proc(alias: uintptr, backing: uintptr) {
	sync.mutex_lock(&g_watch_mu)
	defer sync.mutex_unlock(&g_watch_mu)
	if g_watch_aliases == nil {
		g_watch_aliases = make(map[uintptr][dynamic]uintptr)
	}
	if _, ok := g_watch_aliases[backing]; !ok {
		g_watch_aliases[backing] = make([dynamic]uintptr)
	}
	append(&g_watch_aliases[backing], alias)
}

watch_alias_count :: proc(backing: uintptr) -> int {
	sync.mutex_lock(&g_watch_mu)
	defer sync.mutex_unlock(&g_watch_mu)
	if list, ok := g_watch_aliases[backing]; ok {
		return len(list)
	}
	return 0
}

// =========================================================================
// Placed heap free-range allocator (`placement`)
// =========================================================================

PLACEMENT_HEAP_BYTES :: u64(64 << 20)
PLACEMENT_ALIGN :: u64(64 << 10)

Free_Range :: struct {
	offset: u64,
	len:    u64,
}

Placed_Heap :: struct {
	id:   u64,
	size: u64,
	free: [dynamic]Free_Range,
}

Placement_Allocator :: struct {
	heaps:   [dynamic]Placed_Heap,
	next_id: u64,
}

placement_init :: proc() -> Placement_Allocator {
	return Placement_Allocator{
		heaps   = make([dynamic]Placed_Heap),
		next_id = 1,
	}
}

placement_destroy :: proc(pa: ^Placement_Allocator) {
	for &h in pa.heaps {
		delete(h.free)
	}
	delete(pa.heaps)
	pa^ = {}
}

placement_alloc :: proc(pa: ^Placement_Allocator, bytes, align_in: u64) -> (heap_id, offset: u64, ok: bool) {
	align := max(PLACEMENT_ALIGN, align_in)
	size_aligned := (bytes + align - 1) & ~(align - 1)
	if size_aligned == 0 {
		size_aligned = align
	}
	for &h in pa.heaps {
		for idx in 0 ..< len(h.free) {
			fr := h.free[idx]
			at := (fr.offset + align - 1) & ~(align - 1)
			if at + size_aligned <= fr.offset + fr.len {
				end := fr.offset + fr.len
				ordered_remove(&h.free, idx)
				if at > fr.offset {
					inject_at(&h.free, idx, Free_Range{offset = fr.offset, len = at - fr.offset})
				}
				if at + size_aligned < end {
					ins := idx + (1 if at > fr.offset else 0)
					inject_at(&h.free, ins, Free_Range{offset = at + size_aligned, len = end - (at + size_aligned)})
				}
				return h.id, at, true
			}
		}
	}
	// Open a new heap
	cap_bytes := max(PLACEMENT_HEAP_BYTES, size_aligned)
	id := pa.next_id
	pa.next_id += 1
	nh := Placed_Heap{
		id   = id,
		size = cap_bytes,
		free = make([dynamic]Free_Range),
	}
	if size_aligned < cap_bytes {
		append(&nh.free, Free_Range{offset = size_aligned, len = cap_bytes - size_aligned})
	}
	append(&pa.heaps, nh)
	return id, 0, true
}

placement_free :: proc(pa: ^Placement_Allocator, heap_id, offset, bytes, align_in: u64) {
	align := max(PLACEMENT_ALIGN, align_in)
	size_aligned := (bytes + align - 1) & ~(align - 1)
	if size_aligned == 0 {
		size_aligned = align
	}
	for &h in pa.heaps {
		if h.id != heap_id {
			continue
		}
		start := offset
		end := offset + size_aligned
		// Insert sorted & coalesce with neighbors
		pos := 0
		for pos < len(h.free) && h.free[pos].offset < start {
			pos += 1
		}
		if pos > 0 && h.free[pos - 1].offset + h.free[pos - 1].len == start {
			h.free[pos - 1].len += size_aligned
			if pos < len(h.free) && h.free[pos - 1].offset + h.free[pos - 1].len == h.free[pos].offset {
				h.free[pos - 1].len += h.free[pos].len
				ordered_remove(&h.free, pos)
			}
			return
		}
		if pos < len(h.free) && end == h.free[pos].offset {
			h.free[pos].offset = start
			h.free[pos].len += size_aligned
			return
		}
		inject_at(&h.free, pos, Free_Range{offset = start, len = size_aligned})
		return
	}
}
