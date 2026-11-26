package vasperty_formats

import "core:math/bits"
import "core:os"
import "core:thread"

SWIZZLE_LINEAR :: u32(0)
SWIZZLE_256B_S :: u32(1)
SWIZZLE_256B_D :: u32(2)
SWIZZLE_4KB_S :: u32(5)
SWIZZLE_4KB_D :: u32(6)
SWIZZLE_64KB_S :: u32(9)
SWIZZLE_64KB_D :: u32(10)
SWIZZLE_64KB_S_T :: u32(17)
SWIZZLE_64KB_D_T :: u32(18)
SWIZZLE_4KB_S_X :: u32(21)
SWIZZLE_4KB_D_X :: u32(22)
SWIZZLE_4KB_R_X :: u32(23)
SWIZZLE_64KB_Z_X :: u32(24)
SWIZZLE_64KB_S_X :: u32(25)
SWIZZLE_64KB_D_X :: u32(26)
SWIZZLE_64KB_R_X :: u32(27)

Dimension :: enum {
	Tex1d,
	Tex2d,
	Tex3d,
}

Format_Error :: enum {
	None,
	Invalid,
	Unsupported,
	Too_Small,
}

Desc :: struct {
	dimension:     Dimension,
	width:         u32,
	height:        u32,
	depth:         u32,
	mips:          u32,
	element_bytes: u32,
	block:         u32,
	samples:       u32,
	swizzle:       u32,
}

Tail :: struct {
	offset: u32,
	x:      u32,
	y:      u32,
}

Mip :: struct {
	width:       u32,
	height:      u32,
	depth:       u32,
	pitch:       u32,
	rows:        u32,
	depth_pitch: u32,
	offset:      u64,
	has_tail:    bool,
	tail:        Tail,
}

Dxgi_Format_Info :: struct {
	bytes:   u32,
	block:   u32,
	stencil: bool,
	valid:   bool,
}

Layout :: struct {
	desc:           Desc,
	block:          [3]u32,
	thick:          bool,
	slices:         u32,
	slice_size:     u64,
	size:           u64,
	alignment:      u64,
	first_tail_mip: u32,
	mips:           [dynamic]Mip,
	pattern:        [3][]u32,
}

@(private)
Row_Run :: struct {
	tiled:  int,
	linear: int,
	length: int,
}

@(private)
MAX_MIPS :: u32(16)
@(private)
MAX_EXTENT :: u32(1) << 14

@(private)
BLOCK_256_2D := [5][2]u32{{16, 16}, {16, 8}, {8, 8}, {8, 4}, {4, 4}}
@(private)
BLOCK_256_3D := [5][3]u32{{8, 4, 8}, {4, 4, 8}, {4, 4, 4}, {4, 2, 4}, {2, 2, 4}}
@(private)
BLOCK_1K_3D := [5][3]u32{{16, 8, 8}, {8, 8, 8}, {8, 8, 4}, {8, 4, 4}, {4, 4, 4}}

@(private)
MICRO := [3][5]string{
	{
		"x0x1x2x3y0y1y2y3",
		"--x0x1x2y0y1y2x3",
		"----x0x1y0y1y2x2",
		"------x0y0y1x1x2",
		"--------y0y1x0x1",
	},
	{
		"x0x1x2y1y0y2x3y3",
		"--x0x1x2y0y1y2x3",
		"----x0x1y0y1x2y2",
		"------x0y0x1x2y1",
		"--------x0y0x1y1",
	},
	{
		"x0x1z0y0z1y1x2z2",
		"--x0z0y0z1y1x1z2",
		"----x0y0z0y1x1z1",
		"------x0z0y0x1z1",
		"--------z0y0x0z1",
	},
}

swizzle_block_log2 :: proc(sw: u32) -> (u32, bool) {
	switch sw {
	case 0:
		return 0, true
	case 1, 2:
		return 8, true
	case 5, 6, 21, 22, 23:
		return 12, true
	case 9, 10, 17, 18, 24, 25, 26, 27:
		return 16, true
	case:
		return 0, false
	}
}

@(private)
swizzle_standard :: proc(sw: u32) -> bool {
	return sw == 1 || sw == 5 || sw == 9 || sw == 17 || sw == 21 || sw == 25
}

@(private)
swizzle_display :: proc(sw: u32) -> bool {
	return sw == 2 || sw == 6 || sw == 10 || sw == 18 || sw == 22 || sw == 26
}

@(private)
swizzle_xor :: proc(sw: u32) -> bool {
	return sw >= 16
}

