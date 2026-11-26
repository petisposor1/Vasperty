package vasperty_gpu

// Hardware vendor tuning profiles (NVIDIA Wave32, Intel Integrated Wave16/UMA, Intel Arc,
// AMD RDNA, WARP) and asynchronous multi-frame Ring Scheduler with 64 KiB dirty-page tracking.

VENDOR_INTEL  :: u32(0x8086)
VENDOR_NVIDIA :: u32(0x10DE)
VENDOR_AMD    :: u32(0x1002)
VENDOR_WARP   :: u32(0x1414)

DIRTY_PAGE_GRANULARITY :: u64(64 << 10)

Gpu_Vendor :: enum {
	Unknown,
	Nvidia,
	Intel,
	Amd,
	Warp,
}

Gpu_Profile_Tier :: enum {
	Unknown,
	Intel_Integrated_Uhd_Xe,
	Intel_Discrete_Arc,
	Nvidia_Modern_Wave32,
	Amd_Rdna,
	Software_Warp,
}

Vendor_Tuning :: struct {
	vendor:                     Gpu_Vendor,
	tier:                       Gpu_Profile_Tier,
	profile_name:               string,
	is_uma:                     bool,
	target_wave_size:           u8,
	emulate_wave64:             bool,
	emulate_mesh_shaders:       bool,
	prefer_async_compute:       bool,
	enable_dxr_bvh:             bool,
	enable_depth_bounds:        bool,
	enable_pipeline_library:    bool,
	max_frames_in_flight:       u8,
	buffer_pool_budget_bytes:   u64,
	dirty_page_granularity_bytes: u64,
}

classify_vendor :: proc(caps: ^Host_Capabilities) -> Vendor_Tuning {
	out := Vendor_Tuning{
		vendor                       = .Unknown,
		tier                         = .Unknown,
		profile_name                 = "Generic D3D12",
		target_wave_size             = 32,
		emulate_wave64               = true,
		emulate_mesh_shaders         = caps != nil ? !caps.mesh_shaders : true,
		enable_pipeline_library      = true,
		max_frames_in_flight         = 2,
		buffer_pool_budget_bytes     = 128 << 20,
		dirty_page_granularity_bytes = DIRTY_PAGE_GRANULARITY,
	}
	if caps == nil {
		return out
	}

	switch caps.vendor_id {
	case VENDOR_INTEL:
		out.vendor = .Intel
		uma := caps.dedicated_video_memory < (512 << 20) ||
			caps.shared_system_memory > caps.dedicated_video_memory * 2
		if uma {
			out.tier = .Intel_Integrated_Uhd_Xe
			out.profile_name = "Intel Integrated (UHD / Xe UMA Wave16)"
			out.is_uma = true
			out.target_wave_size = 16
			if caps.wave_lane_count_max >= 32 && caps.wave_lane_count_min >= 32 {
				out.target_wave_size = 32
			}
			out.emulate_wave64 = true
			out.emulate_mesh_shaders = !caps.mesh_shaders
			out.prefer_async_compute = false
			out.enable_dxr_bvh = caps.raytracing_tier >= 10
			out.enable_depth_bounds = caps.depth_bounds
			out.enable_pipeline_library = true
			out.max_frames_in_flight = 2
			out.buffer_pool_budget_bytes = 64 << 20
		} else {
			out.tier = .Intel_Discrete_Arc
			out.profile_name = "Intel Discrete Arc (Xe-HPG)"
			out.is_uma = false
			out.target_wave_size = 32 if caps.wave_lane_count_max >= 32 else 16
			out.emulate_wave64 = caps.wave_lane_count_max < 64
			out.emulate_mesh_shaders = !caps.mesh_shaders
			out.prefer_async_compute = true
			out.enable_dxr_bvh = caps.raytracing_tier >= 10
			out.enable_depth_bounds = caps.depth_bounds
			out.enable_pipeline_library = true
			out.max_frames_in_flight = 3
			out.buffer_pool_budget_bytes = 192 << 20
		}

	case VENDOR_NVIDIA:
		out.vendor = .Nvidia
		out.tier = .Nvidia_Modern_Wave32
		out.profile_name = "NVIDIA (Wave32 Async + DXR)"
		out.is_uma = false
		out.target_wave_size = 32
		out.emulate_wave64 = true
		out.emulate_mesh_shaders = !caps.mesh_shaders
		out.prefer_async_compute = true
		out.enable_dxr_bvh = caps.raytracing_tier >= 10
		out.enable_depth_bounds = caps.depth_bounds
		out.enable_pipeline_library = true
		out.max_frames_in_flight = 3
		out.buffer_pool_budget_bytes = 256 << 20

	case VENDOR_AMD:
		out.vendor = .Amd
		out.tier = .Amd_Rdna
		out.profile_name = "AMD RDNA"
		out.is_uma = false
		out.target_wave_size = 64 if caps.wave_lane_count_max >= 64 else 32
		out.emulate_wave64 = caps.wave_lane_count_max < 64
		out.emulate_mesh_shaders = !caps.mesh_shaders
		out.prefer_async_compute = true
		out.enable_dxr_bvh = caps.raytracing_tier >= 10
		out.enable_depth_bounds = caps.depth_bounds
		out.enable_pipeline_library = true
		out.max_frames_in_flight = 3
		out.buffer_pool_budget_bytes = 256 << 20

	case VENDOR_WARP:
		out.vendor = .Warp
		out.tier = .Software_Warp
		out.profile_name = "Microsoft WARP Software"
		out.is_uma = true
		out.target_wave_size = 32
		out.emulate_wave64 = true
		out.emulate_mesh_shaders = !caps.mesh_shaders
		out.prefer_async_compute = false
		out.enable_dxr_bvh = false
		out.enable_depth_bounds = caps.depth_bounds
		out.enable_pipeline_library = true
		out.max_frames_in_flight = 2
		out.buffer_pool_budget_bytes = 64 << 20
	}

	return out
}

