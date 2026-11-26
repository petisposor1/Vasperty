package vasperty_game

// RPF9 (`9FPR`) streaming archive header inspection helpers.

RPF9_MAGIC :: [4]u8{'9', 'F', 'P', 'R'}

Rpf9_Header :: struct {
	magic:       [4]u8,
	entry_count: u32,
	meta_flags:  u32,
}

is_rpf9 :: proc(data: []u8) -> bool {
	return len(data) >= 16 &&
		data[0] == RPF9_MAGIC[0] &&
		data[1] == RPF9_MAGIC[1] &&
		data[2] == RPF9_MAGIC[2] &&
		data[3] == RPF9_MAGIC[3]
}

rpf9_parse_header :: proc(data: []u8) -> (hdr: Rpf9_Header, ok: bool) {
	if !is_rpf9(data) {
		return {}, false
	}
	copy(hdr.magic[:], data[0:4])
	hdr.entry_count = u32(data[4]) | (u32(data[5]) << 8) | (u32(data[6]) << 16) | (u32(data[7]) << 24)
	hdr.meta_flags = u32(data[8]) | (u32(data[9]) << 8) | (u32(data[10]) << 16) | (u32(data[11]) << 24)
	return hdr, true
}
