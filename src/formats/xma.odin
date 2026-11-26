package vasperty_formats

import "core:math"
import "core:math/bits"

XMA_PACKET_BYTES :: 2048
XMA_PACKET_BITS :: XMA_PACKET_BYTES * 8
XMA_HEADER_BITS :: 32
XMA_FRAME_SAMPLES :: 512
XMA_SUBFRAME_SAMPLES :: 128
XMA_LENGTH_BITS :: 15
XMA_MIN_SUBFRAME :: XMA_SUBFRAME_SAMPLES
XMA_BLOCK_SIZES :: 3
XMA_MAX_BANDS :: 29
XMA_MAX_SUBFRAMES :: 32

Xma_Error :: enum {
	None,
	Frame_Overread,
	Subframe_Length,
	Too_Many_Subframes,
	Channel_Overflow,
	Bad_Tile_Header,
	Channel_Transform,
	Vector_Coeffs,
	Run_Level_Coeffs,
	Scale_Factor_Run,
	No_Channel_In_Subframe,
	Reserved_Bit,
	Vector_Coeff_Count,
	Subframe_Overrun,
	Subframe_Overread,
}

Xma_Packet :: struct {
	frames:          u32,
	first_frame_bit: u32,
	skip:            u32,
}

xma_packet :: proc(data: []u8, index: int) -> (Xma_Packet, bool) {
	if index < 0 || index > len(data) / XMA_PACKET_BYTES {
		return {}, false
	}
	start := index * XMA_PACKET_BYTES
	if start + 4 > len(data) {
		return {}, false
	}
	h := (u32(data[start]) << 24) |
		(u32(data[start + 1]) << 16) |
		(u32(data[start + 2]) << 8) |
		u32(data[start + 3])
	return Xma_Packet{
		frames          = h >> 26,
		first_frame_bit = (h >> 11) & 0x7FFF,
		skip            = h & 0xFF,
	}, true
}

Xma_Frame :: struct {
	data:     []u8,
	bits:     int,
	start:    int,
	has_next: bool,
	next:     int,
}

destroy_xma_frame :: proc(f: ^Xma_Frame, allocator := context.allocator) {
	if len(f.data) > 0 {
		delete(f.data, allocator)
	}
	f^ = {}
}

Xma_Cursor :: struct {
	data: []u8,
	pos:  int,
}

xma_cursor_bit :: proc(c: ^Xma_Cursor) -> (u32, bool) {
	if c.pos % XMA_PACKET_BITS == 0 {
		prev := c.pos / XMA_PACKET_BITS
		if prev > 0 {
			pkt, ok_p := xma_packet(c.data, prev - 1)
			if !ok_p do return 0, false
			c.pos = (prev + int(pkt.skip)) * XMA_PACKET_BITS
		}
		c.pos += XMA_HEADER_BITS
	}
	byte_idx := c.pos / 8
	if byte_idx >= len(c.data) {
		return 0, false
	}
	bit := (c.data[byte_idx] >> uint(7 - (c.pos % 8))) & 1
	c.pos += 1
	return u32(bit), true
}

xma_cursor_bits :: #force_inline proc(c: ^Xma_Cursor, n: u32) -> (u32, bool) {
	if n == 0 do return 0, true
	in_pkt := c.pos % XMA_PACKET_BITS
	if n <= 24 && in_pkt >= XMA_HEADER_BITS && XMA_PACKET_BITS - in_pkt >= int(n) {
		at := c.pos / 8
		shift := u32(c.pos & 7)
		need_bytes := int((shift + n + 7) / 8)
		if at < len(c.data) && len(c.data) - at >= need_bytes {
			raw := u32(c.data[at]) << 24
			if len(c.data) - at > 1 do raw |= u32(c.data[at + 1]) << 16
			if len(c.data) - at > 2 do raw |= u32(c.data[at + 2]) << 8
			if len(c.data) - at > 3 do raw |= u32(c.data[at + 3])
			if shift + n <= 32 {
				c.pos += int(n)
				return (raw << shift) >> (32 - n), true
			}
		}
	}
	val: u32 = 0
	for _ in 0 ..< n {
		b, ok := xma_cursor_bit(c)
		if !ok do return 0, false
		val = (val << 1) | b
	}
	return val, true
}

xma_cursor_byte :: proc(c: ^Xma_Cursor) -> (u8, bool) {
	in_pkt := c.pos % XMA_PACKET_BITS
	if in_pkt == 0 || in_pkt > XMA_PACKET_BITS - 8 {
		v, ok := xma_cursor_bits(c, 8)
		return u8(v), ok
	}
	at := c.pos / 8
	if at >= len(c.data) do return 0, false
	shift := uint(c.pos % 8)
	first := c.data[at]
	b: u8
	if shift == 0 {
		b = first
	} else {
		if at + 1 >= len(c.data) do return 0, false
		b = (first << shift) | (c.data[at + 1] >> (8 - shift))
	}
	c.pos += 8
	return b, true
}

