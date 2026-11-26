package vasperty_gpu

import "base:intrinsics"
import "core:fmt"
import "core:mem"
import "core:sync"
import win32 "core:sys/windows"

// =========================================================================
// Xbox D3D12.X COM Object Wrappers: Fence, Queue, Allocator, CommandList
// =========================================================================

// Shared helper to decode the vtable slot from x64 indirect call at return address.
@(private)
decode_vtable_slot :: proc "contextless" (ret: rawptr) -> i32 {
	if ret == nil {
		return -1
	}
	b := cast([^]u8)ret
	if b[-3] == 0xFF && (b[-2] & 0xF8) == 0x50 {
		return i32(b[-1])
	}
	if b[-6] == 0xFF && (b[-5] & 0xF8) == 0x90 {
		return i32(u32(b[-4]) | (u32(b[-3]) << 8) | (u32(b[-2]) << 16) | (u32(b[-1]) << 24))
	}
	if b[-4] == 0xFF && (b[-3] & 0xF8) == 0x50 {
		return i32(b[-1])
	}
	if b[-7] == 0xFF && (b[-6] & 0xF8) == 0x90 {
		return i32(u32(b[-4]) | (u32(b[-3]) << 8) | (u32(b[-2]) << 16) | (u32(b[-1]) << 24))
	}
	return -1
}

// =========================================================================
// Console_Fence (ID3D12Fence / ID3D12Fence1 with GetGpuAddress at slot #12)
// =========================================================================

Fence_Waiter :: struct {
	target: u64,
	event:  win32.HANDLE,
}

Console_Fence :: struct {
	object:  Gpu_Object,
	value:   u64,
	flags:   u32,
	mu:      sync.Mutex,
	waiters: [dynamic]Fence_Waiter,
}

@(private)
g_fence_vtable: [24]rawptr

@(private)
fence_qi :: proc "system" (this: This, iid: ^Iid, out: ^This) -> HRESULT {
	context = gpu_context()
	_ = iid
	return answer_interface(this, out)
}

@(private)
fence_release :: proc "system" (this: This) -> u32 {
	context = gpu_context()
	if this == nil { return 0 }
	rem := object_release_static(this)
	if rem == 0 {
		f := cast(^Console_Fence)this
		delete(f.waiters)
		free(f)
	}
	return rem
}

@(private)
fence_completed :: proc "system" (this: This) -> u64 {
	if this == nil { return 0 }
	f := cast(^Console_Fence)this
	return intrinsics.atomic_load(&f.value)
}

@(private)
cfence_set_event :: proc "system" (this: This, value: u64, event: win32.HANDLE) -> HRESULT {
	context = gpu_context()
	if this == nil { return E_INVALIDARG }
	f := cast(^Console_Fence)this
	sync.mutex_lock(&f.mu)
	defer sync.mutex_unlock(&f.mu)
	cur := intrinsics.atomic_load(&f.value)
	if cur >= value {
		if event != nil {
			win32.SetEvent(event)
		}
		return S_OK
	}
	if event == nil {
		return S_OK
	}
	append(&f.waiters, Fence_Waiter{target = value, event = event})
	return S_OK
}

console_fence_set :: proc(this: This, value: u64) -> HRESULT {
	if this == nil { return E_INVALIDARG }
	f := cast(^Console_Fence)this
	sync.mutex_lock(&f.mu)
	defer sync.mutex_unlock(&f.mu)
	intrinsics.atomic_store(&f.value, value)
	i := 0
	for i < len(f.waiters) {
		if f.waiters[i].target <= value {
			if f.waiters[i].event != nil {
				win32.SetEvent(f.waiters[i].event)
			}
			unordered_remove(&f.waiters, i)
		} else {
			i += 1
		}
	}
	return S_OK
}

@(private)
cfence_signal :: proc "system" (this: This, value: u64) -> HRESULT {
	context = gpu_context()
	return console_fence_set(this, value)
}

@(private)
fence_creation_flags :: proc "system" (this: This) -> u32 {
	if this == nil { return 0 }
	return (cast(^Console_Fence)this).flags
}

@(private)
fence_gpu_address :: proc "system" (this: This) -> u64 {
	if this == nil { return 0 }
	f := cast(^Console_Fence)this
	return u64(uintptr(&f.value))
}

@(private)
fence_stub :: proc "system" (this: This, a1, a2: uintptr) -> HRESULT {
	context = gpu_context()
	_ = this
	off := decode_vtable_slot(intrinsics.return_address())
	fmt.printf("[d3d12x] Fence unimpl slot #%d (off=0x%X a1=0x%X a2=0x%X)\n", off / 8, off, a1, a2)
	return E_NOTIMPL
}

create_console_fence :: proc(initial: u64, flags: u32, out: ^rawptr) -> HRESULT {
	if out == nil { return E_POINTER }
	f := new(Console_Fence)
	f.object = Gpu_Object{functions = &g_fence_vtable[0], bits = u32(Object_Kind.Fence), refs = 1}
	f.value = initial
	f.flags = flags
	out^ = rawptr(f)
	return S_OK
}

// =========================================================================
// Console_Queue (ID3D12CommandQueue with newer_slot +2 offset from slot 14)
// =========================================================================

Console_Queue :: struct {
	object:           Gpu_Object,
	host_queue:       rawptr,
	desc:             D3D12_COMMAND_QUEUE_DESC,
	mu:               sync.Mutex,
	host_fence:       rawptr,
	host_fence_event: win32.HANDLE,
	host_fence_val:   u64,
}

@(private)
g_queue_vtable: [36]rawptr
@(private)
g_queue_newer_vtable: [36]rawptr
@(private)
g_presented_frames: u64

Present_Plane_X :: struct {
	token:     u64,
	count:     u32,
	_pad:      u32,
	resources: [^]This,
	_rest:     [6]u64,
}
#assert(size_of(Present_Plane_X) == 0x48)

@(private)
queue_qi :: proc "system" (this: This, iid: ^Iid, out: ^This) -> HRESULT {
	context = gpu_context()
	_ = iid
	return answer_interface(this, out)
}

@(private)
queue_release :: proc "system" (this: This) -> u32 {
	context = gpu_context()
	if this == nil { return 0 }
	rem := object_release_static(this)
	if rem == 0 {
		q := cast(^Console_Queue)this
		if q.host_fence_event != nil {
			_ = win32.CloseHandle(q.host_fence_event)
			q.host_fence_event = nil
		}
		if q.host_fence != nil {
			com_release(q.host_fence)
			q.host_fence = nil
		}
		if q.host_queue != nil {
			com_release(q.host_queue)
		}
		free(q)
	}
	return rem
}

