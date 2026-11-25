package vasperty_hle

import "base:intrinsics"
import "core:compress/deflate"
import "core:io"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import win32 "core:sys/windows"
import "core:thread"
import vasperty_formats "vasperty:formats"

// xmem, dstorage, net (loopback guard), and rpcrt4 (UUID v4 CSPRNG).

// =============================================================================
// 1. xmem
// =============================================================================

XMEM_PAGE :: uint(64) << 10
XMEM_MIB :: uint(1) << 20
XMEM_PAGES_2M :: u32(0x20000000)
XMEM_PAGES_64K_BIT :: u32(0x00400000)
XMEM_PAGES_64K :: XMEM_PAGES_2M | XMEM_PAGES_64K_BIT
XMEM_HOST_PROTECTION :: u32(0x1FF)
XMEM_GRAPHICS :: u64(3)
XMEM_ADDRESS_32BIT :: u64(4)
XMEM_MEM_WRITE_WATCH :: u32(0x00200000)
XMEM_MEM_RESERVE_PLACEHOLDER :: u32(0x00040000)
XMEM_MEM_REPLACE_PLACEHOLDER :: u32(0x00004000)
XMEM_MEM_PRESERVE_PLACEHOLDER :: u32(0x00000002)

MEM_ADDRESS_REQUIREMENTS :: struct {
	lowest_starting_address: rawptr,
	highest_ending_address:  rawptr,
	alignment:               uint,
}
MEM_EXTENDED_PARAMETER :: struct {
	type_reserved: u64,
	pointer:       rawptr,
}

XMem_Basic_Information :: struct {
	base_address:       rawptr,
	allocation_base:    rawptr,
	allocation_protect: u32,
	partition_id:       u16,
	region_size:        uint,
	state:              u32,
	protect:            u32,
	type_:              u32,
	flags:              u64,
	tag_code:           u32,
	tag:                [4]u8,
}

XMem_Working_Set_Stats :: struct {
	shared_read_only:  u64,
	shared_read_write: u64,
	private:           u64,
}

Physical_Section :: struct {
	handle: win32.HANDLE,
	pages:  uint,
}
Physical_Slice :: struct {
	section: ^Physical_Section,
	index:   uint,
}
Physical_View :: struct {
	size:  uint,
	slice: Physical_Slice,
}

@(private)
xmem_state: struct {
	mu:          sync.Mutex,
	allocations: map[uintptr]^Physical_Section,
	views:       map[uintptr]Physical_View,
	transferred: uint,
}

fini_xmem :: proc() {
	sync.mutex_lock(&xmem_state.mu)
	defer sync.mutex_unlock(&xmem_state.mu)
	for _, s in xmem_state.allocations {
		if s.handle != nil { _ = win32.CloseHandle(s.handle) }
		free(s)
	}
	delete(xmem_state.allocations)
	delete(xmem_state.views)
	xmem_state.allocations = nil
	xmem_state.views = nil
}

@(private)
kb_fn :: proc(name: string, $T: typeid) -> (T, bool) {
	addr, ok := host_function("kernelbase.dll", name)
	if !ok {
		addr, ok = host_function("kernel32.dll", name)
	}
	if !ok { return nil, false }
	return cast(T)rawptr(addr), true
}

@(private)
xmem_address_range :: proc(flags: u64) -> (uintptr, uintptr) {
	if flags & XMEM_ADDRESS_32BIT != 0 {
		return 0, uintptr(0xFFFFFFFF)
	}
	field := (flags >> 12) & 7
	bits := uint(40) if field == 0 else uint(47 - field)
	return uintptr(1) << 32, (uintptr(1) << bits) - 1
}

XMemVirtualAlloc :: proc "system" (base: rawptr, size: uint, kind: u32, flags: u64, protect: u32) -> rawptr {
	context = hle_context()
	low, high := xmem_address_range(flags)
	req := MEM_ADDRESS_REQUIREMENTS{
		lowest_starting_address = rawptr(low),
		highest_ending_address  = rawptr(high),
		alignment               = XMEM_MIB * 2 if (kind & (XMEM_PAGES_2M | XMEM_PAGES_64K_BIT) == XMEM_PAGES_2M) else 0,
	}
	prot := protect & XMEM_HOST_PROTECTION
	if prot == 0 { prot = win32.PAGE_NOACCESS }

	placeholder := (kind & XMEM_PAGES_64K == XMEM_PAGES_64K) && (kind & win32.MEM_COMMIT == 0)
	if placeholder {
		if kind & XMEM_MEM_REPLACE_PLACEHOLDER != 0 {
			return base
		}
		prot = win32.PAGE_NOACCESS
	}
	k := kind & ~(XMEM_PAGES_2M | XMEM_PAGES_64K_BIT)
	if placeholder {
		k |= win32.MEM_RESERVE | XMEM_MEM_RESERVE_PLACEHOLDER
	}
	constrained := base == nil
	if constrained {
		k |= win32.MEM_RESERVE
		if k & XMEM_MEM_RESERVE_PLACEHOLDER == 0 {
			k |= XMEM_MEM_WRITE_WATCH
		}
	}

	if valloc2, ok := kb_fn("VirtualAlloc2", proc "system" (win32.HANDLE, rawptr, uint, u32, u32, ^MEM_EXTENDED_PARAMETER, u32) -> rawptr); ok {
	context = hle_context()
		param := MEM_EXTENDED_PARAMETER{type_reserved = 1, pointer = &req}
		pptr: ^MEM_EXTENDED_PARAMETER = &param if constrained else nil
		pcnt: u32 = 1 if constrained else 0
		return valloc2(win32.GetCurrentProcess(), base, size, k, prot, pptr, pcnt)
	}
	return win32.VirtualAlloc(base, size, k & ~XMEM_MEM_RESERVE_PLACEHOLDER, prot)
}

XMemVirtualQuery :: proc "system" (hproc: win32.HANDLE, addr: rawptr, out: ^XMem_Basic_Information) -> win32.BOOL {
	context = hle_context()
	if out == nil { return false }
	fn, ok := host_fn("kernel32.dll", "VirtualQueryEx", proc "system" (win32.HANDLE, rawptr, rawptr, uint) -> uint)
	if !ok || fn(hproc, addr, out, size_of(win32.MEMORY_BASIC_INFORMATION)) == 0 {
		return false
	}
	out.flags = XMEM_GRAPHICS if out.state == win32.MEM_COMMIT else 0
	out.tag_code = 0
	out.tag = {}
	return true
}

@(private)
xmem_hook_pointers :: proc() -> [2]uintptr {
	b, ok := main_image()
	if !ok { return {0, 0} }
	p := win32.GetProcAddress(win32.HMODULE(rawptr(b)), "__XMemAllocationHooks__")
	if p == nil { return {0, 0} }
	ptrs := cast(^[2]uintptr)p
	return ptrs^
}

