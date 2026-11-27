package vasperty_app

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import win32 "core:sys/windows"
import "core:thread"
import "core:time"

import vasperty_core "vasperty:core"
import vasperty_formats "vasperty:formats"
import vasperty_game "vasperty:game"
import vasperty_gpu "vasperty:gpu"
import vasperty_hle "vasperty:hle"
import vasperty_loader "vasperty:loader"
import vasperty_pe "vasperty:pe"
import vasperty_pipeline "vasperty:pipeline"
import vasperty_shader "vasperty:shader"

Host_Runtime :: struct {
	initialized: bool,
	console:     vasperty_hle.Console_Model,
	config:      vasperty_core.Config,
	has_config:  bool,
}

app_init :: proc(console := vasperty_hle.Console_Model.Series_X) -> (rt: Host_Runtime, err: vasperty_core.Policy_Error) {
	rt.console = console
	vasperty_hle.init_hle()
	vasperty_hle.set_console(console)
	vasperty_gpu.register_gpu_hooks()

	cfg, cfg_err := vasperty_core.load_config()
	if cfg_err != .None {
		vasperty_gpu.gpu_fini()
		vasperty_hle.fini_hle()
		return {}, cfg_err
	}
	rt.config = cfg
	rt.has_config = true
	rt.initialized = true

	shader_cache_dir, jerr := filepath.join({cfg.cache_dir, "shaders"}, context.temp_allocator)
	if jerr == nil {
		vasperty_gpu.use_shader_cache(shader_cache_dir)
	}
	return rt, .None
}

app_fini :: proc(rt: ^Host_Runtime) {
	if rt == nil || !rt.initialized {
		return
	}
	vasperty_gpu.gpu_fini()
	vasperty_hle.fini_hle()
	if rt.has_config {
		vasperty_core.destroy_config(&rt.config)
		rt.has_config = false
	}
	rt.initialized = false
}

app_status :: proc() -> int {
	cores := os.get_processor_core_count()
	fmt.printf("vasperty: runtime online (cores=%d)\n", cores)
	fmt.println("  modules : core, pe, game, formats, pipeline, loader, hle, shader, gpu, app, cli")
	fmt.println("  targets : NVIDIA (Wave32 async) + Intel Integrated (Wave16 UMA)")
	return 0
}

app_config :: proc() -> int {
	cfg, cfg_err := vasperty_core.load_config()
	if cfg_err != .None {
		fmt.eprintf("config: error loading config: %v\n", cfg_err)
		return 1
	}
	defer vasperty_core.destroy_config(&cfg)

	fmt.printf("config file : %s\n", cfg.source if cfg.has_source else "(none)")
	fmt.printf("game_dir    : %s\n", cfg.game_dir if cfg.has_game_dir else "(not set)")
	fmt.printf("cache_dir   : %s\n", cfg.cache_dir)
	fmt.printf("data_dir    : %s\n", cfg.data_dir)
	fmt.printf("fidelityfx  : %s\n", cfg.fidelityfx_dir if cfg.has_fidelityfx_dir else "(not set)")
	for t in cfg.test_titles {
		fmt.printf("test_title  : %s\n", t)
	}
	policy_ok := vasperty_core.ensure_outside_repo(cfg.cache_dir) == .None &&
		vasperty_core.ensure_outside_repo(cfg.data_dir) == .None &&
		(!cfg.has_game_dir || vasperty_core.ensure_outside_repo(cfg.game_dir) == .None)
	fmt.printf("asset policy: %s\n", "PASS (outside repository)" if policy_ok else "POLICY VIOLATION")
	return 0 if policy_ok else 1
}

app_doctor :: proc(prune_cache := false, as_json := false) -> int {
	cfg, cfg_err := vasperty_core.load_config()
	if cfg_err != .None {
		fmt.eprintf("doctor: config/policy error: %v\n", cfg_err)
		return 1
	}
	defer vasperty_core.destroy_config(&cfg)

	cores := os.get_processor_core_count()
	caps := vasperty_gpu.probe_capabilities(true)
	defer vasperty_gpu.destroy_host_capabilities(&caps)
	tune := vasperty_gpu.classify_vendor(&caps)

	cache_entries := 0
	cache_bytes := u64(0)
	stale_temps := 0
	stale_bytes := u64(0)
	if cache, c_err := vasperty_pipeline.cache_open(cfg.cache_dir); c_err == .None {
		defer vasperty_pipeline.cache_destroy(&cache)
		if prune_cache {
			if rem, freed, pr_err := vasperty_pipeline.cache_prune_stale_temps(&cache); pr_err == .None && rem > 0 && !as_json {
				fmt.printf("Cache pruned    : %d stale temp files (%d bytes)\n", rem, freed)
			}
		}
		if stats, s_err := vasperty_pipeline.cache_stats(&cache); s_err == .None {
			cache_entries = stats.entries
			cache_bytes = stats.total_bytes
			stale_temps = stats.stale_temps
			stale_bytes = stats.stale_temp_bytes
		}
	} else {
		fmt.eprintf("doctor: cache open error: %v\n", c_err)
		return 1
	}

	bcpack_ok := false
	if tbl, b_err := vasperty_formats.bcpack_builtin_tables(); b_err == .None {
		vasperty_formats.bcpack_destroy_tables(tbl)
		bcpack_ok = true
	} else {
		fmt.eprintf("doctor: bcpack tables error: %v\n", b_err)
		return 1
	}

	if as_json {
		fmt.printf(
			"{{\"cpu_cores\":%d,\"adapter\":\"%s\",\"vendor_id\":\"0x%04X\",\"device_id\":\"0x%04X\",\"shader_model\":\"%s\",\"profile\":\"%v\",\"uma\":%v,\"cache_coherent_uma\":%v,\"wave_size\":%d,\"mesh_shaders\":%v,\"mesh_fallback\":%v,\"depth_bounds\":%v,\"typed_uav_additional\":%v,\"raytracing_tier\":%d,\"tearing\":%v,\"in_flight\":%d,\"pool_budget_mib\":%d,\"cache_entries\":%d,\"bcpack_ok\":%v}}\n",
			cores, caps.adapter_name, caps.vendor_id, caps.device_id, caps.highest_shader_model,
			tune.tier, tune.is_uma, tune.cache_coherent_uma, tune.target_wave_size,
			caps.mesh_shaders, tune.emulate_mesh_shaders, caps.depth_bounds, caps.typed_uav_additional,
			caps.raytracing_tier, caps.allow_tearing, tune.max_frames_in_flight,
			tune.buffer_pool_budget_bytes >> 20, cache_entries, bcpack_ok,
		)
		return 0
	}

	fmt.println("=== Vasperty Doctor ===")
	fmt.printf("CPU cores       : %d\n", cores)
	fmt.printf("Config source   : %s\n", cfg.source if cfg.has_source else "<defaults/env>")
	fmt.printf("Game dir        : %s\n", cfg.game_dir if cfg.has_game_dir else "<unset>")
	fmt.printf("Cache dir       : %s (policy OK)\n", cfg.cache_dir)
	fmt.printf("Data dir        : %s (policy OK)\n", cfg.data_dir)
	fmt.printf("FidelityFX dir  : %s\n", cfg.fidelityfx_dir if cfg.has_fidelityfx_dir else "<unset>")
	fmt.printf(
		"D3D12 Adapter   : %s (vendor=0x%04X device=0x%04X %s mesh=%v wave=%v %d..%d)\n",
		caps.adapter_name,
		caps.vendor_id,
		caps.device_id,
		caps.highest_shader_model,
		caps.mesh_shaders,
		caps.wave_ops,
		caps.wave_lane_count_min,
		caps.wave_lane_count_max,
	)
	fmt.printf("Display         : %d modes, max %d Hz, tearing=%v\n",
		caps.display_mode_count, caps.max_refresh_hz, caps.allow_tearing)
	fmt.printf("GPU profile     : %s [%v]\n", tune.profile_name, tune.tier)
	fmt.printf("  uma=%v coherent=%v wave=%d emulate_wave64=%v mesh_fallback=%v in_flight=%d pool=%d MiB async=%v dxr=%v depth_bounds=%v typed_uav=%v\n",
		tune.is_uma, tune.cache_coherent_uma, tune.target_wave_size, tune.emulate_wave64, tune.emulate_mesh_shaders,
		tune.max_frames_in_flight, tune.buffer_pool_budget_bytes >> 20, tune.prefer_async_compute, tune.enable_dxr_bvh,
		caps.depth_bounds, caps.typed_uav_additional)
	fmt.printf(
		"Pipeline cache  : %d entries (%d bytes), %d stale temps (%d bytes)\n",
		cache_entries, cache_bytes, stale_temps, stale_bytes,
	)
	fmt.println("BCPack tables   : loaded cleanly (128 rANS models, 6 dictionaries)")
	return 0
}

