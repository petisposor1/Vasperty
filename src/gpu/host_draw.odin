package vasperty_gpu

import "base:intrinsics"
import "core:mem"
import "core:sync"
import win32 "core:sys/windows"
import vasperty_formats "vasperty:formats"
import vasperty_shader "vasperty:shader"

// Draw & PSO telemetry counters
g_stat_draws:      u64
g_stat_indexed:    u64
g_stat_clears:     u64
g_stat_copies:     u64
g_stat_dispatches: u64
g_stat_pso_ok:     u64
g_stat_pso_fail:   u64
g_last_drawn_rt:   ^Console_Resource
g_last_indexed_rt: ^Console_Resource

D3D12_VERTEX_BUFFER_VIEW :: struct {
	BufferLocation: u64,
	SizeInBytes:    u32,
	StrideInBytes:  u32,
}
#assert(size_of(D3D12_VERTEX_BUFFER_VIEW) == 16)

D3D12_INDEX_BUFFER_VIEW :: struct {
	BufferLocation: u64,
	SizeInBytes:    u32,
	Format:         u32,
}
#assert(size_of(D3D12_INDEX_BUFFER_VIEW) == 16)

// =========================================================================
// Host D3D12 Command-List Pool, RTV/DSV Descriptor Rings & Draw Helpers
// =========================================================================

D3D12_RESOURCE_STATE_GENERIC_READ             :: u32(0xAC3)
D3D12_RESOURCE_STATE_UNORDERED_ACCESS         :: u32(0x8)
D3D12_RESOURCE_STATE_DEPTH_WRITE              :: u32(0x10)
D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE :: u32(0x40)

D3D12_DESCRIPTOR_HEAP_TYPE_DSV :: u32(3)
D3D12_HEAP_TYPE_UPLOAD         :: u32(2)

RTV_RING_CAPACITY :: u32(256)
DSV_RING_CAPACITY :: u32(64)

D3D12_VIEWPORT :: struct {
	TopLeftX: f32,
	TopLeftY: f32,
	Width:    f32,
	Height:   f32,
	MinDepth: f32,
	MaxDepth: f32,
}
#assert(size_of(D3D12_VIEWPORT) == 24)

D3D12_RECT :: struct {
	left:   i32,
	top:    i32,
	right:  i32,
	bottom: i32,
}
#assert(size_of(D3D12_RECT) == 16)

@(private)
Draw_Dev_Vtbl :: struct {
	_pad0:                            [9]rawptr,                                                                                                           // 0..8
	CreateCommandAllocator:           proc "system" (rawptr, u32, ^Iid, ^rawptr) -> HRESULT,                                                               // 9
	_pad1:                            [2]rawptr,                                                                                                           // 10..11
	CreateCommandList:                proc "system" (rawptr, u32, u32, rawptr, rawptr, ^Iid, ^rawptr) -> HRESULT,                                          // 12
	_pad2:                            rawptr,                                                                                                              // 13
	CreateDescriptorHeap:             proc "system" (rawptr, ^D3D12_DESCRIPTOR_HEAP_DESC, ^Iid, ^rawptr) -> HRESULT,                                       // 14
	GetDescriptorHandleIncrementSize: proc "system" (rawptr, u32) -> u32,                                                                                  // 15
	_pad3a:                           [2]rawptr,                                                                                                           // 16..17
	CreateShaderResourceView:         proc "system" (rawptr, rawptr, rawptr, u64),                                                                         // 18
	CreateUnorderedAccessView:        proc "system" (rawptr, rawptr, rawptr, rawptr, u64),                                                                 // 19
	CreateRenderTargetView:           proc "system" (rawptr, rawptr, rawptr, u64),                                                                         // 20
	CreateDepthStencilView:           proc "system" (rawptr, rawptr, rawptr, u64),                                                                         // 21
	_pad4:                            [5]rawptr,                                                                                                           // 22..26
	CreateCommittedResource:          proc "system" (rawptr, ^D3D12_HEAP_PROPERTIES, u32, ^D3D12_RESOURCE_DESC, u32, rawptr, ^Iid, ^rawptr) -> HRESULT,    // 27
	_pad5:                            [8]rawptr,                                                                                                           // 28..35
	CreateFence:                      proc "system" (rawptr, u64, u32, ^Iid, ^rawptr) -> HRESULT,                                                          // 36
}
#assert(offset_of(Draw_Dev_Vtbl, CreateUnorderedAccessView) == 19 * size_of(rawptr))
#assert(offset_of(Draw_Dev_Vtbl, CreateRenderTargetView) == 20 * size_of(rawptr))
#assert(offset_of(Draw_Dev_Vtbl, CreateDepthStencilView) == 21 * size_of(rawptr))
#assert(offset_of(Draw_Dev_Vtbl, CreateCommittedResource) == 27 * size_of(rawptr))
#assert(offset_of(Draw_Dev_Vtbl, CreateFence) == 36 * size_of(rawptr))

@(private)
Host_Cmd_List_Vtbl :: struct {
	_pad0:                    [9]rawptr,                                                                                                 // 0..8
	Close:                    proc "system" (rawptr) -> HRESULT,                                                                         // 9
	Reset:                    proc "system" (rawptr, rawptr, rawptr) -> HRESULT,                                                         // 10
	_pad1:                    rawptr,                                                                                                    // 11
	DrawInstanced:            proc "system" (rawptr, u32, u32, u32, u32),                                                                // 12
	DrawIndexedInstanced:     proc "system" (rawptr, u32, u32, u32, i32, u32),                                                           // 13
	Dispatch:                 proc "system" (rawptr, u32, u32, u32),                                                                     // 14
	_pad2:                    rawptr,                                                                                                    // 15
	CopyTextureRegion:        proc "system" (rawptr, ^D3D12_TEXTURE_COPY_LOCATION, u32, u32, u32, ^D3D12_TEXTURE_COPY_LOCATION, rawptr), // 16
	CopyResource:             proc "system" (rawptr, rawptr, rawptr),                                                                    // 17
	_pad3:                    [2]rawptr,                                                                                                 // 18..19
	IASetPrimitiveTopology:   proc "system" (rawptr, u32),                                                                               // 20
	RSSetViewports:           proc "system" (rawptr, u32, ^D3D12_VIEWPORT),                                                              // 21
	RSSetScissorRects:        proc "system" (rawptr, u32, ^D3D12_RECT),                                                                  // 22
	OMSetBlendFactor:         proc "system" (rawptr, ^[4]f32),                                                                           // 23
	OMSetStencilRef:          proc "system" (rawptr, u32),                                                                               // 24
	SetPipelineState:            proc "system" (rawptr, rawptr),                                                                            // 25
	ResourceBarrier:             proc "system" (rawptr, u32, ^D3D12_RESOURCE_BARRIER),                                                      // 26
	_pad5:                       rawptr,                                                                                                    // 27
	SetDescriptorHeaps:          proc "system" (rawptr, u32, ^rawptr),                                                                      // 28
	SetComputeRootSignature:        proc "system" (rawptr, rawptr),                                                                            // 29
	SetGraphicsRootSignature:       proc "system" (rawptr, rawptr),                                                                            // 30
	SetComputeRootDescriptorTable:  proc "system" (rawptr, u32, u64),                                                                          // 31
	SetGraphicsRootDescriptorTable: proc "system" (rawptr, u32, u64),                                                                          // 32
	_pad6a1:                        [2]rawptr,                                                                                                 // 33..34
	SetComputeRoot32BitConsts:      proc "system" (rawptr, u32, u32, rawptr, u32),                                                             // 35
	SetGraphicsRoot32BitConsts:     proc "system" (rawptr, u32, u32, rawptr, u32),                                                             // 36
	SetComputeRootCBV:              proc "system" (rawptr, u32, u64),                                                                          // 37
	SetGraphicsRootCBV:             proc "system" (rawptr, u32, u64),                                                                          // 38
	SetComputeRootSRV:              proc "system" (rawptr, u32, u64),                                                                          // 39
	SetGraphicsRootSRV:             proc "system" (rawptr, u32, u64),                                                                          // 40
	SetComputeRootUAV:              proc "system" (rawptr, u32, u64),                                                                          // 41
	SetGraphicsRootUAV:             proc "system" (rawptr, u32, u64),                                                                          // 42
	IASetIndexBuffer:            proc "system" (rawptr, ^D3D12_INDEX_BUFFER_VIEW),                                                          // 43
	IASetVertexBuffers:          proc "system" (rawptr, u32, u32, ^D3D12_VERTEX_BUFFER_VIEW),                                               // 44
	_pad6c:                      rawptr,                                                                                                    // 45
	OMSetRenderTargets:          proc "system" (rawptr, u32, ^u64, i32, ^u64),                                                              // 46
	ClearDepthStencilView:       proc "system" (rawptr, u64, u32, f32, u8, u32, rawptr),                                                    // 47
	ClearRenderTargetView:       proc "system" (rawptr, u64, ^[4]f32, u32, rawptr),                                                         // 48
}
#assert(offset_of(Host_Cmd_List_Vtbl, DrawInstanced) == 12 * size_of(rawptr))
#assert(offset_of(Host_Cmd_List_Vtbl, Dispatch) == 14 * size_of(rawptr))
#assert(offset_of(Host_Cmd_List_Vtbl, CopyTextureRegion) == 16 * size_of(rawptr))
#assert(offset_of(Host_Cmd_List_Vtbl, SetDescriptorHeaps) == 28 * size_of(rawptr))
#assert(offset_of(Host_Cmd_List_Vtbl, SetComputeRootSignature) == 29 * size_of(rawptr))
#assert(offset_of(Host_Cmd_List_Vtbl, SetGraphicsRootSignature) == 30 * size_of(rawptr))
#assert(offset_of(Host_Cmd_List_Vtbl, SetComputeRootDescriptorTable) == 31 * size_of(rawptr))
#assert(offset_of(Host_Cmd_List_Vtbl, SetComputeRoot32BitConsts) == 35 * size_of(rawptr))
#assert(offset_of(Host_Cmd_List_Vtbl, SetGraphicsRoot32BitConsts) == 36 * size_of(rawptr))
#assert(offset_of(Host_Cmd_List_Vtbl, SetComputeRootCBV) == 37 * size_of(rawptr))
#assert(offset_of(Host_Cmd_List_Vtbl, SetGraphicsRootCBV) == 38 * size_of(rawptr))
#assert(offset_of(Host_Cmd_List_Vtbl, SetComputeRootSRV) == 39 * size_of(rawptr))
#assert(offset_of(Host_Cmd_List_Vtbl, SetGraphicsRootSRV) == 40 * size_of(rawptr))
#assert(offset_of(Host_Cmd_List_Vtbl, SetComputeRootUAV) == 41 * size_of(rawptr))
#assert(offset_of(Host_Cmd_List_Vtbl, SetGraphicsRootUAV) == 42 * size_of(rawptr))
#assert(offset_of(Host_Cmd_List_Vtbl, IASetIndexBuffer) == 43 * size_of(rawptr))
#assert(offset_of(Host_Cmd_List_Vtbl, IASetVertexBuffers) == 44 * size_of(rawptr))
#assert(offset_of(Host_Cmd_List_Vtbl, OMSetRenderTargets) == 46 * size_of(rawptr))
#assert(offset_of(Host_Cmd_List_Vtbl, ClearRenderTargetView) == 48 * size_of(rawptr))

