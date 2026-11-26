package vasperty_game

import "core:os"
import "core:slice"
import "core:sync"
import "core:thread"

STATE_DEPTH :: 24
STATE_RASTER :: 16
STATE_BLEND :: 68

DEFAULT_TARGET := [8]u8{0, 2, 1, 1, 2, 1, 1, 15}

State_Source :: enum {
	Database,
	Registers,
	Enumeration,
}

Named_States :: struct {
	depth:  map[u64][STATE_DEPTH]u8,
	raster: map[u64][STATE_RASTER]u8,
	blend:  map[u64][STATE_BLEND]u8,
	source: map[u64]State_Source,
}

destroy_named_states :: proc(n: ^Named_States) {
	delete(n.depth)
	delete(n.raster)
	delete(n.blend)
	delete(n.source)
	n^ = {}
}

@(private)
put_u32_le :: #force_inline proc(dst: []u8, at: int, v: u32) {
	dst[at + 0] = u8(v)
	dst[at + 1] = u8(v >> 8)
	dst[at + 2] = u8(v >> 16)
	dst[at + 3] = u8(v >> 24)
}

@(private)
put_u64_le :: #force_inline proc(dst: []u8, at: int, v: u64) {
	put_u32_le(dst, at, u32(v))
	put_u32_le(dst, at + 4, u32(v >> 32))
}

@(private)
f32_to_bits :: #force_inline proc "contextless" (v: f32) -> u32 {
	return transmute(u32)v
}

@(private)
SLOPES := [29]f32{
	0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 8.0, 10.0, 16.0, 0.25, 0.1, 0.01, 0.001, -0.5,
	-1.0, -1.5, -2.0, -4.0, 0.75, 1.25, 6.0, 7.0, 20.0, 32.0, 64.0, 100.0,
}

@(private)
MASKS := [19]u8{
	0xFF, 0x0F, 0xF0, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x03, 0x07, 0x0C, 0x30, 0xC0,
	0x00, 0x7F, 0xFE,
}

@(private)
RASTER_BIASES := [43]i8{
	-16, -15, -14, -13, -12, -11, -10, -9, -8, -7, -6, -5, -4, -3, -2, -1, 0,
	1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
	-128, 127, 100, -100, 50, -50, 64, -64, 32, -32,
}

@(private)
Raster_Slice :: struct {
	fill: u8,
	cull: u8,
	ccw:  u8,
}

@(private)
Depth_Slice :: struct {
	enable: u8,
	write:  u8,
	func:   u8,
}

@(private)
Raster_Resolve_Ctx :: struct {
	want:      ^map[u64]bool,
	slices:    []Raster_Slice,
	cursor:    int,
	remaining: int,
	mu:        sync.Mutex,
	found:     map[u64][STATE_RASTER]u8,
}

@(private)
raster_worker :: proc(ctx: ^Raster_Resolve_Ctx) {
	for {
		if sync.atomic_load(&ctx.remaining) == 0 {
			return
		}
		idx := sync.atomic_add(&ctx.cursor, 1)
		if idx >= len(ctx.slices) {
			return
		}
		sl := ctx.slices[idx]
		for tail_bits: u8 = 0; tail_bits < 32; tail_bits += 1 {
			b: [STATE_RASTER]u8
			b[0] = sl.fill
			b[1] = sl.cull
			b[2] = sl.ccw
			b[12] = tail_bits & 1
			b[13] = (tail_bits >> 1) & 1
			b[14] = (tail_bits >> 2) & 1
			b[15] = tail_bits >> 3
			if !raster_check(ctx, &b) {
				return
			}
			for bias in RASTER_BIASES {
				for slope in SLOPES {
					if bias == 0 && slope == 0.0 {
						continue
					}
					b[3] = u8(bias)
					put_u32_le(b[:], 8, f32_to_bits(slope))
					if !raster_check(ctx, &b) {
						return
					}
				}
			}
		}
	}
}

