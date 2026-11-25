package vasperty_shader

import "core:compress/deflate"

// Native GFX10 container decoder: XDAT -> XBCH (zlib) -> FSSM and ACCC -> FSPX.

Hw_Stage :: enum {
	Ls,
	Hs,
	Es,
	Gs,
	Vs,
	Ps,
	Ms,
	Cs,
}

hw_stage_user_sgpr :: proc(s: Hw_Stage, index: u8) -> u8 {
	switch s {
	case .Ls, .Hs, .Es, .Gs, .Ms:
		return index + 8
	case .Vs, .Ps, .Cs:
		return index
	}
	return index
}

Root_Type :: enum u32 {
	Table             = 0,
	Constants         = 1,
	Descriptor        = 2,
	Immediate_Sampler = 5,
	Heap              = 6,
	Heap_Sampler      = 7,
}

root_type_from_raw :: proc(raw: u32) -> Root_Type {
	switch raw {
	case 0, 3, 4: return .Table
	case 1:       return .Constants
	case 2:       return .Descriptor
	case 5:       return .Immediate_Sampler
	case 6:       return .Heap
	case 7:       return .Heap_Sampler
	}
	return .Table
}

Root_Param :: struct {
	root:                Root_Type,
	table_offset_dwords: u32,
	sgprs:               u32,
	base_register:       u32,
	user_data:           u8,
	slot:                u8,
}

Resource_Type :: enum u8 {
	Srv     = 0,
	Sampler = 1,
	Cbv     = 2,
	Uav     = 3,
}

Used_Resource :: struct {
	kind:                Resource_Type,
	root:                Root_Type,
	table_offset_dwords: u32,
	lower_bound:         u32,
	stride:              u32,
	dwords:              u8,
	user_data:           u8,
	slot:                u8,
}

Ps_Input :: struct {
	row:   u8,
	mask:  u8,
	attr:  u8,
	flat:  bool,
	fp16:  bool,
	pack2: bool,
	row2:  u8,
}

Vs_Input :: struct {
	row:  u8,
	mask: u8,
	vgpr: u8,
}

Vs_Output :: struct {
	row:   u8,
	param: u8,
	fp16:  bool,
	pack2: bool,
}

Export_Patch :: struct {
	mrt:    u8,
	offset: u32,
	code:   []u32,
}

Compute_Io :: struct {
	rsrc2:   u32,
	threads: [3]u32,
}

Mesh_Io :: struct {
	outputs:        []Vs_Output,
	clip_cntl:      u32,
	threads:        u32,
	max_vertices:   u32,
	max_primitives: u32,
	topology:       u8,
	lds_bytes:      u32,
}

Stage_Io_Kind :: enum {
	None,
	Vs,
	Ps,
	Cs,
	Ms,
}

Stage_Io :: struct {
	kind:              Stage_Io_Kind,
	vs_inputs:         []Vs_Input,
	vs_outputs:        []Vs_Output,
	ps_inputs:         []Ps_Input,
	ps_input_addr:     u32,
	db_shader_control: u32,
	ps_patches:        []Export_Patch,
	cs:                Compute_Io,
	ms:                Mesh_Io,
}

Native_Program :: struct {
	stage:  Hw_Stage,
	wave64: bool,
	vgprs:  u16,
	layout: []Root_Param,
	used:   []Used_Resource,
	io:     Stage_Io,
	code:   []u8,
}

destroy_native_program :: proc(np: ^Native_Program) {
	delete(np.layout)
	delete(np.used)
	delete(np.io.vs_inputs)
	delete(np.io.vs_outputs)
	delete(np.io.ps_inputs)
	for p in np.io.ps_patches {
		delete(p.code)
	}
	delete(np.io.ps_patches)
	delete(np.io.ms.outputs)
	delete(np.code)
	np^ = {}
}

destroy_native_programs :: proc(nps: []Native_Program) {
	for &np in nps {
		destroy_native_program(&np)
	}
	delete(nps)
}