@(private)
Desc_Ring_Heap :: struct {
	mu:       sync.Mutex,
	heap:     rawptr,
	base:     u64,
	inc:      u32,
	capacity: u32,
	cursor:   u32,
}

@(private)
Host_Cmd_Pair :: struct {
	list_type: u32,
	alloc:     rawptr,
	list:      rawptr,
}

@(private)
g_rtv_ring: Desc_Ring_Heap
@(private)
g_dsv_ring: Desc_Ring_Heap
@(private)
SRV_RING_CAPACITY :: u32(16384)
@(private)
g_default_srv_heap: rawptr
@(private)
g_srv_ring_cpu:     u64
@(private)
g_srv_ring_gpu:     u64
@(private)
g_srv_ring_inc:     u32
@(private)
g_srv_ring_cursor:  u32
@(private)
g_srv_ring_mu:      sync.Mutex
@(private)
g_default_smp_heap: rawptr
@(private)
g_white_tex:        rawptr

@(private)
Srv_Desc_Heap_Vtbl :: struct {
	_pad0:                              [9]rawptr,
	GetCPUDescriptorHandleForHeapStart: proc "system" (rawptr, ^u64) -> ^u64, // 9
	GetGPUDescriptorHandleForHeapStart: proc "system" (rawptr, ^u64) -> ^u64, // 10
}

@(private)
D3D12_SHADER_RESOURCE_VIEW_DESC :: struct {
	Format:                  u32,
	ViewDimension:           u32,
	Shader4ComponentMapping: u32,
	_align_pad:              u32, // union starts at offset 16 (8-byte aligned due to D3D12_BUFFER_SRV.FirstElement u64)
	MostDetailedMip:         u32,
	MipLevels:               u32,
	PlaneSlice:              u32,
	ResourceMinLODClamp:     f32,
	_pad_union:              [2]u32,
}
#assert(size_of(D3D12_SHADER_RESOURCE_VIEW_DESC) == 40)

@(private)
D3D12_UNORDERED_ACCESS_VIEW_DESC :: struct {
	Format:        u32,
	ViewDimension: u32,
	MipSlice:      u32,
	PlaneSlice:    u32,
	_pad_union:    [6]u32,
}
#assert(size_of(D3D12_UNORDERED_ACCESS_VIEW_DESC) == 40)
@(private)
g_dummy_zero_buf: rawptr
@(private)
g_dummy_zero_va: u64

UPLOAD_RING_BYTES :: u64(128 << 20) // 128 MiB persistent mapped upload ring buffer (prevents in-flight wrap corruption)
@(private)
g_upload_ring_mu: sync.Mutex
@(private)
g_upload_ring_buf: rawptr
@(private)
g_upload_ring_cpu: [^]u8
@(private)
g_upload_ring_gpu: u64
@(private)
g_upload_ring_pos: u64

@(private)
Upload_Res_Vtbl :: struct {
	_pad0:                 [8]rawptr,
	Map:                   proc "system" (rawptr, u32, rawptr, ^rawptr) -> HRESULT, // 8
	Unmap:                 proc "system" (rawptr, u32, rawptr),                      // 9
	_pad1:                 rawptr,                                                   // 10
	GetGPUVirtualAddress:  proc "system" (rawptr) -> u64,                            // 11
}

@(private)
g_host_pool_mu: sync.Mutex
@(private)
g_host_cl_pool: [dynamic]Host_Cmd_Pair

@(private)
init_desc_ring_heap :: proc(ring: ^Desc_Ring_Heap, hdev: rawptr, heap_type: u32, capacity: u32) -> bool {
	if hdev == nil || capacity == 0 {
		return false
	}
	sync.mutex_lock(&ring.mu)
	defer sync.mutex_unlock(&ring.mu)
	if ring.heap != nil {
		return true
	}
	dvt := (cast(^^Draw_Dev_Vtbl)hdev)^
	desc := D3D12_DESCRIPTOR_HEAP_DESC{
		Type           = heap_type,
		NumDescriptors = capacity,
		Flags          = 0,
		NodeMask       = 0,
	}
	dh_iid := IID_ID3D12DescriptorHeap_G
	heap: rawptr
	if dvt.CreateDescriptorHeap(hdev, &desc, &dh_iid, &heap) < 0 || heap == nil {
		return false
	}
	dhvt := (cast(^^Win_Desc_Heap_Vtbl)heap)^
	base: u64 = 0
	_ = dhvt.GetCPUDescriptorHandleForHeapStart(heap, &base)
	inc := dvt.GetDescriptorHandleIncrementSize(hdev, heap_type)
	if base == 0 || inc == 0 {
		com_release(heap)
		return false
	}
	ring.heap = heap
	ring.base = base
	ring.inc = inc
	ring.capacity = capacity
	ring.cursor = 0
	return true
}

init_host_desc_rings :: proc(hdev: rawptr) {
	if hdev == nil {
		return
	}
	_ = init_desc_ring_heap(&g_rtv_ring, hdev, D3D12_DESCRIPTOR_HEAP_TYPE_RTV, RTV_RING_CAPACITY)
	_ = init_desc_ring_heap(&g_dsv_ring, hdev, D3D12_DESCRIPTOR_HEAP_TYPE_DSV, DSV_RING_CAPACITY)
	dvt := (cast(^^Draw_Dev_Vtbl)hdev)^
	dh_iid := IID_ID3D12DescriptorHeap_G
	if g_default_srv_heap == nil {
		d := D3D12_DESCRIPTOR_HEAP_DESC{Type = 0, NumDescriptors = SRV_RING_CAPACITY, Flags = 1, NodeMask = 0}
		if dvt.CreateDescriptorHeap(hdev, &d, &dh_iid, &g_default_srv_heap) >= 0 && g_default_srv_heap != nil {
			svt := (cast(^^Srv_Desc_Heap_Vtbl)g_default_srv_heap)^
			_ = svt.GetCPUDescriptorHandleForHeapStart(g_default_srv_heap, &g_srv_ring_cpu)
			_ = svt.GetGPUDescriptorHandleForHeapStart(g_default_srv_heap, &g_srv_ring_gpu)
			g_srv_ring_inc = dvt.GetDescriptorHandleIncrementSize(hdev, 0)
			g_srv_ring_cursor = 0
		}
	}
	if g_default_smp_heap == nil {
		d := D3D12_DESCRIPTOR_HEAP_DESC{Type = 1, NumDescriptors = 64, Flags = 1, NodeMask = 0}
		_ = dvt.CreateDescriptorHeap(hdev, &d, &dh_iid, &g_default_smp_heap)
	}
	if g_dummy_zero_buf == nil {
		hp := D3D12_HEAP_PROPERTIES{Type = D3D12_HEAP_TYPE_UPLOAD}
		rd := D3D12_RESOURCE_DESC{
			Dimension        = D3D12_RESOURCE_DIMENSION_BUFFER,
			Width            = 65536,
			Height           = 1,
			DepthOrArraySize = 1,
			MipLevels        = 1,
			Format           = 0,
			SampleCount      = 1,
			Layout           = D3D12_TEXTURE_LAYOUT_ROW_MAJOR,
		}
		res_iid := IID_ID3D12Resource_G
		if dvt.CreateCommittedResource(hdev, &hp, 0, &rd, D3D12_RESOURCE_STATE_GENERIC_READ, nil, &res_iid, &g_dummy_zero_buf) >= 0 && g_dummy_zero_buf != nil {
			rvt := (cast(^^Upload_Res_Vtbl)g_dummy_zero_buf)^
			mapped: rawptr
			if rvt.Map(g_dummy_zero_buf, 0, nil, &mapped) >= 0 && mapped != nil {
				mem.zero(mapped, 65536)
				rvt.Unmap(g_dummy_zero_buf, 0, nil)
			}
			g_dummy_zero_va = rvt.GetGPUVirtualAddress(g_dummy_zero_buf)
		}
	}
}