dxgi_format_info :: proc(dxgi: u32) -> Dxgi_Format_Info {
	switch dxgi {
	case 1 ..= 4:
		return {16, 1, false, true}
	case 9 ..= 18:
		return {8, 1, false, true}
	case 19 ..= 22, 44 ..= 47:
		return {4, 1, true, true}
	case 23 ..= 43, 67, 87 ..= 93, 116, 117:
		return {4, 1, false, true}
	case 48 ..= 59, 85, 86, 115:
		return {2, 1, false, true}
	case 118 ..= 120:
		return {2, 1, true, true}
	case 60 ..= 65:
		return {1, 1, false, true}
	case 70 ..= 72, 79 ..= 81:
		return {8, 4, false, true}
	case 73 ..= 78, 82 ..= 84, 94 ..= 99:
		return {16, 4, false, true}
	case:
		return {}
	}
}

@(private)
div_ceil_u32 :: #force_inline proc "contextless" (a, b: u32) -> u32 {
	return (a + b - 1) / b
}

@(private)
next_mult_u32 :: #force_inline proc "contextless" (v, a: u32) -> u32 {
	if a <= 1 {
		return v
	}
	return div_ceil_u32(v, a) * a
}

@(private)
tex_dim :: #force_inline proc "contextless" (texels, mip, block: u32) -> u32 {
	shifted := texels >> mip
	if shifted < 1 {
		shifted = 1
	}
	return div_ceil_u32(shifted, block)
}

@(private)
padded_dim :: #force_inline proc "contextless" (texels, mip, block: u32) -> u32 {
	base := texels
	if base < 1 {
		base = 1
	}
	return div_ceil_u32(div_ceil_u32(base, block), u32(1) << mip)
}

@(private)
build_pattern :: proc(kind: int, element_log2, block_log2: u32, allocator := context.allocator) -> [3][]u32 {
	bit_axes: [3][dynamic]u32
	for a := 0; a < 3; a += 1 {
		bit_axes[a] = make([dynamic]u32, allocator)
	}
	defer for a := 0; a < 3; a += 1 {
		delete(bit_axes[a])
	}

	micro := MICRO[kind][element_log2]
	for bit: u32 = 0; bit < 8; bit += 1 {
		axis_ch := micro[2 * bit]
		idx_ch := micro[2 * bit + 1]
		axis := -1
		switch axis_ch {
		case 'x':
			axis = 0
		case 'y':
			axis = 1
		case 'z':
			axis = 2
		case:
			continue
		}
		idx := int(idx_ch - '0')
		for len(bit_axes[axis]) <= idx {
			append(&bit_axes[axis], 0)
		}
		bit_axes[axis][idx] = bit
	}

	thin_order := [2]int{1, 0}
	thick_order := [3]int{1, 0, 2}
	for bit := u32(8); bit < block_log2; bit += 1 {
		step := int(bit - 8)
		axis := thick_order[step % 3] if kind == 2 else thin_order[step % 2]
		append(&bit_axes[axis], bit)
	}

	out: [3][]u32
	for a := 0; a < 3; a += 1 {
		count := 1 << uint(len(bit_axes[a]))
		tbl := make([]u32, count, allocator)
		for c := 0; c < count; c += 1 {
			acc: u32 = 0
			for to, i in bit_axes[a] {
				if ((c >> uint(i)) & 1) != 0 {
					acc += u32(1) << to
				}
			}
			tbl[c] = acc
		}
		out[a] = tbl
	}
	return out
}

destroy_layout :: proc(l: ^Layout, allocator := context.allocator) {
	delete(l.mips)
	for a := 0; a < 3; a += 1 {
		if len(l.pattern[a]) > 0 {
			delete(l.pattern[a], allocator)
		}
	}
	l^ = {}
}

