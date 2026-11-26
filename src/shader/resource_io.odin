package vasperty_shader

import "core:strings"

ADDR_CODE :: max(int)
ADDR_MEMORY :: max(int) - 1
ADDR_USER_DATA :: max(int) - 2

Address :: struct {
	param:  int,
	offset: u32,
	dyn:    Maybe(Value),
}

Source_Kind :: enum u8 {
	Loaded,
	Built,
	Constant,
	Phi,
	Select,
	Fetched,
	Lanes,
	Lane_Phi,
}

Source :: struct {
	kind:     Source_Kind,
	load:     Site,
	first:    u8,
	address:  Address,
	bits:     u32,
	words:    [2]u32,
	constant: [dynamic]u32,
	block:    int,
	scc:      Value,
	mask:     Value,
	args:     [dynamic]Source,
	opt_args: [dynamic]Maybe(Source),
}

source_destroy :: proc(s: ^Source) {
	delete(s.constant)
	for &a in s.args {
		source_destroy(&a)
	}
	delete(s.args)
	for &oa in s.opt_args {
		if v, ok := &oa.?; ok {
			source_destroy(v)
		}
	}
	delete(s.opt_args)
}

Role :: enum u8 {
	Resource,
	Sampler,
}

Descriptor :: struct {
	site:   Site,
	role:   Role,
	source: Source,
}

Scalar_Access :: struct {
	site: Site,
	addr: Address,
}

Param_Input :: struct {
	val:   Value,
	param: int,
	dword: u32,
}

Waterfall :: struct {
	compares: [dynamic]Site,
	reads:    [dynamic]Value,
	loads:    [dynamic]Site,
}

Resources :: struct {
	scalar:      [dynamic]Scalar_Access,
	descriptors: [dynamic]Descriptor,
	params:      [dynamic]Param_Input,
	waterfall:   Waterfall,
}

destroy_resources :: proc(r: ^Resources) {
	delete(r.scalar)
	for &d in r.descriptors {
		source_destroy(&d.source)
	}
	delete(r.descriptors)
	delete(r.params)
	delete(r.waterfall.compares)
	delete(r.waterfall.reads)
	delete(r.waterfall.loads)
}