@(private)
destroy_desc_ring_heap :: proc(ring: ^Desc_Ring_Heap) {
	sync.mutex_lock(&ring.mu)
	defer sync.mutex_unlock(&ring.mu)
	if ring.heap != nil {
		com_release(ring.heap)
	}
	ring.heap = nil
	ring.base = 0
	ring.inc = 0
	ring.capacity = 0
	ring.cursor = 0
}

fini_host_draw :: proc() {
	sync.mutex_lock(&g_host_pool_mu)
	for pair in g_host_cl_pool {
		if pair.list != nil {
			com_release(pair.list)
		}
		if pair.alloc != nil {
			com_release(pair.alloc)
		}
	}
	delete(g_host_cl_pool)
	g_host_cl_pool = nil
	sync.mutex_unlock(&g_host_pool_mu)

	destroy_desc_ring_heap(&g_rtv_ring)
	destroy_desc_ring_heap(&g_dsv_ring)
	if g_default_srv_heap != nil { com_release(g_default_srv_heap); g_default_srv_heap = nil }
	if g_white_tex != nil { com_release(g_white_tex); g_white_tex = nil }
	if g_default_smp_heap != nil { com_release(g_default_smp_heap); g_default_smp_heap = nil }
	if g_dummy_zero_buf != nil { com_release(g_dummy_zero_buf); g_dummy_zero_buf = nil; g_dummy_zero_va = 0 }
	sync.mutex_lock(&g_upload_ring_mu)
	if g_upload_ring_buf != nil {
		com_release(g_upload_ring_buf)
		g_upload_ring_buf = nil
		g_upload_ring_cpu = nil
		g_upload_ring_gpu = 0
		g_upload_ring_pos = 0
	}
	sync.mutex_unlock(&g_upload_ring_mu)
}

@(private)
alloc_ring_handle :: proc(ring: ^Desc_Ring_Heap) -> (u64, bool) {
	sync.mutex_lock(&ring.mu)
	defer sync.mutex_unlock(&ring.mu)
	if ring.heap == nil || ring.capacity == 0 || ring.inc == 0 {
		return 0, false
	}
	slot := ring.cursor
	ring.cursor = (ring.cursor + 1) % ring.capacity
	return ring.base + u64(slot) * u64(ring.inc), true
}

@(private)
materialize_rtv_or_dsv :: proc(cpu_handle: u64, is_dsv: bool) -> (^Console_Resource, u64, bool) {
	if cpu_handle < 0x10000 {
		return nil, 0, false
	}
	rec := (cast(^Rtv_Record)rawptr(uintptr(cpu_handle)))^
	expected_tag := DSV_RECORD_TAG if is_dsv else RTV_RECORD_TAG
	if rec.tag != expected_tag || uintptr(rec.resource) < 0x10000 {
		return nil, 0, false
	}
	if (rec.resource.bits & 0xFF) != u32(Object_Kind.Resource) {
		return nil, 0, false
	}
	cr := cast(^Console_Resource)rec.resource
	tex, _ := ensure_host_texture(cr)
	if tex == nil {
		return nil, 0, false
	}
	hdev := ensure_host_device()
	if hdev == nil {
		return nil, 0, false
	}

	ring := &g_dsv_ring if is_dsv else &g_rtv_ring
	host_handle, ok := alloc_ring_handle(ring)
	if !ok {
		return nil, 0, false
	}
	if cl_dbg_rtv := false; cl_dbg_rtv {}

	desc_copy := rec.desc
	desc_ptr: rawptr = nil
	if rec.described != 0 {
		if desc_copy[0] != 0 {
			desc_copy[0] = map_host_texture_format(desc_copy[0])
		}
		max_dim := u32(6) if is_dsv else u32(8)
		if desc_copy[1] <= max_dim && (desc_copy[0] != 0 || desc_copy[1] != 0) {
			desc_ptr = &desc_copy[0]
		}
	}

	dvt := (cast(^^Draw_Dev_Vtbl)hdev)^
	if is_dsv {
		dvt.CreateDepthStencilView(hdev, tex, desc_ptr, host_handle)
	} else {
		dvt.CreateRenderTargetView(hdev, tex, desc_ptr, host_handle)
	}
	return cr, host_handle, true
}

@(private)
host_transition_resource :: proc(host_list: rawptr, r: ^Console_Resource, target_state: u32) {
	if host_list == nil || r == nil || r.host_tex == nil {
		return
	}
	if r.host_state == target_state {
		return
	}
	b := transition_barrier(r.host_tex, r.host_state, target_state)
	lvt := (cast(^^Host_Cmd_List_Vtbl)host_list)^
	lvt.ResourceBarrier(host_list, 1, &b)
	r.host_state = target_state
}

// Lazily acquires or creates a host (ID3D12CommandAllocator, ID3D12GraphicsCommandList)
// for `cl` ONLY when a real GPU draw/clear/copy command is recorded.
ensure_cl_host_list :: proc(cl: ^Console_Cmd_List) -> rawptr {
	if cl == nil || cl.is_closed {
		return nil
	}
	if cl.host_list != nil {
		return cl.host_list
	}

	list_type := cl.kind if (cl.kind == 0 || cl.kind == 2 || cl.kind == 3) else u32(0)

	// Try recycling a previously executed host allocator + list from the pool.
	popped: Host_Cmd_Pair
	has_popped := false
	sync.mutex_lock(&g_host_pool_mu)
	for i := len(g_host_cl_pool) - 1; i >= 0; i -= 1 {
		if g_host_cl_pool[i].list_type == list_type {
			popped = g_host_cl_pool[i]
			unordered_remove(&g_host_cl_pool, i)
			has_popped = true
			break
		}
	}
	sync.mutex_unlock(&g_host_pool_mu)

	if has_popped {
		avt := (cast(^^Exec_Alloc_Vtbl)popped.alloc)^
		lvt := (cast(^^Host_Cmd_List_Vtbl)popped.list)^
		if avt.Reset(popped.alloc) >= 0 && lvt.Reset(popped.list, popped.alloc, nil) >= 0 {
			cl.host_alloc = popped.alloc
			cl.host_list = popped.list
			cl.host_list_type = list_type
			cl.bound_host_root = nil
			cl.bound_host_cs_root = nil
			cl.bound_host_pso = nil
			cl.vp_dirty = cl.num_viewports > 0
			cl.scissor_dirty = cl.num_scissors > 0
			cl.blend_factor_dirty = cl.has_blend_factor
			cl.stencil_ref_dirty = cl.has_stencil_ref
			cl.topo_dirty = true
			return cl.host_list
		}
		com_release(popped.list)
		com_release(popped.alloc)
	}

	hdev := ensure_host_device()
	if hdev == nil {
		return nil
	}
	dvt := (cast(^^Draw_Dev_Vtbl)hdev)^

	alloc_iid := IID_ID3D12CommandAllocator_G
	alloc: rawptr
	if dvt.CreateCommandAllocator(hdev, list_type, &alloc_iid, &alloc) < 0 || alloc == nil {
		return nil
	}

	list_iid := IID_ID3D12GraphicsCommandList_G
	list: rawptr
	if dvt.CreateCommandList(hdev, 0, list_type, alloc, nil, &list_iid, &list) < 0 || list == nil {
		com_release(alloc)
		return nil
	}

	cl.host_alloc = alloc
	cl.host_list = list
	cl.host_list_type = list_type
	cl.bound_host_root = nil
	cl.bound_host_cs_root = nil
	cl.bound_host_pso = nil
	cl.vp_dirty = cl.num_viewports > 0
	cl.scissor_dirty = cl.num_scissors > 0
	cl.blend_factor_dirty = cl.has_blend_factor
	cl.stencil_ref_dirty = cl.has_stencil_ref
	cl.topo_dirty = true
	return cl.host_list
}