app_inspect :: proc(path: string, show_imports := false, show_exports := false) -> int {
	raw, r_err := os.read_entire_file_from_path(path, context.allocator)
	if r_err != nil {
		fmt.eprintf("inspect: cannot read '%s': %v\n", path, r_err)
		return 1
	}
	defer delete(raw)

	info, pe_err := vasperty_pe.parse_image(raw)
	if pe_err != .None {
		fmt.eprintf("inspect: invalid PE32+ image '%s': %v\n", path, pe_err)
		return 1
	}
	defer vasperty_pe.destroy_image(&info)

	fmt.printf("Image           : %s\n", path)
	fmt.printf("Machine         : 0x%04X\n", info.machine)
	fmt.printf("Subsystem       : %s (%d)\n", vasperty_pe.subsystem_name(info.subsystem), info.subsystem)
	dll_flags := vasperty_pe.dll_characteristics_names(info.dll_characteristics)
	defer delete(dll_flags)
	fmt.printf("DllChars        : 0x%04X (%s)\n", info.dll_characteristics, dll_flags)
	fmt.printf("ImageBase       : 0x%X\n", info.image_base)
	fmt.printf("SizeOfImage     : %d bytes\n", info.size_of_image)
	fmt.printf("EntryRVA        : 0x%X\n", info.entry_rva)
	fmt.printf("Sections        : %d\n", len(info.sections))
	fmt.printf("Imports         : %d modules, %d symbols\n", len(info.imports), vasperty_pe.import_count(&info))
	fmt.printf("TLS callbacks   : %d\n", len(info.tls.callback_rvas) if info.has_tls else 0)
	fmt.printf("Reloc/Exc/LCfg  : %v / %v / %v\n", info.has_relocations, info.has_exception_table, info.has_load_config)

	if prep, p_err := vasperty_loader.prepare_image(raw); p_err == .None {
		defer vasperty_loader.destroy_prepared_image(&prep)
		fname := vasperty_loader.prepared_file_name(&prep)
		defer delete(fname)
		fmt.printf("Prepared DLL    : %s (%d bytes)\n", fname, len(prep.bytes))
	}
	if show_imports {
		for &imp in info.imports {
			fmt.printf("  import %s (%d symbols)\n", imp.dll, len(imp.entries))
			for &sym in imp.entries {
				if sym.by_ordinal {
					fmt.printf("    #%d\n", sym.ordinal)
				} else {
					fmt.printf("    %s\n", sym.name)
				}
			}
		}
	}
	if show_exports && len(info.exports) > 0 {
		fmt.printf("Exports         : %d symbols\n", len(info.exports))
		for &exp in info.exports {
			fmt.printf("  %s (ord=%d rva=0x%X)\n", exp.name, exp.ordinal, exp.rva)
		}
	}
	return 0
}

Census_Result :: struct {
	images:  int,
	hle:     int,
	host:    int,
	missing: int,
}

app_census_file :: proc(res: ^vasperty_hle.Hle_Resolver, path: string, missing_map: ^map[string]int) -> (r: Census_Result, ok: bool) {
	raw, r_err := os.read_entire_file_from_path(path, context.allocator)
	if r_err != nil {
		return {}, false
	}
	defer delete(raw)
	info, pe_err := vasperty_pe.parse_image(raw)
	if pe_err != .None {
		return {}, false
	}
	defer vasperty_pe.destroy_image(&info)

	r.images = 1
	for &mod in info.imports {
		for &sym in mod.entries {
			got := vasperty_hle.hle_resolve(res, mod.dll, &sym)
			if !got.found {
				r.missing += 1
				if missing_map != nil {
					sname := fmt.tprintf("%s!#%d", mod.dll, sym.ordinal) if sym.by_ordinal else fmt.tprintf("%s!%s", mod.dll, sym.name)
					if prev, has_k := missing_map[sname]; has_k {
						missing_map[sname] = prev + 1
					} else {
						missing_map[strings.clone(sname)] = 1
					}
				}
			} else if got.provenance == .Hle {
				r.hle += 1
			} else {
				r.host += 1
			}
		}
	}
	return r, true
}

app_census :: proc(paths: []string, strict := false, show_missing := false) -> int {
	vasperty_hle.init_hle()
	defer vasperty_hle.fini_hle()
	policy := vasperty_hle.none_host_policy() if strict else vasperty_hle.default_host_policy()
	res := vasperty_hle.make_hle_resolver(policy)
	defer vasperty_hle.destroy_hle_resolver(&res)

	missing_map := make(map[string]int)
	defer {
		for k, _ in missing_map { delete(k) }
		delete(missing_map)
	}

	total: Census_Result
	unreadable := 0
	for p in paths {
		if os.is_file(p) {
			if r, ok := app_census_file(&res, p, &missing_map); ok {
				total.images += r.images
				total.hle += r.hle
				total.host += r.host
				total.missing += r.missing
			} else {
				unreadable += 1
				fmt.eprintf("census: warning: unreadable or non-PE file '%s'\n", p)
			}
		} else {
			unreadable += 1
			fmt.eprintf("census: warning: path not found '%s'\n", p)
		}
	}
	fmt.printf("census: %d images -> %d hle, %d host, %d missing", total.images, total.hle, total.host, total.missing)
	if unreadable > 0 {
		fmt.printf(" (%d unreadable/skipped)", unreadable)
	}
	fmt.println("")
	if show_missing && len(missing_map) > 0 {
		for k, cnt in missing_map {
			fmt.printf("  missing (%dx): %s\n", cnt, k)
		}
	}
	return 0
}

Translate_Tally :: struct {
	xdat:            int,
	accc:            int,
	dxil:            int,
	sgd5_records:    int,
	containers:      int,
	translated:      int,
	validated:       int,
	failed:          int,
	stage_vs:        int,
	stage_ps:        int,
	stage_cs:        int,
	stage_ms:        int,
	stage_gs:        int,
	stage_other:     int,
	err_unpack:      int,
	err_not_dxbc:    int,
	err_malformed:   int,
	err_isa:         int,
	err_unsupported: int,
	fail_stages:     [8]int,
}

@(private)
tally_record_stage :: proc(t: ^Translate_Tally, st: vasperty_shader.Hw_Stage) {
	#partial switch st {
	case .Vs: t.stage_vs += 1
	case .Ps: t.stage_ps += 1
	case .Cs: t.stage_cs += 1
	case .Ms: t.stage_ms += 1
	case .Gs, .Es, .Hs, .Ls: t.stage_gs += 1
	case:     t.stage_other += 1
	}
}

@(private)
tally_record_err :: proc(t: ^Translate_Tally, err: vasperty_shader.Shader_Error) {
	#partial switch err {
	case .Not_Dxbc:    t.err_not_dxbc += 1
	case .Malformed:   t.err_malformed += 1
	case .Isa_Error:   t.err_isa += 1
	case .Unsupported: t.err_unsupported += 1
	}
}

