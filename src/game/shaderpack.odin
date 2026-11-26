package vasperty_game

import "core:strings"

SHADERPACK_MAGIC :: [4]u8{'P', 'S', 0, 9}
HEADER_SIZE :: 0x80
GRAPHICS_RECORD_SIZE :: 0x70
COMPUTE_RECORD_SIZE :: 0x18
INDEX_NONE :: max(u32)

STAGE_NAMES := [7]string{"PS", "VS", "GS", "ES", "HS", "LS", "fetch"}

Pack_Error :: enum {
	None,
	Not_A_Shader_Pack,
	Truncated,
	Bad_Table_Ref,
}

Table :: struct {
	entries: []u8,
	data:    []u8,
}

Stage :: struct {
	program:      []u8,
	has_metadata: bool,
	metadata:     []u8,
}

Graphics_Record :: struct {
	key:                u64,
	shader_hash:        u64,
	pipeline_hash:      u64,
	depth_stencil_hash: u64,
	rasterizer_hash:    u64,
	blend_hash:         u64,
	packet:             []u8,
	metadata:           []u8,
	has_stage:          [7]bool,
	stages:             [7]Stage,
}

Compute_Record :: struct {
	shader_hash: u64,
	packet:      []u8,
	metadata:    []u8,
	stage:       Stage,
}

Input_Element :: struct {
	semantic:  string,
	index:     u32,
	format:    u32,
	slot:      u32,
	offset:    u32,
	class:     u32,
	step_rate: u32,
}

Shader_Pack :: struct {
	file:     []u8,
	graphics: []u8,
	compute:  []u8,
	blobs:    Table,
	programs: Table,
}

@(private)
u32_at :: proc(b: []u8, o: int) -> (u32, bool) {
	if o < 0 || o + 4 > len(b) {
		return 0, false
	}
	v := u32(b[o]) | (u32(b[o + 1]) << 8) | (u32(b[o + 2]) << 16) | (u32(b[o + 3]) << 24)
	return v, true
}

@(private)
u64_at :: proc(b: []u8, o: int) -> (u64, bool) {
	lo, ok0 := u32_at(b, o)
	hi, ok1 := u32_at(b, o + 4)
	if !ok0 || !ok1 {
		return 0, false
	}
	return u64(lo) | (u64(hi) << 32), true
}

@(private)
table_len :: proc(t: Table) -> u32 {
	return u32(len(t.entries) / 8)
}

@(private)
table_get :: proc(t: Table, index: u32) -> ([]u8, bool) {
	if index == INDEX_NONE {
		return nil, false
	}
	at := int(index) * 8
	off, ok0 := u32_at(t.entries, at)
	length, ok1 := u32_at(t.entries, at + 4)
	if !ok0 || !ok1 {
		return nil, false
	}
	end := u64(off) + u64(length)
	if end > u64(len(t.data)) {
		return nil, false
	}
	return t.data[int(off):int(end)], true
}

@(private)
cstr_slice :: proc(b: []u8) -> string {
	end := len(b)
	for i := 0; i < len(b); i += 1 {
		if b[i] == 0 {
			end = i
			break
		}
	}
	return string(b[:end])
}

