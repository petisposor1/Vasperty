package vasperty_formats

import "core:os"
import "core:thread"

BCPACK_MODELS :: 128
BCPACK_BUCKETS :: 9
BCPACK_HISTORY :: 256
BCPACK_DICTIONARY :: 255
BCPACK_LOW :: u32(1) << 24
BCPACK_ROUND_BYTES :: 8

BCPACK_TABLES_SIZE :: BCPACK_MODELS * BCPACK_BUCKETS * 2 +
	256 + 64 + 256 + 64 + 64 +
	512 * 2 +
	BCPACK_DICTIONARY * (6 + 16 + 8 + 32 + 2 + 16 + 4 + 32 + 25 + 33 + 50 + 66)

BCPACK_TABLES_BYTES :: #load("bcpack-tables.bin")

Bcpack_Error :: enum {
	None,
	Invalid_Tables_Size,
	Empty_Bucket,
	Bad_Model_Tiling,
	Unsupported_Format,
	Bad_Dest_Size,
	Truncated_Or_Corrupt,
	Bad_Bc7_Control,
	Bad_Bc6_Mode,
}

Bcpack_Plain :: struct {
	ep: [8]u8,
	ix: [32]u8,
}

Bcpack_Bc6_Ep :: struct {
	e: [4][3]u16,
}

Bcpack_Bc6_Ix :: struct {
	mode: u8,
	ix:   [16]i16,
}

Bcpack_Bc6_Entry :: struct {
	ep: Bcpack_Bc6_Ep,
	ix: Bcpack_Bc6_Ix,
}

Bcpack_Bc7_Ep :: struct {
	ctrl: u16,
	rows: [3][8]u16,
}

Bcpack_Bc7_Ix :: struct {
	bits: [2]u8,
	ix:   [2][16]i16,
}

Bcpack_Bc7_Entry :: struct {
	ep: Bcpack_Bc7_Ep,
	ix: Bcpack_Bc7_Ix,
}

Bcpack_Tables :: struct {
	freq:   [BCPACK_MODELS][BCPACK_BUCKETS]u32,
	start:  [BCPACK_MODELS][BCPACK_BUCKETS + 1]u32,
	bucket: [BCPACK_MODELS][256]u8,
	recip:  [BCPACK_MODELS][BCPACK_BUCKETS]u64,
	rank1:  [256]u8,
	rank3a: [64]u8,
	rank3c: [256]u8,
	rank4:  [64]u8,
	rank5:  [64]u8,
	ctrl7:  [512]u16,
	bc1:    [BCPACK_DICTIONARY]Bcpack_Plain,
	bc3:    [BCPACK_DICTIONARY]Bcpack_Plain,
	bc4:    [BCPACK_DICTIONARY]Bcpack_Plain,
	bc5:    [BCPACK_DICTIONARY]Bcpack_Plain,
	bc6:    [BCPACK_DICTIONARY]Bcpack_Bc6_Entry,
	bc7:    [BCPACK_DICTIONARY]Bcpack_Bc7_Entry,
}

@(private)
Tbl_Reader :: struct {
	data: []u8,
	at:   int,
}

@(private)
tr_u8 :: #force_inline proc(r: ^Tbl_Reader) -> u8 {
	v := r.data[r.at]
	r.at += 1
	return v
}

@(private)
tr_u16 :: #force_inline proc(r: ^Tbl_Reader) -> u16 {
	v := u16(r.data[r.at]) | (u16(r.data[r.at + 1]) << 8)
	r.at += 2
	return v
}

bcpack_destroy_tables :: proc(t: ^Bcpack_Tables, allocator := context.allocator) {
	if t != nil {
		free(t, allocator)
	}
}

bcpack_parse_tables :: proc(raw: []u8, allocator := context.allocator) -> (t: ^Bcpack_Tables, err: Bcpack_Error) {
	if len(raw) != BCPACK_TABLES_SIZE {
		return nil, .Invalid_Tables_Size
	}
	t = new(Bcpack_Tables, allocator)
	r := Tbl_Reader{data = raw, at = 0}

	for m := 0; m < BCPACK_MODELS; m += 1 {
		for b := 0; b < BCPACK_BUCKETS; b += 1 {
			t.freq[m][b] = u32(tr_u16(&r))
		}
		used := m / 16 + 2
		at: u32 = 0
		for b := 0; b < used; b += 1 {
			f := t.freq[m][b]
			if f == 0 {
				free(t, allocator)
				return nil, .Empty_Bucket
			}
			t.start[m][b] = at
			t.recip[m][b] = ((u64(1) << 32) + u64(f) - 1) / u64(f)
			shift := uint(b - 1) if b > 0 else 0
			at += f << shift
		}
		if at != (u32(1) << 16) {
			free(t, allocator)
			return nil, .Bad_Model_Tiling
		}
		for b := used; b < BCPACK_BUCKETS + 1; b += 1 {
			t.start[m][b] = u32(1) << 16
		}
		for w := 0; w < 256; w += 1 {
			first := u32(w) << 8
			cnt: u8 = 0
			for b := 1; b < BCPACK_BUCKETS + 1; b += 1 {
				if t.start[m][b] <= first {
					cnt += 1
				}
			}
			t.bucket[m][w] = cnt
		}
	}

	copy(t.rank1[:], r.data[r.at : r.at + 256]); r.at += 256
	copy(t.rank3a[:], r.data[r.at : r.at + 64]); r.at += 64
	copy(t.rank3c[:], r.data[r.at : r.at + 256]); r.at += 256
	copy(t.rank4[:], r.data[r.at : r.at + 64]); r.at += 64
	copy(t.rank5[:], r.data[r.at : r.at + 64]); r.at += 64
	for c := 0; c < 512; c += 1 {
		t.ctrl7[c] = tr_u16(&r)
	}

	read_plain_dict :: proc(r: ^Tbl_Reader, dst: []Bcpack_Plain, ep_n, ix_n: int) {
		for i := 0; i < len(dst); i += 1 {
			for k := 0; k < ep_n; k += 1 do dst[i].ep[k] = tr_u8(r)
			for k := 0; k < ix_n; k += 1 do dst[i].ix[k] = tr_u8(r)
		}
	}
	read_plain_dict(&r, t.bc1[:], 6, 16)
	read_plain_dict(&r, t.bc3[:], 8, 32)
	read_plain_dict(&r, t.bc4[:], 2, 16)
	read_plain_dict(&r, t.bc5[:], 4, 32)

	for i := 0; i < BCPACK_DICTIONARY; i += 1 {
		_ = tr_u8(&r) // unused endpoint mode
		for k := 0; k < 4; k += 1 {
			for c := 0; c < 3; c += 1 {
				t.bc6[i].ep.e[k][c] = tr_u16(&r)
			}
		}
		t.bc6[i].ix.mode = tr_u8(&r)
		for k := 0; k < 16; k += 1 {
			t.bc6[i].ix.ix[k] = i16(tr_u16(&r))
		}
	}

	for i := 0; i < BCPACK_DICTIONARY; i += 1 {
		t.bc7[i].ep.ctrl = tr_u16(&r)
		for row := 0; row < 3; row += 1 {
			for col := 0; col < 8; col += 1 {
				t.bc7[i].ep.rows[row][col] = tr_u16(&r)
			}
		}
		t.bc7[i].ix.bits[0] = tr_u8(&r)
		t.bc7[i].ix.bits[1] = tr_u8(&r)
		for set := 0; set < 2; set += 1 {
			for p := 0; p < 16; p += 1 {
				t.bc7[i].ix.ix[set][p] = i16(tr_u16(&r))
			}
		}
	}

	return t, .None
}