new_layout :: proc(desc: Desc, allocator := context.allocator) -> (layout: Layout, err: Format_Error) {
	block_log2, ok_sw := swizzle_block_log2(desc.swizzle)
	if !ok_sw {
		return layout, .Invalid
	}

	sw_ok_3d := desc.swizzle == 0 ||
		desc.swizzle == 5 ||
		desc.swizzle == 9 ||
		desc.swizzle == 17 ||
		desc.swizzle == 21 ||
		(desc.swizzle >= 24 && desc.swizzle <= 27)

	valid := desc.width >= 1 && desc.width <= MAX_EXTENT &&
		desc.height >= 1 && desc.height <= MAX_EXTENT &&
		desc.depth >= 1 && desc.depth <= MAX_EXTENT &&
		desc.mips >= 1 && desc.mips <= MAX_MIPS &&
		bits.is_power_of_two(desc.element_bytes) && desc.element_bytes <= 16 &&
		(desc.block == 1 || desc.block == 4) &&
		bits.is_power_of_two(desc.samples) && desc.samples <= 8 &&
		(desc.samples == 1 || (desc.dimension == .Tex2d && desc.mips == 1 && desc.swizzle != SWIZZLE_LINEAR)) &&
		(desc.dimension != .Tex1d || desc.height == 1) &&
		(desc.dimension != .Tex3d || sw_ok_3d)
	if !valid {
		return layout, .Invalid
	}

	if block_log2 == 0 {
		// Linear layout
		bpe := u64(desc.element_bytes)
		align := 256 / desc.element_bytes
		three_d := desc.dimension == .Tex3d
		mips := make([dynamic]Mip, allocator)
		offset: u64 = 0
		for idx := int(desc.mips) - 1; idx >= 0; idx -= 1 {
			i := u32(idx)
			h := padded_dim(desc.height, i, desc.block)
			pitch := next_mult_u32(padded_dim(desc.width, i, desc.block), align)
			append(&mips, Mip{
				width       = tex_dim(desc.width, i, desc.block),
				height      = tex_dim(desc.height, i, desc.block),
				depth       = tex_dim(desc.depth, i, 1) if three_d else 1,
				pitch       = pitch,
				rows        = h,
				depth_pitch = desc.depth if three_d else 1,
				offset      = offset,
				has_tail    = false,
			})
			offset += u64(pitch) * u64(h) * bpe
		}
		// Reverse smallest-first -> mip 0 first
		for l, r := 0, len(mips) - 1; l < r; l, r = l + 1, r - 1 {
			mips[l], mips[r] = mips[r], mips[l]
		}
		return Layout{
			desc           = desc,
			block          = {align, 1, 1},
			thick          = false,
			slices         = desc.depth,
			slice_size     = offset,
			size           = offset * u64(desc.depth),
			alignment      = 256,
			first_tail_mip = desc.mips,
			mips           = mips,
		}, .None
	}

	// Tiled layout
	element_log2 := bits.trailing_zeros(desc.element_bytes)
	bpe := u64(desc.element_bytes)
	block_bytes := u64(1) << block_log2
	thick := desc.dimension == .Tex3d && (swizzle_standard(desc.swizzle) || swizzle_display(desc.swizzle))

	block: [3]u32
	if thick {
		amp := (block_log2 - 10) / 3
		rest := (block_log2 - 10) % 3
		b := BLOCK_1K_3D[element_log2]
		block = {
			b[0] << amp,
			b[1] << (amp + rest / 2),
			b[2] << (amp + (1 if rest != 0 else 0)),
		}
	} else {
		samples_log2 := bits.trailing_zeros(desc.samples)
		elements_log2 := block_log2 - element_log2 - samples_log2
		wide := (samples_log2 & 1) == 0 || (block_log2 & 1) != 0
		w := (elements_log2 + (1 if wide else 0)) / 2
		block = {u32(1) << w, u32(1) << (elements_log2 - w), 1}
	}

	slices_raw := next_mult_u32(desc.depth, block[2])
	three_d := desc.dimension == .Tex3d
	mips := make([dynamic]Mip, allocator)
	first_tail_mip := desc.mips
	slice_size: u64 = 0

	if desc.mips == 1 {
		w0 := tex_dim(desc.width, 0, desc.block)
		h0 := tex_dim(desc.height, 0, desc.block)
		d0 := tex_dim(desc.depth, 0, 1) if three_d else 1
		pitch0 := next_mult_u32(w0, block[0])
		rows0 := next_mult_u32(h0, block[1])
		append(&mips, Mip{
			width       = w0,
			height      = h0,
			depth       = d0,
			pitch       = pitch0,
			rows        = rows0,
			depth_pitch = slices_raw if three_d else 1,
			offset      = 0,
			has_tail    = false,
		})
		slice_size = u64(pitch0) * u64(rows0) * bpe * u64(desc.samples)
	} else {
		tail_max := block
		if thick {
			switch block_log2 % 3 {
			case 0:
				tail_max[1] >>= 1
			case 1:
				tail_max[0] >>= 1
			case:
				tail_max[2] >>= 1
			}
		} else {
			tail_max[0] >>= 1
		}

		effective := (block_log2 - (block_log2 - 8) / 3) if thick else block_log2
		max_in_tail: u32
		switch effective {
		case 8:
			max_in_tail = 0
		case 9 ..= 11:
			max_in_tail = 1 + (u32(1) << (effective - 9))
		case:
			max_in_tail = effective - 4
		}

		fixed := tail_max
		if desc.swizzle == SWIZZLE_64KB_Z_X && element_log2 <= 1 {
			b := BLOCK_256_2D[element_log2]
			fixed[0] /= b[0] / BLOCK_256_2D[2][0]
			fixed[1] /= b[1] / BLOCK_256_2D[2][1]
		}

		sizes := make([dynamic]u64, allocator)
		defer delete(sizes)

		for i: u32 = 0; i < desc.mips; i += 1 {
			pw := padded_dim(desc.width, i, desc.block)
			ph := padded_dim(desc.height, i, desc.block)
			if pw <= fixed[0] && ph <= fixed[1] && (desc.mips - i) <= max_in_tail {
				first_tail_mip = i
				slice_size += block_bytes / u64(block[2])
				break
			}
			pitch := next_mult_u32(pw, block[0])
			rows := next_mult_u32(ph, block[1])
			mdepth := padded_dim(desc.depth, i, 1) if thick else 1
			depth_p := next_mult_u32(mdepth, block[2])
			one := u64(pitch) * u64(rows) * bpe
			slice_size += one
			append(&sizes, one * u64(block[2]))
			append(&mips, Mip{
				width       = tex_dim(desc.width, i, desc.block),
				height      = tex_dim(desc.height, i, desc.block),
				depth       = tex_dim(desc.depth, i, 1) if three_d else 1,
				pitch       = pitch,
				rows        = rows,
				depth_pitch = depth_p if three_d else 1,
				offset      = 0,
				has_tail    = false,
			})
		}

		offset := block_bytes if first_tail_mip < desc.mips else 0
		for i := int(first_tail_mip) - 1; i >= 0; i -= 1 {
			mips[i].offset = offset
			offset += sizes[i]
		}

		micro := [2]u32{BLOCK_256_3D[element_log2][0], BLOCK_256_3D[element_log2][1]} if thick else BLOCK_256_2D[element_log2]
		pitch := tail_max[0]
		rows := tail_max[1]
		for i := first_tail_mip; i < desc.mips; i += 1 {
			m := max_in_tail - 1 - (i - first_tail_mip)
			t_off := (u32(16) << m) if m > 6 else (m << 8)
			x: u32 = 0
			y: u32 = 0
			for b: u32 = 0; b < 6; b += 1 {
				x += ((t_off >> (9 + 2 * b)) & 1) << b
				y += ((t_off >> (8 + 2 * b)) & 1) << b
			}
			if (block_log2 & 1) != 0 {
				x, y = y, x
				if (element_log2 & 1) != 0 {
					y = (y << 1) | (x & 1)
					x >>= 1
				}
			}
			mdepth := padded_dim(desc.depth, i, 1) if thick else 1
			append(&mips, Mip{
				width       = tex_dim(desc.width, i, desc.block),
				height      = tex_dim(desc.height, i, desc.block),
				depth       = tex_dim(desc.depth, i, 1) if three_d else 1,
				pitch       = pitch,
				rows        = rows,
				depth_pitch = next_mult_u32(mdepth, BLOCK_256_3D[element_log2][2]) if thick else 1,
				offset      = 0,
				has_tail    = true,
				tail        = Tail{offset = t_off, x = x * micro[0], y = y * micro[1]},
			})
			pitch = max(pitch >> 1, micro[0])
			rows = max(rows >> 1, micro[1])
		}
	}

	slab := u64(block[2]) if thick else 1
	final_slice_size := slice_size * slab
	final_slices := slices_raw / block[2]
	addressable := !swizzle_xor(desc.swizzle) && desc.samples == 1
	pat: [3][]u32
	if addressable {
		kind := 2 if thick else (1 if swizzle_display(desc.swizzle) else 0)
		pat = build_pattern(kind, element_log2, block_log2, allocator)
	}

	return Layout{
		desc           = desc,
		block          = block,
		thick          = thick,
		slices         = final_slices,
		slice_size     = final_slice_size,
		size           = final_slice_size * u64(final_slices),
		alignment      = block_bytes,
		first_tail_mip = first_tail_mip,
		mips           = mips,
		pattern        = pat,
	}, .None
}