@(private)
next_frame_offset :: proc(data: []u8, start, end_in: int) -> (int, bool) {
	index := start / XMA_PACKET_BITS
	hdr, ok_h := xma_packet(data, index)
	if !ok_h do return 0, false
	at := index * XMA_PACKET_BITS + XMA_HEADER_BITS + int(hdr.first_frame_bit)
	num := 0
	for at < start {
		cur := Xma_Cursor{data = data, pos = at}
		bits_n, ok_b := xma_cursor_bits(&cur, XMA_LENGTH_BITS)
		if !ok_b || int(bits_n) <= XMA_LENGTH_BITS {
			return 0, false
		}
		at += int(bits_n)
		num += 1
	}
	last := u32(num + 1) >= hdr.frames
	end := end_in
	ends_without := false
	if end / XMA_PACKET_BITS != index && end % XMA_PACKET_BITS != 0 {
		ep, ok_e := xma_packet(data, end / XMA_PACKET_BITS)
		if !ok_e do return 0, false
		ends_without = ep.frames == 0
	}
	if end % XMA_PACKET_BITS == 0 || (last && end / XMA_PACKET_BITS == index) || ends_without {
		p_idx := (end - 1) / XMA_PACKET_BITS
		p_hdr, ok_ph := xma_packet(data, p_idx)
		if !ok_ph do return 0, false
		nxt := p_idx + 1 + int(p_hdr.skip)
		nh, ok_nh := xma_packet(data, nxt)
		if !ok_nh do return 0, false
		for nh.frames == 0 {
			nxt += 1 + int(nh.skip)
			nh, ok_nh = xma_packet(data, nxt)
			if !ok_nh do return 0, false
		}
		end = nxt * XMA_PACKET_BITS + XMA_HEADER_BITS + int(nh.first_frame_bit)
	}
	if end / 8 >= len(data) {
		return 0, false
	}
	return end, true
}

xma_read_frame :: proc(data: []u8, start: int, allocator := context.allocator) -> (frame: Xma_Frame, ok: bool) {
	c0 := Xma_Cursor{data = data, pos = start}
	len_bits, ok_l := xma_cursor_bits(&c0, XMA_LENGTH_BITS)
	if !ok_l || int(len_bits) <= XMA_LENGTH_BITS || len_bits == 0x7FFF {
		return frame, false
	}
	nbits := int(len_bits)
	out := make([dynamic]u8, 0, (nbits + 7) / 8, allocator)
	c := Xma_Cursor{data = data, pos = start}
	for _ in 0 ..< (nbits / 8) {
		b, ok_b := xma_cursor_byte(&c)
		if !ok_b {
			delete(out)
			return frame, false
		}
		append(&out, b)
	}
	tail := u32(nbits % 8)
	if tail != 0 {
		v, ok_t := xma_cursor_bits(&c, tail)
		if !ok_t {
			delete(out)
			return frame, false
		}
		append(&out, u8(v << (8 - tail)))
	}
	end_pos := c.pos
	nxt, has_nxt := next_frame_offset(data, start, end_pos)
	return Xma_Frame{
		data     = out[:],
		bits     = nbits,
		start    = start,
		has_next = has_nxt,
		next     = nxt,
	}, true
}

@(private)
Xma_Bits :: struct {
	data: []u8,
	pos:  int,
	end:  int,
}

@(private)
xb_peek32 :: #force_inline proc(b: ^Xma_Bits) -> u32 {
	v: u64 = 0
	by := b.pos / 8
	for i := 0; i < 5; i += 1 {
		byte_v: u64 = u64(b.data[by + i]) if (by + i < len(b.data)) else 0
		v = (v << 8) | byte_v
	}
	return u32((v << uint(24 + (b.pos % 8))) >> 32)
}

@(private)
xb_read :: #force_inline proc(b: ^Xma_Bits, n: u32) -> u32 {
	if n == 0 do return 0
	v := xb_peek32(b) >> (32 - n)
	b.pos += int(n)
	return v
}

@(private)
xb_bit :: #force_inline proc(b: ^Xma_Bits) -> bool {
	return xb_read(b, 1) != 0
}

@(private)
xb_signed :: #force_inline proc(b: ^Xma_Bits, n: u32) -> i32 {
	return (i32(xb_read(b, n) << (32 - n))) >> (32 - n)
}

@(private)
xb_overread :: #force_inline proc(b: ^Xma_Bits) -> bool {
	return b.pos > b.end
}

@(private)
Vlc_Entry :: struct {
	code:   u32,
	len:    u8,
	symbol: i32,
}

@(private)
Vlc_Table :: struct {
	entries: [272]Vlc_Entry,
	count:   int,
}

@(private)
vlc_from_pairs :: proc(pairs: []XMA_Vlc_Pair, offset: i32) -> Vlc_Table {
	t: Vlc_Table
	code: u64 = 0
	t.count = len(pairs)
	for p, i in pairs {
		t.entries[i] = Vlc_Entry{
			code   = u32(code),
			len    = p.len,
			symbol = i32(p.sym) + offset,
		}
		code += u64(1) << uint(32 - p.len)
	}
	return t
}

