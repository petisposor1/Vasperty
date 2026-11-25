package vasperty_loader

import win32 "core:sys/windows"
import vasperty_pe "vasperty:pe"

TLS_SCN_MEM_EXECUTE :: u32(0x2000_0000)
TLS64_ADDRESS_OF_INDEX :: int(16)
TLS_LOAD_LEN :: int(9)
TLS_THUNK_SIZE :: uint(32)

// tls_patch_code rewrites `mov r64, gs:[0x58]` (`65 [48|4C] 8B ModRM 25 58 00 00 00`)
// into `call rel32; nop4` targeting the corresponding per-register TLS thunk.
tls_patch_code :: proc(code: []u8, at: uintptr, thunks: uintptr) -> int {
	count := 0
	i := 0
	for i + TLS_LOAD_LEN <= len(code) {
		rex := code[i + 1]
		modrm := code[i + 3]
		reg := int((modrm >> 3) & 7) | (8 if (rex & 4) != 0 else 0)
		if code[i] == 0x65 &&
			(rex == 0x48 || rex == 0x4C) &&
			code[i + 2] == 0x8B &&
			(modrm & 0xC7) == 0x04 &&
			code[i + 4] == 0x25 &&
			code[i + 5] == 0x58 &&
			code[i + 6] == 0x00 &&
			code[i + 7] == 0x00 &&
			code[i + 8] == 0x00 &&
			reg != 4 {
			target := thunks + uintptr(reg) * uintptr(TLS_THUNK_SIZE)
			call_end := at + uintptr(i + 5)
			rel := i32(i64(target) - i64(call_end))
			code[i] = 0xE8
			u_rel := u32(rel)
			code[i + 1] = u8(u_rel)
			code[i + 2] = u8(u_rel >> 8)
			code[i + 3] = u8(u_rel >> 16)
			code[i + 4] = u8(u_rel >> 24)
			code[i + 5] = 0x0F
			code[i + 6] = 0x1F
			code[i + 7] = 0x40
			code[i + 8] = 0x00
			count += 1
			i += TLS_LOAD_LEN
		} else {
			i += 1
		}
	}
	return count
}

// tls_build_thunks populates a writable 4 KiB page with 16 per-register thunks:
// `mov r, gs:[0x58]; lea r, [r + index * 8]; ret` and seals it as RX.
tls_build_thunks :: proc(block: rawptr, index: u32) -> (uintptr, bool) {
	if block == nil do return 0, false
	disp := index * 8
	base := ([^]u8)(block)
	for reg: u8 = 0; reg < 16; reg += 1 {
		r := reg >> 3
		low := reg & 7
		buf: [24]u8
		n := 0
		buf[n] = 0x65; n += 1
		buf[n] = 0x48 | (r << 2); n += 1
		buf[n] = 0x8B; n += 1
		buf[n] = (low << 3) | 4; n += 1
		buf[n] = 0x25; n += 1
		buf[n] = 0x58; n += 1
		buf[n] = 0x00; n += 1
		buf[n] = 0x00; n += 1
		buf[n] = 0x00; n += 1

		buf[n] = 0x48 | (r << 2) | r; n += 1
		buf[n] = 0x8D; n += 1
		buf[n] = 0x80 | (low << 3) | low; n += 1
		if low == 4 {
			buf[n] = 0x24; n += 1
		}
		buf[n] = u8(disp); n += 1
		buf[n] = u8(disp >> 8); n += 1
		buf[n] = u8(disp >> 16); n += 1
		buf[n] = u8(disp >> 24); n += 1
		buf[n] = 0xC3; n += 1

		slot := ([^]u8)(uintptr(block) + uintptr(reg) * uintptr(TLS_THUNK_SIZE))
		for k := 0; k < n; k += 1 do slot[k] = buf[k]
		_ = base
	}
	old: win32.DWORD = 0
	if win32.VirtualProtect(block, 4096, win32.PAGE_EXECUTE_READ, &old) == false {
		return 0, false
	}
	_ = FlushInstructionCache(win32.GetCurrentProcess(), block, 4096)
	return uintptr(block), true
}

tls_alloc_near :: proc(base, size: uintptr) -> rawptr {
	GRANULE :: uintptr(0x1_0000)
	if size >= (uintptr(1) << 30) {
		return nil
	}
	above := (base + size + GRANULE - 1) & ~(GRANULE - 1)
	for k: uintptr = 0; k < (uintptr(1) << 14); k += 1 {
		step := (k + 1) * GRANULE
		if base > step {
			p := win32.VirtualAlloc(rawptr(base - step), 4096, win32.MEM_COMMIT | win32.MEM_RESERVE, win32.PAGE_READWRITE)
			if p != nil do return p
		}
		p := win32.VirtualAlloc(rawptr(above + k * GRANULE), 4096, win32.MEM_COMMIT | win32.MEM_RESERVE, win32.PAGE_READWRITE)
		if p != nil do return p
	}
	return nil
}

tls_free_page :: proc(page: rawptr) {
	if page != nil {
		_ = win32.VirtualFree(page, 0, win32.MEM_RELEASE)
	}
}

tls_redirect :: proc(base: uintptr, info: ^vasperty_pe.Image_Info) -> (patched: int, thunk_page: rawptr, ok: bool) {
	if !info.has_tls {
		return 0, nil, true
	}
	dir_ptr := (^uintptr)(base + uintptr(info.tls.directory_rva) + uintptr(TLS64_ADDRESS_OF_INDEX))
	index_ptr := (^u32)(dir_ptr^)
	if index_ptr == nil {
		return 0, nil, true
	}
	index := index_ptr^
	if index == 0 {
		return 0, nil, true
	}

	page := tls_alloc_near(base, uintptr(info.size_of_image))
	if page == nil {
		return 0, nil, false
	}
	thunks, ok_th := tls_build_thunks(page, index)
	if !ok_th {
		tls_free_page(page)
		return 0, nil, false
	}

	for &sec in info.sections {
		if (sec.characteristics & TLS_SCN_MEM_EXECUTE) == 0 || sec.virtual_size == 0 {
			continue
		}
		start := base + uintptr(sec.rva)
		sz := uint(sec.virtual_size)
		old: win32.DWORD = 0
		if win32.VirtualProtect(rawptr(start), sz, win32.PAGE_EXECUTE_READWRITE, &old) == false {
			tls_free_page(page)
			return 0, nil, false
		}
		code := ([^]u8)(start)[:sz]
		patched += tls_patch_code(code, start, thunks)
		ignored: win32.DWORD = 0
		_ = win32.VirtualProtect(rawptr(start), sz, old, &ignored)
		_ = FlushInstructionCache(win32.GetCurrentProcess(), rawptr(start), sz)
	}

	index_ptr^ = 0
	return patched, page, true
}