XMemAllocDefault :: proc "system" (size: uint, attrs: u64) -> rawptr {
	context = hle_context()
	if attrs & (u64(1) << 33) != 0 {
		return XMemVirtualAlloc(nil, size, win32.MEM_RESERVE | win32.MEM_COMMIT, XMEM_GRAPHICS | XMEM_ADDRESS_32BIT, win32.PAGE_READWRITE)
	}
	log2 := (attrs >> 24) & 0x1F
	align := uint(1) << max(uint(log2), 4)
	hdr := uint(2 * size_of(uintptr))
	total := size + align + hdr
	raw := win32.VirtualAlloc(nil, max(total, 64), win32.MEM_RESERVE | win32.MEM_COMMIT, win32.PAGE_READWRITE)
	if raw == nil { return nil }
	aligned := (uintptr(raw) + uintptr(hdr) + uintptr(align) - 1) & ~uintptr(align - 1)
	meta := cast(^[2]uintptr)rawptr(aligned - uintptr(hdr))
	meta[0] = uintptr(raw)
	meta[1] = uintptr(total)
	return rawptr(aligned)
}

XMemFreeDefault :: proc "system" (addr: rawptr, attrs: u64) {
	context = hle_context()
	if addr == nil { return }
	if attrs & (u64(1) << 33) != 0 {
		_ = win32.VirtualFree(addr, 0, win32.MEM_RELEASE)
		return
	}
	meta := cast(^[2]uintptr)rawptr(uintptr(addr) - 2 * size_of(uintptr))
	_ = win32.VirtualFree(rawptr(meta[0]), 0, win32.MEM_RELEASE)
}

XMemAlloc :: proc "system" (size: uint, attrs: u64) -> rawptr {
	context = hle_context()
	hooks := xmem_hook_pointers()
	if hooks[0] != 0 {
		fn := cast(proc "system" (uint, u64) -> rawptr)rawptr(hooks[0])
		return fn(size, attrs)
	}
	return XMemAllocDefault(size, attrs)
}

XMemFree :: proc "system" (addr: rawptr, attrs: u64) {
	context = hle_context()
	hooks := xmem_hook_pointers()
	if hooks[1] != 0 {
		fn := cast(proc "system" (rawptr, u64))rawptr(hooks[1])
		fn(addr, attrs)
		return
	}
	XMemFreeDefault(addr, attrs)
}

XMemIsToolsMemAvailable :: proc "system" (_out: ^u8) -> bool { context = hle_context(); return false }

XMemAllocatePhysicalPages :: proc "system" (count_ptr: ^uint, out_pages: [^]uint) -> bool {
	context = hle_context()
	if count_ptr == nil || out_pages == nil { return false }
	cnt := count_ptr^
	if cnt == 0 { return true }
	bytes := cnt * XMEM_PAGE
	SEC_RESERVE :: u32(0x04000000)
	h := win32.CreateFileMappingW(win32.INVALID_HANDLE_VALUE, nil, win32.PAGE_READWRITE | SEC_RESERVE, u32(bytes >> 32), u32(bytes & 0xFFFFFFFF), nil)
	if h == nil {
		count_ptr^ = 0
		return false
	}
	sec := new(Physical_Section)
	sec.handle = h
	sec.pages = cnt
	sync.mutex_lock(&xmem_state.mu)
	if xmem_state.allocations == nil { xmem_state.allocations = make(map[uintptr]^Physical_Section) }
	if xmem_state.views == nil { xmem_state.views = make(map[uintptr]Physical_View) }
	base_num: uint = 0x100000 + len(xmem_state.allocations) * 0x10000
	xmem_state.allocations[uintptr(base_num)] = sec
	sync.mutex_unlock(&xmem_state.mu)
	for i in 0 ..< cnt {
		out_pages[i] = base_num + i
	}
	return true
}

XMemFreePhysicalPages :: proc "system" (count: uint, pages: [^]uint) -> bool {
	context = hle_context()
	_ = count; _ = pages
	return true
}

XMemMapPhysicalPages :: proc "system" (base: rawptr, page_count: uint, _kind, _protect: u32, pages: [^]uint) -> rawptr {
	context = hle_context()
	if base == nil || page_count == 0 || pages == nil { return nil }
	sync.mutex_lock(&xmem_state.mu)
	defer sync.mutex_unlock(&xmem_state.mu)
	first := pages[0]
	var_sec: ^Physical_Section = nil
	var_idx: uint = 0
	for pbase, sec in xmem_state.allocations {
		if first >= uint(pbase) && first < uint(pbase) + sec.pages {
			var_sec = sec
			var_idx = first - uint(pbase)
			break
		}
	}
	if var_sec == nil { return nil }
	mv3, ok := kb_fn("MapViewOfFile3", proc "system" (win32.HANDLE, win32.HANDLE, rawptr, u64, uint, u32, u32, rawptr, u32) -> rawptr)
	if !ok { return nil }
	len_b := page_count * XMEM_PAGE
	_ = win32.VirtualFree(base, len_b, win32.MEM_RELEASE | XMEM_MEM_PRESERVE_PLACEHOLDER)
	view := mv3(var_sec.handle, win32.GetCurrentProcess(), base, u64(var_idx * XMEM_PAGE), len_b, XMEM_MEM_REPLACE_PLACEHOLDER, win32.PAGE_READWRITE, nil, 0)
	if view != base { return nil }
	_ = win32.VirtualAlloc(base, len_b, win32.MEM_COMMIT, win32.PAGE_READWRITE)
	xmem_state.views[uintptr(base)] = Physical_View{size = len_b, slice = {section = var_sec, index = var_idx}}
	hooks := get_gpu_hooks()
	if hooks.title_memory_remapped != nil { hooks.title_memory_remapped(uintptr(base), len_b) }
	return base
}

XMemMapPhysicalPagesScatter :: proc "system" (addrs: [^]rawptr, flags: u32, count: uint, pages: [^]uint) -> rawptr {
	context = hle_context()
	_ = flags
	if addrs == nil || count == 0 || pages == nil { return nil }
	for i in 0 ..< count {
		if XMemMapPhysicalPages(addrs[i], 1, 0, win32.PAGE_READWRITE, &pages[i]) == nil {
			return nil
		}
	}
	return addrs[0]
}

XMemGetWorkingSetStatistics :: proc "system" (out: ^XMem_Working_Set_Stats) -> HRESULT {
	context = hle_context()
	if out == nil { return E_INVALIDARG }
	_, std_mem := console_title_memory(current_console())
	out^ = XMem_Working_Set_Stats{private = std_mem / 2}
	return S_OK
}

XMemTransferMemory :: proc "system" (_p: rawptr, sz: uint) {
	context = hle_context()
	sync.mutex_lock(&xmem_state.mu)
	xmem_state.transferred += sz
	sync.mutex_unlock(&xmem_state.mu)
}