layout_addressable :: proc(l: ^Layout) -> bool {
	return l.desc.swizzle == SWIZZLE_LINEAR || len(l.pattern[0]) > 0
}

@(private)
split_z :: proc(l: ^Layout, z: u32) -> (u32, u32) {
	if l.thick {
		return z / l.block[2], z % l.block[2]
	}
	return z, 0
}

@(private)
row_offset :: #force_inline proc(l: ^Layout, m: ^Mip, y, z: u32) -> u64 {
	bw := l.block[0]
	bh := l.block[1]
	log2 := bits.trailing_zeros(l.alignment)
	yy := y + (m.tail.y if m.has_tail else 0)
	blocks := u64(yy / bh) * u64(m.pitch / bw)
	return (blocks << log2) + u64(l.pattern[1][yy % bh] | l.pattern[2][z])
}

@(private)
col_offset :: #force_inline proc(l: ^Layout, m: ^Mip, x: u32) -> u64 {
	bw := l.block[0]
	log2 := bits.trailing_zeros(l.alignment)
	xx := x + (m.tail.x if m.has_tail else 0)
	return (u64(xx / bw) << log2) + u64(l.pattern[0][xx % bw])
}

layout_offset :: proc(l: ^Layout, mip, x, y, z: u32) -> (u64, Format_Error) {
	if int(mip) >= len(l.mips) {
		return 0, .Invalid
	}
	m := &l.mips[mip]
	depth := m.depth if l.desc.dimension == .Tex3d else l.slices
	inside := x < m.width && y < m.height && z < depth
	if !inside || !layout_addressable(l) {
		return 0, .Unsupported if inside else .Invalid
	}
	slice, iz := split_z(l, z)
	base := u64(slice) * l.slice_size + m.offset
	if l.desc.swizzle == SWIZZLE_LINEAR {
		row := u64(y) * u64(m.pitch) + u64(x)
		return base + row * u64(l.desc.element_bytes), .None
	}
	return base + row_offset(l, m, y, iz) + col_offset(l, m, x), .None
}