track_resources :: proc(
	p: ^Program,
	layout: []Root_Param,
	stage: Hw_Stage,
	lanes: ^Structured,
) -> (Resources, Shader_Error) {
	_ = stage
	_ = lanes

	r: Resources
	r.scalar = make([dynamic]Scalar_Access)
	r.descriptors = make([dynamic]Descriptor)
	r.params = make([dynamic]Param_Input)
	r.waterfall.compares = make([dynamic]Site)
	r.waterfall.reads = make([dynamic]Value)
	r.waterfall.loads = make([dynamic]Site)

	def_inst := make(map[Value]Site)
	defer delete(def_inst)
	for bi in 0 ..< len(p.blocks) {
		for ii in 0 ..< len(p.blocks[bi].insts) {
			for w in p.blocks[bi].insts[ii].writes {
				def_inst[w.val] = Site{block = bi, inst = ii}
			}
		}
	}

	param_at_sgpr := make(map[Value]Param_Input)
	defer delete(param_at_sgpr)
	user_sgpr_param :: proc(lo: []Root_Param, sgpr: u8) -> (param_idx: int, dword: u32, ok: bool) {
		for rp, idx in lo {
			sz := u8(max(u32(1), rp.sgprs))
			if sgpr >= rp.user_data && sgpr < rp.user_data + sz {
				return idx, u32(sgpr - rp.user_data), true
			}
		}
		return 0, 0, false
	}

	for inp in p.inputs {
		if inp.reg.kind == .S && inp.reg.code < 106 {
			if pidx, dw, ok := user_sgpr_param(layout, inp.reg.code); ok {
				pi := Param_Input{val = inp.val, param = pidx, dword = dw}
				param_at_sgpr[inp.val] = pi
				append(&r.params, pi)
			}
		}
	}

	trace_const :: proc(p: ^Program, defs: ^map[Value]Site, v: Value, depth: int) -> (u32, bool) {
		if depth > 16 {
			return 0, false
		}
		site, ok := defs[v]
		if !ok {
			return 0, false
		}
		inst := &p.blocks[site.block].insts[site.inst]
		name := inst_name(inst)
		if inst.fields.kind == .Sop && (name == "s_mov_b32" || name == "s_movk_i32") {
			if name == "s_movk_i32" && inst.fields.has_imm {
				return u32(i32(i16(inst.fields.imm))), true
			}
			if len(inst.fields.src) > 0 {
				op := inst.fields.src[0]
				if op.kind == .Literal {
					return op.literal, true
				}
				if op.kind == .Const {
					if c, cok := inline_const_u64(op.code); cok {
						return u32(c), true
					}
				}
				if op.kind == .Scalar && op.code < 106 {
					if sv, sok := inst_read(inst, reg_s(op.code)); sok {
						return trace_const(p, defs, sv, depth + 1)
					}
				}
			}
		}
		return 0, false
	}

	trace_address :: proc(
		p: ^Program,
		defs: ^map[Value]Site,
		param_map: ^map[Value]Param_Input,
		base_v: Value,
		off_bytes: u32,
		dyn_v: Maybe(Value),
		depth: int,
	) -> Address {
		if pi, ok := param_map[base_v]; ok {
			return Address{param = pi.param, offset = off_bytes + pi.dword * 4, dyn = dyn_v}
		}
		if depth < 16 {
			if site, dok := defs[base_v]; dok {
				inst := &p.blocks[site.block].insts[site.inst]
				name := inst_name(inst)
				if inst.fields.kind == .Sop && name == "s_getpc_b64" {
					return Address{param = ADDR_CODE, offset = off_bytes + u32(inst.machine.offset + 4 * inst.machine.word_len), dyn = dyn_v}
				}
				if inst.fields.kind == .Sop && (name == "s_mov_b32" || name == "s_mov_b64") && len(inst.fields.src) > 0 {
					op := inst.fields.src[0]
					if op.kind == .Scalar && op.code < 106 {
						if sv, sok := inst_read(inst, reg_s(op.code)); sok {
							return trace_address(p, defs, param_map, sv, off_bytes, dyn_v, depth + 1)
						}
					}
				}
				if inst.fields.kind == .Sop && (name == "s_add_u32" || name == "s_add_i32") && len(inst.fields.src) >= 2 {
					s0 := inst.fields.src[0]
					s1 := inst.fields.src[1]
					if s0.kind == .Scalar && s0.code < 106 {
						if sv, sok := inst_read(inst, reg_s(s0.code)); sok {
							if s1.kind == .Literal {
								return trace_address(p, defs, param_map, sv, off_bytes + s1.literal, dyn_v, depth + 1)
							}
							if s1.kind == .Const {
								if c, cok := inline_const_u64(s1.code); cok {
									return trace_address(p, defs, param_map, sv, off_bytes + u32(c), dyn_v, depth + 1)
								}
							}
							if s1.kind == .Scalar && s1.code < 106 {
								if sv1, sok1 := inst_read(inst, reg_s(s1.code)); sok1 {
									if c1, cok1 := trace_const(p, defs, sv1, 0); cok1 {
										return trace_address(p, defs, param_map, sv, off_bytes + c1, dyn_v, depth + 1)
									}
									return trace_address(p, defs, param_map, sv, off_bytes, sv1, depth + 1)
								}
							}
						}
					}
				}
			}
		}
		return Address{param = ADDR_MEMORY, offset = off_bytes, dyn = dyn_v}
	}

	smem_site := make(map[Value]Site)
	defer delete(smem_site)
	global_site := make(map[Value]Site)
	defer delete(global_site)

	for bi in 0 ..< len(p.blocks) {
		for ii in 0 ..< len(p.blocks[bi].insts) {
			inst := &p.blocks[bi].insts[ii]
			site := Site{block = bi, inst = ii}
			name := inst_name(inst)
			if inst.fields.kind == .Smem && (strings.has_prefix(name, "s_load_dword") || strings.has_prefix(name, "s_store_dword")) {
				if inst.fields.has_base && inst.fields.base.kind == .Scalar && inst.fields.base.code < 106 {
					if bv, bok := inst_read(inst, reg_s(inst.fields.base.code)); bok {
						dyn := Maybe(Value){}
						extra_off := u32(inst.fields.s_offset)
						soff := inst.fields.soffset
						if soff.kind == .Scalar && soff.code < 106 {
							if sv, sok := inst_read(inst, reg_s(soff.code)); sok {
								if c, cok := trace_const(p, &def_inst, sv, 0); cok {
									extra_off += c
								} else {
									dyn = sv
								}
							}
						} else if soff.kind == .Const {
							if c, cok := inline_const_u64(soff.code); cok {
								extra_off += u32(c)
							}
						} else if soff.kind == .Literal {
							extra_off += soff.literal
						}
						addr := trace_address(p, &def_inst, &param_at_sgpr, bv, extra_off, dyn, 0)
						append(&r.scalar, Scalar_Access{site = site, addr = addr})
						if strings.has_prefix(name, "s_load_dword") {
							for w in inst.writes {
								smem_site[w.val] = site
							}
						}
					}
				}
			} else if inst.fields.kind == .Flat && strings.has_prefix(name, "global_load_") {
				addr := Address{param = ADDR_MEMORY, offset = u32(inst.fields.s_offset)}
				append(&r.scalar, Scalar_Access{site = site, addr = addr})
				for w in inst.writes {
					global_site[w.val] = site
				}
			}
		}
	}

	trace_descriptor :: proc(
		p: ^Program,
		defs: ^map[Value]Site,
		param_map: ^map[Value]Param_Input,
		smems: ^map[Value]Site,
		globs: ^map[Value]Site,
		op: Operand,
		inst: ^Inst,
		trace_addr_fn: proc(^Program, ^map[Value]Site, ^map[Value]Param_Input, Value, u32, Maybe(Value), int) -> Address,
	) -> Source {
		if op.kind == .Scalar && op.code < 106 {
			if v, ok := inst_read(inst, reg_s(op.code)); ok {
				if lsite, lok := smems[v]; lok {
					first := u8(0)
					linst := &p.blocks[lsite.block].insts[lsite.inst]
					if linst.fields.has_dst && linst.fields.dst.kind == .Scalar && op.code >= linst.fields.dst.code {
						first = op.code - linst.fields.dst.code
					}
					return Source{kind = .Loaded, load = lsite, first = first}
				}
				if gsite, gok := globs[v]; gok {
					return Source{kind = .Fetched, load = gsite, first = 0}
				}
				addr := trace_addr_fn(p, defs, param_map, v, 0, nil, 0)
				return Source{kind = .Built, address = addr, words = {0, 0x2000_0000}}
			}
		} else if op.kind == .Vector {
			if v, ok := inst_read(inst, reg_v(op.code)); ok {
				if gsite, gok := globs[v]; gok {
					return Source{kind = .Fetched, load = gsite, first = 0}
				}
			}
		}
		return Source{kind = .Constant, constant = make([dynamic]u32, 4)}
	}

	for bi in 0 ..< len(p.blocks) {
		for ii in 0 ..< len(p.blocks[bi].insts) {
			inst := &p.blocks[bi].insts[ii]
			site := Site{block = bi, inst = ii}
			name := inst_name(inst)
			if inst.fields.kind == .Smem && strings.has_prefix(name, "s_buffer_load") && inst.fields.has_base {
				src := trace_descriptor(p, &def_inst, &param_at_sgpr, &smem_site, &global_site, inst.fields.base, inst, trace_address)
				append(&r.descriptors, Descriptor{site = site, role = .Resource, source = src})
			} else if inst.fields.kind == .Buffer && len(inst.fields.src) > 0 {
				if !strings.has_suffix(name, "_inv") && !strings.has_prefix(name, "buffer_wbl2") && !strings.has_prefix(name, "buffer_gl") {
					src := trace_descriptor(p, &def_inst, &param_at_sgpr, &smem_site, &global_site, inst.fields.src[0], inst, trace_address)
					append(&r.descriptors, Descriptor{site = site, role = .Resource, source = src})
				}
			} else if inst.fields.kind == .Image && inst.fields.has_base {
				src := trace_descriptor(p, &def_inst, &param_at_sgpr, &smem_site, &global_site, inst.fields.base, inst, trace_address)
				append(&r.descriptors, Descriptor{site = site, role = .Resource, source = src})
				if inst.fields.has_sampler {
					ssrc := trace_descriptor(p, &def_inst, &param_at_sgpr, &smem_site, &global_site, inst.fields.sampler, inst, trace_address)
					append(&r.descriptors, Descriptor{site = site, role = .Sampler, source = ssrc})
				}
			}
		}
	}

	return r, .None
}