@(private)
vlc_from_split :: proc(syms: []u16, lens: []u8, offset: i32) -> Vlc_Table {
	t: Vlc_Table
	code: u64 = 0
	t.count = len(syms)
	for i := 0; i < len(syms); i += 1 {
		l := lens[i]
		t.entries[i] = Vlc_Entry{
			code   = u32(code),
			len    = l,
			symbol = i32(syms[i]) + offset,
		}
		code += u64(1) << uint(32 - l)
	}
	return t
}

@(private)
vlc_read :: #force_inline proc(t: ^Vlc_Table, b: ^Xma_Bits) -> i32 {
	v := xb_peek32(b)
	lo := 0
	hi := t.count
	for lo < hi {
		mid := lo + (hi - lo) / 2
		if t.entries[mid].code <= v {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	idx := max(0, lo - 1)
	e := t.entries[idx]
	b.pos += int(e.len)
	return e.symbol
}

@(private)
large_value :: proc(b: ^Xma_Bits) -> u32 {
	n: u32 = 8
	if xb_bit(b) {
		n += 8
		if xb_bit(b) {
			n += 8
			if xb_bit(b) {
				n += 7
			}
		}
	}
	return xb_read(b, n)
}

@(private)
xma_log2 :: #force_inline proc "contextless" (v: int) -> u32 {
	x := uint(max(1, v))
	return u32(63 - bits.count_leading_zeros(u64(x)))
}

Xma_Rotations :: struct {
	m:          int,
	pre_re:     [256]f64,
	pre_im:     [256]f64,
	post_re:    [256]f64,
	post_im:    [256]f64,
	reversed:   [256]u16,
	twiddle_re: [256]f64,
	twiddle_im: [256]f64,
}

xma_init_rotations :: proc(r: ^Xma_Rotations, n: int) {
	m := n / 2
	r.m = m
	for k := 0; k < m; k += 1 {
		ang := -math.PI * f64(k) / f64(n)
		r.pre_re[k] = math.cos(ang)
		r.pre_im[k] = math.sin(ang)

		ang2 := -math.PI * f64(4 * k + 1) / f64(4 * n)
		r.post_re[k] = math.cos(ang2)
		r.post_im[k] = math.sin(ang2)

		r.reversed[k] = u16(k)
	}
	j := 0
	for i := 1; i < m; i += 1 {
		bit := m >> 1
		for (j & bit) != 0 {
			j ~= bit
			bit >>= 1
		}
		j |= bit
		if i < j {
			r.reversed[i], r.reversed[j] = r.reversed[j], r.reversed[i]
		}
	}
	length := 2
	tw_at := 0
	for length <= m {
		ang := -2.0 * math.PI / f64(length)
		wc := math.cos(ang)
		ws := math.sin(ang)
		cr, ci := 1.0, 0.0
		half := length / 2
		for _ in 0 ..< half {
			r.twiddle_re[tw_at] = cr
			r.twiddle_im[tw_at] = ci
			tw_at += 1
			cr, ci = cr * wc - ci * ws, cr * ws + ci * wc
		}
		length <<= 1
	}
}

xma_imdct_with_rotations :: proc(r: ^Xma_Rotations, input: []f32, out: []f32, scale: f32) {
	n := len(input)
	m := n / 2
	re: [256]f64
	im: [256]f64
	for k := 0; k < m; k += 1 {
		a := f64(input[2 * k])
		b := f64(input[n - 1 - 2 * k])
		c := r.pre_re[k]
		s := r.pre_im[k]
		to := int(r.reversed[k])
		re[to] = a * c - b * s
		im[to] = a * s + b * c
	}
	length := 2
	for length <= m {
		half := length / 2
		tw_base := half - 1
		for start := 0; start < m; start += length {
			for k := 0; k < half; k += 1 {
				ia := start + k
				ib := ia + half
				cr := r.twiddle_re[tw_base + k]
				ci := r.twiddle_im[tw_base + k]
				tr := re[ib] * cr - im[ib] * ci
				ti := re[ib] * ci + im[ib] * cr
				re[ib] = re[ia] - tr
				im[ib] = im[ia] - ti
				re[ia] = re[ia] + tr
				im[ia] = im[ia] + ti
			}
		}
		length <<= 1
	}
	for k := 0; k < m; k += 1 {
		c := r.post_re[k]
		s := r.post_im[k]
		wr := re[k] * c - im[k] * s
		wi := re[k] * s + im[k] * c
		out[n - 1 - 2 * k] = f32(wr) * scale
		out[2 * k] = -f32(wi) * scale
	}
}

xma_window_overlap :: proc(block: []f32, window: []f32) {
	half := len(block) / 2
	for k := 0; k < half; k += 1 {
		j := 2 * half - 1 - k
		s0 := block[k]
		s1 := block[j]
		wi := window[k]
		wj := window[j]
		block[k] = s0 * wj - s1 * wi
		block[j] = s0 * wi + s1 * wj
	}
}

XMA_QUANT_MIN :: -128
XMA_QUANT_LEN :: 321