bcpack_builtin_tables :: proc(allocator := context.allocator) -> (^Bcpack_Tables, Bcpack_Error) {
	return bcpack_parse_tables(BCPACK_TABLES_BYTES, allocator)
}

@(private)
Lane :: struct {
	width:     u8,
	phase:     u8,
	is_long:   bool,
	reset:     bool,
	model:     u8,
	need:      bool,
	has_latch: bool,
	latch:     u8,
	has_out:   bool,
	out:       u8,
	stalled:   bool,
	x:         u32,
	left:      u32,
}

@(private)
bucket_of :: #force_inline proc(t: ^Bcpack_Tables, model: u8, slot: u32) -> int {
	b := int(t.bucket[model][slot >> 8])
	for t.start[model][b + 1] <= slot {
		b += 1
	}
	return b
}

@(private)
lane_step :: #force_inline proc(l: ^Lane, t: ^Bcpack_Tables) {
	if l.phase != 3 {
		if !l.has_latch {
			return
		}
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
		return
	}

	x := l.x
	if x < BCPACK_LOW && l.has_latch {
		l.has_latch = false
		l.left -= 1
		x = (x << 8) | u32(l.latch)
	}
	l.need = l.left != 0 && !l.has_latch
	if x > BCPACK_LOW {
		slot := x & 0xFFFF
		b := bucket_of(t, l.model, slot)
		sym, f, rem: u32
		if b == 0 {
			sym = 0
			f = t.freq[l.model][0] - 1
			rem = slot - 1
		} else {
			offset := slot - t.start[l.model][b]
			q := u32((u64(offset) * t.recip[l.model][b]) >> 32)
			sym = (u32(1) << uint(b - 1)) + q
			f = t.freq[l.model][b]
			rem = offset - q * f
		}
		l.x = (x >> 16) * f + rem
		l.out = u8(sym)
		l.has_out = true
	} else if l.left != 0 {
		l.x = x
	} else {
		l.phase = 0
		l.need = !l.has_latch
		if l.reset {
			l.x = 0
		}
	}
}

bcpack_decode_lanes :: proc(
	t: ^Bcpack_Tables,
	widths: []u8,
	per: int,
	blocks: int,
	src: []u8,
	records: []u8,
) -> Bcpack_Error {
	lanes: [16]Lane
	n_lanes := len(widths)
	for j := 0; j < n_lanes; j += 1 {
		lanes[j].width = widths[j]
		lanes[j].need = true
	}
	stride := n_lanes * per
	full := (u32(1) << uint(n_lanes)) - 1
	pos := 0
	done: u32 = 0
	idle := 0
	at := 0
	src_pos := 0

	for pos < blocks * per {
		taken := 0
		moved := false
		for j := 0; j < n_lanes; j += 1 {
			bit := u32(1) << uint(j)
			before := taken
			l := &lanes[j]
			if !l.stalled {
				lane_step(l, t)
			}
			waiting := l.has_out && (done & bit) != 0
			if l.need && !waiting && taken < BCPACK_ROUND_BYTES {
				if src_pos < len(src) {
					l.latch = src[src_pos]
					l.has_latch = true
					src_pos += 1
					taken += 1
				}
			}
			l.stalled = (l.need && before >= BCPACK_ROUND_BYTES) || waiting
			if !l.stalled && l.has_out {
				records[at + j * per] = l.out
				l.has_out = false
				done |= bit
				moved = true
			}
		}
		if done == full {
			pos += 1
			if pos % per == 0 {
				at += stride - per + 1
			} else {
				at += 1
			}
			done = 0
			moved = true
		}
		idle = 0 if (taken > 0 || moved) else (idle + 1)
		if idle > 3 {
			return .Truncated_Or_Corrupt
		}
	}
	return .None
}

@(private)
SPREAD4 := [16]u8{
	0x00, 0x01, 0x04, 0x05, 0x10, 0x11, 0x14, 0x15,
	0x40, 0x41, 0x44, 0x45, 0x50, 0x51, 0x54, 0x55,
}

bcpack_interleave :: #force_inline proc "contextless" (a, b: u8) -> u8 {
	return SPREAD4[a & 0x0F] | (SPREAD4[b & 0x0F] << 1)
}

@(private)
decode_refs :: #force_inline proc "contextless" (s: []u8, paired: bool) -> (int, int) {
	d, ix: u8
	if paired {
		d = bcpack_interleave(s[0], s[1])
		ix = bcpack_interleave(s[2], s[3])
	} else {
		d = s[0]
		ix = s[1]
	}
	neg_mask := u8(0xFF) if (d & 1) != 0 else 0
	delta := (d >> 1) ~ neg_mask
	return int(ix + delta), int(ix)
}

@(private)
zz_u8 :: #force_inline proc "contextless" (v: u8, bit_count: uint) -> u8 {
	mask := u8((u32(1) << bit_count) - 1)
	flip := mask if (v & 1) != 0 else 0
	return ((v >> 1) ~ flip) & mask
}

@(private)
Plain_Widths :: struct {
	ep:     [8]u8,
	ix:     [32]u8,
	paired: bool,
}

