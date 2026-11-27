package vasperty_shader

import "core:slice"
import "core:strings"

// GFX10/RDNA2 CFG-following instruction decoder, operand/field decoder, and SP3 formatter.

Encoding :: enum {
	Sop2, Sopk, Sop1, Sopc, Sopp, Smem,
	Vop2, Vop1, Vopc, Vop3, Vop3p, Vintrp,
	Ds, Mubuf, Mtbuf, Mimg, Exp, Flat, Global, Scratch,
}

Operand_Kind :: enum {
	Scalar,
	Vector,
	Const,
	Literal,
	Attr,
}

Operand :: struct {
	kind:       Operand_Kind,
	code:       u8, // scalar reg/special or inline const or vector reg
	dwords:     u8,
	literal:    u32,
	attr_index: u8,
	attr_chan:  u8,
	attr_high:  bool,
}

NULL_SCALAR :: u8(125)
VCC_SCALAR :: u8(106)
M0_SCALAR :: u8(124)
EXEC_SCALAR :: u8(126)

Cache_Flags :: struct {
	glc, slc, dlc: bool,
}

Sdwa :: struct {
	dst_sel:    u8,
	dst_unused: u8,
	src_sel:    [2]u8,
	sext:       u8,
}

Dpp_Kind :: enum { None, Row, Lanes }
Dpp :: struct {
	kind:       Dpp_Kind,
	ctrl:       u16,
	row_mask:   u8,
	bank_mask:  u8,
	bound_ctrl: bool,
	sel:        u32,
	fi:         bool,
}

Valu_Fields :: struct {
	has_dst:   bool,
	dst:       Operand,
	has_carry: bool,
	carry:     Operand,
	src:       [dynamic]Operand,
	neg:       u8,
	abs:       u8,
	neg_hi:    u8,
	opsel:     u8,
	opsel_hi:  u8,
	clamp:     bool,
	omod:      u8,
	has_sdwa:  bool,
	sdwa:      Sdwa,
	dpp:       Dpp,
}

Fields_Kind :: enum {
	Sop,
	Sopp,
	Smem,
	Valu,
	Vintrp,
	Ds,
	Buffer,
	Image,
	Flat,
	Exp,
}

Fields :: struct {
	kind:       Fields_Kind,
	has_dst:    bool,
	dst:        Operand,
	has_imm:    bool,
	imm:        u16,
	src:        [dynamic]Operand,
	cache:      Cache_Flags,
	// Smem / Buffer / Flat
	has_base:   bool,
	base:       Operand,
	soffset:    Operand,
	s_offset:   i32,
	offset0:    u16,
	offset1:    u8,
	offen:      bool,
	idxen:      bool,
	has_format: bool,
	format:     u8,
	lds:        bool,
	tfe:        bool,
	has_saddr:  bool,
	saddr:      Operand,
	// Image
	dim, dmask: u8,
	unorm, r128, a16, d16, lwe: bool,
	has_sampler: bool,
	sampler:    Operand,
	// Exp
	exp_target: u8,
	exp_src:    [4]Operand,
	exp_has:    [4]bool,
	exp_compr:  bool,
	exp_done:   bool,
	exp_vm:     bool,
	// Valu
	valu:       Valu_Fields,
}

destroy_fields :: proc(f: ^Fields) {
	delete(f.src)
	delete(f.valu.src)
	f^ = {}
}

Instruction :: struct {
	offset:   int,
	encoding: Encoding,
	opcode:   u16,
	words:    [4]u32,
	word_len: int,
	has_name: bool,
	name:     string,
}

Flow_Kind :: enum { Next, Stop, Jump, Branch }
Flow :: struct {
	kind:   Flow_Kind,
	target: int,
}