Xma_Runtime :: struct {
	scale_vlc:    Vlc_Table,
	scale_rl_vlc: Vlc_Table,
	coef_vlc:     [2]Vlc_Table,
	vec4_vlc:     Vlc_Table,
	vec2_vlc:     Vlc_Table,
	vec1_vlc:     Vlc_Table,
	rotations:    [3]Xma_Rotations,
	win_128:      [128]f32,
	win_256:      [256]f32,
	win_512:      [512]f32,
	quant_lut:    [XMA_QUANT_LEN]f32,
}

xma_quant_scale_compute :: #force_inline proc(exp: i32) -> f32 {
	return math.pow(f32(10.0), f32(exp) / 20.0)
}

@(private)
init_runtime :: proc(rt: ^Xma_Runtime) {
	rt.scale_vlc = vlc_from_pairs(XMA_SCALE[:], -60)
	rt.scale_rl_vlc = vlc_from_pairs(XMA_SCALE_RL[:], 0)
	rt.coef_vlc[0] = vlc_from_split(XMA_COEF0_SYMS[:], XMA_COEF0_LENS[:], 0)
	rt.coef_vlc[1] = vlc_from_pairs(XMA_COEF1[:], 0)
	rt.vec4_vlc = vlc_from_split(XMA_VEC4_SYMS[:], XMA_VEC4_LENS[:], -1)
	rt.vec2_vlc = vlc_from_pairs(XMA_VEC2[:], -1)
	rt.vec1_vlc = vlc_from_pairs(XMA_VEC1[:], 0)

	xma_init_rotations(&rt.rotations[0], 128)
	xma_init_rotations(&rt.rotations[1], 256)
	xma_init_rotations(&rt.rotations[2], 512)

	for i := 0; i < 128; i += 1 {
		rt.win_128[i] = f32(math.sin((f64(i) + 0.5) * math.PI / 256.0))
	}
	for i := 0; i < 256; i += 1 {
		rt.win_256[i] = f32(math.sin((f64(i) + 0.5) * math.PI / 512.0))
	}
	for i := 0; i < 512; i += 1 {
		rt.win_512[i] = f32(math.sin((f64(i) + 0.5) * math.PI / 1024.0))
	}
	for i := 0; i < XMA_QUANT_LEN; i += 1 {
		rt.quant_lut[i] = xma_quant_scale_compute(i32(i + XMA_QUANT_MIN))
	}
}

xma_quant_scale :: #force_inline proc(rt: ^Xma_Runtime, exp: i32) -> f32 {
	idx := exp - XMA_QUANT_MIN
	if idx >= 0 && idx < XMA_QUANT_LEN {
		return rt.quant_lut[idx]
	}
	return xma_quant_scale_compute(exp)
}

@(private)
Xma_Channel :: struct {
	prev_block_len:      int,
	transmit_coefs:      bool,
	num_subframes:       int,
	subframe_len:        [XMA_MAX_SUBFRAMES]int,
	cur_subframe:        int,
	decoded_samples:     int,
	quant_step:          i32,
	reuse_sf:            bool,
	scale_factor_step:   i32,
	max_scale_factor:    i32,
	saved_scale_factors: [2][XMA_MAX_BANDS]i32,
	scale_factor_idx:    int,
	scale_factors:       int,
	table_idx:           int,
	num_vec_coeffs:      int,
	coeffs:              [XMA_FRAME_SAMPLES]f32,
	out:                 [XMA_FRAME_SAMPLES + XMA_FRAME_SAMPLES / 2]f32,
}

Xma_Decoder :: struct {
	rt:                        ^Xma_Runtime,
	channels:                  int,
	num_sfb:                   [XMA_BLOCK_SIZES]int,
	sfb_offsets:               [XMA_BLOCK_SIZES][XMA_MAX_BANDS + 1]int,
	sf_offsets:                [XMA_BLOCK_SIZES][XMA_BLOCK_SIZES][XMA_MAX_BANDS]int,
	ch:                        [2]Xma_Channel,
	subframe_len:              int,
	channels_for_cur_subframe: int,
	channel_indexes:           [2]int,
	num_bands:                 int,
	table_idx:                 int,
	esc_len:                   u32,
	transmit_num_vec_coeffs:   bool,
	transform:                 bool,
	transform_band:            [XMA_MAX_BANDS]bool,
	parsed_all_subframes:      bool,
}

@(private)
xma_reset_channel :: proc(c: ^Xma_Channel) {
	c^ = {}
	c.prev_block_len = XMA_FRAME_SAMPLES
	c.scale_factor_step = 1
}