@(private)
BC1_WIDTHS :: Plain_Widths{
	ep = {5, 6, 5, 5, 6, 5, 0, 0},
	ix = {2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
	paired = false,
}

@(private)
BC3_WIDTHS :: Plain_Widths{
	ep = {5, 6, 5, 5, 6, 5, 8, 8},
	ix = {3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2},
	paired = true,
}

@(private)
BC4_WIDTHS :: Plain_Widths{
	ep = {8, 8, 0, 0, 0, 0, 0, 0},
	ix = {3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
	paired = false,
}

@(private)
BC5_WIDTHS :: Plain_Widths{
	ep = {8, 8, 8, 8, 0, 0, 0, 0},
	ix = {3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3},
	paired = true,
}

@(private)
BC1_CODE := [4]u32{0, 2, 3, 1}
@(private)
BC4_CODE := [8]u64{0, 2, 3, 4, 5, 6, 7, 1}

@(private)
decode_quads :: #force_inline proc(rank: ^[256]u8, s: []u8, ix: []u8) {
	pos_tbl := [4]int{0, 1, 4, 5}
	for q := 0; q < len(s); q += 1 {
		v := rank[s[q]]
		base := (q >> 1) * 8 + (q & 1) * 2
		for p, k in pos_tbl {
			ix[base + p] = (v >> uint(2 * k)) & 3
		}
	}
}

@(private)
decode_pairs :: #force_inline proc(rank: ^[64]u8, s: []u8, ix: []u8) {
	for k := 0; k < len(s); k += 1 {
		v := rank[s[k] & 63]
		ix[2 * k] = v & 7
		ix[2 * k + 1] = (v >> 4) & 7
	}
}

@(private)
pack_bc1_color :: proc(ep, ix, out: []u8) {
	c0 := (u16(ep[0]) << 11) | (u16(ep[1]) << 5) | u16(ep[2])
	c1 := (u16(ep[3]) << 11) | (u16(ep[4]) << 5) | u16(ep[5])
	bits: u32 = 0
	for p: uint = 0; p < 16; p += 1 {
		bits |= BC1_CODE[ix[p] & 3] << (2 * p)
	}
	out[0] = u8(c0); out[1] = u8(c0 >> 8)
	out[2] = u8(c1); out[3] = u8(c1 >> 8)
	out[4] = u8(bits); out[5] = u8(bits >> 8)
	out[6] = u8(bits >> 16); out[7] = u8(bits >> 24)
}

@(private)
pack_bc4_alpha :: proc(e0, e1: u8, ix, out: []u8) {
	bits: u64 = 0
	for p: uint = 0; p < 16; p += 1 {
		bits |= BC4_CODE[ix[p] & 7] << (16 + 3 * p)
	}
	v := u64(e0 ~ 0x80) | (u64(e1 ~ 0x80) << 8) | bits
	for b: uint = 0; b < 8; b += 1 {
		out[b] = u8(v >> (8 * b))
	}
}

@(private)
decode_plain :: proc(
	bc: u8,
	t: ^Bcpack_Tables,
	recs: []u8,
	stride: int,
	dst: []u8,
	block_bytes: int,
	blocks: int,
) {
	w := BC1_WIDTHS
	dict := t.bc1[:]
	switch bc {
	case 3:
		w = BC3_WIDTHS
		dict = t.bc3[:]
	case 4:
		w = BC4_WIDTHS
		dict = t.bc4[:]
	case 5:
		w = BC5_WIDTHS
		dict = t.bc5[:]
	}

	history: [BCPACK_HISTORY]Bcpack_Plain
	zero: Bcpack_Plain
	for i := 0; i < blocks; i += 1 {
		s := recs[i * stride : (i + 1) * stride]
		out := dst[i * block_bytes : (i + 1) * block_bytes]
		ep_r, ix_r := decode_refs(s, w.paired)

		ep_ref := &zero
		if ep_r != 0 {
			ep_ref = &history[(i - ep_r) % BCPACK_HISTORY] if ep_r <= i else &dict[ep_r - i - 1]
		}
		ix_ref := &zero
		if ix_r != 0 {
			ix_ref = &history[(i - ix_r) % BCPACK_HISTORY] if ix_r <= i else &dict[ix_r - i - 1]
		}

		v: Bcpack_Plain
		switch bc {
		case 1:
			ep_b := [6]uint{5, 6, 5, 5, 6, 5}
			for b, k in ep_b do v.ep[k] = zz_u8(s[2 + k], b)
			decode_quads(&t.rank1, s[8:12], v.ix[:])
		case 3:
			v.ep = {
				zz_u8(s[14], 5), zz_u8(s[16], 6), zz_u8(s[18], 5),
				zz_u8(s[15], 5), zz_u8(s[17], 6), zz_u8(s[19], 5),
				zz_u8(s[4], 8), zz_u8(s[5], 8),
			}
			decode_pairs(&t.rank3a, s[6:14], v.ix[:16])
			decode_quads(&t.rank3c, s[20:24], v.ix[16:])
		case 4:
			v.ep[0] = zz_u8(s[2], 8)
			v.ep[1] = zz_u8(s[3], 8)
			decode_pairs(&t.rank4, s[4:12], v.ix[:16])
		case 5:
			for k := 0; k < 4; k += 1 do v.ep[k] = zz_u8(s[4 + k], 8)
			decode_pairs(&t.rank5, s[8:24], v.ix[:])
		}

		for k := 0; k < 8; k += 1 {
			bits := w.ep[k]
			if bits > 0 {
				v.ep[k] = (v.ep[k] + ep_ref.ep[k]) & u8((u32(1) << uint(bits)) - 1)
			}
		}
		for k := 0; k < 32; k += 1 {
			bits := w.ix[k]
			if bits > 0 {
				v.ix[k] = (v.ix[k] + ix_ref.ix[k]) & ((u8(1) << uint(bits)) - 1)
			}
		}

		history[i % BCPACK_HISTORY] = v
		switch bc {
		case 1:
			pack_bc1_color(v.ep[:], v.ix[:], out)
		case 3:
			pack_bc4_alpha(v.ep[6], v.ep[7], v.ix[:16], out[:8])
			pack_bc1_color(v.ep[:], v.ix[16:], out[8:])
		case 4:
			pack_bc4_alpha(v.ep[0], v.ep[1], v.ix[:], out)
		case 5:
			pack_bc4_alpha(v.ep[0], v.ep[1], v.ix[:16], out[:8])
			pack_bc4_alpha(v.ep[2], v.ep[3], v.ix[16:], out[8:])
		}
	}
}

