package vasperty_gpu

import "core:slice"

// Swapchain, HDR10/SDR Display Engine, Multi-Plane PresentX Compositor (#1997),
// and zero-allocation 64-frame Rolling Frame Pacer.

DXGI_FORMAT_R8G8B8A8_UNORM     :: u32(28)
DXGI_FORMAT_R10G10B10A2_UNORM  :: u32(24)
DXGI_FORMAT_R16G16B16A16_FLOAT :: u32(10)

Color_Space :: enum {
	Sdr_Srgb,
	Hdr10_Pq,
	Scrgb_Linear,
}

Swapchain_Config :: struct {
	width:            u32,
	height:           u32,
	buffer_count:     u32,
	format:           u32,
	color_space:      Color_Space,
	allow_tearing:    bool,
	hdr_paper_white:  f32, // nits for SDR UI overlay composited on HDR10
	max_luminance:    f32,
}

Present_Plane :: struct {
	active:       bool,
	resource_ptr: uintptr,
	format:       u32,
	width:        u32,
	height:       u32,
	alpha_blend:  bool,
	is_ui_layer:  bool,
}

MAX_PRESENT_PLANES :: 4

Present_Batch :: struct {
	plane_count: int,
	planes:      [MAX_PRESENT_PLANES]Present_Plane,
	sync_interval: u32,
	present_flags: u32,
}

swapchain_config_for_host :: proc(
	width, height: u32,
	caps: ^Host_Capabilities,
	tuning: ^Vendor_Tuning,
	prefer_hdr := false,
) -> Swapchain_Config {
	w := max(width, u32(1))
	h := max(height, u32(1))
	bufs := u32(max(int(tuning.max_frames_in_flight), 2)) if tuning != nil else u32(2)
	tearing := caps.allow_tearing if caps != nil else false

	fmt_id := DXGI_FORMAT_R8G8B8A8_UNORM
	cs := Color_Space.Sdr_Srgb
	if prefer_hdr {
		fmt_id = DXGI_FORMAT_R10G10B10A2_UNORM
		cs = .Hdr10_Pq
	}
	return Swapchain_Config{
		width           = w,
		height          = h,
		buffer_count    = bufs,
		format          = fmt_id,
		color_space     = cs,
		allow_tearing   = tearing,
		hdr_paper_white = 200.0,
		max_luminance   = 1000.0,
	}
}

// Builds a PresentX composition batch supporting main scene + UI overlay planes (#1997).
present_batch_init :: proc(allow_tearing: bool, vsync: bool) -> Present_Batch {
	DXGI_PRESENT_ALLOW_TEARING :: u32(0x00000200)
	flags := u32(0)
	interval := u32(1)
	if !vsync {
		interval = 0
		if allow_tearing {
			flags = DXGI_PRESENT_ALLOW_TEARING
		}
	}
	return Present_Batch{
		sync_interval = interval,
		present_flags = flags,
	}
}

present_batch_add_plane :: proc(b: ^Present_Batch, p: Present_Plane) -> bool {
	if b == nil || b.plane_count >= MAX_PRESENT_PLANES {
		return false
	}
	plane := p
	plane.active = true
	b.planes[b.plane_count] = plane
	b.plane_count += 1
	return true
}

present_batch_needs_composite :: proc "contextless" (b: ^Present_Batch) -> bool {
	return b != nil && b.plane_count > 1
}

// =========================================================================
// Zero-Allocation 64-Frame Rolling Frame Pacer
// =========================================================================

PACER_WINDOW :: 64

Frame_Pacer_Stats :: struct {
	samples: int,
	avg_ms:  f64,
	p50_ms:  f64,
	p95_ms:  f64,
	p99_ms:  f64,
	fps:     f64,
}

Frame_Pacer :: struct {
	ring:   [PACER_WINDOW]f64,
	cursor: int,
	count:  int,
}

frame_pacer_record :: proc(p: ^Frame_Pacer, frame_ms: f64) {
	if p == nil || frame_ms < 0 {
		return
	}
	p.ring[p.cursor] = frame_ms
	p.cursor = (p.cursor + 1) % PACER_WINDOW
	if p.count < PACER_WINDOW {
		p.count += 1
	}
}

frame_pacer_stats :: proc(p: ^Frame_Pacer) -> Frame_Pacer_Stats {
	if p == nil || p.count == 0 {
		return {}
	}
	tmp: [PACER_WINDOW]f64
	copy(tmp[:p.count], p.ring[:p.count])
	slice.sort(tmp[:p.count])
	sum := 0.0
	for i := 0; i < p.count; i += 1 {
		sum += tmp[i]
	}
	avg := sum / f64(p.count)
	idx50 := min((p.count * 50) / 100, p.count - 1)
	idx95 := min((p.count * 95) / 100, p.count - 1)
	idx99 := min((p.count * 99) / 100, p.count - 1)
	return Frame_Pacer_Stats{
		samples = p.count,
		avg_ms  = avg,
		p50_ms  = tmp[idx50],
		p95_ms  = tmp[idx95],
		p99_ms  = tmp[idx99],
		fps     = 1000.0 / max(avg, 0.001),
	}
}