native_patched_code :: proc(np: ^Native_Program, allocator := context.allocator) -> []u8 {
	out := make([]u8, len(np.code), allocator)
	copy(out, np.code)
	if np.io.kind == .Ps {
		for p in np.io.ps_patches {
			at := int(p.offset) * 4
			for w, i in p.code {
				pos := at + 4 * i
				if pos + 4 <= len(out) {
					out[pos + 0] = u8(w)
					out[pos + 1] = u8(w >> 8)
					out[pos + 2] = u8(w >> 16)
					out[pos + 3] = u8(w >> 24)
				}
			}
		}
	}
	return out
}

@(private)
zlib_inflate_exact :: proc(stream: []u8, expected_len: uint, allocator := context.allocator) -> ([]u8, Shader_Error) {
	if len(stream) < 6 {
		return nil, .Malformed
	}
	// Strip standard 2-byte zlib CMF/FLG and 4-byte trailing Adler32 for raw deflate.
	raw_deflate := stream[2 : len(stream) - 4]
	dyn := make([dynamic]u8, 0, int(expected_len), allocator)
	if err := deflate.inflate_raw(&dyn, raw_deflate, int(expected_len), int(expected_len) + 1024, allocator); err != nil {
		delete(dyn)
		return nil, .Malformed
	}
	if uint(len(dyn)) != expected_len {
		delete(dyn)
		return nil, .Malformed
	}
	return dyn[:], .None
}

parse_native_programs :: proc(part: []u8, allocator := context.allocator) -> ([]Native_Program, Shader_Error) {
	if len(part) >= 4 && part[0] == 'F' && part[1] == 'S' && part[2] == 'P' && part[3] == 'X' {
		np, err := parse_fspx(part, allocator)
		if err != .None { return nil, err }
		res := make([]Native_Program, 1, allocator)
		res[0] = np
		return res, .None
	}
	if len(part) < 0x18 + 8 || part[0x18] != 'X' || part[0x19] != 'D' || part[0x1a] != 'A' || part[0x1b] != 'T' {
		return nil, .None
	}
	cnt, e1 := rd_u32(part, 0x18 + 4)
	if e1 != .None || cnt > 64 { return nil, .Malformed }

	out := make([dynamic]Native_Program, 0, 4, allocator)
	for i := 0; i < int(cnt); i += 1 {
		at := 0x18 + 12 + 12 * i
		k, ek := rd_u32(part, at)
		if ek != .None { destroy_native_programs(out[:]); return nil, .Malformed }
		if k != 0x0d { continue }
		off, _ := rd_u32(part, at + 4)
		sz, _ := rd_u32(part, at + 8)
		if int(off) + int(sz) > len(part) { destroy_native_programs(out[:]); return nil, .Malformed }
		blob := part[int(off) : int(off) + int(sz)]
		if len(blob) < 0x18 || blob[0] != 'X' || blob[1] != 'B' || blob[2] != 'C' || blob[3] != 'H' {
			destroy_native_programs(out[:])
			return nil, .Malformed
		}
		ver, _ := rd_u32(blob, 4)
		if ver != 3 { destroy_native_programs(out[:]); return nil, .Malformed }
		packed, _ := rd_u64(blob, 8)
		unpacked, _ := rd_u64(blob, 16)
		if unpacked > (16 << 20) || 0x18 + int(packed) > len(blob) {
			destroy_native_programs(out[:])
			return nil, .Malformed
		}
		fssm, ferr := zlib_inflate_exact(blob[0x18 : 0x18 + int(packed)], uint(unpacked), context.temp_allocator)
		if ferr != .None { destroy_native_programs(out[:]); return nil, ferr }
		progs, perr := parse_fssm(fssm, allocator)
		if perr != .None { destroy_native_programs(out[:]); return nil, perr }
		for p in progs { append(&out, p) }
		delete(progs, allocator)
	}
	return out[:], .None
}