@(private)
raster_check :: #force_inline proc(ctx: ^Raster_Resolve_Ctx, b: ^[STATE_RASTER]u8) -> bool {
	if sync.atomic_load(&ctx.remaining) == 0 {
		return false
	}
	h := city64(b[:])
	if h in ctx.want {
		sync.mutex_lock(&ctx.mu)
		if !(h in ctx.found) {
			ctx.found[h] = b^
			left := len(ctx.want) - len(ctx.found)
			sync.atomic_store(&ctx.remaining, max(0, left))
		}
		sync.mutex_unlock(&ctx.mu)
	}
	return sync.atomic_load(&ctx.remaining) > 0
}

resolve_raster_hashes :: proc(want: ^map[u64]bool, allocator := context.allocator) -> map[u64][STATE_RASTER]u8 {
	out := make(map[u64][STATE_RASTER]u8, allocator)
	if len(want) == 0 {
		return out
	}
	slices := make([dynamic]Raster_Slice, 0, 12, allocator)
	defer delete(slices)
	for fill in ([2]u8{2, 3}) {
		for cull in ([3]u8{1, 2, 3}) {
			for ccw in ([2]u8{0, 1}) {
				append(&slices, Raster_Slice{fill = fill, cull = cull, ccw = ccw})
			}
		}
	}

	ctx := Raster_Resolve_Ctx{
		want      = want,
		slices    = slices[:],
		remaining = len(want),
		found     = out,
	}
	n_workers := min(max(1, os.get_processor_core_count()), len(slices))
	workers := make([dynamic]^thread.Thread, 0, n_workers, allocator)
	defer delete(workers)

	for _ in 0 ..< n_workers {
		append(&workers, thread.create_and_start_with_poly_data(&ctx, raster_worker, init_context = context))
	}
	for th in workers {
		thread.join(th)
		thread.destroy(th)
	}
	return ctx.found
}

@(private)
Depth_Resolve_Ctx :: struct {
	want:      ^map[u64]bool,
	slices:    []Depth_Slice,
	cursor:    int,
	remaining: int,
	mu:        sync.Mutex,
	found:     map[u64][STATE_DEPTH]u8,
}

@(private)
depth_check :: #force_inline proc(ctx: ^Depth_Resolve_Ctx, b: ^[STATE_DEPTH]u8) -> bool {
	if sync.atomic_load(&ctx.remaining) == 0 {
		return false
	}
	h := city64(b[:])
	if h in ctx.want {
		sync.mutex_lock(&ctx.mu)
		if !(h in ctx.found) {
			ctx.found[h] = b^
			left := len(ctx.want) - len(ctx.found)
			sync.atomic_store(&ctx.remaining, max(0, left))
		}
		sync.mutex_unlock(&ctx.mu)
	}
	return sync.atomic_load(&ctx.remaining) > 0
}

@(private)
depth_worker :: proc(ctx: ^Depth_Resolve_Ctx) {
	tails := [4][2]u8{{1, 1}, {0, 0}, {1, 0}, {0, 1}}
	for {
		if sync.atomic_load(&ctx.remaining) == 0 {
			return
		}
		idx := sync.atomic_add(&ctx.cursor, 1)
		if idx >= len(ctx.slices) {
			return
		}
		sl := ctx.slices[idx]
		for tl in tails {
			b := [STATE_DEPTH]u8{
				sl.enable, sl.write, sl.func, 0, 0xFF, 0xFF,
				1, 1, 1, 8, 1, 1, 1, 8,
				0, 0, 0, 0, 0, 0, 0, 0,
				tl[0], tl[1],
			}
			if !depth_check(ctx, &b) {
				return
			}
		}
		for rd in MASKS {
			for wr in MASKS {
				for ops: u8 = 0; ops < 27; ops += 1 {
					for sf: u8 = 1; sf <= 8; sf += 1 {
						f0 := (ops % 3) + 1
						f1 := ((ops / 3) % 3) + 1
						f2 := (ops / 9) + 1
						b := [STATE_DEPTH]u8{
							sl.enable, sl.write, sl.func, 1, rd, wr,
							f0, f1, f2, sf, f0, f1, f2, sf,
							0, 0, 0, 0, 0, 0, 0, 0,
							1, 1,
						}
						if !depth_check(ctx, &b) {
							return
						}
					}
				}
			}
		}
	}
}

