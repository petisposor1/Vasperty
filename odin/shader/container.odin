package vasperty_shader

import "core:mem"
import "core:slice"
import "core:strings"

// DXBC containers, DXIL program headers, Xbox XDAT/XBOP extras, PC signature/PSV0 serialization,
// and D3D12 DXBC MD5 container hash.

Shader_Error :: enum {
	None,
	Not_Dxbc,
	Malformed,
	Isa_Error,
	Unsupported,
}

FourCC :: [4]u8

FOURCC_DXIL :: FourCC{'D', 'X', 'I', 'L'}
FOURCC_ACCC :: FourCC{'A', 'C', 'C', 'C'}
FOURCC_STAT :: FourCC{'S', 'T', 'A', 'T'}
FOURCC_RTS0 :: FourCC{'R', 'T', 'S', '0'}
FOURCC_PSV0 :: FourCC{'P', 'S', 'V', '0'}
FOURCC_ISG1 :: FourCC{'I', 'S', 'G', '1'}
FOURCC_OSG1 :: FourCC{'O', 'S', 'G', '1'}
FOURCC_PSG1 :: FourCC{'P', 'S', 'G', '1'}
FOURCC_SFI0 :: FourCC{'S', 'F', 'I', '0'}
FOURCC_HASH :: FourCC{'H', 'A', 'S', 'H'}
FOURCC_ILDB :: FourCC{'I', 'L', 'D', 'B'}
FOURCC_ILDN :: FourCC{'I', 'L', 'D', 'N'}

rd_u16 :: proc(data: []u8, at: int) -> (u16, Shader_Error) {
	if at < 0 || at + 2 > len(data) {
		return 0, .Malformed
	}
	return u16(data[at]) | (u16(data[at + 1]) << 8), .None
}

rd_u32 :: proc(data: []u8, at: int) -> (u32, Shader_Error) {
	if at < 0 || at + 4 > len(data) {
		return 0, .Malformed
	}
	return u32(data[at]) |
		(u32(data[at + 1]) << 8) |
		(u32(data[at + 2]) << 16) |
		(u32(data[at + 3]) << 24), .None
}

rd_u64 :: proc(data: []u8, at: int) -> (u64, Shader_Error) {
	if at < 0 || at + 8 > len(data) {
		return 0, .Malformed
	}
	lo, _ := rd_u32(data, at)
	hi, _ := rd_u32(data, at + 4)
	return u64(lo) | (u64(hi) << 32), .None
}

append_u16_le :: proc(out: ^[dynamic]u8, v: u16) {
	append(out, u8(v), u8(v >> 8))
}