@(private)
parse_fssm :: proc(fssm: []u8, allocator := context.allocator) -> ([]Native_Program, Shader_Error) {
	if len(fssm) < 0x10 || fssm[0] != 'F' || fssm[1] != 'S' || fssm[2] != 'S' || fssm[3] != 'M' {
		return nil, .Malformed
	}
	ver, _ := rd_u32(fssm, 4)
	psz, _ := rd_u64(fssm, 8)
	payload := fssm[0x10:]
	if ver != 0x101 || psz != u64(len(payload)) {
		return nil, .Malformed
	}
	slots, _ := rd_u64(payload, 0)
	if slots != 6 { return nil, .Malformed }

	Stage_Slot :: struct { st: Hw_Stage, off: int }
	SLOT_TABLE := [8]Stage_Slot{
		{.Ls, 0x08}, {.Hs, 0x10}, {.Es, 0x18}, {.Gs, 0x20},
		{.Vs, 0x28}, {.Ps, 0x30}, {.Ms, 0x48}, {.Cs, 0x60},
	}
	ABSENT :: u64(0xDEADBEEF_DEADBEEF)
	out := make([dynamic]Native_Program, 0, 2, allocator)
	for sl in SLOT_TABLE {
		start_u64, es := rd_u64(payload, sl.off)
		if es != .None { destroy_native_programs(out[:]); return nil, .Malformed }
		if start_u64 == ABSENT { continue }
		start := int(start_u64)
		if start + 0x54 > len(payload) { destroy_native_programs(out[:]); return nil, .Malformed }
		rec := payload[start : start + 0x54]
		code_off, _ := rd_u64(rec, 0)
		code_sz, _ := rd_u64(rec, 8)
		if int(code_off) + int(code_sz) > len(payload) { destroy_native_programs(out[:]); return nil, .Malformed }
		code_copy := make([]u8, int(code_sz), allocator)
		copy(code_copy, payload[int(code_off) : int(code_off) + int(code_sz)])

		regs, _ := rd_u32(rec, 0x50)
		vgprs := u16(regs & 0x3FF)
		flags, _ := rd_u32(rec, 0x14)
		wave64 := (flags & (1 << 5)) == 0

		lay_off, _ := rd_u64(rec, 0x28)
		used_off, _ := rd_u64(rec, 0x30)
		lay_cnt, _ := rd_u32(rec, 0x38)
		used_cnt, _ := rd_u32(rec, 0x3c)
		if int(lay_off) + 20 * int(lay_cnt) > len(payload) || int(used_off) + 20 * int(used_cnt) > len(payload) {
			delete(code_copy, allocator)
			destroy_native_programs(out[:])
			return nil, .Malformed
		}
		layout := make([]Root_Param, int(lay_cnt), allocator)
		for i := 0; i < int(lay_cnt); i += 1 {
			e := payload[int(lay_off) + 20 * i:]
			rt, _ := rd_u32(e, 0)
			to, _ := rd_u32(e, 4)
			sg, _ := rd_u32(e, 8)
			br, _ := rd_u32(e, 12)
			layout[i] = Root_Param{root = root_type_from_raw(rt), table_offset_dwords = to, sgprs = sg, base_register = br, user_data = e[16], slot = e[17]}
		}
		used := make([]Used_Resource, int(used_cnt), allocator)
		for i := 0; i < int(used_cnt); i += 1 {
			e := payload[int(used_off) + 20 * i:]
			to, _ := rd_u32(e, 4)
			lb, _ := rd_u32(e, 8)
			st, _ := rd_u32(e, 12)
			used[i] = Used_Resource{kind = Resource_Type(e[0]), root = root_type_from_raw(u32(e[1])), table_offset_dwords = to, lower_bound = lb, stride = st, dwords = e[16], user_data = e[17], slot = e[18]}
		}

		sdata := payload[start + 0x54:]
		io := Stage_Io{kind = .None}
		io_err := Shader_Error.None
		switch sl.st {
		case .Ps:
			io, io_err = parse_ps_io(sdata, len(code_copy), allocator)
		case .Vs:
			io, io_err = parse_vs_io(sdata, allocator)
		case .Cs:
			r2, er2 := rd_u32(sdata, 0x24)
			t0, et0 := rd_u32(sdata, 0x28)
			t1, et1 := rd_u32(sdata, 0x2c)
			t2, et2 := rd_u32(sdata, 0x30)
			if er2 != .None || et0 != .None || et1 != .None || et2 != .None {
				io_err = .Malformed
			} else {
				io = Stage_Io{kind = .Cs, cs = {rsrc2 = r2, threads = {t0, t1, t2}}}
			}
		case .Ms:
			lds, _ := rd_u32(rec, 0x4c)
			io, io_err = parse_ms_io(sdata, lds, allocator)
		case .Ls, .Hs, .Es, .Gs:
			io = Stage_Io{kind = .None}
		}
		if io_err != .None {
			delete(code_copy, allocator); delete(layout, allocator); delete(used, allocator)
			destroy_native_programs(out[:])
			return nil, io_err
		}
		append(&out, Native_Program{
			stage = sl.st, wave64 = wave64, vgprs = vgprs, layout = layout, used = used, io = io, code = code_copy,
		})
	}
	return out[:], .None
}

