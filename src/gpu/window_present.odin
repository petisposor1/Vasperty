package vasperty_gpu

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import win32 "core:sys/windows"

// Real Win32 + DXGI IDXGISwapChain3 Window Presenter for Xbox D3D12.X PresentX.
// Lazily creates a 1280x720 Win32 window backed by the host ID3D12CommandQueue,
// pumps Win32 messages, clears or copies to the backbuffer, presents with VSync,
// and optionally writes BMP/PPM screenshots when VASPERTY_SCREENSHOT_PATH is set.

WIN_PRESENT_WIDTH  :: u32(1280)
WIN_PRESENT_HEIGHT :: u32(720)
WIN_BUFFER_COUNT   :: u32(2)

@(private)
DXGI_USAGE_RENDER_TARGET_OUTPUT :: u32(0x00000020)
@(private)
DXGI_SCALING_STRETCH :: u32(0)
@(private)
DXGI_SWAP_EFFECT_FLIP_DISCARD :: u32(4)
@(private)
DXGI_ALPHA_MODE_UNSPECIFIED :: u32(0)
@(private)
DXGI_MWA_NO_ALT_ENTER :: u32(0x00000002)

@(private)
D3D12_DESCRIPTOR_HEAP_TYPE_RTV :: u32(2)
@(private)
D3D12_HEAP_TYPE_READBACK :: u32(3)
@(private)
D3D12_RESOURCE_DIMENSION_BUFFER :: u32(1)
@(private)
D3D12_TEXTURE_LAYOUT_ROW_MAJOR :: u32(1)

@(private)
D3D12_RESOURCE_STATE_PRESENT :: u32(0)
@(private)
D3D12_RESOURCE_STATE_RENDER_TARGET :: u32(0x4)
@(private)
D3D12_RESOURCE_STATE_COPY_DEST :: u32(0x400)
@(private)
D3D12_RESOURCE_STATE_COPY_SOURCE :: u32(0x800)
@(private)
D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES :: u32(0xFFFFFFFF)

@(private)
IID_ID3D12DescriptorHeap_G := guid(0x8efb471d, 0x616c, 0x4f49, {0x90, 0xf7, 0x12, 0x7b, 0xb7, 0x63, 0xfa, 0x51})
@(private)
IID_ID3D12Resource_G := guid(0x696442be, 0xa72e, 0x4059, {0xbc, 0x79, 0x5b, 0x5c, 0x98, 0x04, 0x0f, 0xad})
@(private)
IID_IDXGISwapChain1_G := guid(0x790a45f7, 0x0d42, 0x4876, {0x98, 0x3a, 0x0a, 0x55, 0xcf, 0xe6, 0xf4, 0xaa})
@(private)
IID_IDXGISwapChain3_G := guid(0x94d99bdb, 0xf1f8, 0x4ab0, {0xb2, 0x36, 0x7d, 0xa0, 0x17, 0x0e, 0xda, 0xb1})

@(private)
DXGI_SAMPLE_DESC :: struct {
	Count:   u32,
	Quality: u32,
}

@(private)
DXGI_SWAP_CHAIN_DESC1 :: struct {
	Width:       u32,
	Height:      u32,
	Format:      u32,
	Stereo:      i32,
	SampleDesc:  DXGI_SAMPLE_DESC,
	BufferUsage: u32,
	BufferCount: u32,
	Scaling:     u32,
	SwapEffect:  u32,
	AlphaMode:   u32,
	Flags:       u32,
}

@(private)
D3D12_RESOURCE_TRANSITION_BARRIER :: struct {
	pResource:   rawptr,
	Subresource: u32,
	StateBefore: u32,
	StateAfter:  u32,
}

@(private)
D3D12_RESOURCE_BARRIER :: struct {
	Type:       u32,
	Flags:      u32,
	Transition: D3D12_RESOURCE_TRANSITION_BARRIER,
}

#assert(size_of(D3D12_RESOURCE_BARRIER) == 32)

@(private)
D3D12_TEXTURE_COPY_LOCATION :: struct {
	pResource: rawptr,
	Type:      u32,
	using _:   struct #raw_union {
		PlacedFootprint:  D3D12_PLACED_SUBRESOURCE_FOOTPRINT,
		SubresourceIndex: u32,
	},
}

#assert(size_of(D3D12_TEXTURE_COPY_LOCATION) == 48)