@(private)
nibbles :: proc(b: u8, odd_first: bool) -> [2]i16 {
	even_u: u8 = 0
	odd_u: u8 = 0
	for k: uint = 0; k < 4; k += 1 {
		even_u |= ((b >> (2 * k)) & 1) << k
		odd_u |= ((b >> (2 * k + 1)) & 1) << k
	}
	z :: #force_inline proc "contextless" (u: u8) -> i16 {
		return i16(u >> 1) ~ -i16(u & 1)
	}
	ev, od := z(even_u), z(odd_u)
	return {od, ev} if odd_first else {ev, od}
}

@(private)
add_index :: #force_inline proc "contextless" (cur: i16, bits: u8, refv: i16, ref_bits: u8) -> i16 {
	up :: #force_inline proc "contextless" (v: i16, b: u8) -> u16 {
		if b == 0 || b > 16 do return 0
		return u16(v) << uint(16 - b)
	}
	sum := i16(up(cur, bits) + up(refv, ref_bits))
	if bits == 0 do return 0
	return sum >> uint(16 - bits)
}

@(private)
Bits128 :: struct {
	v:  u128,
	at: u32,
}

@(private)
bits_put :: #force_inline proc(w: ^Bits128, value: u64, n: u32) {
	if n > 0 && w.at < 128 {
		mask := (u128(1) << uint(n)) - 1
		w.v |= (u128(value) & mask) << uint(w.at)
	}
	w.at += n
}

@(private)
write_u128_le :: #force_inline proc(out: []u8, v: u128) {
	for i: uint = 0; i < 16; i += 1 {
		out[i] = u8(v >> (8 * i))
	}
}

@(private)
ANCHOR2 := [64]u8{
	15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
	15, 2, 8, 2, 2, 8, 8, 15, 2, 8, 2, 2, 8, 8, 2, 2,
	15, 15, 6, 8, 2, 8, 15, 15, 2, 8, 2, 2, 2, 15, 15, 6,
	6, 2, 6, 8, 15, 15, 2, 2, 15, 15, 15, 15, 15, 2, 2, 15,
}
@(private)
ANCHOR3A := [64]u8{
	3, 3, 15, 15, 8, 3, 15, 15, 8, 8, 6, 6, 6, 5, 3, 3,
	3, 3, 8, 15, 3, 3, 6, 10, 5, 8, 8, 6, 8, 5, 15, 15,
	8, 15, 3, 5, 6, 10, 8, 15, 15, 3, 15, 5, 15, 15, 15, 15,
	3, 15, 5, 5, 5, 8, 5, 10, 5, 10, 8, 13, 15, 12, 3, 3,
}
@(private)
ANCHOR3B := [64]u8{
	15, 8, 8, 3, 15, 15, 3, 8, 15, 15, 15, 15, 15, 15, 15, 8,
	15, 8, 15, 3, 15, 8, 15, 8, 3, 15, 6, 10, 15, 15, 10, 8,
	15, 3, 15, 10, 10, 8, 9, 10, 6, 15, 8, 15, 3, 6, 6, 8,
	15, 3, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 3, 15, 15, 8,
}

@(private)
BC7_BITS := [8][4]u8{
	{4, 4, 4, 0}, {6, 6, 6, 0}, {5, 5, 5, 0}, {7, 7, 7, 0},
	{5, 5, 5, 6}, {7, 7, 7, 8}, {7, 7, 7, 7}, {5, 5, 5, 5},
}
@(private)
BC7_INDEX := [8][2]u8{
	{3, 0}, {3, 0}, {2, 0}, {2, 0},
	{3, 2}, {2, 2}, {4, 0}, {2, 0},
}

@(private)
bc7_has_pbits :: #force_inline proc "contextless" (mode: u16) -> bool {
	return mode == 0 || mode == 1 || mode == 3 || mode == 6 || mode == 7
}

@(private)
bc7_precision :: proc(ctrl: u16) -> [4]u8 {
	mode := ctrl & 7
	rot := int((ctrl >> 3) & 3)
	p := BC7_BITS[mode]
	if rot != 0 {
		p[3], p[rot - 1] = p[rot - 1], p[3]
	} else if bc7_has_pbits(mode) {
		p[0] += 1
	}
	return p
}