xma_new_decoder :: proc(channels: int, sample_rate: u32, allocator := context.allocator) -> ^Xma_Decoder {
	d := new(Xma_Decoder, allocator)
	d.rt = new(Xma_Runtime, allocator)
	init_runtime(d.rt)

	ch_cnt := clamp(channels, 1, 2)
	d.channels = ch_cnt
	rate := 24_000
	if sample_rate > 44_100 {
		rate = 48_000
	} else if sample_rate > 32_000 {
		rate = 44_100
	} else if sample_rate > 24_000 {
		rate = 32_000
	}

	for i := 0; i < XMA_BLOCK_SIZES; i += 1 {
		sfl := XMA_FRAME_SAMPLES >> uint(i)
		band := 1
		for f_idx := 0; f_idx < XMA_MAX_BANDS - 1 && f_idx < len(XMA_CRITICAL_FREQ); f_idx += 1 {
			if d.sfb_offsets[i][band - 1] >= sfl do break
			off := ((sfl * 2 * int(XMA_CRITICAL_FREQ[f_idx])) / rate + 2) & ~int(3)
			if off > d.sfb_offsets[i][band - 1] {
				d.sfb_offsets[i][band] = off
				band += 1
			}
			if off >= sfl do break
		}
		d.sfb_offsets[i][band - 1] = sfl
		d.num_sfb[i] = band - 1
	}

	for i := 0; i < XMA_BLOCK_SIZES; i += 1 {
		for b := 0; b < d.num_sfb[i]; b += 1 {
			off := ((d.sfb_offsets[i][b] + d.sfb_offsets[i][b + 1] - 1) << uint(i)) >> 1
			for x := 0; x < XMA_BLOCK_SIZES; x += 1 {
				v := 0
				for v + 1 < XMA_MAX_BANDS && (d.sfb_offsets[x][v + 1] << uint(x)) < off {
					v += 1
				}
				d.sf_offsets[i][x][b] = v
			}
		}
	}

	d.channel_indexes = {0, 1}
	d.subframe_len = XMA_FRAME_SAMPLES
	xma_decoder_reset(d)
	return d
}

xma_destroy_decoder :: proc(d: ^Xma_Decoder, allocator := context.allocator) {
	if d != nil {
		if d.rt != nil {
			free(d.rt, allocator)
		}
		free(d, allocator)
	}
}

xma_decoder_reset :: proc(d: ^Xma_Decoder) {
	xma_reset_channel(&d.ch[0])
	xma_reset_channel(&d.ch[1])
}

@(private)
xma_to_i16 :: #force_inline proc(v: f32) -> i16 {
	scaled := math.round(v * 32768.0)
	if scaled < -32768.0 do return -32768
	if scaled > 32767.0 do return 32767
	return i16(scaled)
}

@(private)
xma_subframe_length :: proc(b: ^Xma_Bits, offset: int) -> (int, Xma_Error) {
	if offset == XMA_FRAME_SAMPLES - XMA_MIN_SUBFRAME {
		return XMA_MIN_SUBFRAME, .None
	}
	shift := (1 + xb_read(b, 1)) if xb_bit(b) else 0
	length := XMA_FRAME_SAMPLES >> shift
	if length < XMA_MIN_SUBFRAME {
		return 0, .Subframe_Length
	}
	return length, .None
}

@(private)
xma_tile_header :: proc(d: ^Xma_Decoder, b: ^Xma_Bits) -> Xma_Error {
	num_samples: [2]int
	contains: [2]bool
	ch_for_sub := d.channels
	min_ch_len := 0
	for c := 0; c < d.channels; c += 1 {
		d.ch[c].num_subframes = 0
	}
	fixed := xb_bit(b)
	for {
		for c := 0; c < d.channels; c += 1 {
			contains[c] = num_samples[c] == min_ch_len &&
				(fixed || ch_for_sub == 1 || min_ch_len == XMA_FRAME_SAMPLES - XMA_MIN_SUBFRAME || xb_bit(b))
		}
		sfl, err := xma_subframe_length(b, min_ch_len)
		if err != .None do return err
		min_ch_len += sfl
		for c := 0; c < d.channels; c += 1 {
			ch := &d.ch[c]
			if contains[c] {
				if ch.num_subframes >= XMA_MAX_SUBFRAMES do return .Too_Many_Subframes
				ch.subframe_len[ch.num_subframes] = sfl
				num_samples[c] += sfl
				ch.num_subframes += 1
				if num_samples[c] > XMA_FRAME_SAMPLES do return .Channel_Overflow
			} else if num_samples[c] <= min_ch_len {
				if num_samples[c] < min_ch_len {
					ch_for_sub = 0
					min_ch_len = num_samples[c]
				}
				ch_for_sub += 1
			}
		}
		if min_ch_len >= XMA_FRAME_SAMPLES || xb_overread(b) {
			break
		}
	}
	if xb_overread(b) do return .Bad_Tile_Header
	return .None
}

@(private)
xma_channel_transform :: proc(d: ^Xma_Decoder, b: ^Xma_Bits) -> Xma_Error {
	d.transform = false
	if d.channels == 1 do return .None
	if xb_bit(b) do return .Channel_Transform
	if d.channels_for_cur_subframe == 2 {
		if xb_bit(b) {
			if xb_bit(b) do return .Channel_Transform
		} else {
			d.transform = true
		}
	}
	if d.transform {
		if !xb_bit(b) {
			for i := 0; i < d.num_bands; i += 1 {
				d.transform_band[i] = xb_bit(b)
			}
		} else {
			for i := 0; i < XMA_MAX_BANDS; i += 1 {
				d.transform_band[i] = true
			}
		}
	}
	return .None
}