@(private)
recycle_cl_host_list :: proc(cl: ^Console_Cmd_List) {
	if cl == nil {
		return
	}
	for t in cl.host_temps {
		if t != nil {
			com_release(t)
		}
	}
	clear(&cl.host_temps)

	if cl.host_list == nil {
		return
	}
	if cl.host_alloc == nil {
		com_release(cl.host_list)
		cl.host_list = nil
		return
	}

	if !cl.is_closed {
		lvt := (cast(^^Host_Cmd_List_Vtbl)cl.host_list)^
		_ = lvt.Close(cl.host_list)
		cl.is_closed = true
	}

	avt := (cast(^^Exec_Alloc_Vtbl)cl.host_alloc)^
	if avt.Reset(cl.host_alloc) < 0 {
		com_release(cl.host_list)
		com_release(cl.host_alloc)
	} else {
		sync.mutex_lock(&g_host_pool_mu)
		append(&g_host_cl_pool, Host_Cmd_Pair{
			list_type = cl.host_list_type,
			alloc     = cl.host_alloc,
			list      = cl.host_list,
		})
		sync.mutex_unlock(&g_host_pool_mu)
	}

	cl.host_alloc = nil
	cl.host_list = nil
	cl.bound_host_root = nil
	cl.bound_host_cs_root = nil
	cl.bound_host_pso = nil
	cl.vp_dirty = false
	cl.scissor_dirty = false
	cl.topo_dirty = false
}

@(private)
map_host_topology :: proc "contextless" (t: u32) -> u32 {
	switch t {
	case 1, 2, 3, 4, 5, 10, 11, 12, 13:
		return t
	case 6, 17, 18, 19, 20:
		return 4 // D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST
	case 33 ..= 64:
		return t
	}
	return 4
}

@(private)
g_up_err_logs: u64

@(private)
ensure_upload_ring_locked :: proc(hdev: rawptr) -> bool {
	if g_upload_ring_buf != nil && g_upload_ring_cpu != nil && g_upload_ring_gpu != 0 {
		return true
	}
	hp := D3D12_HEAP_PROPERTIES{Type = D3D12_HEAP_TYPE_UPLOAD}
	rd := D3D12_RESOURCE_DESC{
		Dimension        = D3D12_RESOURCE_DIMENSION_BUFFER,
		Width            = UPLOAD_RING_BYTES,
		Height           = 1,
		DepthOrArraySize = 1,
		MipLevels        = 1,
		Format           = 0,
		SampleCount      = 1,
		Layout           = D3D12_TEXTURE_LAYOUT_ROW_MAJOR,
	}
	dvt := (cast(^^Draw_Dev_Vtbl)hdev)^
	res_iid := IID_ID3D12Resource_G
	buf: rawptr
	if dvt.CreateCommittedResource(hdev, &hp, 0, &rd, D3D12_RESOURCE_STATE_GENERIC_READ, nil, &res_iid, &buf) < 0 || buf == nil {
		return false
	}
	rvt := (cast(^^Upload_Res_Vtbl)buf)^
	mapped: rawptr
	if rvt.Map(buf, 0, nil, &mapped) < 0 || mapped == nil {
		com_release(buf)
		return false
	}
	g_upload_ring_buf = buf
	g_upload_ring_cpu = cast([^]u8)mapped
	g_upload_ring_gpu = rvt.GetGPUVirtualAddress(buf)
	g_upload_ring_pos = 0
	return true
}

@(private)
upload_cpu_to_host_buf :: proc(cl: ^Console_Cmd_List, cpu_va: u64, size: u32) -> u64 {
	if cl == nil || cpu_va < 0x10000 || size == 0 || size > (64 << 20) {
		return 0
	}
	hdev := ensure_host_device()
	if hdev == nil { return 0 }
	aligned_sz := (u64(size) + 255) & ~u64(255)

	// Fast path: sub-allocate from persistent 16 MiB mapped upload ring (zero D3D12 allocations per draw!).
	if aligned_sz <= (4 << 20) {
		sync.mutex_lock(&g_upload_ring_mu)
		if ensure_upload_ring_locked(hdev) {
			if g_upload_ring_pos + aligned_sz > UPLOAD_RING_BYTES {
				g_upload_ring_pos = 0
			}
			off := g_upload_ring_pos
			g_upload_ring_pos += aligned_sz
			dst := rawptr(&g_upload_ring_cpu[off])
			gpu_va := g_upload_ring_gpu + off
			sync.mutex_unlock(&g_upload_ring_mu)
			mem.copy(dst, rawptr(uintptr(cpu_va)), int(size))
			return gpu_va
		}
		sync.mutex_unlock(&g_upload_ring_mu)
	}

	hp := D3D12_HEAP_PROPERTIES{Type = D3D12_HEAP_TYPE_UPLOAD}
	rd := D3D12_RESOURCE_DESC{
		Dimension        = D3D12_RESOURCE_DIMENSION_BUFFER,
		Width            = aligned_sz,
		Height           = 1,
		DepthOrArraySize = 1,
		MipLevels        = 1,
		Format           = 0,
		SampleCount      = 1,
		Layout           = D3D12_TEXTURE_LAYOUT_ROW_MAJOR,
	}
	dvt := (cast(^^Draw_Dev_Vtbl)hdev)^
	res_iid := IID_ID3D12Resource_G
	buf: rawptr
	hr := dvt.CreateCommittedResource(hdev, &hp, 0, &rd, D3D12_RESOURCE_STATE_GENERIC_READ, nil, &res_iid, &buf)
	if hr < 0 || buf == nil {
		return 0
	}
	rvt := (cast(^^Upload_Res_Vtbl)buf)^
	mapped: rawptr
	if rvt.Map(buf, 0, nil, &mapped) < 0 || mapped == nil {
		com_release(buf)
		return 0
	}
	mem.copy(mapped, rawptr(uintptr(cpu_va)), int(size))
	rvt.Unmap(buf, 0, nil)
	gpu_va := rvt.GetGPUVirtualAddress(buf)
	append(&cl.host_temps, buf)
	return gpu_va
}

@(private)
safe_readable_bytes :: proc(cpu_va: u64, max_bytes: u32) -> u32 {
	if cpu_va < 0x10000 || max_bytes == 0 {
		return 0
	}
	mbi: win32.MEMORY_BASIC_INFORMATION
	if win32.VirtualQuery(rawptr(uintptr(cpu_va)), &mbi, size_of(mbi)) == 0 {
		return 0
	}
	if mbi.State != win32.MEM_COMMIT {
		return 0
	}
	region_end := uintptr(mbi.BaseAddress) + uintptr(mbi.RegionSize)
	if region_end <= uintptr(cpu_va) {
		return 0
	}
	avail := u64(region_end - uintptr(cpu_va))
	return u32(min(avail, u64(max_bytes)))
}

@(private)
bind_stage_user_data :: proc(cl: ^Console_Cmd_List, hl: rawptr, lvt: ^Host_Cmd_List_Vtbl, param_idx: i32, dwords: u32, ud: []vasperty_shader.User_Data) {
	if param_idx < 0 || dwords == 0 {
		return
	}
	vals: [64]u32
	for u in ud {
		if u.index >= 64 || u.slot >= 32 {
			continue
		}
		r := cl.gfx_roots[u.slot]
		if r.kind == 2 && u.dword < 32 {
			vals[u.index] = r.consts[u.dword]
		} else if r.kind == 1 || r.kind == 3 {
			if u.dword == 0 {
				vals[u.index] = u32(r.va)
			} else if u.dword == 1 {
				vals[u.index] = u32(r.va >> 32)
			}
		}
	}
	lvt.SetGraphicsRoot32BitConsts(hl, u32(param_idx), min(dwords, u32(64)), &vals[0], 0)
}

@(private)
ensure_white_tex :: proc(hdev: rawptr) -> rawptr {
	if g_white_tex != nil {
		return g_white_tex
	}
	hp := D3D12_HEAP_PROPERTIES{Type = 1} // DEFAULT
	rd := D3D12_RESOURCE_DESC{
		Dimension        = 3, // TEXTURE2D
		Width            = 1,
		Height           = 1,
		DepthOrArraySize = 1,
		MipLevels        = 1,
		Format           = DXGI_FORMAT_R8G8B8A8_UNORM,
		SampleCount      = 1,
		Layout           = 0,
	}
	dvt := (cast(^^Draw_Dev_Vtbl)hdev)^
	res_iid := IID_ID3D12Resource_G
	tex: rawptr
	if dvt.CreateCommittedResource(hdev, &hp, 0, &rd, 0x80, nil, &res_iid, &tex) >= 0 && tex != nil {
		g_white_tex = tex
	}
	return g_white_tex
}