@(private)
build_row_runs :: proc(l: ^Layout, m: ^Mip, n, bytes: int, allocator := context.allocator) -> []Row_Run {
	runs := make([dynamic]Row_Run, allocator)
	first_lin := 0
	first_tiled := int(col_offset(l, m, 0))
	for x: u32 = 1; x < m.width; x += 1 {
		off := int(col_offset(l, m, x))
		at := int(x) * n
		if off != first_tiled + (at - first_lin) {
			append(&runs, Row_Run{tiled = first_tiled, linear = first_lin, length = at - first_lin})
			first_tiled = off
			first_lin = at
		}
	}
	append(&runs, Row_Run{tiled = first_tiled, linear = first_lin, length = bytes - first_lin})
	return runs[:]
}

@(private)
copy_runs :: #force_inline proc(
	runs: []Row_Run,
	uniform_len: int,
	tiled_buf: []u8,
	tiled_row: int,
	lin_buf: []u8,
	lin_row: int,
	detile_dir: bool,
) {
	if detile_dir {
		if uniform_len > 0 {
			for r in runs {
				t := tiled_row + r.tiled
				lp := lin_row + r.linear
				copy(lin_buf[lp : lp + uniform_len], tiled_buf[t : t + uniform_len])
			}
		} else {
			for r in runs {
				t := tiled_row + r.tiled
				lp := lin_row + r.linear
				copy(lin_buf[lp : lp + r.length], tiled_buf[t : t + r.length])
			}
		}
	} else {
		if uniform_len > 0 {
			for r in runs {
				t := tiled_row + r.tiled
				lp := lin_row + r.linear
				copy(tiled_buf[t : t + uniform_len], lin_buf[lp : lp + uniform_len])
			}
		} else {
			for r in runs {
				t := tiled_row + r.tiled
				lp := lin_row + r.linear
				copy(tiled_buf[t : t + r.length], lin_buf[lp : lp + r.length])
			}
		}
	}
}

@(private)
Detile_2D_Task :: struct {
	l:          ^Layout,
	m:          ^Mip,
	tiled:      []u8,
	linear:     []u8,
	runs:       []Row_Run,
	uniform_ln: int,
	base:       u64,
	inner:      u32,
	y0, y1:     int,
	row_pitch:  int,
	bytes:      int,
	n:          int,
	is_linear:  bool,
}

@(private)
detile_2d_worker :: proc(t: ^Detile_2D_Task) {
	for y := t.y0; y < t.y1; y += 1 {
		lin_row := y * t.row_pitch
		if t.is_linear {
			t_row := int(t.base + u64(y) * u64(t.m.pitch) * u64(t.n))
			copy(t.linear[lin_row : lin_row + t.bytes], t.tiled[t_row : t_row + t.bytes])
		} else {
			t_row := int(t.base + row_offset(t.l, t.m, u32(y), t.inner))
			copy_runs(t.runs, t.uniform_ln, t.tiled, t_row, t.linear, lin_row, true)
		}
	}
}

@(private)
Tile_Band_Task :: struct {
	l:          ^Layout,
	m:          ^Mip,
	tiled:      []u8,
	linear:     []u8,
	runs:       []Row_Run,
	uniform_ln: int,
	base:       u64,
	inner:      u32,
	y0, y1:     int,
	height:     int,
	row_pitch:  int,
	bytes:      int,
	n:          int,
	is_linear:  bool,
}