@(private)
D3D12_BOX :: struct {
	left:   u32,
	top:    u32,
	front:  u32,
	right:  u32,
	bottom: u32,
	back:   u32,
}

#assert(size_of(D3D12_BOX) == 24)

@(private)
Win_Factory4_Vtbl :: struct {
	_pad0:                 [8]rawptr,
	MakeWindowAssociation: proc "system" (rawptr, win32.HWND, u32) -> HRESULT,                               // 8
	_pad1:                 [6]rawptr,                                                                        // 9..14
	CreateSwapChainForHwnd: proc "system" (rawptr, rawptr, win32.HWND, ^DXGI_SWAP_CHAIN_DESC1, rawptr, rawptr, ^rawptr) -> HRESULT, // 15
}

@(private)
Win_SwapChain3_Vtbl :: struct {
	_pad0:                     [8]rawptr,
	Present:                   proc "system" (rawptr, u32, u32) -> HRESULT,         // 8
	GetBuffer:                 proc "system" (rawptr, u32, ^Iid, ^rawptr) -> HRESULT, // 9
	_pad1:                     [26]rawptr,                                         // 10..35
	GetCurrentBackBufferIndex: proc "system" (rawptr) -> u32,                      // 36
}

@(private)
Win_Queue_Child_Vtbl :: struct {
	_pad0:     [7]rawptr,
	GetDevice: proc "system" (rawptr, ^Iid, ^rawptr) -> HRESULT, // 7
}

@(private)
Win_Dev_Vtbl :: struct {
	_pad0:                            [9]rawptr,
	CreateCommandAllocator:           proc "system" (rawptr, u32, ^Iid, ^rawptr) -> HRESULT,                         // 9
	_pad1:                            [2]rawptr,                                                                     // 10..11
	CreateCommandList:                proc "system" (rawptr, u32, u32, rawptr, rawptr, ^Iid, ^rawptr) -> HRESULT,    // 12
	_pad2:                            rawptr,                                                                        // 13
	CreateDescriptorHeap:             proc "system" (rawptr, ^D3D12_DESCRIPTOR_HEAP_DESC, ^Iid, ^rawptr) -> HRESULT, // 14
	GetDescriptorHandleIncrementSize: proc "system" (rawptr, u32) -> u32,                                            // 15
	_pad3:                            [4]rawptr,                                                                     // 16..19
	CreateRenderTargetView:           proc "system" (rawptr, rawptr, rawptr, u64),                                   // 20
	_pad4:                            [6]rawptr,                                                                     // 21..26
	CreateCommittedResource:          proc "system" (rawptr, ^D3D12_HEAP_PROPERTIES, u32, ^D3D12_RESOURCE_DESC, u32, rawptr, ^Iid, ^rawptr) -> HRESULT, // 27
	_pad5:                            [8]rawptr,                                                                     // 28..35
	CreateFence:                      proc "system" (rawptr, u64, u32, ^Iid, ^rawptr) -> HRESULT,                    // 36
}

@(private)
Win_Desc_Heap_Vtbl :: struct {
	_pad0:                             [9]rawptr,
	GetCPUDescriptorHandleForHeapStart: proc "system" (rawptr, ^u64) -> ^u64, // 9 (MSVC x64 COM sret)
}

@(private)
Win_Cmd_List_Vtbl :: struct {
	_pad0:                 [9]rawptr,
	Close:                 proc "system" (rawptr) -> HRESULT,                                                                       // 9
	Reset:                 proc "system" (rawptr, rawptr, rawptr) -> HRESULT,                                                       // 10
	_pad1:                 [5]rawptr,                                                                                               // 11..15
	CopyTextureRegion:     proc "system" (rawptr, ^D3D12_TEXTURE_COPY_LOCATION, u32, u32, u32, ^D3D12_TEXTURE_COPY_LOCATION, rawptr), // 16
	CopyResource:          proc "system" (rawptr, rawptr, rawptr),                                                                  // 17
	_pad2:                 [8]rawptr,                                                                                               // 18..25
	ResourceBarrier:       proc "system" (rawptr, u32, ^D3D12_RESOURCE_BARRIER),                                                    // 26
	_pad3:                 [21]rawptr,                                                                                              // 27..47
	ClearRenderTargetView: proc "system" (rawptr, u64, ^[4]f32, u32, rawptr),                                                       // 48
}