resolve_depth_hashes :: proc(want: ^map[u64]bool, allocator := context.allocator) -> map[u64][STATE_DEPTH]u8 {
	out := make(map[u64][STATE_DEPTH]u8, allocator)
	if len(want) == 0 {
		return out
	}
	slices := make([dynamic]Depth_Slice, 0, 32, allocator)
	defer delete(slices)
	for enable in ([2]u8{0, 1}) {
		for write in ([2]u8{0, 1}) {
			for func: u8 = 1; func <= 8; func += 1 {
				append(&slices, Depth_Slice{enable = enable, write = write, func = func})
			}
		}
	}

	ctx := Depth_Resolve_Ctx{
		want      = want,
		slices    = slices[:],
		remaining = len(want),
		found     = out,
	}
	n_workers := min(max(1, os.get_processor_core_count()), len(slices))
	workers := make([dynamic]^thread.Thread, 0, n_workers, allocator)
	defer delete(workers)

	for _ in 0 ..< n_workers {
		append(&workers, thread.create_and_start_with_poly_data(&ctx, depth_worker, init_context = context))
	}
	for th in workers {
		thread.join(th)
		thread.destroy(th)
	}
	return ctx.found
}

@(private)
extract_registers :: proc(packet: []u8) -> ([14]u32, bool) {
	tag, ok_tag := u32_at(packet, 4)
	if !ok_tag {
		return {}, false
	}
	base := 0x74 if tag == 4 else 0xC8
	regs: [14]u32
	for i := 0; i < 14; i += 1 {
		v, ok_v := u32_at(packet, base + 0x44 + 4 * i)
		if !ok_v {
			return {}, false
		}
		regs[i] = v
	}
	return regs, true
}

@(private)
hw_func :: #force_inline proc(v: u32) -> u8 {
	return u8(v & 7) + 1
}

@(private)
hw_stencil_op :: proc(v: u32) -> u8 {
	switch v & 15 {
	case 0:
		return 1
	case 1:
		return 2
	case 3, 4:
		return 3
	case 5:
		return 4
	case 6:
		return 5
	case 7:
		return 6
	case 8:
		return 7
	case 9:
		return 8
	case:
		return 1
	}
}

@(private)
hw_factor :: proc(v: u32) -> (u8, bool) {
	low := v & 31
	if low <= 10 || (low >= 13 && low <= 20) {
		return u8(low) + 1, true
	}
	return 0, false
}

@(private)
hw_combine :: proc(v: u32) -> (u8, bool) {
	switch v & 7 {
	case 0:
		return 1, true
	case 1:
		return 2, true
	case 4:
		return 3, true
	case 2:
		return 4, true
	case 3:
		return 5, true
	case:
		return 0, false
	}
}

