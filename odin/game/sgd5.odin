package vasperty_game

import "core:compress/deflate"
import "core:os"
import "core:thread"

SGD5_MAGIC :: [4]u8{'S', 'G', 'D', '5'}
SGD5_MARKER :: [4]u8{0xE7, 0xDC, 0x0D, 0x00}
SGD5_MAX_UNPACKED :: 64 << 20
SGD5_SHARED :: u32(0x8000_0000)

SGD5_STAGES := [6]string{"vertex", "pixel", "geometry", "slot3", "slot4", "compute"}

Sgd5_Record :: struct {
	offset:        int,
	has_name:      bool,
	name:          string,
	kind:          u8,
	packed:        []u8,
	unpacked_size: int,
}

Sgd5_Shader :: struct {
	record: Sgd5_Record,
	hash:   u64,
}

Sgd5_Pass :: struct {
	has_shader:        [6]bool,
	shaders:           [6]int,
	has_rasterizer:    bool,
	rasterizer:        []u8,
	has_depth_stencil: bool,
	depth_stencil:     []u8,
	has_blend:         bool,
	blend:             []u8,
	has_stencil_ref:   bool,
	stencil_ref:       u8,
}

Sgd5_Technique :: struct {
	name:   string,
	passes: [dynamic]Sgd5_Pass,
}

Sgd5_Effect :: struct {
	name:           string,
	techniques:     [dynamic]Sgd5_Technique,
	rasterizers:    [dynamic][]u8,
	depth_stencils: [dynamic][]u8,
	blends:         [dynamic][]u8,
}

Sgd5_Database :: struct {
	shaders: [6][dynamic]Sgd5_Shader,
	effects: [dynamic]Sgd5_Effect,
	start:   int,
	end:     int,
}

@(private)
Sgd5_Cursor :: struct {
	file: []u8,
	at:   int,
}

@(private)
cur_bytes :: proc(c: ^Sgd5_Cursor, n: int) -> ([]u8, bool) {
	if n < 0 || c.at < 0 || c.at > len(c.file) || n > len(c.file) - c.at {
		return nil, false
	}
	b := c.file[c.at : c.at + n]
	c.at += n
	return b, true
}

@(private)
cur_u8 :: proc(c: ^Sgd5_Cursor) -> (u8, bool) {
	b, ok := cur_bytes(c, 1)
	if !ok do return 0, false
	return b[0], true
}

@(private)
cur_u32 :: proc(c: ^Sgd5_Cursor) -> (u32, bool) {
	b, ok := cur_bytes(c, 4)
	if !ok do return 0, false
	return u32(b[0]) | (u32(b[1]) << 8) | (u32(b[2]) << 16) | (u32(b[3]) << 24), true
}

@(private)
cur_u64 :: proc(c: ^Sgd5_Cursor) -> (u64, bool) {
	lo, ok0 := cur_u32(c)
	hi, ok1 := cur_u32(c)
	if !ok0 || !ok1 do return 0, false
	return u64(lo) | (u64(hi) << 32), true
}

@(private)
cur_str :: proc(c: ^Sgd5_Cursor) -> (string, bool) {
	n, ok_n := cur_u8(c)
	if !ok_n || n == 0 do return "", false
	b, ok_b := cur_bytes(c, int(n))
	if !ok_b || b[len(b) - 1] != 0 do return "", false
	return string(b[:len(b) - 1]), true
}

@(private)
cur_items :: proc(c: ^Sgd5_Cursor, item_size: int, allocator := context.allocator) -> ([dynamic][]u8, bool) {
	n, ok_n := cur_u32(c)
	if !ok_n do return nil, false
	total := u64(n) * u64(item_size)
	if total > u64(max(int)) do return nil, false
	all, ok_b := cur_bytes(c, int(total))
	if !ok_b do return nil, false
	out := make([dynamic][]u8, 0, int(n), allocator)
	for i := 0; i < int(n); i += 1 {
		append(&out, all[i * item_size : (i + 1) * item_size])
	}
	return out, true
}