@(private)
queue_execute :: proc "system" (this: This, count: u32, lists: [^]rawptr) {
	context = gpu_context()
	if this == nil || count == 0 || lists == nil { return }
	q := cast(^Console_Queue)this
	if q.host_queue == nil { return }
	// Unwrap Console_Cmd_List -> host_list before submitting to PC D3D12 queue
	host_lists := make([dynamic]rawptr, 0, int(count), context.temp_allocator)
	submitted_cls := make([dynamic]^Console_Cmd_List, 0, int(count), context.temp_allocator)
	for i in 0 ..< count {
		if lists[i] == nil { continue }
		cl := cast(^Console_Cmd_List)lists[i]
		if cl.host_list != nil {
			if !cl.is_closed {
				lvt := (cast(^^Host_Cmd_List_Vtbl)cl.host_list)^
				if lvt.Close(cl.host_list) >= 0 {
					cl.is_closed = true
				}
			}
			if cl.is_closed {
				append(&host_lists, cl.host_list)
				append(&submitted_cls, cl)
			}
		}
	}
	if len(host_lists) > 0 {
		sync.mutex_lock(&q.mu)
		qvt := (cast(^^Exec_Queue_Vtbl)q.host_queue)^
		qvt.ExecuteCommandLists(q.host_queue, u32(len(host_lists)), &host_lists[0])
		queue_signal_and_wait_host_fence(q)
		sync.mutex_unlock(&q.mu)
		for cl in submitted_cls {
			recycle_cl_host_list(cl)
		}
	}
}

@(private)
queue_execute_x :: proc "system" (this: This, count: u32, lists: [^]rawptr, token: u64, flags: u32) {
	_ = token; _ = flags
	queue_execute(this, count, lists)
}

@(private)
queue_marker :: proc "system" (this: This) {
	_ = this
}

@(private)
queue_signal :: proc "system" (this: This, fence: This, value: u64) -> HRESULT {
	context = gpu_context()
	_ = this
	return console_fence_set(fence, value)
}

@(private)
queue_signal2_x :: proc "system" (this: This, fence: This, value: u64, flags: u32) -> HRESULT {
	context = gpu_context()
	_ = this; _ = flags
	return console_fence_set(fence, value)
}

@(private)
queue_wait :: proc "system" (this: This, fence: This, value: u64) -> HRESULT {
	_ = this; _ = fence; _ = value
	return S_OK
}

@(private)
queue_timestamp_freq :: proc "system" (this: This, out: ^u64) -> HRESULT {
	_ = this
	if out == nil { return E_POINTER }
	out^ = 10_000_000
	return S_OK
}

@(private)
queue_get_desc :: proc "system" (this: This, out: ^D3D12_COMMAND_QUEUE_DESC) -> ^D3D12_COMMAND_QUEUE_DESC {
	if out != nil && this != nil {
		out^ = (cast(^Console_Queue)this).desc
	}
	return out
}

@(private)
queue_copy_page_mappings :: proc "system" (this: This, count: u32, batches: rawptr) -> HRESULT {
	_ = this; _ = count; _ = batches
	return S_OK
}

@(private)
queue_present_x :: proc "system" (this: This, plane_count: u32, planes: rawptr, params: rawptr) -> HRESULT {
	context = gpu_context()
	_ = params
	frame := intrinsics.atomic_add(&g_presented_frames, 1) + 1
	plane_res: rawptr = nil
	plane_state: u32 = 0
	plane_w: u32 = 0
	plane_h: u32 = 0
	plane_drawn := false
	if plane_count > 0 && uintptr(planes) >= 0x10000 {
		plane_arr := cast([^]Present_Plane_X)planes
		for i in 0 ..< min(plane_count, u32(8)) {
			p := plane_arr[i]
			if p.count > 0 && uintptr(p.resources) >= 0x10000 && p.resources[0] != nil {
				cr := cast(^Console_Resource)p.resources[0]
				tex, st := ensure_host_texture(cr)
				if frame == 1 || frame == 10 {
					fmt.printf("[d3d12x]   plane[%d]: %dx%d fmt=%d state=0x%X drawn=%v addr=0x%X tex=%p\n", i, cr.desc.Width, cr.desc.Height, cr.desc.Format, st, cr.was_drawn, cr.address, tex)
				}
				if tex != nil && (plane_res == nil || (cr.was_drawn && !plane_drawn)) {
					plane_res = tex
					plane_state = st
					plane_w = u32(cr.desc.Width)
					plane_h = cr.desc.Height
					plane_drawn = cr.was_drawn
				}
			}
		}
		if g_last_indexed_rt != nil {
			if ltex, lst := ensure_host_texture(g_last_indexed_rt); ltex != nil {
				plane_res = ltex
				plane_state = lst
				plane_w = u32(g_last_indexed_rt.desc.Width)
				plane_h = g_last_indexed_rt.desc.Height
				plane_drawn = true
			}
		} else if plane_res == nil && g_last_drawn_rt != nil {
			if ltex, lst := ensure_host_texture(g_last_drawn_rt); ltex != nil {
				plane_res = ltex
				plane_state = lst
				plane_w = u32(g_last_drawn_rt.desc.Width)
				plane_h = g_last_drawn_rt.desc.Height
				plane_drawn = true
			}
		}
	}
	if frame == 1 || frame == 10 || frame == 30 || frame == 60 || frame == 100 || frame % 100 == 0 {
		fmt.printf("[d3d12x] PresentX frame=%d planes=%d draws=%d idx=%d disp=%d clears=%d copies=%d pso_ok=%d pso_fail=%d\n",
			frame, plane_count,
			intrinsics.atomic_load(&g_stat_draws),
			intrinsics.atomic_load(&g_stat_indexed),
			intrinsics.atomic_load(&g_stat_dispatches),
			intrinsics.atomic_load(&g_stat_clears),
			intrinsics.atomic_load(&g_stat_copies),
			intrinsics.atomic_load(&g_stat_pso_ok),
			intrinsics.atomic_load(&g_stat_pso_fail))
	}
	if this != nil {
		q := cast(^Console_Queue)this
		present_window_frame(q.host_queue, frame, plane_res, plane_state, plane_w, plane_h)
	}
	return S_OK
}

@(private)
queue_stub :: proc "system" (this: This, a1, a2, a3: uintptr) -> HRESULT {
	context = gpu_context()
	_ = this
	off := decode_vtable_slot(intrinsics.return_address())
	fmt.printf("[d3d12x] Queue unimpl slot #%d (off=0x%X a1=0x%X a2=0x%X a3=0x%X)\n", off / 8, off, a1, a2, a3)
	return S_OK
}