@(private)
tile_2d_worker :: proc(t: ^Tile_Band_Task) {
	y1 := min(t.y1, t.height)
	for y := t.y0; y < y1; y += 1 {
		lin_row := y * t.row_pitch
		if t.is_linear {
			t_row := int(t.base + u64(y) * u64(t.m.pitch) * u64(t.n))
			copy(t.tiled[t_row : t_row + t.bytes], t.linear[lin_row : lin_row + t.bytes])
		} else {
			t_row := int(t.base + row_offset(t.l, t.m, u32(y), t.inner))
			copy_runs(t.runs, t.uniform_ln, t.tiled, t_row, t.linear, lin_row, false)
		}
	}
}

@(private)
Volume_Task :: struct {
	l:           ^Layout,
	m:           ^Mip,
	tiled:       []u8,
	linear:      []u8,
	runs:        []Row_Run,
	uniform_ln:  int,
	first:       u32,
	s0, s1:      int,
	slab_depth:  int,
	depth:       int,
	row_pitch:   int,
	depth_pitch: int,
	bytes:       int,
	n:           int,
	is_linear:   bool,
	detile_dir:  bool,
}

@(private)
volume_worker :: proc(t: ^Volume_Task) {
	for s := t.s0; s < t.s1; s += 1 {
		for inner := 0; inner < t.slab_depth; inner += 1 {
			z := s * t.slab_depth + inner
			if z >= t.depth {
				break
			}
			sl, iz := split_z(t.l, t.first + u32(z))
			base := u64(sl) * t.l.slice_size + t.m.offset
			z_lin := z * t.depth_pitch
			for y := 0; y < int(t.m.height); y += 1 {
				lin_row := z_lin + y * t.row_pitch
				if t.is_linear {
					t_row := int(base + u64(y) * u64(t.m.pitch) * u64(t.n))
					if t.detile_dir {
						copy(t.linear[lin_row : lin_row + t.bytes], t.tiled[t_row : t_row + t.bytes])
					} else {
						copy(t.tiled[t_row : t_row + t.bytes], t.linear[lin_row : lin_row + t.bytes])
					}
				} else {
					t_row := int(base + row_offset(t.l, t.m, u32(y), iz))
					copy_runs(t.runs, t.uniform_ln, t.tiled, t_row, t.linear, lin_row, t.detile_dir)
				}
			}
		}
	}
}

@(private)
validate_copy_args :: proc(
	l: ^Layout,
	tiled_len: int,
	mip, slice: u32,
	linear_len, row_pitch, depth_pitch: int,
) -> (m: ^Mip, first: u32, err: Format_Error) {
	if int(mip) >= len(l.mips) {
		return nil, 0, .Invalid
	}
	m = &l.mips[mip]
	if l.desc.dimension == .Tex3d {
		if slice != 0 {
			return nil, 0, .Invalid
		}
		first = 0
	} else {
		first = slice
	}
	if first >= l.slices {
		return nil, 0, .Invalid
	}
	if !layout_addressable(l) {
		return nil, 0, .Unsupported
	}
	n := int(l.desc.element_bytes)
	bytes := int(m.width) * n
	depth := int(m.depth)
	if row_pitch < bytes {
		return nil, 0, .Too_Small
	}
	slice_bytes := (int(m.height) - 1) * row_pitch + bytes
	if depth > 1 && depth_pitch < slice_bytes {
		return nil, 0, .Too_Small
	}
	need := (depth - 1) * depth_pitch + slice_bytes
	if tiled_len < int(l.size) || linear_len < need {
		return nil, 0, .Too_Small
	}
	return m, first, .None
}

@(private)
worker_count :: proc() -> int {
	c := os.get_processor_core_count()
	if c < 2 do return 2
	if c > 8 do return 8
	return c
}

@(private)
uniform_run_length :: proc(runs: []Row_Run) -> int {
	if len(runs) <= 1 {
		return 0
	}
	candidate := runs[0].length
	for i := 1; i < len(runs) - 1; i += 1 {
		if runs[i].length != candidate {
			return 0
		}
	}
	return candidate
}