@(private)
blend_target_candidates :: proc(control: u32, mask: u8, allocator := context.allocator) -> [dynamic][8]u8 {
	out := make([dynamic][8]u8, allocator)
	if ((control >> 30) & 1) == 0 {
		defaults := [6][6]u8{
			{2, 1, 1, 2, 1, 1},
			{5, 6, 1, 2, 6, 1},
			{5, 6, 1, 5, 6, 1},
			{2, 2, 1, 2, 2, 1},
			{2, 6, 1, 2, 6, 1},
			{1, 1, 1, 1, 1, 1},
		}
		for f in defaults {
			append(&out, [8]u8{0, f[0], f[1], f[2], f[3], f[4], f[5], mask})
		}
		return out
	}

	s, ok0 := hw_factor(control)
	op, ok1 := hw_combine(control >> 5)
	d, ok2 := hw_factor(control >> 8)
	sa, ok3 := s, ok0
	opa, ok4 := op, ok1
	da, ok5 := d, ok2
	if ((control >> 29) & 1) != 0 {
		sa, ok3 = hw_factor(control >> 16)
		opa, ok4 = hw_combine(control >> 21)
		da, ok5 = hw_factor(control >> 24)
	}
	if !(ok0 && ok1 && ok2 && ok3 && ok4 && ok5) {
		return out
	}

	alpha_twins :: proc(f: u8) -> (res: [2]u8, count: int) {
		res[0] = f
		count = 1
		aliases := [6][2]u8{{3, 5}, {4, 6}, {9, 7}, {10, 8}, {16, 18}, {17, 19}}
		for a in aliases {
			if a[1] == f {
				res[1] = a[0]
				count = 2
				break
			}
		}
		return res, count
	}

	sas, san := alpha_twins(sa)
	das, dan := alpha_twins(da)
	for i := 0; i < san; i += 1 {
		for j := 0; j < dan; j += 1 {
			append(&out, [8]u8{1, s, d, op, sas[i], das[j], opa, mask})
		}
	}
	return out
}

@(private)
try_insert_depth :: proc(named: ^Named_States, want: ^map[u64]bool, src: State_Source, b: []u8) {
	if len(b) != STATE_DEPTH do return
	arr: [STATE_DEPTH]u8
	copy(arr[:], b)
	h := city64(arr[:])
	if h in want {
		delete_key(want, h)
		named.depth[h] = arr
		named.source[h] = src
	}
}

@(private)
try_insert_raster :: proc(named: ^Named_States, want: ^map[u64]bool, src: State_Source, b: []u8) {
	if len(b) != STATE_RASTER do return
	arr: [STATE_RASTER]u8
	copy(arr[:], b)
	h := city64(arr[:])
	if h in want {
		delete_key(want, h)
		named.raster[h] = arr
		named.source[h] = src
	}
}

@(private)
try_insert_blend :: proc(named: ^Named_States, want: ^map[u64]bool, src: State_Source, b: []u8) {
	if len(b) != STATE_BLEND do return
	arr: [STATE_BLEND]u8
	copy(arr[:], b)
	h := city64(arr[:])
	if h in want {
		delete_key(want, h)
		named.blend[h] = arr
		named.source[h] = src
	}
}