// =========================================================================
// Stage I/O raising
// =========================================================================

Barycentric_Kind :: enum u8 {
	Perspective,
	Linear,
}

Barycentric_At :: enum u8 {
	Center,
	Centroid,
	Sample,
}

Barycentric :: struct {
	kind: Barycentric_Kind,
	at:   Barycentric_At,
}

Input_Kind :: enum u8 {
	Vertex_Id,
	Instance_Id,
	Primitive_Id,
	Attribute,
	Barycentric,
	Line_Stipple,
	Position,
	Front_Face,
	Ancillary,
	Sample_Coverage,
	Fixed_Position,
	Thread_Id_In_Group,
	Group_Id,
	Group_Info,
	Mesh_Group,
	Merged_Wave_Info,
}

Input :: struct {
	kind:        Input_Kind,
	row:         u8,
	channel:     u8,
	component:   u8,
	barycentric: Barycentric,
}

Attribute :: struct {
	row:     u8,
	channel: u8,
	high:    bool,
	flat:    bool,
}

Interp_Kind :: enum u8 {
	Interpolated,
	Vertex,
}

Interp :: struct {
	kind:        Interp_Kind,
	attribute:   Attribute,
	barycentric: Barycentric,
	vertex:      u8,
}

Target_Kind :: enum u8 {
	Color,
	Depth,
	Null,
	Position,
	Param,
	Unread,
	Primitive,
	Primitive_Param,
}

