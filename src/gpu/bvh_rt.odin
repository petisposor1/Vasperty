package vasperty_gpu

// Real-Time BVH / Ray-Tracing Acceleration Structure Scheduler.
// Routes XboxBvhBuilder workloads to hardware DXR (NVIDIA RTX / Intel Arc / AMD RDNA2+)
// or Compute-emulated BVH4 fallback (Intel Integrated UHD/Xe UMA) with 256-byte D3D12
// acceleration structure alignment and per-vendor VRAM budgets.

BVH_ALIGN_BYTES :: u64(256)

Bvh_Backend :: enum {
	Hardware_Dxr,
	Compute_Bvh4_Fallback,
}

Bvh_Kind :: enum {
	Blas,
	Tlas,
}

Bvh_Entry :: struct {
	id:            u64,
	kind:          Bvh_Kind,
	prim_count:    u32,
	result_bytes:  u64,
	scratch_bytes: u64,
	generation:    u64,
	allow_refit:   bool,
	dirty:         bool,
}

Bvh_Rt_Manager :: struct {
	backend:       Bvh_Backend,
	budget_bytes:  u64,
	used_bytes:    u64,
	next_id:       u64,
	builds_total:  u64,
	refits_total:  u64,
	entries:       map[u64]Bvh_Entry,
}

@(private)
align_up_u64 :: proc "contextless" (v, align: u64) -> u64 {
	if align <= 1 {
		return v
	}
	return (v + align - 1) & ~(align - 1)
}

bvh_rt_init :: proc(tuning: ^Vendor_Tuning, allocator := context.allocator) -> Bvh_Rt_Manager {
	hw := tuning != nil && tuning.enable_dxr_bvh
	uma := tuning != nil && tuning.is_uma
	return Bvh_Rt_Manager{
		backend      = .Hardware_Dxr if hw else .Compute_Bvh4_Fallback,
		budget_bytes = (64 << 20) if uma else (512 << 20),
		next_id      = 1,
		entries      = make(map[u64]Bvh_Entry, 32, allocator),
	}
}

bvh_rt_destroy :: proc(m: ^Bvh_Rt_Manager) {
	if m == nil {
		return
	}
	delete(m.entries)
	m^ = {}
}

// Estimates D3D12 256-byte aligned result and scratch buffer sizes for a BLAS or TLAS.
bvh_prebuild_sizes :: proc "contextless" (kind: Bvh_Kind, prim_count: u32) -> (result_bytes, scratch_bytes: u64) {
	n := max(u64(prim_count), 1)
	if kind == .Blas {
		result_bytes = align_up_u64(n * 96 + 512, BVH_ALIGN_BYTES)
		scratch_bytes = align_up_u64(n * 128 + 1024, BVH_ALIGN_BYTES)
	} else {
		result_bytes = align_up_u64(n * 64 + 512, BVH_ALIGN_BYTES)
		scratch_bytes = align_up_u64(n * 96 + 1024, BVH_ALIGN_BYTES)
	}
	return result_bytes, scratch_bytes
}

bvh_rt_register :: proc(m: ^Bvh_Rt_Manager, kind: Bvh_Kind, prim_count: u32, allow_refit := true) -> (id: u64, ok: bool) {
	if m == nil {
		return 0, false
	}
	res_b, scr_b := bvh_prebuild_sizes(kind, prim_count)
	if m.used_bytes + res_b > m.budget_bytes {
		return 0, false
	}
	id = m.next_id
	m.next_id += 1
	m.entries[id] = Bvh_Entry{
		id            = id,
		kind          = kind,
		prim_count    = prim_count,
		result_bytes  = res_b,
		scratch_bytes = scr_b,
		allow_refit   = allow_refit,
		dirty         = true,
	}
	m.used_bytes += res_b
	return id, true
}

bvh_rt_build_or_refit :: proc(m: ^Bvh_Rt_Manager, id: u64) -> (was_refit: bool, ok: bool) {
	if m == nil {
		return false, false
	}
	ent, found := &m.entries[id]
	if !found {
		return false, false
	}
	if ent.generation > 0 && ent.allow_refit {
		ent.generation += 1
		ent.dirty = false
		m.refits_total += 1
		return true, true
	}
	ent.generation += 1
	ent.dirty = false
	m.builds_total += 1
	return false, true
}

bvh_rt_remove :: proc(m: ^Bvh_Rt_Manager, id: u64) {
	if m == nil {
		return
	}
	if ent, found := m.entries[id]; found {
		if m.used_bytes >= ent.result_bytes {
			m.used_bytes -= ent.result_bytes
		} else {
			m.used_bytes = 0
		}
		delete_key(&m.entries, id)
	}
}