@(private)
xma_coefficients :: proc(d: ^Xma_Decoder, b: ^Xma_Bits, c: int) -> Xma_Error {
	rt := d.rt
	tbl := 1 if xb_bit(b) else 0
	run_tbl := XMA_COEF1_RUN[:] if tbl == 1 else XMA_COEF0_RUN[:]
	lvl_tbl := XMA_COEF1_LEVEL[:] if tbl == 1 else XMA_COEF0_LEVEL[:]
	sfl := d.subframe_len
	ch := &d.ch[c]
	rl_mode := false
	cur := 0
	num_zeros := 0

	for (d.transmit_num_vec_coeffs || !rl_mode) && cur + 3 < ch.num_vec_coeffs {
		vals: [4]u32
		idx := vlc_read(&rt.vec4_vlc, b)
		if idx < 0 {
			for i := 0; i < 4; i += 2 {
				idx2 := vlc_read(&rt.vec2_vlc, b)
				if idx2 < 0 {
					for k := 0; k < 2; k += 1 {
						x := u32(vlc_read(&rt.vec1_vlc, b))
						if int(x) == len(XMA_VEC1) - 1 {
							x += large_value(b)
						}
						vals[i + k] = x
					}
				} else {
					vals[i] = u32(idx2 >> 4)
					vals[i + 1] = u32(idx2 & 0xF)
				}
			}
		} else {
			vals = {
				u32(idx >> 12),
				u32((idx >> 8) & 0xF),
				u32((idx >> 4) & 0xF),
				u32(idx & 0xF),
			}
		}
		for v in vals {
			if v != 0 {
				neg := !xb_bit(b)
				ch.coeffs[cur] = -f32(v) if neg else f32(v)
				num_zeros = 0
			} else {
				ch.coeffs[cur] = 0.0
				num_zeros += 1
				if num_zeros > (sfl >> 8) {
					rl_mode = true
				}
			}
			cur += 1
		}
		if xb_overread(b) do return .Vector_Coeffs
	}

	if cur < sfl {
		for i := cur; i < sfl; i += 1 do ch.coeffs[i] = 0.0
		mask := sfl - 1
		offset := cur
		for offset < sfl {
			code := vlc_read(&rt.coef_vlc[tbl], b)
			if code > 1 {
				offset += int(run_tbl[code])
				neg := !xb_bit(b)
				v := lvl_tbl[code]
				ch.coeffs[offset & mask] = -v if neg else v
			} else if code == 1 {
				break
			} else {
				val := i32(large_value(b))
				if xb_bit(b) {
					if xb_bit(b) {
						if xb_bit(b) do break
						offset += int(xb_read(b, d.esc_len)) + 4
					} else {
						offset += int(xb_read(b, 2)) + 1
					}
				}
				neg := !xb_bit(b)
				ch.coeffs[offset & mask] = f32(-val if neg else val)
			}
			if xb_overread(b) do return .Run_Level_Coeffs
			offset += 1
		}
	}
	return .None
}

@(private)
xma_scale_factors :: proc(d: ^Xma_Decoder, b: ^Xma_Bits) -> Xma_Error {
	rt := d.rt
	for i := 0; i < d.channels_for_cur_subframe; i += 1 {
		c := d.channel_indexes[i]
		ch := &d.ch[c]
		target := 1 - ch.scale_factor_idx
		ch.scale_factors = target
		if ch.reuse_sf {
			from := ch.saved_scale_factors[ch.scale_factor_idx]
			sf_offs := d.sf_offsets[d.table_idx][ch.table_idx]
			for band := 0; band < d.num_bands; band += 1 {
				ch.saved_scale_factors[target][band] = from[sf_offs[band]]
			}
		}
		if ch.cur_subframe == 0 || xb_bit(b) {
			if !ch.reuse_sf {
				ch.scale_factor_step = i32(xb_read(b, 2)) + 1
				val := 45 / ch.scale_factor_step
				for band := 0; band < d.num_bands; band += 1 {
					val += vlc_read(&rt.scale_vlc, b)
					ch.saved_scale_factors[target][band] = val
				}
			} else {
				band := 0
				for band < d.num_bands {
					idx := vlc_read(&rt.scale_rl_vlc, b)
					skip, val: i32
					neg: bool
					if idx == 0 {
						code := xb_read(b, 14)
						skip = i32((code & 0x3F) >> 1)
						val = i32(code >> 6)
						neg = (code & 1) == 0
					} else if idx == 1 {
						break
					} else {
						skip = i32(XMA_SCALE_RL_RUN[idx])
						val = i32(XMA_SCALE_RL_LEVEL[idx])
						neg = !xb_bit(b)
					}
					band += int(skip)
					if band >= d.num_bands do return .Scale_Factor_Run
					ch.saved_scale_factors[target][band] += (-val if neg else val)
					band += 1
				}
			}
			ch.scale_factor_idx = target
			ch.table_idx = d.table_idx
			ch.reuse_sf = true
		}
		mx := ch.saved_scale_factors[ch.scale_factors][0] if d.num_bands > 0 else 0
		for band := 1; band < d.num_bands; band += 1 {
			v := ch.saved_scale_factors[ch.scale_factors][band]
			if v > mx do mx = v
		}
		ch.max_scale_factor = mx
	}
	return .None
}

