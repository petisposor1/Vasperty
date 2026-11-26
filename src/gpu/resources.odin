package vasperty_gpu

import "base:intrinsics"
import "core:fmt"
import "core:sync"
import win32 "core:sys/windows"
import vasperty_hle "vasperty:hle"

// =========================================================================
// Console D3D12.X Device & Virtual Memory
// =========================================================================

CHECKED_DEVICE_VERSION :: u32(0x0002_0004)
HIGHEST_FEATURE_LEVEL :: u32(0xC200)

DEVICE_LEVEL_IIDS := [?]Iid{
	guid(0x77acce80, 0x638e, 0x4e65, {0x88, 0x95, 0xc1, 0xf2, 0x33, 0x86, 0x86, 0x3e}),
	guid(0x30baa41e, 0xb15b, 0x475c, {0xa0, 0xbb, 0x1a, 0xf5, 0xc5, 0xb6, 0x43, 0x28}),
	guid(0x81dadc15, 0x2bad, 0x4392, {0x93, 0xc5, 0x10, 0x13, 0x45, 0xc4, 0xaa, 0x98}),
	guid(0xe865df17, 0xa9ee, 0x46f9, {0xa4, 0x63, 0x30, 0x98, 0x31, 0x5a, 0xa2, 0xe5}),
	guid(0x8b4f173b, 0x2fea, 0x4b80, {0x8f, 0x58, 0x43, 0x07, 0x19, 0x1a, 0xb9, 0x5d}),
	guid(0xc70b221b, 0x40e4, 0x4a17, {0x89, 0xaf, 0x02, 0x5a, 0x07, 0x27, 0xa6, 0xdc}),
	guid(0x5c014b53, 0x68a1, 0x4b9b, {0x8b, 0xd1, 0xdd, 0x60, 0x46, 0xb9, 0x35, 0x8b}),
	guid(0x728f1fa2, 0xea11, 0x4a9f, {0x9b, 0x52, 0x9b, 0x42, 0xa4, 0x84, 0xd5, 0xc9}),
	guid(0x5405c344, 0xd457, 0x444e, {0xb4, 0xdd, 0x23, 0x66, 0xe4, 0x5a, 0xee, 0x39}),
}

Console_Device :: struct {
	object:               Gpu_Object,
	null_constant_buffer: u64,
	out_of_line:          [16]u32,
}

#assert(size_of(Console_Device) == 0x58)

@(private)
device_stub_slot :: proc "system" (this: This, a1, a2, a3: uintptr) -> HRESULT {
	context = gpu_context()
	_ = this; _ = a1; _ = a2; _ = a3
	return E_NOTIMPL
}

@(private)
device_get_desc_inc :: proc "system" (this: This, kind: u32) -> u32 {
	context = gpu_context()
	_ = this
	return descriptor_increment(kind)
}

@(private)
device_check_feature_support :: proc "system" (this: This, feature: u32, data: rawptr, size: u32) -> HRESULT {
	context = gpu_context()
	_ = this
	fmt.printf("[d3d12x] CheckFeatureSupport(feature=%d, size=%d)\n", feature, size)
	if data == nil || size == 0 {
		return E_INVALIDARG
	}
	// Forward to real host ID3D12Device when available
	dlls := ensure_d3d12_dlls()
	if dlls.create_device != nil {
		D3D_FEATURE_LEVEL_12_0 :: u32(0xC000)
		dev_iid := guid(0x189819f1, 0x1db6, 0x4b57, {0xbe, 0x54, 0x18, 0x21, 0x33, 0x9b, 0x85, 0xf7})
		hdev: rawptr
		if dlls.create_device(nil, D3D_FEATURE_LEVEL_12_0, &dev_iid, &hdev) >= 0 && hdev != nil {
			defer com_release(hdev)
			Dev_Cfs_Vtbl :: struct {
				_pad:                [13]rawptr,
				CheckFeatureSupport: proc "system" (rawptr, u32, rawptr, u32) -> HRESULT,
			}
			vt := (cast(^^Dev_Cfs_Vtbl)hdev)^
			return vt.CheckFeatureSupport(hdev, feature, data, size)
		}
	}
	return E_NOTIMPL
}

@(private)
g_device_vtable: [96]rawptr