blend_candidates_from_registers :: proc(
	regs: ^[14]u32,
	formats: ^[8]u8,
	user: rawptr,
	cb: proc(user: rawptr, cand: ^[STATE_BLEND]u8),
	allocator := context.allocator,
) {
	target_mask := regs[5]
	per_target: [8][dynamic][8]u8
	defer for i := 0; i < 8; i += 1 {
		delete(per_target[i])
	}

	for i := 0; i < 8; i += 1 {
		control := regs[6 + i]
		m := u8((target_mask >> uint(4 * i)) & 15)
		masks := make([dynamic]u8, 0, 4, allocator)
		defer delete(masks)
		append(&masks, m)
		if formats[i] == 0 {
			append(&masks, 0, 15)
			if i > 0 {
				append(&masks, u8(target_mask & 15))
			}
			slice.sort(masks[:])
		}
		c := make([dynamic][8]u8, allocator)
		prev_m: u8 = 255
		for mv, k in masks {
			if k > 0 && mv == prev_m {
				continue
			}
			prev_m = mv
			sub := blend_target_candidates(control, mv, allocator)
			for item in sub do append(&c, item)
			delete(sub)
		}
		if formats[i] == 0 {
			cleared := DEFAULT_TARGET
			cleared[7] = 0
			append(&c, DEFAULT_TARGET, cleared)
		}
		per_target[i] = c
	}

	for i := 0; i < 8; i += 1 {
		if len(per_target[i]) == 0 do return
	}

	emit_blend :: #force_inline proc(a2c, ind: u8, targets: ^[8][8]u8, user: rawptr, cb: proc(user: rawptr, cand: ^[STATE_BLEND]u8)) {
		b: [STATE_BLEND]u8
		b[0] = a2c
		b[1] = ind
		for t := 0; t < 8; t += 1 {
			copy(b[4 + 8 * t : 12 + 8 * t], targets[t][:])
		}
		cb(user, &b)
	}

	for ind: u8 = 0; ind <= 1; ind += 1 {
		for a2c: u8 = 0; a2c <= 1; a2c += 1 {
			if ind == 1 {
				first: [8][8]u8
				for i := 0; i < 8; i += 1 {
					first[i] = per_target[i][0]
				}
				// Pass split bases + single-target mutations
				for split := -1; split <= 8; split += 1 {
					base := first
					if split >= 0 {
						for i := 0; i < 8; i += 1 {
							if formats[i] == 0 {
								base[i] = DEFAULT_TARGET
								base[i][7] = 0 if i < split else 15
							}
						}
					}
					emit_blend(a2c, ind, &base, user, cb)
					for i := 0; i < 8; i += 1 {
						for t in per_target[i] {
							mut := base
							mut[i] = t
							emit_blend(a2c, ind, &mut, user, cb)
						}
					}
				}
			} else {
				for c0 in per_target[0] {
					all_c0: [8][8]u8
					for i := 0; i < 8; i += 1 do all_c0[i] = c0
					emit_blend(a2c, ind, &all_c0, user, cb)

					keep_off := c0
					keep_off[7] = 0
					default_off := DEFAULT_TARGET
					default_off[7] = 0
					off := c0
					off[0] = 0
					off[7] = 0
					disabled := c0
					disabled[0] = 0
					fills := [6][8]u8{DEFAULT_TARGET, keep_off, default_off, {}, off, disabled}
					for fill in fills {
						for n := 1; n < 8; n += 1 {
							targets: [8][8]u8
							for i := 0; i < 8; i += 1 {
								targets[i] = c0 if i < n else fill
							}
							emit_blend(a2c, ind, &targets, user, cb)
						}
					}
				}
			}
		}
	}
}

@(private)
depth_from_registers :: proc(
	regs: ^[14]u32,
	named: ^Named_States,
	want: ^map[u64]bool,
) {
	control := regs[0]
	stencil := regs[1]
	mask := regs[2]
	stencil_on := u8(control & 1)
	depth_on := ((control >> 1) & 1) != 0
	off := [4]u8{1, 1, 1, 8}

	front, back := off, off
	m0, m1 := u32(0xFF), u32(0xFF)
	if stencil_on != 0 {
		front = {
			hw_stencil_op(stencil),
			hw_stencil_op(stencil >> 8),
			hw_stencil_op(stencil >> 4),
			hw_func(control >> 8),
		}
		if ((control >> 7) & 1) != 0 {
			back = {
				hw_stencil_op(stencil >> 12),
				hw_stencil_op(stencil >> 20),
				hw_stencil_op(stencil >> 16),
				hw_func(control >> 20),
			}
		} else {
			back = front
		}
		m0 = (mask >> 8) & 0xFF
		m1 = (mask >> 16) & 0xFF
	}

	e_arr: [2]u8 = {1, 0} if depth_on else {0, 1}
	e_cnt := 1 if depth_on else 2
	w_arr: [2]u8 = {u8((control >> 2) & 1), 0} if depth_on else {0, 1}
	w_cnt := 1 if depth_on else 2
	f_arr: [8]u8 = {hw_func(control >> 4), 0, 0, 0, 0, 0, 0, 0} if depth_on else {1, 2, 3, 4, 5, 6, 7, 8}
	f_cnt := 1 if depth_on else 8

	face_pairs := [2][2][4]u8{{front, back}, {front, off}}
	face_cnt := 2 if stencil_on != 0 else 1

	for ei := 0; ei < e_cnt; ei += 1 {
		for wi := 0; wi < w_cnt; wi += 1 {
			for fi := 0; fi < f_cnt; fi += 1 {
				for fpi := 0; fpi < face_cnt; fpi += 1 {
					b := [STATE_DEPTH]u8{
						e_arr[ei], w_arr[wi], f_arr[fi], stencil_on, u8(m0), u8(m1),
						face_pairs[fpi][0][0], face_pairs[fpi][0][1], face_pairs[fpi][0][2], face_pairs[fpi][0][3],
						face_pairs[fpi][1][0], face_pairs[fpi][1][1], face_pairs[fpi][1][2], face_pairs[fpi][1][3],
						0, 0, 0, 0, 0, 0, 0, 0,
						1, 1,
					}
					try_insert_depth(named, want, .Registers, b[:])
					if stencil_on == 0 {
						b[4] = u8(mask >> 8)
						b[5] = u8(mask >> 16)
						try_insert_depth(named, want, .Registers, b[:])
					}
				}
			}
		}
	}
}

