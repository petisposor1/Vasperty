package vasperty_core

import "core:fmt"
import "core:sync"

// Zero-allocation runtime telemetry counters & subsystem profiler.

Frame_Telemetry :: struct {
	mu:                    sync.Mutex,
	frames_presented:      u64,
	shaders_translated:    u64,
	pso_cache_hits:        u64,
	pso_cache_misses:      u64,
	shadow_writeback_bytes: u64,
	dirty_pages_synced:    u64,
	bvh_builds:            u64,
	bvh_refits:            u64,
	mesh_fallback_draws:   u64,
}

telemetry_reset :: proc(t: ^Frame_Telemetry) {
	if t == nil {
		return
	}
	sync.mutex_lock(&t.mu)
	defer sync.mutex_unlock(&t.mu)
	t.frames_presented = 0
	t.shaders_translated = 0
	t.pso_cache_hits = 0
	t.pso_cache_misses = 0
	t.shadow_writeback_bytes = 0
	t.dirty_pages_synced = 0
	t.bvh_builds = 0
	t.bvh_refits = 0
	t.mesh_fallback_draws = 0
}

telemetry_pso_hit_rate :: proc(t: ^Frame_Telemetry) -> f64 {
	if t == nil {
		return 0.0
	}
	sync.mutex_lock(&t.mu)
	defer sync.mutex_unlock(&t.mu)
	tot := t.pso_cache_hits + t.pso_cache_misses
	if tot == 0 {
		return 0.0
	}
	return (f64(t.pso_cache_hits) * 100.0) / f64(tot)
}

telemetry_format_summary :: proc(t: ^Frame_Telemetry, allocator := context.allocator) -> string {
	if t == nil {
		return ""
	}
	sync.mutex_lock(&t.mu)
	fp := t.frames_presented
	sh := t.shaders_translated
	ph := t.pso_cache_hits
	pm := t.pso_cache_misses
	sw := t.shadow_writeback_bytes
	dp := t.dirty_pages_synced
	bb := t.bvh_builds
	br := t.bvh_refits
	mf := t.mesh_fallback_draws
	sync.mutex_unlock(&t.mu)

	rate := 0.0
	if ph + pm > 0 {
		rate = (f64(ph) * 100.0) / f64(ph + pm)
	}
	return fmt.aprintf(
		"frames=%d shaders=%d pso_hit=%.1f%% (%d/%d) writeback=%dB dirty_pages=%d bvh=%d/%d mesh_fb=%d",
		fp, sh, rate, ph, ph + pm, sw, dp, bb, br, mf,
		allocator = allocator,
	)
}