@(private)
find_srv_resource_at :: proc(va: u64) -> (^Console_Resource, u32, u32) {
	if va < 0x10000 || safe_readable_bytes(va, size_of(Srv_Record)) < size_of(Srv_Record) {
		return nil, 0, 5768
	}
	rec := (cast(^Srv_Record)rawptr(uintptr(va)))^
	if rec.tag != SRV_RECORD_TAG || uintptr(rec.resource) < 0x10000 {
		return nil, 0, 5768
	}
	cr := cast(^Console_Resource)rec.resource
	if (cr.object.bits & 0xFF) != u32(Object_Kind.Resource) || cr.desc.Dimension != 3 {
		return nil, 0, 5768
	}
	cmap := rec.comp_map if rec.comp_map != 0 else u32(5768)
	return cr, rec.format, cmap
}

@(private)
is_bound_as_rt :: proc(cl: ^Console_Cmd_List, cr: ^Console_Resource) -> bool {
	for i in u32(0) ..< cl.num_cur_rts {
		if cl.cur_rts[i] == cr { return true }
	}
	return false
}

@(private)
srv_safe_format :: proc "contextless" (f: u32) -> u32 {
	hf := map_host_texture_format(f)
	switch hf {
	case 40: return 41 // D32_FLOAT -> R32_FLOAT
	case 45: return 46 // D24_UNORM_S8_UINT -> R24_UNORM_X8_TYPELESS
	case 55: return 56 // D16_UNORM -> R16_UNORM
	case 0:  return DXGI_FORMAT_R8G8B8A8_UNORM
	}
	return hf
}

@(private)
sample_uma_sig :: proc(addr: u64, nbytes: u64) -> u64 {
	if addr < 0x10000 || nbytes < 8 { return 0 }
	p := cast([^]u64)rawptr(uintptr(addr))
	nwords := nbytes / 8
	// Scan every 64-byte cache line (8 qwords) for textures <= 4 MiB so incremental glyph atlas writes are never missed.
	stride := u64(8) if nbytes <= (4 << 20) else max(u64(8), nwords / 65536)
	h := u64(0xCBF29CE484222325)
	for i := u64(0); i < nwords; i += stride {
		v := p[i]
		if v != 0 {
			h = (h ~ v) * 0x100000001B3
		}
	}
	return h
}

@(private)
upload_uma_texture_if_needed :: proc(cl: ^Console_Cmd_List, hl: rawptr, lvt: ^Host_Cmd_List_Vtbl, cr: ^Console_Resource, htex: rawptr) {
	if cr == nil || htex == nil || cr.was_drawn || cr.gpu_written || cr.address < 0x10000 || cr.desc.Dimension != 3 {
		return
	}
	w := u32(cr.desc.Width)
	h := cr.desc.Height
	if w == 0 || h == 0 || w > 4096 || h > 4096 {
		return
	}
	hf := srv_safe_format(cr.desc.Format)
	info := vasperty_formats.dxgi_format_info(hf)
	if !info.valid || info.bytes == 0 || info.block == 0 {
		return
	}
	bx := max(u32(1), (w + info.block - 1) / info.block)
	by := max(u32(1), (h + info.block - 1) / info.block)
	row_bytes := bx * info.bytes
	row_pitch := (row_bytes + 255) & ~u32(255)
	total_bytes := u64(row_pitch) * u64(by)
	if total_bytes == 0 || total_bytes > (16 << 20) {
		return
	}

	raw_linear_bytes := u64(row_bytes) * u64(by)
	avail := u64(safe_readable_bytes(cr.address, u32(min(max(total_bytes, u64(65536)), u64(16 << 20)))))
	if avail < raw_linear_bytes {
		return
	}
	sig := sample_uma_sig(cr.address, min(avail, total_bytes))
	if cr.cpu_uploaded && sig == cr.cpu_upload_sig {
		return
	}

	hdev := ensure_host_device()
	if hdev == nil { return }

	upload_buf: rawptr
	upload_off: u64
	dst_cpu: [^]u8
	aligned_sz := (total_bytes + 511) & ~u64(511)
	if aligned_sz <= (4 << 20) {
		sync.mutex_lock(&g_upload_ring_mu)
		if ensure_upload_ring_locked(hdev) {
			pos := (g_upload_ring_pos + 511) & ~u64(511)
			if pos + aligned_sz > UPLOAD_RING_BYTES {
				pos = 0
			}
			g_upload_ring_pos = pos + aligned_sz
			upload_buf = g_upload_ring_buf
			upload_off = pos
			dst_cpu = cast([^]u8)&g_upload_ring_cpu[pos]
		}
		sync.mutex_unlock(&g_upload_ring_mu)
	}
	temp_buf: rawptr
	if upload_buf == nil {
		hp := D3D12_HEAP_PROPERTIES{Type = D3D12_HEAP_TYPE_UPLOAD}
		rd := D3D12_RESOURCE_DESC{
			Dimension        = D3D12_RESOURCE_DIMENSION_BUFFER,
			Width            = aligned_sz,
			Height           = 1,
			DepthOrArraySize = 1,
			MipLevels        = 1,
			Format           = 0,
			SampleCount      = 1,
			Layout           = D3D12_TEXTURE_LAYOUT_ROW_MAJOR,
		}
		dvt := (cast(^^Draw_Dev_Vtbl)hdev)^
		res_iid := IID_ID3D12Resource_G
		if dvt.CreateCommittedResource(hdev, &hp, 0, &rd, D3D12_RESOURCE_STATE_GENERIC_READ, nil, &res_iid, &temp_buf) < 0 || temp_buf == nil {
			return
		}
		rvt := (cast(^^Upload_Res_Vtbl)temp_buf)^
		mapped: rawptr
		if rvt.Map(temp_buf, 0, nil, &mapped) < 0 || mapped == nil {
			com_release(temp_buf)
			return
		}
		upload_buf = temp_buf
		upload_off = 0
		dst_cpu = cast([^]u8)mapped
	}

	detiled := false
	if cr.desc.Layout != 1 { // Not ROW_MAJOR -> attempt RDNA2 detile
		sw := vasperty_formats.SWIZZLE_64KB_S_X
		if cr.desc.Layout >= 0x100 && cr.desc.Layout <= 0x11F {
			sw = cr.desc.Layout & 0x1F
		}
		fdesc := vasperty_formats.Desc{
			dimension     = .Tex2d,
			width         = w,
			height        = h,
			depth         = 1,
			mips          = 1,
			element_bytes = info.bytes,
			block         = info.block,
			samples       = 1,
			swizzle       = sw,
		}
		if lay, lerr := vasperty_formats.new_layout(fdesc, context.temp_allocator); lerr == .None {
			defer vasperty_formats.destroy_layout(&lay, context.temp_allocator)
			avail_tiled := u64(safe_readable_bytes(cr.address, u32(min(lay.size, u64(16 << 20)))))
			if avail_tiled >= lay.size {
				src_slice := (cast([^]u8)rawptr(uintptr(cr.address)))[:lay.size]
				dst_slice := dst_cpu[:total_bytes]
				if vasperty_formats.layout_detile(&lay, src_slice, 0, 0, dst_slice, int(row_pitch), int(total_bytes), context.temp_allocator) == .None {
					detiled = true
				}
			}
		}
	}
	if !detiled {
		src_p := cast([^]u8)rawptr(uintptr(cr.address))
		for y in u32(0) ..< by {
			mem.copy(&dst_cpu[u64(y) * u64(row_pitch)], &src_p[u64(y) * u64(row_bytes)], int(row_bytes))
		}
	}
	if temp_buf != nil {
		rvt := (cast(^^Upload_Res_Vtbl)temp_buf)^
		rvt.Unmap(temp_buf, 0, nil)
		append(&cl.host_temps, temp_buf)
	}

	host_transition_resource(hl, cr, D3D12_RESOURCE_STATE_COPY_DEST)
	dst_loc := D3D12_TEXTURE_COPY_LOCATION{
		pResource        = htex,
		Type             = 0, // SUBRESOURCE_INDEX
		SubresourceIndex = 0,
	}
	src_loc := D3D12_TEXTURE_COPY_LOCATION{
		pResource = upload_buf,
		Type      = 1, // PLACED_FOOTPRINT
		PlacedFootprint = D3D12_PLACED_SUBRESOURCE_FOOTPRINT{
			Offset = upload_off,
			Footprint = D3D12_SUBRESOURCE_FOOTPRINT{
				Format   = hf,
				Width    = w,
				Height   = h,
				Depth    = 1,
				RowPitch = row_pitch,
			},
		},
	}
	lvt.CopyTextureRegion(hl, &dst_loc, 0, 0, 0, &src_loc, nil)
	cr.cpu_uploaded = true
	cr.cpu_upload_sig = sig
}

@(private)
find_uav_resource_at :: proc(va: u64) -> (^Console_Resource, u32, u32) {
	if va < 0x10000 || safe_readable_bytes(va, size_of(Uav_Record)) < size_of(Uav_Record) {
		return nil, 0, 0
	}
	rec := (cast(^Uav_Record)rawptr(uintptr(va)))^
	if rec.tag != UAV_RECORD_TAG || uintptr(rec.resource) < 0x10000 {
		return nil, 0, 0
	}
	cr := cast(^Console_Resource)rec.resource
	if (cr.object.bits & 0xFF) != u32(Object_Kind.Resource) || cr.desc.Dimension != 3 {
		return nil, 0, 0
	}
	return cr, rec.format, rec.mip_slice
}