@(private)
Register_Blend_Key :: struct {
	dh:      u64,
	bh:      u64,
	formats: [8]u8,
	regs:    [14]u32,
}

@(private)
Blend_CB_Env :: struct {
	named: ^Named_States,
	want:  ^map[u64]bool,
}

find_named_states :: proc(pack: ^Shader_Pack, databases: []Sgd5_Database, allocator := context.allocator) -> Named_States {
	want_d := make(map[u64]bool, allocator)
	want_r := make(map[u64]bool, allocator)
	want_b := make(map[u64]bool, allocator)
	defer {
		delete(want_d)
		delete(want_r)
		delete(want_b)
	}

	ng := pack_graphics_count(pack)
	for i := 0; i < ng; i += 1 {
		g, _ := pack_graphics(pack, i)
		want_d[g.depth_stencil_hash] = true
		want_r[g.rasterizer_hash] = true
		want_b[g.blend_hash] = true
	}

	named := Named_States{
		depth  = make(map[u64][STATE_DEPTH]u8, allocator),
		raster = make(map[u64][STATE_RASTER]u8, allocator),
		blend  = make(map[u64][STATE_BLEND]u8, allocator),
		source = make(map[u64]State_Source, allocator),
	}

	for &db in databases {
		for &e in db.effects {
			for b in e.depth_stencils do try_insert_depth(&named, &want_d, .Database, b)
			for b in e.rasterizers    do try_insert_raster(&named, &want_r, .Database, b)
			for b in e.blends         do try_insert_blend(&named, &want_b, .Database, b)
		}
	}

	tried := make(map[Register_Blend_Key]bool, allocator)
	defer delete(tried)
	cb_env := Blend_CB_Env{named = &named, want = &want_b}
	blend_cb :: proc(user: rawptr, cand: ^[STATE_BLEND]u8) {
		env := (^Blend_CB_Env)(user)
		try_insert_blend(env.named, env.want, .Registers, cand[:])
	}

	for i := 0; i < ng; i += 1 {
		g, _ := pack_graphics(pack, i)
		regs, ok_r := extract_registers(g.packet)
		fmts, ok_f := graphics_target_formats(&g)
		if !ok_r || !ok_f do continue
		key := Register_Blend_Key{dh = g.depth_stencil_hash, bh = g.blend_hash, formats = fmts, regs = regs}
		if key in tried do continue
		tried[key] = true
		if g.depth_stencil_hash in want_d {
			depth_from_registers(&regs, &named, &want_d)
		}
		if g.blend_hash in want_b {
			blend_candidates_from_registers(&regs, &fmts, &cb_env, blend_cb, allocator)
		}
	}

	if len(want_d) > 0 {
		found_d := resolve_depth_hashes(&want_d, allocator)
		for h, b in found_d {
			delete_key(&want_d, h)
			named.depth[h] = b
			named.source[h] = .Enumeration
		}
		delete(found_d)
	}
	if len(want_r) > 0 {
		found_r := resolve_raster_hashes(&want_r, allocator)
		for h, b in found_r {
			delete_key(&want_r, h)
			named.raster[h] = b
			named.source[h] = .Enumeration
		}
		delete(found_r)
	}

	return named
}