decode_instruction :: proc(code: []u8, offset: int) -> (Instruction, Shader_Error) {
	w0, err0 := rd_u32(code, offset)
	if err0 != .None { return {}, .Isa_Error }
	enc: Encoding
	op: u32
	wlen := 1

	if (w0 >> 31) == 0 {
		src0 := w0 & 0x1FF
		extra := 1 if (src0 == 0xFF || src0 == 0xF9 || src0 == 0xFA || src0 == 0xE9 || src0 == 0xEA) else 0
		switch w0 >> 25 {
		case 0x3F:
			enc = .Vop1; op = (w0 >> 9) & 0xFF; wlen = 1 + extra
		case 0x3E:
			enc = .Vopc; op = (w0 >> 17) & 0xFF; wlen = 1 + extra
		case:
			enc = .Vop2; op = w0 >> 25
			nm, _ := gfx10_lookup_name(.Vop2, u16(op))
			mk_ak := nm == "v_madmk_f32" || nm == "v_madak_f32" || nm == "v_fmamk_f32" || nm == "v_fmaak_f32" ||
				nm == "v_madmk_f16" || nm == "v_madak_f16" || nm == "v_fmamk_f16" || nm == "v_fmaak_f16"
			wlen = 1 + max(extra, 1 if mk_ak else 0)
		}
	} else if (w0 >> 30) == 2 {
		has_lit :: proc(a, b: u32) -> int { return 1 if (a == 0xFF || b == 0xFF) else 0 }
		switch w0 >> 23 {
		case 0x17D:
			enc = .Sop1; op = (w0 >> 8) & 0xFF; wlen = 1 + has_lit(w0 & 0xFF, 0)
		case 0x17E:
			enc = .Sopc; op = (w0 >> 16) & 0x7F; wlen = 1 + has_lit(w0 & 0xFF, (w0 >> 8) & 0xFF)
		case 0x17F:
			enc = .Sopp; op = (w0 >> 16) & 0x7F; wlen = 1
		case:
			if (w0 >> 28) == 0b1011 {
				enc = .Sopk; op = (w0 >> 23) & 0x1F
				nm, _ := gfx10_lookup_name(.Sopk, u16(op))
				wlen = 2 if nm == "s_setreg_imm32_b32" else 1
			} else {
				enc = .Sop2; op = (w0 >> 23) & 0x7F; wlen = 1 + has_lit(w0 & 0xFF, (w0 >> 8) & 0xFF)
			}
		}
	} else {
		vop3_len :: proc(code: []u8, offset: int) -> (int, Shader_Error) {
			w1, err1 := rd_u32(code, offset + 4)
			if err1 != .None { return 0, .Isa_Error }
			lit := ((w1 & 0x1FF) == 0xFF) || (((w1 >> 9) & 0x1FF) == 0xFF) || (((w1 >> 18) & 0x1FF) == 0xFF)
			return 3 if lit else 2, .None
		}
		switch w0 >> 26 {
		case 0x32:
			enc = .Vintrp; op = (w0 >> 16) & 0x3; wlen = 1
		case 0x33:
			enc = .Vop3p; op = (w0 >> 16) & 0x7F
			l, err := vop3_len(code, offset); if err != .None { return {}, err }; wlen = l
		case 0x35:
			enc = .Vop3; op = (w0 >> 16) & 0x3FF
			l, err := vop3_len(code, offset); if err != .None { return {}, err }; wlen = l
		case 0x36:
			enc = .Ds; op = (w0 >> 18) & 0xFF; wlen = 2
		case 0x37:
			seg := (w0 >> 14) & 3
			switch seg {
			case 0: enc = .Flat
			case 1: enc = .Scratch
			case 2: enc = .Global
			case:   return {}, .Isa_Error
			}
			op = (w0 >> 18) & 0x7F; wlen = 2
		case 0x38:
			enc = .Mubuf; op = ((w0 >> 18) & 0x7F) | (((w0 >> 25) & 1) << 7); wlen = 2
		case 0x3A:
			w1, err1 := rd_u32(code, offset + 4); if err1 != .None { return {}, .Isa_Error }
			enc = .Mtbuf; op = ((w0 >> 16) & 0x7) | (((w1 >> 21) & 1) << 3); wlen = 2
		case 0x3C:
			enc = .Mimg; op = ((w0 >> 18) & 0x7F) | ((w0 & 1) << 7); wlen = 2 + int((w0 >> 1) & 3)
		case 0x3D:
			enc = .Smem; op = (w0 >> 18) & 0xFF; wlen = 2
		case 0x3E:
			enc = .Exp; op = 0; wlen = 2
		case:
			return {}, .Isa_Error
		}
	}

	inst := Instruction{offset = offset, encoding = enc, opcode = u16(op), word_len = min(wlen, 4)}
	for i in 0 ..< inst.word_len {
		w, ew := rd_u32(code, offset + 4 * i)
		if ew != .None { return {}, .Isa_Error }
		inst.words[i] = w
	}
	nm, has_nm := gfx10_lookup_name(enc, inst.opcode)
	inst.name = nm
	inst.has_name = has_nm
	return inst, .None
}