parse_pack :: proc(file: []u8) -> (pack: Shader_Pack, err: Pack_Error) {
	if len(file) < 4 ||
		file[0] != SHADERPACK_MAGIC[0] ||
		file[1] != SHADERPACK_MAGIC[1] ||
		file[2] != SHADERPACK_MAGIC[2] ||
		file[3] != SHADERPACK_MAGIC[3] {
		return pack, .Not_A_Shader_Pack
	}

	ng, ok0 := u32_at(file, 0x50)
	nc, ok1 := u32_at(file, 0x54)
	nb, ok2 := u32_at(file, 0x58)
	np, ok3 := u32_at(file, 0x5C)
	blob_bytes, ok4 := u32_at(file, 0x60)
	prog_bytes, ok5 := u32_at(file, 0x64)
	if !ok0 || !ok1 || !ok2 || !ok3 || !ok4 || !ok5 || len(file) < HEADER_SIZE {
		return pack, .Truncated
	}

	at := HEADER_SIZE
	take :: proc(file: []u8, at: ^int, size: u64) -> ([]u8, bool) {
		if size > u64(len(file) - at^) {
			return nil, false
		}
		part := file[at^ : at^ + int(size)]
		at^ += int(size)
		return part, true
	}

	g_slice, g_ok := take(file, &at, u64(ng) * GRAPHICS_RECORD_SIZE)
	c_slice, c_ok := take(file, &at, u64(nc) * COMPUTE_RECORD_SIZE)
	b_ent, b_ok := take(file, &at, u64(nb) * 8)
	p_ent, p_ok := take(file, &at, u64(np) * 8)
	b_data, bd_ok := take(file, &at, u64(blob_bytes))
	p_data, pd_ok := take(file, &at, u64(prog_bytes))
	if !g_ok || !c_ok || !b_ok || !p_ok || !bd_ok || !pd_ok {
		return pack, .Truncated
	}

	pack = Shader_Pack{
		file     = file,
		graphics = g_slice,
		compute  = c_slice,
		blobs    = Table{entries = b_ent, data = b_data},
		programs = Table{entries = p_ent, data = p_data},
	}

	for i: u32 = 0; i < nb; i += 1 {
		if _, ok := table_get(pack.blobs, i); !ok {
			return {}, .Bad_Table_Ref
		}
	}
	for i: u32 = 0; i < np; i += 1 {
		if _, ok := table_get(pack.programs, i); !ok {
			return {}, .Bad_Table_Ref
		}
	}

	for r := 0; r < int(ng); r += 1 {
		rec := g_slice[r * GRAPHICS_RECORD_SIZE : (r + 1) * GRAPHICS_RECORD_SIZE]
		pkt, _ := u32_at(rec, 8)
		meta, _ := u32_at(rec, 12)
		if pkt >= nb || meta >= nb {
			return {}, .Bad_Table_Ref
		}
		for s := 0; s < 7; s += 1 {
			pr, _ := u32_at(rec, 0x38 + 8 * s)
			mr, _ := u32_at(rec, 0x3C + 8 * s)
			if (pr != INDEX_NONE && pr >= np) || (mr != INDEX_NONE && mr >= nb) {
				return {}, .Bad_Table_Ref
			}
		}
	}

	for r := 0; r < int(nc); r += 1 {
		rec := c_slice[r * COMPUTE_RECORD_SIZE : (r + 1) * COMPUTE_RECORD_SIZE]
		pkt, _ := u32_at(rec, 8)
		meta, _ := u32_at(rec, 12)
		pr, _ := u32_at(rec, 16)
		mr, _ := u32_at(rec, 20)
		if pkt >= nb || meta >= nb || pr >= np || (mr != INDEX_NONE && mr >= nb) {
			return {}, .Bad_Table_Ref
		}
	}

	return pack, .None
}

pack_driver :: proc(p: ^Shader_Pack) -> string {
	return cstr_slice(p.file[4:0x24])
}

pack_compiler :: proc(p: ^Shader_Pack) -> string {
	return cstr_slice(p.file[0x24:0x48])
}

pack_fingerprint :: proc(p: ^Shader_Pack) -> u64 {
	v, _ := u64_at(p.file, 0x48)
	return v
}

pack_graphics_count :: proc(p: ^Shader_Pack) -> int {
	return len(p.graphics) / GRAPHICS_RECORD_SIZE
}

pack_compute_count :: proc(p: ^Shader_Pack) -> int {
	return len(p.compute) / COMPUTE_RECORD_SIZE
}