Target :: struct {
	kind:  Target_Kind,
	index: u8,
	row:   u8,
}

Export :: struct {
	site:       Site,
	target:     Target,
	values:     [4]Maybe(Value),
	compressed: bool,
	done:       bool,
}

Io_Input :: struct {
	val:   Value,
	input: Input,
}

Io_Interp :: struct {
	site:   Site,
	interp: Interp,
}

Io :: struct {
	inputs:            [dynamic]Io_Input,
	interps:           [dynamic]Io_Interp,
	exports:           [dynamic]Export,
	initialized_sgprs: Maybe(u8),
}

destroy_io :: proc(io: ^Io) {
	delete(io.inputs)
	delete(io.interps)
	delete(io.exports)
}

ps_vgprs :: proc(input_addr: u32) -> [dynamic]struct {
	reg: u8,
	inp: Input,
} {
	out := make([dynamic]struct {
		reg: u8,
		inp: Input,
	})
	BARY_ORDER := [6]Barycentric{
		{kind = .Perspective, at = .Sample},
		{kind = .Perspective, at = .Center},
		{kind = .Perspective, at = .Centroid},
		{kind = .Linear, at = .Sample},
		{kind = .Linear, at = .Center},
		{kind = .Linear, at = .Centroid},
	}
	r := u8(0)
	for bit in 0 ..< 6 {
		if ((input_addr >> u32(bit)) & 1) != 0 {
			append(&out, struct {
				reg: u8,
				inp: Input,
			}{reg = r, inp = Input{kind = .Barycentric, barycentric = BARY_ORDER[bit], component = 0}})
			append(&out, struct {
				reg: u8,
				inp: Input,
			}{reg = r + 1, inp = Input{kind = .Barycentric, barycentric = BARY_ORDER[bit], component = 1}})
			r += 2
		}
	}
	if ((input_addr >> 7) & 1) != 0 {
		append(&out, struct {
			reg: u8,
			inp: Input,
		}{reg = r, inp = Input{kind = .Line_Stipple}})
		r += 1
	}
	for c in u8(0) ..< 4 {
		if ((input_addr >> u32(8 + c)) & 1) != 0 {
			append(&out, struct {
				reg: u8,
				inp: Input,
			}{reg = r, inp = Input{kind = .Position, component = c}})
			r += 1
		}
	}
	if ((input_addr >> 12) & 1) != 0 {
		append(&out, struct {
			reg: u8,
			inp: Input,
		}{reg = r, inp = Input{kind = .Front_Face}})
		r += 1
	}
	if ((input_addr >> 13) & 1) != 0 {
		append(&out, struct {
			reg: u8,
			inp: Input,
		}{reg = r, inp = Input{kind = .Ancillary}})
		r += 1
	}
	if ((input_addr >> 14) & 1) != 0 {
		append(&out, struct {
			reg: u8,
			inp: Input,
		}{reg = r, inp = Input{kind = .Sample_Coverage}})
		r += 1
	}
	if ((input_addr >> 15) & 1) != 0 {
		append(&out, struct {
			reg: u8,
			inp: Input,
		}{reg = r, inp = Input{kind = .Fixed_Position}})
		r += 1
	}
	return out
}

