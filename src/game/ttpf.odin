package vasperty_game

import win32 "core:sys/windows"

// TTPF (Tiled Texture Pack File) & low-RAM streaming archive probe.
// Uses Windows shared-read opening (FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
// and reads at most 4 KiB so multi-gigabyte or actively downloading archives can be
// inspected safely without exhausting UMA / system memory.

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
RDS5_MAGIC :: [4]u8{'R', 'D', 'S', '5'}

is_ttpf :: proc(data: []u8) -> bool {
	if len(data) < 16 {
		return false
	}
	is_t := data[0] == TTPF_MAGIC[0] && data[1] == TTPF_MAGIC[1] && data[2] == TTPF_MAGIC[2] && data[3] == TTPF_MAGIC[3]
	is_r := data[0] == RDS5_MAGIC[0] && data[1] == RDS5_MAGIC[1] && data[2] == RDS5_MAGIC[2] && data[3] == RDS5_MAGIC[3]
	return is_t || is_r
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

// Streaming low-RAM shared-read file probe: reads at most 4 KiB from disk.
probe_archive_file :: proc(path: string) -> (Archive_Probe, bool) {
	wpath := win32.utf8_to_wstring(path, context.temp_allocator)
	share := win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE
	h := win32.CreateFileW(wpath, win32.GENERIC_READ, share, nil, win32.OPEN_EXISTING, win32.FILE_ATTRIBUTE_NORMAL, nil)
	if h == win32.INVALID_HANDLE_VALUE {
		return {}, false
	}
	defer win32.CloseHandle(h)

	fsize: win32.LARGE_INTEGER
	_ = win32.GetFileSizeEx(h, &fsize)

	buf: [4096]u8
	got: win32.DWORD
	if !win32.ReadFile(h, &buf[0], u32(len(buf)), &got, nil) || got < 4 {
		return {}, false
	}
	return probe_archive_bytes(buf[:got], i64(fsize)), true
}