layout_detile :: proc(
	l: ^Layout,
	tiled: []u8,
	mip, slice: u32,
	linear: []u8,
	row_pitch, depth_pitch: int,
	allocator := context.allocator,
) -> Format_Error {
	m, first, v_err := validate_copy_args(l, len(tiled), mip, slice, len(linear), row_pitch, depth_pitch)
	if v_err != .None {
		return v_err
	}

	n := int(l.desc.element_bytes)
	bytes := int(m.width) * n
	depth := int(m.depth)
	is_linear := l.desc.swizzle == SWIZZLE_LINEAR
	runs: []Row_Run
	if !is_linear {
		runs = build_row_runs(l, m, n, bytes, allocator)
	}
	defer if len(runs) > 0 do delete(runs, allocator)

	// Keep body+tail uniform length fast path for interior runs while safely copying tail run separately
	body := runs[:len(runs) - 1] if len(runs) > 1 else runs[:0]
	last_run := runs[len(runs) - 1:] if len(runs) > 0 else runs[:0]
	u_len := uniform_run_length(runs)
	total_payload := depth * int(m.height) * bytes
	threads := worker_count()

	if !m.has_tail && depth == 1 && m.height >= 64 && total_payload >= (256 << 10) {
		sl, inner := split_z(l, first)
		base := u64(sl) * l.slice_size + m.offset
		height := int(m.height)
		chunk_rows := max(16, (height + threads - 1) / threads)
		num_tasks := (height + chunk_rows - 1) / chunk_rows
		tasks := make([dynamic]Detile_2D_Task, 0, num_tasks, allocator)
		workers := make([dynamic]^thread.Thread, 0, num_tasks, allocator)
		defer {
			delete(tasks)
			delete(workers)
		}
		for c := 0; c < num_tasks; c += 1 {
			y0 := c * chunk_rows
			y1 := min(y0 + chunk_rows, height)
			append(&tasks, Detile_2D_Task{
				l = l, m = m, tiled = tiled, linear = linear,
				runs = body, uniform_ln = u_len,
				base = base, inner = inner, y0 = y0, y1 = y1,
				row_pitch = row_pitch, bytes = bytes, n = n, is_linear = is_linear,
			})
		}
		// Copy last run when u_len is set OR reuse whole slice for non-uniform
		for &tk in tasks {
			tk.runs = runs
			tk.uniform_ln = 0 if len(last_run) > 0 && u_len > 0 else 0
		}
		if u_len > 0 && len(last_run) > 0 {
			// Split into separate uniform body + single tail inside worker via sequential fallback when non-zero tail?
			// Wait: detile_2d_worker copies `runs` cleanly; we can pass full `runs` at u_len=0 or copy body+last.
			// Keep detile_2d_worker simple: pass full `runs` (`u_len = 0` or identical fast path).
		}
		for i := 0; i < len(tasks); i += 1 {
			th := thread.create_and_start_with_poly_data(&tasks[i], detile_2d_worker)
			append(&workers, th)
		}
		for th in workers {
			thread.join(th)
			thread.destroy(th)
		}
		return .None
	}

	if !m.has_tail && depth >= 4 && total_payload >= (256 << 10) {
		slices_per := max(1, (depth + threads - 1) / threads)
		num_tasks := (depth + slices_per - 1) / slices_per
		tasks := make([dynamic]Volume_Task, 0, num_tasks, allocator)
		workers := make([dynamic]^thread.Thread, 0, num_tasks, allocator)
		defer {
			delete(tasks)
			delete(workers)
		}
		for c := 0; c < num_tasks; c += 1 {
			s0 := c * slices_per
			s1 := min(s0 + slices_per, depth)
			append(&tasks, Volume_Task{
				l = l, m = m, tiled = tiled, linear = linear,
				runs = runs, uniform_ln = 0, first = first,
				s0 = s0, s1 = s1, slab_depth = 1, depth = depth,
				row_pitch = row_pitch, depth_pitch = depth_pitch,
				bytes = bytes, n = n, is_linear = is_linear, detile_dir = true,
			})
		}
		for i := 0; i < len(tasks); i += 1 {
			th := thread.create_and_start_with_poly_data(&tasks[i], volume_worker)
			append(&workers, th)
		}
		for th in workers {
			thread.join(th)
			thread.destroy(th)
		}
		return .None
	}

	for z: u32 = 0; z < m.depth; z += 1 {
		sl, inner := split_z(l, first + z)
		base := u64(sl) * l.slice_size + m.offset
		z_lin := int(z) * depth_pitch
		for y: u32 = 0; y < m.height; y += 1 {
			lin_row := z_lin + int(y) * row_pitch
			if is_linear {
				t_row := int(base + u64(y) * u64(m.pitch) * u64(n))
				copy(linear[lin_row : lin_row + bytes], tiled[t_row : t_row + bytes])
			} else {
				t_row := int(base + row_offset(l, m, y, inner))
				copy_runs(body, u_len, tiled, t_row, linear, lin_row, true)
				copy_runs(last_run, 0, tiled, t_row, linear, lin_row, true)
			}
		}
	}
	return .None
}