@(private)
emit_uav_barrier :: proc(hl: rawptr, lvt: ^Host_Cmd_List_Vtbl) {
	if hl == nil || lvt == nil { return }
	b := D3D12_RESOURCE_BARRIER{
		Type = 2, // D3D12_RESOURCE_BARRIER_TYPE_UAV
	}
	lvt.ResourceBarrier(hl, 1, &b)
}

@(private)
bind_cs_user_data :: proc(cl: ^Console_Cmd_List, hl: rawptr, lvt: ^Host_Cmd_List_Vtbl, param_idx: i32, dwords: u32, ud: []vasperty_shader.User_Data) {
	if param_idx < 0 || dwords == 0 {
		return
	}
	vals: [64]u32
	for u in ud {
		if u.index >= 64 || u.slot >= 32 {
			continue
		}
		r := cl.cs_roots[u.slot]
		if r.kind == 2 && u.dword < 32 {
			vals[u.index] = r.consts[u.dword]
		} else if r.kind == 1 || r.kind == 3 {
			if u.dword == 0 {
				vals[u.index] = u32(r.va)
			} else if u.dword == 1 {
				vals[u.index] = u32(r.va >> 32)
			}
		}
	}
	lvt.SetComputeRoot32BitConsts(hl, u32(param_idx), min(dwords, u32(64)), &vals[0], 0)
}

@(private)
bind_host_cs_textures_and_uavs :: proc(cl: ^Console_Cmd_List, hl: rawptr, lvt: ^Host_Cmd_List_Vtbl, p: ^Console_Pipeline) {
	if g_default_srv_heap == nil || g_srv_ring_cpu == 0 || g_srv_ring_gpu == 0 || g_srv_ring_inc == 0 {
		return
	}
	hdev := ensure_host_device()
	if hdev == nil { return }
	dvt := (cast(^^Draw_Dev_Vtbl)hdev)^

	if p.cs_tex_table_param >= 0 {
		sync.mutex_lock(&g_srv_ring_mu)
		if g_srv_ring_cursor + 16 > SRV_RING_CAPACITY {
			g_srv_ring_cursor = 0
		}
		base_idx := g_srv_ring_cursor
		g_srv_ring_cursor += 16
		sync.mutex_unlock(&g_srv_ring_mu)

		cpu_start := g_srv_ring_cpu + u64(base_idx) * u64(g_srv_ring_inc)
		gpu_start := g_srv_ring_gpu + u64(base_idx) * u64(g_srv_ring_inc)
		fallback := ensure_white_tex(hdev)
		for i in u32(0) ..< 16 {
			if fallback != nil {
				dvt.CreateShaderResourceView(hdev, fallback, nil, cpu_start + u64(i) * u64(g_srv_ring_inc))
			}
		}

		for ts, idx in p.cs_shader.tex_srvs {
			if idx >= 16 { break }
			cr: ^Console_Resource
			rec_fmt: u32
			rec_cmap: u32 = 5768
			rs := cl.cs_roots[ts.slot] if ts.slot < 32 else Console_Root_Slot{}
			if ts.slot < 32 && rs.kind == 1 {
				cr, rec_fmt, rec_cmap = find_srv_resource_at(rs.va + u64(ts.byte_offset))
				if cr == nil && ts.byte_offset == 0 {
					cr, rec_fmt, rec_cmap = find_srv_resource_at(rs.va + 0x20)
				}
			}
			if cr == nil { continue }
			htex, _ := ensure_host_texture(cr)
			if htex == nil { continue }
			if !cr.was_drawn {
				upload_uma_texture_if_needed(cl, hl, lvt, cr, htex)
			}
			host_transition_resource(hl, cr, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE)
			sdesc := D3D12_SHADER_RESOURCE_VIEW_DESC{
				Format                  = srv_safe_format(rec_fmt if rec_fmt != 0 else cr.desc.Format),
				ViewDimension           = 4,
				Shader4ComponentMapping = rec_cmap,
				MipLevels               = 1,
			}
			dvt.CreateShaderResourceView(hdev, htex, &sdesc, cpu_start + u64(idx) * u64(g_srv_ring_inc))
		}
		lvt.SetComputeRootDescriptorTable(hl, u32(p.cs_tex_table_param), gpu_start)
	}

	if p.cs_uav_table_param >= 0 {
		sync.mutex_lock(&g_srv_ring_mu)
		if g_srv_ring_cursor + 16 > SRV_RING_CAPACITY {
			g_srv_ring_cursor = 0
		}
		base_idx := g_srv_ring_cursor
		g_srv_ring_cursor += 16
		sync.mutex_unlock(&g_srv_ring_mu)

		cpu_start := g_srv_ring_cpu + u64(base_idx) * u64(g_srv_ring_inc)
		gpu_start := g_srv_ring_gpu + u64(base_idx) * u64(g_srv_ring_inc)
		null_uav := D3D12_UNORDERED_ACCESS_VIEW_DESC{
			Format        = DXGI_FORMAT_R8G8B8A8_UNORM,
			ViewDimension = 4, // TEXTURE2D
		}
		for i in u32(0) ..< 16 {
			dvt.CreateUnorderedAccessView(hdev, nil, nil, &null_uav, cpu_start + u64(i) * u64(g_srv_ring_inc))
		}

		for tu, idx in p.cs_shader.tex_uavs {
			if idx >= 16 { break }
			cr: ^Console_Resource
			rec_fmt: u32
			rec_mip: u32
			rs := cl.cs_roots[tu.slot] if tu.slot < 32 else Console_Root_Slot{}
			if tu.slot < 32 && rs.kind == 1 {
				cr, rec_fmt, rec_mip = find_uav_resource_at(rs.va + u64(tu.byte_offset))
				if cr == nil && tu.byte_offset == 0 {
					cr, rec_fmt, rec_mip = find_uav_resource_at(rs.va + 0x20)
				}
			}
			if cr == nil {
				continue
			}
			htex, _ := ensure_host_texture(cr)
			if htex == nil { continue }
			uav_fmt := srv_safe_format(rec_fmt if rec_fmt != 0 else cr.desc.Format)
			if !format_supports_typed_uav_store(uav_fmt, true) { continue }
			host_transition_resource(hl, cr, D3D12_RESOURCE_STATE_UNORDERED_ACCESS)
			cr.gpu_written = true
			cr.was_drawn = true
			udesc := D3D12_UNORDERED_ACCESS_VIEW_DESC{
				Format        = uav_fmt,
				ViewDimension = 4, // TEXTURE2D
				MipSlice      = rec_mip,
			}
			dvt.CreateUnorderedAccessView(hdev, htex, nil, &udesc, cpu_start + u64(idx) * u64(g_srv_ring_inc))
		}
		lvt.SetComputeRootDescriptorTable(hl, u32(p.cs_uav_table_param), gpu_start)
	}
}

@(private)
prepare_host_dispatch :: proc(cl: ^Console_Cmd_List) -> rawptr {
	if cl == nil || cl.is_closed || uintptr(cl.cur_pso) < 0x10000 {
		return nil
	}
	p := cast(^Console_Pipeline)cl.cur_pso
	if (p.object.bits & 0xFF) != u32(Object_Kind.Pipeline) || !p.is_compute {
		return nil
	}
	root, hpso, ok := ensure_host_pipeline(p)
	if !ok || root == nil || hpso == nil {
		return nil
	}
	hl := ensure_cl_host_list(cl)
	if hl == nil {
		return nil
	}
	lvt := (cast(^^Host_Cmd_List_Vtbl)hl)^
	if g_default_srv_heap != nil && g_default_smp_heap != nil {
		heaps := [2]rawptr{g_default_srv_heap, g_default_smp_heap}
		lvt.SetDescriptorHeaps(hl, 2, &heaps[0])
	}
	if cl.bound_host_cs_root != root {
		lvt.SetComputeRootSignature(hl, root)
		cl.bound_host_cs_root = root
	}
	if cl.bound_host_pso != hpso {
		lvt.SetPipelineState(hl, hpso)
		cl.bound_host_pso = hpso
	}
	bind_cs_user_data(cl, hl, lvt, p.vs_ud_param, p.vs_ud_dwords, p.cs_shader.user_data[:])
	for b in p.root_bindings {
		gpu_va := g_dummy_zero_va
		if b.slot < 32 {
			rs := cl.cs_roots[b.slot]
			va := rs.va
			if va >= 0x10000 {
				max_sz := u32(4096) if b.kind == 0 else u32(65536)
				if (b.kind == 0 || b.kind == 1) && rs.kind == 1 {
					if safe_readable_bytes(va, 16) >= 16 {
						desc_va := (cast(^u64)rawptr(uintptr(va)))^
						desc_sz := (cast(^u32)rawptr(uintptr(va + 8)))^
						if desc_va >= 0x10000 {
							va = desc_va
							if desc_sz > 0 && desc_sz <= 65536 {
								max_sz = (desc_sz + 255) & ~u32(255)
							}
						}
					}
				}
				if sz := safe_readable_bytes(va, max_sz); sz > 0 {
					if up_va := upload_cpu_to_host_buf(cl, va, sz); up_va != 0 {
						gpu_va = up_va
					}
				}
			}
		}
		if gpu_va == 0 { continue }
		switch b.kind {
		case 0:
			lvt.SetComputeRootCBV(hl, b.param_idx, gpu_va)
		case 1:
			lvt.SetComputeRootSRV(hl, b.param_idx, gpu_va)
		case 2:
			lvt.SetComputeRootUAV(hl, b.param_idx, gpu_va)
		}
	}
	if p.cs_tex_table_param >= 0 || p.cs_uav_table_param >= 0 {
		bind_host_cs_textures_and_uavs(cl, hl, lvt, p)
	}
	return hl
}