@(private)
cur_u32s :: proc(c: ^Sgd5_Cursor, allocator := context.allocator) -> ([dynamic]u32, bool) {
	n, ok_n := cur_u32(c)
	if !ok_n do return nil, false
	total := u64(n) * 4
	if total > u64(max(int)) do return nil, false
	all, ok_b := cur_bytes(c, int(total))
	if !ok_b do return nil, false
	out := make([dynamic]u32, 0, int(n), allocator)
	for i := 0; i < int(n); i += 1 {
		off := i * 4
		v := u32(all[off]) | (u32(all[off + 1]) << 8) | (u32(all[off + 2]) << 16) | (u32(all[off + 3]) << 24)
		append(&out, v)
	}
	return out, true
}

@(private)
find_4byte_pattern :: proc(haystack: []u8, needle: [4]u8, from: int) -> (int, bool) {
	if from < 0 || len(haystack) - from < 4 {
		return 0, false
	}
	limit := len(haystack) - 4
	for i := from; i <= limit; i += 1 {
		if haystack[i] == needle[0] &&
			haystack[i + 1] == needle[1] &&
			haystack[i + 2] == needle[2] &&
			haystack[i + 3] == needle[3] {
			return i, true
		}
	}
	return 0, false
}

is_sgd5 :: proc(file: []u8) -> bool {
	_, found := find_4byte_pattern(file, SGD5_MAGIC, 0)
	return found
}

sgd5_record_unpack :: proc(r: ^Sgd5_Record, allocator := context.allocator) -> (out: []u8, ok: bool) {
	if r.unpacked_size < 0 || r.unpacked_size > SGD5_MAX_UNPACKED {
		return nil, false
	}
	if r.unpacked_size == 0 {
		return nil, len(r.packed) > 0
	}
	buf := make([dynamic]u8, 0, r.unpacked_size, allocator)
	d_err := deflate.inflate_raw(&buf, r.packed, r.unpacked_size, r.unpacked_size, allocator)
	if d_err != nil || len(buf) != r.unpacked_size {
		delete(buf)
		return nil, false
	}
	return buf[:], true
}

Sgd5_Unpack_Result :: struct {
	data: []u8,
	ok:   bool,
}

@(private)
Unpack_Chunk_Task :: struct {
	recs: []Sgd5_Record,
	outs: []Sgd5_Unpack_Result,
}

@(private)
unpack_chunk_worker :: proc(t: ^Unpack_Chunk_Task) {
	for i := 0; i < len(t.recs); i += 1 {
		d, ok := sgd5_record_unpack(&t.recs[i], context.allocator)
		t.outs[i] = Sgd5_Unpack_Result{data = d, ok = ok}
	}
}

sgd5_unpack_all :: proc(recs: []Sgd5_Record, allocator := context.allocator) -> []Sgd5_Unpack_Result {
	out := make([]Sgd5_Unpack_Result, len(recs), allocator)
	if len(recs) < 4 {
		for i := 0; i < len(recs); i += 1 {
			d, ok := sgd5_record_unpack(&recs[i], allocator)
			out[i] = Sgd5_Unpack_Result{data = d, ok = ok}
		}
		return out
	}

	cores := os.get_processor_core_count()
	threads := clamp(cores, 2, 8)
	threads = min(threads, len(recs))
	chunk := (len(recs) + threads - 1) / threads
	num_tasks := (len(recs) + chunk - 1) / chunk

	tasks := make([dynamic]Unpack_Chunk_Task, 0, num_tasks, allocator)
	workers := make([dynamic]^thread.Thread, 0, num_tasks, allocator)
	defer {
		delete(tasks)
		delete(workers)
	}

	for i := 0; i < num_tasks; i += 1 {
		start := i * chunk
		end := min(start + chunk, len(recs))
		append(&tasks, Unpack_Chunk_Task{
			recs = recs[start:end],
			outs = out[start:end],
		})
	}
	for i := 0; i < len(tasks); i += 1 {
		th := thread.create_and_start_with_poly_data(&tasks[i], unpack_chunk_worker, init_context = context)
		append(&workers, th)
	}
	for th in workers {
		thread.join(th)
		thread.destroy(th)
	}
	return out
}