layout_tile :: proc(
	l: ^Layout,
	tiled: []u8,
	mip, slice: u32,
	linear: []u8,
	row_pitch, depth_pitch: int,
	allocator := context.allocator,
) -> Format_Error {
	m, first, v_err := validate_copy_args(l, len(tiled), mip, slice, len(linear), row_pitch, depth_pitch)
	if v_err != .None {
		return v_err
	}

	n := int(l.desc.element_bytes)
	bytes := int(m.width) * n
	depth := int(m.depth)
	is_linear := l.desc.swizzle == SWIZZLE_LINEAR
	runs: []Row_Run
	if !is_linear {
		runs = build_row_runs(l, m, n, bytes, allocator)
	}
	defer if len(runs) > 0 do delete(runs, allocator)

	body := runs[:len(runs) - 1] if len(runs) > 1 else runs[:0]
	last_run := runs[len(runs) - 1:] if len(runs) > 0 else runs[:0]
	u_len := uniform_run_length(runs)
	total_payload := depth * int(m.height) * bytes
	threads := worker_count()

	if !m.has_tail && total_payload >= (256 << 10) {
		if depth == 1 && m.height >= 64 && !is_linear {
			bh := int(l.block[1])
			bands := (int(m.height) + bh - 1) / bh
			if bands >= 2 {
				sl, inner := split_z(l, first)
				base := u64(sl) * l.slice_size + m.offset
				bands_per := max(1, (bands + threads - 1) / threads)
				num_tasks := (bands + bands_per - 1) / bands_per
				tasks := make([dynamic]Tile_Band_Task, 0, num_tasks, allocator)
				workers := make([dynamic]^thread.Thread, 0, num_tasks, allocator)
				defer {
					delete(tasks)
					delete(workers)
				}
				for c := 0; c < num_tasks; c += 1 {
					b0 := c * bands_per
					b1 := min(b0 + bands_per, bands)
					append(&tasks, Tile_Band_Task{
						l = l, m = m, tiled = tiled, linear = linear,
						runs = runs, uniform_ln = 0,
						base = base, inner = inner,
						y0 = b0 * bh, y1 = b1 * bh, height = int(m.height),
						row_pitch = row_pitch, bytes = bytes, n = n, is_linear = false,
					})
				}
				for i := 0; i < len(tasks); i += 1 {
					th := thread.create_and_start_with_poly_data(&tasks[i], tile_2d_worker)
					append(&workers, th)
				}
				for th in workers {
					thread.join(th)
					thread.destroy(th)
				}
				return .None
			}
		} else if depth >= 4 {
			slab_depth := int(l.block[2]) if l.thick else 1
			slabs := (depth + slab_depth - 1) / slab_depth
			if slabs >= 2 {
				slabs_per := max(1, (slabs + threads - 1) / threads)
				num_tasks := (slabs + slabs_per - 1) / slabs_per
				tasks := make([dynamic]Volume_Task, 0, num_tasks, allocator)
				workers := make([dynamic]^thread.Thread, 0, num_tasks, allocator)
				defer {
					delete(tasks)
					delete(workers)
				}
				for c := 0; c < num_tasks; c += 1 {
					s0 := c * slabs_per
					s1 := min(s0 + slabs_per, slabs)
					append(&tasks, Volume_Task{
						l = l, m = m, tiled = tiled, linear = linear,
						runs = runs, uniform_ln = 0, first = first,
						s0 = s0, s1 = s1, slab_depth = slab_depth, depth = depth,
						row_pitch = row_pitch, depth_pitch = depth_pitch,
						bytes = bytes, n = n, is_linear = is_linear, detile_dir = false,
					})
				}
				for i := 0; i < len(tasks); i += 1 {
					th := thread.create_and_start_with_poly_data(&tasks[i], volume_worker)
					append(&workers, th)
				}
				for th in workers {
					thread.join(th)
					thread.destroy(th)
				}
				return .None
			}
		}
	}

	for z: u32 = 0; z < m.depth; z += 1 {
		sl, inner := split_z(l, first + z)
		base := u64(sl) * l.slice_size + m.offset
		z_lin := int(z) * depth_pitch
		for y: u32 = 0; y < m.height; y += 1 {
			lin_row := z_lin + int(y) * row_pitch
			if is_linear {
				t_row := int(base + u64(y) * u64(m.pitch) * u64(n))
				copy(tiled[t_row : t_row + bytes], linear[lin_row : lin_row + bytes])
			} else {
				t_row := int(base + row_offset(l, m, y, inner))
				copy_runs(body, u_len, tiled, t_row, linear, lin_row, false)
				copy_runs(last_run, 0, tiled, t_row, linear, lin_row, false)
			}
		}
	}
	return .None
}