@(private)
bind_host_ps_textures :: proc(cl: ^Console_Cmd_List, hl: rawptr, lvt: ^Host_Cmd_List_Vtbl, p: ^Console_Pipeline) {
	hdev := ensure_host_device()
	if hdev == nil { return }
	dvt := (cast(^^Draw_Dev_Vtbl)hdev)^

	sync.mutex_lock(&g_srv_ring_mu)
	if g_srv_ring_cursor + 16 > SRV_RING_CAPACITY {
		g_srv_ring_cursor = 0
	}
	base_idx := g_srv_ring_cursor
	g_srv_ring_cursor += 16
	sync.mutex_unlock(&g_srv_ring_mu)

	cpu_start := g_srv_ring_cpu + u64(base_idx) * u64(g_srv_ring_inc)
	gpu_start := g_srv_ring_gpu + u64(base_idx) * u64(g_srv_ring_inc)
	fallback := ensure_white_tex(hdev)
	for i in u32(0) ..< 16 {
		if fallback != nil {
			dvt.CreateShaderResourceView(hdev, fallback, nil, cpu_start + u64(i) * u64(g_srv_ring_inc))
		}
	}

	for ts, idx in p.ps_shader.tex_srvs {
		if idx >= 16 { break }
		cr: ^Console_Resource
		rec_fmt: u32
		rec_cmap: u32 = 5768
		rs := cl.gfx_roots[ts.slot] if ts.slot < 32 else Console_Root_Slot{}
		if ts.slot < 32 && rs.kind == 1 {
			cr, rec_fmt, rec_cmap = find_srv_resource_at(rs.va + u64(ts.byte_offset))
			if cr == nil && ts.byte_offset == 0 {
				cr, rec_fmt, rec_cmap = find_srv_resource_at(rs.va + 0x20)
			}
		}
		if cr == nil || is_bound_as_rt(cl, cr) { continue }
		htex, _ := ensure_host_texture(cr)
		if htex == nil { continue }
		if !cr.was_drawn {
			upload_uma_texture_if_needed(cl, hl, lvt, cr, htex)
		}
		host_transition_resource(hl, cr, 0x80)
		sdesc := D3D12_SHADER_RESOURCE_VIEW_DESC{
			Format                  = srv_safe_format(rec_fmt if rec_fmt != 0 else cr.desc.Format),
			ViewDimension           = 4,
			Shader4ComponentMapping = rec_cmap,
			MipLevels               = 1,
		}
		dvt.CreateShaderResourceView(hdev, htex, &sdesc, cpu_start + u64(idx) * u64(g_srv_ring_inc))
	}

	lvt.SetGraphicsRootDescriptorTable(hl, u32(p.ps_tex_table_param), gpu_start)
}

@(private)
prepare_host_draw :: proc(cl: ^Console_Cmd_List) -> rawptr {
	if cl == nil || cl.is_closed || uintptr(cl.cur_pso) < 0x10000 {
		return nil
	}
	p := cast(^Console_Pipeline)cl.cur_pso
	if (p.object.bits & 0xFF) != u32(Object_Kind.Pipeline) || p.is_compute {
		return nil
	}
	root, hpso, ok := ensure_host_pipeline(p)
	if !ok || root == nil || hpso == nil {
		return nil
	}
	hl := ensure_cl_host_list(cl)
	if hl == nil {
		return nil
	}
	lvt := (cast(^^Host_Cmd_List_Vtbl)hl)^
	if g_default_srv_heap != nil && g_default_smp_heap != nil {
		heaps := [2]rawptr{g_default_srv_heap, g_default_smp_heap}
		lvt.SetDescriptorHeaps(hl, 2, &heaps[0])
	}
	if cl.bound_host_root != root {
		lvt.SetGraphicsRootSignature(hl, root)
		cl.bound_host_root = root
	}
	if cl.bound_host_pso != hpso {
		lvt.SetPipelineState(hl, hpso)
		cl.bound_host_pso = hpso
	}
	// Bind user_data root constants & root CBV/SRV/UAV descriptors
	bind_stage_user_data(cl, hl, lvt, p.vs_ud_param, p.vs_ud_dwords, p.vs_shader.user_data[:])
	bind_stage_user_data(cl, hl, lvt, p.ps_ud_param, p.ps_ud_dwords, p.ps_shader.user_data[:])
	for b in p.root_bindings {
		gpu_va := g_dummy_zero_va
		if b.slot < 32 {
			rs := cl.gfx_roots[b.slot]
			va := rs.va
			if va >= 0x10000 {
				max_sz := u32(4096) if b.kind == 0 else u32(65536)
				// If the title bound a Descriptor Table (kind==1) for a CBV/SRV, dereference the stored desc {BufferLocation, SizeInBytes}
				if (b.kind == 0 || b.kind == 1) && rs.kind == 1 {
					if safe_readable_bytes(va, 16) >= 16 {
						desc_va := (cast(^u64)rawptr(uintptr(va)))^
						desc_sz := (cast(^u32)rawptr(uintptr(va + 8)))^
						if desc_va >= 0x10000 {
							va = desc_va
							if desc_sz > 0 && desc_sz <= 65536 {
								max_sz = (desc_sz + 255) & ~u32(255)
							}
						}
					}
				}
				if sz := safe_readable_bytes(va, max_sz); sz > 0 {
					if up_va := upload_cpu_to_host_buf(cl, va, sz); up_va != 0 {
						gpu_va = up_va
					}
				}
			}
		}
		if gpu_va == 0 { continue }
		switch b.kind {
		case 0:
			lvt.SetGraphicsRootCBV(hl, b.param_idx, gpu_va)
		case 1:
			lvt.SetGraphicsRootSRV(hl, b.param_idx, gpu_va)
		case 2:
			lvt.SetGraphicsRootUAV(hl, b.param_idx, gpu_va)
		}
	}
	if p.ps_tex_table_param >= 0 && g_default_srv_heap != nil && g_srv_ring_cpu != 0 && g_srv_ring_gpu != 0 && g_srv_ring_inc != 0 {
		bind_host_ps_textures(cl, hl, lvt, p)
	}
	if cl.vp_dirty && cl.num_viewports > 0 {
		lvt.RSSetViewports(hl, cl.num_viewports, &cl.viewports[0])
		cl.vp_dirty = false
	}
	if cl.scissor_dirty && cl.num_scissors > 0 {
		lvt.RSSetScissorRects(hl, cl.num_scissors, &cl.scissors[0])
		cl.scissor_dirty = false
	}
	if cl.blend_factor_dirty {
		lvt.OMSetBlendFactor(hl, &cl.blend_factor)
		cl.blend_factor_dirty = false
	}
	if cl.stencil_ref_dirty {
		lvt.OMSetStencilRef(hl, cl.stencil_ref)
		cl.stencil_ref_dirty = false
	}
	if cl.topo_dirty {
		topo := cl.topology if cl.has_topology else u32(4)
		lvt.IASetPrimitiveTopology(hl, topo)
		cl.topo_dirty = false
	}
	// Upload and bind Vertex Buffers & Index Buffer from title UMA memory
	if cl.vb_mask != 0 {
		for slot in u32(0) ..< 8 {
			if (cl.vb_mask & (u8(1) << slot)) != 0 {
				v := cl.vb_views[slot]
				if gpu_va := upload_cpu_to_host_buf(cl, v.BufferLocation, v.SizeInBytes); gpu_va != 0 {
					hv := D3D12_VERTEX_BUFFER_VIEW{
						BufferLocation = gpu_va,
						SizeInBytes    = v.SizeInBytes,
						StrideInBytes  = v.StrideInBytes,
					}
					lvt.IASetVertexBuffers(hl, slot, 1, &hv)
				}
			}
		}
	}
	if cl.has_ib {
		if gpu_va := upload_cpu_to_host_buf(cl, cl.ib_view.BufferLocation, cl.ib_view.SizeInBytes); gpu_va != 0 {
			hi := D3D12_INDEX_BUFFER_VIEW{
				BufferLocation = gpu_va,
				SizeInBytes    = cl.ib_view.SizeInBytes,
				Format         = cl.ib_view.Format,
			}
			lvt.IASetIndexBuffer(hl, &hi)
		}
	}
	for ri in u32(0) ..< cl.num_cur_rts {
		if cl.cur_rts[ri] != nil {
			cl.cur_rts[ri].was_drawn = true
			if ri == 0 {
				g_last_drawn_rt = cl.cur_rts[0]
			}
		}
	}
	return hl
}

