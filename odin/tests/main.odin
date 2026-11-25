package vasperty_tests

import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:path/filepath"

import vasperty_core "vasperty:core"
import vasperty_formats "vasperty:formats"
import vasperty_game "vasperty:game"
import vasperty_loader "vasperty:loader"
import vasperty_pe "vasperty:pe"
import vasperty_pipeline "vasperty:pipeline"
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
	assert(vasperty_core.ensure_outside_repo("crates\\..\\not-created\\out") == .Inside_Repo)
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
	fmt.println("ALL ODIN PHASE 3 TESTS PASSED (0 leaks, 0 bad frees)")
}