sgd5_destroy_unpack_results :: proc(res: []Sgd5_Unpack_Result, allocator := context.allocator) {
	for &r in res {
		if r.ok && len(r.data) > 0 {
			delete(r.data, allocator)
		}
	}
	delete(res, allocator)
}

@(private)
is_ascii_graphic :: #force_inline proc "contextless" (b: u8) -> bool {
	return b >= 0x21 && b <= 0x7E
}

@(private)
name_before :: proc(file: []u8, nul: int) -> (string, bool) {
	run := 0
	for i := nul - 1; i >= 0; i -= 1 {
		if !is_ascii_graphic(file[i]) {
			run = i + 1
			break
		}
	}
	start := run - 1 if run > 0 else 0
	for l := start; l < nul; l += 1 {
		if int(file[l]) == nul - l {
			return string(file[l + 1 : nul]), true
		}
	}
	return "", false
}

@(private)
record_at_marker :: proc(file: []u8, at: int) -> (Sgd5_Record, bool) {
	if at < 6 {
		return {}, false
	}
	n_val, ok0 := u32_at(file, at - 4)
	n2_val, ok1 := u32_at(file, at + 4)
	unpacked_val, ok2 := u32_at(file, at + 8)
	if !ok0 || !ok1 || !ok2 {
		return {}, false
	}
	n := int(n_val)
	unpacked := int(unpacked_val)
	if int(n2_val) != n || n < 12 || unpacked > SGD5_MAX_UNPACKED {
		return {}, false
	}
	if at + n > len(file) {
		return {}, false
	}
	nul := at - 6
	has_nm := false
	nm := ""
	if file[nul] == 0 {
		nm, has_nm = name_before(file, nul)
	}
	return Sgd5_Record{
		offset        = at,
		has_name      = has_nm,
		name          = nm,
		kind          = file[at - 5],
		packed        = file[at + 12 : at + n],
		unpacked_size = unpacked,
	}, true
}

@(private)
parse_shader :: proc(c: ^Sgd5_Cursor) -> (Sgd5_Shader, bool) {
	name, ok0 := cur_str(c)
	kind, ok1 := cur_u8(c)
	n_u32, ok2 := cur_u32(c)
	if !ok0 || !ok1 || !ok2 {
		return {}, false
	}
	n := int(n_u32)
	offset := c.at
	rec_bytes, ok3 := cur_bytes(c, n)
	if !ok3 {
		return {}, false
	}
	rc := Sgd5_Cursor{file = rec_bytes, at = 0}
	m, ok4 := cur_bytes(&rc, 4)
	n2, ok5 := cur_u32(&rc)
	unpacked, ok6 := cur_u32(&rc)
	if !ok4 || !ok5 || !ok6 ||
		m[0] != SGD5_MARKER[0] || m[1] != SGD5_MARKER[1] || m[2] != SGD5_MARKER[2] || m[3] != SGD5_MARKER[3] ||
		int(n2) != n || int(unpacked) > SGD5_MAX_UNPACKED {
		return {}, false
	}
	hash, ok7 := cur_u64(c)
	_, ok8 := cur_bytes(c, 0x90)
	tail_len, ok9 := cur_u32(c)
	if !ok7 || !ok8 || !ok9 {
		return {}, false
	}
	if _, ok10 := cur_bytes(c, int(tail_len)); !ok10 {
		return {}, false
	}
	return Sgd5_Shader{
		record = Sgd5_Record{
			offset        = offset,
			has_name      = true,
			name          = name,
			kind          = kind,
			packed        = rc.file[12:],
			unpacked_size = int(unpacked),
		},
		hash = hash,
	}, true
}