create_console_queue :: proc(desc: D3D12_COMMAND_QUEUE_DESC, host_queue: rawptr, out: ^rawptr) -> HRESULT {
	if out == nil { return E_POINTER }
	q := new(Console_Queue)
	vt := &g_queue_newer_vtable[0] if g_newer_device else &g_queue_vtable[0]
	q.object = Gpu_Object{functions = vt, bits = u32(Object_Kind.Queue), refs = 1}
	q.host_queue = host_queue
	q.desc = desc
	out^ = rawptr(q)
	return S_OK
}

// =========================================================================
// Console_Allocator (ID3D12CommandAllocator)
// =========================================================================

Console_Allocator :: struct {
	object:     Gpu_Object,
	kind:       u32,
	host_alloc: rawptr,
}

@(private)
g_alloc_vtable: [24]rawptr

@(private)
alloc_qi :: proc "system" (this: This, iid: ^Iid, out: ^This) -> HRESULT {
	context = gpu_context()
	_ = iid
	return answer_interface(this, out)
}

@(private)
alloc_release :: proc "system" (this: This) -> u32 {
	context = gpu_context()
	if this == nil { return 0 }
	rem := object_release_static(this)
	if rem == 0 {
		a := cast(^Console_Allocator)this
		if a.host_alloc != nil {
			com_release(a.host_alloc)
		}
		free(a)
	}
	return rem
}

@(private)
alloc_reset :: proc "system" (this: This) -> HRESULT {
	_ = this
	return S_OK
}

@(private)
alloc_stub :: proc "system" (this: This, a1: uintptr) -> HRESULT {
	context = gpu_context()
	_ = this
	off := decode_vtable_slot(intrinsics.return_address())
	fmt.printf("[d3d12x] Allocator unimpl slot #%d (off=0x%X a1=0x%X)\n", off / 8, off, a1)
	return S_OK
}

create_console_allocator :: proc(kind: u32, host_alloc: rawptr, out: ^rawptr) -> HRESULT {
	if out == nil { return E_POINTER }
	a := new(Console_Allocator)
	a.object = Gpu_Object{functions = &g_alloc_vtable[0], bits = u32(Object_Kind.Allocator), refs = 1}
	a.kind = kind
	a.host_alloc = host_alloc
	out^ = rawptr(a)
	return S_OK
}

// =========================================================================
// Console_Cmd_List (ID3D12GraphicsCommandList6 with exact Xbox inline layout)
// =========================================================================

Console_Cmd_List :: struct #align(16) {
	object:                Gpu_Object, // 0x00..0x10
	kind:                  u32,        // 0x10..0x14 (+4 padding -> 0x18)
	put:                   [5]u64,     // 0x18..0x40 (all zero so inline checks fall through to vtable)
	reserved:              [64]u32,    // 0x40..0x140
	graphics_root_headers: [128]u32,   // 0x140..0x340
	compute_root_headers:  [128]u32,   // 0x340..0x540
	pipeline_shadow:       [8]u32,     // 0x540..0x560
	newer:                 [256]u32,   // 0x560..0x960
	// Host & internal fields strictly after the console inline layout:
	host_list:             rawptr,
	host_alloc:            rawptr,
	host_list_type:        u32,
	is_closed:             bool,
	uploads:               [dynamic]rawptr,
	host_temps:            [dynamic]rawptr,
	cur_pso:               rawptr,
	bound_host_root:       rawptr,
	bound_host_pso:        rawptr,
	viewports:             [8]D3D12_VIEWPORT,
	scissors:              [8]D3D12_RECT,
	num_viewports:         u32,
	num_scissors:          u32,
	topology:              u32,
	raw_topology:          u32,
	has_topology:          bool,
	vp_dirty:              bool,
	scissor_dirty:         bool,
	topo_dirty:            bool,
	vb_views:              [8]D3D12_VERTEX_BUFFER_VIEW,
	vb_mask:               u8,
	ib_view:               D3D12_INDEX_BUFFER_VIEW,
	has_ib:                bool,
	cur_rts:               [8]^Console_Resource,
	num_cur_rts:           u32,
	gfx_roots:             [32]Console_Root_Slot,
}

#assert(offset_of(Console_Cmd_List, put) == 0x18)
#assert(offset_of(Console_Cmd_List, newer) == 0x560)

Console_Root_Slot :: struct {
	kind:       u8, // 0=none, 1=table, 2=consts, 3=view
	va:         u64,
	consts:     [32]u32,
	num_consts: u32,
}

@(private)
g_cmdlist_vtable: [160]rawptr
@(private)
g_cmdlist_newer_vtable: [160]rawptr

@(private)
cmdlist_qi :: proc "system" (this: This, iid: ^Iid, out: ^This) -> HRESULT {
	context = gpu_context()
	_ = iid
	return answer_interface(this, out)
}

@(private)
cmdlist_release :: proc "system" (this: This) -> u32 {
	context = gpu_context()
	if this == nil { return 0 }
	rem := object_release_static(this)
	if rem == 0 {
		cl := cast(^Console_Cmd_List)this
		for u in cl.uploads {
			free(u)
		}
		delete(cl.uploads)
		for t in cl.host_temps {
			if t != nil {
				com_release(t)
			}
		}
		delete(cl.host_temps)
		if cl.host_list != nil {
			if !cl.is_closed {
				lvt := (cast(^^Host_Cmd_List_Vtbl)cl.host_list)^
				_ = lvt.Close(cl.host_list)
			}
			com_release(cl.host_list)
		}
		if cl.host_alloc != nil {
			com_release(cl.host_alloc)
		}
		free(cl)
	}
	return rem
}

@(private)
cmdlist_get_type :: proc "system" (this: This) -> u32 {
	if this == nil { return 0 }
	return (cast(^Console_Cmd_List)this).kind
}

@(private)
cmdlist_close :: proc "system" (this: This) -> HRESULT {
	context = gpu_context()
	if this == nil { return E_INVALIDARG }
	cl := cast(^Console_Cmd_List)this
	if cl.is_closed || cl.host_list == nil {
		cl.is_closed = true
		return S_OK
	}
	lvt := (cast(^^Host_Cmd_List_Vtbl)cl.host_list)^
	hr := lvt.Close(cl.host_list)
	if hr >= 0 {
		cl.is_closed = true
	} else {
		fmt.printf("[d3d12x] HostCmdList Close FAILED hr=0x%08X\n", u32(hr))
	}
	return hr
}

