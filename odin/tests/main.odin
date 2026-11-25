package vasperty_tests

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"

import vasperty_core "vasperty:core"
import vasperty_formats "vasperty:formats"
import vasperty_game "vasperty:game"
import vasperty_pe "vasperty:pe"
import vasperty_pipeline "vasperty:pipeline"

@(private)
put_u32_le :: proc(buf: []u8, at: int, val: u32) {
	buf[at + 0] = u8(val)
	buf[at + 1] = u8(val >> 8)
	buf[at + 2] = u8(val >> 16)
	buf[at + 3] = u8(val >> 24)
}

@(private)
put_u64_le :: proc(buf: []u8, at: int, val: u64) {
	put_u32_le(buf, at, u32(val))
	put_u32_le(buf, at + 4, u32(val >> 32))
}

test_core_policy_and_config :: proc() {
	fmt.print("[test] core_policy_and_config ... ")
	assert(vasperty_core.ensure_outside_repo("cache\\textures") == .Inside_Repo, "relative repo path rejected")
	assert(vasperty_core.ensure_outside_repo("crates\\..\\not-created\\out") == .Inside_Repo, "dotdot escape rejected")
	assert(vasperty_core.ensure_outside_repo("") == .Empty_Path, "empty path rejected")

	temp_base, found_tmp := os.lookup_env("TEMP", context.allocator)
	assert(found_tmp && len(temp_base) > 0, "TEMP env present")
	defer delete(temp_base)

	ext_path, _ := filepath.join({temp_base, "vasperty_odin_outside_test", "sub"}, context.allocator)
	defer delete(ext_path)
	assert(vasperty_core.ensure_outside_repo(ext_path) == .None, "unrelated path allowed")

	cfg, err := vasperty_core.load_config()
	assert(err == .None, "default config loads outside repo")
	vasperty_core.destroy_config(&cfg)
	fmt.println("ok")
}

test_pe_parser :: proc() {
	fmt.print("[test] pe_self_parse_and_guards ... ")
	exe_path := os.args[0]
	raw, r_err := os.read_entire_file_from_path(exe_path, context.allocator)
	assert(r_err == nil && len(raw) > 1024, "read self exe")
	defer delete(raw)

	info, pe_err := vasperty_pe.parse_image(raw)
	assert(pe_err == .None, "parse self PE32+")
	defer vasperty_pe.destroy_image(&info)

	assert(info.machine == vasperty_pe.MACHINE_AMD64, "AMD64 machine")
	assert(!vasperty_pe.is_dll(&info), "not DLL")
	assert(info.entry_rva != 0, "entry RVA non-zero")
	assert(len(info.sections) >= 2, "sections parsed")
	off, off_ok := vasperty_pe.rva_to_file_offset(info.sections[:], info.entry_rva)
	assert(off_ok && off > 0, "entry RVA maps to file offset")

	garbage := [16]u8{0 = 1, 1 = 2, 2 = 3, 3 = 4}
	bad_info, bad_err := vasperty_pe.parse_image(garbage[:])
	assert(bad_err != .None, "garbage PE rejected")
	vasperty_pe.destroy_image(&bad_info)
	fmt.println("ok")
}

test_cityhash64 :: proc() {
	fmt.print("[test] game_cityhash64_v11_vectors ... ")
	// Reference vectors verified identically against upstream victory-game CityHash64 v1.1
	v0 := vasperty_game.city64(nil)
	assert(v0 == 0x9AE1_6A3B_2F90_404F, "empty vector")

	abc := transmute([]u8)string("abc")
	assert(vasperty_game.city64(abc) == 0x24A5_B3A0_74E7_F369, "short string vector")

	seq: [128]u8
	for i := 0; i < 128; i += 1 {
		seq[i] = u8(i)
	}
	assert(vasperty_game.city64(seq[:24]) != vasperty_game.city64(seq[:25]), "medium distinct")
	assert(vasperty_game.city64(seq[:48]) != vasperty_game.city64(seq[:49]), "to64 distinct")
	h_long := vasperty_game.city64(seq[:])
	assert(h_long != 0 && h_long == vasperty_game.city64(seq[:]), "128B deterministic")
	fmt.println("ok")
}