@(private)
destroy_effect :: proc(e: ^Sgd5_Effect) {
	for &t in e.techniques {
		delete(t.passes)
	}
	delete(e.techniques)
	delete(e.rasterizers)
	delete(e.depth_stencils)
	delete(e.blends)
}

@(private)
parse_effect :: proc(c: ^Sgd5_Cursor, shaders: ^[6][dynamic]Sgd5_Shader, allocator := context.allocator) -> (fx: Sgd5_Effect, ok: bool) {
	name, ok_name := cur_str(c)
	size_u32, ok_sz := cur_u32(c)
	if !ok_name || !ok_sz {
		return fx, false
	}
	size := int(size_u32)

	stages: [6][dynamic]u32
	defer for s := 0; s < 6; s += 1 {
		delete(stages[s])
	}
	for s := 0; s < 6; s += 1 {
		list, ok_l := cur_u32s(c, allocator)
		if !ok_l {
			return fx, false
		}
		stages[s] = list
		for idx in list {
			if int(idx) >= len(shaders[s]) {
				return fx, false
			}
		}
	}

	if _, ok_hdr := cur_bytes(c, 0x50); !ok_hdr {
		return fx, false
	}
	rasterizers, ok_r := cur_items(c, 16, allocator)
	if !ok_r {
		return fx, false
	}
	depth_stencils, ok_d := cur_items(c, 24, allocator)
	if !ok_d {
		delete(rasterizers)
		return fx, false
	}
	blends, ok_b := cur_items(c, 0x44, allocator)
	if !ok_b {
		delete(rasterizers)
		delete(depth_stencils)
		return fx, false
	}
	samplers, ok_smp := cur_items(c, 0x24, allocator)
	if !ok_smp {
		delete(rasterizers)
		delete(depth_stencils)
		delete(blends)
		return fx, false
	}
	delete(samplers)

	techniques_u32, ok_tq := cur_u32s(c, allocator)
	if !ok_tq {
		delete(rasterizers)
		delete(depth_stencils)
		delete(blends)
		return fx, false
	}
	defer delete(techniques_u32)

	passes_raw, ok_ps := cur_items(c, 24, allocator)
	if !ok_ps {
		delete(rasterizers)
		delete(depth_stencils)
		delete(blends)
		return fx, false
	}
	defer delete(passes_raw)

	extra, ok_ex := cur_u32s(c, allocator)
	if !ok_ex {
		delete(rasterizers)
		delete(depth_stencils)
		delete(blends)
		return fx, false
	}
	defer delete(extra)

	loaded := 0
	for s := 0; s < 6; s += 1 {
		loaded += (len(stages[s]) + 1) * 8
	}
	loaded += len(techniques_u32) * 8 + len(passes_raw) * 32 + len(extra) * 4

	strs_u32, ok_st := cur_u32(c)
	if !ok_st {
		delete(rasterizers)
		delete(depth_stencils)
		delete(blends)
		return fx, false
	}
	if strs_u32 != SGD5_SHARED {
		if _, ok_sb := cur_bytes(c, int(strs_u32)); !ok_sb {
			delete(rasterizers)
			delete(depth_stencils)
			delete(blends)
			return fx, false
		}
		loaded += int(strs_u32)
	}

	for _ in 0 ..< 2 {
		n_u32, ok_n := cur_u32(c)
		if !ok_n {
			delete(rasterizers)
			delete(depth_stencils)
			delete(blends)
			return fx, false
		}
		if _, ok_nb := cur_bytes(c, int(n_u32)); !ok_nb {
			delete(rasterizers)
			delete(depth_stencils)
			delete(blends)
			return fx, false
		}
		loaded += int(n_u32)
	}

	blocks_hdr, ok_bh := cur_u32(c)
	if !ok_bh {
		delete(rasterizers)
		delete(depth_stencils)
		delete(blends)
		return fx, false
	}
	blocks := blocks_hdr & 0x00FF_FFFF
	if blocks != 0 {
		loaded = ((loaded + 7) / 8) * 8 + int(blocks) * 8
	}
	for _ in 0 ..< blocks {
		blk, ok_blk := cur_u32(c)
		if !ok_blk {
			delete(rasterizers)
			delete(depth_stencils)
			delete(blends)
			return fx, false
		}
		if blk == SGD5_SHARED {
			if _, ok_h := cur_u32(c); !ok_h {
				delete(rasterizers)
				delete(depth_stencils)
				delete(blends)
				return fx, false
			}
		} else {
			if _, ok_bb := cur_bytes(c, int(blk)); !ok_bb {
				delete(rasterizers)
				delete(depth_stencils)
				delete(blends)
				return fx, false
			}
			loaded += int(blk)
		}
	}

	names_len, ok_nl := cur_u32(c)
	if !ok_nl {
		delete(rasterizers)
		delete(depth_stencils)
		delete(blends)
		return fx, false
	}
	names, ok_nb := cur_bytes(c, int(names_len))
	if !ok_nb || loaded + len(names) != size {
		delete(rasterizers)
		delete(depth_stencils)
		delete(blends)
		return fx, false
	}

	fx.name = name
	fx.rasterizers = rasterizers
	fx.depth_stencils = depth_stencils
	fx.blends = blends
	fx.techniques = make([dynamic]Sgd5_Technique, 0, len(techniques_u32), allocator)

	for t in techniques_u32 {
		at := int(t & 0x7FFF)
		if at >= len(names) {
			destroy_effect(&fx)
			return {}, false
		}
		nul_idx := -1
		for i := at; i < len(names); i += 1 {
			if names[i] == 0 {
				nul_idx = i
				break
			}
		}
		if nul_idx < 0 {
			destroy_effect(&fx)
			return {}, false
		}
		t_name := string(names[at:nul_idx])
		first := int((t >> 15) & 0x1FF)
		count := int(t >> 24)
		if first + count > len(passes_raw) {
			destroy_effect(&fx)
			return {}, false
		}

		tech := Sgd5_Technique{
			name   = t_name,
			passes = make([dynamic]Sgd5_Pass, 0, count, allocator),
		}
		for p_idx := first; p_idx < first + count; p_idx += 1 {
			p := passes_raw[p_idx]
			flags := p[10]
			pass: Sgd5_Pass
			if (flags & 8) != 0 {
				pass.has_stencil_ref = true
				pass.stencil_ref = p[9]
			}
			for slot := 0; slot < 6; slot += 1 {
				if p[slot] != 0 {
					s_idx := int(p[slot]) - 1
					if s_idx >= len(stages[slot]) {
						delete(tech.passes)
						destroy_effect(&fx)
						return {}, false
					}
					pass.has_shader[slot] = true
					pass.shaders[slot] = int(stages[slot][s_idx])
				}
			}
			if (flags & 1) != 0 {
				ri := int(p[6])
				if ri >= len(rasterizers) {
					delete(tech.passes)
					destroy_effect(&fx)
					return {}, false
				}
				pass.has_rasterizer = true
				pass.rasterizer = rasterizers[ri]
			}
			if (flags & 2) != 0 {
				di := int(p[7]) + int((flags >> 6) & 1) * 256
				if di >= len(depth_stencils) {
					delete(tech.passes)
					destroy_effect(&fx)
					return {}, false
				}
				pass.has_depth_stencil = true
				pass.depth_stencil = depth_stencils[di]
			}
			if (flags & 4) != 0 {
				bi := int(p[8]) + int(flags >> 7) * 256
				if bi >= len(blends) {
					delete(tech.passes)
					destroy_effect(&fx)
					return {}, false
				}
				pass.has_blend = true
				pass.blend = blends[bi]
			}
			append(&tech.passes, pass)
		}
		append(&fx.techniques, tech)
	}

	return fx, true
}