@(private)
Win_Res_Vtbl :: struct {
	_pad0:   [8]rawptr,
	Map:     proc "system" (rawptr, u32, rawptr, ^rawptr) -> HRESULT,                   // 8
	Unmap:   proc "system" (rawptr, u32, rawptr),                                       // 9
	GetDesc: proc "system" (rawptr, ^D3D12_RESOURCE_DESC) -> ^D3D12_RESOURCE_DESC,      // 10
}

@(private)
Window_Presenter :: struct {
	initialized:      bool,
	failed:           bool,
	closed:           bool,
	class_registered: bool,
	owns_device_ref:  bool,
	owner_thread:     win32.DWORD,
	hwnd:             win32.HWND,
	device:           rawptr,
	swapchain:        rawptr,
	rtv_heap:         rawptr,
	rtv_base:         u64,
	rtv_inc:          u32,
	backbuffers:      [WIN_BUFFER_COUNT]rawptr,
	allocators:       [WIN_BUFFER_COUNT]rawptr,
	frame_fences:     [WIN_BUFFER_COUNT]u64,
	cmd_list:         rawptr,
	fence:            rawptr,
	fence_event:      win32.HANDLE,
	fence_value:      u64,
	readback_buf:     rawptr,
	readback_pitch:   u32,
	readback_w:       u32,
	readback_h:       u32,
}

@(private)
g_win_mu: sync.Mutex
@(private)
g_win: Window_Presenter

@(private)
window_proc :: proc "system" (hwnd: win32.HWND, msg: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) -> win32.LRESULT {
	switch msg {
	case win32.WM_CLOSE:
		g_win.closed = true
		_ = win32.DestroyWindow(hwnd)
		return 0
	case win32.WM_DESTROY:
		g_win.closed = true
		win32.PostQuitMessage(0)
		return 0
	}
	return win32.DefWindowProcW(hwnd, msg, wparam, lparam)
}

@(private)
cleanup_window_presenter :: proc(wp: ^Window_Presenter) {
	if wp.readback_buf != nil {
		com_release(wp.readback_buf)
		wp.readback_buf = nil
	}
	if wp.cmd_list != nil {
		com_release(wp.cmd_list)
		wp.cmd_list = nil
	}
	for i in 0 ..< WIN_BUFFER_COUNT {
		if wp.allocators[i] != nil {
			com_release(wp.allocators[i])
			wp.allocators[i] = nil
		}
		if wp.backbuffers[i] != nil {
			com_release(wp.backbuffers[i])
			wp.backbuffers[i] = nil
		}
	}
	if wp.rtv_heap != nil {
		com_release(wp.rtv_heap)
		wp.rtv_heap = nil
	}
	if wp.swapchain != nil {
		com_release(wp.swapchain)
		wp.swapchain = nil
	}
	if wp.fence_event != nil {
		_ = win32.CloseHandle(wp.fence_event)
		wp.fence_event = nil
	}
	if wp.fence != nil {
		com_release(wp.fence)
		wp.fence = nil
	}
	if wp.device != nil && wp.owns_device_ref {
		com_release(wp.device)
	}
	wp.device = nil
	wp.owns_device_ref = false
	if wp.hwnd != nil {
		_ = win32.DestroyWindow(wp.hwnd)
		wp.hwnd = nil
	}
	wp.initialized = false
}