append_u32_le :: proc(out: ^[dynamic]u8, v: u32) {
	append(out, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
}

append_u64_le :: proc(out: ^[dynamic]u8, v: u64) {
	append_u32_le(out, u32(v))
	append_u32_le(out, u32(v >> 32))
}

// =============================================================================
// DXBC Container Parser & Builder
// =============================================================================

Part :: struct {
	fourcc: FourCC,
	data:   []u8, // view into original DXBC slice
}

Container :: struct {
	hash:       [16]u8,
	total_size: u32,
	parts:      [dynamic]Part,
}

destroy_container :: proc(c: ^Container) {
	delete(c.parts)
	c^ = {}
}

dxbc_parse :: proc(data: []u8, allocator := context.allocator) -> (Container, Shader_Error) {
	c := Container{}
	if len(data) < 32 || data[0] != 'D' || data[1] != 'X' || data[2] != 'B' || data[3] != 'C' {
		return c, .Not_Dxbc
	}
	copy(c.hash[:], data[4:20])
	total_size, err1 := rd_u32(data, 24)
	if err1 != .None || int(total_size) > len(data) {
		return c, .Malformed
	}
	part_count, err2 := rd_u32(data, 28)
	if err2 != .None || part_count > 128 {
		return c, .Malformed
	}
	c.total_size = total_size
	c.parts = make([dynamic]Part, 0, int(part_count), allocator)

	for i := 0; i < int(part_count); i += 1 {
		off_u32, err_o := rd_u32(data, 32 + 4 * i)
		if err_o != .None {
			destroy_container(&c)
			return {}, .Malformed
		}
		off := int(off_u32)
		if off + 8 > int(total_size) {
			destroy_container(&c)
			return {}, .Malformed
		}
		sz_u32, err_s := rd_u32(data, off + 4)
		if err_s != .None || off + 8 + int(sz_u32) > int(total_size) {
			destroy_container(&c)
			return {}, .Malformed
		}
		fc := FourCC{data[off], data[off + 1], data[off + 2], data[off + 3]}
		append(&c.parts, Part{fourcc = fc, data = data[off + 8 : off + 8 + int(sz_u32)]})
	}
	return c, .None
}

dxbc_part :: proc(c: ^Container, fc: FourCC) -> ([]u8, bool) {
	for p in c.parts {
		if p.fourcc == fc {
			return p.data, true
		}
	}
	return nil, false
}

Raw_Part :: struct {
	fourcc: FourCC,
	data:   []u8,
}

dxbc_build :: proc(parts: []Raw_Part, allocator := context.allocator) -> []u8 {
	table := 0x20 + 4 * len(parts)
	total := table
	for p in parts {
		total += 8 + len(p.data)
	}
	out := make([dynamic]u8, 0, total, allocator)
	append(&out, 'D', 'X', 'B', 'C')
	for _ in 0 ..< 16 {
		append(&out, 0)
	}
	append_u16_le(&out, 1)
	append_u16_le(&out, 0)
	append_u32_le(&out, u32(total))
	append_u32_le(&out, u32(len(parts)))
	off := u32(table)
	for p in parts {
		append_u32_le(&out, off)
		off += u32(8 + len(p.data))
	}
	for p in parts {
		append(&out, p.fourcc[0], p.fourcc[1], p.fourcc[2], p.fourcc[3])
		append_u32_le(&out, u32(len(p.data)))
		if len(p.data) > 0 {
			append(&out, ..p.data)
		}
	}
	digest := dxbc_hash(out[20:])
	copy(out[4:20], digest[:])
	return out[:]
}

// dxbc_hash implements D3D12's non-standard DXBC MD5 tail framing.
dxbc_hash :: proc(data: []u8) -> [16]u8 {
	n := len(data)
	left := n % 64
	tail := make([dynamic]u8, 0, 128, context.temp_allocator)
	if left < 56 {
		append_u32_le(&tail, u32(n) << 3)
		append(&tail, ..data[n - left:])
		append(&tail, 0x80)
		for len(tail) < 60 {
			append(&tail, 0)
		}
	} else {
		append(&tail, ..data[n - left:])
		append(&tail, 0x80)
		for len(tail) < 64 {
			append(&tail, 0)
		}
		append_u32_le(&tail, u32(n) << 3)
		for len(tail) < 124 {
			append(&tail, 0)
		}
	}
	append_u32_le(&tail, (u32(n) << 1) | 1)

	state := [4]u32{0x6745_2301, 0xefcd_ab89, 0x98ba_dcfe, 0x1032_5476}
	head_end := n - left
	for off := 0; off < head_end; off += 64 {
		blk := cast(^[64]u8)raw_data(data[off:])
		md5_block(&state, blk)
	}
	for off := 0; off < len(tail); off += 64 {
		blk := cast(^[64]u8)raw_data(tail[off:])
		md5_block(&state, blk)
	}
	out: [16]u8
	for s, i in state {
		out[4 * i + 0] = u8(s)
		out[4 * i + 1] = u8(s >> 8)
		out[4 * i + 2] = u8(s >> 16)
		out[4 * i + 3] = u8(s >> 24)
	}
	return out
}

md5_block :: proc(state: ^[4]u32, block: ^[64]u8) {
	S := [64]u32{
		7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
		5,  9, 14, 20, 5,  9, 14, 20, 5,  9, 14, 20, 5,  9, 14, 20,
		4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
		6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
	}
	K := [64]u32{
		0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
		0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
		0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
		0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
		0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
		0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
		0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
		0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
		0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
		0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
		0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
		0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
		0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
		0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
		0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
		0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
	}
	x: [16]u32
	for i in 0 ..< 16 {
		x[i] = u32(block[4 * i]) | (u32(block[4 * i + 1]) << 8) | (u32(block[4 * i + 2]) << 16) | (u32(block[4 * i + 3]) << 24)
	}
	a, b, c, d := state[0], state[1], state[2], state[3]
	for i in 0 ..< 64 {
		f, g: u32
		switch i / 16 {
		case 0: f = (b & c) | ((~b) & d); g = u32(i)
		case 1: f = (d & b) | ((~d) & c); g = u32((5 * i + 1) % 16)
		case 2: f = b ~ c ~ d;            g = u32((3 * i + 5) % 16)
		case:   f = c ~ (b | (~d));       g = u32((7 * i) % 16)
		}
		tmp := a + f + K[i] + x[g]
		sh := S[i]
		rot := (tmp << sh) | (tmp >> (32 - sh))
		a, b, c, d = d, b + rot, b, c
	}
	state[0] += a
	state[1] += b
	state[2] += c
	state[3] += d
}

// =============================================================================
// DXIL Program Header & Xbox Extensions
// =============================================================================

Shader_Kind :: enum u16 {
	Pixel         = 0,
	Vertex        = 1,
	Geometry      = 2,
	Hull          = 3,
	Domain        = 4,
	Compute       = 5,
	Library       = 6,
	Mesh          = 13,
	Amplification = 14,
}

Xbox_Extras :: struct {
	has_xdat: bool,
	has_xbop: bool,
	xbop:     string,
}

Dxil_Program :: struct {
	kind_raw:      u16,
	major:         u8,
	minor:         u8,
	dxil_version:  u32,
	bitcode_offset: u32,
	bitcode:       []u8,
	extras:        Xbox_Extras,
}

dxil_parse :: proc(part: []u8) -> (Dxil_Program, Shader_Error) {
	if len(part) < 24 {
		return {}, .Malformed
	}
	ver_kind, _ := rd_u32(part, 0)
	kind_raw := u16(ver_kind >> 16)
	major := u8((ver_kind >> 4) & 0xF)
	minor := u8(ver_kind & 0xF)
	magic, _ := rd_u32(part, 8)
	if magic != 0x4C495844 { // "DXIL"
		return {}, .Malformed
	}
	dxil_ver, _ := rd_u32(part, 12)
	bc_off, _ := rd_u32(part, 16)
	bc_sz, _ := rd_u32(part, 20)
	abs_off := 8 + int(bc_off)
	if abs_off < 24 || abs_off + int(bc_sz) > len(part) {
		return {}, .Malformed
	}
	extras := Xbox_Extras{}
	if len(part) >= 28 && part[24] == 'X' && part[25] == 'D' && part[26] == 'A' && part[27] == 'T' {
		extras.has_xdat = true
		cnt, err_c := rd_u32(part, 28)
		if err_c == .None && cnt <= 64 {
			for i := 0; i < int(cnt); i += 1 {
				at := 0x18 + 12 + 12 * i
				k, err_k := rd_u32(part, at)
				if err_k == .None && k == 0x0a {
					off_x, _ := rd_u32(part, at + 4)
					sz_x, _ := rd_u32(part, at + 8)
					if int(off_x) + int(sz_x) <= len(part) && sz_x >= 4 {
						extras.has_xbop = true
						raw := part[int(off_x) + 4 : int(off_x) + int(sz_x)]
						extras.xbop = strings.trim_right(string(raw), "\x00")
					}
					break
				}
			}
		}
	}
	return Dxil_Program{
		kind_raw       = kind_raw,
		major          = major,
		minor          = minor,
		dxil_version   = dxil_ver,
		bitcode_offset = bc_off,
		bitcode        = part[abs_off : abs_off + int(bc_sz)],
		extras         = extras,
	}, .None
}

dxil_is_standard_layout :: proc(p: ^Dxil_Program) -> bool {
	return p.bitcode_offset == 16 && !p.extras.has_xdat
}

dxil_build_standard :: proc(kind: Shader_Kind, major, minor: u8, bitcode: []u8, allocator := context.allocator) -> []u8 {
	out := make([dynamic]u8, 0, 24 + len(bitcode), allocator)
	append_u32_le(&out, (u32(kind) << 16) | (u32(major & 0xF) << 4) | u32(minor & 0xF))
	append_u32_le(&out, u32((24 + len(bitcode)) / 4))
	append(&out, 'D', 'X', 'I', 'L')
	append_u32_le(&out, 0x106)
	append_u32_le(&out, 16)
	append_u32_le(&out, u32(len(bitcode)))
	if len(bitcode) > 0 {
		append(&out, ..bitcode)
	}
	return out[:]
}

// =============================================================================
// Signatures (ISG1 / OSG1 / PSG1) & PSV0 Serialization
// =============================================================================

Sig_Element :: struct {
	name:      string,
	index:     u32,
	kind:      u8,
	comp:      u8, // 1 i1, 4 i32, 5 u32, 9 f32
	interp:    u8,
	has_row:   bool,
	row:       u32,
	col:       u8,
	cols:      u8,
	usage:     u8,
	half:      bool,
}

destroy_sig_elements :: proc(els: []Sig_Element) {
	for e in els {
		delete(e.name)
	}
	delete(els)
}

sig_system_value :: proc(kind: u8) -> u32 {
	switch kind {
	case 1:  return 6
	case 2:  return 8
	case 3:  return 1
	case 4:  return 4
	case 5:  return 5
	case 6:  return 2
	case 7:  return 3
	case 10: return 7
	case 12: return 10
	case 13: return 9
	case 14: return 66
	case 15: return 70
	case 16: return 64
	case 17: return 65
	case 18: return 68
	case 19: return 67
	case 20: return 69
	case 30: return 25
	}
	return 0
}

sig_comp_kind :: proc(comp: u8) -> u32 {
	switch comp {
	case 1, 5: return 1
	case 4:    return 2
	case 9:    return 3
	}
	return 0
}

parse_signature_part :: proc(part: []u8, allocator := context.allocator) -> ([]Sig_Element, Shader_Error) {
	cnt, e1 := rd_u32(part, 0)
	base, e2 := rd_u32(part, 4)
	if e1 != .None || e2 != .None || cnt > 64 {
		return nil, .Malformed
	}
	out := make([dynamic]Sig_Element, 0, int(cnt), allocator)
	for i := 0; i < int(cnt); i += 1 {
		at := int(base) + 32 * i
		if at + 32 > len(part) {
			destroy_sig_elements(out[:])
			return nil, .Malformed
		}
		stream, _ := rd_u32(part, at)
		if stream != 0 {
			destroy_sig_elements(out[:])
			return nil, .Unsupported
		}
		name_at, _ := rd_u32(part, at + 4)
		if int(name_at) >= len(part) {
			destroy_sig_elements(out[:])
			return nil, .Malformed
		}
		end := int(name_at)
		for end < len(part) && part[end] != 0 {
			end += 1
		}
		if end == len(part) {
			destroy_sig_elements(out[:])
			return nil, .Malformed
		}
		sv_raw, _ := rd_u32(part, at + 12)
		kind: u8 = 0
		switch sv_raw {
		case 0: kind = 0
		case 1: kind = 3
		case 2: kind = 6
		case 3: kind = 7
		case 4: kind = 4
		case 5: kind = 5
		case 6: kind = 1
		case 7: kind = 10
		case 8: kind = 2
		case 9: kind = 13
		case 10: kind = 12
		case 64: kind = 16
		case 65: kind = 17
		case 66: kind = 14
		case 67: kind = 19
		case 68: kind = 18
		case 69: kind = 20
		case 70: kind = 15
		case 25: kind = 30
		case:
			destroy_sig_elements(out[:])
			return nil, .Unsupported
		}
		raw_comp, _ := rd_u32(part, at + 16)
		comp: u8 = 9
		if kind == 13 {
			comp = 5
		} else {
			switch raw_comp {
			case 1, 4: comp = 5
			case 2, 5: comp = 4
			case 3, 6: comp = 9
			case:
				destroy_sig_elements(out[:])
				return nil, .Unsupported
			}
		}
		idx, _ := rd_u32(part, at + 8)
		reg, _ := rd_u32(part, at + 20)
		mask := part[at + 24]
		min_prec, _ := rd_u32(part, at + 28)
		if min_prec != 0 {
			destroy_sig_elements(out[:])
			return nil, .Unsupported
		}
		col: u8 = 0
		if mask != 0 {
			tz: u8 = 0
			m := mask
			for m & 1 == 0 && tz < 3 {
				tz += 1
				m >>= 1
			}
			col = tz
		}
		ones: u8 = 0
		for b in 0 ..< 4 {
			if (mask >> uint(b)) & 1 != 0 { ones += 1 }
		}
		append(&out, Sig_Element{
			name    = strings.clone(string(part[int(name_at):end]), allocator),
			index   = idx,
			kind    = kind,
			comp    = comp,
			interp  = 0,
			has_row = reg != 0xFFFFFFFF,
			row     = reg,
			col     = col,
			cols    = max(ones, 1),
			usage   = 0,
			half    = raw_comp >= 4 && raw_comp <= 6,
		})
	}
	return out[:], .None
}

same_mode_per_row :: proc(elements: []Sig_Element, read: bool) {
	is_free :: proc(e: ^Sig_Element, read: bool) -> bool {
		return e.kind == 0 && e.comp == 9 && !(read && e.usage != 0)
	}
	for &e, i in elements {
		if !e.has_row || !is_free(&e, read) { continue }
		row := e.row
		decided: u8 = 0
		mixed := false
		for &o, j in elements {
			_ = j
			if !o.has_row || o.row != row || is_free(&o, read) || o.interp == 0 { continue }
			if decided == 0 {
				decided = o.interp
			} else if decided != o.interp {
				mixed = true
				break
			}
		}
		if decided != 0 && !mixed {
			elements[i].interp = decided
		}
	}
}

build_signature_part :: proc(elements: []Sig_Element, input: bool, allocator := context.allocator) -> []u8 {
	out := make([dynamic]u8, 0, 8 + 32 * len(elements) + 64, allocator)
	append_u32_le(&out, u32(len(elements)))
	append_u32_le(&out, 8)
	offsets := make([]u32, len(elements), context.temp_allocator)
	names := make([dynamic]string, 0, len(elements), context.temp_allocator)
	next_off := u32(8 + 32 * len(elements))
	for e, i in elements {
		shared := -1
		if e.kind != 0 {
			for j in 0 ..< i {
				if elements[j].kind == e.kind {
					shared = j
					break
				}
			}
		}
		if shared >= 0 {
			offsets[i] = offsets[shared]
		} else {
			offsets[i] = next_off
			next_off += u32(len(e.name) + 1)
			append(&names, e.name)
		}
	}
	order := make([]int, len(elements), context.temp_allocator)
	for i in 0 ..< len(elements) { order[i] = i }
	slice.sort_by(order, proc(a, b: int) -> bool { return a < b })
	// Simple stable insertion sort by row so unallocated rows go last.
	for i := 1; i < len(order); i += 1 {
		key := order[i]
		kr := elements[key].row if elements[key].has_row else u32(0xFFFFFFFF)
		j := i - 1
		for j >= 0 {
			jr := elements[order[j]].row if elements[order[j]].has_row else u32(0xFFFFFFFF)
			if jr <= kr { break }
			order[j + 1] = order[j]
			j -= 1
		}
		order[j + 1] = key
	}

	for idx in order {
		e := elements[idx]
		used := e.usage << e.col
		rw := used if input else (~used & 0xF)
		mask := ((u8(1) << e.cols) - 1) << e.col
		reg := e.row if e.has_row else u32(0xFFFFFFFF)
		append_u32_le(&out, 0)
		append_u32_le(&out, offsets[idx])
		append_u32_le(&out, e.index)
		append_u32_le(&out, sig_system_value(e.kind))
		append_u32_le(&out, sig_comp_kind(e.comp))
		append_u32_le(&out, reg)
		append(&out, mask, rw, 0, 0)
		append_u32_le(&out, 0)
	}
	for nm in names {
		if len(nm) > 0 { append(&out, ..transmute([]u8)nm) }
		append(&out, 0)
	}
	return out[:]
}

Psv_Binding :: struct {
	kind:      u32, // 1 sampler, 2 cbv, 3 srv, 4 uav
	space:     u32,
	register:  u32,
	dxil_kind: u32,
}

Mesh_Desc :: struct {
	max_vertices:   u32,
	max_primitives: u32,
	topology:       u8, // 1 lines, 2 triangles
}

Psv_Desc :: struct {
	stage:      u8,
	flag:       bool,
	inputs:     []Sig_Element,
	outputs:    []Sig_Element,
	prims:      []Sig_Element,
	has_mesh:   bool,
	mesh:       Mesh_Desc,
	mesh_lds:   u32,
	has_gs:     bool,
	gs_max:     u32,
	bindings:   []Psv_Binding,
	threads:    [3]u32,
	has_wave:   bool,
	wave_size:  u32,
}

build_psv0 :: proc(p: ^Psv_Desc, allocator := context.allocator) -> []u8 {
	max_vec :: proc(els: []Sig_Element) -> u32 {
		m: u32 = 0
		for e in els {
			if e.has_row && e.row + 1 > m { m = e.row + 1 }
		}
		return m
	}
	in_vecs := max_vec(p.inputs)
	out_vecs := max_vec(p.outputs)
	out := make([dynamic]u8, 0, 256, allocator)
	append_u32_le(&out, 48)

	info: [48]u8
	info[0] = 1 if p.flag else 0
	if p.stage == 0 {
		for e in p.inputs {
			if e.interp == 6 || e.interp == 7 || e.kind == 12 {
				info[1] = 1
				break
			}
		}
	}
	wmin := p.wave_size if p.has_wave else 0
	wmax := p.wave_size if p.has_wave else u32(0xFFFFFFFF)
	copy(info[16:20], mem.byte_slice(&wmin, 4))
	copy(info[20:24], mem.byte_slice(&wmax, 4))
	info[24] = p.stage
	for k in 0 ..< 3 {
		v := p.threads[k]
		copy(info[36 + 4 * k : 40 + 4 * k], mem.byte_slice(&v, 4))
	}
	info[28] = u8(len(p.inputs))
	info[29] = u8(len(p.outputs))
	info[31] = u8(in_vecs)
	info[32] = u8(out_vecs)
	if p.has_mesh {
		copy(info[0:4], mem.byte_slice(&p.mesh_lds, 4))
		mv := u16(p.mesh.max_vertices)
		mp := u16(p.mesh.max_primitives)
		copy(info[12:14], mem.byte_slice(&mv, 2))
		copy(info[14:16], mem.byte_slice(&mp, 2))
		info[26] = u8(max_vec(p.prims))
		info[27] = p.mesh.topology
		info[30] = u8(len(p.prims))
	}
	if p.has_gs {
		gv := [3]u32{3, 5, 1}
		for k in 0 ..< 3 {
			v := gv[k]
			copy(info[4 * k : 4 * k + 4], mem.byte_slice(&v, 4))
		}
		info[12] = 1 if p.flag else 0
		gm := u16(p.gs_max)
		copy(info[26:28], mem.byte_slice(&gm, 2))
	}
	append(&out, ..info[:])

	append_u32_le(&out, u32(len(p.bindings)))
	if len(p.bindings) > 0 {
		append_u32_le(&out, 24)
		for b in p.bindings {
			append_u32_le(&out, b.kind)
			append_u32_le(&out, b.space)
			append_u32_le(&out, b.register)
			append_u32_le(&out, b.register)
			append_u32_le(&out, b.dxil_kind)
			append_u32_le(&out, 0)
		}
	}

	strs := make([dynamic]u8, 0, 64, context.temp_allocator)
	append(&strs, 0)
	indices := make([dynamic]u32, 0, 16, context.temp_allocator)
	Elem_Rec :: struct { name_off, idx: u32, start, cols: u8, e: Sig_Element }
	erecs := make([dynamic]Elem_Rec, 0, len(p.inputs) + len(p.outputs) + len(p.prims), context.temp_allocator)

	for group in ([3][]Sig_Element{p.inputs, p.outputs, p.prims}) {
		for e in group {
			name_off: u32 = 0
			if e.kind == 0 {
				needle := make([]u8, len(e.name) + 1, context.temp_allocator)
				copy(needle, e.name)
				found := -1
				if len(strs) >= len(needle) {
					for pos := 0; pos <= len(strs) - len(needle); pos += 1 {
						if mem.compare_ptrs(raw_data(strs[pos:]), raw_data(needle), len(needle)) == 0 {
							found = pos
							break
						}
					}
				}
				if found >= 0 {
					name_off = u32(found)
				} else {
					name_off = u32(len(strs))
					append(&strs, ..needle)
				}
			}
			idx_pos: u32 = 0
			found_idx := false
			for existing, ei in indices {
				if existing == e.index {
					idx_pos = u32(ei)
					found_idx = true
					break
				}
			}
			if !found_idx {
				idx_pos = u32(len(indices))
				append(&indices, e.index)
			}
			start := u8(e.row) if e.has_row else 0
			alloc := (0x40 | (e.col << 4)) if e.has_row else 0
			append(&erecs, Elem_Rec{name_off = name_off, idx = idx_pos, start = start, cols = e.cols | alloc, e = e})
		}
	}
	for len(strs) % 4 != 0 { append(&strs, 0) }
	append_u32_le(&out, u32(len(strs)))
	append(&out, ..strs[:])
	append_u32_le(&out, u32(len(indices)))
	for idx in indices { append_u32_le(&out, idx) }
	if len(erecs) > 0 {
		append_u32_le(&out, 16)
		for er in erecs {
			append_u32_le(&out, er.name_off)
			append_u32_le(&out, er.idx)
			append(&out, 1, er.start, er.cols, er.e.kind, u8(sig_comp_kind(er.e.comp)), er.e.interp, 0, 0)
		}
	}
	if in_vecs > 0 && out_vecs > 0 {
		scalars :: proc(els: []Sig_Element) -> u32 {
			m: u32 = 0
			for e in els {
				if e.has_row {
					v := e.row * 4 + u32(e.col + e.cols)
					if v > m { m = v }
				}
			}
			return m
		}
		ni := scalars(p.inputs)
		no := scalars(p.outputs)
		per := (out_vecs * 4 + 31) / 32
		for i in 0 ..< in_vecs * 4 {
			for k in 0 ..< per {
				bits: u32 = 0
				if i < ni && no > 32 * k {
					bits = min(no - 32 * k, 32)
				}
				mask := u32(0xFFFFFFFF) if bits == 32 else ((u32(1) << bits) - 1)
				append_u32_le(&out, mask)
			}
		}
	}
	return out[:]
}