gfx10_lookup_name :: proc(enc: Encoding, op: u16) -> (string, bool) {
	if enc == .Vop3 {
		if op < 0x100 { return opcode_name(.Vopc, op) }
		if op < 0x140 { return opcode_name(.Vop2, op - 0x100) }
		if op >= 0x180 && op < 0x200 { return opcode_name(.Vop1, op - 0x180) }
	}
	return opcode_name(enc, op)
}

decode_program :: proc(code: []u8, allocator := context.allocator) -> ([]Instruction, Shader_Error) {
	if len(code) % 4 != 0 { return nil, .Isa_Error }
	found := make(map[int]Instruction, 64, context.temp_allocator)
	pending := make([dynamic]int, 0, 16, context.temp_allocator)
	append(&pending, 0)

	for len(pending) > 0 {
		off := pending[len(pending) - 1]
		pop(&pending)
		for !(off in found) {
			inst, err := decode_instruction(code, off)
			if err != .None { return nil, err }
			next := off + 4 * inst.word_len
			fl, ferr := control_flow(&inst, len(code), &found)
			if ferr != .None { return nil, ferr }
			found[off] = inst
			switch fl.kind {
			case .Next:   off = next
			case .Stop:   break
			case .Jump:   off = fl.target
			case .Branch: append(&pending, fl.target); off = next
			}
			if fl.kind == .Stop { break }
		}
	}
	list := make([]Instruction, len(found), allocator)
	idx := 0
	for _, v in found {
		list[idx] = v
		idx += 1
	}
	slice.sort_by(list, proc(a, b: Instruction) -> bool { return a.offset < b.offset })
	for i := 0; i + 1 < len(list); i += 1 {
		if list[i].offset + 4 * list[i].word_len > list[i + 1].offset {
			delete(list, allocator)
			return nil, .Isa_Error
		}
	}
	return list, .None
}

control_flow :: proc(inst: ^Instruction, code_len: int, found: ^map[int]Instruction) -> (Flow, Shader_Error) {
	next := inst.offset + 4 * inst.word_len
	target_off :: proc(w0: u32, next: int, code_len: int) -> (int, Shader_Error) {
		delta := 4 * i64(i16(u16(w0)))
		t := i64(next) + delta
		if t < 0 || int(t) >= code_len { return 0, .Isa_Error }
		return int(t), .None
	}
	switch inst.encoding {
	case .Sopp:
		if inst.name == "s_endpgm" || inst.name == "s_endpgm_saved" || inst.name == "s_endpgm_ordered_ps_done" || inst.name == "s_code_end" {
			return Flow{kind = .Stop}, .None
		}
		if inst.name == "s_branch" {
			t, err := target_off(inst.words[0], next, code_len)
			return Flow{kind = .Jump, target = t}, err
		}
		if strings.has_prefix(inst.name, "s_cbranch_") {
			t, err := target_off(inst.words[0], next, code_len)
			return Flow{kind = .Branch, target = t}, err
		}
	case .Sopk:
		if inst.name == "s_call_b64" {
			t, err := target_off(inst.words[0], next, code_len)
			return Flow{kind = .Branch, target = t}, err
		}
	case .Sop1:
		if inst.name == "s_setpc_b64" {
			n := inst.words[0] & 0xFF
			has_delta := false
			delta: i64 = 0
			cur_at := inst.offset
			for _ in 0 ..< 4 {
				best_off := -1
				for o, _ in found {
					if o < cur_at && o > best_off { best_off = o }
				}
				if best_off < 0 { break }
				prev := found[best_off]
				if prev.offset + 4 * prev.word_len != cur_at { break }
				pw := prev.words[0]
				sdst, s0, s1 := (pw >> 16) & 0x7F, pw & 0xFF, (pw >> 8) & 0xFF
				if prev.encoding == .Sop2 && (prev.name == "s_add_u32" || prev.name == "s_sub_u32") && sdst == n && s0 == n && s1 == 0xFF && !has_delta {
					lit := i64(i32(prev.words[1]))
					delta = lit if prev.name == "s_add_u32" else -lit
					has_delta = true
				} else if prev.encoding == .Sop1 && prev.name == "s_getpc_b64" && sdst == n {
					if !has_delta { break }
					t := i64(prev.offset) + 4 + delta
					if t < 0 || int(t) >= code_len { return {}, .Isa_Error }
					return Flow{kind = .Jump, target = int(t)}, .None
				}
				cur_at = prev.offset
			}
			return Flow{kind = .Stop}, .None
		}
	case .Sop2, .Sopc, .Smem, .Vop2, .Vop1, .Vopc, .Vop3, .Vop3p, .Vintrp, .Ds, .Mubuf, .Mtbuf, .Mimg, .Exp, .Flat, .Global, .Scratch:
	}
	return Flow{kind = .Next}, .None
}