@(private)
tally_merge :: proc(dst: ^Translate_Tally, src: ^Translate_Tally) {
	dst.xdat += src.xdat
	dst.accc += src.accc
	dst.dxil += src.dxil
	dst.sgd5_records += src.sgd5_records
	dst.containers += src.containers
	dst.translated += src.translated
	dst.validated += src.validated
	dst.failed += src.failed
	dst.stage_vs += src.stage_vs
	dst.stage_ps += src.stage_ps
	dst.stage_cs += src.stage_cs
	dst.stage_ms += src.stage_ms
	dst.stage_gs += src.stage_gs
	dst.stage_other += src.stage_other
	dst.err_unpack += src.err_unpack
	dst.err_not_dxbc += src.err_not_dxbc
	dst.err_malformed += src.err_malformed
	dst.err_isa += src.err_isa
	dst.err_unsupported += src.err_unsupported
	for i in 0 ..< 8 { dst.fail_stages[i] += src.fail_stages[i] }
}

@(private)
Sgd5_Stream_State :: struct {
	recs:      []vasperty_game.Sgd5_Record,
	validate:  bool,
	wave_mode: vasperty_shader.Target_Wave_Mode,
	next_idx:  int,
	mu:        sync.Mutex,
	tally:     Translate_Tally,
}

@(private)
sgd5_stream_worker_proc :: proc(t: ^thread.Thread) {
	st := cast(^Sgd5_Stream_State)t.data
	local: Translate_Tally

	// Per-worker Dynamic_Arena eliminates 12-core Windows heap lock contention
	// and gives O(1) bulk reset after each shader with zero memory leaks.
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	arena_alloc := mem.dynamic_arena_allocator(&arena)

	for {
		idx := sync.atomic_add(&st.next_idx, 1)
		if idx >= len(st.recs) {
			break
		}
		mem.dynamic_arena_reset(&arena)
		context.allocator = arena_alloc

		rec := st.recs[idx]
		local.sgd5_records += 1
		unpacked, ok := vasperty_game.sgd5_record_unpack(&rec, arena_alloc)
		if !ok || len(unpacked) == 0 {
			local.failed += 1
			local.err_unpack += 1
			continue
		}
		local.containers += 1
		hs, terr, fstage := vasperty_shader.translate_with_diag(
			unpacked,
			vasperty_shader.Shader_Options{wave_mode = st.wave_mode},
		)
		if terr != .None {
			local.failed += 1
			tally_record_err(&local, terr)
			local.fail_stages[int(fstage)] += 1
			continue
		}
		local.translated += 1
		tally_record_stage(&local, hs.stage)
		if st.validate {
			vok, vmsg, _ := vasperty_shader.validate_dxil(hs.dxil[:])
			if vmsg != "" { delete(vmsg) }
			if vok { local.validated += 1 }
		}
		free_all(context.temp_allocator)
	}
	sync.mutex_lock(&st.mu)
	tally_merge(&st.tally, &local)
	sync.mutex_unlock(&st.mu)
}