@(private)
xma_inverse_channel_transform :: proc(d: ^Xma_Decoder) {
	if !d.transform || d.channels_for_cur_subframe != 2 do return
	sfb := &d.sfb_offsets[d.table_idx]
	a := &d.ch[0]
	b := &d.ch[1]
	for band := 0; band < d.num_bands; band += 1 {
		start := sfb[band]
		end := min(sfb[band + 1], d.subframe_len)
		if d.transform_band[band] {
			for y := start; y < end; y += 1 {
				l := a.coeffs[y]
				r := b.coeffs[y]
				a.coeffs[y] = l - r
				b.coeffs[y] = l + r
			}
		} else {
			for y := start; y < end; y += 1 {
				a.coeffs[y] *= 181.0 / 128.0
				b.coeffs[y] *= 181.0 / 128.0
			}
		}
	}
}

@(private)
xma_subframe :: proc(d: ^Xma_Decoder, b: ^Xma_Bits) -> Xma_Error {
	offset := XMA_FRAME_SAMPLES
	sfl := XMA_FRAME_SAMPLES
	total_samples := XMA_FRAME_SAMPLES * d.channels
	for c := 0; c < d.channels; c += 1 {
		if offset > d.ch[c].decoded_samples {
			offset = d.ch[c].decoded_samples
			sfl = d.ch[c].subframe_len[min(d.ch[c].cur_subframe, XMA_MAX_SUBFRAMES - 1)]
		}
	}
	d.channels_for_cur_subframe = 0
	for c := 0; c < d.channels; c += 1 {
		ch := &d.ch[c]
		total_samples -= ch.decoded_samples
		if offset == ch.decoded_samples &&
			ch.cur_subframe < ch.num_subframes &&
			sfl == ch.subframe_len[ch.cur_subframe] {
			total_samples -= sfl
			ch.decoded_samples += sfl
			d.channel_indexes[d.channels_for_cur_subframe] = c
			d.channels_for_cur_subframe += 1
		}
	}
	if d.channels_for_cur_subframe == 0 do return .No_Channel_In_Subframe
	if total_samples == 0 do d.parsed_all_subframes = true

	d.table_idx = int(xma_log2(XMA_FRAME_SAMPLES / sfl))
	d.num_bands = d.num_sfb[d.table_idx]
	d.subframe_len = sfl
	d.esc_len = xma_log2(sfl - 1) + 1

	if xb_bit(b) {
		fill := int(xb_read(b, 2))
		if fill == 0 {
			length := xb_read(b, 4)
			fill = int(xb_read(b, length)) + 1
		}
		b.pos += fill
	}
	if xb_bit(b) do return .Reserved_Bit
	if err := xma_channel_transform(d, b); err != .None do return err

	tx_coeffs := false
	for i := 0; i < d.channels_for_cur_subframe; i += 1 {
		c := d.channel_indexes[i]
		d.ch[c].transmit_coefs = xb_bit(b)
		tx_coeffs = tx_coeffs || d.ch[c].transmit_coefs
	}
	if tx_coeffs {
		d.transmit_num_vec_coeffs = xb_bit(b)
		if d.transmit_num_vec_coeffs {
			nb := xma_log2((sfl + 3) / 4) + 1
			for i := 0; i < d.channels_for_cur_subframe; i += 1 {
				c := d.channel_indexes[i]
				n := int(xb_read(b, nb) << 2)
				if n > sfl do return .Vector_Coeff_Count
				d.ch[c].num_vec_coeffs = n
			}
		} else {
			for i := 0; i < d.channels_for_cur_subframe; i += 1 {
				d.ch[d.channel_indexes[i]].num_vec_coeffs = sfl
			}
		}

		qstep := i32(90)
		step := xb_signed(b, 6)
		qstep += step
		if step == -32 || step == 31 {
			neg := step == -32
			quant := i32(0)
			for b.pos + 5 < b.end {
				step = i32(xb_read(b, 5))
				if step != 31 do break
				quant += 31
			}
			qstep += -(quant + step) if neg else (quant + step)
		}
		if d.channels_for_cur_subframe == 1 {
			d.ch[d.channel_indexes[0]].quant_step = qstep
		} else {
			mod_len := xb_read(b, 3)
			for i := 0; i < d.channels_for_cur_subframe; i += 1 {
				c := d.channel_indexes[i]
				d.ch[c].quant_step = qstep
				if xb_bit(b) {
					d.ch[c].quant_step += (i32(xb_read(b, mod_len)) + 1) if mod_len > 0 else 1
				}
			}
		}
		if err := xma_scale_factors(d, b); err != .None do return err
	}

	for i := 0; i < d.channels_for_cur_subframe; i += 1 {
		c := d.channel_indexes[i]
		if d.ch[c].transmit_coefs && b.pos < b.end {
			if err := xma_coefficients(d, b, c); err != .None do return err
		} else {
			for k := 0; k < sfl; k += 1 do d.ch[c].coeffs[k] = 0.0
		}
	}

	at := offset + XMA_FRAME_SAMPLES / 2
	if tx_coeffs {
		xma_inverse_channel_transform(d)
		scale := 2.0 / f32(sfl) / 32768.0
		sfb := &d.sfb_offsets[d.table_idx]
		tmp: [XMA_FRAME_SAMPLES]f32
		rot := &d.rt.rotations[xma_log2(sfl) - 7]
		for i := 0; i < d.channels_for_cur_subframe; i += 1 {
			ch := &d.ch[d.channel_indexes[i]]
			sf := &ch.saved_scale_factors[ch.scale_factors]
			for band := 0; band < d.num_bands; band += 1 {
				end := min(sfb[band + 1], sfl)
				exp := ch.quant_step - (ch.max_scale_factor - sf[band]) * ch.scale_factor_step
				q := xma_quant_scale(d.rt, exp)
				for y := sfb[band]; y < end; y += 1 {
					tmp[y] = ch.coeffs[y] * q
				}
			}
			xma_imdct_with_rotations(rot, tmp[:sfl], ch.out[at : at + sfl], scale)
		}
	} else {
		for i := 0; i < d.channels_for_cur_subframe; i += 1 {
			c := d.channel_indexes[i]
			for k := at; k < at + sfl; k += 1 do d.ch[c].out[k] = 0.0
		}
	}

	for i := 0; i < d.channels_for_cur_subframe; i += 1 {
		ch := &d.ch[d.channel_indexes[i]]
		winlen := ch.prev_block_len
		start := at - winlen / 2
		if sfl < winlen {
			start += (winlen - sfl) / 2
			winlen = sfl
		}
		win_slice := d.rt.win_128[:]
		if winlen == 256 {
			win_slice = d.rt.win_256[:]
		} else if winlen == 512 {
			win_slice = d.rt.win_512[:]
		}
		xma_window_overlap(ch.out[start : start + winlen], win_slice)
		ch.prev_block_len = sfl
	}

	for i := 0; i < d.channels_for_cur_subframe; i += 1 {
		ch := &d.ch[d.channel_indexes[i]]
		if ch.cur_subframe >= ch.num_subframes do return .Subframe_Overrun
		ch.cur_subframe += 1
	}
	if xb_overread(b) do return .Subframe_Overread
	return .None
}