@(private)
cmdlist_reset :: proc "system" (this: This, alloc: rawptr, pso: rawptr) -> HRESULT {
	context = gpu_context()
	_ = alloc
	if this == nil { return E_INVALIDARG }
	cl := cast(^Console_Cmd_List)this
	for u in cl.uploads {
		free(u)
	}
	clear(&cl.uploads)
	recycle_cl_host_list(cl)
	cl.cur_pso = pso
	cl.bound_host_root = nil
	cl.bound_host_pso = nil
	cl.num_viewports = 0
	cl.num_scissors = 0
	cl.topology = 0
	cl.has_topology = false
	cl.vp_dirty = false
	cl.scissor_dirty = false
	cl.topo_dirty = false
	cl.vb_mask = 0
	cl.has_ib = false
	cl.num_cur_rts = 0
	cl.gfx_roots = {}
	cl.is_closed = false
	return S_OK
}

@(private)
cmdlist_reset_x :: proc "system" (this: This, alloc: rawptr, pso: rawptr, flags: u32) -> HRESULT {
	_ = flags
	return cmdlist_reset(this, alloc, pso)
}

@(private)
cmdlist_allocate_upload :: proc "system" (this: This, size: u64, alignment: u64) -> rawptr {
	context = gpu_context()
	if this == nil || size == 0 { return nil }
	if alignment == 0 || (alignment & (alignment - 1)) != 0 { return nil }
	align := max(int(alignment), 16)
	ptr, err := mem.alloc(int(size), align)
	if err != nil || ptr == nil { return nil }
	cl := cast(^Console_Cmd_List)this
	append(&cl.uploads, ptr)
	return ptr
}

@(private)
g_disp_log_count: u64

@(private)
cmdlist_dispatch :: proc "system" (this: This, x, y, z: u32) {
	context = gpu_context()
	intrinsics.atomic_add(&g_stat_dispatches, 1)
	_ = this; _ = x; _ = y; _ = z
}

@(private)
cmdlist_noop :: proc "system" (this: This) {
	_ = this
}

@(private)
cmdlist_noop_u64 :: proc "system" (this: This, a1, a2: u64) -> u64 {
	_ = this; _ = a1; _ = a2
	return 0
}

@(private)
cmdlist_barrier :: proc "system" (this: This, count: u32, barriers: rawptr) -> u32 {
	_ = this; _ = count; _ = barriers
	return 0
}

@(private)
cmdlist_copy_buffer_region :: proc "system" (this: This, dst: This, dst_off: u64, src: This, src_off: u64, num_bytes: u64) {
	_ = this
	if dst == nil || src == nil || num_bytes == 0 { return }
	dr := cast(^Console_Resource)dst
	sr := cast(^Console_Resource)src
	if dr.address < 0x10000 || sr.address < 0x10000 { return }
	mem.copy(rawptr(uintptr(dr.address + dst_off)), rawptr(uintptr(sr.address + src_off)), int(num_bytes))
}

@(private)
cmdlist_copy_texture_region :: proc "system" (
	this: This,
	dst_loc: ^D3D12_TEXTURE_COPY_LOCATION,
	dst_x, dst_y, dst_z: u32,
	src_loc: ^D3D12_TEXTURE_COPY_LOCATION,
	src_box: ^D3D12_BOX,
) {
	context = gpu_context()
	if this == nil { return }
	intrinsics.atomic_add(&g_stat_copies, 1)
	host_copy_texture_region(cast(^Console_Cmd_List)this, dst_loc, dst_x, dst_y, dst_z, src_loc, src_box)
}

@(private)
cmdlist_copy_texture_region_x :: proc "system" (
	this: This,
	dst_loc: ^D3D12_TEXTURE_COPY_LOCATION,
	dst_x, dst_y, dst_z: u32,
	src_loc: ^D3D12_TEXTURE_COPY_LOCATION,
	src_box: ^D3D12_BOX,
	flags: u32,
) {
	_ = flags
	cmdlist_copy_texture_region(this, dst_loc, dst_x, dst_y, dst_z, src_loc, src_box)
}

@(private)
cmdlist_copy_resource :: proc "system" (this: This, dst: This, src: This) {
	context = gpu_context()
	if dst == nil || src == nil { return }
	dr := cast(^Console_Resource)dst
	sr := cast(^Console_Resource)src
	if (dr.object.bits & 0xFF) == u32(Object_Kind.Resource) && (sr.object.bits & 0xFF) == u32(Object_Kind.Resource) {
		if this != nil && can_host_copy_resources(dr, sr) {
			cl := cast(^Console_Cmd_List)this
			dtex, _ := ensure_host_texture(dr)
			stex, _ := ensure_host_texture(sr)
			if dtex != nil && stex != nil {
				hl := ensure_cl_host_list(cl)
				if hl != nil {
					host_transition_resource(hl, dr, D3D12_RESOURCE_STATE_COPY_DEST)
					host_transition_resource(hl, sr, D3D12_RESOURCE_STATE_COPY_SOURCE)
					lvt := (cast(^^Host_Cmd_List_Vtbl)hl)^
					lvt.CopyResource(hl, dtex, stex)
					return
				}
			}
		}
	}
	if dr.address < 0x10000 || sr.address < 0x10000 { return }
	dsz, _ := estimate_resource_bytes(dr.desc)
	ssz, _ := estimate_resource_bytes(sr.desc)
	n := min(dsz, ssz)
	if n > 0 {
		mem.copy(rawptr(uintptr(dr.address)), rawptr(uintptr(sr.address)), int(n))
	}
}

@(private)
cmdlist_copy_resource_x :: proc "system" (this: This, dst: This, src: This, flags: u32) {
	_ = flags
	cmdlist_copy_resource(this, dst, src)
}

@(private)
cmdlist_ia_topology :: proc "system" (this: This, topology: u32) {
	context = gpu_context()
	if this == nil { return }
	cl := cast(^Console_Cmd_List)this
	mapped := map_host_topology(topology)
	cl.topology = mapped
	cl.raw_topology = topology
	cl.has_topology = true
	cl.topo_dirty = true
	if cl.host_list != nil && !cl.is_closed {
		lvt := (cast(^^Host_Cmd_List_Vtbl)cl.host_list)^
		lvt.IASetPrimitiveTopology(cl.host_list, mapped)
		cl.topo_dirty = false
	}
}