// =============================================================================
// Operand & Field Decoder
// =============================================================================

op_scalar :: proc(code: u8, dwords: u8) -> Operand { return Operand{kind = .Scalar, code = code, dwords = dwords} }
op_vector :: proc(reg: u32, dwords: u8) -> Operand { return Operand{kind = .Vector, code = u8(reg), dwords = dwords} }
op_source :: proc(code: u32, dwords: u8, lit: u32) -> Operand {
	if code <= 127 { return op_scalar(u8(code), dwords) }
	if code == 255 { return Operand{kind = .Literal, literal = lit, dwords = dwords} }
	if code >= 256 { return op_vector(code - 256, dwords) }
	return Operand{kind = .Const, code = u8(code), dwords = dwords}
}

@(private) type_dwords :: proc(tok: string) -> u8 {
	if tok == "b64" || tok == "u64" || tok == "i64" || tok == "f64" { return 2 }
	return 1
}

@(private) salu_dwords :: proc(name: string) -> (u8, u8, u8) {
	switch name {
	case "s_lshl_b64", "s_lshr_b64", "s_ashr_i64", "s_bfe_u64", "s_bfe_i64", "s_bitcmp0_b64", "s_bitcmp1_b64":
		return 2, 2, 1
	case "s_bfm_b64", "s_bitset0_b64", "s_bitset1_b64", "s_bitreplicate_b64_b32":
		return 2, 1, 1
	case "s_bcnt0_i32_b64", "s_bcnt1_i32_b64", "s_ff0_i32_b64", "s_ff1_i32_b64", "s_flbit_i32_b64", "s_flbit_i32_i64":
		return 1, 2, 2
	}
	idx := strings.last_index_byte(name, '_')
	n := type_dwords(name[idx + 1:] if idx >= 0 else "")
	return n, n, n
}

@(private) data_dwords :: proc(name: string) -> u8 {
	n: u8 = 1
	rem := name
	for len(rem) > 0 {
		us := strings.index_byte(rem, '_')
		tok := rem if us < 0 else rem[:us]
		rem = "" if us < 0 else rem[us + 1:]
		switch tok {
		case "dwordx2", "x2", "xy", "b64", "u64", "i64", "f64": n = 2
		case "dwordx3", "xyz", "b96":                           n = 3
		case "dwordx4", "xyzw", "b128":                         n = 4
		case "dwordx8":                                         n = 8
		case "dwordx16":                                        n = 16
		}
	}
	if strings.contains(name, "cmpswap") { n *= 2 }
	if strings.contains(name, "format_d16") { n = (n + 1) / 2 }
	return n
}