@(private)
decode_bc7 :: proc(t: ^Bcpack_Tables, recs: []u8, dst: []u8, blocks: int) -> Bcpack_Error {
	history: [BCPACK_HISTORY]Bcpack_Bc7_Entry
	zero: Bcpack_Bc7_Entry
	set_offsets := [2][4]int{{22, 24, 26, 28}, {12, 14, 16, 20}}

	for i := 0; i < blocks; i += 1 {
		s := recs[i * 32 : (i + 1) * 32]
		out := dst[i * 16 : (i + 1) * 16]
		ep_r, ix_r := decode_refs(s, true)
		ctrl := t.ctrl7[(int(s[31] & 15) << 5) | int(s[30] & 31)]
		if ctrl == 0 {
			return .Bad_Bc7_Control
		}
		mode := int(ctrl & 7)
		subsets := int((ctrl & 0xFF) >> 6)
		prec := bc7_precision(ctrl)
		three := subsets == 3

		or0 :: #force_inline proc(v: u8, t3: bool) -> u8 { return 0 if t3 else v }
		if3 :: #force_inline proc(v: u8, t3: bool) -> u8 { return v if t3 else 0 }
		stored := [3][8]u8{
			{s[4], s[5], s[6], s[7], s[8], s[9], or0(s[10], three), or0(s[11], three)},
			{s[12], s[13], s[14], s[15], s[16], s[17], or0(s[18], three), or0(s[19], three)},
			{s[20], s[21], if3(s[10], three), if3(s[11], three), if3(s[18], three), if3(s[19], three), 0, 0},
		}

		r_ep := &zero.ep
		if ep_r != 0 {
			r_ep = &history[(i - ep_r) % BCPACK_HISTORY].ep if ep_r <= i else &t.bc7[ep_r - i - 1].ep
		}
		ep := Bcpack_Bc7_Ep{ctrl = ctrl}
		common := min(subsets, int((r_ep.ctrl & 0xFF) >> 6))
		columns := 8 if prec[3] > 0 else 6
		for c := 0; c < columns; c += 1 {
			p := prec[c / 2]
			if p == 0 do continue
			mask := u16(0xFFFF) << uint(16 - p)
			for row := 0; row < subsets; row += 1 {
				v := stored[row][c]
				neg := u16(0xFFFF) if (v & 1) != 0 else 0
				res := (u16(v >> 1) ~ neg) << uint(16 - p)
				base_row := row if row < common else 0
				ep.rows[row][c] = (r_ep.rows[base_row][c] & mask) + res
			}
		}

		bits := BC7_INDEX[mode]
		r_ix := &zero.ix
		if ix_r != 0 {
			r_ix = &history[(i - ix_r) % BCPACK_HISTORY].ix if ix_r <= i else &t.bc7[ix_r - i - 1].ix
		}
		ix := Bcpack_Bc7_Ix{bits = bits}
		for set := 0; set < 2; set += 1 {
			if bits[set] == 0 do continue
			for o, k in set_offsets[set] {
				for b := 0; b < 2; b += 1 {
					pair := nibbles(s[o + b], k < 3)
					for v, h in pair {
						p := 4 * k + 2 * b + h
						ix.ix[set][p] = add_index(v, bits[set], r_ix.ix[set][p], r_ix.bits[set])
					}
				}
			}
		}

		history[i % BCPACK_HISTORY] = Bcpack_Bc7_Entry{ep = ep, ix = ix}

		// Pack BC7 block
		part := int((ctrl >> 8) & 63)
		rot := int((ctrl >> 3) & 3)
		w: Bits128
		bits_put(&w, u64(1) << uint(mode), u32(mode) + 1)
		switch mode {
		case 0:
			bits_put(&w, u64(part), 4)
		case 1, 2, 3, 7:
			bits_put(&w, u64(part), 6)
		case 4:
			bits_put(&w, u64(rot), 2)
			bits_put(&w, u64((ctrl >> 5) & 1), 1)
		case 5:
			bits_put(&w, u64(rot), 2)
		}

		ends := 2 * subsets
		order := [4]int{0, 1, 2, 3}
		if rot != 0 {
			order[3], order[rot - 1] = order[rot - 1], order[3]
		}
		for ch in order {
			p := prec[ch]
			if p == 0 do continue
			drop: u32 = 1 if (ch == 0 && bc7_has_pbits(u16(mode))) else 0
			for e := 0; e < ends; e += 1 {
				fld := u64(ep.rows[e / 2][2 * ch + (e % 2)] >> uint(16 - p))
				bits_put(&w, fld >> drop, u32(p) - drop)
			}
		}
		if mode == 1 {
			for row := 0; row < subsets; row += 1 {
				fld := u64(ep.rows[row][0] >> uint(16 - prec[0]))
				bits_put(&w, fld & 1, 1)
			}
		} else if bc7_has_pbits(u16(mode)) {
			for e := 0; e < ends; e += 1 {
				fld := u64(ep.rows[e / 2][e % 2] >> uint(16 - prec[0]))
				bits_put(&w, fld & 1, 1)
			}
		}

		anchors := [3]u8{0, 0, 0}
		n_anc := 1
		if subsets == 2 {
			anchors[1] = ANCHOR2[part]
			n_anc = 2
		} else if subsets == 3 {
			anchors[1] = ANCHOR3A[part]
			anchors[2] = ANCHOR3B[part]
			n_anc = 3
		}
		emit_indices :: proc(w: ^Bits128, ix: ^Bcpack_Bc7_Ix, set: int, anchors: [3]u8, n_anc: int) {
			nb := u32(ix.bits[set])
			for p := 0; p < 16; p += 1 {
				is_anc := false
				for ai := 0; ai < n_anc; ai += 1 {
					if int(anchors[ai]) == p {
						is_anc = true
						break
					}
				}
				bits_put(w, u64(u16(ix.ix[set][p])), nb - (1 if is_anc else 0))
			}
		}
		if mode == 4 {
			emit_indices(&w, &ix, 1, anchors, n_anc)
			emit_indices(&w, &ix, 0, anchors, n_anc)
		} else if mode == 5 {
			emit_indices(&w, &ix, 0, anchors, n_anc)
			emit_indices(&w, &ix, 1, anchors, n_anc)
		} else {
			emit_indices(&w, &ix, 0, anchors, n_anc)
		}
		write_u128_le(out, w.v)
	}
	return .None
}

@(private)
BC6_BITS := [15][4]u8{
	{0, 0, 0, 0},
	{10, 5, 5, 5}, {7, 6, 6, 6}, {11, 5, 4, 4}, {11, 4, 5, 4},
	{11, 4, 4, 5}, {9, 5, 5, 5}, {8, 6, 5, 5}, {8, 5, 6, 5},
	{8, 5, 5, 6}, {6, 6, 6, 6}, {10, 10, 10, 10}, {11, 9, 9, 9},
	{12, 8, 8, 8}, {16, 4, 4, 4},
}

@(private)
BC6_CODE := [15][2]u32{
	{0, 0},
	{0, 2}, {1, 2}, {2, 5}, {6, 5},
	{10, 5}, {14, 5}, {18, 5}, {22, 5},
	{26, 5}, {30, 5}, {3, 5}, {7, 5},
	{11, 5}, {15, 5},
}

@(private)
Bc6_Run :: struct {
	ch:    u8,
	ep:    u8,
	first: u8,
	length: u8,
}

@(private)
r6 :: #force_inline proc "contextless" (ch, ep, first, length: u8) -> Bc6_Run {
	return {ch, ep, first, length}
}

@(private)
BC6_R :: u8(0)
@(private)
BC6_G :: u8(1)
@(private)
BC6_B :: u8(2)
@(private)
BC6_D :: Bc6_Run{3, 0, 0, 5}