xma_decode_frame :: proc(d: ^Xma_Decoder, data: []u8, nbits: int, out: ^[dynamic]i16) -> Xma_Error {
	max_bits := len(data) * 8
	b := Xma_Bits{
		data = data,
		pos  = 0,
		end  = min(nbits, max_bits),
	}
	length := int(xb_read(&b, XMA_LENGTH_BITS))
	err: Xma_Error = .None
	if e := xma_tile_header(d, &b); e != .None {
		err = e
	} else {
		if d.channels > 1 && xb_bit(&b) && xb_bit(&b) {
			_ = xb_read(&b, u32(d.channels * d.channels * 4))
		}
		_ = xb_read(&b, 8)
		if xb_bit(&b) {
			if xb_bit(&b) do _ = xb_read(&b, xma_log2(XMA_FRAME_SAMPLES * 2))
			if xb_bit(&b) do _ = xb_read(&b, xma_log2(XMA_FRAME_SAMPLES * 2))
		}
		d.parsed_all_subframes = false
		for c := 0; c < d.channels; c += 1 {
			d.ch[c].decoded_samples = 0
			d.ch[c].cur_subframe = 0
			d.ch[c].reuse_sf = false
		}
		for !d.parsed_all_subframes {
			if se := xma_subframe(d, &b); se != .None {
				err = se
				break
			}
		}
		if err == .None && (xb_overread(&b) || b.pos > length) {
			err = .Frame_Overread
		}
	}

	if err != .None {
		for c := 0; c < d.channels; c += 1 {
			d.ch[c].out = {}
		}
	}
	for s := 0; s < XMA_FRAME_SAMPLES; s += 1 {
		for c := 0; c < d.channels; c += 1 {
			append(out, xma_to_i16(d.ch[c].out[s]))
		}
	}
	for c := 0; c < d.channels; c += 1 {
		copy(d.ch[c].out[:XMA_FRAME_SAMPLES / 2], d.ch[c].out[XMA_FRAME_SAMPLES:])
	}
	return err
}

xma_flush :: proc(d: ^Xma_Decoder, out: ^[dynamic]i16) {
	for s := 0; s < XMA_FRAME_SAMPLES / 2; s += 1 {
		for c := 0; c < d.channels; c += 1 {
			append(out, xma_to_i16(d.ch[c].out[s]))
		}
	}
	xma_decoder_reset(d)
}