@(private)
can_host_copy_resources :: proc "contextless" (dr, sr: ^Console_Resource) -> bool {
	if dr == nil || sr == nil {
		return false
	}
	if dr.desc.Dimension < 2 || dr.desc.Dimension > 4 {
		return false
	}
	if dr.desc.Dimension != sr.desc.Dimension {
		return false
	}
	if dr.desc.Width != sr.desc.Width || dr.desc.Height != sr.desc.Height {
		return false
	}
	if max(dr.desc.DepthOrArraySize, u16(1)) != max(sr.desc.DepthOrArraySize, u16(1)) {
		return false
	}
	if max(dr.desc.SampleCount, u32(1)) != max(sr.desc.SampleCount, u32(1)) {
		return false
	}
	if dr.desc.MipLevels != sr.desc.MipLevels {
		return false
	}
	if map_host_texture_format(dr.desc.Format) != map_host_texture_format(sr.desc.Format) {
		return false
	}
	return true
}

@(private)
create_host_upload_buffer :: proc(bytes: u64) -> (buf: rawptr, mapped: rawptr) {
	if bytes == 0 || bytes > (128 << 20) {
		return nil, nil
	}
	hdev := ensure_host_device()
	if hdev == nil {
		return nil, nil
	}
	heap_props := D3D12_HEAP_PROPERTIES{
		Type             = D3D12_HEAP_TYPE_UPLOAD,
		CreationNodeMask = 1,
		VisibleNodeMask  = 1,
	}
	desc := D3D12_RESOURCE_DESC{
		Dimension        = D3D12_RESOURCE_DIMENSION_BUFFER,
		Width            = bytes,
		Height           = 1,
		DepthOrArraySize = 1,
		MipLevels        = 1,
		Format           = 0,
		SampleCount      = 1,
		Layout           = D3D12_TEXTURE_LAYOUT_ROW_MAJOR,
	}
	dvt := (cast(^^Draw_Dev_Vtbl)hdev)^
	res_iid := IID_ID3D12Resource_G
	if dvt.CreateCommittedResource(hdev, &heap_props, 0, &desc, D3D12_RESOURCE_STATE_GENERIC_READ, nil, &res_iid, &buf) < 0 || buf == nil {
		return nil, nil
	}
	rvt := (cast(^^Win_Res_Vtbl)buf)^
	if rvt.Map(buf, 0, nil, &mapped) < 0 || mapped == nil {
		com_release(buf)
		return nil, nil
	}
	return buf, mapped
}

@(private)
host_copy_texture_region :: proc(
	cl: ^Console_Cmd_List,
	dst_loc_in: ^D3D12_TEXTURE_COPY_LOCATION,
	dst_x, dst_y, dst_z: u32,
	src_loc_in: ^D3D12_TEXTURE_COPY_LOCATION,
	src_box: ^D3D12_BOX,
) {
	if cl == nil || cl.is_closed || uintptr(dst_loc_in) < 0x10000 || uintptr(src_loc_in) < 0x10000 {
		return
	}
	if uintptr(dst_loc_in.pResource) < 0x10000 || uintptr(src_loc_in.pResource) < 0x10000 {
		return
	}
	dr := cast(^Console_Resource)dst_loc_in.pResource
	sr := cast(^Console_Resource)src_loc_in.pResource
	if (dr.object.bits & 0xFF) != u32(Object_Kind.Resource) || (sr.object.bits & 0xFF) != u32(Object_Kind.Resource) {
		return
	}

	box_ptr := rawptr(src_box) if uintptr(src_box) >= 0x10000 else nil
	dr.gpu_written = true

	// Texture -> Texture copy on host GPU
	if dst_loc_in.Type == 0 && src_loc_in.Type == 0 {
		dtex, _ := ensure_host_texture(dr)
		stex, _ := ensure_host_texture(sr)
		if dtex == nil || stex == nil {
			return
		}
		hl := ensure_cl_host_list(cl)
		if hl == nil {
			return
		}
		host_transition_resource(hl, dr, D3D12_RESOURCE_STATE_COPY_DEST)
		host_transition_resource(hl, sr, D3D12_RESOURCE_STATE_COPY_SOURCE)

		dst_loc := dst_loc_in^
		src_loc := src_loc_in^
		dst_loc.pResource = dtex
		src_loc.pResource = stex
		lvt := (cast(^^Host_Cmd_List_Vtbl)hl)^
		lvt.CopyTextureRegion(hl, &dst_loc, dst_x, dst_y, dst_z, &src_loc, box_ptr)
		return
	}

	// CPU-visible Buffer -> Texture upload on host GPU
	if dst_loc_in.Type == 0 && src_loc_in.Type == 1 {
		if sr.address < 0x10000 {
			return
		}
		dtex, _ := ensure_host_texture(dr)
		if dtex == nil {
			return
		}
		fp := src_loc_in.PlacedFootprint
		if fp.Footprint.Width == 0 || fp.Footprint.Height == 0 || fp.Footprint.RowPitch == 0 {
			return
		}
		host_fmt := map_host_texture_format(fp.Footprint.Format)
		_, blk := dxgi_format_bpp(host_fmt)
		bh := max((fp.Footprint.Height + blk - 1) / blk, u32(1))
		dep := max(fp.Footprint.Depth, u32(1))
		src_pitch := fp.Footprint.RowPitch
		dst_pitch := (src_pitch + 255) & ~u32(255)
		total_bytes := u64(dst_pitch) * u64(bh) * u64(dep)

		up_buf, mapped := create_host_upload_buffer(total_bytes)
		if up_buf == nil || mapped == nil {
			return
		}
		src_base := uintptr(sr.address + fp.Offset)
		if src_pitch == dst_pitch {
			mem.copy(mapped, rawptr(src_base), int(total_bytes))
		} else {
			rows := u64(bh) * u64(dep)
			copy_bytes := min(int(src_pitch), int(dst_pitch))
			for row in 0 ..< rows {
				mem.copy(
					rawptr(uintptr(mapped) + uintptr(row * u64(dst_pitch))),
					rawptr(src_base + uintptr(row * u64(src_pitch))),
					copy_bytes,
				)
			}
		}
		rvt := (cast(^^Win_Res_Vtbl)up_buf)^
		rvt.Unmap(up_buf, 0, nil)

		hl := ensure_cl_host_list(cl)
		if hl == nil {
			com_release(up_buf)
			return
		}
		append(&cl.host_temps, up_buf)
		host_transition_resource(hl, dr, D3D12_RESOURCE_STATE_COPY_DEST)

		dst_loc := dst_loc_in^
		dst_loc.pResource = dtex
		src_loc := src_loc_in^
		src_loc.pResource = up_buf
		src_loc.PlacedFootprint.Offset = 0
		src_loc.PlacedFootprint.Footprint.Format = host_fmt
		src_loc.PlacedFootprint.Footprint.RowPitch = dst_pitch

		lvt := (cast(^^Host_Cmd_List_Vtbl)hl)^
		lvt.CopyTextureRegion(hl, &dst_loc, dst_x, dst_y, dst_z, &src_loc, box_ptr)
	}
}

@(private)
queue_signal_and_wait_host_fence :: proc(q: ^Console_Queue) {
	if q == nil || q.host_queue == nil {
		return
	}
	if q.host_fence == nil {
		hdev := ensure_host_device()
		if hdev == nil {
			return
		}
		dvt := (cast(^^Draw_Dev_Vtbl)hdev)^
		f_iid := IID_ID3D12Fence_G
		if dvt.CreateFence(hdev, 0, 0, &f_iid, &q.host_fence) < 0 || q.host_fence == nil {
			q.host_fence = nil
			return
		}
	}
	if q.host_fence_event == nil {
		q.host_fence_event = win32.CreateEventW(nil, false, false, nil)
		if q.host_fence_event == nil {
			return
		}
	}

	q.host_fence_val += 1
	target := q.host_fence_val
	qvt := (cast(^^Exec_Queue_Vtbl)q.host_queue)^
	if qvt.Signal(q.host_queue, q.host_fence, target) < 0 {
		return
	}
	fvt := (cast(^^Exec_Fence_Vtbl)q.host_fence)^
	if fvt.GetCompletedValue(q.host_fence) >= target {
		return
	}
	if fvt.SetEventOnCompletion(q.host_fence, target, q.host_fence_event) >= 0 {
		_ = win32.WaitForSingleObject(q.host_fence_event, win32.INFINITE)
	}
}
