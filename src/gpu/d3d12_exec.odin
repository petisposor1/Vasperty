package vasperty_gpu

import win32 "core:sys/windows"

// Real D3D12 Host Execution Engine (ID3D12Device + Direct/Async-Compute Queues +
// per-slot ID3D12CommandAllocator ring + ID3D12GraphicsCommandList + ID3D12Fence).
// Driven by Vendor_Tuning and Frame_Ring so Intel UMA runs 2 frames in flight and
// NVIDIA/AMD run 3 frames in flight with optional Async Compute queue.

IID_ID3D12CommandQueue_G        := guid(0x0ec870a6, 0x5d7e, 0x4c22, {0x8c, 0xfc, 0x5b, 0xaa, 0xe0, 0x76, 0x16, 0xed})
IID_ID3D12CommandAllocator_G    := guid(0x6102dee4, 0xaf59, 0x4b09, {0xb9, 0x99, 0xb4, 0x4d, 0x73, 0xf0, 0x9b, 0x24})
IID_ID3D12GraphicsCommandList_G := guid(0x5b160d0f, 0xac1b, 0x4185, {0x8b, 0xa8, 0xb3, 0xae, 0x42, 0xa5, 0xa4, 0x55})
IID_ID3D12Fence_G               := guid(0x0a753dcf, 0xc4d8, 0x4b91, {0xad, 0xf6, 0xbe, 0x5a, 0x60, 0xd9, 0x5a, 0x76})

D3D12_COMMAND_LIST_TYPE_DIRECT  :: u32(0)
D3D12_COMMAND_LIST_TYPE_COMPUTE :: u32(2)

D3D12_COMMAND_QUEUE_DESC :: struct {
	Type:     u32,
	Priority: i32,
	Flags:    u32,
	NodeMask: u32,
}

@(private)
Exec_Dev_Vtbl :: struct {
	_pad0:                  [8]rawptr, // IUnknown(3) + ID3D12Object(4) + GetNodeCount(1)
	CreateCommandQueue:     proc "system" (rawptr, ^D3D12_COMMAND_QUEUE_DESC, ^Iid, ^rawptr) -> HRESULT, // 8
	CreateCommandAllocator: proc "system" (rawptr, u32, ^Iid, ^rawptr) -> HRESULT,                       // 9
	_pad1:                  [2]rawptr,                                                                    // 10..11
	CreateCommandList:      proc "system" (rawptr, u32, u32, rawptr, rawptr, ^Iid, ^rawptr) -> HRESULT,  // 12
	_pad2:                  [23]rawptr,                                                                   // 13..35
	CreateFence:            proc "system" (rawptr, u64, u32, ^Iid, ^rawptr) -> HRESULT,                  // 36
}

@(private)
Exec_Queue_Vtbl :: struct {
	_pad0:               [10]rawptr, // IUnknown(3)+Object(4)+DeviceChild(1)+Tile(2)
	ExecuteCommandLists: proc "system" (rawptr, u32, ^rawptr),         // 10
	_pad1:               [3]rawptr,                                     // 11..13
	Signal:              proc "system" (rawptr, rawptr, u64) -> HRESULT, // 14
}

@(private)
Exec_Alloc_Vtbl :: struct {
	_pad0: [8]rawptr,
	Reset: proc "system" (rawptr) -> HRESULT, // 8
}

@(private)
Exec_List_Vtbl :: struct {
	_pad0: [9]rawptr,
	Close: proc "system" (rawptr) -> HRESULT,                // 9
	Reset: proc "system" (rawptr, rawptr, rawptr) -> HRESULT, // 10
}

@(private)
Exec_Fence_Vtbl :: struct {
	_pad0:                [8]rawptr,
	GetCompletedValue:    proc "system" (rawptr) -> u64,                         // 8
	SetEventOnCompletion: proc "system" (rawptr, u64, win32.HANDLE) -> HRESULT, // 9
}