@(private)
init_window_presenter :: proc(wp: ^Window_Presenter, host_queue: rawptr) -> bool {
	dlls := ensure_d3d12_dlls()
	if dlls.create_dxgi_fac2 == nil {
		return false
	}

	// Obtain host ID3D12Device matching host_queue (falling back to shared host device).
	dev_iid := guid(0x189819f1, 0x1db6, 0x4b57, {0xbe, 0x54, 0x18, 0x21, 0x33, 0x9b, 0x85, 0xf7})
	qchild_vt := (cast(^^Win_Queue_Child_Vtbl)host_queue)^
	if qchild_vt.GetDevice(host_queue, &dev_iid, &wp.device) >= 0 && wp.device != nil {
		wp.owns_device_ref = true
	} else {
		wp.device = ensure_host_device()
		wp.owns_device_ref = false
	}
	if wp.device == nil {
		return false
	}

	// Create 1280x720 Win32 window.
	hinst := win32.HINSTANCE(win32.GetModuleHandleW(nil))
	class_w := win32.utf8_to_wstring("VaspertyScarlettWindow", context.temp_allocator)
	title_w := win32.utf8_to_wstring("Vasperty - Xbox Scarlett", context.temp_allocator)

	if !wp.class_registered {
		wc := win32.WNDCLASSEXW{
			cbSize        = size_of(win32.WNDCLASSEXW),
			style         = win32.CS_HREDRAW | win32.CS_VREDRAW,
			lpfnWndProc   = window_proc,
			hInstance     = hinst,
			hCursor       = win32.LoadCursorW(nil, transmute(win32.LPCWSTR)uintptr(32512)),
			lpszClassName = class_w,
		}
		ERROR_CLASS_ALREADY_EXISTS :: u32(1410)
		if win32.RegisterClassExW(&wc) == 0 && win32.GetLastError() != ERROR_CLASS_ALREADY_EXISTS {
			return false
		}
		wp.class_registered = true
	}

	style := win32.WS_OVERLAPPEDWINDOW
	rect := win32.RECT{0, 0, i32(WIN_PRESENT_WIDTH), i32(WIN_PRESENT_HEIGHT)}
	_ = win32.AdjustWindowRect(&rect, style, false)

	wp.hwnd = win32.CreateWindowExW(
		0,
		class_w,
		title_w,
		style,
		win32.CW_USEDEFAULT,
		win32.CW_USEDEFAULT,
		rect.right - rect.left,
		rect.bottom - rect.top,
		nil,
		nil,
		hinst,
		nil,
	)
	if wp.hwnd == nil {
		return false
	}
	wp.owner_thread = win32.GetCurrentThreadId()
	_ = win32.ShowWindow(wp.hwnd, win32.SW_SHOW)
	_ = win32.UpdateWindow(wp.hwnd)

	// Create DXGI Factory4 and IDXGISwapChain3 backed by host_queue.
	fac: rawptr
	f4_iid := IID_IDXGIFactory4_G
	if dlls.create_dxgi_fac2(0, &f4_iid, &fac) < 0 || fac == nil {
		return false
	}
	defer com_release(fac)

	fvt := (cast(^^Win_Factory4_Vtbl)fac)^
	_ = fvt.MakeWindowAssociation(fac, wp.hwnd, DXGI_MWA_NO_ALT_ENTER)

	sc_desc := DXGI_SWAP_CHAIN_DESC1{
		Width       = WIN_PRESENT_WIDTH,
		Height      = WIN_PRESENT_HEIGHT,
		Format      = DXGI_FORMAT_R8G8B8A8_UNORM,
		Stereo      = 0,
		SampleDesc  = {Count = 1, Quality = 0},
		BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT,
		BufferCount = WIN_BUFFER_COUNT,
		Scaling     = DXGI_SCALING_STRETCH,
		SwapEffect  = DXGI_SWAP_EFFECT_FLIP_DISCARD,
		AlphaMode   = DXGI_ALPHA_MODE_UNSPECIFIED,
		Flags       = 0,
	}
	sc1: rawptr
	if fvt.CreateSwapChainForHwnd(fac, host_queue, wp.hwnd, &sc_desc, nil, nil, &sc1) < 0 || sc1 == nil {
		return false
	}
	sc3_iid := IID_IDXGISwapChain3_G
	wp.swapchain = com_query(sc1, &sc3_iid)
	com_release(sc1)
	if wp.swapchain == nil {
		return false
	}

	// Create RTV heap, backbuffer RTVs, per-buffer allocators, command list, and fence.
	dvt := (cast(^^Win_Dev_Vtbl)wp.device)^
	heap_desc := D3D12_DESCRIPTOR_HEAP_DESC{
		Type           = D3D12_DESCRIPTOR_HEAP_TYPE_RTV,
		NumDescriptors = WIN_BUFFER_COUNT,
		Flags          = 0,
		NodeMask       = 0,
	}
	dh_iid := IID_ID3D12DescriptorHeap_G
	if dvt.CreateDescriptorHeap(wp.device, &heap_desc, &dh_iid, &wp.rtv_heap) < 0 || wp.rtv_heap == nil {
		return false
	}
	dhvt := (cast(^^Win_Desc_Heap_Vtbl)wp.rtv_heap)^
	_ = dhvt.GetCPUDescriptorHandleForHeapStart(wp.rtv_heap, &wp.rtv_base)
	wp.rtv_inc = dvt.GetDescriptorHandleIncrementSize(wp.device, D3D12_DESCRIPTOR_HEAP_TYPE_RTV)

	scvt := (cast(^^Win_SwapChain3_Vtbl)wp.swapchain)^
	res_iid := IID_ID3D12Resource_G
	alloc_iid := IID_ID3D12CommandAllocator_G
	for i in 0 ..< WIN_BUFFER_COUNT {
		if scvt.GetBuffer(wp.swapchain, i, &res_iid, &wp.backbuffers[i]) < 0 || wp.backbuffers[i] == nil {
			return false
		}
		rtv_handle := wp.rtv_base + u64(i) * u64(wp.rtv_inc)
		dvt.CreateRenderTargetView(wp.device, wp.backbuffers[i], nil, rtv_handle)
		if dvt.CreateCommandAllocator(wp.device, D3D12_COMMAND_LIST_TYPE_DIRECT, &alloc_iid, &wp.allocators[i]) < 0 || wp.allocators[i] == nil {
			return false
		}
	}

	list_iid := IID_ID3D12GraphicsCommandList_G
	if dvt.CreateCommandList(wp.device, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, wp.allocators[0], nil, &list_iid, &wp.cmd_list) < 0 || wp.cmd_list == nil {
		return false
	}
	lvt := (cast(^^Win_Cmd_List_Vtbl)wp.cmd_list)^
	if lvt.Close(wp.cmd_list) < 0 {
		return false
	}

	fence_iid := IID_ID3D12Fence_G
	if dvt.CreateFence(wp.device, 0, 0, &fence_iid, &wp.fence) < 0 || wp.fence == nil {
		return false
	}
	wp.fence_event = win32.CreateEventW(nil, false, false, nil)
	if wp.fence_event == nil {
		return false
	}

	wp.initialized = true
	return true
}