xmem_write_physical :: proc(pages: []uint, offset: uint, data: []u8) -> bool {
	if len(data) == 0 { return true }
	mv, ok := kb_fn("MapViewOfFile", proc "system" (win32.HANDLE, u32, u32, u32, uint) -> rawptr)
	uv, ok2 := kb_fn("UnmapViewOfFile", proc "system" (rawptr) -> win32.BOOL)
	if !ok || !ok2 { return false }

	sync.mutex_lock(&xmem_state.mu)
	defer sync.mutex_unlock(&xmem_state.mu)
	written: uint = 0
	rem := len(data)
	cur_off := offset
	for pi := 0; pi < len(pages) && rem > 0; pi += 1 {
		pg := pages[pi]
		var_sec: ^Physical_Section = nil
		var_idx: uint = 0
		for pbase, sec in xmem_state.allocations {
			if pg >= uint(pbase) && pg < uint(pbase) + sec.pages {
				var_sec = sec
				var_idx = pg - uint(pbase)
				break
			}
		}
		if var_sec == nil { return false }
		chunk := min(rem, int(XMEM_PAGE - cur_off))
		FILE_MAP_ALL_ACCESS :: u32(0xF001F)
		file_off := u64(var_idx * XMEM_PAGE)
		view := mv(var_sec.handle, FILE_MAP_ALL_ACCESS, u32(file_off >> 32), u32(file_off & 0xFFFFFFFF), XMEM_PAGE)
		if view == nil { return false }
		_ = win32.VirtualAlloc(view, XMEM_PAGE, win32.MEM_COMMIT, win32.PAGE_READWRITE)
		mem.copy(rawptr(uintptr(view) + uintptr(cur_off)), raw_data(data[written:]), chunk)
		_ = uv(view)
		written += uint(chunk)
		rem -= chunk
		cur_off = 0
	}
	return rem == 0
}

XMEM_DLLS := [?]string{"xmem.dll"}
XMEM_EXPORTS := [?]Hle_Export {
	{name = "XMemAlloc", address = uintptr(rawptr(XMemAlloc))},
	{name = "XMemFree", address = uintptr(rawptr(XMemFree))},
	{name = "XMemAllocDefault", address = uintptr(rawptr(XMemAllocDefault))},
	{name = "XMemFreeDefault", address = uintptr(rawptr(XMemFreeDefault))},
	{name = "XMemIsToolsMemAvailable", address = uintptr(rawptr(XMemIsToolsMemAvailable))},
	{name = "XMemAllocatePhysicalPages", address = uintptr(rawptr(XMemAllocatePhysicalPages))},
	{name = "XMemFreePhysicalPages", address = uintptr(rawptr(XMemFreePhysicalPages))},
	{name = "XMemMapPhysicalPages", address = uintptr(rawptr(XMemMapPhysicalPages))},
	{name = "XMemMapPhysicalPagesScatter", address = uintptr(rawptr(XMemMapPhysicalPagesScatter))},
	{name = "XMemVirtualAlloc", address = uintptr(rawptr(XMemVirtualAlloc))},
	{name = "XMemVirtualQuery", address = uintptr(rawptr(XMemVirtualQuery))},
	{name = "XMemGetWorkingSetStatistics", address = uintptr(rawptr(XMemGetWorkingSetStatistics))},
	{name = "XMemTransferMemory", address = uintptr(rawptr(XMemTransferMemory))},
}

// =============================================================================
// 2. dstorage
// =============================================================================

IID_DS_FACTORY :: Guid{0x62959d11, 0xd45f, 0x4884, {0xa0, 0xa3, 0xf7, 0x86, 0x2e, 0xa2, 0x43, 0xae}}

DS_Instance :: struct($T: typeid) {
	base:  Runtime_Object,
	refs:  u32,
	state: T,
}

DS_File :: struct {
	handle: ^os.File,
}

DS_Status_Array :: struct {
	entries: []i32,
}

DS_Queue_Desc :: struct {
	capacity: u16,
	priority: i8,
	_pad:     [5]u8,
	name:     cstring,
}

DS_Request :: struct {
	options:           u64,
	source:            rawptr,
	offset:            u64,
	source_size:       u32,
	destination:       rawptr,
	destination_size:  u32,
	page_offset:       u32,
	intermediate_size: u32,
	name:              cstring,
}

DS_Queue :: struct {
	mu:       sync.Mutex,
	pending:  [dynamic]DS_Request,
	statuses: [dynamic]struct{ arr: ^DS_Instance(DS_Status_Array), idx: u32, wait_seq: u64 },
	seq:      u64,
	done_seq: u64,
}

@(private) ds_state: struct {
	mu:           sync.Mutex,
	cond:         sync.Cond,
	staging_size: u32,
	started:      bool,
	stopping:     bool,
	workers:      [dynamic]^thread.Thread,
	queues:       [dynamic]^DS_Instance(DS_Queue),
}

fini_dstorage :: proc() {
	sync.mutex_lock(&ds_state.mu)
	ds_state.stopping = true
	sync.cond_broadcast(&ds_state.cond)
	ws := make([dynamic]^thread.Thread, len(ds_state.workers))
	copy(ws[:], ds_state.workers[:])
	clear(&ds_state.workers)
	sync.mutex_unlock(&ds_state.mu)
	for w in ws {
		thread.join(w)
		thread.destroy(w)
	}
	delete(ws)
	delete(ds_state.workers)
	delete(ds_state.queues)
	ds_state.started = false
	ds_state.stopping = false
}

@(private)
ds_execute_request :: proc(req: ^DS_Request) -> HRESULT {
	if req.destination == nil || req.destination_size == 0 {
		return E_INVALIDARG
	}
	bc := u8((req.options >> 16) & 0xFF)
	is_zlib := (req.options & 1) != 0
	is_mem_src := (req.options & 4) != 0
	is_page_dst := (req.options & 8) != 0

	src_bytes := make([]u8, int(req.source_size), context.temp_allocator)
	if is_mem_src {
		if req.source == nil { return E_INVALIDARG }
		mem.copy(raw_data(src_bytes), req.source, int(req.source_size))
	} else {
		finst := cast(^DS_Instance(DS_File))req.source
		if finst == nil { return E_INVALIDARG }
		_, serr := os.seek(finst.state.handle, i64(req.offset), io.Seek_From.Start)
		if serr != nil { return END_OF_FILE }
		total := 0
		for total < len(src_bytes) {
			n, rerr := os.read(finst.state.handle, src_bytes[total:])
			if rerr != nil || n == 0 { return END_OF_FILE }
			total += n
		}
	}

	write_dst :: proc(r: ^DS_Request, payload: []u8, page_dst: bool) -> HRESULT {
		if !page_dst {
			hooks := get_gpu_hooks()
			tok: uintptr = 0
			if hooks.kernel_will_write != nil { tok = hooks.kernel_will_write(uintptr(r.destination), uint(len(payload))) }
			defer if hooks.kernel_end_write != nil && tok != 0 { hooks.kernel_end_write(tok) }
			mem.copy(r.destination, raw_data(payload), len(payload))
			return S_OK
		}
		off := uint(r.page_offset & 0xFFFF)
		npages := (off + uint(len(payload)) + XMEM_PAGE - 1) / XMEM_PAGE
		pages := mem.slice_ptr(cast(^uint)r.destination, int(npages))
		return S_OK if xmem_write_physical(pages, off, payload) else INVALID_DATA
	}

	if !is_zlib && bc == 0 {
		return write_dst(req, src_bytes[:min(len(src_bytes), int(req.destination_size))], is_page_dst)
	}

	plain := src_bytes
	if is_zlib {
		out_dyn := make([dynamic]u8, 0, int(req.destination_size), context.temp_allocator)
		// Strip 2-byte zlib header / 4-byte adler32 when present.
		raw_in := src_bytes[2 : len(src_bytes) - 4] if len(src_bytes) >= 6 else src_bytes
		if err := deflate.inflate_raw(&out_dyn, raw_in, -1, int(req.destination_size) + 4096, context.temp_allocator); err != nil {
			return INVALID_DATA
		}
		plain = out_dyn[:]
	}
	if bc != 0 {
		out_bc := make([]u8, int(req.destination_size), context.temp_allocator)
		tables, tbl_err := vasperty_formats.bcpack_builtin_tables(context.temp_allocator)
		if tbl_err != .None || tables == nil { return E_NOTIMPL }
		defer vasperty_formats.bcpack_destroy_tables(tables, context.temp_allocator)
		if dec_err := vasperty_formats.bcpack_decode(bc, plain, out_bc, tables, context.temp_allocator); dec_err != .None {
			return INVALID_DATA
		}
		return write_dst(req, out_bc, is_page_dst)
	}
	return write_dst(req, plain[:min(len(plain), int(req.destination_size))], is_page_dst)
}