Host_Executor :: struct {
	ready:           bool,
	device:          rawptr,
	direct_queue:    rawptr,
	compute_queue:   rawptr, // non-nil when tuning.prefer_async_compute is true
	fence:           rawptr,
	fence_event:     win32.HANDLE,
	allocators:      [dynamic]rawptr,
	cmd_list:        rawptr,
	list_closed:     bool,
	ring:            Frame_Ring,
	tuning:          Vendor_Tuning,
	frames_submitted: u64,
	last_fence:      u64,
}

host_executor_init :: proc(allow_warp := true) -> (ex: Host_Executor, ok: bool) {
	dlls := ensure_d3d12_dlls()
	if dlls.create_device == nil {
		return {}, false
	}

	caps := probe_capabilities(allow_warp)
	defer destroy_host_capabilities(&caps)
	ex.tuning = classify_vendor(&caps)

	D3D_FEATURE_LEVEL_12_0 :: u32(0xC000)
	dev_iid := guid(0x189819f1, 0x1db6, 0x4b57, {0xbe, 0x54, 0x18, 0x21, 0x33, 0x9b, 0x85, 0xf7})
	hr := dlls.create_device(nil, D3D_FEATURE_LEVEL_12_0, &dev_iid, &ex.device)
	if (hr < 0 || ex.device == nil) && allow_warp && dlls.create_dxgi_fac2 != nil {
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
				hr = dlls.create_device(warp_adp, D3D_FEATURE_LEVEL_12_0, &dev_iid, &ex.device)
			}
		}
	}
	if hr < 0 || ex.device == nil {
		return {}, false
	}

	dvt := (cast(^^Exec_Dev_Vtbl)ex.device)^
	q_desc := D3D12_COMMAND_QUEUE_DESC{Type = D3D12_COMMAND_LIST_TYPE_DIRECT}
	q_iid := IID_ID3D12CommandQueue_G
	if dvt.CreateCommandQueue(ex.device, &q_desc, &q_iid, &ex.direct_queue) < 0 || ex.direct_queue == nil {
		host_executor_destroy(&ex)
		return {}, false
	}

	if ex.tuning.prefer_async_compute {
		cq_desc := D3D12_COMMAND_QUEUE_DESC{Type = D3D12_COMMAND_LIST_TYPE_COMPUTE}
		_ = dvt.CreateCommandQueue(ex.device, &cq_desc, &q_iid, &ex.compute_queue)
	}

	f_iid := IID_ID3D12Fence_G
	if dvt.CreateFence(ex.device, 0, 0, &f_iid, &ex.fence) < 0 || ex.fence == nil {
		host_executor_destroy(&ex)
		return {}, false
	}

	ex.fence_event = win32.CreateEventW(nil, false, false, nil)
	if ex.fence_event == nil {
		host_executor_destroy(&ex)
		return {}, false
	}

	n_slots := max(int(ex.tuning.max_frames_in_flight), 2)
	ex.ring = frame_ring_init(n_slots)
	ex.allocators = make([dynamic]rawptr, n_slots)
	a_iid := IID_ID3D12CommandAllocator_G
	for i := 0; i < n_slots; i += 1 {
		if dvt.CreateCommandAllocator(ex.device, D3D12_COMMAND_LIST_TYPE_DIRECT, &a_iid, &ex.allocators[i]) < 0 {
			host_executor_destroy(&ex)
			return {}, false
		}
	}

	l_iid := IID_ID3D12GraphicsCommandList_G
	if dvt.CreateCommandList(ex.device, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, ex.allocators[0], nil, &l_iid, &ex.cmd_list) < 0 || ex.cmd_list == nil {
		host_executor_destroy(&ex)
		return {}, false
	}
	lvt := (cast(^^Exec_List_Vtbl)ex.cmd_list)^
	_ = lvt.Close(ex.cmd_list)
	ex.list_closed = true
	ex.ready = true
	return ex, true
}