@(private)
parse_ps_io :: proc(data: []u8, code_len: int, allocator := context.allocator) -> (Stage_Io, Shader_Error) {
	cnt, e1 := rd_u32(data, 0x124)
	if e1 != .None || cnt > 32 || 0x24 + 8 * int(cnt) > len(data) { return {}, .Malformed }
	ins := make([]Ps_Input, int(cnt), allocator)
	for i := 0; i < int(cnt); i += 1 {
		e := data[0x24 + 8 * i:]
		ins[i] = Ps_Input{row = e[1], mask = e[2] & 0xF, attr = e[3], flat = e[7] & 1 != 0, fp16 = e[7] & 8 != 0, pack2 = e[7] & 0x10 != 0, row2 = e[5]}
	}
	iaddr, e2 := rd_u32(data, 0x134)
	db, e3 := rd_u32(data, 0x138)
	psz, e4 := rd_u32(data, 0x148)
	if e2 != .None || e3 != .None || e4 != .None || psz > 10 { delete(ins, allocator); return {}, .Malformed }
	patches := make([dynamic]Export_Patch, 0, 8, allocator)
	for mrt := 0; mrt < 8; mrt += 1 {
		at := 0x14c + mrt * (4 + 10 * 10 * 4)
		off, eo := rd_u32(data, at)
		if eo != .None { break }
		if off == 0xFFFFFFFF { continue }
		if (int(off) + int(psz)) * 4 > code_len {
			for p in patches { delete(p.code, allocator) }
			delete(patches); delete(ins, allocator)
			return {}, .Malformed
		}
		full := at + 4 + 9 * 10 * 4
		pcode := make([]u32, int(psz), allocator)
		for k := 0; k < int(psz); k += 1 {
			w, _ := rd_u32(data, full + 4 * k)
			pcode[k] = w
		}
		append(&patches, Export_Patch{mrt = u8(mrt), offset = off, code = pcode})
	}
	return Stage_Io{kind = .Ps, ps_inputs = ins, ps_input_addr = iaddr, db_shader_control = db, ps_patches = patches[:]}, .None
}