@(private)
ds_worker_proc :: proc(t: ^thread.Thread) {
	_ = t
	for {
		var_job: DS_Request
		var_q: ^DS_Instance(DS_Queue) = nil
		var_seq: u64 = 0
		sync.mutex_lock(&ds_state.mu)
		for !ds_state.stopping && var_q == nil {
			for q in ds_state.queues {
				sync.mutex_lock(&q.state.mu)
				if len(q.state.pending) > 0 {
					var_job = q.state.pending[0]
					ordered_remove(&q.state.pending, 0)
					q.state.seq += 1
					var_seq = q.state.seq
					var_q = q
					sync.mutex_unlock(&q.state.mu)
					break
				}
				sync.mutex_unlock(&q.state.mu)
			}
			if var_q == nil {
				sync.cond_wait(&ds_state.cond, &ds_state.mu)
			}
		}
		if ds_state.stopping {
			sync.mutex_unlock(&ds_state.mu)
			return
		}
		sync.mutex_unlock(&ds_state.mu)

		hr := ds_execute_request(&var_job)
		sync.mutex_lock(&var_q.state.mu)
		var_q.state.done_seq = max(var_q.state.done_seq, var_seq)
		for st_idx := len(var_q.state.statuses) - 1; st_idx >= 0; st_idx -= 1 {
			st := var_q.state.statuses[st_idx]
			if var_q.state.done_seq >= st.wait_seq {
				intrinsics.atomic_store(&st.arr.state.entries[st.idx], i32(hr))
				ordered_remove(&var_q.state.statuses, st_idx)
			}
		}
		sync.mutex_unlock(&var_q.state.mu)
		free_all(context.temp_allocator)
	}
}

@(private) ds_ensure_workers :: proc() {
	sync.mutex_lock(&ds_state.mu)
	defer sync.mutex_unlock(&ds_state.mu)
	if ds_state.started { return }
	ds_state.started = true
	for _ in 0 ..< 2 {
		w := thread.create(ds_worker_proc)
		if w != nil {
			append(&ds_state.workers, w)
			thread.start(w)
		}
	}
}

@(private) ds_file_addref :: proc "system" (t: ^DS_Instance(DS_File)) -> u32 { context = hle_context(); return intrinsics.atomic_add(&t.refs, 1) + 1 }
@(private) ds_file_rel :: proc "system" (t: ^DS_Instance(DS_File)) -> u32 {
	context = hle_context()
	left := intrinsics.atomic_sub(&t.refs, 1) - 1
	if left == 0 { os.close(t.state.handle); free(t) }
	return left
}
@(private) ds_st_addref :: proc "system" (t: ^DS_Instance(DS_Status_Array)) -> u32 { context = hle_context(); return intrinsics.atomic_add(&t.refs, 1) + 1 }
@(private) ds_st_rel :: proc "system" (t: ^DS_Instance(DS_Status_Array)) -> u32 {
	context = hle_context()
	left := intrinsics.atomic_sub(&t.refs, 1) - 1
	if left == 0 { delete(t.state.entries); free(t) }
	return left
}
@(private) ds_q_addref :: proc "system" (t: ^DS_Instance(DS_Queue)) -> u32 { context = hle_context(); return intrinsics.atomic_add(&t.refs, 1) + 1 }
@(private) ds_q_rel :: proc "system" (t: ^DS_Instance(DS_Queue)) -> u32 {
	context = hle_context()
	left := intrinsics.atomic_sub(&t.refs, 1) - 1
	if left == 0 {
		sync.mutex_lock(&ds_state.mu)
		for q, i in ds_state.queues {
			if q == t { ordered_remove(&ds_state.queues, i); break }
		}
		sync.mutex_unlock(&ds_state.mu)
		delete(t.state.pending)
		delete(t.state.statuses)
		free(t)
	}
	return left
}

DS_FILE_VTABLE := [8]rawptr{rawptr(rt_missing), rawptr(ds_file_addref), rawptr(ds_file_rel), rawptr(rt_missing), rawptr(rt_missing), rawptr(rt_missing), rawptr(rt_missing), rawptr(rt_missing)}

@(private) ds_st_complete :: proc "system" (t: ^DS_Instance(DS_Status_Array), idx: u32) -> bool {
	context = hle_context()
	if t == nil || int(idx) >= len(t.state.entries) { return false }
	return HRESULT(intrinsics.atomic_load(&t.state.entries[idx])) != E_PENDING
}
@(private) ds_st_result :: proc "system" (t: ^DS_Instance(DS_Status_Array), idx: u32) -> HRESULT {
	context = hle_context()
	if t == nil || int(idx) >= len(t.state.entries) { return E_INVALIDARG }
	return HRESULT(intrinsics.atomic_load(&t.state.entries[idx]))
}
DS_STATUS_VTABLE := [5]rawptr{rawptr(rt_missing), rawptr(ds_st_addref), rawptr(ds_st_rel), rawptr(ds_st_complete), rawptr(ds_st_result)}

@(private) ds_q_enqueue_req :: proc "system" (q: ^DS_Instance(DS_Queue), req: ^DS_Request) {
	context = hle_context()
	if q == nil || req == nil { return }
	sync.mutex_lock(&q.state.mu)
	append(&q.state.pending, req^)
	sync.mutex_unlock(&q.state.mu)
}
@(private) ds_q_enqueue_status :: proc "system" (q: ^DS_Instance(DS_Queue), arr: ^DS_Instance(DS_Status_Array), idx: u32) {
	context = hle_context()
	if q == nil || arr == nil || int(idx) >= len(arr.state.entries) { return }
	intrinsics.atomic_store(&arr.state.entries[idx], i32(E_PENDING))
	sync.mutex_lock(&q.state.mu)
	wseq := q.state.seq + u64(len(q.state.pending))
	append(&q.state.statuses, struct{ arr: ^DS_Instance(DS_Status_Array), idx: u32, wait_seq: u64 }{arr = arr, idx = idx, wait_seq = wseq})
	sync.mutex_unlock(&q.state.mu)
}
@(private) ds_q_submit :: proc "system" (_: ^DS_Instance(DS_Queue)) {
	context = hle_context()
	ds_ensure_workers()
	sync.mutex_lock(&ds_state.mu)
	sync.cond_broadcast(&ds_state.cond)
	sync.mutex_unlock(&ds_state.mu)
}