@(private)
wait_presenter_fence :: proc(wp: ^Window_Presenter, target: u64) {
	if wp.fence == nil || target == 0 {
		return
	}
	fvt := (cast(^^Exec_Fence_Vtbl)wp.fence)^
	if fvt.GetCompletedValue(wp.fence) >= target {
		return
	}
	if fvt.SetEventOnCompletion(wp.fence, target, wp.fence_event) >= 0 {
		_ = win32.WaitForSingleObject(wp.fence_event, win32.INFINITE)
	}
}

@(private)
transition_barrier :: proc "contextless" (res: rawptr, before, after: u32) -> D3D12_RESOURCE_BARRIER {
	return D3D12_RESOURCE_BARRIER{
		Type  = 0,
		Flags = 0,
		Transition = D3D12_RESOURCE_TRANSITION_BARRIER{
			pResource   = res,
			Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
			StateBefore = before,
			StateAfter  = after,
		},
	}
}

@(private)
frame_clear_color :: proc "contextless" (frame_num: u64) -> [4]f32 {
	// Deep Xbox Scarlett emerald tone with subtle per-frame pulse so live frames are distinct.
	phase := f32(frame_num % 120) / 120.0
	pulse := phase if phase <= 0.5 else (1.0 - phase)
	return [4]f32{0.04, 0.18 + 0.10 * pulse, 0.09 + 0.03 * pulse, 1.0}
}

@(private)
ensure_readback_buffer :: proc(wp: ^Window_Presenter, w, h: u32) -> bool {
	if wp.readback_buf != nil && wp.readback_w == w && wp.readback_h == h {
		return true
	}
	if wp.readback_buf != nil {
		com_release(wp.readback_buf)
		wp.readback_buf = nil
	}
	if wp.device == nil || w == 0 || h == 0 {
		return false
	}
	pitch := (w * 4 + 255) & ~u32(255)
	heap_props := D3D12_HEAP_PROPERTIES{
		Type = D3D12_HEAP_TYPE_READBACK,
	}
	res_desc := D3D12_RESOURCE_DESC{
		Dimension        = D3D12_RESOURCE_DIMENSION_BUFFER,
		Width            = u64(pitch) * u64(h),
		Height           = 1,
		DepthOrArraySize = 1,
		MipLevels        = 1,
		Format           = 0,
		SampleCount      = 1,
		Layout           = D3D12_TEXTURE_LAYOUT_ROW_MAJOR,
	}
	dvt := (cast(^^Win_Dev_Vtbl)wp.device)^
	res_iid := IID_ID3D12Resource_G
	if dvt.CreateCommittedResource(wp.device, &heap_props, 0, &res_desc, D3D12_RESOURCE_STATE_COPY_DEST, nil, &res_iid, &wp.readback_buf) < 0 || wp.readback_buf == nil {
		wp.readback_buf = nil
		return false
	}
	wp.readback_pitch = pitch
	wp.readback_w = w
	wp.readback_h = h
	return true
}