@(private)
stencil_writes :: proc(c: ^[STATE_DEPTH]u8) -> bool {
	face_writes :: #force_inline proc(c: ^[STATE_DEPTH]u8, off: int) -> bool {
		if (c[off + 3] == 1 || c[off + 2] == 1) && (c[off + 3] == 8 || c[off] == 1) {
			return c[off + 1] != 1 && (c[0] & 1) != 0 && c[2] != 8
		}
		return true
	}
	return c[3] == 1 && c[5] != 0 && (face_writes(c, 6) || face_writes(c, 10))
}

depth_stencil_desc :: proc(c: ^[STATE_DEPTH]u8) -> [0x38]u8 {
	d: [0x38]u8
	put_u32_le(d[:], 0x00, u32(c[0]))
	put_u32_le(d[:], 0x04, u32(c[1]) if c[0] != 0 else 0)
	put_u32_le(d[:], 0x08, u32(c[2]))
	put_u32_le(d[:], 0x0C, u32(c[3]))
	for i := 0; i < 8; i += 1 {
		put_u32_le(d[:], 0x14 + 4 * i, u32(c[6 + i]))
	}
	put_u32_le(d[:], 0x34, u32(c[15]))
	d[0x10] = c[4]
	d[0x11] = c[5] if stencil_writes(c) else 0
	return d
}

rasterizer_desc :: proc(c: ^[STATE_RASTER]u8) -> [0x2C]u8 {
	d: [0x2C]u8
	w0 := u32(c[0])
	w1 := u32(c[1])
	w2 := u32(c[2])
	w3 := u32(i32(i8(c[3])))
	w4, _ := u32_at(c[:], 4)
	w5, _ := u32_at(c[:], 8)
	words := [11]u32{
		w0, w1, w2, w3, w4, w5,
		u32(c[12]), u32(c[14]), u32(c[15] & 1), 0, u32((c[15] >> 1) & 1),
	}
	for w, i in words {
		put_u32_le(d[:], 4 * i, w)
	}
	return d
}

blend_desc :: proc(c: ^[STATE_BLEND]u8) -> [0x148]u8 {
	d: [0x148]u8
	d[0] = c[0]
	d[4] = c[1]
	for i := 0; i < 8; i += 1 {
		t := c[4 + 8 * i : 12 + 8 * i]
		at := 8 + 40 * i
		words := [9]u8{t[0], 0, t[1], t[2], t[3], t[4], t[5], t[6], 4}
		for w, k in words {
			d[at + 4 * k] = w
		}
		d[at + 36] = t[7]
	}
	return d
}

Stream_Error :: enum {
	None,
	Missing_Depth_Stencil,
	Missing_Rasterizer,
	Missing_Blend,
	Invalid_Metadata,
}

Pipeline_Stream :: struct {
	bytes:    [0x2B0]u8,
	elements: [dynamic][32]u8,
	names:    [dynamic][]u8,
}

destroy_pipeline_stream :: proc(s: ^Pipeline_Stream, allocator := context.allocator) {
	for nm in s.names {
		delete(nm, allocator)
	}
	delete(s.names)
	delete(s.elements)
	s^ = {}
}