DS_QUEUE_VTABLE := [12]rawptr{
	rawptr(rt_missing), rawptr(ds_q_addref), rawptr(ds_q_rel),
	rawptr(ds_q_enqueue_req), rawptr(ds_q_enqueue_status),
	rawptr(rt_missing), rawptr(ds_q_submit),
	rawptr(rt_missing), rawptr(rt_missing), rawptr(rt_missing), rawptr(rt_missing), rawptr(rt_missing),
}

@(private) ds_open_file :: proc "system" (_: ^Runtime_Object, path_w: [^]u16, _iid: ^Guid, out: ^rawptr) -> HRESULT {
	context = hle_context()
	if path_w == nil || out == nil { return E_INVALIDARG }
	n := wptr_len(path_w)
	tr, ok := translate_virtual_path_w(path_w[:n], context.temp_allocator)
	use_w := tr if ok else path_w[:n]
	pstr, _ := win32.utf16_to_utf8(use_w, context.temp_allocator)
	pstr = strings.trim_right(pstr, "\x00")
	h, err := os.open(pstr)
	if err != nil { return E_FAIL }
	inst := new(DS_Instance(DS_File))
	inst.base = {vtable = raw_data(DS_FILE_VTABLE[:]), area = "dstorage file"}
	inst.refs = 1
	inst.state = {handle = h}
	out^ = rawptr(inst)
	return S_OK
}
@(private) ds_create_status :: proc "system" (_: ^Runtime_Object, count: u32, _iid: ^Guid, out: ^rawptr) -> HRESULT {
	context = hle_context()
	if out == nil { return E_INVALIDARG }
	inst := new(DS_Instance(DS_Status_Array))
	inst.base = {vtable = raw_data(DS_STATUS_VTABLE[:]), area = "dstorage status"}
	inst.refs = 1
	inst.state.entries = make([]i32, int(count))
	for i in 0 ..< int(count) { inst.state.entries[i] = i32(S_OK) }
	out^ = rawptr(inst)
	return S_OK
}
@(private) ds_set_staging :: proc "system" (_: ^Runtime_Object, sz: u32) -> HRESULT {
	context = hle_context()
	sync.mutex_lock(&ds_state.mu)
	ds_state.staging_size = sz
	sync.mutex_unlock(&ds_state.mu)
	return S_OK
}
@(private) ds_create_queue :: proc "system" (_: ^Runtime_Object, _desc: ^DS_Queue_Desc, _iid: ^Guid, out: ^rawptr) -> HRESULT {
	context = hle_context()
	if out == nil { return E_INVALIDARG }
	inst := new(DS_Instance(DS_Queue))
	inst.base = {vtable = raw_data(DS_QUEUE_VTABLE[:]), area = "dstorage queue"}
	inst.refs = 1
	sync.mutex_lock(&ds_state.mu)
	append(&ds_state.queues, inst)
	sync.mutex_unlock(&ds_state.mu)
	out^ = rawptr(inst)
	return S_OK
}

DS_FACTORY_VTABLE := [16]rawptr{
	rawptr(rt_missing), rawptr(rt_add_ref), rawptr(rt_add_ref),
	rawptr(rt_missing), rawptr(ds_open_file), rawptr(ds_create_status),
	rawptr(rt_missing), rawptr(rt_missing), rawptr(ds_set_staging),
	rawptr(rt_missing), rawptr(ds_create_queue),
	rawptr(rt_missing), rawptr(rt_missing), rawptr(rt_missing), rawptr(rt_missing), rawptr(rt_missing),
}
DS_FACTORY_OBJECT := Runtime_Object{vtable = raw_data(DS_FACTORY_VTABLE[:]), area = "dstorage factory"}

DStorageGetFactory :: proc "system" (iid: ^Guid, out: ^rawptr) -> HRESULT {
	context = hle_context()
	if iid != nil && guid_eq(iid^, IID_DS_FACTORY) {
		return put_ptr(out, rawptr(&DS_FACTORY_OBJECT))
	}
	return E_NOINTERFACE
}

DSTORAGE_DLLS := [?]string{"xcrdapi.dll"}
DSTORAGE_EXPORTS := [?]Hle_Export{{name = "DStorageGetFactory", address = uintptr(rawptr(DStorageGetFactory))}}

// =============================================================================
// 3. net (loopback-only Winsock & WinHTTP offline firewall)
// =============================================================================

WSAENETUNREACH :: i32(10051)
WSAHOST_NOT_FOUND :: i32(11001)
ERROR_WINHTTP_CANNOT_CONNECT :: u32(12029)
ERROR_WINHTTP_AUTODETECTION_FAILED :: u32(12180)
SOCKADDR_AF_INET :: u16(2)
SOCKADDR_AF_INET6 :: u16(23)

@(private) wsa_set_last :: proc(code: i32) {
	fn, ok := host_fn("ws2_32.dll", "WSASetLastError", proc "system" (i32))
	if ok { fn(code) }
}

is_loopback_sockaddr :: proc(sa: rawptr, len: i32) -> bool {
	if sa == nil || len < 4 { return false }
	family := (cast(^u16)sa)^
	if family == SOCKADDR_AF_INET && len >= 8 {
		b := cast([^]u8)sa
		return b[4] == 127
	}
	if family == SOCKADDR_AF_INET6 && len >= 24 {
		b := cast([^]u8)sa
		for i in 8 ..< 23 {
			if b[i] != 0 { return false }
		}
		return b[23] == 1
	}
	return false
}

is_loopback_host_str :: proc(h: string) -> bool {
	s := strings.trim_space(h)
	if len(s) == 0 || strings.equal_fold(s, "localhost") || s == "::1" || s == "[::1]" {
		return true
	}
	return strings.has_prefix(s, "127.")
}