@(private)
cmdlist_rs_viewports :: proc "system" (this: This, num_viewports: u32, viewports: [^]D3D12_VIEWPORT) {
	context = gpu_context()
	if this == nil { return }
	cl := cast(^Console_Cmd_List)this
	if num_viewports == 0 || uintptr(viewports) < 0x10000 {
		cl.num_viewports = 0
		cl.vp_dirty = false
		return
	}
	n := min(num_viewports, u32(len(cl.viewports)))
	for i in 0 ..< n {
		cl.viewports[i] = viewports[i]
	}
	cl.num_viewports = n
	cl.vp_dirty = true
	if cl.host_list != nil && !cl.is_closed {
		lvt := (cast(^^Host_Cmd_List_Vtbl)cl.host_list)^
		lvt.RSSetViewports(cl.host_list, n, &cl.viewports[0])
		cl.vp_dirty = false
	}
}

@(private)
cmdlist_rs_scissors :: proc "system" (this: This, num_rects: u32, rects: [^]D3D12_RECT) {
	context = gpu_context()
	if this == nil { return }
	cl := cast(^Console_Cmd_List)this
	if num_rects == 0 || uintptr(rects) < 0x10000 {
		cl.num_scissors = 0
		cl.scissor_dirty = false
		return
	}
	n := min(num_rects, u32(len(cl.scissors)))
	for i in 0 ..< n {
		cl.scissors[i] = rects[i]
	}
	cl.num_scissors = n
	cl.scissor_dirty = true
	if cl.host_list != nil && !cl.is_closed {
		lvt := (cast(^^Host_Cmd_List_Vtbl)cl.host_list)^
		lvt.RSSetScissorRects(cl.host_list, n, &cl.scissors[0])
		cl.scissor_dirty = false
	}
}

@(private)
cmdlist_set_pipeline :: proc "system" (this: This, pso: rawptr) {
	context = gpu_context()
	if this == nil { return }
	cl := cast(^Console_Cmd_List)this
	cl.cur_pso = pso
	if cl.host_list != nil && !cl.is_closed && uintptr(pso) >= 0x10000 {
		p := cast(^Console_Pipeline)pso
		if (p.object.bits & 0xFF) == u32(Object_Kind.Pipeline) && !p.is_compute {
			root, hpso, ok := ensure_host_pipeline(p)
			if ok && root != nil && hpso != nil {
				lvt := (cast(^^Host_Cmd_List_Vtbl)cl.host_list)^
				if cl.bound_host_root != root {
					lvt.SetGraphicsRootSignature(cl.host_list, root)
					cl.bound_host_root = root
				}
				if cl.bound_host_pso != hpso {
					lvt.SetPipelineState(cl.host_list, hpso)
					cl.bound_host_pso = hpso
				}
			}
		}
	}
}

@(private)
cmdlist_set_gfx_root_table :: proc "system" (this: This, slot: u32, handle: u64) {
	if this == nil || slot >= 32 { return }
	cl := cast(^Console_Cmd_List)this
	cl.gfx_roots[slot].kind = 1
	cl.gfx_roots[slot].va = handle
}

@(private)
cmdlist_set_gfx_root_const :: proc "system" (this: This, slot: u32, val: u32, dest_offset: u32) {
	if this == nil || slot >= 32 || dest_offset >= 32 { return }
	cl := cast(^Console_Cmd_List)this
	cl.gfx_roots[slot].kind = 2
	cl.gfx_roots[slot].consts[dest_offset] = val
	if dest_offset + 1 > cl.gfx_roots[slot].num_consts {
		cl.gfx_roots[slot].num_consts = dest_offset + 1
	}
}

@(private)
cmdlist_set_gfx_root_consts :: proc "system" (this: This, slot: u32, count: u32, src: [^]u32, dest_offset: u32) {
	if this == nil || slot >= 32 || count == 0 || uintptr(src) < 0x10000 { return }
	cl := cast(^Console_Cmd_List)this
	cl.gfx_roots[slot].kind = 2
	for i in u32(0) ..< count {
		idx := dest_offset + i
		if idx >= 32 { break }
		cl.gfx_roots[slot].consts[idx] = src[i]
		if idx + 1 > cl.gfx_roots[slot].num_consts {
			cl.gfx_roots[slot].num_consts = idx + 1
		}
	}
}

@(private)
cmdlist_set_gfx_root_view :: proc "system" (this: This, slot: u32, gpu_va: u64) {
	if this == nil || slot >= 32 { return }
	cl := cast(^Console_Cmd_List)this
	cl.gfx_roots[slot].kind = 3
	cl.gfx_roots[slot].va = gpu_va
}

@(private)
cmdlist_ia_index_buffer :: proc "system" (this: This, view: ^D3D12_INDEX_BUFFER_VIEW) {
	if this == nil { return }
	cl := cast(^Console_Cmd_List)this
	if uintptr(view) < 0x10000 {
		cl.has_ib = false
		return
	}
	cl.ib_view = view^
	cl.has_ib = true
}

@(private)
cmdlist_ia_vertex_buffers :: proc "system" (this: This, start_slot: u32, num_views: u32, views: [^]D3D12_VERTEX_BUFFER_VIEW) {
	if this == nil || num_views == 0 || uintptr(views) < 0x10000 { return }
	cl := cast(^Console_Cmd_List)this
	for i in u32(0) ..< num_views {
		s := start_slot + i
		if s >= 8 { break }
		cl.vb_views[s] = views[i]
		if views[i].BufferLocation >= 0x10000 && views[i].SizeInBytes > 0 {
			cl.vb_mask |= (u8(1) << s)
		} else {
			cl.vb_mask &= ~(u8(1) << s)
		}
	}
}