test_shaderpack :: proc() {
	fmt.print("[test] game_shaderpack_parse_and_reject ... ")
	// Build a minimal valid PS\0\x09 ShaderPack with 1 blob & 1 program & 1 compute record
	blob0 := [8]u8{1, 2, 3, 4, 5, 6, 7, 8}
	prog0 := [16]u8{0xDE, 0xAD, 0xBE, 0xEF, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}

	buf := make([]u8, 0x80 + 0x18 + 8 + 8 + len(blob0) + len(prog0))
	defer delete(buf)

	copy(buf[:4], ([]u8)(transmute([]u8)string("PS\x00\x09")))
	copy(buf[4:16], transmute([]u8)string("vasperty-drv"))
	copy(buf[0x24:0x2E], transmute([]u8)string("odin-1.0"))
	put_u64_le(buf, 0x48, 0x1122334455667788)
	put_u32_le(buf, 0x50, 0) // ng
	put_u32_le(buf, 0x54, 1) // nc
	put_u32_le(buf, 0x58, 1) // nb
	put_u32_le(buf, 0x5C, 1) // np
	put_u32_le(buf, 0x60, u32(len(blob0)))
	put_u32_le(buf, 0x64, u32(len(prog0)))

	c_off := 0x80
	put_u64_le(buf, c_off + 0, 0xAABBCCDDEEFF0011)
	put_u32_le(buf, c_off + 8, 0)  // packet blob 0
	put_u32_le(buf, c_off + 12, 0) // meta blob 0
	put_u32_le(buf, c_off + 16, 0) // program 0
	put_u32_le(buf, c_off + 20, max(u32)) // no stage meta

	bt_off := c_off + 0x18
	put_u32_le(buf, bt_off + 0, 0)
	put_u32_le(buf, bt_off + 4, u32(len(blob0)))

	pt_off := bt_off + 8
	put_u32_le(buf, pt_off + 0, 0)
	put_u32_le(buf, pt_off + 4, u32(len(prog0)))

	bd_off := pt_off + 8
	copy(buf[bd_off:], blob0[:])
	pd_off := bd_off + len(blob0)
	copy(buf[pd_off:], prog0[:])

	pack, err := vasperty_game.parse_pack(buf)
	assert(err == .None, "synthetic shaderpack valid")
	assert(vasperty_game.pack_fingerprint(&pack) == 0x1122334455667788, "fingerprint matches")
	assert(vasperty_game.pack_compute_count(&pack) == 1, "1 compute entry")
	crec, cok := vasperty_game.pack_compute(&pack, 0)
	assert(cok && crec.shader_hash == 0xAABBCCDDEEFF0011, "compute hash matches")
	assert(len(crec.stage.program) == len(prog0), "program length matches")

	_, bad_err := vasperty_game.parse_pack(buf[:32])
	assert(bad_err != .None, "truncated pack rejected")
	fmt.println("ok")
}

test_texture_formats :: proc() {
	fmt.print("[test] formats_rdna2_2d_3d_tile_detile ... ")
	// 2D 512x512 RGBA8 (1 MiB -> parallel tile/detile path!)
	d2 := vasperty_formats.Desc{
		dimension     = .Tex2d,
		width         = 512,
		height        = 512,
		depth         = 1,
		mips          = 4,
		element_bytes = 4,
		block         = 1,
		samples       = 1,
		swizzle       = vasperty_formats.SWIZZLE_64KB_S,
	}
	l2, err2 := vasperty_formats.new_layout(d2)
	assert(err2 == .None && l2.size > 0, "2D layout created")
	defer vasperty_formats.destroy_layout(&l2)

	o0, ok0 := vasperty_formats.layout_offset(&l2, 0, 0, 0, 0)
	o1, ok1 := vasperty_formats.layout_offset(&l2, 0, 1, 0, 0)
	assert(ok0 == .None && ok1 == .None && o0 != o1, "distinct pixel offsets")

	tiled2 := make([]u8, int(l2.size))
	src2 := make([]u8, 512 * 512 * 4)
	dst2 := make([]u8, 512 * 512 * 4)
	defer {
		delete(tiled2)
		delete(src2)
		delete(dst2)
	}
	for i := 0; i < len(src2); i += 1 {
		src2[i] = u8((i * 13 + 5) & 0xFF)
	}
	assert(vasperty_formats.layout_tile(&l2, tiled2, 0, 0, src2, 512 * 4, len(src2)) == .None, "2D tile OK")
	assert(vasperty_formats.layout_detile(&l2, tiled2, 0, 0, dst2, 512 * 4, len(dst2)) == .None, "2D detile OK")
	for i := 0; i < len(src2); i += 1 {
		assert(src2[i] == dst2[i], "2D tile/detile exact roundtrip")
	}

	// 3D 128x64x16 RGBA8 thick (512 KiB -> parallel 3D slab tile/detile path!)
	d3 := vasperty_formats.Desc{
		dimension     = .Tex3d,
		width         = 128,
		height        = 64,
		depth         = 16,
		mips          = 1,
		element_bytes = 4,
		block         = 1,
		samples       = 1,
		swizzle       = vasperty_formats.SWIZZLE_64KB_S,
	}
	l3, err3 := vasperty_formats.new_layout(d3)
	assert(err3 == .None && l3.thick, "3D thick layout")
	defer vasperty_formats.destroy_layout(&l3)

	tiled3 := make([]u8, int(l3.size))
	src3 := make([]u8, 128 * 64 * 16 * 4)
	dst3 := make([]u8, 128 * 64 * 16 * 4)
	defer {
		delete(tiled3)
		delete(src3)
		delete(dst3)
	}
	for i := 0; i < len(src3); i += 1 {
		src3[i] = u8((i * 29 + 11) & 0xFF)
	}
	rp3 := 128 * 4
	dp3 := rp3 * 64
	assert(vasperty_formats.layout_tile(&l3, tiled3, 0, 0, src3, rp3, dp3) == .None, "3D tile OK")
	assert(vasperty_formats.layout_detile(&l3, tiled3, 0, 0, dst3, rp3, dp3) == .None, "3D detile OK")
	for i := 0; i < len(src3); i += 1 {
		assert(src3[i] == dst3[i], "3D tile/detile exact roundtrip")
	}
	fmt.println("ok")
}