raise_io :: proc(p: ^Program, native: ^Native_Program) -> (Io, Shader_Error) {
	io: Io
	io.inputs = make([dynamic]Io_Input)
	io.interps = make([dynamic]Io_Interp)
	io.exports = make([dynamic]Export)

	Loaded_Entry :: struct {
		reg: Reg,
		inp: Input,
	}
	loaded := make([dynamic]Loaded_Entry)
	defer delete(loaded)

	ps_inputs: []Ps_Input
	vs_params: []Vs_Output

	switch native.stage {
	case .Ps:
		if native.io.kind != .Ps {
			destroy_io(&io)
			return {}, .Unsupported
		}
		vg := ps_vgprs(native.io.ps_input_addr)
		defer delete(vg)
		for entry in vg {
			append(&loaded, Loaded_Entry{reg = reg_v(entry.reg), inp = entry.inp})
		}
		ps_inputs = native.io.ps_inputs
		max_ud := u8(8)
		for rp in native.layout {
			sz := u8(max(u32(1), rp.sgprs))
			if rp.user_data + sz > max_ud {
				max_ud = rp.user_data + sz
			}
		}
		io.initialized_sgprs = max_ud + 2

	case .Vs:
		if native.io.kind != .Vs {
			destroy_io(&io)
			return {}, .Unsupported
		}
		append(&loaded, Loaded_Entry{reg = reg_v(0), inp = Input{kind = .Vertex_Id}})
		append(&loaded, Loaded_Entry{reg = reg_v(2), inp = Input{kind = .Primitive_Id}})
		append(&loaded, Loaded_Entry{reg = reg_v(3), inp = Input{kind = .Instance_Id}})
		for vi in native.io.vs_inputs {
			for ch in u8(0) ..< 4 {
				if ((vi.mask >> ch) & 1) != 0 {
					append(&loaded, Loaded_Entry{
						reg = reg_v(vi.vgpr + ch),
						inp = Input{kind = .Attribute, row = vi.row, channel = ch},
					})
				}
			}
		}
		vs_params = native.io.vs_outputs

	case .Cs:
		if native.io.kind != .Cs {
			destroy_io(&io)
			return {}, .Unsupported
		}
		cs := native.io.cs
		user_sgprs := u8((cs.rsrc2 >> 1) & 0x1F)
		tgid_x := ((cs.rsrc2 >> 7) & 1) != 0
		tgid_y := ((cs.rsrc2 >> 8) & 1) != 0
		tgid_z := ((cs.rsrc2 >> 9) & 1) != 0
		tg_size := ((cs.rsrc2 >> 10) & 1) != 0
		tid_cnt := u8(((cs.rsrc2 >> 11) & 3) + 1)
		if tid_cnt > 3 {
			tid_cnt = 3
		}
		for c in u8(0) ..< tid_cnt {
			append(&loaded, Loaded_Entry{reg = reg_v(c), inp = Input{kind = .Thread_Id_In_Group, component = c}})
		}
		s := user_sgprs
		if tgid_x {
			append(&loaded, Loaded_Entry{reg = reg_s(s), inp = Input{kind = .Group_Id, component = 0}})
			s += 1
		}
		if tgid_y {
			append(&loaded, Loaded_Entry{reg = reg_s(s), inp = Input{kind = .Group_Id, component = 1}})
			s += 1
		}
		if tgid_z {
			append(&loaded, Loaded_Entry{reg = reg_s(s), inp = Input{kind = .Group_Id, component = 2}})
			s += 1
		}
		if tg_size {
			append(&loaded, Loaded_Entry{reg = reg_s(s), inp = Input{kind = .Group_Info}})
			s += 1
		}
		io.initialized_sgprs = s

	case .Ms:
		if native.io.kind != .Ms {
			destroy_io(&io)
			return {}, .Unsupported
		}
		append(&loaded, Loaded_Entry{reg = reg_v(5), inp = Input{kind = .Mesh_Group}})
		append(&loaded, Loaded_Entry{reg = reg_s(3), inp = Input{kind = .Merged_Wave_Info}})
		vs_params = native.io.ms.outputs

	case .Gs, .Hs, .Ls, .Es:
		// RDNA2 merged ES-GS / LS-HS stages receive Merged_Wave_Info in s3 and vertex/prim IDs in v0/v2/v3.
		append(&loaded, Loaded_Entry{reg = reg_s(3), inp = Input{kind = .Merged_Wave_Info}})
		append(&loaded, Loaded_Entry{reg = reg_v(0), inp = Input{kind = .Vertex_Id}})
		append(&loaded, Loaded_Entry{reg = reg_v(2), inp = Input{kind = .Primitive_Id}})
		append(&loaded, Loaded_Entry{reg = reg_v(3), inp = Input{kind = .Instance_Id}})
		if native.io.kind == .Vs {
			vs_params = native.io.vs_outputs
		} else if native.io.kind == .Ms {
			vs_params = native.io.ms.outputs
		}
	}

	for inp in p.inputs {
		for l in loaded {
			if l.reg == inp.reg {
				append(&io.inputs, Io_Input{val = inp.val, input = l.inp})
				break
			}
		}
	}

	find_input :: proc(inputs: []Io_Input, v: Value) -> (Input, bool) {
		for item in inputs {
			if item.val == v {
				return item.input, true
			}
		}
		return {}, false
	}

	find_ps_attr :: proc(ps: []Ps_Input, op: Operand) -> (Attribute, bool) {
		if op.kind != .Attr {
			return {}, false
		}
		for pi in ps {
			if pi.attr == op.attr_index {
				return Attribute{row = pi.row, channel = op.attr_chan, high = op.attr_high, flat = pi.flat}, true
			}
		}
		return {}, false
	}

	for bi in 0 ..< len(p.blocks) {
		for ii in 0 ..< len(p.blocks[bi].insts) {
			inst := &p.blocks[bi].insts[ii]
			site := Site{block = bi, inst = ii}
			name := inst_name(inst)
			if strings.has_prefix(name, "v_interp_") && len(inst.fields.valu.src) >= 2 {
				src := inst.fields.valu.src[1] if name == "v_interp_p2_f32" || name == "v_interp_p2_f16" else inst.fields.valu.src[0]
				attr_op := inst.fields.valu.src[0] if inst.fields.valu.src[0].kind == .Attr else inst.fields.valu.src[1]
				attr, aok := find_ps_attr(ps_inputs, attr_op)
				if aok {
					if name == "v_interp_p2_f32" || name == "v_interp_p2_f16" {
						bary := Barycentric{kind = .Perspective, at = .Center}
						if src.kind == .Vector {
							if sv, sok := inst_read(inst, reg_v(src.code)); sok {
								if in_info, iok := find_input(io.inputs[:], sv); iok && in_info.kind == .Barycentric {
									bary = in_info.barycentric
								}
							}
						}
						append(&io.interps, Io_Interp{
							site   = site,
							interp = Interp{kind = .Interpolated, attribute = attr, barycentric = bary},
						})
					} else if name == "v_interp_mov_f32" {
						vtx := u8(2)
						if src.kind == .Const && src.code >= 128 && src.code <= 130 {
							vtx = src.code - 128
						}
						append(&io.interps, Io_Interp{
							site   = site,
							interp = Interp{kind = .Vertex, attribute = attr, vertex = vtx},
						})
					}
				}
			} else if inst.fields.kind == .Exp {
				tgt_code := inst.fields.exp_target
				target: Target
				switch {
				case tgt_code <= 7:
					target = Target{kind = .Color, index = tgt_code}
				case tgt_code == 8:
					target = Target{kind = .Depth}
				case tgt_code == 9:
					target = Target{kind = .Null}
				case tgt_code >= 12 && tgt_code <= 15:
					target = Target{kind = .Position, index = tgt_code - 12}
				case tgt_code == 20:
					target = Target{kind = .Primitive}
				case tgt_code >= 32:
					pidx := tgt_code - 32
					matched := false
					for vp in vs_params {
						if vp.param == pidx {
							target = Target{kind = .Param, row = vp.row}
							matched = true
							break
						}
					}
					if !matched {
						target = Target{kind = .Unread}
					}
				case:
					target = Target{kind = .Null}
				}
				vals: [4]Maybe(Value)
				for ch in 0 ..< 4 {
					if inst.fields.exp_has[ch] {
						sop := inst.fields.exp_src[ch]
						if sop.kind == .Vector {
							if v, vok := inst_read(inst, reg_v(sop.code)); vok {
								vals[ch] = v
							}
						}
					}
				}
				append(&io.exports, Export{
					site       = site,
					target     = target,
					values     = vals,
					compressed = inst.fields.exp_compr,
					done       = inst.fields.exp_done,
				})
			}
		}
	}

	return io, .None
}