@(private) net_connect :: proc "system" (s: uintptr, name: rawptr, namelen: i32) -> i32 {
	context = hle_context()
	if !is_loopback_sockaddr(name, namelen) { wsa_set_last(WSAENETUNREACH); return -1 }
	fn, ok := host_fn("ws2_32.dll", "connect", proc "system" (uintptr, rawptr, i32) -> i32)
	return fn(s, name, namelen) if ok else -1
}
@(private) net_wsaconnect :: proc "system" (s: uintptr, name: rawptr, namelen: i32, a, b, c, d: rawptr) -> i32 {
	context = hle_context()
	if !is_loopback_sockaddr(name, namelen) { wsa_set_last(WSAENETUNREACH); return -1 }
	fn, ok := host_fn("ws2_32.dll", "WSAConnect", proc "system" (uintptr, rawptr, i32, rawptr, rawptr, rawptr, rawptr) -> i32)
	return fn(s, name, namelen, a, b, c, d) if ok else -1
}
@(private) net_wsaconnect_name_a :: proc "system" (s: uintptr, node, serv: cstring, a, b, c, d, e, f: rawptr) -> i32 {
	context = hle_context()
	if node == nil || !is_loopback_host_str(string(node)) { wsa_set_last(WSAENETUNREACH); return -1 }
	fn, ok := host_fn("ws2_32.dll", "WSAConnectByNameA", proc "system" (uintptr, cstring, cstring, rawptr, rawptr, rawptr, rawptr, rawptr, rawptr) -> i32)
	return fn(s, node, serv, a, b, c, d, e, f) if ok else -1
}
@(private) net_wsaconnect_name_w :: proc "system" (s: uintptr, node, serv: [^]u16, a, b, c, d, e, f: rawptr) -> i32 {
	context = hle_context()
	if node == nil || !is_loopback_host_str(wptr_to_string(node, context.temp_allocator)) { wsa_set_last(WSAENETUNREACH); return -1 }
	fn, ok := host_fn("ws2_32.dll", "WSAConnectByNameW", proc "system" (uintptr, [^]u16, [^]u16, rawptr, rawptr, rawptr, rawptr, rawptr, rawptr) -> i32)
	return fn(s, node, serv, a, b, c, d, e, f) if ok else -1
}
@(private) net_wsaconnect_list :: proc "system" (s: uintptr, list: rawptr, a, b, c, d, e, f: rawptr) -> i32 {
	context = hle_context()
	_ = s; _ = list; _ = a; _ = b; _ = c; _ = d; _ = e; _ = f
	wsa_set_last(WSAENETUNREACH)
	return -1
}
@(private) net_wsajoin :: proc "system" (s: uintptr, name: rawptr, len: i32, a, b, c, d: rawptr, fl: u32) -> uintptr {
	context = hle_context()
	if !is_loopback_sockaddr(name, len) { wsa_set_last(WSAENETUNREACH); return ~uintptr(0) }
	fn, ok := host_fn("ws2_32.dll", "WSAJoinLeaf", proc "system" (uintptr, rawptr, i32, rawptr, rawptr, rawptr, rawptr, u32) -> uintptr)
	return fn(s, name, len, a, b, c, d, fl) if ok else ~uintptr(0)
}
@(private) net_wsaioctl :: proc "system" (s: uintptr, code: u32, in_b: rawptr, in_l: u32, out_b: rawptr, out_l: u32, ret: ^u32, ov, comp: rawptr) -> i32 {
	context = hle_context()
	fn, ok := host_fn("ws2_32.dll", "WSAIoctl", proc "system" (uintptr, u32, rawptr, u32, rawptr, u32, ^u32, rawptr, rawptr) -> i32)
	return fn(s, code, in_b, in_l, out_b, out_l, ret, ov, comp) if ok else -1
}
@(private) net_sendto :: proc "system" (s: uintptr, buf: rawptr, l, fl: i32, to: rawptr, tolen: i32) -> i32 {
	context = hle_context()
	if to != nil && !is_loopback_sockaddr(to, tolen) { wsa_set_last(WSAENETUNREACH); return -1 }
	fn, ok := host_fn("ws2_32.dll", "sendto", proc "system" (uintptr, rawptr, i32, i32, rawptr, i32) -> i32)
	return fn(s, buf, l, fl, to, tolen) if ok else -1
}
@(private) net_wsasendto :: proc "system" (s: uintptr, bufs: rawptr, cnt: u32, sent: ^u32, fl: u32, to: rawptr, tolen: i32, ov, comp: rawptr) -> i32 {
	context = hle_context()
	if to != nil && !is_loopback_sockaddr(to, tolen) { wsa_set_last(WSAENETUNREACH); return -1 }
	fn, ok := host_fn("ws2_32.dll", "WSASendTo", proc "system" (uintptr, rawptr, u32, ^u32, u32, rawptr, i32, rawptr, rawptr) -> i32)
	return fn(s, bufs, cnt, sent, fl, to, tolen, ov, comp) if ok else -1
}
@(private) net_wsasendmsg :: proc "system" (s: uintptr, msg: rawptr, fl: u32, sent: ^u32, ov, comp: rawptr) -> i32 {
	context = hle_context()
	_ = s; _ = msg; _ = fl; _ = sent; _ = ov; _ = comp
	wsa_set_last(WSAENETUNREACH)
	return -1
}
@(private) net_bind :: proc "system" (s: uintptr, name: rawptr, namelen: i32) -> i32 {
	context = hle_context()
	// Narrow INADDR_ANY / in6addr_any onto loopback cleanly before forwarding.
	if name != nil && namelen >= 8 && (cast(^u16)name)^ == SOCKADDR_AF_INET {
		b: [16]u8
		copy(b[:], mem.byte_slice(name, min(int(namelen), 16)))
		if b[4] == 0 && b[5] == 0 && b[6] == 0 && b[7] == 0 {
			b[4] = 127; b[7] = 1
			fn, ok := host_fn("ws2_32.dll", "bind", proc "system" (uintptr, rawptr, i32) -> i32)
			return fn(s, raw_data(b[:]), namelen) if ok else -1
		}
	}
	fn, ok := host_fn("ws2_32.dll", "bind", proc "system" (uintptr, rawptr, i32) -> i32)
	return fn(s, name, namelen) if ok else -1
}
@(private) net_getaddrinfo :: proc "system" (node, serv: cstring, hints, res: rawptr) -> i32 {
	context = hle_context()
	if node != nil && !is_loopback_host_str(string(node)) { return WSAHOST_NOT_FOUND }
	fn, ok := host_fn("ws2_32.dll", "getaddrinfo", proc "system" (cstring, cstring, rawptr, rawptr) -> i32)
	return fn(node, serv, hints, res) if ok else WSAHOST_NOT_FOUND
}
@(private) net_getaddrinfo_w :: proc "system" (node, serv: [^]u16, hints, res: rawptr) -> i32 {
	context = hle_context()
	if node != nil && !is_loopback_host_str(wptr_to_string(node, context.temp_allocator)) { return WSAHOST_NOT_FOUND }
	fn, ok := host_fn("ws2_32.dll", "GetAddrInfoW", proc "system" ([^]u16, [^]u16, rawptr, rawptr) -> i32)
	return fn(node, serv, hints, res) if ok else WSAHOST_NOT_FOUND
}
@(private) net_getaddrinfo_exa :: proc "system" (name, serv: cstring, ns: u32, nsp, hints, res, t, ov, cr, ch: rawptr) -> i32 {
	context = hle_context()
	if name != nil && !is_loopback_host_str(string(name)) { return WSAHOST_NOT_FOUND }
	fn, ok := host_fn("ws2_32.dll", "GetAddrInfoExA", proc "system" (cstring, cstring, u32, rawptr, rawptr, rawptr, rawptr, rawptr, rawptr, rawptr) -> i32)
	return fn(name, serv, ns, nsp, hints, res, t, ov, cr, ch) if ok else WSAHOST_NOT_FOUND
}
@(private) net_getaddrinfo_exw :: proc "system" (name, serv: [^]u16, ns: u32, nsp, hints, res, t, ov, cr, ch: rawptr) -> i32 {
	context = hle_context()
	if name != nil && !is_loopback_host_str(wptr_to_string(name, context.temp_allocator)) { return WSAHOST_NOT_FOUND }
	fn, ok := host_fn("ws2_32.dll", "GetAddrInfoExW", proc "system" ([^]u16, [^]u16, u32, rawptr, rawptr, rawptr, rawptr, rawptr, rawptr, rawptr) -> i32)
	return fn(name, serv, ns, nsp, hints, res, t, ov, cr, ch) if ok else WSAHOST_NOT_FOUND
}
@(private) net_gethostbyname :: proc "system" (name: cstring) -> rawptr {
	context = hle_context()
	if name == nil || !is_loopback_host_str(string(name)) { wsa_set_last(WSAHOST_NOT_FOUND); return nil }
	fn, ok := host_fn("ws2_32.dll", "gethostbyname", proc "system" (cstring) -> rawptr)
	return fn(name) if ok else nil
}
@(private) net_async_byname :: proc "system" (_h: rawptr, _m: u32, _n: cstring, _b: rawptr, _bl: i32) -> rawptr { context = hle_context(); wsa_set_last(WSAHOST_NOT_FOUND); return nil }
@(private) net_lookup_begin_a :: proc "system" (_q: rawptr, _fl: u32, _out: rawptr) -> i32 { context = hle_context(); wsa_set_last(10108); return -1 }
@(private) net_lookup_begin_w :: proc "system" (_q: rawptr, _fl: u32, _out: rawptr) -> i32 { context = hle_context(); wsa_set_last(10108); return -1 }
@(private) net_gethostbyaddr :: proc "system" (_a: rawptr, _l, _t: i32) -> rawptr { context = hle_context(); wsa_set_last(WSAHOST_NOT_FOUND); return nil }
@(private) net_async_byaddr :: proc "system" (_h: rawptr, _m: u32, _a: rawptr, _l, _t: i32, _b: rawptr, _bl: i32) -> rawptr { context = hle_context(); wsa_set_last(WSAHOST_NOT_FOUND); return nil }
@(private) net_getnameinfo :: proc "system" (sa: rawptr, salen: i32, h: [^]u8, hl: u32, s: [^]u8, sl: u32, fl: i32) -> i32 {
	context = hle_context()
	if !is_loopback_sockaddr(sa, salen) && (fl & 0x04 != 0) { wsa_set_last(WSAHOST_NOT_FOUND); return WSAHOST_NOT_FOUND }
	fn, ok := host_fn("ws2_32.dll", "getnameinfo", proc "system" (rawptr, i32, [^]u8, u32, [^]u8, u32, i32) -> i32)
	return fn(sa, salen, h, hl, s, sl, fl | 0x02) if ok else WSAHOST_NOT_FOUND
}
@(private) net_getnameinfo_w :: proc "system" (sa: rawptr, salen: i32, h: [^]u16, hl: u32, s: [^]u16, sl: u32, fl: i32) -> i32 {
	context = hle_context()
	if !is_loopback_sockaddr(sa, salen) && (fl & 0x04 != 0) { wsa_set_last(WSAHOST_NOT_FOUND); return WSAHOST_NOT_FOUND }
	fn, ok := host_fn("ws2_32.dll", "GetNameInfoW", proc "system" (rawptr, i32, [^]u16, u32, [^]u16, u32, i32) -> i32)
	return fn(sa, salen, h, hl, s, sl, fl | 0x02) if ok else WSAHOST_NOT_FOUND
}
@(private) wh_connect :: proc "system" (sess: rawptr, server: [^]u16, port: u16, res: u32) -> rawptr {
	context = hle_context()
	if server == nil || !is_loopback_host_str(wptr_to_string(server, context.temp_allocator)) {
		SetLastError(ERROR_WINHTTP_CANNOT_CONNECT)
		return nil
	}
	fn, ok := host_fn("winhttp.dll", "WinHttpConnect", proc "system" (rawptr, [^]u16, u16, u32) -> rawptr)
	return fn(sess, server, port, res) if ok else nil
}
@(private) wh_open :: proc "system" (ua: [^]u16, _acc: u32, _pn, _pb: [^]u16, fl: u32) -> rawptr {
	context = hle_context()
	fn, ok := host_fn("winhttp.dll", "WinHttpOpen", proc "system" ([^]u16, u32, [^]u16, [^]u16, u32) -> rawptr)
	return fn(ua, 1, nil, nil, fl) if ok else nil
}
@(private) wh_set_opt :: proc "system" (h: rawptr, opt: u32, buf: rawptr, len: u32) -> i32 {
	context = hle_context()
	if opt == 38 { SetLastError(87); return 0 } // refuse proxy changes
	fn, ok := host_fn("winhttp.dll", "WinHttpSetOption", proc "system" (rawptr, u32, rawptr, u32) -> i32)
	return fn(h, opt, buf, len) if ok else 0
}
@(private) wh_autoproxy :: proc "system" (_fl: u32, _url: ^rawptr) -> i32 { context = hle_context(); SetLastError(ERROR_WINHTTP_AUTODETECTION_FAILED); return 0 }
@(private) wh_proxy_url :: proc "system" (_s: rawptr, _u: [^]u16, _o, _i: rawptr) -> i32 { context = hle_context(); SetLastError(ERROR_WINHTTP_AUTODETECTION_FAILED); return 0 }
@(private) wh_proxy_urlex :: proc "system" (_s: rawptr, _u: [^]u16, _o: rawptr, _c: rawptr) -> u32 { context = hle_context(); return ERROR_WINHTTP_AUTODETECTION_FAILED }
@(private) wh_proxy_urlex2 :: proc "system" (_s: rawptr, _u: [^]u16, _o: rawptr, _if: u32, _p, _c: rawptr) -> u32 { context = hle_context(); return ERROR_WINHTTP_AUTODETECTION_FAILED }
@(private) wh_proxy_settings :: proc "system" (_s: rawptr, _ver: u32, _p: rawptr, _o: rawptr) -> u32 { context = hle_context(); return ERROR_WINHTTP_AUTODETECTION_FAILED }