@(private)
should_capture_screenshot :: proc(frame_num: u64) -> (path: string, allocated: bool, ok: bool) {
	if frame_num != 1 && frame_num != 10 && frame_num != 60 && frame_num != 150 && frame_num != 300 && frame_num != 600 && frame_num != 1000 && frame_num != 1500 {
		return "", false, false
	}
	raw_path, found := os.lookup_env("VASPERTY_SCREENSHOT_PATH", context.allocator)
	if !found || len(raw_path) == 0 {
		delete(raw_path)
		return "", false, false
	}
	if strings.contains(raw_path, "{frame}") {
		defer delete(raw_path)
		num_buf: [32]u8
		num_str := fmt.bprintf(num_buf[:], "%d", frame_num)
		formatted, was_alloc := strings.replace_all(raw_path, "{frame}", num_str)
		if !was_alloc {
			return strings.clone(raw_path), true, true
		}
		return formatted, true, true
	}
	return raw_path, true, true
}

@(private)
put_u16_le :: proc "contextless" (dst: []u8, v: u16) {
	dst[0] = u8(v)
	dst[1] = u8(v >> 8)
}

@(private)
put_u32_le :: proc "contextless" (dst: []u8, v: u32) {
	dst[0] = u8(v)
	dst[1] = u8(v >> 8)
	dst[2] = u8(v >> 16)
	dst[3] = u8(v >> 24)
}

@(private)
write_screenshot_file :: proc(wp: ^Window_Presenter, path: string) {
	if wp.readback_buf == nil {
		return
	}
	rvt := (cast(^^Win_Res_Vtbl)wp.readback_buf)^
	mapped: rawptr
	if rvt.Map(wp.readback_buf, 0, nil, &mapped) < 0 || mapped == nil {
		return
	}
	defer rvt.Unmap(wp.readback_buf, 0, nil)

	src := cast([^]u8)mapped
	sw := int(wp.readback_w)
	sh := int(wp.readback_h)
	w := int(WIN_PRESENT_WIDTH)
	h := int(WIN_PRESENT_HEIGHT)
	pitch := int(wp.readback_pitch)
	is_ppm := strings.has_suffix(path, ".ppm") || strings.has_suffix(path, ".PPM")
	if is_ppm {
		hdr_buf: [64]u8
		hdr := fmt.bprintf(hdr_buf[:], "P6\n%d %d\n255\n", w, h)
		total := len(hdr) + w * h * 3
		out := make([]u8, total)
		defer delete(out)
		copy(out[:len(hdr)], transmute([]u8)hdr)
		di := len(hdr)
		for y in 0 ..< h {
			sy := (y * sh) / h
			row := src[sy * pitch:]
			for x in 0 ..< w {
				sx := (x * sw) / w
				si := sx * 4
				out[di + 0] = row[si + 0]
				out[di + 1] = row[si + 1]
				out[di + 2] = row[si + 2]
				di += 3
			}
		}
		_ = os.write_entire_file_from_bytes(path, out)
		return
	}

	// 32-bit top-down BGRA BMP (negative height avoids vertical flip).
	pixel_bytes := w * h * 4
	total := 54 + pixel_bytes
	out := make([]u8, total)
	defer delete(out)

	out[0] = 'B'
	out[1] = 'M'
	put_u32_le(out[2:6], u32(total))
	put_u32_le(out[10:14], 54)

	put_u32_le(out[14:18], 40)
	put_u32_le(out[18:22], u32(w))
	put_u32_le(out[22:26], u32(-i32(h)))
	put_u16_le(out[26:28], 1)
	put_u16_le(out[28:30], 32)
	put_u32_le(out[34:38], u32(pixel_bytes))

	di := 54
	for y in 0 ..< h {
		sy := (y * sh) / h
		row := src[sy * pitch:]
		for x in 0 ..< w {
			sx := (x * sw) / w
			si := sx * 4
			out[di + 0] = row[si + 2] // B
			out[di + 1] = row[si + 1] // G
			out[di + 2] = row[si + 0] // R
			out[di + 3] = row[si + 3] // A
			di += 4
		}
	}
	_ = os.write_entire_file_from_bytes(path, out)
}

@(private)
is_copy_compatible_rgba8 :: proc "contextless" (fmt_id: u32) -> bool {
	return fmt_id >= 27 && fmt_id <= 32
}