@(private)
parse_vs_io :: proc(data: []u8, allocator := context.allocator) -> (Stage_Io, Shader_Error) {
	icnt, e1 := rd_u32(data, 0xc4)
	ocnt, e2 := rd_u32(data, 0x188)
	if e1 != .None || e2 != .None || icnt > 32 || ocnt > 32 || 0x24 + 5 * int(icnt) > len(data) || 0xc8 + 6 * int(ocnt) > len(data) {
		return {}, .Malformed
	}
	ins := make([]Vs_Input, int(icnt), allocator)
	for i := 0; i < int(icnt); i += 1 {
		e := data[0x24 + 5 * i:]
		ins[i] = Vs_Input{row = e[1], mask = e[2] & 0xF, vgpr = e[3]}
	}
	outs := make([]Vs_Output, int(ocnt), allocator)
	for i := 0; i < int(ocnt); i += 1 {
		e := data[0xc8 + 6 * i:]
		outs[i] = Vs_Output{row = e[1], param = e[2], fp16 = e[5] & 1 != 0, pack2 = e[5] & 2 != 0}
	}
	return Stage_Io{kind = .Vs, vs_inputs = ins, vs_outputs = outs}, .None
}

@(private)
parse_ms_io :: proc(data: []u8, lds: u32, allocator := context.allocator) -> (Stage_Io, Shader_Error) {
	ocnt, e1 := rd_u32(data, 0x188)
	clip, e2 := rd_u32(data, 0x194)
	if e1 != .None || e2 != .None || ocnt > 32 || 0x448 + 8 > len(data) { return {}, .Malformed }
	outs := make([]Vs_Output, int(ocnt), allocator)
	for i := 0; i < int(ocnt); i += 1 {
		e := data[0xc8 + 6 * i:]
		outs[i] = Vs_Output{row = e[1], param = e[2], fp16 = e[5] & 1 != 0, pack2 = e[5] & 2 != 0}
	}
	th, _ := rd_u16(data, 0x448)
	mv, _ := rd_u16(data, 0x44a)
	mp, _ := rd_u16(data, 0x44c)
	return Stage_Io{kind = .Ms, ms = Mesh_Io{outputs = outs, clip_cntl = clip, threads = u32(th), max_vertices = u32(mv), max_primitives = u32(mp), topology = data[0x44f], lds_bytes = lds}}, .None
}

@(private)
parse_fspx :: proc(part: []u8, allocator := context.allocator) -> (Native_Program, Shader_Error) {
	ver, _ := rd_u32(part, 4)
	cnt, _ := rd_u32(part, 8)
	if ver != 1 || cnt > 64 { return {}, .Malformed }
	find_k :: proc(p: []u8, c: u32, kind: u32) -> ([]u8, bool) {
		for i := 0; i < int(c); i += 1 {
			at := 0x10 + 16 * i
			k, ek := rd_u32(p, at)
			if ek == .None && k == kind {
				off, _ := rd_u32(p, at + 4)
				sz, _ := rd_u32(p, at + 8)
				if int(off) + int(sz) <= len(p) {
					return p[int(off) : int(off) + int(sz)], true
				}
			}
		}
		return nil, false
	}
	pkt, ok1 := find_k(part, cnt, 0)
	code, ok2 := find_k(part, cnt, 6)
	meta, ok3 := find_k(part, cnt, 7)
	if !ok1 || !ok2 || !ok3 || len(pkt) < 0x1c || len(meta) < 0x18 { return {}, .Malformed }
	fl, _ := rd_u16(pkt, 0x12)
	wave64 := (fl & (1 << 4)) == 0
	r1, _ := rd_u32(pkt, 0x14)
	r2, _ := rd_u32(pkt, 0x18)
	vgprs := u16(min(((r1 & 0x3F) + 1) * (4 if wave64 else 8), 256))
	t0, _ := rd_u16(pkt, 0x0c); t1, _ := rd_u16(pkt, 0x0e); t2, _ := rd_u16(pkt, 0x10)
	code_cp := make([]u8, len(code), allocator)
	copy(code_cp, code)
	_ = meta
	return Native_Program{stage = .Cs, wave64 = wave64, vgprs = vgprs, io = Stage_Io{kind = .Cs, cs = {rsrc2 = r2, threads = {u32(t0), u32(t1), u32(t2)}}}, code = code_cp}, .None
}