NET_DLLS := [?]string{"ws2_32.dll", "winhttp.dll"}
NET_EXPORTS := [?]Hle_Export {
	{name = "connect", address = uintptr(rawptr(net_connect))},
	{name = "WSAConnect", address = uintptr(rawptr(net_wsaconnect))},
	{name = "WSAConnectByNameA", address = uintptr(rawptr(net_wsaconnect_name_a))},
	{name = "WSAConnectByNameW", address = uintptr(rawptr(net_wsaconnect_name_w))},
	{name = "WSAConnectByList", address = uintptr(rawptr(net_wsaconnect_list))},
	{name = "WSAJoinLeaf", address = uintptr(rawptr(net_wsajoin))},
	{name = "WSAIoctl", address = uintptr(rawptr(net_wsaioctl))},
	{name = "sendto", address = uintptr(rawptr(net_sendto))},
	{name = "WSASendTo", address = uintptr(rawptr(net_wsasendto))},
	{name = "WSASendMsg", address = uintptr(rawptr(net_wsasendmsg))},
	{name = "bind", address = uintptr(rawptr(net_bind))},
	{name = "getaddrinfo", address = uintptr(rawptr(net_getaddrinfo))},
	{name = "GetAddrInfoW", address = uintptr(rawptr(net_getaddrinfo_w))},
	{name = "GetAddrInfoExA", address = uintptr(rawptr(net_getaddrinfo_exa))},
	{name = "GetAddrInfoExW", address = uintptr(rawptr(net_getaddrinfo_exw))},
	{name = "gethostbyname", address = uintptr(rawptr(net_gethostbyname))},
	{name = "WSAAsyncGetHostByName", address = uintptr(rawptr(net_async_byname))},
	{name = "WSALookupServiceBeginA", address = uintptr(rawptr(net_lookup_begin_a))},
	{name = "WSALookupServiceBeginW", address = uintptr(rawptr(net_lookup_begin_w))},
	{name = "gethostbyaddr", address = uintptr(rawptr(net_gethostbyaddr))},
	{name = "WSAAsyncGetHostByAddr", address = uintptr(rawptr(net_async_byaddr))},
	{name = "getnameinfo", address = uintptr(rawptr(net_getnameinfo))},
	{name = "GetNameInfoW", address = uintptr(rawptr(net_getnameinfo_w))},
	{name = "WinHttpConnect", address = uintptr(rawptr(wh_connect))},
	{name = "WinHttpOpen", address = uintptr(rawptr(wh_open))},
	{name = "WinHttpSetOption", address = uintptr(rawptr(wh_set_opt))},
	{name = "WinHttpDetectAutoProxyConfigUrl", address = uintptr(rawptr(wh_autoproxy))},
	{name = "WinHttpGetProxyForUrl", address = uintptr(rawptr(wh_proxy_url))},
	{name = "WinHttpGetProxyForUrlEx", address = uintptr(rawptr(wh_proxy_urlex))},
	{name = "WinHttpGetProxyForUrlEx2", address = uintptr(rawptr(wh_proxy_urlex2))},
	{name = "WinHttpGetProxySettingsEx", address = uintptr(rawptr(wh_proxy_settings))},
}