@(private)
bc6_layout_for :: proc(mode: u8) -> []Bc6_Run {
	@(static) l1 := [?]Bc6_Run{
		{BC6_G, 2, 4, 1}, {BC6_B, 2, 4, 1}, {BC6_B, 3, 4, 1}, {BC6_R, 0, 0, 10}, {BC6_G, 0, 0, 10}, {BC6_B, 0, 0, 10},
		{BC6_R, 1, 0, 5}, {BC6_G, 3, 4, 1}, {BC6_G, 2, 0, 4}, {BC6_G, 1, 0, 5}, {BC6_B, 3, 0, 1}, {BC6_G, 3, 0, 4},
		{BC6_B, 1, 0, 5}, {BC6_B, 3, 1, 1}, {BC6_B, 2, 0, 4}, {BC6_R, 2, 0, 5}, {BC6_B, 3, 2, 1}, {BC6_R, 3, 0, 5},
		{BC6_B, 3, 3, 1}, BC6_D,
	}
	@(static) l2 := [?]Bc6_Run{
		{BC6_G, 2, 5, 1}, {BC6_G, 3, 4, 1}, {BC6_G, 3, 5, 1}, {BC6_R, 0, 0, 7}, {BC6_B, 3, 0, 1}, {BC6_B, 3, 1, 1},
		{BC6_B, 2, 4, 1}, {BC6_G, 0, 0, 7}, {BC6_B, 2, 5, 1}, {BC6_B, 3, 2, 1}, {BC6_G, 2, 4, 1}, {BC6_B, 0, 0, 7},
		{BC6_B, 3, 3, 1}, {BC6_B, 3, 5, 1}, {BC6_B, 3, 4, 1}, {BC6_R, 1, 0, 6}, {BC6_G, 2, 0, 4}, {BC6_G, 1, 0, 6},
		{BC6_G, 3, 0, 4}, {BC6_B, 1, 0, 6}, {BC6_B, 2, 0, 4}, {BC6_R, 2, 0, 6}, {BC6_R, 3, 0, 6}, BC6_D,
	}
	@(static) l3 := [?]Bc6_Run{
		{BC6_R, 0, 0, 10}, {BC6_G, 0, 0, 10}, {BC6_B, 0, 0, 10}, {BC6_R, 1, 0, 5}, {BC6_R, 0, 10, 1}, {BC6_G, 2, 0, 4},
		{BC6_G, 1, 0, 4}, {BC6_G, 0, 10, 1}, {BC6_B, 3, 0, 1}, {BC6_G, 3, 0, 4}, {BC6_B, 1, 0, 4}, {BC6_B, 0, 10, 1},
		{BC6_B, 3, 1, 1}, {BC6_B, 2, 0, 4}, {BC6_R, 2, 0, 5}, {BC6_B, 3, 2, 1}, {BC6_R, 3, 0, 5}, {BC6_B, 3, 3, 1}, BC6_D,
	}
	@(static) l4 := [?]Bc6_Run{
		{BC6_R, 0, 0, 10}, {BC6_G, 0, 0, 10}, {BC6_B, 0, 0, 10}, {BC6_R, 1, 0, 4}, {BC6_R, 0, 10, 1}, {BC6_G, 3, 4, 1},
		{BC6_G, 2, 0, 4}, {BC6_G, 1, 0, 5}, {BC6_G, 0, 10, 1}, {BC6_G, 3, 0, 4}, {BC6_B, 1, 0, 4}, {BC6_B, 0, 10, 1},
		{BC6_B, 3, 1, 1}, {BC6_B, 2, 0, 4}, {BC6_R, 2, 0, 4}, {BC6_B, 3, 0, 1}, {BC6_B, 3, 2, 1}, {BC6_R, 3, 0, 4},
		{BC6_G, 2, 4, 1}, {BC6_B, 3, 3, 1}, BC6_D,
	}
	@(static) l5 := [?]Bc6_Run{
		{BC6_R, 0, 0, 10}, {BC6_G, 0, 0, 10}, {BC6_B, 0, 0, 10}, {BC6_R, 1, 0, 4}, {BC6_R, 0, 10, 1}, {BC6_B, 2, 4, 1},
		{BC6_G, 2, 0, 4}, {BC6_G, 1, 0, 4}, {BC6_G, 0, 10, 1}, {BC6_B, 3, 0, 1}, {BC6_G, 3, 0, 4}, {BC6_B, 1, 0, 5},
		{BC6_B, 0, 10, 1}, {BC6_B, 2, 0, 4}, {BC6_R, 2, 0, 4}, {BC6_B, 3, 1, 1}, {BC6_B, 3, 2, 1}, {BC6_R, 3, 0, 4},
		{BC6_B, 3, 4, 1}, {BC6_B, 3, 3, 1}, BC6_D,
	}
	@(static) l6 := [?]Bc6_Run{
		{BC6_R, 0, 0, 9}, {BC6_B, 2, 4, 1}, {BC6_G, 0, 0, 9}, {BC6_G, 2, 4, 1}, {BC6_B, 0, 0, 9}, {BC6_B, 3, 4, 1},
		{BC6_R, 1, 0, 5}, {BC6_G, 3, 4, 1}, {BC6_G, 2, 0, 4}, {BC6_G, 1, 0, 5}, {BC6_B, 3, 0, 1}, {BC6_G, 3, 0, 4},
		{BC6_B, 1, 0, 5}, {BC6_B, 3, 1, 1}, {BC6_B, 2, 0, 4}, {BC6_R, 2, 0, 5}, {BC6_B, 3, 2, 1}, {BC6_R, 3, 0, 5},
		{BC6_B, 3, 3, 1}, BC6_D,
	}
	@(static) l7 := [?]Bc6_Run{
		{BC6_R, 0, 0, 8}, {BC6_G, 3, 4, 1}, {BC6_B, 2, 4, 1}, {BC6_G, 0, 0, 8}, {BC6_B, 3, 2, 1}, {BC6_G, 2, 4, 1},
		{BC6_B, 0, 0, 8}, {BC6_B, 3, 3, 1}, {BC6_B, 3, 4, 1}, {BC6_R, 1, 0, 6}, {BC6_G, 2, 0, 4}, {BC6_G, 1, 0, 5},
		{BC6_B, 3, 0, 1}, {BC6_G, 3, 0, 4}, {BC6_B, 1, 0, 5}, {BC6_B, 3, 1, 1}, {BC6_B, 2, 0, 4}, {BC6_R, 2, 0, 6},
		{BC6_R, 3, 0, 6}, BC6_D,
	}
	@(static) l8 := [?]Bc6_Run{
		{BC6_R, 0, 0, 8}, {BC6_B, 3, 0, 1}, {BC6_B, 2, 4, 1}, {BC6_G, 0, 0, 8}, {BC6_G, 2, 5, 1}, {BC6_G, 2, 4, 1},
		{BC6_B, 0, 0, 8}, {BC6_G, 3, 5, 1}, {BC6_B, 3, 4, 1}, {BC6_R, 1, 0, 5}, {BC6_G, 3, 4, 1}, {BC6_G, 2, 0, 4},
		{BC6_G, 1, 0, 6}, {BC6_G, 3, 0, 4}, {BC6_B, 1, 0, 5}, {BC6_B, 3, 1, 1}, {BC6_B, 2, 0, 4}, {BC6_R, 2, 0, 5},
		{BC6_B, 3, 2, 1}, {BC6_R, 3, 0, 5}, {BC6_B, 3, 3, 1}, BC6_D,
	}
	@(static) l9 := [?]Bc6_Run{
		{BC6_R, 0, 0, 8}, {BC6_B, 3, 1, 1}, {BC6_B, 2, 4, 1}, {BC6_G, 0, 0, 8}, {BC6_B, 2, 5, 1}, {BC6_G, 2, 4, 1},
		{BC6_B, 0, 0, 8}, {BC6_B, 3, 5, 1}, {BC6_B, 3, 4, 1}, {BC6_R, 1, 0, 5}, {BC6_G, 3, 4, 1}, {BC6_G, 2, 0, 4},
		{BC6_G, 1, 0, 5}, {BC6_B, 3, 0, 1}, {BC6_G, 3, 0, 4}, {BC6_B, 1, 0, 6}, {BC6_B, 2, 0, 4}, {BC6_R, 2, 0, 5},
		{BC6_B, 3, 2, 1}, {BC6_R, 3, 0, 5}, {BC6_B, 3, 3, 1}, BC6_D,
	}
	@(static) l10 := [?]Bc6_Run{
		{BC6_R, 0, 0, 6}, {BC6_G, 3, 4, 1}, {BC6_B, 3, 0, 1}, {BC6_B, 3, 1, 1}, {BC6_B, 2, 4, 1}, {BC6_G, 0, 0, 6},
		{BC6_G, 2, 5, 1}, {BC6_B, 2, 5, 1}, {BC6_B, 3, 2, 1}, {BC6_G, 2, 4, 1}, {BC6_B, 0, 0, 6}, {BC6_G, 3, 5, 1},
		{BC6_B, 3, 3, 1}, {BC6_B, 3, 5, 1}, {BC6_B, 3, 4, 1}, {BC6_R, 1, 0, 6}, {BC6_G, 2, 0, 4}, {BC6_G, 1, 0, 6},
		{BC6_G, 3, 0, 4}, {BC6_B, 1, 0, 6}, {BC6_B, 2, 0, 4}, {BC6_R, 2, 0, 6}, {BC6_R, 3, 0, 6}, BC6_D,
	}
	@(static) l11 := [?]Bc6_Run{
		{BC6_R, 0, 0, 10}, {BC6_G, 0, 0, 10}, {BC6_B, 0, 0, 10}, {BC6_R, 1, 0, 10}, {BC6_G, 1, 0, 10}, {BC6_B, 1, 0, 10},
	}
	@(static) l12 := [?]Bc6_Run{
		{BC6_R, 0, 0, 10}, {BC6_G, 0, 0, 10}, {BC6_B, 0, 0, 10}, {BC6_R, 1, 0, 9}, {BC6_R, 0, 10, 1}, {BC6_G, 1, 0, 9},
		{BC6_G, 0, 10, 1}, {BC6_B, 1, 0, 9}, {BC6_B, 0, 10, 1},
	}
	@(static) l13 := [?]Bc6_Run{
		{BC6_R, 0, 0, 10}, {BC6_G, 0, 0, 10}, {BC6_B, 0, 0, 10}, {BC6_R, 1, 0, 8}, {BC6_R, 0, 10, 2}, {BC6_G, 1, 0, 8},
		{BC6_G, 0, 10, 2}, {BC6_B, 1, 0, 8}, {BC6_B, 0, 10, 2},
	}
	@(static) l14 := [?]Bc6_Run{
		{BC6_R, 0, 0, 10}, {BC6_G, 0, 0, 10}, {BC6_B, 0, 0, 10}, {BC6_R, 1, 0, 4}, {BC6_R, 0, 10, 6}, {BC6_G, 1, 0, 4},
		{BC6_G, 0, 10, 6}, {BC6_B, 1, 0, 4}, {BC6_B, 0, 10, 6},
	}
	switch mode {
	case 1: return l1[:]
	case 2: return l2[:]
	case 3: return l3[:]
	case 4: return l4[:]
	case 5: return l5[:]
	case 6: return l6[:]
	case 7: return l7[:]
	case 8: return l8[:]
	case 9: return l9[:]
	case 10: return l10[:]
	case 11: return l11[:]
	case 12: return l12[:]
	case 13: return l13[:]
	case 14: return l14[:]
	case: return nil
	}
}