@(private)
cmdlist_om_set_render_targets :: proc "system" (
	this: This,
	num_rtvs: u32,
	rtv_handles: [^]u64,
	single_handle: i32,
	dsv_handle: ^u64,
) {
	context = gpu_context()
	if this == nil { return }
	cl := cast(^Console_Cmd_List)this
	if cl.is_closed { return }

	rtv_crs: [8]^Console_Resource
	host_rtvs: [8]u64
	out_num_rtvs := u32(0)
	if num_rtvs > 0 && uintptr(rtv_handles) >= 0x10000 {
		n := min(num_rtvs, u32(8))
		step := u64(descriptor_increment(HEAP_KIND_RTV))
		base_h := rtv_handles[0] if single_handle != 0 else u64(0)
		for i in 0 ..< n {
			ch := base_h + u64(i) * step if single_handle != 0 else rtv_handles[i]
			cr, hr_h, ok := materialize_rtv_or_dsv(ch, false)
			if !ok { break }
			rtv_crs[out_num_rtvs] = cr
			host_rtvs[out_num_rtvs] = hr_h
			out_num_rtvs += 1
		}
	}

	dsv_cr: ^Console_Resource = nil
	host_dsv: u64 = 0
	has_dsv := false
	if uintptr(dsv_handle) >= 0x10000 {
		dcr, hd_h, ok := materialize_rtv_or_dsv(dsv_handle^, true)
		if ok {
			dsv_cr = dcr
			host_dsv = hd_h
			has_dsv = true
		}
	}

	if out_num_rtvs == 0 && !has_dsv {
		if num_rtvs == 0 && dsv_handle == nil && cl.host_list != nil {
			lvt := (cast(^^Host_Cmd_List_Vtbl)cl.host_list)^
			lvt.OMSetRenderTargets(cl.host_list, 0, nil, 0, nil)
		}
		return
	}

	hl := ensure_cl_host_list(cl)
	if hl == nil { return }
	cl.num_cur_rts = out_num_rtvs
	for i in 0 ..< out_num_rtvs {
		cl.cur_rts[i] = rtv_crs[i]
		host_transition_resource(hl, rtv_crs[i], D3D12_RESOURCE_STATE_RENDER_TARGET)
	}
	if has_dsv {
		host_transition_resource(hl, dsv_cr, D3D12_RESOURCE_STATE_DEPTH_WRITE)
	}
	lvt := (cast(^^Host_Cmd_List_Vtbl)hl)^
	rtv_ptr := &host_rtvs[0] if out_num_rtvs > 0 else nil
	dsv_ptr := &host_dsv if has_dsv else nil
	lvt.OMSetRenderTargets(hl, out_num_rtvs, rtv_ptr, 0, dsv_ptr)
}

@(private)
cmdlist_clear_dsv :: proc "system" (
	this: This,
	dsv_handle: u64,
	clear_flags: u32,
	depth: f32,
	stencil: u8,
	num_rects: u32,
	rects: rawptr,
) {
	context = gpu_context()
	if this == nil { return }
	cl := cast(^Console_Cmd_List)this
	if cl.is_closed { return }
	cr, host_dsv, ok := materialize_rtv_or_dsv(dsv_handle, true)
	if !ok { return }
	hl := ensure_cl_host_list(cl)
	if hl == nil { return }
	host_transition_resource(hl, cr, D3D12_RESOURCE_STATE_DEPTH_WRITE)
	n_rects := num_rects
	r_ptr := rects
	if n_rects > 0 && uintptr(r_ptr) < 0x10000 {
		n_rects = 0
		r_ptr = nil
	}
	lvt := (cast(^^Host_Cmd_List_Vtbl)hl)^
	lvt.ClearDepthStencilView(hl, host_dsv, clear_flags, depth, stencil, n_rects, r_ptr)
}

@(private)
cmdlist_clear_rtv :: proc "system" (
	this: This,
	cpu_handle: u64,
	color: ^[4]f32,
	num_rects: u32,
	rects: rawptr,
) {
	context = gpu_context()
	if this == nil || uintptr(color) < 0x10000 { return }
	cl := cast(^Console_Cmd_List)this
	if cl.is_closed { return }
	cr, host_rtv, ok := materialize_rtv_or_dsv(cpu_handle, false)
	if !ok { return }
	hl := ensure_cl_host_list(cl)
	if hl == nil { return }
	host_transition_resource(hl, cr, D3D12_RESOURCE_STATE_RENDER_TARGET)
	n_rects := num_rects
	r_ptr := rects
	if n_rects > 0 && uintptr(r_ptr) < 0x10000 {
		n_rects = 0
		r_ptr = nil
	}
	col := color^
	intrinsics.atomic_add(&g_stat_clears, 1)
	lvt := (cast(^^Host_Cmd_List_Vtbl)hl)^
	lvt.ClearRenderTargetView(hl, host_rtv, &col, n_rects, r_ptr)
}

@(private)
g_draw_log_count: u64

@(private)
cmdlist_draw_instanced :: proc "system" (
	this: This,
	vertex_count: u32,
	instance_count: u32,
	start_vertex: u32,
	start_instance: u32,
) {
	context = gpu_context()
	if this == nil { return }
	intrinsics.atomic_add(&g_stat_draws, 1)
	cl := cast(^Console_Cmd_List)this
	hl := prepare_host_draw(cl)
	if hl == nil { return }
	lvt := (cast(^^Host_Cmd_List_Vtbl)hl)^
	// Expand Xbox D3D_PRIMITIVE_TOPOLOGY_RECTLIST (17): 3 verts (v0,v1,v2) -> 2 tris (v0,v1,v2, v0,v2,v3)
	if cl.raw_topology == 17 && vertex_count >= 3 && (vertex_count % 3) == 0 && cl.vb_mask == 1 {
		v := cl.vb_views[0]
		st := v.StrideInBytes
		n_rects := vertex_count / 3
		src_off := u64(start_vertex) * u64(st)
		need := u64(vertex_count) * u64(st)
		if st >= 12 && st <= 256 && v.BufferLocation >= 0x10000 && src_off + need <= u64(v.SizeInBytes) {
			out_verts := n_rects * 6
			out_bytes := u32(out_verts) * st
			tmp := make([]u8, int(out_bytes), context.temp_allocator)
			src_ptr := cast([^]u8)rawptr(uintptr(v.BufferLocation + src_off))
			for ri in u32(0) ..< n_rects {
				v0 := src_ptr[(ri * 3 + 0) * st:]
				v1 := src_ptr[(ri * 3 + 1) * st:]
				v2 := src_ptr[(ri * 3 + 2) * st:]
				dst := tmp[(ri * 6) * st:]
				mem.copy(&dst[0 * st], &v0[0], int(st))
				mem.copy(&dst[1 * st], &v1[0], int(st))
				mem.copy(&dst[2 * st], &v2[0], int(st))
				mem.copy(&dst[3 * st], &v0[0], int(st))
				mem.copy(&dst[4 * st], &v2[0], int(st))
				mem.copy(&dst[5 * st], &v0[0], int(st))
				// v3 = v0 + v2 - v1 for xyz floats (and trailing uv floats if st == 24)
				f0 := cast([^]f32)&v0[0]
				f1 := cast([^]f32)&v1[0]
				f2 := cast([^]f32)&v2[0]
				f3 := cast([^]f32)&dst[5 * st]
				f3[0] = f0[0] + f2[0] - f1[0]
				f3[1] = f0[1] + f2[1] - f1[1]
				f3[2] = f0[2] + f2[2] - f1[2]
				if st == 24 {
					f3[4] = f0[4] + f2[4] - f1[4]
					f3[5] = f0[5] + f2[5] - f1[5]
				}
			}
			if gpu_va := upload_cpu_to_host_buf(cl, u64(uintptr(&tmp[0])), out_bytes); gpu_va != 0 {
				hv := D3D12_VERTEX_BUFFER_VIEW{BufferLocation = gpu_va, SizeInBytes = out_bytes, StrideInBytes = st}
				lvt.IASetVertexBuffers(hl, 0, 1, &hv)
				lvt.DrawInstanced(hl, out_verts, instance_count, 0, start_instance)
				return
			}
		}
	}
	lvt.DrawInstanced(hl, vertex_count, instance_count, start_vertex, start_instance)
}

