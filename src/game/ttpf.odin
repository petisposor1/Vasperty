package vasperty_game

import "core:os"

// TTPF (Tiled Texture Pack File) & low-RAM streaming archive probe.
// Designed for UMA / Intel Integrated GPUs so multi-gigabyte archives are never
// read wholesale into system memory just to inspect headers.

Archive_Kind :: enum {
	Unknown,
	Rpf9,
	Ttpf,
	Sgd5,
	Shader_Pack,
}

Archive_Probe :: struct {
	kind:       Archive_Kind,
	file_size:  i64,
	magic:      [4]u8,
	version:    u32,
	entry_hint: u32,
}

TTPF_MAGIC :: [4]u8{'T', 'T', 'P', 'F'}

is_ttpf :: proc(data: []u8) -> bool {
	return len(data) >= 16 &&
		data[0] == TTPF_MAGIC[0] &&
		data[1] == TTPF_MAGIC[1] &&
		data[2] == TTPF_MAGIC[2] &&
		data[3] == TTPF_MAGIC[3]
}

probe_archive_bytes :: proc(head: []u8, total_size: i64 = 0) -> Archive_Probe {
	out := Archive_Probe{
		kind      = .Unknown,
		file_size = total_size > 0 ? total_size : i64(len(head)),
	}
	if len(head) < 4 {
		return out
	}
	copy(out.magic[:], head[0:4])
	if is_rpf9(head) {
		out.kind = .Rpf9
		if hdr, ok := rpf9_parse_header(head); ok {
			out.entry_hint = hdr.entry_count
			out.version = hdr.meta_flags
		}
		return out
	}
	if is_ttpf(head) {
		out.kind = .Ttpf
		out.version = u32(head[4]) | (u32(head[5]) << 8) | (u32(head[6]) << 16) | (u32(head[7]) << 24)
		out.entry_hint = u32(head[8]) | (u32(head[9]) << 8) | (u32(head[10]) << 16) | (u32(head[11]) << 24)
		return out
	}
	if is_sgd5(head) {
		out.kind = .Sgd5
		return out
	}
	if head[0] == 'P' && head[1] == 'S' && head[2] == 0 && head[3] == 9 {
		out.kind = .Shader_Pack
		return out
	}
	return out
}

// Streaming low-RAM file probe: reads at most 4 KiB from disk.
probe_archive_file :: proc(path: string) -> (Archive_Probe, bool) {
	f, err := os.open(path)
	if err != nil {
		return {}, false
	}
	defer os.close(f)

	fsize, serr := os.file_size(f)
	if serr != nil {
		fsize = 0
	}
	buf: [4096]u8
	n, rerr := os.read(f, buf[:])
	if rerr != nil || n < 4 {
		return {}, false
	}
	return probe_archive_bytes(buf[:n], fsize), true
}