host_executor_wait_fence :: proc(ex: ^Host_Executor, value: u64) {
	if ex == nil || ex.fence == nil || value == 0 {
		return
	}
	fvt := (cast(^^Exec_Fence_Vtbl)ex.fence)^
	done := fvt.GetCompletedValue(ex.fence)
	if done >= value {
		frame_ring_complete(&ex.ring, done)
		return
	}
	if fvt.SetEventOnCompletion(ex.fence, value, ex.fence_event) >= 0 {
		_ = win32.WaitForSingleObject(ex.fence_event, win32.INFINITE)
	}
	frame_ring_complete(&ex.ring, fvt.GetCompletedValue(ex.fence))
}

host_executor_begin_frame :: proc(ex: ^Host_Executor) -> (slot_idx: int, ok: bool) {
	if ex == nil || !ex.ready {
		return 0, false
	}
	fvt := (cast(^^Exec_Fence_Vtbl)ex.fence)^
	frame_ring_complete(&ex.ring, fvt.GetCompletedValue(ex.fence))

	slot, wait_f, need_wait := frame_ring_begin(&ex.ring)
	if need_wait {
		host_executor_wait_fence(ex, wait_f)
		slot, _, _ = frame_ring_begin(&ex.ring)
	}

	alloc := ex.allocators[slot]
	avt := (cast(^^Exec_Alloc_Vtbl)alloc)^
	if avt.Reset(alloc) < 0 {
		return 0, false
	}
	lvt := (cast(^^Exec_List_Vtbl)ex.cmd_list)^
	if lvt.Reset(ex.cmd_list, alloc, nil) < 0 {
		return 0, false
	}
	ex.list_closed = false
	return slot, true
}

host_executor_submit_frame :: proc(ex: ^Host_Executor, slot_idx: int) -> (fence_val: u64, ok: bool) {
	if ex == nil || !ex.ready {
		return 0, false
	}
	if !ex.list_closed {
		lvt := (cast(^^Exec_List_Vtbl)ex.cmd_list)^
		if lvt.Close(ex.cmd_list) < 0 {
			return 0, false
		}
		ex.list_closed = true
	}
	qvt := (cast(^^Exec_Queue_Vtbl)ex.direct_queue)^
	lists := [1]rawptr{ex.cmd_list}
	qvt.ExecuteCommandLists(ex.direct_queue, 1, &lists[0])

	f := frame_ring_submit(&ex.ring, slot_idx)
	if qvt.Signal(ex.direct_queue, ex.fence, f) < 0 {
		return 0, false
	}
	ex.last_fence = f
	ex.frames_submitted += 1
	return f, true
}

host_executor_drain :: proc(ex: ^Host_Executor) {
	if ex == nil || !ex.ready {
		return
	}
	host_executor_wait_fence(ex, ex.last_fence)
}

host_executor_destroy :: proc(ex: ^Host_Executor) {
	if ex == nil {
		return
	}
	if ex.ready {
		host_executor_drain(ex)
	}
	if ex.cmd_list != nil {
		com_release(ex.cmd_list)
		ex.cmd_list = nil
	}
	for a in ex.allocators {
		if a != nil {
			com_release(a)
		}
	}
	delete(ex.allocators)
	ex.allocators = nil
	frame_ring_destroy(&ex.ring)
	if ex.fence_event != nil {
		_ = win32.CloseHandle(ex.fence_event)
		ex.fence_event = nil
	}
	if ex.fence != nil {
		com_release(ex.fence)
		ex.fence = nil
	}
	if ex.compute_queue != nil {
		com_release(ex.compute_queue)
		ex.compute_queue = nil
	}
	if ex.direct_queue != nil {
		com_release(ex.direct_queue)
		ex.direct_queue = nil
	}
	if ex.device != nil {
		com_release(ex.device)
		ex.device = nil
	}
	ex.ready = false
}
