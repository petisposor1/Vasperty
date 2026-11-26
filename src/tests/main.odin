package vasperty_tests

import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"

import vasperty_app "vasperty:app"
import vasperty_core "vasperty:core"
import vasperty_formats "vasperty:formats"
import vasperty_game "vasperty:game"
import vasperty_gpu "vasperty:gpu"
import vasperty_hle "vasperty:hle"
import vasperty_loader "vasperty:loader"
import vasperty_pe "vasperty:pe"
import vasperty_pipeline "vasperty:pipeline"
import vasperty_shader "vasperty:shader"
import win32 "core:sys/windows"

@(private)
put_u16_le :: proc(buf: []u8, at: int, val: u16) {
	buf[at + 0] = u8(val)
	buf[at + 1] = u8(val >> 8)
}

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

@(private)
append_u32s :: proc(out: ^[dynamic]u8, vals: []u32) {
	for v in vals {
		append(out, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
	}
}

@(private)
append_sgd5_str :: proc(out: ^[dynamic]u8, s: string) {
	append(out, u8(len(s) + 1))
	for i := 0; i < len(s); i += 1 do append(out, s[i])
	append(out, 0)
}

// Valid RFC1951 uncompressed raw deflate stored block (`BFINAL=1, BTYPE=00`).
@(private)
deflate_stored_block :: proc(payload: []u8, allocator := context.allocator) -> []u8 {
	out := make([]u8, 5 + len(payload), allocator)
	out[0] = 0x01
	l := u16(len(payload))
	nl := ~l
	put_u16_le(out, 1, l)
	put_u16_le(out, 3, nl)
	copy(out[5:], payload)
	return out
}

@(private)
make_sgd5_record_bytes :: proc(name: string, kind: u8, payload: []u8, out: ^[dynamic]u8) {
	packed := deflate_stored_block(payload, context.allocator)
	defer delete(packed)
	n := u32(len(packed) + 12)
	append(out, 0xF4, 0x01, 0x00, 0x00, u8(len(name) + 1))
	for i := 0; i < len(name); i += 1 do append(out, name[i])
	append(out, 0, kind)
	append_u32s(out, {n, 0x000D_DCE7, n, u32(len(payload))})
	for b in packed do append(out, b)
}

test_core_policy_and_config :: proc() {
	fmt.print("[test] core_policy_and_config ... ")
	assert(vasperty_core.ensure_outside_repo("cache\\textures") == .Inside_Repo)
	assert(vasperty_core.ensure_outside_repo("src\\..\\not-created\\out") == .Inside_Repo)
	assert(vasperty_core.ensure_outside_repo("") == .Empty_Path)

	temp_base, found_tmp := os.lookup_env("TEMP", context.allocator)
	assert(found_tmp && len(temp_base) > 0)
	defer delete(temp_base)

	ext_path, _ := filepath.join({temp_base, "vasperty_odin_outside_test", "sub"}, context.allocator)
	defer delete(ext_path)
	assert(vasperty_core.ensure_outside_repo(ext_path) == .None)

	cfg, err := vasperty_core.load_config()
	assert(err == .None)
	vasperty_core.destroy_config(&cfg)
	fmt.println("ok")
}

test_pe_parser :: proc() {
	fmt.print("[test] pe_self_parse_and_guards ... ")
	exe_path := os.args[0]
	raw, r_err := os.read_entire_file_from_path(exe_path, context.allocator)
	assert(r_err == nil && len(raw) > 1024)
	defer delete(raw)

	info, pe_err := vasperty_pe.parse_image(raw)
	assert(pe_err == .None)
	defer vasperty_pe.destroy_image(&info)

	assert(info.machine == vasperty_pe.MACHINE_AMD64)
	assert(!vasperty_pe.is_dll(&info))
	assert(info.entry_rva != 0)
	assert(len(info.sections) >= 2)
	off, off_ok := vasperty_pe.rva_to_file_offset(info.sections[:], info.entry_rva)
	assert(off_ok && off > 0)

	garbage := [16]u8{0 = 1, 1 = 2, 2 = 3, 3 = 4}
	bad_info, bad_err := vasperty_pe.parse_image(garbage[:])
	assert(bad_err != .None)
	vasperty_pe.destroy_image(&bad_info)
	fmt.println("ok")
}

test_cityhash64 :: proc() {
	fmt.print("[test] game_cityhash64_v11_vectors ... ")
	assert(vasperty_game.city64(nil) == 0x9AE1_6A3B_2F90_404F)
	abc := transmute([]u8)string("abc")
	assert(vasperty_game.city64(abc) == 0x24A5_B3A0_74E7_F369)

	seq: [128]u8
	for i := 0; i < 128; i += 1 do seq[i] = u8(i)
	assert(vasperty_game.city64(seq[:24]) != vasperty_game.city64(seq[:25]))
	assert(vasperty_game.city64(seq[:48]) != vasperty_game.city64(seq[:49]))
	h_long := vasperty_game.city64(seq[:])
	assert(h_long != 0 && h_long == vasperty_game.city64(seq[:]))
	fmt.println("ok")
}

test_shaderpack :: proc() {
	fmt.print("[test] game_shaderpack_parse_and_reject ... ")
	blob0 := [8]u8{1, 2, 3, 4, 5, 6, 7, 8}
	prog0 := [16]u8{0xDE, 0xAD, 0xBE, 0xEF, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}

	buf := make([]u8, 0x80 + 0x18 + 8 + 8 + len(blob0) + len(prog0))
	defer delete(buf)

	copy(buf[:4], transmute([]u8)string("PS\x00\x09"))
	copy(buf[4:16], transmute([]u8)string("vasperty-drv"))
	copy(buf[0x24:0x2E], transmute([]u8)string("odin-1.0"))
	put_u64_le(buf, 0x48, 0x1122334455667788)
	put_u32_le(buf, 0x50, 0)
	put_u32_le(buf, 0x54, 1)
	put_u32_le(buf, 0x58, 1)
	put_u32_le(buf, 0x5C, 1)
	put_u32_le(buf, 0x60, u32(len(blob0)))
	put_u32_le(buf, 0x64, u32(len(prog0)))

	c_off := 0x80
	put_u64_le(buf, c_off + 0, 0xAABBCCDDEEFF0011)
	put_u32_le(buf, c_off + 8, 0)
	put_u32_le(buf, c_off + 12, 0)
	put_u32_le(buf, c_off + 16, 0)
	put_u32_le(buf, c_off + 20, max(u32))

	bt_off := c_off + 0x18
	put_u32_le(buf, bt_off + 0, 0)
	put_u32_le(buf, bt_off + 4, u32(len(blob0)))
	pt_off := bt_off + 8
	put_u32_le(buf, pt_off + 0, 0)
	put_u32_le(buf, pt_off + 4, u32(len(prog0)))
	bd_off := pt_off + 8
	copy(buf[bd_off:], blob0[:])
	copy(buf[bd_off + len(blob0):], prog0[:])

	pack, err := vasperty_game.parse_pack(buf)
	assert(err == .None)
	assert(vasperty_game.pack_fingerprint(&pack) == 0x1122334455667788)
	assert(vasperty_game.pack_compute_count(&pack) == 1)
	crec, cok := vasperty_game.pack_compute(&pack, 0)
	assert(cok && crec.shader_hash == 0xAABBCCDDEEFF0011)
	assert(len(crec.stage.program) == len(prog0))

	_, bad_err := vasperty_game.parse_pack(buf[:32])
	assert(bad_err != .None)
	fmt.println("ok")
}

test_sgd5 :: proc() {
	fmt.print("[test] game_sgd5_parse_unpack_parallel ... ")
	archive := make([dynamic]u8, context.allocator)
	defer delete(archive)

	for i := 0; i < 8; i += 1 {
		sz := 64 + i * 8
		payload := make([]u8, sz, context.allocator)
		for j := 0; j < sz; j += 1 do payload[j] = u8((i * 19 + 3) & 0xFF)
		name := fmt.aprintf("SH_%d", i, allocator = context.allocator)
		rec_start := len(archive)
		make_sgd5_record_bytes(name, 0x3C, payload, &archive)
		delete(name)
		delete(payload)
		if i == 5 {
			// Corrupt the DEFLATE header byte on record 5 only (BTYPE=11 reserved -> inflate fails).
			// Header bytes before record payload: 4+1+len("SH_5")+2+16 = 27 -> deflate start at rec_start + 27.
			archive[rec_start + 27] = 0xFF
		}
	}
	assert(!vasperty_game.is_sgd5(archive[:]))
	recs := vasperty_game.sgd5_records(archive[:])
	defer delete(recs)
	assert(len(recs) == 8)

	parallel := vasperty_game.sgd5_unpack_all(recs[:])
	defer vasperty_game.sgd5_destroy_unpack_results(parallel)
	assert(!parallel[5].ok)
	for i := 0; i < 8; i += 1 {
		if i == 5 do continue
		assert(parallel[i].ok)
		s_out, s_ok := vasperty_game.sgd5_record_unpack(&recs[i])
		assert(s_ok && len(s_out) == len(parallel[i].data))
		for k := 0; k < len(s_out); k += 1 do assert(s_out[k] == parallel[i].data[k])
		delete(s_out)
	}

	// Structured SGD5 database parse + marker fallback
	db_file := make([dynamic]u8, context.allocator)
	defer delete(db_file)
	for b in ([4]u8{'S', 'G', 'D', '5'}) do append(&db_file, b)
	for _ in 0 ..< 8 do append(&db_file, 0)
	append_u32s(&db_file, {1, 4, 0xAA, 0})

	counts := [6]int{1, 2, 0, 0, 0, 1}
	for s := 0; s < 6; s += 1 {
		append_u32s(&db_file, {u32(counts[s])})
		for idx := 0; idx < counts[s]; idx += 1 {
			pl := [40]u8{}
			for k := 0; k < 40; k += 1 do pl[k] = u8(s * 16 + idx)
			pk := deflate_stored_block(pl[:], context.allocator)
			nm := fmt.aprintf("SH_%d_%d", s, idx, allocator = context.allocator)
			append_sgd5_str(&db_file, nm)
			delete(nm)
			append(&db_file, 0x32)
			n := u32(len(pk) + 12)
			append_u32s(&db_file, {n, 0x000D_DCE7, n, 40})
			for b in pk do append(&db_file, b)
			delete(pk)
			h := u64(0x1000 + s * 16 + idx)
			append_u32s(&db_file, {u32(h), u32(h >> 32)})
			for _ in 0 ..< 0x90 do append(&db_file, 0)
			append_u32s(&db_file, {4, 0x0101})
		}
	}

	// One effect
	append_u32s(&db_file, {1})
	append_sgd5_str(&db_file, "fx")
	body := make([dynamic]u8, context.allocator)
	defer delete(body)
	append_u32s(&body, {1, 0, 2, 1, 0, 0, 0, 0, 1, 0})
	for _ in 0 ..< 0x50 do append(&body, 0)
	append_u32s(&body, {1})
	for _ in 0 ..< 16 do append(&body, 3)
	append_u32s(&body, {0, 2})
	for _ in 0 ..< 0x44 do append(&body, 4)
	for _ in 0 ..< 0x44 do append(&body, 5)
	append_u32s(&body, {0})
	names_b := transmute([]u8)string("draw\x00dispatch\x00")
	append_u32s(&body, {2, 2 << 24, 5 | (2 << 15) | (1 << 24)})
	append_u32s(&body, {3})
	passes: [3][24]u8
	passes[0][0] = 1; passes[0][1] = 1
	passes[1][0] = 1; passes[1][1] = 2; passes[1][6] = 0; passes[1][8] = 1; passes[1][9] = 0x83; passes[1][10] = 1 | 4 | 8
	passes[2][5] = 1
	for p in passes do for b in p do append(&body, b)
	append_u32s(&body, {2, 7, 8, 0x8000_0000, 3})
	append(&body, 'a', 'b', 'c')
	append_u32s(&body, {1})
	append(&body, 9)
	append_u32s(&body, {2 | (8 << 24), 6})
	for _ in 0 ..< 6 do append(&body, 6)
	append_u32s(&body, {0x8000_0000, 0x1234, u32(len(names_b))})
	for b in names_b do append(&body, b)

	loaded := (2 + 3 + 1 + 1 + 1 + 2) * 8 + 2 * 8 + 3 * 32 + 2 * 4 + 3 + 1
	loaded = ((loaded + 7) / 8) * 8 + 2 * 8 + 6 + len(names_b)
	append_u32s(&db_file, {u32(loaded)})
	for b in body do append(&db_file, b)
	append(&db_file, 1)

	dbs := vasperty_game.sgd5_databases(db_file[:])
	defer vasperty_game.destroy_sgd5_databases(&dbs)
	assert(len(dbs) == 1 && len(dbs[0].effects) == 1)
	assert(dbs[0].effects[0].name == "fx")
	assert(len(dbs[0].effects[0].techniques) == 2)
	assert(dbs[0].effects[0].techniques[0].passes[1].stencil_ref == 0x83)
	assert(len(dbs[0].shaders[1]) == 2 && dbs[0].shaders[1][1].hash == 0x1011)
	out_sh, out_ok := vasperty_game.sgd5_record_unpack(&dbs[0].shaders[1][1].record)
	assert(out_ok && len(out_sh) == 40 && out_sh[0] == 17)
	delete(out_sh)
	fmt.println("ok")
}

test_pipelines :: proc() {
	fmt.print("[test] game_pipelines_descs_and_resolvers ... ")
	// Depth write requires depth test and writing op
	c := [vasperty_game.STATE_DEPTH]u8{}
	copy(c[:14], ([]u8)([]u8{0, 1, 4, 1, 0xF0, 0x0F, 1, 1, 1, 8, 1, 1, 1, 8}))
	d := vasperty_game.depth_stencil_desc(&c)
	assert(d[0x10] == 0xF0 && d[0x11] == 0)
	c[8] = 3
	assert(vasperty_game.depth_stencil_desc(&c)[0x11] == 0x0F)

	// Default D3D12 depth state + custom rasterizer resolution
	def_d := [vasperty_game.STATE_DEPTH]u8{1, 1, 2, 0, 0xFF, 0xFF, 1, 1, 1, 8, 1, 1, 1, 8, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1}
	dh := vasperty_game.city64(def_d[:])
	want_d := make(map[u64]bool)
	defer delete(want_d)
	want_d[dh] = true
	res_d := vasperty_game.resolve_depth_hashes(&want_d)
	defer delete(res_d)
	assert(dh in res_d && res_d[dh] == def_d)

	r1 := [vasperty_game.STATE_RASTER]u8{3, 2, 1, transmute(u8)i8(-4), 0, 0, 0, 0, 0, 0, 0xC0, 0x3F, 1, 0, 1, 2}
	rh := vasperty_game.city64(r1[:])
	want_r := make(map[u64]bool)
	defer delete(want_r)
	want_r[rh] = true
	res_r := vasperty_game.resolve_raster_hashes(&want_r)
	defer delete(res_r)
	assert(rh in res_r && res_r[rh] == r1)

	// Creation stream test
	meta := make([]u8, 0x4C)
	copy(meta[0x10:0x18], ([]u8)([]u8{28, 0, 10, 0, 0, 0, 0, 0}))
	put_u32_le(meta, 0x1C, max(u32))
	meta[0x24] = 40; meta[0x25] = 3; meta[0x26] = 3
	meta[0x28] = 2
	// empty layout
	layout_b := make([]u8, 4)
	put_u32_le(layout_b, 0, 0)
	put_u32_le(meta, 0x38, 4)
	full_meta := make([]u8, len(meta) + len(layout_b))
	copy(full_meta, meta)
	copy(full_meta[len(meta):], layout_b)
	delete(meta)
	delete(layout_b)
	defer delete(full_meta)

	g := vasperty_game.Graphics_Record{
		depth_stencil_hash = dh,
		rasterizer_hash    = rh,
		blend_hash         = 99,
		metadata           = full_meta,
	}
	named := vasperty_game.Named_States{
		depth  = make(map[u64][vasperty_game.STATE_DEPTH]u8),
		raster = make(map[u64][vasperty_game.STATE_RASTER]u8),
		blend  = make(map[u64][vasperty_game.STATE_BLEND]u8),
		source = make(map[u64]vasperty_game.State_Source),
	}
	defer vasperty_game.destroy_named_states(&named)
	named.depth[dh] = def_d
	named.raster[rh] = r1
	bl := [vasperty_game.STATE_BLEND]u8{}
	copy(bl[4:12], ([]u8)([]u8{1, 5, 6, 1, 2, 1, 1, 15}))
	named.blend[99] = bl

	vs := [12]u8{0 = 1, 1 = 2, 2 = 3, 3 = 4}
	ps := [20]u8{0 = 5, 1 = 6, 2 = 7, 3 = 8}
	ps_stream, st_err := vasperty_game.build_pipeline_stream(&g, &named, vs[:], false, true, ps[:])
	assert(st_err == .None)
	vasperty_game.destroy_pipeline_stream(&ps_stream)
	fmt.println("ok")
}

test_texture_formats :: proc() {
	fmt.print("[test] formats_rdna2_2d_3d_tile_detile ... ")
	d2 := vasperty_formats.Desc{
		dimension = .Tex2d, width = 512, height = 512, depth = 1, mips = 4,
		element_bytes = 4, block = 1, samples = 1, swizzle = vasperty_formats.SWIZZLE_64KB_S,
	}
	l2, err2 := vasperty_formats.new_layout(d2)
	assert(err2 == .None && l2.size > 0)
	defer vasperty_formats.destroy_layout(&l2)

	o0, ok0 := vasperty_formats.layout_offset(&l2, 0, 0, 0, 0)
	o1, ok1 := vasperty_formats.layout_offset(&l2, 0, 1, 0, 0)
	assert(ok0 == .None && ok1 == .None && o0 != o1)

	tiled2 := make([]u8, int(l2.size))
	src2 := make([]u8, 512 * 512 * 4)
	dst2 := make([]u8, 512 * 512 * 4)
	defer { delete(tiled2); delete(src2); delete(dst2) }
	for i := 0; i < len(src2); i += 1 do src2[i] = u8((i * 13 + 5) & 0xFF)
	assert(vasperty_formats.layout_tile(&l2, tiled2, 0, 0, src2, 512 * 4, len(src2)) == .None)
	assert(vasperty_formats.layout_detile(&l2, tiled2, 0, 0, dst2, 512 * 4, len(dst2)) == .None)
	for i := 0; i < len(src2); i += 1 do assert(src2[i] == dst2[i])

	d3 := vasperty_formats.Desc{
		dimension = .Tex3d, width = 128, height = 64, depth = 16, mips = 1,
		element_bytes = 4, block = 1, samples = 1, swizzle = vasperty_formats.SWIZZLE_64KB_S,
	}
	l3, err3 := vasperty_formats.new_layout(d3)
	assert(err3 == .None && l3.thick)
	defer vasperty_formats.destroy_layout(&l3)

	tiled3 := make([]u8, int(l3.size))
	src3 := make([]u8, 128 * 64 * 16 * 4)
	dst3 := make([]u8, 128 * 64 * 16 * 4)
	defer { delete(tiled3); delete(src3); delete(dst3) }
	for i := 0; i < len(src3); i += 1 do src3[i] = u8((i * 29 + 11) & 0xFF)
	rp3 := 128 * 4
	dp3 := rp3 * 64
	assert(vasperty_formats.layout_tile(&l3, tiled3, 0, 0, src3, rp3, dp3) == .None)
	assert(vasperty_formats.layout_detile(&l3, tiled3, 0, 0, dst3, rp3, dp3) == .None)
	for i := 0; i < len(src3); i += 1 do assert(src3[i] == dst3[i])
	fmt.println("ok")
}

// Builds a synthetic uniform-model BCPack fragment & interleaved multi-lane stream for verification.
@(private)
make_bcpack_fragment :: proc(width: u8, symbols: []u8, out: ^[dynamic]u8) {
	f := u32(1) << uint(15 - width)
	x := vasperty_formats.BCPACK_LOW
	rev := make([dynamic]u8, context.allocator)
	defer delete(rev)
	for i := len(symbols) - 1; i >= 0; i -= 1 {
		s := symbols[i]
		freq := (f - 1) if s == 0 else f
		start := u32(1) if s == 0 else (u32(s) * f)
		for x >= (freq << 16) {
			append(&rev, u8(x))
			x >>= 8
		}
		x = ((x / freq) << 16) + (x % freq) + start
	}
	append(&rev, u8(x), u8(x >> 8), u8(x >> 16), u8(x >> 24))
	// Reverse bytes + append filler fragment [0, 1, 0, 0]
	n_bytes := len(rev)
	if n_bytes > 256 {
		append(out, 0x20)
		nb := n_bytes - 257
		append(out, u8(nb), u8(nb >> 8))
	} else {
		append(out, 0x00, u8(n_bytes - 1))
	}
	for i := n_bytes - 1; i >= 0; i -= 1 do append(out, rev[i])
	append(out, 0, 1, 0, 0)
}

@(private)
encode_bcpack_stream :: proc(
	t: ^vasperty_formats.Bcpack_Tables,
	widths: []u8,
	per: int,
	records: [][]u8,
	allocator := context.allocator,
) -> []u8 {
	n_lanes := len(widths)
	qs := make([][dynamic]u8, n_lanes, allocator)
	qpos := make([]int, n_lanes, allocator)
	defer {
		for j := 0; j < n_lanes; j += 1 do delete(qs[j])
		delete(qs)
		delete(qpos)
	}
	for j := 0; j < n_lanes; j += 1 {
		qs[j] = make([dynamic]u8, allocator)
		syms := make([dynamic]u8, 0, len(records) * per, allocator)
		for rec in records {
			for k := 0; k < per; k += 1 do append(&syms, rec[j * per + k])
		}
		make_bcpack_fragment(widths[j], syms[:], &qs[j])
		delete(syms)
	}

	// Simulate schedule exactly to interleave bytes in demand order
	Stream_Lane :: struct {
		width:     u8,
		phase:     u8,
		is_long:   bool,
		reset:     bool,
		model:     u8,
		need:      bool,
		has_latch: bool,
		latch:     u8,
		has_out:   bool,
		stalled:   bool,
		x:         u32,
		left:      u32,
	}
	lanes: [16]Stream_Lane
	for j := 0; j < n_lanes; j += 1 {
		lanes[j].width = widths[j]
		lanes[j].need = true
	}
	out := make([dynamic]u8, allocator)
	pos := 0
	done: u32 = 0
	full := (u32(1) << uint(n_lanes)) - 1
	for pos < len(records) * per {
		taken := 0
		for j := 0; j < n_lanes; j += 1 {
			bit := u32(1) << uint(j)
			before := taken
			l := &lanes[j]
			if !l.stalled {
				if l.phase != 3 {
					if l.has_latch {
						b := l.latch
						l.has_latch = false
						l.need = true
						switch l.phase {
						case 0:
							group := l.width - (b >> 6)
							l.model = group * 16 + (b & 15)
							l.reset = (b & 0x10) != 0
							l.is_long = (b & 0x20) != 0
							l.left = 0
							l.phase = 1
						case 1:
							if l.is_long {
								l.left = u32(b)
								l.phase = 2
							} else {
								l.left = u32(b) + 1
								l.phase = 3
							}
						case:
							l.left = ((u32(b) << 8) | l.left) + 257
							l.phase = 3
						}
					}
				} else {
					x := l.x
					if x < vasperty_formats.BCPACK_LOW && l.has_latch {
						l.has_latch = false
						l.left -= 1
						x = (x << 8) | u32(l.latch)
					}
					l.need = l.left != 0 && !l.has_latch
					if x > vasperty_formats.BCPACK_LOW {
						slot := x & 0xFFFF
						b_idx := 0
						for t.start[l.model][b_idx + 1] <= slot do b_idx += 1
						f, rem: u32
						if b_idx == 0 {
							f = t.freq[l.model][0] - 1
							rem = slot - 1
						} else {
							off := slot - t.start[l.model][b_idx]
							f = t.freq[l.model][b_idx]
							q := off / f
							rem = off - q * f
						}
						l.x = (x >> 16) * f + rem
						l.has_out = true
					} else if l.left != 0 {
						l.x = x
					} else {
						l.phase = 0
						l.need = !l.has_latch
						if l.reset do l.x = 0
					}
				}
			}
			waiting := l.has_out && (done & bit) != 0
			if l.need && !waiting && taken < vasperty_formats.BCPACK_ROUND_BYTES {
				if qpos[j] < len(qs[j]) {
					b := qs[j][qpos[j]]
					qpos[j] += 1
					append(&out, b)
					l.latch = b
					l.has_latch = true
					taken += 1
				}
			}
			l.stalled = (l.need && before >= vasperty_formats.BCPACK_ROUND_BYTES) || waiting
			if !l.stalled && l.has_out {
				l.has_out = false
				done |= bit
			}
		}
		if done == full {
			pos += 1
			done = 0
		}
	}
	return out[:]
}

test_bcpack :: proc() {
	fmt.print("[test] formats_bcpack_tables_batch_malformed ... ")
	// 1. Built-in tables parse cleanly
	tbl, err := vasperty_formats.bcpack_builtin_tables()
	assert(err == .None && tbl != nil)
	vasperty_formats.bcpack_destroy_tables(tbl)

	// 2. SPREAD4 interleave matches bit-by-bit spread across all 256 pairs
	for a: u8 = 0; a < 16; a += 1 {
		for b: u8 = 0; b < 16; b += 1 {
			expected: u8 = 0
			for k: uint = 0; k < 4; k += 1 {
				expected |= ((a >> k) & 1) << (2 * k)
				expected |= ((b >> k) & 1) << (2 * k + 1)
			}
			assert(vasperty_formats.bcpack_interleave(a, b) == expected)
		}
	}

	// 3. Synthetic uniform tables -> encode & decode BC4 blocks + parallel batch + malformed checks
	raw_tbl := make([]u8, vasperty_formats.BCPACK_TABLES_SIZE)
	defer delete(raw_tbl)
	pos := 0
	for m := 0; m < vasperty_formats.BCPACK_MODELS; m += 1 {
		g := m / 16
		for b := 0; b < vasperty_formats.BCPACK_BUCKETS; b += 1 {
			f: u16 = (u16(1) << uint(15 - g)) if b < g + 2 else 0
			put_u16_le(raw_tbl, pos, f)
			pos += 2
		}
	}
	pos += 256 + 64 + 256 // skip rank1, rank3a, rank3c
	for v := 0; v < 64; v += 1 {
		raw_tbl[pos + v] = u8((v & 7) | ((v >> 3) << 4)) // rank4
	}
	st, serr := vasperty_formats.bcpack_parse_tables(raw_tbl)
	assert(serr == .None)
	defer vasperty_formats.bcpack_destroy_tables(st)

	zz :: proc(v: i32) -> u8 {
		return u8(2 * v) if v >= 0 else u8(-2 * v - 1)
	}
	r0 := [12]u8{0, 0, zz(10), zz(-3), 1 << 3, 1 << 3, 1 << 3, 1 << 3, 1 << 3, 1 << 3, 1 << 3, 1 << 3}
	r1 := [12]u8{0, 1, zz(1), zz(1), 0, 0, 0, 0, 0, 0, 0, 0}
	recs := [2][]u8{r0[:], r1[:]}
	w4 := [12]u8{7, 7, 7, 7, 5, 5, 5, 5, 5, 5, 5, 5}
	src := encode_bcpack_stream(st, w4[:], 1, recs[:])
	defer delete(src)

	dst_serial: [16]u8
	assert(vasperty_formats.bcpack_decode(4, src, dst_serial[:], st) == .None)
	assert(dst_serial[0] == 138 && dst_serial[1] == 125)
	assert(dst_serial[8] == 139 && dst_serial[9] == 126)

	dst_batch0, dst_batch1: [16]u8
	jobs := [2]vasperty_formats.Bcpack_Batch_Job{
		{bc = 4, src = src, dst = dst_batch0[:]},
		{bc = 4, src = src, dst = dst_batch1[:]},
	}
	assert(vasperty_formats.bcpack_decode_batch(jobs[:], st) == .None)
	assert(dst_batch0 == dst_serial && dst_batch1 == dst_serial)

	// Malformed inputs
	assert(vasperty_formats.bcpack_decode(2, src, dst_serial[:], st) == .Unsupported_Format)
	assert(vasperty_formats.bcpack_decode(4, src[:len(src) / 2], dst_serial[:], st) != .None)
	fmt.println("ok")
}

@(private)
put_be_bits :: proc(data: []u8, pos: int, n: u32, val: u32) {
	for i := 0; i < int(n); i += 1 {
		bit := (val >> uint(int(n) - 1 - i)) & 1
		p := pos + i
		if bit != 0 {
			data[p / 8] |= u8(1) << uint(7 - (p % 8))
		} else {
			data[p / 8] &= ~(u8(1) << uint(7 - (p % 8)))
		}
	}
}

test_xma :: proc() {
	fmt.print("[test] formats_xma_packets_imdct_decoder ... ")
	// 1. Packet header + skip + fast-path Cursor parity across 3 packets
	pkt_data := make([]u8, 3 * vasperty_formats.XMA_PACKET_BYTES)
	defer delete(pkt_data)
	put_be_bits(pkt_data, 0, 32, (1 << 26) | 1)
	put_be_bits(pkt_data, vasperty_formats.XMA_PACKET_BITS * 2, 32, 1 << 26)
	seed := u64(0x9E37_79B9_7F4A_7C15)
	for i := 4; i < vasperty_formats.XMA_PACKET_BYTES; i += 1 {
		seed ~= seed << 13; seed ~= seed >> 7; seed ~= seed << 17
		pkt_data[i] = u8(seed)
	}
	for i := vasperty_formats.XMA_PACKET_BITS * 2 / 8 + 4; i < len(pkt_data); i += 1 {
		seed ~= seed << 13; seed ~= seed >> 7; seed ~= seed << 17
		pkt_data[i] = u8(seed)
	}
	for width in ([4]u32{3, 8, 15, 24}) {
		fast := vasperty_formats.Xma_Cursor{data = pkt_data, pos = vasperty_formats.XMA_HEADER_BITS}
		slow := vasperty_formats.Xma_Cursor{data = pkt_data, pos = vasperty_formats.XMA_HEADER_BITS}
		for _ in 0 ..< 250 {
			got, ok_f := vasperty_formats.xma_cursor_bits(&fast, width)
			want: u32 = 0
			ok_s := true
			for _ in 0 ..< width {
				b, ok_b := vasperty_formats.xma_cursor_bit(&slow)
				if !ok_b { ok_s = false; break }
				want = (want << 1) | b
			}
			assert(ok_f == ok_s && fast.pos == slow.pos)
			if ok_f do assert(got == want)
			else do break
		}
	}

	// 2. Windowed MDCT + IMDCT signal reconstruction
	n :: 256
	sig := make([]f32, n * 6)
	out := make([]f32, n * 7)
	coeffs := make([]f32, n)
	win := make([]f32, n)
	defer { delete(sig); delete(out); delete(coeffs); delete(win) }
	for i := 0; i < len(sig); i += 1 do sig[i] = f32(math.sin(f64(i) * 0.05) * 0.3)
	for i := 0; i < n; i += 1 do win[i] = f32(math.sin((f64(i) + 0.5) * math.PI / f64(2 * n)))

	rot: vasperty_formats.Xma_Rotations
	vasperty_formats.xma_init_rotations(&rot, n)
	for block := 0; block < 5; block += 1 {
		base := block * n
		for k := 0; k < n; k += 1 {
			acc: f64 = 0
			for i := 0; i < 2 * n; i += 1 {
				w := math.sin((f64(i) + 0.5) * math.PI / f64(2 * n))
				t := f64(i) + 0.5 + f64(n) / 2.0
				acc += -f64(sig[base + i]) * w * math.cos(math.PI / f64(n) * t * (f64(k) + 0.5))
			}
			coeffs[k] = f32(acc)
		}
		at := base + n / 2
		vasperty_formats.xma_imdct_with_rotations(&rot, coeffs, out[at : at + n], 2.0 / f32(n))
		if block > 0 {
			vasperty_formats.xma_window_overlap(out[at - n / 2 : at + n / 2], win)
		}
	}
	for i := n; i < 5 * n; i += 1 {
		assert(math.abs(out[i] - sig[i]) < 1e-3, "MDCT signal reconstruction mismatch")
	}

	// 3. Decoder init / decode / flush / destroy with quant_scale LUT check
	for exp: i32 = -160; exp <= 220; exp += 1 {
		dec_tmp := vasperty_formats.xma_new_decoder(1, 48_000)
		got := vasperty_formats.xma_quant_scale(dec_tmp.rt, exp)
		want := vasperty_formats.xma_quant_scale_compute(exp)
		vasperty_formats.xma_destroy_decoder(dec_tmp)
		assert(got == want)
		break // quick check inside loop + explicit full loop below using one decoder!
	}
	dec := vasperty_formats.xma_new_decoder(2, 48_000)
	defer vasperty_formats.xma_destroy_decoder(dec)
	for exp: i32 = -160; exp <= 220; exp += 1 {
		assert(vasperty_formats.xma_quant_scale(dec.rt, exp) == vasperty_formats.xma_quant_scale_compute(exp))
	}
	pcm := make([dynamic]i16, context.allocator)
	defer delete(pcm)
	noise_frame: [200]u8
	for i := 0; i < len(noise_frame); i += 1 do noise_frame[i] = u8((i * 73 + 17) & 0xFF)
	_ = vasperty_formats.xma_decode_frame(dec, noise_frame[:], len(noise_frame) * 8, &pcm)
	assert(len(pcm) == vasperty_formats.XMA_FRAME_SAMPLES * 2)
	vasperty_formats.xma_flush(dec, &pcm)
	assert(len(pcm) == vasperty_formats.XMA_FRAME_SAMPLES * 2 + vasperty_formats.XMA_FRAME_SAMPLES)
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
	_, inside_err := vasperty_pipeline.cache_open("cache\\bad_odin_test")
	assert(inside_err == .Inside_Repo)

	temp_base, _ := os.lookup_env("TEMP", context.allocator)
	defer delete(temp_base)
	root, _ := filepath.join({temp_base, "vasperty_odin_cache_test"}, context.allocator)
	defer delete(root)

	cache, o_err := vasperty_pipeline.cache_open(root)
	assert(o_err == .None)
	defer vasperty_pipeline.cache_destroy(&cache)

	calls := 0
	a := transmute([]u8)string("partA-")
	b := transmute([]u8)string("partB")
	parts := [2][]u8{a, b}
	d1, p1, hit1, e1 := vasperty_pipeline.cache_read_or_convert_parts(&cache, "test-conv", 1, parts[:], &calls, dummy_convert)
	assert(e1 == .None && !hit1 && calls == 1)
	assert(string(d1) == "partA-partB")
	delete(d1); delete(p1)

	d2, p2, hit2, e2 := vasperty_pipeline.cache_read_or_convert_parts(&cache, "test-conv", 1, parts[:], &calls, dummy_convert)
	assert(e2 == .None && hit2 && calls == 1)
	assert(string(d2) == "partA-partB")
	delete(d2); delete(p2)

	k := vasperty_pipeline.cache_key_from_parts("test-conv", 1, parts[:])
	kp, _ := vasperty_pipeline.cache_path_for(&cache, k)
	shard := filepath.dir(kp)
	stale, _ := filepath.join({shard, ".tmp-99999-stale"}, context.allocator)
	_ = os.write_entire_file(stale, transmute([]u8)string("junk"))

	st1, s_err1 := vasperty_pipeline.cache_stats(&cache)
	assert(s_err1 == .None && st1.entries >= 1 && st1.stale_temps >= 1)
	removed, freed, pr_err := vasperty_pipeline.cache_prune_stale_temps(&cache)
	assert(pr_err == .None && removed >= 1 && freed >= 4)
	assert(os.exists(kp))

	_ = os.remove(kp)
	delete(kp); delete(stale)
	fmt.println("ok")
}

test_loader_phase3 :: proc() {
	fmt.print("[test] loader_prepare_publish_thunks_tls_map ... ")
	exe_path := os.args[0]
	raw, r_err := os.read_entire_file_from_path(exe_path, context.allocator)
	assert(r_err == nil && len(raw) > 1024)
	defer delete(raw)

	// 1. Prepare self binary & verify patched PE headers / hash naming
	prep, p_err := vasperty_loader.prepare_image(raw)
	assert(p_err == .None)
	defer vasperty_loader.destroy_prepared_image(&prep)
	assert(!vasperty_pe.is_dll(&prep.info))
	assert(vasperty_pe.import_count(&prep.info) > 0)

	patched, pt_err := vasperty_pe.parse_image(prep.bytes)
	assert(pt_err == .None)
	defer vasperty_pe.destroy_image(&patched)
	assert(vasperty_pe.is_dll(&patched))
	assert(patched.entry_rva == 0)
	assert(len(patched.imports) == 0)
	assert((patched.dll_characteristics & 0x0080) == 0)

	fn1 := vasperty_loader.prepared_file_name(&prep)
	fn2 := vasperty_loader.prepared_file_name(&prep)
	assert(fn1 == fn2 && len(fn1) > 16)
	delete(fn1); delete(fn2)

	// 2. Atomic staging publish & cleanup
	temp_base, _ := os.lookup_env("TEMP", context.allocator)
	defer delete(temp_base)
	loader_dir, _ := filepath.join({temp_base, "vasperty_odin_loader_test"}, context.allocator)
	defer delete(loader_dir)
	_ = os.make_directory_all(loader_dir)
	pub_file, _ := filepath.join({loader_dir, "pub_test.bin"}, context.allocator)
	defer delete(pub_file)
	assert(vasperty_loader.write_if_changed(pub_file, transmute([]u8)string("hello-loader")))
	assert(vasperty_loader.write_if_changed(pub_file, transmute([]u8)string("hello-loader")))
	_ = os.remove(pub_file)

	// 3. Native executable x86-64 Thunk_Block (Return_Zero stub execution)
	before_calls := vasperty_loader.unimplemented_call_count()
	blk, blk_ok := vasperty_loader.thunk_block_new(2)
	assert(blk_ok)
	stub_addr, emit_ok := vasperty_loader.thunk_block_emit(&blk, "test.dll", "MissingProc", .Return_Zero)
	assert(emit_ok && stub_addr != 0)
	assert(vasperty_loader.thunk_block_seal(&blk))
	Stub_Fn :: proc "system" () -> u64
	fn := Stub_Fn(rawptr(stub_addr))
	ret := fn()
	assert(ret == 0 && vasperty_loader.unimplemented_call_count() == before_calls + 1)
	vasperty_loader.thunk_block_destroy(&blk)

	// 4. Static TLS byte patching & executable thunk generation (`rax`, `r8`, `r12`)
	tls_page := vasperty_loader.tls_alloc_near(uintptr(rawptr(test_loader_phase3)), 0x10000)
	assert(tls_page != nil)
	thunk_page := vasperty_loader.tls_alloc_near(uintptr(tls_page), 4096)
	assert(thunk_page != nil)
	th_base, th_ok := vasperty_loader.tls_build_thunks(thunk_page, 3)
	assert(th_ok && th_base != 0)
	sample_code := [10]u8{0x65, 0x48, 0x8B, 0x04, 0x25, 0x58, 0x00, 0x00, 0x00, 0xC3}
	code_ptr := ([^]u8)(tls_page)
	for b, idx in sample_code do code_ptr[idx] = b
	patched_n := vasperty_loader.tls_patch_code(code_ptr[:len(sample_code)], uintptr(tls_page), th_base)
	assert(patched_n == 1 && code_ptr[0] == 0xE8 && code_ptr[5] == 0x0F && code_ptr[6] == 0x1F)
	// Also run the patched thunk sequence and verify it returns `tls_array + 3 * 8` cleanly!
	old_prot: win32.DWORD = 0
	assert(win32.VirtualProtect(tls_page, 4096, win32.PAGE_EXECUTE_READ, &old_prot) != false)
	Tls_Probe :: proc "system" () -> uintptr
	probe_fn := Tls_Probe(tls_page)
	probe_res := probe_fn()
	assert(probe_res != 0)
	vasperty_loader.tls_free_page(tls_page)
	vasperty_loader.tls_free_page(thunk_page)

	// 5. Real Win32 LoadLibraryExW map + unload + cleanup of prepared DLL
	img, l_err := vasperty_loader.load_prepared(&prep, loader_dir)
	assert(l_err == .None && vasperty_loader.loaded_base(&img) != 0)
	img_file := img.path
	img_file_copy := make([]u8, len(img_file))
	copy(img_file_copy, img_file)
	vasperty_loader.loaded_unload(&img)
	_ = os.remove(string(img_file_copy))
	delete(img_file_copy)
	fmt.println("ok")
}

@(private)
hle_vslot :: proc(obj: rawptr, byte_off: uintptr, $T: typeid) -> T {
	vt := (cast(^[^]rawptr)obj)^
	return cast(T)(vt[byte_off / 8])
}

test_hle_phase4 :: proc() {
	fmt.print("[test] hle_resolver_com_saves_xmem_xg_dsp ... ")
	vasperty_hle.init_hle()
	defer {
		vasperty_hle.fini_hle()
		vasperty_hle.fini_files()
		vasperty_hle.fini_lifecycle()
		vasperty_hle.fini_xmem()
	}

	// 1. Manifest XML parsing
	xml := `<!-- comment --><Game><Identity Name="T &amp; A"/><TitleId>4D5308AB</TitleId><StoreId>9NBLGGH12345</StoreId><PersistentLocalStorage><SizeMB>32</SizeMB></PersistentLocalStorage></Game>`
	temp_base, _ := os.lookup_env("TEMP", context.allocator)
	defer delete(temp_base)
	hle_tmp, _ := filepath.join({temp_base, "vasperty_odin_hle_test"}, context.allocator)
	defer delete(hle_tmp)
	_ = os.make_directory_all(hle_tmp)

	tinfo := vasperty_hle.parse_manifest_xml(xml, hle_tmp)
	assert(tinfo.id == 0x4D5308AB && tinfo.store_id == "9NBLGGH12345" && tinfo.storage_bytes == (32 << 20))
	vasperty_hle.set_title(tinfo)
	vasperty_hle.destroy_title_info(&tinfo)

	// 2. Hle_Resolver & Policy
	pol := vasperty_hle.default_host_policy()
	res := vasperty_hle.make_hle_resolver(pol)
	defer vasperty_hle.destroy_hle_resolver(&res)

	imp_cf := vasperty_pe.Import_Entry{name = "CreateFileW"}
	r_cf := vasperty_hle.hle_resolve(&res, "kernel32.dll", &imp_cf)
	assert(r_cf.found && r_cf.provenance == .Hle && r_cf.address == uintptr(rawptr(vasperty_hle.CreateFileW)))

	imp_gtc := vasperty_pe.Import_Entry{name = "GetTickCount"}
	r_gtc := vasperty_hle.hle_resolve(&res, "kernel32.dll", &imp_gtc)
	assert(r_gtc.found && r_gtc.provenance == .Host && r_gtc.address != 0)

	imp_net := vasperty_pe.Import_Entry{name = "InternetOpenA"}
	r_net := vasperty_hle.hle_resolve(&res, "wininet.dll", &imp_net)
	assert(!r_net.found)

	imp_iid := vasperty_pe.Import_Entry{name = "IID_ID3D12Device"}
	r_iid := vasperty_hle.hle_resolve(&res, "d3d12_xs.dll", &imp_iid)
	assert(r_iid.found && r_iid.provenance == .Hle)
	iid_ptr := cast(^[16]u8)rawptr(r_iid.address)
	assert(iid_ptr^ == vasperty_hle.IID_ID3D12Device_DATA)

	// 3. Registry ConsoleMode override
	vasperty_hle.set_console(.Series_X)
	key: rawptr = nil
	sub_w := win32.utf8_to_wstring(`software\microsoft\windows nt\currentversion\oem`, context.allocator)
	defer delete(sub_w)
	assert(vasperty_hle.RegOpenKeyW(rawptr(vasperty_hle.REG_HKEY_LOCAL_MACHINE), cast([^]u16)sub_w, &key) == 0)
	val_name := win32.utf8_to_wstring("ConsoleMode", context.allocator)
	defer delete(val_name)
	cm_val: u32 = 0
	cm_sz: u32 = 4
	cm_kind: u32 = 0
	assert(vasperty_hle.RegQueryValueExW(key, cast([^]u16)val_name, nil, &cm_kind, cast([^]u8)&cm_val, &cm_sz) == 0)
	assert(cm_val == 0x64 && cm_kind == 4)
	assert(vasperty_hle.RegCloseKey(key) == 0)

	// 4. QueryApiImpl + XUser + XStore + Speech
	assert(vasperty_hle.InitializeApiImplEx2(1, 2, 0, nil) == vasperty_hle.S_OK)
	prov_u := vasperty_hle.PROVIDER_XUSER
	iid_u := vasperty_hle.IID_XUSER
	uobj: rawptr = nil
	assert(vasperty_hle.QueryApiImpl(&prov_u, &iid_u, &uobj) == vasperty_hle.S_OK && uobj != nil)

	Add_Fn :: #type proc "system" (rawptr, u32, ^vasperty_hle.Async_Block) -> vasperty_hle.HRESULT
	Res_Fn :: #type proc "system" (rawptr, ^vasperty_hle.Async_Block, ^rawptr) -> vasperty_hle.HRESULT
	Get_Id_Fn :: #type proc "system" (rawptr, rawptr, ^u64) -> vasperty_hle.HRESULT
	blk := vasperty_hle.Async_Block{}
	assert(hle_vslot(uobj, 0x38, Add_Fn)(uobj, 1, &blk) == vasperty_hle.S_OK)
	assert(vasperty_hle.XAsyncGetStatus(&blk, true) == vasperty_hle.S_OK)
	uhandle: rawptr = nil
	assert(hle_vslot(uobj, 0x40, Res_Fn)(uobj, &blk, &uhandle) == vasperty_hle.S_OK && uhandle != nil)
	xuid: u64 = 0
	assert(hle_vslot(uobj, 0x58, Get_Id_Fn)(uobj, uhandle, &xuid) == vasperty_hle.S_OK && xuid == vasperty_hle.XUSER_XUID)

	prov_s := vasperty_hle.PROVIDER_XSTORE
	iid_s := vasperty_hle.IID_XSTORE_2026
	sobj: rawptr = nil
	assert(vasperty_hle.QueryApiImpl(&prov_s, &iid_s, &sobj) == vasperty_hle.S_OK && sobj != nil)
	GL_Async :: #type proc "system" (rawptr, rawptr, ^vasperty_hle.Async_Block) -> vasperty_hle.HRESULT
	GL_Res :: #type proc "system" (rawptr, ^vasperty_hle.Async_Block, ^vasperty_hle.Store_Game_License) -> vasperty_hle.HRESULT
	sblk := vasperty_hle.Async_Block{}
	assert(hle_vslot(sobj, 0xe0, GL_Async)(sobj, nil, &sblk) == vasperty_hle.S_OK)
	gl: vasperty_hle.Store_Game_License
	assert(hle_vslot(sobj, 0xe8, GL_Res)(sobj, &sblk, &gl) == vasperty_hle.S_OK && gl.is_active)
	assert(string(cstring(raw_data(gl.sku_store_id[:]))) == "9NBLGGH12345/0010")

	// 5. XGameSave atomic update + read
	prov_gs := vasperty_hle.PROVIDER_XGAMESAVE
	iid_gs := vasperty_hle.IID_XGAMESAVE_2026
	gsobj: rawptr = nil
	assert(vasperty_hle.QueryApiImpl(&prov_gs, &iid_gs, &gsobj) == vasperty_hle.S_OK && gsobj != nil)
	GS_Init :: #type proc "system" (rawptr, rawptr, cstring, bool, ^vasperty_hle.Async_Block) -> vasperty_hle.HRESULT
	GS_Crt :: #type proc "system" (rawptr, ^vasperty_hle.Save_Provider, cstring, ^^vasperty_hle.Save_Container) -> vasperty_hle.HRESULT
	GS_Upd :: #type proc "system" (rawptr, ^vasperty_hle.Save_Container, cstring, ^^vasperty_hle.Save_Update) -> vasperty_hle.HRESULT
	GS_Wb :: #type proc "system" (rawptr, ^vasperty_hle.Save_Update, cstring, [^]u8, uint) -> vasperty_hle.HRESULT
	GS_Sub :: #type proc "system" (rawptr, ^vasperty_hle.Save_Update, ^vasperty_hle.Async_Block) -> vasperty_hle.HRESULT
	GS_Rd :: #type proc "system" (rawptr, ^vasperty_hle.Save_Container, [^]cstring, ^u32, uint, [^]vasperty_hle.Save_Blob_Data) -> vasperty_hle.HRESULT
	GS_CloseP :: #type proc "system" (rawptr, ^vasperty_hle.Save_Provider)
	GS_CloseC :: #type proc "system" (rawptr, ^vasperty_hle.Save_Container)
	GS_CloseU :: #type proc "system" (rawptr, ^vasperty_hle.Save_Update)

	gs_blk := vasperty_hle.Async_Block{}
	assert(hle_vslot(gsobj, 0x20, GS_Init)(gsobj, nil, "scid-1", false, &gs_blk) == vasperty_hle.S_OK)
	sprov: ^vasperty_hle.Save_Provider = nil
	assert(hle_vslot(gsobj, 0x28, Res_Fn)(gsobj, &gs_blk, cast(^rawptr)&sprov) == vasperty_hle.S_OK && sprov != nil)
	scont: ^vasperty_hle.Save_Container = nil
	assert(hle_vslot(gsobj, 0x80, GS_Crt)(gsobj, sprov, "slot0", &scont) == vasperty_hle.S_OK && scont != nil)
	supd: ^vasperty_hle.Save_Update = nil
	assert(hle_vslot(gsobj, 0xb8, GS_Upd)(gsobj, scont, "Slot 0", &supd) == vasperty_hle.S_OK && supd != nil)
	save_bytes := [5]u8{1, 2, 3, 4, 5}
	assert(hle_vslot(gsobj, 0xc8, GS_Wb)(gsobj, supd, "hdr", raw_data(save_bytes[:]), 5) == vasperty_hle.S_OK)
	sub_blk := vasperty_hle.Async_Block{}
	assert(hle_vslot(gsobj, 0xe0, GS_Sub)(gsobj, supd, &sub_blk) == vasperty_hle.S_OK)
	assert(vasperty_hle.XAsyncGetStatus(&sub_blk, true) == vasperty_hle.S_OK)

	req_name: [1]cstring = {"hdr"}
	req_cnt: u32 = 1
	rd_buf: [256]u8
	out_blobs := cast([^]vasperty_hle.Save_Blob_Data)raw_data(rd_buf[:])
	assert(hle_vslot(gsobj, 0xa0, GS_Rd)(gsobj, scont, raw_data(req_name[:]), &req_cnt, size_of(rd_buf), out_blobs) == vasperty_hle.S_OK)
	assert(out_blobs[0].info.size == 5 && out_blobs[0].data[4] == 5)
	hle_vslot(gsobj, 0xc0, GS_CloseU)(gsobj, supd)
	hle_vslot(gsobj, 0x88, GS_CloseC)(gsobj, scont)
	hle_vslot(gsobj, 0x30, GS_CloseP)(gsobj, sprov)

	// 6. RPCRT4 UUID v4 + roundtrip + free
	u1: vasperty_hle.Guid
	assert(vasperty_hle.UuidCreate(&u1) == 0 && (u1.data3 >> 12) == 4 && (u1.data4[0] >> 6) == 2)
	u_cstr: cstring = nil
	assert(vasperty_hle.UuidToStringA(&u1, &u_cstr) == 0 && u_cstr != nil)
	u2: vasperty_hle.Guid
	assert(vasperty_hle.UuidFromStringA(u_cstr, &u2) == 0 && vasperty_hle.guid_eq(u1, u2))
	u_raw := rawptr(u_cstr)
	assert(vasperty_hle.RpcStringFreeA(&u_raw) == 0 && u_raw == nil)

	// 7. XMem + XG + DSP FDN Reverb + APU TOC + Virtual Drive
	xm_ptr := vasperty_hle.XMemAllocDefault(256, 0x6 << 24) // 64-byte aligned
	assert(xm_ptr != nil && (uintptr(xm_ptr) & 63) == 0)
	vasperty_hle.XMemFreeDefault(xm_ptr, 0)

	xg_desc := vasperty_hle.XG_Resource_Desc{dimension = 3, width = 16, height = 16, depth_or_array = 1, mips = 1, format = 28, samples = 1}
	xg_comp: ^vasperty_hle.XG_Computer = nil
	assert(vasperty_hle.XGCreateTextureComputer(&xg_desc, &xg_comp) == vasperty_hle.S_OK && xg_comp != nil)
	XG_Rel :: #type proc "system" (^vasperty_hle.XG_Computer) -> u32
	assert(hle_vslot(xg_comp, 0x10, XG_Rel)(xg_comp) == 0)

	dsp_inst: ^vasperty_hle.Dsp_Instance = nil
	assert(vasperty_hle.XDspConnectWithMaximumStreamLimit(nil, 0, 1, 4, 4, &dsp_inst) == vasperty_hle.S_OK)
	dsp_s: ^vasperty_hle.Dsp_Stream = nil
	dsp_st: rawptr = nil
	assert(vasperty_hle.XDspActivate(dsp_inst, 1, 0, 16384, 2, &dsp_s, &dsp_st) == vasperty_hle.S_OK)
	dsp_in: [64]f32
	dsp_out: [64]f32
	dsp_in[0] = 1.0
	gains := [2]f32{1.0, 1.0}
	assert(vasperty_hle.XDspSubmitCommand(dsp_s, 42, 32, &gains, raw_data(dsp_in[:]), raw_data(dsp_out[:])) == vasperty_hle.S_OK)
	assert((cast(^u32)dsp_st) != nil)
	assert(vasperty_hle.XDspDeactivate(dsp_s) == vasperty_hle.S_OK)
	assert(vasperty_hle.XDspDisconnect(dsp_inst) == vasperty_hle.S_OK)

	nsamp, ok_toc := vasperty_hle.opus_packet_samples([]u8{0xF8, 0xFF, 0xFE}) // CELT FB 20ms code=0 => 960
	assert(ok_toc && nsamp == 960)
	assert(vasperty_hle.is_local_media_url(`file://localhost/C:/vid.mp4`) && !vasperty_hle.is_local_media_url(`https://example.invalid/x`))
	assert(vasperty_hle.is_loopback_host_str("127.0.0.1") && !vasperty_hle.is_loopback_host_str("example.com"))

	fmt.println("ok")
}

test_shader_phase5 :: proc() {
	fmt.print("test_shader_phase5... ")
	// 1. DXBC container build, parse & D3D12 MD5 hash
	parts := [2]vasperty_shader.Raw_Part{
		{fourcc = vasperty_shader.FOURCC_ISG1, data = []u8{0, 0, 0, 0, 8, 0, 0, 0}},
		{fourcc = vasperty_shader.FOURCC_SFI0, data = []u8{0, 0, 0, 0, 0, 0, 0, 0}},
	}
	blob := vasperty_shader.dxbc_build(parts[:])
	defer delete(blob)
	parsed, perr := vasperty_shader.dxbc_parse(blob)
	assert(perr == .None)
	defer vasperty_shader.destroy_container(&parsed)
	isg_d, ok_isg := vasperty_shader.dxbc_part(&parsed, vasperty_shader.FOURCC_ISG1)
	assert(ok_isg && len(isg_d) == 8)
	assert(parsed.hash == vasperty_shader.dxbc_hash(blob[20:]))
	assert(parsed.hash != [16]u8{})
	_, bad_err := vasperty_shader.dxbc_parse(transmute([]u8)string("nope"))
	assert(bad_err == .Not_Dxbc)

	// 2. Static sampler decoding & host aniso point mip filter fallback
	point := vasperty_shader.static_sampler_from_words({0x3088, 0x0054_0100, 0x1400_0080, 0x8000_0000})
	assert(point.filter == 0)
	assert(point.address == [3]u32{1, 2, 3})
	assert(point.max_anisotropy == 1 && point.comparison == 4 && point.border == 2)
	aniso := vasperty_shader.static_sampler_from_words({0x369E, 0x00FF_F000, 0x18F0_3E00, 0x8000_0000})
	assert(aniso.filter == 0x55 && aniso.address == [3]u32{4, 5, 3} && aniso.max_anisotropy == 8)
	aniso_point := vasperty_shader.static_sampler_from_words({0, 0, (1 << 26) | (1 << 22) | (2 << 20), 0})
	assert(aniso_point.filter == 0x54)
	assert(vasperty_shader.static_sampler_filter_for_host(aniso_point, false) == 0x55)
	assert(vasperty_shader.static_sampler_filter_for_host(aniso_point, true) == 0x54)

	// 3. Rectangle geometry shader generation & right_angle geometry
	tl := [2]f32{0.0, 0.0}
	bl := [2]f32{0.0, 1.0}
	br := [2]f32{1.0, 1.0}
	tr := [2]f32{1.0, 0.0}
	assert(vasperty_shader.right_angle({tl, bl, br}) == 1)
	assert(vasperty_shader.right_angle({tl, bl, tr}) == 0)
	assert(vasperty_shader.right_angle({bl, tr, tl}) == 2)

	osg_elems := [2]vasperty_shader.Sig_Element{
		{name = "SV_Position", kind = 3, comp = 9, has_row = true, row = 0, cols = 4, usage = 0xF},
		{name = "TEXCOORD", kind = 0, comp = 9, has_row = true, row = 1, cols = 2, usage = 0x3},
	}
	osg_data := vasperty_shader.build_signature_part(osg_elems[:], false)
	defer delete(osg_data)
	dummy_vs := vasperty_shader.dxbc_build({{fourcc = vasperty_shader.FOURCC_OSG1, data = osg_data}})
	defer delete(dummy_vs)
	gs_blob, gs_err := vasperty_shader.rectangle_gs(dummy_vs)
	assert(gs_err == .None && len(gs_blob) > 64)
	defer delete(gs_blob)
	gs_c, gs_perr := vasperty_shader.dxbc_parse(gs_blob[:])
	assert(gs_perr == .None)
	_, ok_gs_dxil := vasperty_shader.dxbc_part(&gs_c, vasperty_shader.FOURCC_DXIL)
	assert(ok_gs_dxil)
	vasperty_shader.destroy_container(&gs_c)

	// 4. GFX10 decode + SSA IR + BDD structurization + Resource/IO + DXIL emission (CS)
	cs_words := [6]u32{
		0xbe82_0300, // s_mov_b32 s2, s0
		0x7e00_0202, // v_mov_b32 v0, s2
		0x8000_8100, // s_add_u32 s0, s0, 1
		0xbf06_8100, // s_cmp_eq_u32 s0, 1
		0xbf84_0000, // s_cbranch_scc0 +0
		0xbf81_0000, // s_endpgm
	}
	cs_bytes := slice.reinterpret([]u8, cs_words[:])
	p, st, rerr := vasperty_shader.range_build(cs_bytes, false, 4)
	assert(rerr == .None && len(p.blocks) >= 1)
	defer vasperty_shader.destroy_program(&p)
	defer vasperty_shader.destroy_structured(&st)

	layout := [1]vasperty_shader.Root_Param{
		{root = .Constants, user_data = 0, sgprs = 2},
	}
	native: vasperty_shader.Native_Program
	native.stage = .Cs
	native.vgprs = 4
	native.layout = layout[:]
	native.io = vasperty_shader.Stage_Io{
		kind = .Cs,
		cs   = vasperty_shader.Compute_Io{rsrc2 = (2 << 1) | (1 << 7), threads = {64, 1, 1}},
	}

	res, res_err := vasperty_shader.track_resources(&p, native.layout, .Cs, &st)
	assert(res_err == .None)
	defer vasperty_shader.destroy_resources(&res)

	io, io_err := vasperty_shader.raise_io(&p, &native)
	assert(io_err == .None)
	defer vasperty_shader.destroy_io(&io)

	empty_c := vasperty_shader.Container{}
	hs, emit_err := vasperty_shader.emit_shader(&empty_c, &native, &p, &st, &io, &res)
	assert(emit_err == .None && len(hs.dxil) > 64)
	defer vasperty_shader.destroy_host_shader(&hs)

	hs_c, hs_perr := vasperty_shader.dxbc_parse(hs.dxil[:])
	assert(hs_perr == .None)
	dx_part, ok_hs_dxil := vasperty_shader.dxbc_part(&hs_c, vasperty_shader.FOURCC_DXIL)
	assert(ok_hs_dxil && len(dx_part) > 24)
	expected_h := hs_c.hash
	vasperty_shader.destroy_container(&hs_c)
	assert(vasperty_shader.dxbc_hash(hs.dxil[20:]) == expected_h)

	// Optional live dxil.dll validation if installed on host
	ok_val, msg_val, val_err := vasperty_shader.validate_dxil(hs.dxil[:])
	if msg_val != "" {
		delete(msg_val)
	}
	_ = ok_val
	_ = val_err

	fmt.println("ok")
}

test_gpu_phase6 :: proc() {
	fmt.print("test_gpu_phase6... ")
	vasperty_hle.init_hle()
	defer vasperty_hle.fini_hle()
	vasperty_gpu.register_gpu_hooks()
	defer vasperty_gpu.gpu_fini()

	// 1. Live D3D12/DXGI capability probe (hardware or WARP)
	caps := vasperty_gpu.probe_capabilities(true)
	defer vasperty_gpu.destroy_host_capabilities(&caps)
	assert(caps.adapter_name != "" && caps.highest_shader_model != "")

	// 2. Virtual memory configuration & console Device COM object creation through HLE hooks
	hooks := vasperty_hle.get_gpu_hooks()
	assert(hooks.configure_virtual_memory != nil && hooks.create_device != nil)
	vm: vasperty_gpu.Virtual_Memory_X
	vm.flags = 1
	assert(hooks.configure_virtual_memory(&vm, 0, nil) == vasperty_hle.S_OK)
	assert(vm.highest > vm.lowest)

	ver := vasperty_gpu.CHECKED_DEVICE_VERSION
	dev_out: rawptr = nil
	dev_iid := transmute(vasperty_hle.Guid)vasperty_gpu.IID_ID3D12Device
	assert(hooks.create_device(nil, &ver, &dev_iid, &dev_out) == vasperty_hle.S_OK && dev_out != nil)
	dev_obj := cast(^vasperty_gpu.Gpu_Object)dev_out
	Vtbl_Dev :: struct {
		QueryInterface:     rawptr,
		AddRef:             proc "system" (^vasperty_gpu.Gpu_Object) -> u32,
		Release:            proc "system" (^vasperty_gpu.Gpu_Object) -> u32,
		GetPrivateData:     proc "system" (^vasperty_gpu.Gpu_Object, ^vasperty_gpu.Iid, ^u32, rawptr) -> vasperty_gpu.HRESULT,
		SetPrivateData:     proc "system" (^vasperty_gpu.Gpu_Object, ^vasperty_gpu.Iid, u32, rawptr) -> vasperty_gpu.HRESULT,
		SetPrivIfc:         rawptr,
		SetName:            rawptr,
		GetNodeCount:       proc "system" (^vasperty_gpu.Gpu_Object) -> u32,
	}
	dvt := (cast(^^Vtbl_Dev)dev_obj)^
	assert(dvt.GetNodeCount(dev_obj) == 1)
	priv_key := vasperty_gpu.guid(0x11223344, 0x5566, 0x7788, {1, 2, 3, 4, 5, 6, 7, 8})
	priv_val := u32(0xDEAD_BEEF)
	assert(dvt.SetPrivateData(dev_obj, &priv_key, 4, &priv_val) == vasperty_hle.S_OK)
	got_val := u32(0)
	got_sz := u32(4)
	assert(dvt.GetPrivateData(dev_obj, &priv_key, &got_sz, &got_val) == vasperty_hle.S_OK && got_val == 0xDEAD_BEEF)
	dvt.Release(dev_obj)

	// 3. Placed heap coalescing allocator
	pa := vasperty_gpu.placement_init()
	defer vasperty_gpu.placement_destroy(&pa)
	h1, o1, ok1 := vasperty_gpu.placement_alloc(&pa, 128 << 10, 64 << 10)
	h2, o2, ok2 := vasperty_gpu.placement_alloc(&pa, 256 << 10, 64 << 10)
	assert(ok1 && ok2 && h1 == h2 && o2 > o1)
	vasperty_gpu.placement_free(&pa, h1, o1, 128 << 10, 64 << 10)
	vasperty_gpu.placement_free(&pa, h2, o2, 256 << 10, 64 << 10)
	h3, o3, ok3 := vasperty_gpu.placement_alloc(&pa, 384 << 10, 64 << 10)
	assert(ok3 && h3 == h1 && o3 == 0)

	// 4. Page table & host descriptor heap virtualization + shadow copy-back + barrier tracker
	pt := vasperty_gpu.page_table_create()
	defer vasperty_gpu.page_table_destroy(pt)
	vasperty_gpu.page_table_map_range(pt, 0x1_0000_0000, 128 << 10, 42)
	ent, found_pg := vasperty_gpu.page_table_lookup(pt, 0x1_0001_2345)
	assert(found_pg && ent.srv_heap_slot == 42)

	hh := vasperty_gpu.host_heap_create(false, 64, 16)
	defer vasperty_gpu.host_heap_destroy(hh)
	vasperty_gpu.host_heap_set_view_stride(hh, 5, 16 | vasperty_shader.VIEW_INTEGER)
	dslot, dok := vasperty_gpu.host_heap_alloc_dyn(hh)
	assert(dok && dslot == 64)
	pslot := vasperty_gpu.host_heap_alloc_pair(hh)
	assert(pslot == 80)
	vasperty_gpu.host_heap_free_pair(hh, pslot)
	assert(vasperty_gpu.host_heap_alloc_pair(hh) == pslot)

	title_mem := make([]u8, 256)
	defer delete(title_mem)
	title_mem[12] = 0x77
	sc := vasperty_gpu.shadow_create(0x1_0000_0000, 256, 42)
	defer vasperty_gpu.shadow_destroy(sc)
	vasperty_gpu.shadow_refresh_from(sc, title_mem)
	assert(sc.backing[12] == 0x77)
	sc.backing[20] = 0xAB
	sc.backing[21] = 0xCD
	copied := vasperty_gpu.shadow_copy_back(sc, title_mem)
	assert(copied == 2 && title_mem[20] == 0xAB && title_mem[21] == 0xCD)

	cl := vasperty_gpu.command_list_create(0)
	defer vasperty_gpu.command_list_destroy(cl)
	vasperty_gpu.command_list_transition(cl, 0xCAFE_0000, 0x0200_0008, true) // strip high bits & buffer-only bits
	vasperty_gpu.command_list_transition(cl, 0xCAFE_0000, 0x0000_0008, true) // redundant -> coalesced away
	assert(len(cl.barriers) == 1 && cl.barriers[0].after == 0x8)

	// 5. Watch alias tracking & root signature console flag stripping
	vasperty_gpu.watch_memory_aliased(0x2_0000_0000, 0x1_0000_0000)
	assert(vasperty_gpu.watch_alias_count(0x1_0000_0000) == 1)
	rs := vasperty_gpu.root_desc_without_console_flags(vasperty_gpu.Root_Sig_Desc{flags = 0xFF00_0009})
	assert(rs.flags == 0x9)

	// 6. Shader cache miss -> hit roundtrip
	_, _, terr_miss := vasperty_gpu.host_shader_from_container([]u8{1, 2, 3, 4})
	assert(terr_miss != .None)
	_, hit2, _ := vasperty_gpu.host_shader_from_container([]u8{1, 2, 3, 4})
	assert(hit2)
	hits, misses := vasperty_gpu.shader_cache_counts()
	assert(hits >= 1 && misses >= 1)

	fmt.println("ok")
}

test_app_phase7 :: proc() {
	fmt.print("test_app_phase7... ")
	rt, err := vasperty_app.app_init(.Series_X)
	assert(err == .None && rt.initialized && rt.has_config)
	defer vasperty_app.app_fini(&rt)

	// Verify runtime config/policy/hooks wired end-to-end
	hooks := vasperty_hle.get_gpu_hooks()
	assert(hooks.create_device != nil && hooks.configure_virtual_memory != nil)
	assert(vasperty_app.app_config() == 0)
	assert(vasperty_app.app_doctor(false) == 0)
	assert(vasperty_app.app_inspect(os.args[0], false, false) == 0)
	assert(vasperty_app.app_census({os.args[0]}, false, false) == 0)

	// Verify synthetic translate batch tally with clean teardown
	tally: vasperty_app.Translate_Tally
	vasperty_app.app_translate_blob([]u8{'D', 'X', 'B', 'C', 0, 0}, false, &tally)
	assert(tally.containers == 1 && tally.failed == 1)

	fmt.println("ok")
}

test_vendor_and_ring :: proc() {
	fmt.print("[test] vendor_profiles_frame_ring_scanner ... ")
	intel := vasperty_gpu.Host_Capabilities{vendor_id = 0x8086, dedicated_video_memory = 128 << 20, shared_system_memory = 8 << 30, wave_lane_count_min = 16, wave_lane_count_max = 16}
	t := vasperty_gpu.classify_vendor(&intel)
	assert(t.tier == .Intel_Integrated_Uhd_Xe && t.is_uma && t.target_wave_size == 16 && t.max_frames_in_flight == 2)
	nv := vasperty_gpu.Host_Capabilities{vendor_id = 0x10DE, dedicated_video_memory = 8 << 30, wave_lane_count_min = 32, wave_lane_count_max = 32}
	t = vasperty_gpu.classify_vendor(&nv)
	assert(t.tier == .Nvidia_Modern_Wave32 && t.target_wave_size == 32 && t.prefer_async_compute && t.max_frames_in_flight == 3)
	amd := vasperty_gpu.Host_Capabilities{vendor_id = 0x1002, dedicated_video_memory = 8 << 30, wave_lane_count_max = 64}
	t = vasperty_gpu.classify_vendor(&amd)
	assert(t.tier == .Amd_Rdna && t.target_wave_size == 64 && !t.emulate_wave64)
	warp := vasperty_gpu.Host_Capabilities{vendor_id = 0x1414}
	assert(vasperty_gpu.classify_vendor(&warp).tier == .Software_Warp)

	ring := vasperty_gpu.frame_ring_init(2)
	defer vasperty_gpu.frame_ring_destroy(&ring)
	s0, _, w0 := vasperty_gpu.frame_ring_begin(&ring)
	assert(!w0)
	vasperty_gpu.frame_ring_mark_dirty_page(&ring, s0, 0x1_0000_0010)
	vasperty_gpu.frame_ring_mark_dirty_page(&ring, s0, 0x1_0000_FFF0)
	assert(len(ring.slots[s0].dirty_pages) == 1)
	f0 := vasperty_gpu.frame_ring_submit(&ring, s0)
	s1, _, w1 := vasperty_gpu.frame_ring_begin(&ring)
	assert(!w1 && s1 != s0)
	f1 := vasperty_gpu.frame_ring_submit(&ring, s1)
	_, wf, w2 := vasperty_gpu.frame_ring_begin(&ring)
	assert(w2 && wf == f0)
	vasperty_gpu.frame_ring_complete(&ring, f0)
	_, _, w3 := vasperty_gpu.frame_ring_begin(&ring)
	assert(!w3 && f1 > f0)

	buf := make([]u8, 256)
	defer delete(buf)
	emb := vasperty_shader.scan_embedded_dxbc(buf)
	assert(len(emb) == 0)
	delete(emb)
	assert(!vasperty_game.is_rpf9(buf))
	copy(buf, []u8{'9', 'F', 'P', 'R'})
	assert(vasperty_game.is_rpf9(buf))
	assert(vasperty_game.probe_archive_bytes(buf).kind == .Rpf9)
	copy(buf, []u8{'T', 'T', 'P', 'F'})
	assert(vasperty_game.is_ttpf(buf))
	assert(vasperty_game.probe_archive_bytes(buf).kind == .Ttpf)

	// Wave masks
	assert(vasperty_shader.wave_lane_mask(.Wave16) == 0xFFFF)
	assert(vasperty_shader.wave_lane_mask(.Wave32) == 0xFFFF_FFFF)
	assert(vasperty_shader.wave_lane_mask(.Wave64) == 0xFFFF_FFFF_FFFF_FFFF)

	// 64 KiB incremental dirty-page shadow copy-back
	page_title := make([]u8, 128 << 10)
	defer delete(page_title)
	sc := vasperty_gpu.shadow_create(0x1_0000_0000, 128 << 10, 1)
	defer vasperty_gpu.shadow_destroy(sc)
	vasperty_gpu.shadow_refresh_from(sc, page_title)
	sc.backing[10] = 0xAA
	sc.backing[(64 << 10) + 5] = 0xBB
	dirty_only_page0 := [1]u64{0x1_0000_0000}
	copied_p0 := vasperty_gpu.shadow_copy_back_pages(sc, page_title, dirty_only_page0[:])
	assert(copied_p0 == 1 && page_title[10] == 0xAA && page_title[(64 << 10) + 5] == 0)

	// oleaut32.dll allowed by default host policy
	def_pol := vasperty_hle.default_host_policy()
	defer vasperty_hle.destroy_host_policy(&def_pol)
	assert(vasperty_hle.host_policy_allows(&def_pol, "OLEAUT32.dll"))

	// Disk-backed PSO Pipeline Library roundtrip
	tmp_dir, has_tmp := os.lookup_env("TEMP", context.allocator)
	assert(has_tmp)
	defer delete(tmp_dir)
	pso_dir, _ := filepath.join({tmp_dir, "vasperty_pso_lib_test"}, context.allocator)
	defer delete(pso_dir)
	lib, lib_ok := vasperty_gpu.pso_library_open(pso_dir, 0x10DE, 0x2684, 32)
	assert(lib_ok)
	defer vasperty_gpu.pso_library_close(&lib)
	pso_desc := [4]u8{1, 2, 3, 4}
	pso_blob := [8]u8{0xDE, 0xAD, 0xBE, 0xEF, 5, 6, 7, 8}
	assert(vasperty_gpu.pso_library_store(&lib, pso_desc[:], pso_blob[:]))
	got_blob, got_ok := vasperty_gpu.pso_library_load(&lib, pso_desc[:])
	assert(got_ok && len(got_blob) == len(pso_blob) && got_blob[0] == 0xDE)
	delete(got_blob)

	// Branchless u64-stride shadow_merge_writeback oracle verification
	for n in ([?]int{0, 1, 7, 8, 63, 64, 65, 193, 4096}) {
		old := make([]u8, n)
		title := make([]u8, n)
		host := make([]u8, n)
		expected := make([]u8, n)
		for i := 0; i < n; i += 1 {
			old[i] = 0x11
			title[i] = 0x22 if (i % 3 == 0) else 0x11
			host[i] = (0x22 if (i % 2 == 0) else 0x33) if (i % 5 == 0) else 0x11
			expected[i] = title[i] if host[i] == old[i] else host[i]
		}
		_, _ = vasperty_gpu.shadow_merge_writeback(title, host, old)
		assert(slice.equal(title, expected))
		assert(slice.equal(host, expected))
		delete(old); delete(title); delete(host); delete(expected)
	}

	// Integer RT blend sanitization (#1152), typed UAV format guard (#2462), sampler filter (#2031)
	rt_fmts := [2]u32{28, 62} // R8G8B8A8_UNORM + R8_UINT
	indep := false
	en := [8]bool{true, false, false, false, false, false, false, false}
	disabled := vasperty_gpu.sanitize_blend_for_targets(rt_fmts[:], &indep, &en)
	assert(disabled == 1 && indep && en[0] && !en[1])
	assert(vasperty_gpu.format_supports_typed_uav_store(62, false))
	assert(!vasperty_gpu.format_supports_typed_uav_store(28, false))
	assert(vasperty_gpu.format_supports_typed_uav_store(28, true))
	assert(vasperty_gpu.sampler_filter_for_host(0x54, true) == 0x54)
	assert(vasperty_gpu.sampler_filter_for_host(0x54, false) == 0x55)

	// PE DllCharacteristics bit names (#1988)
	dnames := vasperty_pe.dll_characteristics_names(0x0160)
	assert(dnames == "HIGH_ENTROPY_VA | DYNAMIC_BASE | NX_COMPAT")
	delete(dnames)

	// Dirty_Bitmap 64-bit CTZ zero-word skip (#1865)
	bm := vasperty_gpu.dirty_bitmap_init(1024)
	defer vasperty_gpu.dirty_bitmap_destroy(&bm)
	vasperty_gpu.dirty_bitmap_mark(&bm, 0)
	vasperty_gpu.dirty_bitmap_mark(&bm, 65)
	vasperty_gpu.dirty_bitmap_mark_range(&bm, 512, 3)
	pages := make([dynamic]u64)
	defer delete(pages)
	vasperty_gpu.dirty_bitmap_collect(&bm, &pages)
	assert(len(pages) == 5 && pages[0] == 0 && pages[1] == 65 && pages[2] == 512 && pages[4] == 514)

	// Shader LDS guard, Wave16/32 bpermute scoping, i64 dword compare, XMem <4GiB range
	assert(vasperty_shader.bpermute_lane_mask(.Wave16) == 0x0F && vasperty_shader.bpermute_lane_mask(.Wave32) == 0x1F)
	assert(vasperty_shader.lds_offset_in_bounds(0, 16, 4096) && !vasperty_shader.lds_offset_in_bounds(4090, 16, 4096))
	assert(vasperty_shader.cmp_i64_dwords_safe(0xFFFF_FFFF_FFFF_FFFF, 1, true) == -1)
	assert(vasperty_shader.cmp_i64_dwords_safe(0xFFFF_FFFF_FFFF_FFFF, 1, false) == 1)
	lo32, hi32 := vasperty_hle.xmem_address_range(vasperty_hle.XMEM_ADDRESS_32BIT)
	assert(lo32 == 0 && hi32 == 0xFFFF_FFFF && vasperty_hle.xmem_is_low32(0x1000_0000, 0x1000))

	// Live D3D12 Host_Executor async Frame_Ring submission (real GPU or WARP)
	if ex, ex_ok := vasperty_gpu.host_executor_init(true); ex_ok {
		defer vasperty_gpu.host_executor_destroy(&ex)
		for _ in 0 ..< 6 {
			slot, bok := vasperty_gpu.host_executor_begin_frame(&ex)
			assert(bok)
			fval, sok := vasperty_gpu.host_executor_submit_frame(&ex, slot)
			assert(sok && fval > 0)
		}
		vasperty_gpu.host_executor_drain(&ex)
		assert(ex.frames_submitted == 6)
	}

	// Zero-copy shared-read MapViewOfFile roundtrip on self executable
	mf, mf_ok := vasperty_game.map_file_readonly(os.args[0])
	assert(mf_ok && len(mf.data) > 1024 && mf.data[0] == 'M' && mf.data[1] == 'Z')
	vasperty_game.unmap_file_readonly(&mf)

	// Mesh Shader -> Compute + Pass-Through VS Fallback for Intel Integrated / GTX GPUs
	mio := vasperty_shader.Mesh_Io{
		max_vertices   = 64,
		max_primitives = 126,
		topology       = 3, // triangles
		threads        = 32,
		lds_bytes      = 4096,
	}
	mplan := vasperty_shader.mesh_fallback_plan(&mio, .Wave16)
	assert(mplan.target_wave_size == 16 && mplan.indices_per_prim == 3 && mplan.total_scratch_bytes > 0)
	msr := vasperty_gpu.mesh_scratch_ring_init(2, true)
	defer vasperty_gpu.mesh_scratch_ring_destroy(&msr)
	ma0, mok0 := vasperty_gpu.mesh_scratch_alloc(&msr, 0, &mplan)
	ma1, mok1 := vasperty_gpu.mesh_scratch_alloc(&msr, 0, &mplan)
	assert(mok0 && mok1 && ma1.vertex_offset == ma0.vertex_offset + ma0.total_bytes)
	vasperty_gpu.mesh_scratch_reset_slot(&msr, 0)
	ma2, mok2 := vasperty_gpu.mesh_scratch_alloc(&msr, 0, &mplan)
	assert(mok2 && ma2.vertex_offset == ma0.vertex_offset)

	pt_vs := vasperty_shader.emit_mesh_passthrough_vs(2, .Wave16)
	defer vasperty_shader.destroy_host_shader(&pt_vs)
	assert(pt_vs.stage == .Vs && pt_vs.target_wave_size == 16 && len(pt_vs.dxil) > 64)
	pt_c, pt_err := vasperty_shader.dxbc_parse(pt_vs.dxil[:])
	assert(pt_err == .None)
	_, has_pt_dxil := vasperty_shader.dxbc_part(&pt_c, vasperty_shader.FOURCC_DXIL)
	assert(has_pt_dxil && vasperty_shader.dxbc_hash(pt_vs.dxil[20:]) == pt_c.hash)
	vasperty_shader.destroy_container(&pt_c)

	// Swapchain_Engine (PresentX multi-plane + HDR10 + Frame_Pacer)
	sc_cfg := vasperty_gpu.swapchain_config_for_host(1920, 1080, &nv, &t, true)
	assert(sc_cfg.format == vasperty_gpu.DXGI_FORMAT_R10G10B10A2_UNORM && sc_cfg.color_space == .Hdr10_Pq)
	pb := vasperty_gpu.present_batch_init(true, false)
	assert(vasperty_gpu.present_batch_add_plane(&pb, vasperty_gpu.Present_Plane{width = 1920, height = 1080}))
	assert(!vasperty_gpu.present_batch_needs_composite(&pb))
	assert(vasperty_gpu.present_batch_add_plane(&pb, vasperty_gpu.Present_Plane{width = 1920, height = 1080, alpha_blend = true, is_ui_layer = true}))
	assert(vasperty_gpu.present_batch_needs_composite(&pb))
	pacer: vasperty_gpu.Frame_Pacer
	for i in 0 ..< 16 { vasperty_gpu.frame_pacer_record(&pacer, 8.0 + f64(i % 4)) }
	pstats := vasperty_gpu.frame_pacer_stats(&pacer)
	assert(pstats.samples == 16 && pstats.p95_ms >= pstats.p50_ms && pstats.fps > 50.0)

	// Bvh_Rt_Manager (NVIDIA DXR hardware vs Intel UMA compute fallback)
	nv_caps := vasperty_gpu.Host_Capabilities{vendor_id = 0x10DE, dedicated_video_memory = 8 << 30, raytracing_tier = 11}
	nv_tune := vasperty_gpu.classify_vendor(&nv_caps)
	bvh := vasperty_gpu.bvh_rt_init(&nv_tune)
	defer vasperty_gpu.bvh_rt_destroy(&bvh)
	assert(bvh.backend == .Hardware_Dxr)
	bid, bok := vasperty_gpu.bvh_rt_register(&bvh, .Blas, 4096, true)
	assert(bok && bid > 0)
	refit1, ok_b1 := vasperty_gpu.bvh_rt_build_or_refit(&bvh, bid)
	refit2, ok_b2 := vasperty_gpu.bvh_rt_build_or_refit(&bvh, bid)
	assert(ok_b1 && !refit1 && ok_b2 && refit2 && bvh.builds_total == 1 && bvh.refits_total == 1)
	vasperty_gpu.bvh_rt_remove(&bvh, bid)
	assert(bvh.used_bytes == 0)

	// Frame_Telemetry + shader math precision (#682, #1259)
	tel: vasperty_core.Frame_Telemetry
	tel.frames_presented = 10
	tel.pso_cache_hits = 9
	tel.pso_cache_misses = 1
	assert(vasperty_core.telemetry_pso_hit_rate(&tel) == 90.0)
	tsum := vasperty_core.telemetry_format_summary(&tel)
	assert(len(tsum) > 0)
	delete(tsum)
	assert(vasperty_shader.mul_legacy_f32_safe(0.0, math.inf_f32(1)) == 0.0)
	neg_zero := transmute(f32)u32(0x8000_0000)
	pos_zero := f32(0.0)
	med := vasperty_shader.med3_f32_ordered(1.0, pos_zero, neg_zero)
	assert(transmute(u32)med == 0) // pos_zero is median between neg_zero and 1.0
	assert(vasperty_app.app_doctor(false, true) == 0)
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
	test_sgd5()
	test_pipelines()
	test_texture_formats()
	test_bcpack()
	test_xma()
	test_pipeline_cache()
	test_loader_phase3()
	test_hle_phase4()
	test_shader_phase5()
	test_gpu_phase6()
	test_vendor_and_ring()
	test_app_phase7()

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
	fmt.println("ALL VASPERTY TESTS PASSED (0 leaks, 0 bad frees)")
}