decode_fields :: proc(inst: ^Instruction, wave64: bool, allocator := context.allocator) -> Fields {
	name := inst.name
	w0 := inst.words[0]
	w1 := inst.words[1] if inst.word_len > 1 else 0
	w2 := inst.words[2] if inst.word_len > 2 else 0
	lanes: u8 = 2 if wave64 else 1

	bit :: proc(w: u32, n: uint) -> bool { return ((w >> n) & 1) != 0 }

	f := Fields{
		src      = make([dynamic]Operand, 0, 4, allocator),
		valu     = Valu_Fields{src = make([dynamic]Operand, 0, 4, allocator)},
	}

	switch inst.encoding {
	case .Sop2, .Sop1, .Sopc:
		f.kind = .Sop
		d_n, s0_n, s1_n := salu_dwords(name)
		sdst := op_scalar(u8((w0 >> 16) & 0x7F), d_n)
		if inst.encoding == .Sop2 {
			f.has_dst = true; f.dst = sdst
			append(&f.src, op_source(w0 & 0xFF, s0_n, w1), op_source((w0 >> 8) & 0xFF, s1_n, w1))
		} else if inst.encoding == .Sopc {
			append(&f.src, op_source(w0 & 0xFF, s0_n, w1), op_source((w0 >> 8) & 0xFF, s1_n, w1))
		} else {
			if name == "s_getpc_b64" {
				f.has_dst = true; f.dst = sdst
			} else if name == "s_setpc_b64" || name == "s_rfe_b64" {
				append(&f.src, op_source(w0 & 0xFF, s0_n, w1))
			} else {
				f.has_dst = true; f.dst = sdst
				append(&f.src, op_source(w0 & 0xFF, s0_n, w1))
			}
		}
	case .Sopk:
		f.kind = .Sop
		sdst := op_scalar(u8((w0 >> 16) & 0x7F), 2 if name == "s_call_b64" else 1)
		f.has_imm = true; f.imm = u16(w0)
		if name == "s_setreg_imm32_b32" {
			append(&f.src, Operand{kind = .Literal, literal = w1, dwords = 1})
		} else if name == "s_version" {
		} else if strings.has_prefix(name, "s_cmpk_") || strings.has_prefix(name, "s_waitcnt_") || name == "s_setreg_b32" {
			append(&f.src, sdst)
		} else {
			f.has_dst = true; f.dst = sdst
		}
	case .Sopp:
		f.kind = .Sopp; f.has_imm = true; f.imm = u16(w0)
	case .Smem:
		f.kind = .Smem
		sdata := u8((w0 >> 6) & 0x7F)
		probe := name == "s_atc_probe" || name == "s_atc_probe_buffer"
		if probe {
			f.has_dst = true; f.dst = Operand{kind = .Literal, literal = u32(sdata), dwords = 1}
		} else if name != "s_gl1_inv" && name != "s_dcache_inv" && name != "s_dcache_wb" && !strings.has_prefix(name, "s_dcache_discard") {
			f.has_dst = true
			dn: u8 = 2 if (name == "s_memtime" || name == "s_memrealtime") else data_dwords(name)
			f.dst = op_scalar(sdata, dn)
		}
		bn: u8 = 4 if (strings.has_prefix(name, "s_buffer_") || name == "s_atc_probe_buffer") else 2
		f.has_base = true; f.base = op_scalar(u8((w0 & 0x3F) << 1), bn)
		f.s_offset = i32(w1 << 11) >> 11
		f.soffset = op_scalar(u8(w1 >> 25), 1)
		if !probe { f.cache = {glc = bit(w0, 16), dlc = bit(w0, 14)} }
	case .Vop1, .Vop2, .Vopc, .Vop3, .Vop3p:
		f.kind = .Valu
		if name == "v_nop" || name == "v_pipeflush" || name == "v_clrexcp" { return f }
		idx := strings.last_index_byte(name, '_')
		v_dn := type_dwords(name[idx + 1:] if idx >= 0 else "")
		cmp := (inst.encoding == .Vopc) || (inst.encoding == .Vop3 && inst.opcode < 0x100)
		carry_in := strings.has_suffix(name, "_co_ci_u32") || name == "v_cndmask_b32"
		if inst.encoding == .Vop1 || inst.encoding == .Vop2 || inst.encoding == .Vopc {
			ext := w1
			src0 := w0 & 0x1FF
			vsrc1 := 256 + ((w0 >> 9) & 0xFF)
			src1 := vsrc1
			if src0 == 0xF9 {
				src0 = (ext & 0xFF) | (0 if ((ext >> 23) & 1) != 0 else 256)
				if (ext >> 31) == 1 { src1 = vsrc1 - 256 }
				f.valu.neg = u8(((ext >> 20) & 1) | ((ext >> 27) & 2))
				f.valu.abs = u8(((ext >> 21) & 1) | ((ext >> 28) & 2))
				if cmp && ((ext >> 15) & 1) != 0 {
					f.valu.has_dst = true
					f.valu.dst = op_scalar(u8((ext >> 8) & 0x7F), lanes)
				}
				f.valu.has_sdwa = true
				f.valu.sdwa = Sdwa{dst_sel = 6 if cmp else u8((ext >> 8) & 7), dst_unused = 0 if cmp else u8((ext >> 11) & 3), src_sel = {u8((ext >> 16) & 7), u8((ext >> 24) & 7)}, sext = u8(((ext >> 19) & 1) | ((ext >> 26) & 2))}
			} else if src0 == 0xFA {
				src0 = 256 + (ext & 0xFF)
				f.valu.dpp = Dpp{kind = .Row, ctrl = u16((ext >> 8) & 0x1FF), row_mask = u8(ext >> 28), bank_mask = u8((ext >> 24) & 0xF), bound_ctrl = bit(ext, 19), fi = bit(ext, 18)}
			} else if src0 == 0xE9 || src0 == 0xEA {
				f.valu.dpp = Dpp{kind = .Lanes, sel = ext >> 8, fi = src0 == 0xEA}
				src0 = 256 + (ext & 0xFF)
			}
			op0 := op_source(src0, v_dn, ext)
			op1 := op_source(src1, v_dn, ext)
			if inst.encoding == .Vopc {
				if !f.valu.has_dst {
					f.valu.has_dst = true
					f.valu.dst = op_scalar(EXEC_SCALAR if strings.has_prefix(name, "v_cmpx") else VCC_SCALAR, lanes)
				}
				append(&f.valu.src, op0, op1)
			} else if inst.encoding == .Vop1 {
				f.valu.has_dst = true
				f.valu.dst = op_scalar(u8((w0 >> 17) & 0xFF), 1) if (name == "v_readlane_b32" || name == "v_readfirstlane_b32") else op_vector((w0 >> 17) & 0xFF, v_dn)
				append(&f.valu.src, op0)
			} else {
				f.valu.has_dst = true
				f.valu.dst = op_vector((w0 >> 17) & 0xFF, v_dn)
				if strings.has_suffix(name, "mk_f32") || strings.has_suffix(name, "mk_f16") {
					append(&f.valu.src, op0, Operand{kind = .Literal, literal = ext, dwords = 1}, op1)
				} else if strings.has_suffix(name, "ak_f32") || strings.has_suffix(name, "ak_f16") {
					append(&f.valu.src, op0, op1, Operand{kind = .Literal, literal = ext, dwords = 1})
				} else {
					append(&f.valu.src, op0, op1)
				}
				if carry_in { append(&f.valu.src, op_scalar(VCC_SCALAR, lanes)) }
				if strings.has_suffix(name, "_co_ci_u32") { f.valu.has_carry = true; f.valu.carry = op_scalar(VCC_SCALAR, lanes) }
			}
		} else {
			cnt := 3
			if inst.encoding == .Vop3p {
				cnt = 2 if (strings.has_prefix(name, "v_pk_") && !strings.contains(name, "_fma_") && !strings.contains(name, "_mad_")) else 3
			} else if inst.opcode < 0x100 { cnt = 2 } else if inst.opcode < 0x140 { cnt = 2 + (1 if carry_in else 0) } else if inst.opcode >= 0x180 && inst.opcode < 0x200 { cnt = 1 } else if strings.has_suffix(name, "_f64") || name == "v_mul_lo_u32" || name == "v_mul_hi_u32" || name == "v_mul_lo_i32" || name == "v_mul_hi_i32" || name == "v_readlane_b32" || name == "v_writelane_b32" || name == "v_bfm_b32" || name == "v_mbcnt_lo_u32_b32" || name == "v_mbcnt_hi_u32_b32" || name == "v_add_co_u32" || name == "v_sub_co_u32" || name == "v_subrev_co_u32" { cnt = 2 }
			for i := 0; i < cnt; i += 1 {
				code := (w1 >> uint(9 * i)) & 0x1FF
				if i == 0 && strings.has_prefix(name, "v_interp_") {
					append(&f.valu.src, Operand{kind = .Attr, attr_index = u8(code & 0x3F), attr_chan = u8((code >> 6) & 3), attr_high = bit(code, 8), dwords = 1})
				} else if i == 2 && carry_in {
					append(&f.valu.src, op_source(code, lanes, w2))
				} else {
					append(&f.valu.src, op_source(code, v_dn, w2))
				}
			}
			f.valu.clamp = bit(w0, 15)
			f.valu.neg = u8(w1 >> 29)
			f.valu.omod = u8((w1 >> 27) & 3)
			if name == "v_add_co_u32" || name == "v_sub_co_u32" || name == "v_subrev_co_u32" || strings.has_suffix(name, "_co_ci_u32") {
				f.valu.has_carry = true
				f.valu.carry = op_scalar(u8((w0 >> 8) & 0x7F), lanes)
			} else {
				f.valu.abs = u8((w0 >> 8) & 7)
				f.valu.opsel = u8((w0 >> 11) & 0xF)
			}
			vd := w0 & 0xFF
			f.valu.has_dst = true
			if cmp {
				f.valu.dst = op_scalar(u8(vd), lanes)
			} else if name == "v_readlane_b32" || name == "v_readfirstlane_b32" {
				f.valu.dst = op_scalar(u8(vd), 1)
			} else {
				f.valu.dst = op_vector(vd, v_dn)
			}
		}
	case .Vintrp:
		f.kind = .Valu
		f.valu.has_dst = true; f.valu.dst = op_vector(w0 >> 18, 1)
		vsrc := u8(w0 & 0xFF)
		s := Operand{kind = .Const, code = vsrc, dwords = 1} if name == "v_interp_mov_f32" else op_vector(u32(vsrc), 1)
		attr := Operand{kind = .Attr, attr_index = u8((w0 >> 10) & 0x3F), attr_chan = u8((w0 >> 8) & 3), dwords = 1}
		append(&f.valu.src, s, attr)
	case .Ds:
		f.kind = .Ds
		f.offset0 = u16(u8(w0))
		f.offset1 = u8(w0 >> 8)
		f.lds = bit(w0, 17)
		f.has_dst = strings.contains(name, "read") || strings.contains(name, "_rtn") || name == "ds_swizzle_b32" || name == "ds_permute_b32" || name == "ds_bpermute_b32"
		if f.has_dst { f.dst = op_vector(w1 >> 24, data_dwords(name)) }
		f.has_base = true; f.base = op_vector(w1 & 0xFF, 1)
		append(&f.src, op_vector((w1 >> 8) & 0xFF, data_dwords(name)))
	case .Mubuf, .Mtbuf:
		f.kind = .Buffer
		f.offen = bit(w0, 12); f.idxen = bit(w0, 13); f.tfe = bit(w1, 23)
		f.offset0 = u16(w0 & 0xFFF)
		f.lds = (inst.encoding == .Mubuf) && bit(w0, 16)
		if inst.encoding == .Mtbuf { f.has_format = true; f.format = u8((w0 >> 19) & 0x7F) }
		f.cache = {glc = bit(w0, 14), slc = bit(w1, 22), dlc = bit(w0, 15)}
		if !strings.has_suffix(name, "_inv") {
			f.has_dst = true; f.dst = op_vector((w1 >> 8) & 0xFF, data_dwords(name) + (1 if f.tfe else 0))
		}
		f.has_base = true; f.base = op_vector(w1 & 0xFF, 2 if (f.offen && f.idxen) else 1)
		append(&f.src, op_scalar(u8(((w1 >> 16) & 0x1F) << 2), 4)) // rsrc
		f.soffset = op_source(w1 >> 24, 1, 0)
	case .Mimg:
		f.kind = .Image
		f.dim = u8((w0 >> 3) & 7); f.dmask = u8((w0 >> 8) & 0xF)
		f.unorm = bit(w0, 12); f.r128 = bit(w0, 15); f.tfe = bit(w0, 16); f.lwe = bit(w0, 17)
		f.a16 = bit(w1, 30); f.d16 = bit(w1, 31)
		f.cache = {glc = bit(w0, 13), slc = bit(w0, 25), dlc = bit(w0, 7)}
		ones: u8 = 0
		for b in 0 ..< 4 { if (f.dmask >> uint(b)) & 1 != 0 { ones += 1 } }
		dn := u8(4) if strings.has_prefix(name, "image_gather4") else max(ones, 1)
		if f.d16 { dn = (dn + 1) / 2 }
		f.has_dst = true; f.dst = op_vector((w1 >> 8) & 0xFF, dn + (1 if (f.tfe || f.lwe) else 0))
		f.has_base = true; f.base = op_scalar(u8(((w1 >> 16) & 0x1F) << 2), 4 if f.r128 else 8)
		nsize := int((w0 >> 1) & 3)
		coords := 2
		switch f.dim {
		case 0: coords = 1
		case 1, 4: coords = 2
		case 2, 3, 5, 6: coords = 3
		case 7: coords = 4
		}
		if f.a16 { coords = (coords + 1) / 2 }
		if strings.contains(name, "_mip") { coords += 1 }
		if strings.has_prefix(name, "image_sample") || strings.has_prefix(name, "image_gather4") {
			if strings.has_suffix(name, "_o") || strings.contains(name, "_o_") { coords += 1 }
			if strings.has_suffix(name, "_b") || strings.contains(name, "_b_") { coords += 1 }
			if strings.has_suffix(name, "_c") || strings.contains(name, "_c_") || strings.contains(name, "_cd") { coords += 1 }
			if strings.has_suffix(name, "_l") || strings.contains(name, "_l_") { coords += 1 }
			if strings.has_suffix(name, "_cl") || strings.contains(name, "_cl_") { coords += 1 }
			if strings.has_suffix(name, "_d") || strings.contains(name, "_d_") || strings.contains(name, "_cd") {
				coords += 2 if f.dim == 0 else 4
			}
		} else if strings.has_prefix(name, "image_get_resinfo") {
			coords = 1
		}
		if nsize > 0 && inst.word_len >= 3 {
			if coords < 2 { coords = 2 }
			append(&f.src, op_vector(w1 & 0xFF, 1))
			for ci in 1 ..< coords {
				wi := 2 + (ci - 1) / 4
				if wi >= inst.word_len { break }
				sh := uint(((ci - 1) % 4) * 8)
				append(&f.src, op_vector((inst.words[wi] >> sh) & 0xFF, 1))
			}
		} else {
			append(&f.src, op_vector(w1 & 0xFF, u8(max(coords, 1)))) // coord base
		}
		if strings.has_prefix(name, "image_sample") || strings.has_prefix(name, "image_gather4") || strings.has_prefix(name, "image_get_lod") {
			f.has_sampler = true; f.sampler = op_scalar(u8(((w1 >> 21) & 0x1F) << 2), 4)
		}
	case .Flat, .Global, .Scratch:
		f.kind = .Flat
		saddr := u8((w1 >> 16) & 0x7F)
		glc := bit(w0, 16)
		f.lds = bit(w0, 13)
		f.cache = {glc = glc, slc = bit(w0, 17), dlc = bit(w0, 12)}
		f.s_offset = i32(w0 & 0x7FF) if inst.encoding == .Flat else i32(i16(w0 << 4) >> 4)
		if inst.encoding != .Flat { f.has_saddr = true; f.saddr = op_scalar(saddr, 2 if inst.encoding == .Global else 1) }
		dn := data_dwords(name)
		is_ld := strings.contains(name, "_load_")
		is_at := strings.contains(name, "_atomic_")
		if is_ld || (is_at && glc) { f.has_dst = true; f.dst = op_vector(w1 >> 24, dn) }
		f.has_base = true; f.base = op_vector(w1 & 0xFF, 2 if (inst.encoding == .Flat || saddr == NULL_SCALAR) else 1)
		if !is_ld { append(&f.src, op_vector((w1 >> 8) & 0xFF, dn)) }
	case .Exp:
		f.kind = .Exp
		f.exp_target = u8((w0 >> 4) & 0x3F)
		f.exp_compr = bit(w0, 10)
		f.exp_done = bit(w0, 11)
		f.exp_vm = bit(w0, 12)
		for i in 0 ..< 4 {
			if bit(w0, uint(i)) {
				slot := i / 2 if f.exp_compr else i
				f.exp_has[i] = true
				f.exp_src[i] = op_vector((w1 >> uint(8 * slot)) & 0xFF, 1)
			}
		}
	}
	return f
}