// =============================================================================
// 4. rpcrt4
// =============================================================================

RPC_S_OK :: i32(0)
RPC_S_OUT_OF_MEMORY :: i32(14)
RPC_S_INVALID_STRING_UUID :: i32(1705)

@(private)
rpc_guid_from_bytes :: proc(b: [16]u8) -> Guid {
	return Guid{
		data1 = u32(b[0]) << 24 | u32(b[1]) << 16 | u32(b[2]) << 8 | u32(b[3]),
		data2 = u16(b[4]) << 8 | u16(b[5]),
		data3 = u16(b[6]) << 8 | u16(b[7]),
		data4 = {b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]},
	}
}

@(private)
rpc_parse_uuid_str :: proc(s: string) -> (Guid, bool) {
	if len(s) != 36 || s[8] != '-' || s[13] != '-' || s[18] != '-' || s[23] != '-' {
		return {}, false
	}
	d1, ok1 := strconv.parse_u64_of_base(s[0:8], 16)
	d2, ok2 := strconv.parse_u64_of_base(s[9:13], 16)
	d3, ok3 := strconv.parse_u64_of_base(s[14:18], 16)
	p4, ok4 := strconv.parse_u64_of_base(s[19:23], 16)
	p5, ok5 := strconv.parse_u64_of_base(s[24:36], 16)
	if !ok1 || !ok2 || !ok3 || !ok4 || !ok5 { return {}, false }
	return Guid{
		data1 = u32(d1),
		data2 = u16(d2),
		data3 = u16(d3),
		data4 = {
			u8(p4 >> 8), u8(p4),
			u8(p5 >> 40), u8(p5 >> 32), u8(p5 >> 24), u8(p5 >> 16), u8(p5 >> 8), u8(p5),
		},
	}, true
}

UuidCreate :: proc "system" (uuid: ^Guid) -> i32 {
	context = hle_context()
	if uuid == nil { return RPC_S_INVALID_STRING_UUID }
	bytes: [16]u8
	if win32.BCryptGenRandom(nil, raw_data(bytes[:]), 16, win32.BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0 {
		return RPC_S_OUT_OF_MEMORY
	}
	bytes[6] = (bytes[6] & 0x0F) | 0x40
	bytes[8] = (bytes[8] & 0x3F) | 0x80
	uuid^ = rpc_guid_from_bytes(bytes)
	return RPC_S_OK
}
UuidCreateSequential :: proc "system" (uuid: ^Guid) -> i32 { context = hle_context(); return UuidCreate(uuid) }

UuidFromStringA :: proc "system" (text: cstring, uuid: ^Guid) -> i32 {
	context = hle_context()
	s, ok := cstr_to_string(text)
	if !ok || uuid == nil { return RPC_S_INVALID_STRING_UUID }
	g, pok := rpc_parse_uuid_str(s)
	if !pok { return RPC_S_INVALID_STRING_UUID }
	uuid^ = g
	return RPC_S_OK
}
UuidFromStringW :: proc "system" (text: [^]u16, uuid: ^Guid) -> i32 {
	context = hle_context()
	if text == nil || uuid == nil { return RPC_S_INVALID_STRING_UUID }
	g, pok := rpc_parse_uuid_str(wptr_to_string(text, context.temp_allocator))
	if !pok { return RPC_S_INVALID_STRING_UUID }
	uuid^ = g
	return RPC_S_OK
}

UuidToStringA :: proc "system" (uuid: ^Guid, out: ^cstring) -> i32 {
	context = hle_context()
	if uuid == nil || out == nil { return RPC_S_INVALID_STRING_UUID }
	s := guid_to_string(uuid^, context.temp_allocator)
	p := win32.HeapAlloc(win32.GetProcessHeap(), 0, uint(len(s) + 1))
	if p == nil { return RPC_S_OUT_OF_MEMORY }
	mem.copy(p, raw_data(s), len(s))
	(cast([^]u8)p)[len(s)] = 0
	out^ = cstring(p)
	return RPC_S_OK
}
UuidToStringW :: proc "system" (uuid: ^Guid, out: ^[^]u16) -> i32 {
	context = hle_context()
	if uuid == nil || out == nil { return RPC_S_INVALID_STRING_UUID }
	s := guid_to_string(uuid^, context.temp_allocator)
	w := win32.utf8_to_utf16(s, context.temp_allocator)
	p := win32.HeapAlloc(win32.GetProcessHeap(), 0, uint((len(w) + 1) * 2))
	if p == nil { return RPC_S_OUT_OF_MEMORY }
	mem.copy(p, raw_data(w), len(w) * 2)
	(cast([^]u16)p)[len(w)] = 0
	out^ = cast([^]u16)p
	return RPC_S_OK
}
RpcStringFreeA :: proc "system" (p: ^rawptr) -> i32 {
	context = hle_context()
	if p != nil && p^ != nil {
		_ = win32.HeapFree(win32.GetProcessHeap(), 0, p^)
		p^ = nil
	}
	return RPC_S_OK
}
RpcStringFreeW :: proc "system" (p: ^rawptr) -> i32 { context = hle_context(); return RpcStringFreeA(p) }

RPCRT4_DLLS := [?]string{"rpcrt4.dll"}
RPCRT4_EXPORTS := [?]Hle_Export {
	{name = "UuidCreate", address = uintptr(rawptr(UuidCreate))},
	{name = "UuidCreateSequential", address = uintptr(rawptr(UuidCreateSequential))},
	{name = "UuidFromStringA", address = uintptr(rawptr(UuidFromStringA))},
	{name = "UuidFromStringW", address = uintptr(rawptr(UuidFromStringW))},
	{name = "UuidToStringA", address = uintptr(rawptr(UuidToStringA))},
	{name = "UuidToStringW", address = uintptr(rawptr(UuidToStringW))},
	{name = "RpcStringFreeA", address = uintptr(rawptr(RpcStringFreeA))},
	{name = "RpcStringFreeW", address = uintptr(rawptr(RpcStringFreeW))},
}
