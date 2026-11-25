package vasperty_app

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
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
	fmt.printf("vasperty-odin: All 7 phases online (cores=%d)\n", cores)
	fmt.println("  packages: core, pe, game, formats, pipeline, loader, hle, shader, gpu, app, cli")
	fmt.println("  baseline: Marvisak/VIctory upstream 13f91ca (GTA VI prologue)")
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

app_doctor :: proc(prune_cache := false) -> int {
	cfg, cfg_err := vasperty_core.load_config()
	if cfg_err != .None {
		fmt.eprintf("doctor: config/policy error: %v\n", cfg_err)
		return 1
	}
	defer vasperty_core.destroy_config(&cfg)

	cores := os.get_processor_core_count()
	fmt.println("=== Vasperty Odin Doctor ===")
	fmt.printf("CPU cores       : %d\n", cores)
	fmt.printf("Config source   : %s\n", cfg.source if cfg.has_source else "<defaults/env>")
	fmt.printf("Game dir        : %s\n", cfg.game_dir if cfg.has_game_dir else "<unset>")
	fmt.printf("Cache dir       : %s (policy OK)\n", cfg.cache_dir)
	fmt.printf("Data dir        : %s (policy OK)\n", cfg.data_dir)
	fmt.printf("FidelityFX dir  : %s\n", cfg.fidelityfx_dir if cfg.has_fidelityfx_dir else "<unset>")

	caps := vasperty_gpu.probe_capabilities(true)
	defer vasperty_gpu.destroy_host_capabilities(&caps)
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

	if cache, c_err := vasperty_pipeline.cache_open(cfg.cache_dir); c_err == .None {
		defer vasperty_pipeline.cache_destroy(&cache)
		if prune_cache {
			if rem, freed, pr_err := vasperty_pipeline.cache_prune_stale_temps(&cache); pr_err == .None && rem > 0 {
				fmt.printf("Cache pruned    : %d stale temp files (%d bytes)\n", rem, freed)
			}
		}
		if stats, s_err := vasperty_pipeline.cache_stats(&cache); s_err == .None {
			fmt.printf(
				"Pipeline cache  : %d entries (%d bytes), %d stale temps (%d bytes)\n",
				stats.entries,
				stats.total_bytes,
				stats.stale_temps,
				stats.stale_temp_bytes,
			)
		}
	} else {
		fmt.eprintf("doctor: cache open error: %v\n", c_err)
		return 1
	}

	if tbl, b_err := vasperty_formats.bcpack_builtin_tables(); b_err == .None {
		vasperty_formats.bcpack_destroy_tables(tbl)
		fmt.println("BCPack tables   : loaded cleanly (128 rANS models, 6 dictionaries)")
	} else {
		fmt.eprintf("doctor: bcpack tables error: %v\n", b_err)
		return 1
	}
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
	for p in paths {
		if os.is_file(p) {
			if r, ok := app_census_file(&res, p, &missing_map); ok {
				total.images += r.images
				total.hle += r.hle
				total.host += r.host
				total.missing += r.missing
			}
		}
	}
	fmt.printf("census: %d images -> %d hle, %d host, %d missing\n", total.images, total.hle, total.host, total.missing)
	if show_missing && len(missing_map) > 0 {
		for k, cnt in missing_map {
			fmt.printf("  missing (%dx): %s\n", cnt, k)
		}
	}
	return 0
}

Translate_Tally :: struct {
	containers: int,
	translated: int,
	validated:  int,
	failed:     int,
}

app_translate_blob :: proc(blob: []u8, validate: bool, tally: ^Translate_Tally) {
	if len(blob) >= 4 && blob[0] == 'D' && blob[1] == 'X' && blob[2] == 'B' && blob[3] == 'C' {
		tally.containers += 1
		hs, terr := vasperty_shader.translate(blob)
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
				app_translate_blob(ur.data, validate, tally)
			}
		}
	}
}

app_translate :: proc(paths: []string, validate := false) -> (Translate_Tally, int) {
	tally: Translate_Tally
	for p in paths {
		if os.is_file(p) {
			raw, rerr := os.read_entire_file_from_path(p, context.allocator)
			if rerr == nil {
				app_translate_blob(raw, validate, &tally)
				delete(raw)
			}
		}
	}
	fmt.printf(
		"translate: %d containers -> %d translated, %d validated, %d failed/unsupported\n",
		tally.containers, tally.translated, tally.validated, tally.failed,
	)
	return tally, 0
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
		vasperty_hle.use_console_timers()
		vasperty_loader.loaded_run_tls_callbacks(&img, 1)
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
	fmt.printf("=== Vasperty Native Odin Benchmarks (target %.2fs each) ===\n", dur_s)

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
	return 0
}

parse_bench_seconds :: proc(arg: string) -> f64 {
	if v, ok := strconv.parse_f64(arg); ok {
		return v
	}
	return 2.0
}
