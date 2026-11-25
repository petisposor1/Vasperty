package vasperty_cli

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"

import vasperty_core "vasperty:core"
import vasperty_formats "vasperty:formats"
import vasperty_game "vasperty:game"
import vasperty_pe "vasperty:pe"
import vasperty_pipeline "vasperty:pipeline"

usage :: proc() {
	fmt.println("Vasperty Native Odin CLI (Phase 1)")
	fmt.println("Usage:")
	fmt.println("  vasperty.exe status")
	fmt.println("  vasperty.exe doctor")
	fmt.println("  vasperty.exe inspect <pe-path>")
	fmt.println("  vasperty.exe bench [seconds]")
}

cmd_status :: proc() -> int {
	cores := os.get_processor_core_count()
	fmt.printf("vasperty-odin: Phase 1 core packages online (cores=%d)\n", cores)
	fmt.println("  packages: vasperty:core, vasperty:pe, vasperty:game, vasperty:formats, vasperty:pipeline")
	fmt.println("  baseline: Marvisak/VIctory upstream 13f91ca (GTA VI prologue)")
	return 0
}

cmd_doctor :: proc() -> int {
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

	if cache, c_err := vasperty_pipeline.cache_open(cfg.cache_dir); c_err == .None {
		defer vasperty_pipeline.cache_destroy(&cache)
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
	return 0
}

cmd_inspect :: proc(path: string) -> int {
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
	return 0
}

cmd_bench :: proc(secs: f64) -> int {
	dur_s := secs if secs > 0.2 else 1.0
	fmt.printf("=== Vasperty Native Odin Benchmarks (target %.2fs each) ===\n", dur_s)

	// 1. CityHash64 throughput on 128-byte state descriptors
	city_buf: [128]u8
	for i := 0; i < len(city_buf); i += 1 {
		city_buf[i] = u8(i * 31 + 7)
	}
	t0 := time.tick_now()
	hashes := 0
	acc: u64 = 0
	for {
		for batch := 0; batch < 1024; batch += 1 {
			city_buf[0] = u8(hashes + batch)
			acc ~= vasperty_game.city64(city_buf[:])
		}
		hashes += 1024
		if time.duration_seconds(time.tick_since(t0)) >= dur_s {
			break
		}
	}
	el_city := time.duration_seconds(time.tick_since(t0))
	city_mb_s := (f64(hashes) * 128.0) / (1024.0 * 1024.0 * el_city)
	fmt.printf("city64 (128 B)  : %9d hashes in %.3fs -> %.1f M hashes/s (%.1f MiB/s) [0x%016X]\n",
		hashes, el_city, f64(hashes) / (1e6 * el_city), city_mb_s, acc)

	// 2. RDNA2 64KB_S 2D 1024x1024 RGBA8 parallel tile + detile
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
	for i := 0; i < len(linear); i += 1 {
		linear[i] = u8(i)
	}

	t1 := time.tick_now()
	tile_iters := 0
	for {
		_ = vasperty_formats.layout_tile(&layout, tiled, 0, 0, linear, row_pitch, lin_size)
		tile_iters += 1
		if time.duration_seconds(time.tick_since(t1)) >= dur_s {
			break
		}
	}
	el_tile := time.duration_seconds(time.tick_since(t1))
	tile_gb_s := (f64(tile_iters) * f64(lin_size)) / (1024.0 * 1024.0 * 1024.0 * el_tile)
	fmt.printf("rdna2 tile 2D   : %6d frames (4 MiB 64KB_S) in %.3fs -> %.2f GiB/s\n", tile_iters, el_tile, tile_gb_s)

	t2 := time.tick_now()
	detile_iters := 0
	for {
		_ = vasperty_formats.layout_detile(&layout, tiled, 0, 0, linear, row_pitch, lin_size)
		detile_iters += 1
		if time.duration_seconds(time.tick_since(t2)) >= dur_s {
			break
		}
	}
	el_detile := time.duration_seconds(time.tick_since(t2))
	detile_gb_s := (f64(detile_iters) * f64(lin_size)) / (1024.0 * 1024.0 * 1024.0 * el_detile)
	fmt.printf("rdna2 detile 2D : %6d frames (4 MiB 64KB_S) in %.3fs -> %.2f GiB/s\n", detile_iters, el_detile, detile_gb_s)

	// 3. Streaming multipart SHA-256 cache keying (zero-concat)
	p0 := city_buf[:64]
	p1 := city_buf[64:]
	parts := [2][]u8{p0, p1}
	t3 := time.tick_now()
	keys := 0
	key_acc: u8 = 0
	for {
		for b := 0; b < 512; b += 1 {
			p0[0] = u8(keys + b)
			k := vasperty_pipeline.cache_key_from_parts("dxil-sm66", 1, parts[:])
			key_acc ~= k.digest[0]
		}
		keys += 512
		if time.duration_seconds(time.tick_since(t3)) >= dur_s {
			break
		}
	}
	el_key := time.duration_seconds(time.tick_since(t3))
	fmt.printf("cache sha256    : %9d keys in %.3fs -> %.2f M keys/s [0x%02X]\n", keys, el_key, f64(keys) / (1e6 * el_key), key_acc)
	return 0
}

main :: proc() {
	if len(os.args) < 2 {
		usage()
		os.exit(0)
	}
	switch os.args[1] {
	case "status":
		os.exit(cmd_status())
	case "doctor":
		os.exit(cmd_doctor())
	case "inspect":
		if len(os.args) < 3 {
			fmt.eprintln("inspect requires <pe-path>")
			os.exit(2)
		}
		os.exit(cmd_inspect(os.args[2]))
	case "bench":
		secs := 2.0
		if len(os.args) >= 3 {
			if v, ok := strconv.parse_f64(os.args[2]); ok {
				secs = v
			}
		}
		os.exit(cmd_bench(secs))
	case:
		usage()
		os.exit(2)
	}
}
