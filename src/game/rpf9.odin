package vasperty_game

import "core:slice"
import win32 "core:sys/windows"

// RPF9 (`9FPR`) streaming archive header reader, zero-copy shared-read memory mapper,
// and low-RAM windowed chunk scanner (Intel UMA friendly).

Mapped_File :: struct {
	file_handle: win32.HANDLE,
	map_handle:  win32.HANDLE,
	view:        rawptr,
	data:        []u8,
}

map_file_readonly :: proc(path: string) -> (mf: Mapped_File, ok: bool) {
	wpath := win32.utf8_to_wstring(path, context.temp_allocator)
	share := win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE
	h := win32.CreateFileW(wpath, win32.GENERIC_READ, share, nil, win32.OPEN_EXISTING, win32.FILE_ATTRIBUTE_NORMAL, nil)
	if h == win32.INVALID_HANDLE_VALUE {
		return {}, false
	}
	fsize: win32.LARGE_INTEGER
	if !win32.GetFileSizeEx(h, &fsize) || fsize <= 0 {
		win32.CloseHandle(h)
		return {}, false
	}
	mh := win32.CreateFileMappingW(h, nil, win32.PAGE_READONLY, 0, 0, nil)
	if mh == nil {
		win32.CloseHandle(h)
		return {}, false
	}
	view := win32.MapViewOfFile(mh, win32.FILE_MAP_READ, 0, 0, 0)
	if view == nil {
		win32.CloseHandle(mh)
		win32.CloseHandle(h)
		return {}, false
	}
	return Mapped_File{
		file_handle = h,
		map_handle  = mh,
		view        = view,
		data        = slice.bytes_from_ptr(view, int(fsize)),
	}, true
}

unmap_file_readonly :: proc(mf: ^Mapped_File) {
	if mf == nil {
		return
	}
	if mf.view != nil {
		_ = win32.UnmapViewOfFile(mf.view)
	}
	if mf.map_handle != nil {
		_ = win32.CloseHandle(mf.map_handle)
	}
	if mf.file_handle != nil && mf.file_handle != win32.INVALID_HANDLE_VALUE {
		_ = win32.CloseHandle(mf.file_handle)
	}
	mf^ = {}
}

RPF9_MAGIC :: [4]u8{'9', 'F', 'P', 'R'}

Rpf9_Header :: struct {
	magic:       [4]u8,
	entry_count: u32,
	meta_flags:  u32,
}

Rpf9_Scan_Summary :: struct {
	bytes_scanned: i64,
	sgd5_hits:     int,
	dxbc_hits:     int,
	first_sgd5:    i64,
	first_dxbc:    i64,
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

// Streams up to `max_scan_bytes` (0 = full file) in 4 MiB shared-read windows.
rpf9_scan_embedded :: proc(path: string, max_scan_bytes: i64 = 64 << 20) -> (sum: Rpf9_Scan_Summary, ok: bool) {
	sum.first_sgd5 = -1
	sum.first_dxbc = -1
	wpath := win32.utf8_to_wstring(path, context.temp_allocator)
	share := win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE
	h := win32.CreateFileW(wpath, win32.GENERIC_READ, share, nil, win32.OPEN_EXISTING, win32.FILE_ATTRIBUTE_NORMAL, nil)
	if h == win32.INVALID_HANDLE_VALUE {
		return sum, false
	}
	defer win32.CloseHandle(h)

	CHUNK :: 4 << 20
	buf := make([]u8, CHUNK)
	defer delete(buf)

	offset := i64(0)
	for {
		to_read := u32(CHUNK)
		if max_scan_bytes > 0 {
			rem := max_scan_bytes - offset
			if rem <= 0 {
				break
			}
			if rem < i64(to_read) {
				to_read = u32(rem)
			}
		}
		got: win32.DWORD
		if !win32.ReadFile(h, &buf[0], to_read, &got, nil) || got == 0 {
			break
		}
		n := int(got)
		for i := 0; i + 4 <= n; i += 4 {
			b0 := buf[i]
			if b0 == 'S' && buf[i + 1] == 'G' && buf[i + 2] == 'D' && buf[i + 3] == '5' {
				if sum.first_sgd5 < 0 { sum.first_sgd5 = offset + i64(i) }
				sum.sgd5_hits += 1
			} else if b0 == 'D' && buf[i + 1] == 'X' && buf[i + 2] == 'B' && buf[i + 3] == 'C' {
				if sum.first_dxbc < 0 { sum.first_dxbc = offset + i64(i) }
				sum.dxbc_hits += 1
			}
		}
		offset += i64(got)
	}
	sum.bytes_scanned = offset
	return sum, true
}