@(private)
parse_database :: proc(file: []u8, start: int, allocator := context.allocator) -> (db: Sgd5_Database, ok: bool) {
	c := Sgd5_Cursor{file = file, at = start}
	magic, ok_m := cur_bytes(&c, 4)
	if !ok_m || magic[0] != 'S' || magic[1] != 'G' || magic[2] != 'D' || magic[3] != '5' {
		return db, false
	}
	if _, ok_hdr := cur_u64(&c); !ok_hdr {
		return db, false
	}
	shared_cnt, ok_sc := cur_u32(&c)
	if !ok_sc {
		return db, false
	}
	for _ in 0 ..< shared_cnt {
		sz, ok_s := cur_u32(&c)
		if !ok_s do return db, false
		if _, ok_b := cur_bytes(&c, int(sz)); !ok_b do return db, false
	}
	str_sz, ok_ss := cur_u32(&c)
	if !ok_ss do return db, false
	if _, ok_sb := cur_bytes(&c, int(str_sz)); !ok_sb do return db, false

	db.start = start
	for s := 0; s < 6; s += 1 {
		cnt, ok_cnt := cur_u32(&c)
		if !ok_cnt {
			destroy_sgd5_database(&db)
			return {}, false
		}
		db.shaders[s] = make([dynamic]Sgd5_Shader, 0, int(cnt), allocator)
		for _ in 0 ..< cnt {
			sh, ok_sh := parse_shader(&c)
			if !ok_sh {
				destroy_sgd5_database(&db)
				return {}, false
			}
			append(&db.shaders[s], sh)
		}
	}

	fx_cnt, ok_fc := cur_u32(&c)
	if !ok_fc {
		destroy_sgd5_database(&db)
		return {}, false
	}
	db.effects = make([dynamic]Sgd5_Effect, 0, int(fx_cnt), allocator)
	for _ in 0 ..< fx_cnt {
		fx, ok_fx := parse_effect(&c, &db.shaders, allocator)
		if !ok_fx {
			destroy_sgd5_database(&db)
			return {}, false
		}
		append(&db.effects, fx)
	}
	db.end = c.at
	return db, true
}