// =========================================================================
// Async Frame-In-Flight Ring Scheduler & 64 KiB Dirty-Page Writeback
// =========================================================================

Frame_Slot :: struct {
	fence_value: u64,
	submitted:   bool,
	dirty_pages: [dynamic]u64,
}

Frame_Ring :: struct {
	slots:           [dynamic]Frame_Slot,
	cursor:          int,
	next_fence:      u64,
	completed_fence: u64,
}

frame_ring_init :: proc(in_flight: int, allocator := context.allocator) -> Frame_Ring {
	n := max(in_flight, 1)
	slots := make([dynamic]Frame_Slot, n, allocator)
	for i := 0; i < n; i += 1 {
		slots[i].dirty_pages = make([dynamic]u64, 0, 16, allocator)
	}
	return Frame_Ring{
		slots           = slots,
		cursor          = 0,
		next_fence      = 1,
		completed_fence = 0,
	}
}

frame_ring_destroy :: proc(ring: ^Frame_Ring) {
	if ring == nil {
		return
	}
	for &s in ring.slots {
		delete(s.dirty_pages)
	}
	delete(ring.slots)
	ring^ = {}
}

// Acquires the current slot. Returns (slot_idx, wait_fence, needs_wait).
frame_ring_begin :: proc(ring: ^Frame_Ring) -> (slot_idx: int, wait_fence: u64, needs_wait: bool) {
	if ring == nil || len(ring.slots) == 0 {
		return 0, 0, false
	}
	idx := ring.cursor % len(ring.slots)
	s := &ring.slots[idx]
	if s.submitted && s.fence_value > ring.completed_fence {
		return idx, s.fence_value, true
	}
	clear(&s.dirty_pages)
	s.submitted = false
	return idx, 0, false
}

// Marks the 64 KiB page containing `addr` as dirty in the active slot (deduplicated).
frame_ring_mark_dirty_page :: proc(ring: ^Frame_Ring, slot_idx: int, addr: u64) {
	if ring == nil || slot_idx < 0 || slot_idx >= len(ring.slots) {
		return
	}
	page := addr & ~(DIRTY_PAGE_GRANULARITY - 1)
	s := &ring.slots[slot_idx]
	for existing in s.dirty_pages {
		if existing == page {
			return
		}
	}
	append(&s.dirty_pages, page)
}

// Assigns a monotonic fence to `slot_idx` and advances the ring cursor without blocking.
frame_ring_submit :: proc(ring: ^Frame_Ring, slot_idx: int) -> u64 {
	if ring == nil || slot_idx < 0 || slot_idx >= len(ring.slots) {
		return 0
	}
	f := ring.next_fence
	ring.next_fence += 1
	ring.slots[slot_idx].fence_value = f
	ring.slots[slot_idx].submitted = true
	ring.cursor = (slot_idx + 1) % len(ring.slots)
	return f
}

// Records host fence completion and retires completed frame slots & dirty lists.
frame_ring_complete :: proc(ring: ^Frame_Ring, fence: u64) {
	if ring == nil {
		return
	}
	if fence > ring.completed_fence {
		ring.completed_fence = fence
	}
	for &s in ring.slots {
		if s.submitted && s.fence_value <= ring.completed_fence {
			s.submitted = false
			clear(&s.dirty_pages)
		}
	}
}