@(private)
g_idx_log_count: u64

@(private)
cmdlist_draw_indexed_instanced :: proc "system" (
	this: This,
	index_count: u32,
	instance_count: u32,
	start_index: u32,
	base_vertex: i32,
	start_instance: u32,
) {
	context = gpu_context()
	if this == nil { return }
	intrinsics.atomic_add(&g_stat_indexed, 1)
	cl := cast(^Console_Cmd_List)this
	hl := prepare_host_draw(cl)
	if hl == nil { return }
	if cl.num_cur_rts > 0 && cl.cur_rts[0] != nil {
		g_last_indexed_rt = cl.cur_rts[0]
	}
	lvt := (cast(^^Host_Cmd_List_Vtbl)hl)^
	lvt.DrawIndexedInstanced(hl, index_count, instance_count, start_index, base_vertex, start_instance)
}

@(private)
cmdlist_copy_memory :: proc "system" (this: This, dst: u64, src: u64, length: u64, flags: u32) {
	_ = this; _ = flags
	if dst < 0x10000 || src < 0x10000 || length == 0 { return }
	mem.copy(rawptr(uintptr(dst)), rawptr(uintptr(src)), int(length))
}

@(private)
cmdlist_write32 :: proc "system" (this: This, addr: u64, val: u32, flags: u32) {
	_ = this; _ = flags
	if addr > 0x10000 {
		(cast(^u32)rawptr(uintptr(addr)))^ = val
	}
}

@(private)
cmdlist_write64 :: proc "system" (this: This, addr: u64, val: u64, flags: u32) {
	_ = this; _ = flags
	if addr > 0x10000 {
		(cast(^u64)rawptr(uintptr(addr)))^ = val
	}
}

@(private)
cmdlist_wait_noop :: proc "system" (this: This, addr: u64, cmp: u32, ref: u64, mask: u32, flags: u32) {
	_ = this; _ = addr; _ = cmp; _ = ref; _ = mask; _ = flags
}

@(private)
cmdlist_stub_slot :: proc "system" (this: This, a1, a2, a3: uintptr) -> HRESULT {
	context = gpu_context()
	_ = this
	off := decode_vtable_slot(intrinsics.return_address())
	fmt.printf("[d3d12x] CmdList unimpl slot #%d (off=0x%X a1=0x%X a2=0x%X a3=0x%X)\n", off / 8, off, a1, a2, a3)
	return S_OK
}

wrap_console_cmd_list :: proc(host_list: rawptr, kind: u32, closed: bool) -> rawptr {
	cl := new(Console_Cmd_List)
	vt := &g_cmdlist_newer_vtable[0] if g_newer_device else &g_cmdlist_vtable[0]
	cl.object = Gpu_Object{functions = vt, bits = u32(Object_Kind.List), refs = 1}
	cl.kind = kind
	cl.host_list = host_list
	cl.is_closed = closed
	return rawptr(cl)
}

// =========================================================================
// Vtable Initialization
// =========================================================================

@(private)
fill_d3d12_object_slots :: proc "contextless" (tbl: []rawptr, qi, rel: rawptr) {
	tbl[0] = qi
	tbl[1] = rawptr(object_add_ref)
	tbl[2] = rel
	tbl[3] = rawptr(object_get_private_data)
	tbl[4] = rawptr(object_set_private_data)
	tbl[5] = rawptr(object_set_private_data_interface)
	tbl[6] = rawptr(object_set_name)
}