// Lazily opens the 1280x720 Win32 window + IDXGISwapChain3 backed by host_queue,
// pumps Win32 messages, renders/copies to the current backbuffer, optionally saves a
// BMP/PPM screenshot, and presents the frame.
present_window_frame :: proc(host_queue: rawptr, frame_num: u64, plane_res: rawptr, plane_state: u32 = 0, plane_w: u32 = 0, plane_h: u32 = 0) {
	if host_queue == nil {
		return
	}

	sync.mutex_lock(&g_win_mu)
	defer sync.mutex_unlock(&g_win_mu)

	if g_win.failed || g_win.closed {
		return
	}

	if !g_win.initialized {
		if !init_window_presenter(&g_win, host_queue) {
			cleanup_window_presenter(&g_win)
			g_win.failed = true
			return
		}
	}

	if g_win.owner_thread == win32.GetCurrentThreadId() {
		msg: win32.MSG
		for win32.PeekMessageW(&msg, nil, 0, 0, win32.PM_REMOVE) {
			if msg.message == win32.WM_QUIT {
				g_win.closed = true
				return
			}
			_ = win32.TranslateMessage(&msg)
			_ = win32.DispatchMessageW(&msg)
		}
	}

	if g_win.closed || !win32.IsWindow(g_win.hwnd) {
		g_win.closed = true
		return
	}

	scvt := (cast(^^Win_SwapChain3_Vtbl)g_win.swapchain)^
	buf_idx := scvt.GetCurrentBackBufferIndex(g_win.swapchain) % WIN_BUFFER_COUNT
	wait_presenter_fence(&g_win, g_win.frame_fences[buf_idx])

	alloc := g_win.allocators[buf_idx]
	avt := (cast(^^Exec_Alloc_Vtbl)alloc)^
	if avt.Reset(alloc) < 0 {
		return
	}
	lvt := (cast(^^Win_Cmd_List_Vtbl)g_win.cmd_list)^
	if lvt.Reset(g_win.cmd_list, alloc, nil) < 0 {
		return
	}

	can_copy := false
	copy_w := u32(0)
	copy_h := u32(0)
	src_full_w := u32(0)
	src_full_h := u32(0)
	if plane_res != nil {
		rvt := (cast(^^Win_Res_Vtbl)plane_res)^
		pdesc: D3D12_RESOURCE_DESC
		_ = rvt.GetDesc(plane_res, &pdesc)
		w := plane_w if plane_w > 0 else u32(pdesc.Width)
		h := plane_h if plane_h > 0 else pdesc.Height
		if pdesc.Dimension == 3 && pdesc.SampleCount == 1 && is_copy_compatible_rgba8(pdesc.Format) && w > 0 && h > 0 {
			src_full_w = w
			src_full_h = h
			copy_w = min(w, WIN_PRESENT_WIDTH)
			copy_h = min(h, WIN_PRESENT_HEIGHT)
			can_copy = true
		}
	}

	shot_path, shot_alloc, want_shot := should_capture_screenshot(frame_num)
	defer if shot_alloc { delete(shot_path) }
	shot_from_plane := false
	if want_shot {
		rb_w := src_full_w if can_copy else WIN_PRESENT_WIDTH
		rb_h := src_full_h if can_copy else WIN_PRESENT_HEIGHT
		want_shot = ensure_readback_buffer(&g_win, rb_w, rb_h)
		shot_from_plane = want_shot && can_copy
	}

	bb := g_win.backbuffers[buf_idx]
	if can_copy {
		in_barriers: [2]D3D12_RESOURCE_BARRIER
		in_count := u32(0)
		in_barriers[in_count] = transition_barrier(bb, D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_COPY_DEST)
		in_count += 1
		if plane_state != D3D12_RESOURCE_STATE_COPY_SOURCE {
			in_barriers[in_count] = transition_barrier(plane_res, plane_state, D3D12_RESOURCE_STATE_COPY_SOURCE)
			in_count += 1
		}
		lvt.ResourceBarrier(g_win.cmd_list, in_count, &in_barriers[0])

		src_loc := D3D12_TEXTURE_COPY_LOCATION{
			pResource        = plane_res,
			Type             = 0,
			SubresourceIndex = 0,
		}
		dst_loc := D3D12_TEXTURE_COPY_LOCATION{
			pResource        = bb,
			Type             = 0,
			SubresourceIndex = 0,
		}
		src_left := (src_full_w - copy_w) / 2
		src_top := (src_full_h - copy_h) / 2
		src_box := D3D12_BOX{
			left   = src_left,
			top    = src_top,
			front  = 0,
			right  = src_left + copy_w,
			bottom = src_top + copy_h,
			back   = 1,
		}
		lvt.CopyTextureRegion(g_win.cmd_list, &dst_loc, 0, 0, 0, &src_loc, &src_box)

		if shot_from_plane {
			rb_dst := D3D12_TEXTURE_COPY_LOCATION{
				pResource = g_win.readback_buf,
				Type      = 1,
				PlacedFootprint = D3D12_PLACED_SUBRESOURCE_FOOTPRINT{
					Offset = 0,
					Footprint = D3D12_SUBRESOURCE_FOOTPRINT{
						Format   = DXGI_FORMAT_R8G8B8A8_UNORM,
						Width    = g_win.readback_w,
						Height   = g_win.readback_h,
						Depth    = 1,
						RowPitch = g_win.readback_pitch,
					},
				},
			}
			lvt.CopyTextureRegion(g_win.cmd_list, &rb_dst, 0, 0, 0, &src_loc, nil)
		}

		out_barriers: [2]D3D12_RESOURCE_BARRIER
		out_count := u32(0)
		if plane_state != D3D12_RESOURCE_STATE_COPY_SOURCE {
			out_barriers[out_count] = transition_barrier(plane_res, D3D12_RESOURCE_STATE_COPY_SOURCE, plane_state)
			out_count += 1
		}
		out_barriers[out_count] = transition_barrier(bb, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_PRESENT)
		out_count += 1
		lvt.ResourceBarrier(g_win.cmd_list, out_count, &out_barriers[0])
	} else {
		b_in := transition_barrier(bb, D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_RENDER_TARGET)
		lvt.ResourceBarrier(g_win.cmd_list, 1, &b_in)
		rtv := g_win.rtv_base + u64(buf_idx) * u64(g_win.rtv_inc)
		clear_col := frame_clear_color(frame_num)
		lvt.ClearRenderTargetView(g_win.cmd_list, rtv, &clear_col, 0, nil)
		if want_shot {
			b_src := transition_barrier(bb, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_COPY_SOURCE)
			lvt.ResourceBarrier(g_win.cmd_list, 1, &b_src)
		} else {
			b_out := transition_barrier(bb, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_PRESENT)
			lvt.ResourceBarrier(g_win.cmd_list, 1, &b_out)
		}
	}

	if want_shot && !shot_from_plane {
		src_loc := D3D12_TEXTURE_COPY_LOCATION{
			pResource        = bb,
			Type             = 0,
			SubresourceIndex = 0,
		}
		dst_loc := D3D12_TEXTURE_COPY_LOCATION{
			pResource = g_win.readback_buf,
			Type      = 1,
			PlacedFootprint = D3D12_PLACED_SUBRESOURCE_FOOTPRINT{
				Offset = 0,
				Footprint = D3D12_SUBRESOURCE_FOOTPRINT{
					Format   = DXGI_FORMAT_R8G8B8A8_UNORM,
					Width    = WIN_PRESENT_WIDTH,
					Height   = WIN_PRESENT_HEIGHT,
					Depth    = 1,
					RowPitch = g_win.readback_pitch,
				},
			},
		}
		lvt.CopyTextureRegion(g_win.cmd_list, &dst_loc, 0, 0, 0, &src_loc, nil)
		b_out := transition_barrier(bb, D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_PRESENT)
		lvt.ResourceBarrier(g_win.cmd_list, 1, &b_out)
	}

	if lvt.Close(g_win.cmd_list) < 0 {
		return
	}

	qvt := (cast(^^Exec_Queue_Vtbl)host_queue)^
	lists := [1]rawptr{g_win.cmd_list}
	qvt.ExecuteCommandLists(host_queue, 1, &lists[0])

	if want_shot {
		g_win.fence_value += 1
		if qvt.Signal(host_queue, g_win.fence, g_win.fence_value) >= 0 {
			wait_presenter_fence(&g_win, g_win.fence_value)
			write_screenshot_file(&g_win, shot_path)
		}
	}

	_ = scvt.Present(g_win.swapchain, 1, 0)

	g_win.fence_value += 1
	if qvt.Signal(host_queue, g_win.fence, g_win.fence_value) >= 0 {
		g_win.frame_fences[buf_idx] = g_win.fence_value
	}
}