build_pipeline_stream :: proc(
	g: ^Graphics_Record,
	named: ^Named_States,
	first: []u8,
	mesh: bool,
	has_pixel: bool,
	pixel: []u8,
	allocator := context.allocator,
) -> (s: Pipeline_Stream, err: Stream_Error) {
	depth, ok_d := named.depth[g.depth_stencil_hash]
	if !ok_d do return s, .Missing_Depth_Stencil
	raster, ok_r := named.raster[g.rasterizer_hash]
	if !ok_r do return s, .Missing_Rasterizer
	blend, ok_b := named.blend[g.blend_hash]
	if !ok_b do return s, .Missing_Blend

	fmts, ok_f := graphics_target_formats(g)
	dtt, ok_dtt := func_dtt(g)
	_, count, quality, ok_smp := func_samples(g)
	inputs, ok_inp := graphics_input_layout(g, allocator)
	if !ok_f || !ok_dtt || !ok_smp || !ok_inp {
		if ok_inp do destroy_input_layout(&inputs, allocator)
		return s, .Invalid_Metadata
	}
	defer destroy_input_layout(&inputs, allocator)

	kinds := [14][2]u32{
		{0x10, 24 if mesh else 1},
		{0x28, 2}, {0x40, 3}, {0x58, 4}, {0x70, 5}, {0x88, 8},
		{0x1D8, 9}, {0x1E0, 10}, {0x210, 21}, {0x250, 17},
		{0x260, 12}, {0x278, 14}, {0x280, 15}, {0x2A8, 16},
	}
	for kv in kinds {
		put_u32_le(s.bytes[:], int(kv[0]), kv[1])
	}
	put_u64_le(s.bytes[:], 0x18, u64(uintptr(raw_data(first))))
	put_u64_le(s.bytes[:], 0x20, u64(len(first)))
	if has_pixel {
		put_u64_le(s.bytes[:], 0x30, u64(uintptr(raw_data(pixel))))
		put_u64_le(s.bytes[:], 0x38, u64(len(pixel)))
	}
	bd := blend_desc(&blend)
	copy(s.bytes[0x8C:0x1D4], bd[:])
	put_u32_le(s.bytes[:], 0x1DC, max(u32))
	rd := rasterizer_desc(&raster)
	copy(s.bytes[0x1E4:0x210], rd[:])
	dd := depth_stencil_desc(&depth)
	copy(s.bytes[0x214:0x24C], dd[:])

	valid_cnt := count == 1 || count == 2 || count == 4 || count == 8 || count == 16
	if !valid_cnt {
		count = 1
		quality = 0
	}
	put_u32_le(s.bytes[:], 0x254, count)
	put_u32_le(s.bytes[:], 0x258, quality)

	s.names = make([dynamic][]u8, 0, len(inputs), allocator)
	s.elements = make([dynamic][32]u8, 0, len(inputs), allocator)
	for &e in inputs {
		nb := make([]u8, len(e.semantic) + 1, allocator)
		copy(nb[:len(e.semantic)], e.semantic)
		nb[len(e.semantic)] = 0
		append(&s.names, nb)

		elem: [32]u8
		put_u64_le(elem[:], 0, u64(uintptr(raw_data(nb))))
		words := [6]u32{e.index, e.format, e.slot, e.offset, e.class, e.step_rate}
		for w, idx in words {
			put_u32_le(elem[:], 8 + 4 * idx, w)
		}
		append(&s.elements, elem)
	}
	if len(s.elements) > 0 {
		put_u64_le(s.bytes[:], 0x268, u64(uintptr(raw_data(s.elements[:]))))
		put_u32_le(s.bytes[:], 0x270, u32(len(s.elements)))
	}
	put_u32_le(s.bytes[:], 0x27C, u32(dtt[2]))
	for f, idx in fmts {
		put_u32_le(s.bytes[:], 0x284 + 4 * idx, u32(f))
	}
	targets := 0
	for i := 7; i >= 0; i -= 1 {
		if fmts[i] != 0 {
			targets = i + 1
			break
		}
	}
	put_u32_le(s.bytes[:], 0x2A4, u32(targets))
	put_u32_le(s.bytes[:], 0x2AC, u32(dtt[0]))
	return s, .None
}

@(private)
func_dtt :: proc(g: ^Graphics_Record) -> ([3]u8, bool) {
	if len(g.metadata) < 0x27 do return {}, false
	return {g.metadata[0x24], g.metadata[0x25], g.metadata[0x26]}, true
}

@(private)
func_samples :: proc(g: ^Graphics_Record) -> (mask, count, quality: u32, ok: bool) {
	m, ok0 := u32_at(g.metadata, 0x1C)
	c, ok1 := u32_at(g.metadata, 0x28)
	q, ok2 := u32_at(g.metadata, 0x2C)
	if !ok0 || !ok1 || !ok2 do return 0, 0, 0, false
	return m, c, q, true
}