@(private)
app_translate_sgd5_stream :: proc(data: []u8, validate: bool, tally: ^Translate_Tally, wave_mode: vasperty_shader.Target_Wave_Mode, jobs: int, limit: int) {
	recs := vasperty_game.sgd5_records(data)
	defer delete(recs)
	if len(recs) == 0 {
		return
	}
	slice_len := len(recs)
	if limit > 0 && limit < slice_len {
		slice_len = limit
	}
	work := recs[:slice_len]
	n_workers := min(max(jobs, 1), len(work))
	st := Sgd5_Stream_State{
		recs      = work,
		validate  = validate,
		wave_mode = wave_mode,
	}
	if n_workers <= 1 {
		for i := 0; i < len(work); i += 1 {
			rec := work[i]
			st.tally.sgd5_records += 1
			unpacked, ok := vasperty_game.sgd5_record_unpack(&rec, context.allocator)
			if !ok || len(unpacked) == 0 {
				if len(unpacked) > 0 { delete(unpacked) }
				st.tally.failed += 1
				st.tally.err_unpack += 1
				continue
			}
			st.tally.containers += 1
			hs, terr := vasperty_shader.translate_with(unpacked, vasperty_shader.Shader_Options{wave_mode = wave_mode})
			delete(unpacked)
			if terr != .None {
				st.tally.failed += 1
				tally_record_err(&st.tally, terr)
				continue
			}
			st.tally.translated += 1
			tally_record_stage(&st.tally, hs.stage)
			if validate {
				vok, vmsg, _ := vasperty_shader.validate_dxil(hs.dxil[:])
				if vmsg != "" { delete(vmsg) }
				if vok { st.tally.validated += 1 }
			}
			vasperty_shader.destroy_host_shader(&hs)
		}
		tally_merge(tally, &st.tally)
		return
	}
	threads := make([dynamic]^thread.Thread, 0, n_workers)
	defer delete(threads)
	for _ in 0 ..< n_workers {
		th := thread.create(sgd5_stream_worker_proc)
		if th != nil {
			th.data = &st
			thread.start(th)
			append(&threads, th)
		}
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	tally_merge(tally, &st.tally)
}

@(private)
Translate_Job_State :: struct {
	blob:      []u8,
	entries:   []vasperty_shader.Embedded_Dxbc,
	validate:  bool,
	wave_mode: vasperty_shader.Target_Wave_Mode,
	next_idx:  int,
	mu:        sync.Mutex,
	tally:     Translate_Tally,
}

@(private)
translate_worker_proc :: proc(t: ^thread.Thread) {
	st := cast(^Translate_Job_State)t.data
	local: Translate_Tally

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	arena_alloc := mem.dynamic_arena_allocator(&arena)

	for {
		idx := sync.atomic_add(&st.next_idx, 1)
		if idx >= len(st.entries) {
			break
		}
		mem.dynamic_arena_reset(&arena)
		context.allocator = arena_alloc

		e := st.entries[idx]
		if e.has_xdat { local.xdat += 1 }
		if e.has_accc { local.accc += 1 }
		if e.has_dxil { local.dxil += 1 }
		local.containers += 1
		hs, terr := vasperty_shader.translate_with(
			st.blob[e.offset:e.offset + e.size],
			vasperty_shader.Shader_Options{wave_mode = st.wave_mode},
		)
		if terr != .None {
			local.failed += 1
			tally_record_err(&local, terr)
			continue
		}
		local.translated += 1
		tally_record_stage(&local, hs.stage)
		if st.validate {
			vok, vmsg, _ := vasperty_shader.validate_dxil(hs.dxil[:])
			if vmsg != "" { delete(vmsg) }
			if vok { local.validated += 1 }
		}
		free_all(context.temp_allocator)
	}
	sync.mutex_lock(&st.mu)
	tally_merge(&st.tally, &local)
	sync.mutex_unlock(&st.mu)
}

app_translate_blob :: proc(blob: []u8, validate: bool, tally: ^Translate_Tally, wave_mode := vasperty_shader.Target_Wave_Mode.Auto, jobs := 1) {
	if len(blob) >= 4 && blob[0] == 'D' && blob[1] == 'X' && blob[2] == 'B' && blob[3] == 'C' {
		tally.containers += 1
		hs, terr := vasperty_shader.translate_with(blob, vasperty_shader.Shader_Options{wave_mode = wave_mode})
		if terr != .None {
			tally.failed += 1
			return
		}
		tally.translated += 1
		if validate {
			vok, vmsg, _ := vasperty_shader.validate_dxil(hs.dxil[:])
			if vmsg != "" { delete(vmsg) }
			if vok { tally.validated += 1 }
		}
		vasperty_shader.destroy_host_shader(&hs)
		return
	}
	if len(blob) >= 4 && blob[0] == 'P' && blob[1] == 'S' && blob[2] == 0 && blob[3] == 9 {
		pack, perr := vasperty_game.parse_pack(blob)
		if perr == .None {
			ng := vasperty_game.pack_graphics_count(&pack)
			nc := vasperty_game.pack_compute_count(&pack)
			tally.containers += ng + nc
		}
		return
	}
	if vasperty_game.is_sgd5(blob) {
		recs := vasperty_game.sgd5_records(blob)
		defer delete(recs)
		unpacked := vasperty_game.sgd5_unpack_all(recs[:])
		defer vasperty_game.sgd5_destroy_unpack_results(unpacked)
		for &ur in unpacked {
			if ur.ok && len(ur.data) > 0 {
				app_translate_blob(ur.data, validate, tally, wave_mode, jobs)
			}
		}
		return
	}
	emb := vasperty_shader.scan_embedded_dxbc(blob)
	defer delete(emb)
	if len(emb) == 0 {
		return
	}
	n_workers := min(max(jobs, 1), len(emb))
	if n_workers <= 1 {
		for e in emb {
			if e.has_xdat { tally.xdat += 1 }
			if e.has_accc { tally.accc += 1 }
			if e.has_dxil { tally.dxil += 1 }
			app_translate_blob(blob[e.offset:e.offset + e.size], validate, tally, wave_mode, 1)
		}
		return
	}
	st := Translate_Job_State{
		blob      = blob,
		entries   = emb[:],
		validate  = validate,
		wave_mode = wave_mode,
	}
	threads := make([dynamic]^thread.Thread, 0, n_workers)
	defer delete(threads)
	for _ in 0 ..< n_workers {
		t := thread.create(translate_worker_proc)
		if t != nil {
			t.data = &st
			thread.start(t)
			append(&threads, t)
		}
	}
	for t in threads {
		thread.join(t)
		thread.destroy(t)
	}
	tally_merge(tally, &st.tally)
}

app_translate :: proc(
	paths: []string,
	validate := false,
	wave_mode := vasperty_shader.Target_Wave_Mode.Auto,
	jobs := 0,
	limit := 0,
) -> (Translate_Tally, int) {
	workers := jobs
	if workers <= 0 {
		workers = min(max(os.get_processor_core_count(), 1), 8)
	}
	t0 := time.tick_now()
	tally: Translate_Tally
	for p in paths {
		if mf, mok := vasperty_game.map_file_readonly(p); mok {
			defer vasperty_game.unmap_file_readonly(&mf)
			if vasperty_game.is_rpf9(mf.data) || vasperty_game.is_sgd5(mf.data) {
				app_translate_sgd5_stream(mf.data, validate, &tally, wave_mode, workers, limit)
			} else {
				app_translate_blob(mf.data, validate, &tally, wave_mode, workers)
			}
		} else {
			fmt.eprintf("translate: cannot map '%s'\n", p)
		}
	}
	el_ms := time.duration_milliseconds(time.tick_since(t0))
	rate := f64(tally.translated) / max(el_ms / 1000.0, 0.0001)
	fmt.printf(
		"translate: wave=%v workers=%d sgd5=%d embedded(xdat=%d accc=%d dxil=%d) time=%.1fms (%.0f shaders/s)\n",
		wave_mode, workers, tally.sgd5_records, tally.xdat, tally.accc, tally.dxil, el_ms, rate,
	)
	fmt.printf(
		"translate: %d containers -> %d translated (VS=%d PS=%d CS=%d MS=%d GS=%d), %d validated, %d failed\n",
		tally.containers, tally.translated, tally.stage_vs, tally.stage_ps, tally.stage_cs, tally.stage_ms, tally.stage_gs,
		tally.validated, tally.failed,
	)
	if tally.failed > 0 {
		fmt.printf(
			"  failures: unpack=%d not_dxbc=%d malformed=%d isa=%d unsupported=%d\n",
			tally.err_unpack, tally.err_not_dxbc, tally.err_malformed, tally.err_isa, tally.err_unsupported,
		)
		fmt.printf(
			"  stages  : dxbc=%d native=%d no_stage=%d range_build=%d track_res=%d raise_io=%d emit_lower=%d\n",
			tally.fail_stages[int(vasperty_shader.Translate_Fail_Stage.Parse_Dxbc)],
			tally.fail_stages[int(vasperty_shader.Translate_Fail_Stage.Parse_Native)],
			tally.fail_stages[int(vasperty_shader.Translate_Fail_Stage.No_Target_Stage)],
			tally.fail_stages[int(vasperty_shader.Translate_Fail_Stage.Range_Build)],
			tally.fail_stages[int(vasperty_shader.Translate_Fail_Stage.Track_Resources)],
			tally.fail_stages[int(vasperty_shader.Translate_Fail_Stage.Raise_Io)],
			tally.fail_stages[int(vasperty_shader.Translate_Fail_Stage.Emit_Lower)],
		)
	}
	return tally, 0
}

app_probe :: proc(paths: []string, scan := false) -> int {
	ok_count := 0
	for p in paths {
		pr, ok := vasperty_game.probe_archive_file(p)
		if !ok {
			fmt.eprintf("probe: cannot open '%s'\n", p)
			continue
		}
		ok_count += 1
		mib := f64(pr.file_size) / (1024.0 * 1024.0)
		fmt.printf("probe: %-11v %9.2f MiB  magic=%c%c%c%c  ver=0x%X  entries=%d  %s\n",
			pr.kind, mib,
			pr.magic[0] if pr.magic[0] >= 32 && pr.magic[0] <= 126 else '.',
			pr.magic[1] if pr.magic[1] >= 32 && pr.magic[1] <= 126 else '.',
			pr.magic[2] if pr.magic[2] >= 32 && pr.magic[2] <= 126 else '.',
			pr.magic[3] if pr.magic[3] >= 32 && pr.magic[3] <= 126 else '.',
			pr.version, pr.entry_hint, p)
		if scan && pr.kind == .Rpf9 {
			if sum, sok := vasperty_game.rpf9_scan_embedded(p, 64 << 20); sok {
				fmt.printf("  scan (%.1f MiB): sgd5=%d (first=0x%X) dxbc=%d (first=0x%X)\n",
					f64(sum.bytes_scanned) / (1024.0 * 1024.0),
					sum.sgd5_hits, sum.first_sgd5, sum.dxbc_hits, sum.first_dxbc)
			}
		}
	}
	return 0 if ok_count > 0 else 1
}

foreign import kernel32_veh "system:kernel32.lib"
@(default_calling_convention = "system")
foreign kernel32_veh {
	GetModuleHandleExW :: proc(dwFlags: win32.DWORD, lpModuleName: win32.LPCWSTR, phModule: ^win32.HMODULE) -> win32.BOOL ---
}

@(private)
VEH_EXCEPTION_RECORD :: struct {
	ExceptionCode:        u32,
	ExceptionFlags:       u32,
	ExceptionRecord:      rawptr,
	ExceptionAddress:     uintptr,
	NumberParameters:     u32,
	_pad:                 u32,
	ExceptionInformation: [15]uintptr,
}

@(private)
VEH_CONTEXT_X64 :: struct {
	_pad0:  [120]u8,
	Rax:    u64, // 0x78
	Rcx:    u64, // 0x80
	Rdx:    u64, // 0x88
	Rbx:    u64, // 0x90
	Rsp:    u64, // 0x98
	Rbp:    u64, // 0xA0
	Rsi:    u64, // 0xA8
	Rdi:    u64, // 0xB0
	R8:     u64, // 0xB8
	R9:     u64, // 0xC0
	R10:    u64, // 0xC8
	R11:    u64, // 0xD0
	R12:    u64, // 0xD8
	R13:    u64, // 0xE0
	R14:    u64, // 0xE8
	R15:    u64, // 0xF0
	Rip:    u64, // 0xF8
	_pad1:  [0xA0]u8,
	Xmm:    [16][2]u64, // 0x1A0
}

#assert(offset_of(VEH_CONTEXT_X64, Rip) == 0xF8)
#assert(offset_of(VEH_CONTEXT_X64, Xmm) == 0x1A0)

@(private)
VEH_EXCEPTION_POINTERS :: struct {
	ExceptionRecord: ^VEH_EXCEPTION_RECORD,
	ContextRecord:   ^VEH_CONTEXT_X64,
}

@(private)
g_boot_self_base: uintptr
@(private)
g_boot_main_base: uintptr
@(private)
g_boot_main_size: uintptr
@(private)
g_boot_stage: string
@(private)
g_veh_commit_lock: i32

@(private)
boot_veh_handler :: proc "system" (info: ^VEH_EXCEPTION_POINTERS) -> i32 {
	if info == nil || info.ExceptionRecord == nil {
		return 0
	}
	code := info.ExceptionRecord.ExceptionCode
	// Demand-commit uncommitted MEM_RESERVE title memory pages (>= 4 GiB) on access fault.
	if code == 0xC0000005 && info.ContextRecord != nil {
		// Recover from NULL callback/vtable calls from title code by returning 0 to caller.
		if info.ExceptionRecord.ExceptionInformation[0] == 8 && info.ContextRecord.Rip == 0 && info.ContextRecord.Rsp >= 0x10000 {
			ret_addr := (cast(^u64)uintptr(info.ContextRecord.Rsp))^
			if g_boot_main_base != 0 && uintptr(ret_addr) >= g_boot_main_base && uintptr(ret_addr) < g_boot_main_base + g_boot_main_size {
				info.ContextRecord.Rsp += 8
				info.ContextRecord.Rip = ret_addr
				info.ContextRecord.Rax = 0
				return -1 // EXCEPTION_CONTINUE_EXECUTION
			}
		}
		fault_va := info.ExceptionRecord.ExceptionInformation[1]
		if fault_va >= 0x1_0000_0000 {
			for sync.atomic_exchange(&g_veh_commit_lock, 1) != 0 {
				win32.SwitchToThread()
			}
			defer sync.atomic_store(&g_veh_commit_lock, 0)
			mbi: win32.MEMORY_BASIC_INFORMATION
			if win32.VirtualQuery(rawptr(fault_va), &mbi, size_of(mbi)) != 0 &&
			   mbi.Type == 0x20000 && uintptr(mbi.AllocationBase) >= 0x1_0000_0000 {
				if mbi.State == win32.MEM_RESERVE {
					page_base := fault_va & ~uintptr(0xFFFF)
					if win32.VirtualAlloc(rawptr(page_base), 0x10000, win32.MEM_COMMIT, win32.PAGE_READWRITE) != nil {
						return -1 // EXCEPTION_CONTINUE_EXECUTION
					}
					// Placeholder fallback: split and replace 64 KiB placeholder with committed RW memory.
					_ = win32.VirtualFree(rawptr(page_base), 0x10000, win32.MEM_RELEASE | 0x2)
					if vasperty_hle.XMemVirtualAlloc(rawptr(page_base), 0x10000, win32.MEM_COMMIT, 0, win32.PAGE_READWRITE) != nil {
						return -1 // EXCEPTION_CONTINUE_EXECUTION
					}
					if win32.VirtualQuery(rawptr(fault_va), &mbi, size_of(mbi)) != 0 &&
					   mbi.State == win32.MEM_COMMIT && (mbi.Protect == win32.PAGE_READWRITE || mbi.Protect == win32.PAGE_EXECUTE_READWRITE) {
						return -1 // EXCEPTION_CONTINUE_EXECUTION
					}
				} else if mbi.State == win32.MEM_COMMIT && (mbi.Protect == win32.PAGE_READWRITE || mbi.Protect == win32.PAGE_EXECUTE_READWRITE) {
					// Another thread committed this MEM_RESERVE page concurrently while this thread entered VEH.
					return -1 // EXCEPTION_CONTINUE_EXECUTION
				}
			}
		}
	}
	// Continue past soft __debugbreak() (0xCC) assertions in console builds.
	if code == 0x80000003 && info.ContextRecord != nil {
		ctx := info.ContextRecord
		ip := cast([^]u8)uintptr(ctx.Rip)
		if ip != nil && ip[0] == 0xCC {
			ctx.Rip += 1
			return -1 // EXCEPTION_CONTINUE_EXECUTION
		}
	}
	// Emulate AMD Zen 2 `clzero` (0F 01 FC), `monitorx` (0F 01 FA), `mwaitx` (0F 01 FB) on Intel CPUs.
	if code == 0xC000001D && info.ContextRecord != nil {
		ctx := info.ContextRecord
		ip := cast([^]u8)uintptr(ctx.Rip)
		if ip != nil && ip[0] == 0x0F && ip[1] == 0x01 {
			if ip[2] == 0xFA { // monitorx
				ctx.Rip += 3
				return -1 // EXCEPTION_CONTINUE_EXECUTION
			}
			if ip[2] == 0xFB { // mwaitx
				win32.SwitchToThread()
				ctx.Rip += 3
				return -1 // EXCEPTION_CONTINUE_EXECUTION
			}
			if ip[2] == 0xFC { // clzero
				line := uintptr(ctx.Rax & ~u64(63))
				if line != 0 {
					// Fast-path: `clzero; add rax, 0x40; cmp rax, r10; jb -12`
					if ip[3] == 0x48 && ip[4] == 0x83 && ip[5] == 0xC0 && ip[6] == 0x40 &&
					   ip[7] == 0x4C && ip[8] == 0x39 && ip[9] == 0xD0 && ip[10] == 0x72 && ip[11] == 0xF4 &&
					   ctx.R10 > ctx.Rax {
						end_line := uintptr((ctx.R10 + 63) & ~u64(63))
						span := end_line - line
						if span > 0 && span <= (256 << 20) {
							mem.zero(rawptr(line), int(span))
							ctx.Rax = u64(end_line)
							ctx.Rip += 12
							return -1 // EXCEPTION_CONTINUE_EXECUTION
						}
					}
					mem.zero(rawptr(line), 64)
				}
				ctx.Rip += 3
				return -1 // EXCEPTION_CONTINUE_EXECUTION
			}
		}
		// Emulate AMD SSE4a `insertq` (F2 [REX] 0F 78/79) and `extrq` (66 [REX] 0F 78/79).
		if ip != nil && (ip[0] == 0xF2 || ip[0] == 0x66) {
			pfx := ip[0]
			off := u64(1)
			rex := u8(0)
			if (ip[off] & 0xF0) == 0x40 {
				rex = ip[off]
				off += 1
			}
			if ip[off] == 0x0F && (ip[off + 1] == 0x78 || ip[off + 1] == 0x79) {
				op := ip[off + 1]
				modrm := ip[off + 2]
				reg := ((modrm >> 3) & 7) | ((rex & 4) << 1)
				rm := (modrm & 7) | ((rex & 1) << 3)
				if pfx == 0xF2 { // insertq
					length: u32
					index: u32
					inst_len: u64
					if op == 0x78 {
						length = u32(ip[off + 3] & 0x3F)
						index = u32(ip[off + 4] & 0x3F)
						inst_len = off + 5
					} else {
						length = u32(ctx.Xmm[rm][1] & 0x3F)
						index = u32((ctx.Xmm[rm][1] >> 8) & 0x3F)
						inst_len = off + 3
					}
					mask := ~u64(0) if (length == 0 || length >= 64) else ((u64(1) << length) - 1)
					if index < 64 {
						ctx.Xmm[reg][0] = (ctx.Xmm[reg][0] & ~(mask << index)) | ((ctx.Xmm[rm][0] & mask) << index)
					}
					ctx.Rip += inst_len
					return -1 // EXCEPTION_CONTINUE_EXECUTION
				} else { // 0x66 extrq
					dst: u8
					length: u32
					index: u32
					inst_len: u64
					if op == 0x78 {
						dst = rm
						length = u32(ip[off + 3] & 0x3F)
						index = u32(ip[off + 4] & 0x3F)
						inst_len = off + 5
					} else {
						dst = reg
						length = u32(ctx.Xmm[rm][0] & 0x3F)
						index = u32((ctx.Xmm[rm][0] >> 8) & 0x3F)
						inst_len = off + 3
					}
					mask := ~u64(0) if (length == 0 || length >= 64) else ((u64(1) << length) - 1)
					ctx.Xmm[dst][0] = ((ctx.Xmm[dst][0] >> index) & mask) if index < 64 else 0
					ctx.Rip += inst_len
					return -1 // EXCEPTION_CONTINUE_EXECUTION
				}
			}
		}
	}
	if code != 0xC0000005 && code != 0xC000001D && code != 0xC0000096 && code != 0xC00000FD && code != 0x80000003 {
		return 0
	}
	context = runtime.default_context()
	addr := info.ExceptionRecord.ExceptionAddress
	op := info.ExceptionRecord.ExceptionInformation[0]
	fault_va := info.ExceptionRecord.ExceptionInformation[1]
	op_str := "READ"
	if op == 1 { op_str = "WRITE" } else if op == 8 { op_str = "EXEC" }

	if g_boot_main_base != 0 && addr >= g_boot_main_base && addr < g_boot_main_base + g_boot_main_size {
		fmt.eprintf("[crash] stage=%s code=0x%08X rip=0x%X (main+0x%X) %s va=0x%X\n",
			g_boot_stage, code, addr, addr - g_boot_main_base, op_str, fault_va)
	} else if g_boot_self_base != 0 && addr >= g_boot_self_base && addr < g_boot_self_base + 0x2000000 {
		fmt.eprintf("[crash] stage=%s code=0x%08X rip=0x%X (vasperty+0x%X) %s va=0x%X\n",
			g_boot_stage, code, addr, addr - g_boot_self_base, op_str, fault_va)
	} else {
		hmod: win32.HMODULE
		mod_name := "unknown"
		mod_off := uintptr(0)
		if GetModuleHandleExW(6, transmute(win32.LPCWSTR)addr, &hmod) && hmod != nil {
			mod_off = addr - uintptr(hmod)
			wbuf: [260]u16
			n := win32.GetModuleFileNameW(hmod, &wbuf[0], 260)
			if n > 0 {
				if s, err := win32.utf16_to_utf8(wbuf[:n], context.temp_allocator); err == nil {
					mod_name = s
				}
			}
		}
		fmt.eprintf("[crash] stage=%s code=0x%08X rip=0x%X (%s+0x%X) %s va=0x%X\n",
			g_boot_stage, code, addr, mod_name, mod_off, op_str, fault_va)
	}
	if info.ContextRecord != nil {
		if code == 0xC0000005 && fault_va >= 0x10000 {
			mbi: win32.MEMORY_BASIC_INFORMATION
			if win32.VirtualQuery(rawptr(fault_va), &mbi, size_of(mbi)) != 0 {
				fmt.eprintf("  [mbi] base=0x%X alloc=0x%X sz=0x%X state=0x%X prot=0x%X type=0x%X\n",
					uintptr(mbi.BaseAddress), uintptr(mbi.AllocationBase), mbi.RegionSize, mbi.State, mbi.Protect, mbi.Type)
			}
		}
		ctx := info.ContextRecord
		if code == 0xC0000005 && g_boot_main_base != 0 && uintptr(ctx.Rip) >= g_boot_main_base + 16 && uintptr(ctx.Rip) + 16 <= g_boot_main_base + g_boot_main_size {
			cb := cast([^]u8)uintptr(ctx.Rip - 16)
			fmt.eprintf("  [code-16..+16]")
			for i in 0 ..< 32 { fmt.eprintf(" %02X", cb[i]) }
			fmt.eprintf("\n")
		}
		fmt.eprintf("  RAX=0x%X RCX=0x%X RDX=0x%X RBX=0x%X R8=0x%X R9=0x%X R11=0x%X RSP=0x%X\n",
			ctx.Rax, ctx.Rcx, ctx.Rdx, ctx.Rbx, ctx.R8, ctx.R9, ctx.R11, ctx.Rsp)
		if ctx.Rsp != 0 {
			sp := cast([^]uintptr)uintptr(ctx.Rsp)
			for i in 0 ..< 48 {
				v := sp[i]
				if v < 0x10000 { continue }
				if g_boot_main_base != 0 && v >= g_boot_main_base && v < g_boot_main_base + g_boot_main_size {
					fmt.eprintf("  stack[%d]=0x%X (main+0x%X)\n", i, v, v - g_boot_main_base)
				} else if g_boot_self_base != 0 && v >= g_boot_self_base && v < g_boot_self_base + 0x200000 {
					fmt.eprintf("  stack[%d]=0x%X (vasperty+0x%X)\n", i, v, v - g_boot_self_base)
				} else {
					hm: win32.HMODULE
					if GetModuleHandleExW(6, transmute(win32.LPCWSTR)v, &hm) && hm != nil {
						wbuf: [260]u16
						n := win32.GetModuleFileNameW(hm, &wbuf[0], 260)
						if n > 0 {
							if s, err := win32.utf16_to_utf8(wbuf[:n], context.temp_allocator); err == nil {
								fmt.eprintf("  stack[%d]=0x%X (%s+0x%X)\n", i, v, s, v - uintptr(hm))
							}
						}
					}
				}
			}
		}
	}
	return 0
}

foreign import kernel32_app_veh "system:Kernel32.lib"
@(default_calling_convention = "system")
foreign kernel32_app_veh {
	AddVectoredExceptionHandler    :: proc(first: u32, handler: rawptr) -> rawptr ---
	RemoveVectoredExceptionHandler :: proc(handle: rawptr) -> u32 ---
}

app_run :: proc(
	exe_path: string,
	strict := false,
	execute := false,
	zero_unimplemented := false,
	console := vasperty_hle.Console_Model.Series_X,
) -> int {
	rt, rerr := app_init(console)
	if rerr != .None {
		fmt.eprintf("run: init failed: %v\n", rerr)
		return 1
	}
	defer app_fini(&rt)

	raw, read_err := os.read_entire_file_from_path(exe_path, context.allocator)
	if read_err != nil {
		fmt.eprintf("run: cannot read '%s': %v\n", exe_path, read_err)
		return 1
	}
	defer delete(raw)

	prep, perr := vasperty_loader.prepare_image(raw)
	if perr != .None {
		fmt.eprintf("run: prepare failed: %v\n", perr)
		return 1
	}
	defer vasperty_loader.destroy_prepared_image(&prep)

	images_dir, _ := filepath.join({rt.config.cache_dir, "images"}, context.allocator)
	defer delete(images_dir)
	_ = os.make_directory_all(images_dir)

	img, lerr := vasperty_loader.load_prepared(&prep, images_dir)
	if lerr != .None {
		fmt.eprintf("run: load_prepared failed: %v\n", lerr)
		return 1
	}
	defer vasperty_loader.loaded_unload(&img)

	base := vasperty_loader.loaded_base(&img)
	vasperty_hle.set_main_image(base)
	vasperty_hle.set_image_path(base, exe_path)

	title_dir := filepath.dir(exe_path)
	manifest_path, _ := filepath.join({title_dir, "MicrosoftGame.config"}, context.allocator)
	defer delete(manifest_path)
	manifest_xml := ""
	if mbytes, merr := os.read_entire_file_from_path(manifest_path, context.allocator); merr == nil {
		manifest_xml = string(mbytes)
	}
	title := vasperty_hle.parse_manifest_xml(manifest_xml, rt.config.data_dir)
	if len(manifest_xml) > 0 {
		delete(transmute([]u8)manifest_xml)
	}
	vasperty_hle.set_title(title)
	vasperty_hle.destroy_title_info(&title)

	vasperty_hle.mount_virtual_drive_at('G', title_dir)
	temp_drive, _ := filepath.join({rt.config.data_dir, "temp"}, context.allocator)
	defer delete(temp_drive)
	vasperty_hle.mount_virtual_drive_at('T', temp_drive)

	host_policy := vasperty_hle.none_host_policy() if strict else vasperty_hle.default_host_policy()
	resolver := vasperty_hle.make_hle_resolver(host_policy)
	defer vasperty_hle.destroy_hle_resolver(&resolver)

	unimpl_pol := vasperty_loader.Unimplemented_Policy.Return_Zero if zero_unimplemented else vasperty_loader.Unimplemented_Policy.Trap

	// Load & bind sibling title DLLs shipped in title_dir (e.g. Bink2Scarlett, XboxBvhBuilder,
	// libHttpClient.GDK, amd_fidelityfx_loader_xbox) so all title imports resolve cleanly.
	Sibling_Loaded :: struct {
		img:       vasperty_loader.Loaded_Image,
		base:      uintptr,
		entry_rva: u32,
		dll_name:  string,
		exp_names: [dynamic]string,
	}
	siblings := make([dynamic]Sibling_Loaded)
	defer {
		for &sib in siblings {
			vasperty_loader.loaded_unload(&sib.img)
			delete(sib.dll_name)
			for en in sib.exp_names { delete(en) }
			delete(sib.exp_names)
		}
		delete(siblings)
	}

	seen_sib := make(map[string]bool)
	defer {
		for k, _ in seen_sib { delete(k) }
		delete(seen_sib)
	}
	for &imp in prep.info.imports {
		low := strings.to_lower(imp.dll, context.temp_allocator)
		if seen_sib[low] { continue }
		sib_path, jerr := filepath.join({title_dir, imp.dll}, context.temp_allocator)
		if jerr != nil || !os.is_file(sib_path) { continue }
		// Skip DLLs already provided by host system policy unless they are title-specific DLLs
		if vasperty_hle.host_policy_allows(&host_policy, imp.dll) { continue }
		seen_sib[strings.clone(low)] = true

		s_raw, s_rerr := os.read_entire_file_from_path(sib_path, context.allocator)
		if s_rerr != nil { continue }
		defer delete(s_raw)
		s_prep, s_perr := vasperty_loader.prepare_image(s_raw)
		if s_perr != .None { continue }
		defer vasperty_loader.destroy_prepared_image(&s_prep)

		s_img, s_lerr := vasperty_loader.load_prepared(&s_prep, images_dir)
		if s_lerr != .None { continue }
		s_base := vasperty_loader.loaded_base(&s_img)
		vasperty_hle.set_image_path(s_base, sib_path)

		s_rep, s_berr := vasperty_loader.loaded_bind_imports(&s_img, vasperty_hle.as_loader_resolver(&resolver), unimpl_pol)
		if s_berr == .None {
			fmt.printf("  sibling %s at 0x%X: %d hle, %d host, %d missing\n",
				imp.dll, s_base, s_rep.hle, s_rep.host, len(s_rep.missing))
			vasperty_loader.destroy_bind_report(&s_rep)
		}

		sib_rec := Sibling_Loaded{
			img       = s_img,
			base      = s_base,
			entry_rva = s_prep.info.entry_rva,
			dll_name  = strings.clone(imp.dll),
			exp_names = make([dynamic]string, 0, len(s_prep.info.exports)),
		}
		exps := make([dynamic]vasperty_hle.Hle_Export, 0, len(s_prep.info.exports), context.temp_allocator)
		// Bink2 fast-forward stubs: only BinkNextFrame advances FrameNum (hdr[3]);
		// BinkDoFrame* only records LastFrameNum (hdr[4] = hdr[3]), and BinkDoFrameAsyncWait
		// returns 1 (done) without mutating header fields so polling/close cannot race.
		bink_mark_decoded :: proc "system" (bnk: rawptr, advance: u32) {
			if uintptr(bnk) >= 0x10000 {
				hdr := cast([^]u32)bnk
				frames := hdr[2]
				cur := hdr[3]
				if frames > 0 && frames < 1_000_000 {
					hdr[4] = cur
					if advance > 0 && cur < frames {
						hdr[3] = cur + advance if cur + advance <= frames else frames
					}
				}
			}
		}
		bink_do_frame :: proc "system" (bnk: rawptr) -> i32 {
			bink_mark_decoded(bnk, 0)
			return 0
		}
		bink_do_frame_async :: proc "system" (bnk: rawptr) -> i32 {
			bink_mark_decoded(bnk, 3)
			return 1
		}
		bink_async_wait :: proc "system" (_bnk: rawptr) -> i32 { return 1 }
		bink_wait_zero :: proc "system" (_bnk: rawptr) -> i32 { return 0 }
		bink_next_frame :: proc "system" (bnk: rawptr) {
			bink_mark_decoded(bnk, 2)
		}
		is_bink_dll := strings.contains(low, "bink")
		for &exp in s_prep.info.exports {
			if !exp.has_rva { continue }
			addr := s_base + uintptr(exp.rva)
			if is_bink_dll {
				switch exp.name {
				case "BinkDoFrame", "BinkDoFramePlane":
					addr = uintptr(rawptr(bink_do_frame))
				case "BinkWait":
					addr = uintptr(rawptr(bink_wait_zero))
				case "BinkNextFrame":
					addr = uintptr(rawptr(bink_next_frame))
				case "BinkDoFrameAsync", "BinkDoFrameAsyncMulti":
					addr = uintptr(rawptr(bink_do_frame_async))
				case "BinkDoFrameAsyncWait":
					addr = uintptr(rawptr(bink_async_wait))
				}
			}
			if len(exp.name) > 0 {
				nm := strings.clone(exp.name)
				append(&sib_rec.exp_names, nm)
				append(&exps, vasperty_hle.Hle_Export{name = nm, address = addr})
			}
			ord_nm := fmt.aprintf("#%d", exp.ordinal)
			append(&sib_rec.exp_names, ord_nm)
			append(&exps, vasperty_hle.Hle_Export{name = ord_nm, address = addr})
		}
		dll_arr := [1]string{sib_rec.dll_name}
		vasperty_hle.register_module(sib_rec.dll_name, dll_arr[:], exps[:])
		append(&siblings, sib_rec)
	}

	report, berr := vasperty_loader.loaded_bind_imports(&img, vasperty_hle.as_loader_resolver(&resolver), unimpl_pol)
	if berr != .None {
		fmt.eprintf("run: bind imports failed: %v\n", berr)
		return 1
	}
	defer vasperty_loader.destroy_bind_report(&report)

	fmt.printf(
		"bound %s at 0x%X: %d hle, %d host, %d missing\n",
		exe_path, base, report.hle, report.host, len(report.missing),
	)

	if execute {
		g_boot_self_base = uintptr(win32.GetModuleHandleW(nil))
		g_boot_main_base = base
		g_boot_main_size = uintptr(prep.info.size_of_image)
		veh := AddVectoredExceptionHandler(1, rawptr(boot_veh_handler))
		defer if veh != nil { _ = RemoveVectoredExceptionHandler(veh) }

		vasperty_hle.use_console_timers()
		g_boot_stage = "sibling_dllmain"
		Dll_Main_Proc :: #type proc "system" (hinst: rawptr, reason: u32, reserved: rawptr) -> i32
		for &sib in siblings {
			vasperty_loader.loaded_run_tls_callbacks(&sib.img, 1)
			if sib.entry_rva != 0 {
				dll_main := cast(Dll_Main_Proc)rawptr(sib.base + uintptr(sib.entry_rva))
				ok_dm := dll_main(rawptr(sib.base), 1, nil)
				fmt.printf("[boot] DllMain(%s, ATTACH) -> %d\n", sib.dll_name, ok_dm)
			}
		}
		g_boot_stage = "tls_callbacks"
		fmt.printf("[boot] running %d TLS callbacks...\n", len(prep.info.tls.callback_rvas))
		vasperty_loader.loaded_run_tls_callbacks(&img, 1)
		g_boot_stage = "entry_point"
		fmt.printf("[boot] entering EntryRVA 0x%X (0x%X)...\n", prep.info.entry_rva, base + uintptr(prep.info.entry_rva))
		entry_ptr := rawptr(base + uintptr(prep.info.entry_rva))
		if prep.info.entry_rva != 0 {
			Entry_Proc :: #type proc "system" () -> i32
			entry_fn := cast(Entry_Proc)entry_ptr
			return int(entry_fn())
		}
	}
	return 0
}

app_bench :: proc(secs: f64) -> int {
	dur_s := secs if secs > 0.2 else 1.0
	fmt.printf("=== Vasperty Benchmarks (target %.2fs each) ===\n", dur_s)

	city_buf: [128]u8
	for i := 0; i < len(city_buf); i += 1 {
		city_buf[i] = u8(i * 31 + 7)
	}
	t0 := time.tick_now()
	hashes := 0
	acc: u64 = 0
	for {
		for batch := 0; batch < 1024; batch += 1 {
			city_buf[0] = u8((hashes + batch) & 0xFF)
			city_buf[1] = u8((hashes + batch) >> 8)
			acc ~= vasperty_game.city64(city_buf[:])
		}
		hashes += 1024
		if time.duration_seconds(time.tick_since(t0)) >= dur_s { break }
	}
	el_city := time.duration_seconds(time.tick_since(t0))
	city_mb_s := (f64(hashes) * 128.0) / (1024.0 * 1024.0 * el_city)
	fmt.printf("city64 (128 B)  : %9d hashes in %.3fs -> %.1f M hashes/s (%.1f MiB/s) [0x%016X]\n",
		hashes, el_city, f64(hashes) / (1e6 * el_city), city_mb_s, acc)

	desc := vasperty_formats.Desc{
		dimension     = .Tex2d,
		width         = 1024,
		height        = 1024,
		depth         = 1,
		mips          = 1,
		element_bytes = 4,
		block         = 1,
		samples       = 1,
		swizzle       = vasperty_formats.SWIZZLE_64KB_S,
	}
	layout, l_err := vasperty_formats.new_layout(desc)
	if l_err != .None {
		fmt.eprintf("bench: layout creation failed: %v\n", l_err)
		return 1
	}
	defer vasperty_formats.destroy_layout(&layout)

	row_pitch := int(desc.width * desc.element_bytes)
	lin_size := row_pitch * int(desc.height)
	tiled := make([]u8, int(layout.size))
	linear := make([]u8, lin_size)
	defer delete(tiled)
	defer delete(linear)
	for i := 0; i < len(linear); i += 1 { linear[i] = u8(i) }

	t1 := time.tick_now()
	tile_iters := 0
	for {
		_ = vasperty_formats.layout_tile(&layout, tiled, 0, 0, linear, row_pitch, lin_size)
		tile_iters += 1
		if time.duration_seconds(time.tick_since(t1)) >= dur_s { break }
	}
	el_tile := time.duration_seconds(time.tick_since(t1))
	fmt.printf("rdna2 tile 2D   : %6d frames (4 MiB 64KB_S) in %.3fs -> %.2f GiB/s\n",
		tile_iters, el_tile, (f64(tile_iters) * f64(lin_size)) / (1024.0 * 1024.0 * 1024.0 * el_tile))

	t2 := time.tick_now()
	detile_iters := 0
	for {
		_ = vasperty_formats.layout_detile(&layout, tiled, 0, 0, linear, row_pitch, lin_size)
		detile_iters += 1
		if time.duration_seconds(time.tick_since(t2)) >= dur_s { break }
	}
	el_detile := time.duration_seconds(time.tick_since(t2))
	fmt.printf("rdna2 detile 2D : %6d frames (4 MiB 64KB_S) in %.3fs -> %.2f GiB/s\n",
		detile_iters, el_detile, (f64(detile_iters) * f64(lin_size)) / (1024.0 * 1024.0 * 1024.0 * el_detile))

	rot: vasperty_formats.Xma_Rotations
	vasperty_formats.xma_init_rotations(&rot, 512)
	mdct_in: [512]f32
	mdct_out: [512]f32
	for i := 0; i < 512; i += 1 { mdct_in[i] = f32((i * 7919) % 97) - 48.0 }
	tx := time.tick_now()
	mdct_iters := 0
	mdct_acc: f32 = 0
	for {
		for _ in 0 ..< 256 {
			vasperty_formats.xma_imdct_with_rotations(&rot, mdct_in[:], mdct_out[:], 1.0)
			mdct_acc += mdct_out[0]
			mdct_in[0] += 0.0001
		}
		mdct_iters += 256
		if time.duration_seconds(time.tick_since(tx)) >= dur_s { break }
	}
	el_mdct := time.duration_seconds(time.tick_since(tx))
	fmt.printf("xma imdct-512   : %7d transforms in %.3fs -> %.0f ns/subframe (%.2f M/s) [%.3f]\n",
		mdct_iters, el_mdct, (el_mdct * 1e9) / f64(mdct_iters), f64(mdct_iters) / (1e6 * el_mdct), mdct_acc)

	r_state := [vasperty_game.STATE_RASTER]u8{
		0x40, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01, 0x01,
		3, 2, 1, transmute(u8)i8(-4), 0, 0, 0, 0,
	}
	want_r := make(map[u64]bool)
	want_r[vasperty_game.city64(r_state[:])] = true
	defer delete(want_r)
	tr := time.tick_now()
	r_iters := 0
	for {
		found := vasperty_game.resolve_raster_hashes(&want_r)
		delete(found)
		r_iters += 1
		if time.duration_seconds(time.tick_since(tr)) >= dur_s { break }
	}
	el_r := time.duration_seconds(time.tick_since(tr))
	fmt.printf("pso raster res. : %6d solves in %.3fs -> %.2f ms/solve\n", r_iters, el_r, (el_r * 1e3) / f64(r_iters))

	p0 := city_buf[:64]
	p1 := city_buf[64:]
	parts := [2][]u8{p0, p1}
	t3 := time.tick_now()
	keys := 0
	key_acc: u8 = 0
	for {
		for b := 0; b < 512; b += 1 {
			p0[0] = u8((keys + b) & 0xFF)
			p0[1] = u8((keys + b) >> 8)
			k := vasperty_pipeline.cache_key_from_parts("dxil-sm66", 1, parts[:])
			key_acc ~= k.digest[0]
		}
		keys += 512
		if time.duration_seconds(time.tick_since(t3)) >= dur_s { break }
	}
	el_key := time.duration_seconds(time.tick_since(t3))
	fmt.printf("cache sha256    : %9d keys in %.3fs -> %.2f M keys/s [0x%02X]\n", keys, el_key, f64(keys) / (1e6 * el_key), key_acc)

	shader_words := [6]u32{0xbe82_0300, 0x7e00_0202, 0x8000_8100, 0xbf06_8100, 0xbf84_0000, 0xbf81_0000}
	shader_bytes := slice.reinterpret([]u8, shader_words[:])
	t4 := time.tick_now()
	sh_iters := 0
	sh_acc: u64 = 0
	for {
		p, st, err := vasperty_shader.range_build(shader_bytes, false, 4)
		if err == .None {
			sh_acc += u64(len(p.blocks) + len(st.bools.nodes))
			vasperty_shader.destroy_structured(&st)
			vasperty_shader.destroy_program(&p)
		}
		sh_iters += 1
		if time.duration_seconds(time.tick_since(t4)) >= dur_s { break }
	}
	el_sh := time.duration_seconds(time.tick_since(t4))
	fmt.printf("shader ir+bdd   : %6d shaders in %.3fs -> %.1f K shaders/s [0x%X]\n", sh_iters, el_sh, f64(sh_iters) / (1e3 * el_sh), sh_acc)

	caps := vasperty_gpu.probe_capabilities(true)
	defer vasperty_gpu.destroy_host_capabilities(&caps)
	fmt.printf("d3d12 adapter   : %s (%s, mesh=%v, wave=%v %d..%d, tearing=%v)\n",
		caps.adapter_name, caps.highest_shader_model, caps.mesh_shaders,
		caps.wave_ops, caps.wave_lane_count_min, caps.wave_lane_count_max, caps.allow_tearing)

	if ex, ex_ok := vasperty_gpu.host_executor_init(true); ex_ok {
		defer vasperty_gpu.host_executor_destroy(&ex)
		tg := time.tick_now()
		submitted := 0
		for submitted < 256 {
			if slot, bok := vasperty_gpu.host_executor_begin_frame(&ex); bok {
				if _, sok := vasperty_gpu.host_executor_submit_frame(&ex, slot); sok {
					submitted += 1
				} else {
					break
				}
			} else {
				break
			}
		}
		vasperty_gpu.host_executor_drain(&ex)
		el_gpu := time.duration_seconds(time.tick_since(tg))
		fmt.printf("d3d12 async ring: %6d frames in %.3fs -> %.0f frames/s (in_flight=%d async_compute=%v)\n",
			submitted, el_gpu, f64(submitted) / max(el_gpu, 0.0001),
			ex.tuning.max_frames_in_flight, ex.compute_queue != nil)
	}
	return 0
}

parse_bench_seconds :: proc(arg: string) -> f64 {
	if v, ok := strconv.parse_f64(arg); ok {
		return v
	}
	return 2.0
}