@(private)
bc6_index_bits :: #force_inline proc "contextless" (mode: u8) -> u8 {
	if mode >= 1 && mode <= 10 do return 3
	if mode >= 11 && mode <= 14 do return 4
	return 0
}

@(private)
decode_bc6 :: proc(t: ^Bcpack_Tables, recs: []u8, dst: []u8, blocks: int) -> Bcpack_Error {
	history: [BCPACK_HISTORY]Bcpack_Bc6_Entry
	zero := Bcpack_Bc6_Entry{ix = Bcpack_Bc6_Ix{mode = 11}}

	z16 :: #force_inline proc "contextless" (v: u16) -> u16 {
		neg := u16(0xFFFF) if (v & 1) != 0 else 0
		return (v >> 1) ~ neg
	}
	wide :: proc "contextless" (a, b: u8) -> u16 {
		acc: u16 = 0
		for k: uint = 0; k < 8; k += 1 {
			acc |= (u16((a >> k) & 1) << (2 * k)) | (u16((b >> k) & 1) << (2 * k + 1))
		}
		return acc
	}

	for i := 0; i < blocks; i += 1 {
		s := recs[i * 32 : (i + 1) * 32]
		out := dst[i * 16 : (i + 1) * 16]
		ep_r, ix_r := decode_refs(s, true)
		mode := s[30] + 1
		if mode < 1 || mode > 14 {
			return .Bad_Bc6_Mode
		}
		two := mode < 11
		shift: [4]uint
		for k := 0; k < 4; k += 1 do shift[k] = uint(16 - BC6_BITS[mode][k])

		e0 := [3]u16{z16(wide(s[4], s[5])), z16(wide(s[6], s[7])), z16(wide(s[8], s[9]))}
		e1 := [3]u16{z16(wide(s[10], s[11])), z16(wide(s[12], s[13])), z16(wide(s[14], s[15]))}
		e2 := [3]u16{z16(u16(s[16])), z16(u16(s[18])), z16(u16(s[20]))} if two else e0
		e3 := [3]u16{z16(u16(s[17])), z16(u16(s[19])), z16(u16(s[21]))} if two else e1

		r_ep := &zero.ep
		if ep_r != 0 {
			r_ep = &history[(i - ep_r) % BCPACK_HISTORY].ep if ep_r <= i else &t.bc6[ep_r - i - 1].ep
		}
		ep: Bcpack_Bc6_Ep
		m0 := u16(0xFFFF) << shift[0]
		for c := 0; c < 3; c += 1 {
			ep.e[0][c] = (r_ep.e[0][c] + (e0[c] << shift[0])) & m0
		}
		res_arr := [3][3]u16{e1, e2, e3}
		ep_limit := 3 if two else 1
		for k := 0; k < ep_limit; k += 1 {
			for c := 0; c < 3; c += 1 {
				mc := u16(0xFFFF) << shift[1 + c]
				ep.e[k + 1][c] = (r_ep.e[k + 1][c] + (res_arr[k][c] << shift[1 + c])) & mc
			}
		}
		if !two {
			for c := 0; c < 3; c += 1 {
				ep.e[2][c] = (ep.e[0][c] >> shift[0]) << shift[1]
			}
			ep.e[3] = ep.e[1]
		}

		r_ix := &zero.ix
		if ix_r != 0 {
			r_ix = &history[(i - ix_r) % BCPACK_HISTORY].ix if ix_r <= i else &t.bc6[ix_r - i - 1].ix
		}
		bits := bc6_index_bits(mode)
		ix := Bcpack_Bc6_Ix{mode = mode}
		for k := 0; k < 8; k += 1 {
			pair := nibbles(s[22 + k], k < 6)
			for v, h in pair {
				p := 2 * k + h
				ix.ix[p] = add_index(v, bits, r_ix.ix[p], bc6_index_bits(r_ix.mode))
			}
		}
		history[i % BCPACK_HISTORY] = Bcpack_Bc6_Entry{ep = ep, ix = ix}

		w: Bits128
		bits_put(&w, u64(BC6_CODE[mode][0]), BC6_CODE[mode][1])
		part := s[31] & 31
		for run in bc6_layout_for(mode) {
			if run.ch == 3 {
				bits_put(&w, u64(part), 5)
			} else {
				sh := shift[0] if run.ep == 0 else shift[1 + int(run.ch)]
				fld := u64((ep.e[run.ep][run.ch] ~ 0x8000) >> sh)
				bits_put(&w, fld >> uint(run.first), u32(run.length))
			}
		}
		anchor := int(ANCHOR2[part]) if two else 0
		for v, p in ix.ix {
			is_short := p == 0 || p == anchor
			val := u16(v) + (u16(1) << uint(bits - 1))
			bits_put(&w, u64(val), u32(bits) - (1 if is_short else 0))
		}
		write_u128_le(out, w.v)
	}
	return .None
}