pack_graphics :: proc(p: ^Shader_Pack, idx: int) -> (rec_out: Graphics_Record, ok: bool) {
	if idx < 0 || idx >= pack_graphics_count(p) {
		return rec_out, false
	}
	r := p.graphics[idx * GRAPHICS_RECORD_SIZE : (idx + 1) * GRAPHICS_RECORD_SIZE]
	rec_out.key, _ = u64_at(r, 0)
	rec_out.shader_hash, _ = u64_at(r, 0x10)
	rec_out.pipeline_hash, _ = u64_at(r, 0x18)
	rec_out.depth_stencil_hash, _ = u64_at(r, 0x20)
	rec_out.rasterizer_hash, _ = u64_at(r, 0x28)
	rec_out.blend_hash, _ = u64_at(r, 0x30)

	pkt_idx, _ := u32_at(r, 8)
	meta_idx, _ := u32_at(r, 12)
	rec_out.packet, _ = table_get(p.blobs, pkt_idx)
	rec_out.metadata, _ = table_get(p.blobs, meta_idx)

	for s := 0; s < 7; s += 1 {
		pr, _ := u32_at(r, 0x38 + 8 * s)
		if prog, p_ok := table_get(p.programs, pr); p_ok {
			mr, _ := u32_at(r, 0x3C + 8 * s)
			md, md_ok := table_get(p.blobs, mr)
			rec_out.has_stage[s] = true
			rec_out.stages[s] = Stage{
				program      = prog,
				has_metadata = md_ok,
				metadata     = md,
			}
		}
	}
	return rec_out, true
}

pack_compute :: proc(p: ^Shader_Pack, idx: int) -> (rec_out: Compute_Record, ok: bool) {
	if idx < 0 || idx >= pack_compute_count(p) {
		return rec_out, false
	}
	r := p.compute[idx * COMPUTE_RECORD_SIZE : (idx + 1) * COMPUTE_RECORD_SIZE]
	rec_out.shader_hash, _ = u64_at(r, 0)
	pkt_idx, _ := u32_at(r, 8)
	meta_idx, _ := u32_at(r, 12)
	pr, _ := u32_at(r, 16)
	mr, _ := u32_at(r, 20)
	rec_out.packet, _ = table_get(p.blobs, pkt_idx)
	rec_out.metadata, _ = table_get(p.blobs, meta_idx)
	rec_out.stage.program, _ = table_get(p.programs, pr)
	rec_out.stage.metadata, rec_out.stage.has_metadata = table_get(p.blobs, mr)
	return rec_out, true
}

graphics_target_formats :: proc(g: ^Graphics_Record) -> (out: [8]u8, ok: bool) {
	if len(g.metadata) < 0x18 {
		return out, false
	}
	copy(out[:], g.metadata[0x10:0x18])
	return out, true
}

destroy_input_layout :: proc(elems: ^[dynamic]Input_Element, allocator := context.allocator) {
	for &e in elems {
		delete(e.semantic, allocator)
	}
	delete(elems^)
}

graphics_input_layout :: proc(g: ^Graphics_Record, allocator := context.allocator) -> (out: [dynamic]Input_Element, ok: bool) {
	m := g.metadata
	size_val, ok_s := u32_at(m, 0x38)
	count, ok_c := u32_at(m, 0x4C)
	if !ok_s || !ok_c {
		return nil, false
	}
	end := 0x4C + int(size_val)
	if end > len(m) {
		return nil, false
	}
	out = make([dynamic]Input_Element, allocator)
	at := 0x50
	for i: u32 = 0; i < count; i += 1 {
		slen, ok_l := u32_at(m, at)
		if !ok_l || at + 4 + int(slen) + 24 > len(m) {
			destroy_input_layout(&out, allocator)
			return nil, false
		}
		sem_bytes := m[at + 4 : at + 4 + int(slen)]
		at += 4 + int(slen)
		f0, _ := u32_at(m, at)
		f1, _ := u32_at(m, at + 4)
		f2, _ := u32_at(m, at + 8)
		f3, _ := u32_at(m, at + 12)
		f4, _ := u32_at(m, at + 16)
		f5, _ := u32_at(m, at + 20)
		append(&out, Input_Element{
			semantic  = strings.clone(cstr_slice(sem_bytes), allocator),
			index     = f0,
			format    = f1,
			slot      = f2,
			offset    = f3,
			class     = f4,
			step_rate = f5,
		})
		at += 24
	}
	if at != end {
		destroy_input_layout(&out, allocator)
		return nil, false
	}
	return out, true
}