@(init)
init_device_vtable :: proc "contextless" () {
	for i in 0 ..< len(g_device_vtable) {
		g_device_vtable[i] = rawptr(device_stub_slot)
	}
	g_device_vtable[0] = rawptr(device_qi)
	g_device_vtable[1] = rawptr(object_add_ref)
	g_device_vtable[2] = rawptr(object_release_static)
	g_device_vtable[3] = rawptr(object_get_private_data)
	g_device_vtable[4] = rawptr(object_set_private_data)
	g_device_vtable[7] = rawptr(device_get_node_count)
	g_device_vtable[13] = rawptr(device_check_feature_support)
	g_device_vtable[15] = rawptr(device_get_desc_inc)
}

g_device := Console_Device{
	object      = Gpu_Object{functions = &g_device_vtable[0], bits = 0, refs = 1},
	out_of_line = {1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
}

g_newer_device: bool = false

device_qi :: proc "system" (this: This, iid: ^Iid, out: ^This) -> HRESULT {
	context = gpu_context()
	dev_id := IID_ID3D12Device
	if is_iid(iid, {dev_id}) || is_iid(iid, DEVICE_LEVEL_IIDS[:]) {
		return answer_interface(this, out)
	}
	return answer_interface(nil, out)
}

device_get_node_count :: proc "system" (this: This) -> u32 {
	_ = this
	return 1
}

console_create_device :: proc "system" (adapter: rawptr, parameters: ^u32, iid: ^vasperty_hle.Guid, out: ^rawptr) -> HRESULT {
	context = gpu_context()
	_ = adapter
	if parameters == nil || iid == nil {
		return E_INVALIDARG
	}
	raw_iid := cast(^Iid)iid
	dev_id := IID_ID3D12Device
	if !is_iid(raw_iid, {dev_id}) && !is_iid(raw_iid, DEVICE_LEVEL_IIDS[:]) {
		return E_NOINTERFACE
	}
	if out == nil {
		return S_FALSE
	}
	if raw_iid^ == DEVICE_LEVEL_IIDS[8] {
		g_newer_device = true
	}
	return answer_interface(cast(This)&g_device, cast(^This)out)
}

Virtual_Memory_X :: struct {
	flags:            u32,
	page_table_pages: u32,
	preserved_bytes:  u32,
	lowest:           u64,
	highest:          u64,
}

#assert(size_of(Virtual_Memory_X) == 0x20)

console_configure_virtual_memory :: proc "system" (reserved: rawptr, count: u32, ranges: rawptr) -> HRESULT {
	_ = count
	_ = ranges
	if reserved == nil {
		return E_INVALIDARG
	}
	vm := cast(^Virtual_Memory_X)reserved
	vm.lowest = 0x1_0000
	vm.highest = 0x0000_7FFF_FFFF_0000
	return S_OK
}

// =========================================================================
// Descriptor Heap Virtualization (`Host_Heap`)
// =========================================================================

HEAP_KIND_CBV_SRV_UAV :: u32(0)
HEAP_KIND_SAMPLER :: u32(1)
HEAP_KIND_RTV :: u32(2)
HEAP_KIND_DSV :: u32(3)

descriptor_increment :: proc(kind: u32) -> u32 {
	switch kind {
	case HEAP_KIND_CBV_SRV_UAV: return 32
	case HEAP_KIND_SAMPLER:     return 16
	case HEAP_KIND_RTV, HEAP_KIND_DSV: return 128
	}
	return 32
}

Host_Heap :: struct {
	mu:            sync.Mutex,
	sampler:       bool,
	count:         u32,
	dyn_slots:     u32,
	step:          u32,
	made:          []u64,
	strides:       []u32,
	marks:         [][2]u32,
	addresses:     [][4]u32,
	next_dyn:      u32,
	next_pair:     u32,
	free_pairs:    [dynamic]u32,
}

host_heap_create :: proc(sampler: bool, count: u32, dyn_slots := u32(256)) -> ^Host_Heap {
	h := new(Host_Heap)
	h.sampler = sampler
	h.count = count
	h.dyn_slots = 0 if sampler else dyn_slots
	h.step = 16 if sampler else 32
	total := int(count + h.dyn_slots)
	h.made = make([]u64, total)
	if !sampler {
		h.strides = make([]u32, int(count))
		h.marks = make([][2]u32, int(count))
		h.addresses = make([][4]u32, int(count))
		for i in 0 ..< int(count) {
			h.marks[i] = {0xFFFF_FFFF, 0}
		}
	}
	h.next_pair = count + h.dyn_slots
	h.free_pairs = make([dynamic]u32)
	return h
}

host_heap_destroy :: proc(h: ^Host_Heap) {
	if h == nil {
		return
	}
	delete(h.made)
	delete(h.strides)
	delete(h.marks)
	delete(h.addresses)
	delete(h.free_pairs)
	free(h)
}

host_heap_set_view_stride :: proc(h: ^Host_Heap, slot: u32, stride_word: u32) {
	if h == nil || h.sampler || int(slot) >= len(h.strides) {
		return
	}
	sync.mutex_lock(&h.mu)
	defer sync.mutex_unlock(&h.mu)
	h.strides[slot] = stride_word
}

host_heap_alloc_dyn :: proc(h: ^Host_Heap) -> (u32, bool) {
	if h == nil || h.dyn_slots == 0 {
		return 0, false
	}
	sync.mutex_lock(&h.mu)
	defer sync.mutex_unlock(&h.mu)
	slot := h.next_dyn
	h.next_dyn = (h.next_dyn + 1) % h.dyn_slots
	return h.count + slot, true
}

host_heap_alloc_pair :: proc(h: ^Host_Heap) -> u32 {
	sync.mutex_lock(&h.mu)
	defer sync.mutex_unlock(&h.mu)
	if len(h.free_pairs) > 0 {
		p := h.free_pairs[len(h.free_pairs) - 1]
		pop(&h.free_pairs)
		return p
	}
	p := h.next_pair
	h.next_pair += 2
	return p
}

host_heap_free_pair :: proc(h: ^Host_Heap, base_slot: u32) {
	sync.mutex_lock(&h.mu)
	defer sync.mutex_unlock(&h.mu)
	append(&h.free_pairs, base_slot)
}

// =========================================================================
// Title-Memory Page Table (`memory`)
// =========================================================================

MEM_PAGE_SIZE :: u64(64 << 10)
MEM_BLOCK_PAGES :: 4096
MEM_LEVEL1_BLOCKS :: 4096

Page_Table_Entry :: struct {
	srv_heap_slot: u32,
	title_lo:      u32,
}

Page_Table :: struct {
	mu:     sync.Mutex,
	l1:     []u32,
	blocks: [dynamic][]Page_Table_Entry,
}

page_table_create :: proc() -> ^Page_Table {
	pt := new(Page_Table)
	pt.l1 = make([]u32, MEM_LEVEL1_BLOCKS)
	pt.blocks = make([dynamic][]Page_Table_Entry)
	// Block 0 is the null block (index 0)
	append(&pt.blocks, make([]Page_Table_Entry, MEM_BLOCK_PAGES))
	return pt
}

page_table_destroy :: proc(pt: ^Page_Table) {
	if pt == nil {
		return
	}
	delete(pt.l1)
	for blk in pt.blocks {
		delete(blk)
	}
	delete(pt.blocks)
	free(pt)
}

page_table_map_range :: proc(pt: ^Page_Table, title_addr: u64, byte_len: u64, srv_slot: u32) {
	if pt == nil || byte_len == 0 {
		return
	}
	sync.mutex_lock(&pt.mu)
	defer sync.mutex_unlock(&pt.mu)
	start_page := title_addr / MEM_PAGE_SIZE
	end_page := (title_addr + byte_len - 1) / MEM_PAGE_SIZE
	for pg := start_page; pg <= end_page; pg += 1 {
		l1_idx := int(pg / u64(MEM_BLOCK_PAGES))
		l2_idx := int(pg % u64(MEM_BLOCK_PAGES))
		if l1_idx >= MEM_LEVEL1_BLOCKS {
			break
		}
		blk_idx := pt.l1[l1_idx]
		if blk_idx == 0 {
			blk_idx = u32(len(pt.blocks))
			pt.l1[l1_idx] = blk_idx
			append(&pt.blocks, make([]Page_Table_Entry, MEM_BLOCK_PAGES))
		}
		pt.blocks[blk_idx][l2_idx] = Page_Table_Entry{
			srv_heap_slot = srv_slot,
			title_lo      = u32(title_addr),
		}
	}
}

page_table_lookup :: proc(pt: ^Page_Table, title_addr: u64) -> (Page_Table_Entry, bool) {
	if pt == nil {
		return {}, false
	}
	sync.mutex_lock(&pt.mu)
	defer sync.mutex_unlock(&pt.mu)
	pg := title_addr / MEM_PAGE_SIZE
	l1_idx := int(pg / u64(MEM_BLOCK_PAGES))
	l2_idx := int(pg % u64(MEM_BLOCK_PAGES))
	if l1_idx >= MEM_LEVEL1_BLOCKS {
		return {}, false
	}
	blk_idx := pt.l1[l1_idx]
	if blk_idx == 0 {
		return {}, false
	}
	ent := pt.blocks[blk_idx][l2_idx]
	return ent, ent.srv_heap_slot != 0
}

// =========================================================================
// Depth Twin Helpers & Fences
// =========================================================================

TWIN_SIDE_BOTH :: u8(0)
TWIN_SIDE_DEPTH :: u8(1)
TWIN_SIDE_TWIN :: u8(2)

twin_plane_formats :: proc(console_dxgi_fmt: u32) -> (planes: [2]u32, count: int) {
	switch console_dxgi_fmt {
	case 53, 55:       return {53, 0}, 1 // D16_UNORM -> R16
	case 39, 40, 41:   return {39, 0}, 1 // D32_FLOAT -> R32
	case 19, 20, 21, 22: return {39, 60}, 2 // D32_FLOAT_S8X24_UINT -> R32, R8
	}
	return {0, 0}, 0
}

Virtual_Fence :: struct {
	mu:      sync.Mutex,
	value:   u64,
	flags:   u32,
	waiters: [dynamic]struct {
		val:   u64,
		event: win32.HANDLE,
	},
}

fence_create :: proc(initial: u64, flags: u32) -> ^Virtual_Fence {
	f := new(Virtual_Fence)
	f.value = initial
	f.flags = flags
	f.waiters = make([dynamic]struct {
		val:   u64,
		event: win32.HANDLE,
	})
	return f
}

fence_destroy :: proc(f: ^Virtual_Fence) {
	if f == nil {
		return
	}
	delete(f.waiters)
	free(f)
}

fence_signal :: proc(f: ^Virtual_Fence, val: u64) {
	sync.mutex_lock(&f.mu)
	defer sync.mutex_unlock(&f.mu)
	if val > f.value {
		intrinsics.atomic_store(&f.value, val)
	}
	keep := 0
	for w in f.waiters {
		if f.value >= w.val {
			if w.event != nil {
				win32.SetEvent(w.event)
			}
		} else {
			f.waiters[keep] = w
			keep += 1
		}
	}
	resize(&f.waiters, keep)
}

fence_set_event :: proc(f: ^Virtual_Fence, val: u64, event: win32.HANDLE) {
	sync.mutex_lock(&f.mu)
	defer sync.mutex_unlock(&f.mu)
	if intrinsics.atomic_load(&f.value) >= val {
		if event != nil {
			win32.SetEvent(event)
		}
		return
	}
	append(&f.waiters, struct {
		val:   u64,
		event: win32.HANDLE,
	}{val = val, event = event})
}

// =========================================================================
// Shadow Copy & Dirty Compare
// =========================================================================

Shadow_Copy :: struct {
	title_start: u64,
	len:         u64,
	backing:     [dynamic]u8,
	snapshot:    [dynamic]u8,
	heap_slot:   u32,
}

shadow_create :: proc(title_start, len_bytes: u64, heap_slot: u32) -> ^Shadow_Copy {
	sc := new(Shadow_Copy)
	sc.title_start = title_start
	sc.len = len_bytes
	sc.backing = make([dynamic]u8, int(len_bytes))
	sc.snapshot = make([dynamic]u8, int(len_bytes))
	sc.heap_slot = heap_slot
	return sc
}

shadow_destroy :: proc(sc: ^Shadow_Copy) {
	if sc == nil {
		return
	}
	delete(sc.backing)
	delete(sc.snapshot)
	free(sc)
}

shadow_refresh_from :: proc(sc: ^Shadow_Copy, src: []u8) {
	n := min(len(sc.backing), len(src))
	if n > 0 {
		copy(sc.backing[:n], src[:n])
		copy(sc.snapshot[:n], src[:n])
	}
}

// Fast branchless writeback merge with 64-bit word fast-skip (upstream #2054 + u64 stride).
// For each byte: if host[i] != old[i], title[i] = host[i]; else keep title[i]. Always syncs host[i] = title[i].
shadow_merge_writeback :: proc(title, host, old: []u8) -> (changed_bytes: u64, any_changed: bool) {
	n := min(len(title), min(len(host), len(old)))
	i := 0
	// Fast 8-byte word skip for untouched regions (common in 64 KiB pages)
	for i + 8 <= n {
		h_w := (cast(^u64)&host[i])^
		o_w := (cast(^u64)&old[i])^
		if h_w == o_w {
			// GPU did not touch these 8 bytes; mirror CPU title bytes back to host snapshot
			t_w := (cast(^u64)&title[i])^
			if h_w != t_w {
				(cast(^u64)&host[i])^ = t_w
			}
			i += 8
			continue
		}
		for k := 0; k < 8; k += 1 {
			idx := i + k
			hb := host[idx]
			ob := old[idx]
			tb := title[idx]
			mask := u8(0) - u8(1 if hb != ob else 0)
			delta := (tb ~ hb) & mask
			nt := tb ~ delta
			title[idx] = nt
			host[idx] = nt
			if delta != 0 {
				changed_bytes += 1
				any_changed = true
			}
		}
		i += 8
	}
	for i < n {
		hb := host[i]
		ob := old[i]
		tb := title[i]
		mask := u8(0) - u8(1 if hb != ob else 0)
		delta := (tb ~ hb) & mask
		nt := tb ~ delta
		title[i] = nt
		host[i] = nt
		if delta != 0 {
			changed_bytes += 1
			any_changed = true
		}
		i += 1
	}
	return changed_bytes, any_changed
}

// Compares backing against snapshot and writes only changed bytes back into `dst_title`, returning bytes copied back.
shadow_copy_back :: proc(sc: ^Shadow_Copy, dst_title: []u8) -> u64 {
	n := min(len(sc.backing), min(len(sc.snapshot), len(dst_title)))
	if n == 0 {
		return 0
	}
	written, _ := shadow_merge_writeback(dst_title[:n], sc.backing[:n], sc.snapshot[:n])
	copy(sc.snapshot[:n], sc.backing[:n])
	return written
}

// Incremental 64 KiB page copy-back: inspects only pages recorded as dirty by Frame_Ring.
shadow_copy_back_pages :: proc(sc: ^Shadow_Copy, dst_title: []u8, dirty_pages: []u64) -> u64 {
	if sc == nil || len(dirty_pages) == 0 {
		return 0
	}
	n := u64(min(len(sc.backing), min(len(sc.snapshot), len(dst_title))))
	if n == 0 {
		return 0
	}
	written := u64(0)
	for page in dirty_pages {
		page_end := page + DIRTY_PAGE_GRANULARITY
		if page_end <= sc.title_start || page >= sc.title_start + n {
			continue
		}
		lo := int(max(page, sc.title_start) - sc.title_start)
		hi := int(min(page_end, sc.title_start + n) - sc.title_start)
		w, _ := shadow_merge_writeback(dst_title[lo:hi], sc.backing[lo:hi], sc.snapshot[lo:hi])
		copy(sc.snapshot[lo:hi], sc.backing[lo:hi])
		written += w
	}
	return written
}

// =========================================================================
// Pooled Title-Memory Dirty Bitmap with 64-bit Zero-Word Skip (upstream #1865)
// =========================================================================

Dirty_Bitmap :: struct {
	words:      [dynamic]u64,
	page_count: u64,
}

dirty_bitmap_init :: proc(page_count: u64, allocator := context.allocator) -> Dirty_Bitmap {
	n_words := int((page_count + 63) / 64)
	return Dirty_Bitmap{
		words      = make([dynamic]u64, n_words, allocator),
		page_count = page_count,
	}
}

dirty_bitmap_destroy :: proc(bm: ^Dirty_Bitmap) {
	if bm == nil {
		return
	}
	delete(bm.words)
	bm^ = {}
}

dirty_bitmap_clear :: proc(bm: ^Dirty_Bitmap) {
	if bm == nil {
		return
	}
	for i := 0; i < len(bm.words); i += 1 {
		bm.words[i] = 0
	}
}

dirty_bitmap_mark :: proc(bm: ^Dirty_Bitmap, page_index: u64) {
	if bm == nil || page_index >= bm.page_count {
		return
	}
	bm.words[page_index >> 6] |= u64(1) << (page_index & 63)
}

dirty_bitmap_mark_range :: proc(bm: ^Dirty_Bitmap, start_page, count: u64) {
	if bm == nil || count == 0 {
		return
	}
	end := min(start_page + count, bm.page_count)
	for p := start_page; p < end; p += 1 {
		bm.words[p >> 6] |= u64(1) << (p & 63)
	}
}

// Collects all dirty page indices by skipping zero 64-bit words in O(1) via CTZ.
dirty_bitmap_collect :: proc(bm: ^Dirty_Bitmap, out: ^[dynamic]u64) {
	if bm == nil || out == nil {
		return
	}
	for w, wi in bm.words {
		bits := w
		for bits != 0 {
			tz := intrinsics.count_trailing_zeros(bits)
			page := (u64(wi) << 6) | tz
			if page < bm.page_count {
				append(out, page)
			}
			bits &= bits - 1
		}
	}
}