@(init)
init_console_object_vtables :: proc "contextless" () {
	// Fence (24 slots)
	for i in 0 ..< len(g_fence_vtable) { g_fence_vtable[i] = rawptr(fence_stub) }
	fill_d3d12_object_slots(g_fence_vtable[:], rawptr(fence_qi), rawptr(fence_release))
	g_fence_vtable[7] = rawptr(object_parent_device)
	g_fence_vtable[8] = rawptr(fence_completed)
	g_fence_vtable[9] = rawptr(cfence_set_event)
	g_fence_vtable[10] = rawptr(cfence_signal)
	g_fence_vtable[11] = rawptr(fence_creation_flags)
	g_fence_vtable[12] = rawptr(fence_gpu_address)

	// Queue (36 slots, classic and newer where slot >= 14 shifts +2)
	for i in 0 ..< len(g_queue_vtable) {
		g_queue_vtable[i] = rawptr(queue_stub)
		g_queue_newer_vtable[i] = rawptr(queue_stub)
	}
	fill_d3d12_object_slots(g_queue_vtable[:], rawptr(queue_qi), rawptr(queue_release))
	fill_d3d12_object_slots(g_queue_newer_vtable[:], rawptr(queue_qi), rawptr(queue_release))

	Queue_Entry :: struct { slot: int, fn: rawptr }
	q_methods := [?]Queue_Entry{
		{7,  rawptr(object_parent_device)},
		{10, rawptr(queue_execute)},
		{11, rawptr(queue_marker)},
		{12, rawptr(queue_marker)},
		{13, rawptr(queue_marker)},
		{14, rawptr(queue_signal)},
		{15, rawptr(queue_wait)},
		{16, rawptr(queue_timestamp_freq)},
		{26, rawptr(queue_get_desc)},
		{29, rawptr(queue_copy_page_mappings)},
		{30, rawptr(queue_present_x)},
		{32, rawptr(queue_signal2_x)},
		{33, rawptr(queue_execute_x)},
	}
	for m in q_methods {
		g_queue_vtable[m.slot] = m.fn
		ns := m.slot + 2 if m.slot >= 14 else m.slot
		if ns < len(g_queue_newer_vtable) {
			g_queue_newer_vtable[ns] = m.fn
		}
	}

	// Allocator (24 slots)
	for i in 0 ..< len(g_alloc_vtable) { g_alloc_vtable[i] = rawptr(alloc_stub) }
	fill_d3d12_object_slots(g_alloc_vtable[:], rawptr(alloc_qi), rawptr(alloc_release))
	g_alloc_vtable[7] = rawptr(object_parent_device)
	g_alloc_vtable[8] = rawptr(alloc_reset)
	g_alloc_vtable[9] = rawptr(alloc_reset)

	// Command List (160 slots, classic and newer where slot >= 59 shifts +2)
	for i in 0 ..< len(g_cmdlist_vtable) {
		g_cmdlist_vtable[i] = rawptr(cmdlist_stub_slot)
		g_cmdlist_newer_vtable[i] = rawptr(cmdlist_stub_slot)
	}
	fill_d3d12_object_slots(g_cmdlist_vtable[:], rawptr(cmdlist_qi), rawptr(cmdlist_release))
	fill_d3d12_object_slots(g_cmdlist_newer_vtable[:], rawptr(cmdlist_qi), rawptr(cmdlist_release))

	List_Entry :: struct { slot: int, fn: rawptr }
	l_methods := [?]List_Entry{
		{7,   rawptr(object_parent_device)},
		{8,   rawptr(cmdlist_get_type)},
		{9,   rawptr(cmdlist_close)},
		{10,  rawptr(cmdlist_reset)},
		{12,  rawptr(cmdlist_draw_instanced)}, // DrawInstanced
		{13,  rawptr(cmdlist_draw_indexed_instanced)}, // DrawIndexedInstanced
		{14,  rawptr(cmdlist_dispatch)}, // Dispatch
		{15,  rawptr(cmdlist_copy_buffer_region)}, // CopyBufferRegion
		{16,  rawptr(cmdlist_copy_texture_region)}, // CopyTextureRegion
		{17,  rawptr(cmdlist_copy_resource)}, // CopyResource
		{19,  rawptr(cmdlist_noop)}, // ResolveSubresource
		{20,  rawptr(cmdlist_ia_topology)}, // IASetPrimitiveTopology
		{21,  rawptr(cmdlist_rs_viewports)}, // RSSetViewports
		{22,  rawptr(cmdlist_rs_scissors)}, // RSSetScissorRects
		{23,  rawptr(cmdlist_noop)}, // OMSetBlendFactor
		{24,  rawptr(cmdlist_noop)}, // OMSetStencilRef
		{25,  rawptr(cmdlist_set_pipeline)}, // SetPipelineState
		{26,  rawptr(cmdlist_barrier)},
		{28,  rawptr(cmdlist_noop)}, // BeginQuery
		{29,  rawptr(cmdlist_noop)}, // EndQuery
		{30,  rawptr(cmdlist_noop)}, // ResolveQueryData
		{32,  rawptr(cmdlist_noop)}, // SetDescriptorHeaps
		{33,  rawptr(cmdlist_noop)}, // SetComputeRootSignature
		{34,  rawptr(cmdlist_noop)}, // SetGraphicsRootSignature
		{35,  rawptr(cmdlist_noop)}, // SetComputeRootDescriptorTable
		{36,  rawptr(cmdlist_set_gfx_root_table)}, // SetGraphicsRootDescriptorTable
		{37,  rawptr(cmdlist_noop)}, // SetComputeRoot32BitConstant
		{38,  rawptr(cmdlist_set_gfx_root_const)}, // SetGraphicsRoot32BitConstant
		{39,  rawptr(cmdlist_noop)}, // SetComputeRoot32BitConstants
		{40,  rawptr(cmdlist_set_gfx_root_consts)}, // SetGraphicsRoot32BitConstants
		{41,  rawptr(cmdlist_noop)}, // SetComputeRootCBV
		{42,  rawptr(cmdlist_set_gfx_root_view)}, // SetGraphicsRootCBV
		{43,  rawptr(cmdlist_noop)}, // SetComputeRootSRV
		{44,  rawptr(cmdlist_set_gfx_root_view)}, // SetGraphicsRootSRV
		{45,  rawptr(cmdlist_noop)}, // SetComputeRootUAV
		{46,  rawptr(cmdlist_set_gfx_root_view)}, // SetGraphicsRootUAV
		{47,  rawptr(cmdlist_ia_index_buffer)}, // IASetIndexBuffer
		{48,  rawptr(cmdlist_ia_vertex_buffers)}, // IASetVertexBuffers
		{50,  rawptr(cmdlist_om_set_render_targets)}, // OMSetRenderTargets
		{51,  rawptr(cmdlist_clear_dsv)}, // ClearDepthStencilView
		{52,  rawptr(cmdlist_clear_rtv)}, // ClearRenderTargetView
		{53,  rawptr(cmdlist_noop)}, // ClearUAVUint
		{54,  rawptr(cmdlist_noop)}, // ClearUAVFloat
		{55,  rawptr(cmdlist_noop)}, // DiscardResource
		{59,  rawptr(cmdlist_noop)}, // ExecuteIndirect
		{60,  rawptr(cmdlist_copy_memory)}, // CopyMemory
		{68,  rawptr(cmdlist_noop)}, // DepthBounds
		{69,  rawptr(cmdlist_write32)},
		{70,  rawptr(cmdlist_write64)},
		{71,  rawptr(cmdlist_wait_noop)},
		{72,  rawptr(cmdlist_wait_noop)},
		{73,  rawptr(cmdlist_noop)}, // PS depth order
		{78,  rawptr(cmdlist_dispatch)}, // DispatchX
		{83,  rawptr(cmdlist_copy_texture_region_x)}, // CopyTextureRegionX
		{84,  rawptr(cmdlist_copy_resource_x)}, // CopyResourceX
		{98,  rawptr(cmdlist_noop)}, // DispatchMeshX
		{99,  rawptr(cmdlist_noop_u64)}, // driver hint
		{124, rawptr(cmdlist_noop)}, // shading rate
		{127, rawptr(cmdlist_noop)}, // DispatchMesh
		{129, rawptr(cmdlist_noop)}, // top-of-pipe sync
		{130, rawptr(cmdlist_noop)}, // bottom-of-pipe sync
		{137, rawptr(cmdlist_reset_x)},
	}
	for m in l_methods {
		g_cmdlist_vtable[m.slot] = m.fn
		ns := m.slot + 2 if m.slot >= 59 else m.slot
		if ns < len(g_cmdlist_newer_vtable) {
			g_cmdlist_newer_vtable[ns] = m.fn
		}
	}
	// Newer-only methods
	g_cmdlist_newer_vtable[142] = rawptr(cmdlist_noop)
	g_cmdlist_newer_vtable[146] = rawptr(cmdlist_noop) // barrier_groups
	g_cmdlist_newer_vtable[148] = rawptr(cmdlist_allocate_upload)
}