destroy_sgd5_database :: proc(db: ^Sgd5_Database) {
	for s := 0; s < 6; s += 1 {
		delete(db.shaders[s])
	}
	for &fx in db.effects {
		destroy_effect(&fx)
	}
	delete(db.effects)
	db^ = {}
}

destroy_sgd5_databases :: proc(dbs: ^[dynamic]Sgd5_Database) {
	for &db in dbs {
		destroy_sgd5_database(&db)
	}
	delete(dbs^)
}

sgd5_databases :: proc(file: []u8, allocator := context.allocator) -> [dynamic]Sgd5_Database {
	out := make([dynamic]Sgd5_Database, allocator)
	from := 0
	for {
		at, found := find_4byte_pattern(file, SGD5_MAGIC, from)
		if !found {
			break
		}
		if db, ok := parse_database(file, at, allocator); ok {
			from = db.end
			append(&out, db)
		} else {
			from = at + 1
		}
	}
	return out
}

sgd5_records :: proc(file: []u8, allocator := context.allocator) -> [dynamic]Sgd5_Record {
	dbs := sgd5_databases(file, allocator)
	defer destroy_sgd5_databases(&dbs)

	out := make([dynamic]Sgd5_Record, allocator)
	if len(dbs) == 0 {
		from := 0
		for {
			at, found := find_4byte_pattern(file, SGD5_MARKER, from)
			if !found {
				break
			}
			if rec, ok := record_at_marker(file, at); ok {
				append(&out, rec)
			}
			from = at + 1
		}
		return out
	}

	for &db in dbs {
		for s := 0; s < 6; s += 1 {
			for &sh in db.shaders[s] {
				append(&out, sh.record)
			}
		}
	}
	return out
}