@(private)
dummy_convert :: proc(user_data: rawptr, parts: [][]u8, allocator := context.allocator) -> ([]u8, bool) {
	calls := (^int)(user_data)
	calls^ += 1
	total := 0
	for p in parts do total += len(p)
	out := make([]u8, total, allocator)
	pos := 0
	for p in parts {
		copy(out[pos:], p)
		pos += len(p)
	}
	return out, true
}

test_pipeline_cache :: proc() {
	fmt.print("[test] pipeline_cache_sha256_stats_prune ... ")
	// Inside repo must fail
	_, inside_err := vasperty_pipeline.cache_open("cache\\bad_odin_test")
	assert(inside_err == .Inside_Repo, "cache inside repo refused")

	temp_base, _ := os.lookup_env("TEMP", context.allocator)
	defer delete(temp_base)
	root, _ := filepath.join({temp_base, "vasperty_odin_cache_test"}, context.allocator)
	defer delete(root)

	cache, o_err := vasperty_pipeline.cache_open(root)
	assert(o_err == .None, "open external test cache")
	defer vasperty_pipeline.cache_destroy(&cache)

	// Multipart miss then hit
	calls := 0
	a := transmute([]u8)string("partA-")
	b := transmute([]u8)string("partB")
	parts := [2][]u8{a, b}
	d1, p1, hit1, e1 := vasperty_pipeline.cache_read_or_convert_parts(&cache, "test-conv", 1, parts[:], &calls, dummy_convert)
	assert(e1 == .None && !hit1 && calls == 1, "first lookup converts")
	assert(string(d1) == "partA-partB", "converted bytes match")
	delete(d1)
	delete(p1)

	d2, p2, hit2, e2 := vasperty_pipeline.cache_read_or_convert_parts(&cache, "test-conv", 1, parts[:], &calls, dummy_convert)
	assert(e2 == .None && hit2 && calls == 1, "second lookup hits cache")
	assert(string(d2) == "partA-partB", "cached bytes match")
	delete(d2)
	delete(p2)

	// Create synthetic stale .tmp- file and verify stats & prune
	k := vasperty_pipeline.cache_key_from_parts("test-conv", 1, parts[:])
	kp, _ := vasperty_pipeline.cache_path_for(&cache, k)
	shard := filepath.dir(kp)
	stale, _ := filepath.join({shard, ".tmp-99999-stale"}, context.allocator)
	_ = os.write_entire_file(stale, transmute([]u8)string("junk"))

	st1, s_err1 := vasperty_pipeline.cache_stats(&cache)
	assert(s_err1 == .None && st1.entries >= 1 && st1.stale_temps >= 1, "stats count entry and stale temp")
	removed, freed, pr_err := vasperty_pipeline.cache_prune_stale_temps(&cache)
	assert(pr_err == .None && removed >= 1 && freed >= 4, "stale temps pruned")
	assert(os.exists(kp), "published entry kept")

	_ = os.remove(kp)
	delete(kp)
	delete(stale)
	fmt.println("ok")
}

main :: proc() {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	test_core_policy_and_config()
	test_pe_parser()
	test_cityhash64()
	test_shaderpack()
	test_texture_formats()
	test_pipeline_cache()

	if len(track.allocation_map) > 0 {
		fmt.eprintf("\nFAIL: %d memory leaks detected!\n", len(track.allocation_map))
		for _, entry in track.allocation_map {
			fmt.eprintf("  - %d bytes @ %v\n", entry.size, entry.location)
		}
		os.exit(1)
	}
	if len(track.bad_free_array) > 0 {
		fmt.eprintf("\nFAIL: %d bad frees detected!\n", len(track.bad_free_array))
		for bf in track.bad_free_array {
			fmt.eprintf("  - %p @ %v\n", bf.memory, bf.location)
		}
		os.exit(1)
	}
	fmt.println("ALL ODIN PHASE 1 TESTS PASSED (0 leaks, 0 bad frees)")
}