bcpack_decode :: proc(bc: u8, src: []u8, dst: []u8, t: ^Bcpack_Tables, allocator := context.allocator) -> Bcpack_Error {
	block_bytes: int
	per: int
	widths: []u8
	@(static) w1 := [12]u8{7, 7, 4, 5, 4, 4, 5, 4, 7, 7, 7, 7}
	@(static) w3 := [12]u8{3, 3, 7, 5, 5, 5, 5, 4, 5, 4, 7, 7}
	@(static) w4 := [12]u8{7, 7, 7, 7, 5, 5, 5, 5, 5, 5, 5, 5}
	@(static) w5 := [12]u8{3, 3, 7, 7, 5, 5, 5, 5, 5, 5, 5, 5}
	@(static) w6 := [16]u8{3, 3, 7, 7, 7, 4, 4, 4, 5, 5, 5, 7, 7, 7, 7, 4}
	@(static) w7 := [16]u8{3, 3, 7, 7, 7, 7, 7, 6, 6, 4, 5, 7, 7, 7, 7, 4}

	switch bc {
	case 1:
		block_bytes = 8; per = 1; widths = w1[:]
	case 3:
		block_bytes = 16; per = 2; widths = w3[:]
	case 4:
		block_bytes = 8; per = 1; widths = w4[:]
	case 5:
		block_bytes = 16; per = 2; widths = w5[:]
	case 6:
		block_bytes = 16; per = 2; widths = w6[:]
	case 7:
		block_bytes = 16; per = 2; widths = w7[:]
	case:
		return .Unsupported_Format
	}

	if len(dst) == 0 || len(dst) % block_bytes != 0 {
		return .Bad_Dest_Size
	}
	blocks := len(dst) / block_bytes
	stride := len(widths) * per
	records := make([]u8, blocks * stride, allocator)
	defer delete(records, allocator)

	if l_err := bcpack_decode_lanes(t, widths, per, blocks, src, records); l_err != .None {
		return l_err
	}

	switch bc {
	case 1, 3, 4, 5:
		decode_plain(bc, t, records, stride, dst, block_bytes, blocks)
		return .None
	case 6:
		return decode_bc6(t, records, dst, blocks)
	case 7:
		return decode_bc7(t, records, dst, blocks)
	}
	return .Unsupported_Format
}

Bcpack_Batch_Job :: struct {
	bc:  u8,
	src: []u8,
	dst: []u8,
	err: Bcpack_Error,
}

@(private)
Batch_Worker_Task :: struct {
	jobs:   []Bcpack_Batch_Job,
	tables: ^Bcpack_Tables,
}

@(private)
bcpack_batch_worker :: proc(task: ^Batch_Worker_Task) {
	for i := 0; i < len(task.jobs); i += 1 {
		j := &task.jobs[i]
		j.err = bcpack_decode(j.bc, j.src, j.dst, task.tables, context.allocator)
	}
}

bcpack_decode_batch :: proc(jobs: []Bcpack_Batch_Job, t: ^Bcpack_Tables, allocator := context.allocator) -> Bcpack_Error {
	n := len(jobs)
	if n == 0 do return .None
	if n == 1 {
		jobs[0].err = bcpack_decode(jobs[0].bc, jobs[0].src, jobs[0].dst, t, allocator)
		return jobs[0].err
	}

	threads := clamp(os.get_processor_core_count(), 2, 8)
	threads = min(threads, n)
	per_w := (n + threads - 1) / threads
	num_tasks := (n + per_w - 1) / per_w

	tasks := make([dynamic]Batch_Worker_Task, 0, num_tasks, allocator)
	workers := make([dynamic]^thread.Thread, 0, num_tasks, allocator)
	defer {
		delete(tasks)
		delete(workers)
	}

	for c := 0; c < num_tasks; c += 1 {
		start := c * per_w
		end := min(start + per_w, n)
		append(&tasks, Batch_Worker_Task{jobs = jobs[start:end], tables = t})
	}
	for i := 0; i < len(tasks); i += 1 {
		append(&workers, thread.create_and_start_with_poly_data(&tasks[i], bcpack_batch_worker, init_context = context))
	}
	for th in workers {
		thread.join(th)
		thread.destroy(th)
	}
	for &j in jobs {
		if j.err != .None {
			return j.err
		}
	}
	return .None
}
