package vasperty_hle

import "base:intrinsics"
import "core:fmt"
import "core:mem"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import win32 "core:sys/windows"

// Virtual drive filesystem translation, kernel32 overrides, and lifecycle hooks.

foreign import kernel32_hle_kf "system:Kernel32.lib"
@(default_calling_convention = "system")
foreign kernel32_hle_kf {
	GetLogicalDrives :: proc() -> win32.DWORD ---
}

wptr_to_string :: proc(p: [^]u16, allocator := context.allocator) -> string {
	if p == nil {
		return strings.clone("", allocator)
	}
	n := 0
	for p[n] != 0 {
		n += 1
	}
	s, _ := win32.utf16_to_utf8(p[:n], allocator)
	return s
}

@(private)
wptr_len :: proc(p: [^]u16) -> int {
	if p == nil { return 0 }
	n := 0
	for p[n] != 0 { n += 1 }
	return n
}

// =============================================================================
// Virtual Drive Registry & Translation (files)
// =============================================================================

Virtual_Drive :: struct {
	letter: u16,
	root:   []u16, // UTF-16 host root without trailing separator or NUL
}

@(private)
files_state: struct {
	mu:     sync.Mutex,
	drives: [dynamic]Virtual_Drive,
}

fini_files :: proc() {
	sync.mutex_lock(&files_state.mu)
	defer sync.mutex_unlock(&files_state.mu)
	for d in files_state.drives {
		delete(d.root)
	}
	delete(files_state.drives)
	files_state.drives = nil
}

@(private)
make_root_wide :: proc(root: string) -> []u16 {
	p := "." if len(root) == 0 else root
	abs, aerr := filepath.abs(p, context.temp_allocator)
	if aerr != nil { abs = p }
	wslice := win32.utf8_to_utf16(abs)
	end := len(wslice)
	for end > 3 && (wslice[end - 1] == '\\' || wslice[end - 1] == '/') {
		end -= 1
	}
	if end < len(wslice) {
		trimmed := make([]u16, end)
		copy(trimmed, wslice[:end])
		delete(wslice)
		return trimmed
	}
	return wslice
}

mount_virtual_drive :: proc(root: string) -> (u8, bool) {
	rw := make_root_wide(root)
	sync.mutex_lock(&files_state.mu)
	defer sync.mutex_unlock(&files_state.mu)

	for d in files_state.drives {
		if len(d.root) == len(rw) && mem.compare_ptrs(raw_data(d.root), raw_data(rw), len(rw) * 2) == 0 {
			delete(rw)
			return u8(d.letter), true
		}
	}
	host_mask := GetLogicalDrives()
	for l := u8('Z'); l >= u8('D'); l -= 1 {
		bit := u32(1) << uint(l - 'A')
		if host_mask & bit != 0 { continue }
		used := false
		for d in files_state.drives {
			if d.letter == u16(l) { used = true; break }
		}
		if !used {
			append(&files_state.drives, Virtual_Drive{letter = u16(l), root = rw})
			return l, true
		}
	}
	delete(rw)
	return 0, false
}

mount_virtual_drive_at :: proc(letter: u8, root: string) {
	l := letter
	if l >= 'a' && l <= 'z' { l -= 32 }
	if l < 'A' || l > 'Z' { return }
	rw := make_root_wide(root)
	sync.mutex_lock(&files_state.mu)
	defer sync.mutex_unlock(&files_state.mu)
	for i := len(files_state.drives) - 1; i >= 0; i -= 1 {
		if files_state.drives[i].letter == u16(l) {
			delete(files_state.drives[i].root)
			ordered_remove(&files_state.drives, i)
		}
	}
	append(&files_state.drives, Virtual_Drive{letter = u16(l), root = rw})
}

translate_virtual_path_w :: proc(path: []u16, allocator := context.temp_allocator) -> ([]u16, bool) {
	rest := path
	has_prefix := false
	if len(path) >= 4 && path[0] == '\\' && path[1] == '\\' && path[2] == '?' && path[3] == '\\' {
		rest = path[4:]
		has_prefix = true
	}
	if len(rest) < 2 || rest[1] != ':' {
		return nil, false
	}
	ch := rest[0]
	if !((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')) {
		return nil, false
	}
	if ch >= 'a' && ch <= 'z' { ch -= 32 }

	sync.mutex_lock(&files_state.mu)
	var_root: []u16 = nil
	for d in files_state.drives {
		if d.letter == ch {
			var_root = d.root
			break
		}
	}
	if var_root == nil {
		sync.mutex_unlock(&files_state.mu)
		return nil, false
	}
	tail := rest[2:]
	need_sep := len(tail) == 0 || (tail[0] != '\\' && tail[0] != '/')
	LONG_PATH :: 248
	verbatim := has_prefix || (len(var_root) + len(tail) >= LONG_PATH)

	cap_n := (4 if verbatim else 0) + len(var_root) + (1 if need_sep else 0) + len(tail) + 1
	out := make([dynamic]u16, 0, cap_n, allocator)
	if verbatim {
		append(&out, '\\', '\\', '?', '\\')
	}
	for u in var_root { append(&out, u) }
	if need_sep { append(&out, '\\') }
	for u in tail {
		append(&out, '\\' if (verbatim && u == '/') else u)
	}
	append(&out, 0)
	sync.mutex_unlock(&files_state.mu)
	return out[:], true
}

@(private)
files_wide :: proc(path: [^]u16) -> [^]u16 {
	if path == nil { return nil }
	n := wptr_len(path)
	if tr, ok := translate_virtual_path_w(path[:n], context.temp_allocator); ok {
		return raw_data(tr)
	}
	return path
}

@(private)
files_narrow_to_wide :: proc(path: cstring) -> ([]u16, bool) {
	if path == nil { return nil, false }
	s := string(path)
	rest := s[4:] if strings.has_prefix(s, `\\?\`) else s
	if len(rest) < 2 || rest[1] != ':' {
		return nil, false
	}
	c := rest[0]
	if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) {
		return nil, false
	}
	w := win32.utf8_to_utf16(s, context.temp_allocator)
	return translate_virtual_path_w(w, context.temp_allocator)
}

@(private)
host_fn :: proc(dll, name: string, $T: typeid) -> (T, bool) {
	addr, ok := host_function(dll, name)
	if !ok { return nil, false }
	return cast(T)rawptr(addr), true
}

// Win32 & UCRT File Overrides

CreateFileW :: proc "system" (p: [^]u16, acc, sh: u32, sec: rawptr, disp, flags: u32, tmpl: win32.HANDLE) -> win32.HANDLE {
	context = hle_context()
	fn, ok := host_fn("kernel32.dll", "CreateFileW", proc "system" ([^]u16, u32, u32, rawptr, u32, u32, win32.HANDLE) -> win32.HANDLE)
	if !ok { return win32.INVALID_HANDLE_VALUE }
	return fn(files_wide(p), acc, sh, sec, disp, flags, tmpl)
}
CreateFileA :: proc "system" (p: cstring, acc, sh: u32, sec: rawptr, disp, flags: u32, tmpl: win32.HANDLE) -> win32.HANDLE {
	context = hle_context()
	if wp, ok := files_narrow_to_wide(p); ok {
		fn, okf := host_fn("kernel32.dll", "CreateFileW", proc "system" ([^]u16, u32, u32, rawptr, u32, u32, win32.HANDLE) -> win32.HANDLE)
		if !okf { return win32.INVALID_HANDLE_VALUE }
		return fn(raw_data(wp), acc, sh, sec, disp, flags, tmpl)
	}
	fn, okf := host_fn("kernel32.dll", "CreateFileA", proc "system" (cstring, u32, u32, rawptr, u32, u32, win32.HANDLE) -> win32.HANDLE)
	if !okf { return win32.INVALID_HANDLE_VALUE }
	return fn(p, acc, sh, sec, disp, flags, tmpl)
}
CreateFile2 :: proc "system" (p: [^]u16, acc, sh, disp: u32, params: rawptr) -> win32.HANDLE {
	context = hle_context()
	fn, ok := host_fn("kernel32.dll", "CreateFile2", proc "system" ([^]u16, u32, u32, u32, rawptr) -> win32.HANDLE)
	if !ok { return win32.INVALID_HANDLE_VALUE }
	return fn(files_wide(p), acc, sh, disp, params)
}
HLE_ReadFile :: proc "system" (h: win32.HANDLE, buf: rawptr, n: u32, read: ^u32, ov: rawptr) -> win32.BOOL {
	context = hle_context()
	hooks := get_gpu_hooks()
	tok: uintptr = 0
	if hooks.kernel_will_write != nil && buf != nil && n > 0 {
		tok = hooks.kernel_will_write(uintptr(buf), uint(n))
	}
	defer if hooks.kernel_end_write != nil && tok != 0 { hooks.kernel_end_write(tok) }
	fn, ok := host_fn("kernel32.dll", "ReadFile", proc "system" (win32.HANDLE, rawptr, u32, ^u32, rawptr) -> win32.BOOL)
	if !ok { return false }
	return fn(h, buf, n, read, ov)
}
hle_fread :: proc "c" (buf: rawptr, sz, cnt: uint, stream: rawptr) -> uint {
	context = hle_context()
	hooks := get_gpu_hooks()
	tok: uintptr = 0
	if hooks.kernel_will_write != nil && buf != nil && sz * cnt > 0 {
		tok = hooks.kernel_will_write(uintptr(buf), sz * cnt)
	}
	defer if hooks.kernel_end_write != nil && tok != 0 { hooks.kernel_end_write(tok) }
	fn, ok := host_fn("ucrtbase.dll", "fread", proc "c" (rawptr, uint, uint, rawptr) -> uint)
	if !ok { return 0 }
	return fn(buf, sz, cnt, stream)
}
DeleteFileA :: proc "system" (p: cstring) -> i32 {
	context = hle_context()
	if wp, ok := files_narrow_to_wide(p); ok {
		fn, okf := host_fn("kernel32.dll", "DeleteFileW", proc "system" ([^]u16) -> i32)
		return fn(raw_data(wp)) if okf else 0
	}
	fn, okf := host_fn("kernel32.dll", "DeleteFileA", proc "system" (cstring) -> i32)
	return fn(p) if okf else 0
}
DeleteFileW :: proc "system" (p: [^]u16) -> i32 {
	context = hle_context()
	fn, ok := host_fn("kernel32.dll", "DeleteFileW", proc "system" ([^]u16) -> i32)
	return fn(files_wide(p)) if ok else 0
}
RemoveDirectoryW :: proc "system" (p: [^]u16) -> i32 {
	context = hle_context()
	fn, ok := host_fn("kernel32.dll", "RemoveDirectoryW", proc "system" ([^]u16) -> i32)
	return fn(files_wide(p)) if ok else 0
}
SetFileAttributesW :: proc "system" (p: [^]u16, attr: u32) -> i32 {
	context = hle_context()
	fn, ok := host_fn("kernel32.dll", "SetFileAttributesW", proc "system" ([^]u16, u32) -> i32)
	return fn(files_wide(p), attr) if ok else 0
}
GetFileAttributesA :: proc "system" (p: cstring) -> u32 {
	context = hle_context()
	if wp, ok := files_narrow_to_wide(p); ok {
		fn, okf := host_fn("kernel32.dll", "GetFileAttributesW", proc "system" ([^]u16) -> u32)
		return fn(raw_data(wp)) if okf else ~u32(0)
	}
	fn, okf := host_fn("kernel32.dll", "GetFileAttributesA", proc "system" (cstring) -> u32)
	return fn(p) if okf else ~u32(0)
}
GetFileAttributesW :: proc "system" (p: [^]u16) -> u32 {
	context = hle_context()
	fn, ok := host_fn("kernel32.dll", "GetFileAttributesW", proc "system" ([^]u16) -> u32)
	return fn(files_wide(p)) if ok else ~u32(0)
}
GetFileAttributesExW :: proc "system" (p: [^]u16, lvl: i32, info: rawptr) -> i32 {
	context = hle_context()
	fn, ok := host_fn("kernel32.dll", "GetFileAttributesExW", proc "system" ([^]u16, i32, rawptr) -> i32)
	return fn(files_wide(p), lvl, info) if ok else 0
}
CreateDirectoryW :: proc "system" (p: [^]u16, sec: rawptr) -> i32 {
	context = hle_context()
	fn, ok := host_fn("kernel32.dll", "CreateDirectoryW", proc "system" ([^]u16, rawptr) -> i32)
	return fn(files_wide(p), sec) if ok else 0
}
GetDiskFreeSpaceExW :: proc "system" (p: [^]u16, av, tot, fr: ^u64) -> i32 {
	context = hle_context()
	fn, ok := host_fn("kernel32.dll", "GetDiskFreeSpaceExW", proc "system" ([^]u16, ^u64, ^u64, ^u64) -> i32)
	return fn(files_wide(p), av, tot, fr) if ok else 0
}
GetDiskFreeSpaceW :: proc "system" (p: [^]u16, spc, bps, fc, tc: ^u32) -> i32 {
	context = hle_context()
	fn, ok := host_fn("kernel32.dll", "GetDiskFreeSpaceW", proc "system" ([^]u16, ^u32, ^u32, ^u32, ^u32) -> i32)
	return fn(files_wide(p), spc, bps, fc, tc) if ok else 0
}
FindFirstFileW :: proc "system" (p: [^]u16, fd: rawptr) -> win32.HANDLE {
	context = hle_context()
	fn, ok := host_fn("kernel32.dll", "FindFirstFileW", proc "system" ([^]u16, rawptr) -> win32.HANDLE)
	return fn(files_wide(p), fd) if ok else win32.INVALID_HANDLE_VALUE
}
FindFirstFileExW :: proc "system" (p: [^]u16, lvl: i32, fd: rawptr, sop: i32, sf: rawptr, fl: u32) -> win32.HANDLE {
	context = hle_context()
	fn, ok := host_fn("kernel32.dll", "FindFirstFileExW", proc "system" ([^]u16, i32, rawptr, i32, rawptr, u32) -> win32.HANDLE)
	return fn(files_wide(p), lvl, fd, sop, sf, fl) if ok else win32.INVALID_HANDLE_VALUE
}
MoveFileExW :: proc "system" (ex, nw: [^]u16, fl: u32) -> i32 {
	context = hle_context()
	fn, ok := host_fn("kernel32.dll", "MoveFileExW", proc "system" ([^]u16, [^]u16, u32) -> i32)
	return fn(files_wide(ex), files_wide(nw), fl) if ok else 0
}
SetCurrentDirectoryA :: proc "system" (p: cstring) -> i32 {
	context = hle_context()
	if wp, ok := files_narrow_to_wide(p); ok {
		fn, okf := host_fn("kernel32.dll", "SetCurrentDirectoryW", proc "system" ([^]u16) -> i32)
		return fn(raw_data(wp)) if okf else 0
	}
	fn, okf := host_fn("kernel32.dll", "SetCurrentDirectoryA", proc "system" (cstring) -> i32)
	return fn(p) if okf else 0
}

@(private) crt_wfopen :: proc "c" (p, m: [^]u16) -> rawptr {
	context = hle_context()
	fn, ok := host_fn("ucrtbase.dll", "_wfopen", proc "c" ([^]u16, [^]u16) -> rawptr)
	return fn(files_wide(p), m) if ok else nil
}
@(private) crt_wfopen_s :: proc "c" (out: ^rawptr, p, m: [^]u16) -> i32 {
	context = hle_context()
	fn, ok := host_fn("ucrtbase.dll", "_wfopen_s", proc "c" (^rawptr, [^]u16, [^]u16) -> i32)
	return fn(out, files_wide(p), m) if ok else 22
}
@(private) crt_wfsopen :: proc "c" (p, m: [^]u16, sh: i32) -> rawptr {
	context = hle_context()
	fn, ok := host_fn("ucrtbase.dll", "_wfsopen", proc "c" ([^]u16, [^]u16, i32) -> rawptr)
	return fn(files_wide(p), m, sh) if ok else nil
}
@(private) crt_fopen :: proc "c" (p, m: cstring) -> rawptr {
	context = hle_context()
	if wp, ok := files_narrow_to_wide(p); ok {
		wm := win32.utf8_to_wstring(string(m) if m != nil else "", context.temp_allocator)
		return crt_wfopen(raw_data(wp), cast([^]u16)wm)
	}
	fn, ok := host_fn("ucrtbase.dll", "fopen", proc "c" (cstring, cstring) -> rawptr)
	return fn(p, m) if ok else nil
}
@(private) crt_fopen_s :: proc "c" (out: ^rawptr, p, m: cstring) -> i32 {
	context = hle_context()
	if wp, ok := files_narrow_to_wide(p); ok {
		wm := win32.utf8_to_wstring(string(m) if m != nil else "", context.temp_allocator)
		return crt_wfopen_s(out, raw_data(wp), cast([^]u16)wm)
	}
	fn, ok := host_fn("ucrtbase.dll", "fopen_s", proc "c" (^rawptr, cstring, cstring) -> i32)
	return fn(out, p, m) if ok else 22
}
@(private) crt_open :: proc "c" (p: cstring, oflag, pmode: i32) -> i32 {
	context = hle_context()
	if wp, ok := files_narrow_to_wide(p); ok {
		fn, okf := host_fn("ucrtbase.dll", "_wopen", proc "c" ([^]u16, i32, i32) -> i32)
		return fn(raw_data(wp), oflag, pmode) if okf else -1
	}
	fn, okf := host_fn("ucrtbase.dll", "_open", proc "c" (cstring, i32, i32) -> i32)
	return fn(p, oflag, pmode) if okf else -1
}
@(private) crt_wopen :: proc "c" (p: [^]u16, oflag, pmode: i32) -> i32 {
	context = hle_context()
	fn, ok := host_fn("ucrtbase.dll", "_wopen", proc "c" ([^]u16, i32, i32) -> i32)
	return fn(files_wide(p), oflag, pmode) if ok else -1
}
@(private) crt_wstat64 :: proc "c" (p: [^]u16, st: rawptr) -> i32 {
	context = hle_context()
	fn, ok := host_fn("ucrtbase.dll", "_wstat64", proc "c" ([^]u16, rawptr) -> i32)
	return fn(files_wide(p), st) if ok else -1
}
@(private) crt_stat64i32 :: proc "c" (p: cstring, st: rawptr) -> i32 {
	context = hle_context()
	if wp, ok := files_narrow_to_wide(p); ok {
		fn, okf := host_fn("ucrtbase.dll", "_wstat64i32", proc "c" ([^]u16, rawptr) -> i32)
		return fn(raw_data(wp), st) if okf else -1
	}
	fn, okf := host_fn("ucrtbase.dll", "_stat64i32", proc "c" (cstring, rawptr) -> i32)
	return fn(p, st) if okf else -1
}
@(private) crt_remove :: proc "c" (p: cstring) -> i32 {
	context = hle_context()
	if wp, ok := files_narrow_to_wide(p); ok {
		fn, okf := host_fn("ucrtbase.dll", "_wremove", proc "c" ([^]u16) -> i32)
		return fn(raw_data(wp)) if okf else -1
	}
	fn, okf := host_fn("ucrtbase.dll", "remove", proc "c" (cstring) -> i32)
	return fn(p) if okf else -1
}
@(private) crt_wchmod :: proc "c" (p: [^]u16, mode: i32) -> i32 {
	context = hle_context()
	fn, ok := host_fn("ucrtbase.dll", "_wchmod", proc "c" ([^]u16, i32) -> i32)
	return fn(files_wide(p), mode) if ok else -1
}
@(private) crt_wutime64 :: proc "c" (p: [^]u16, times: rawptr) -> i32 {
	context = hle_context()
	fn, ok := host_fn("ucrtbase.dll", "_wutime64", proc "c" ([^]u16, rawptr) -> i32)
	return fn(files_wide(p), times) if ok else -1
}

FILES_DLLS := [?]string{
	"kernel32.dll", "kernelbase.dll",
	"api-ms-win-core-file-*", "api-ms-win-core-handle-*",
	"api-ms-win-core-processenvironment-*",
	"ucrtbase.dll", "api-ms-win-crt-stdio-*", "api-ms-win-crt-filesystem-*", "api-ms-win-crt-time-*",
}
FILES_EXPORTS := [?]Hle_Export {
	{name = "ReadFile", address = uintptr(rawptr(HLE_ReadFile))},
	{name = "fread", address = uintptr(rawptr(hle_fread))},
	{name = "CreateFileW", address = uintptr(rawptr(CreateFileW))},
	{name = "CreateFileA", address = uintptr(rawptr(CreateFileA))},
	{name = "CreateFile2", address = uintptr(rawptr(CreateFile2))},
	{name = "DeleteFileA", address = uintptr(rawptr(DeleteFileA))},
	{name = "DeleteFileW", address = uintptr(rawptr(DeleteFileW))},
	{name = "RemoveDirectoryW", address = uintptr(rawptr(RemoveDirectoryW))},
	{name = "SetFileAttributesW", address = uintptr(rawptr(SetFileAttributesW))},
	{name = "GetFileAttributesA", address = uintptr(rawptr(GetFileAttributesA))},
	{name = "CreateDirectoryW", address = uintptr(rawptr(CreateDirectoryW))},
	{name = "GetFileAttributesW", address = uintptr(rawptr(GetFileAttributesW))},
	{name = "GetFileAttributesExW", address = uintptr(rawptr(GetFileAttributesExW))},
	{name = "GetDiskFreeSpaceExW", address = uintptr(rawptr(GetDiskFreeSpaceExW))},
	{name = "GetDiskFreeSpaceW", address = uintptr(rawptr(GetDiskFreeSpaceW))},
	{name = "FindFirstFileW", address = uintptr(rawptr(FindFirstFileW))},
	{name = "FindFirstFileExW", address = uintptr(rawptr(FindFirstFileExW))},
	{name = "MoveFileExW", address = uintptr(rawptr(MoveFileExW))},
	{name = "SetCurrentDirectoryA", address = uintptr(rawptr(SetCurrentDirectoryA))},
	{name = "_wfopen", address = uintptr(rawptr(crt_wfopen))},
	{name = "_wfopen_s", address = uintptr(rawptr(crt_wfopen_s))},
	{name = "_wfsopen", address = uintptr(rawptr(crt_wfsopen))},
	{name = "fopen", address = uintptr(rawptr(crt_fopen))},
	{name = "fopen_s", address = uintptr(rawptr(crt_fopen_s))},
	{name = "_open", address = uintptr(rawptr(crt_open))},
	{name = "_wopen", address = uintptr(rawptr(crt_wopen))},
	{name = "_wstat64", address = uintptr(rawptr(crt_wstat64))},
	{name = "_stat64i32", address = uintptr(rawptr(crt_stat64i32))},
	{name = "remove", address = uintptr(rawptr(crt_remove))},
	{name = "_wchmod", address = uintptr(rawptr(crt_wchmod))},
	{name = "_wutime64", address = uintptr(rawptr(crt_wutime64))},
}

// =============================================================================
// kernel32 overrides
// =============================================================================

ERROR_MOD_NOT_FOUND :: u32(126)
ERROR_INSUFFICIENT_BUFFER :: u32(122)

@(private) g_title_ex_filter: uintptr = 0

@(private)
find_module_for_title :: proc(path: string, load: bool) -> (rawptr, bool) {
	idx := strings.last_index_any(path, `/\`)
	file := path if idx < 0 else path[idx + 1:]
	if !strings.contains(file, ".") {
		file = strings.concatenate({file, ".dll"}, context.temp_allocator)
	}
	if load {
		sync.mutex_lock(&g_rt.mu)
		ldr := g_rt.title_dll_loader
		usr := g_rt.title_dll_loader_user
		sync.mutex_unlock(&g_rt.mu)
		if ldr != nil {
			base, handled, err := ldr(usr, file)
			if err {
				SetLastError(ERROR_MOD_NOT_FOUND)
				return nil, true
			}
			if handled {
				return rawptr(base), true
			}
		}
	}
	if base, ok := image_named(file); ok {
		return rawptr(base), true
	}
	def_pol := default_host_policy(context.temp_allocator)
	allows_host := host_policy_allows(&def_pol, file)
	if !allows_host {
		if mod, ok := find_module_serving(file); ok {
			return rawptr(mod), true
		}
		SetLastError(ERROR_MOD_NOT_FOUND)
		return nil, true
	}
	return nil, false
}

HLE_GetModuleHandleW :: proc "system" (name: [^]u16) -> rawptr {
	context = hle_context()
	if name == nil {
		base, ok := main_image()
		return rawptr(base) if ok else nil
	}
	s := wptr_to_string(name, context.temp_allocator)
	if h, handled := find_module_for_title(s, false); handled {
		return h
	}
	fn, ok := host_fn("kernel32.dll", "GetModuleHandleW", proc "system" ([^]u16) -> rawptr)
	return fn(name) if ok else nil
}

HLE_GetModuleHandleA :: proc "system" (name: cstring) -> rawptr {
	context = hle_context()
	if name == nil {
		base, ok := main_image()
		return rawptr(base) if ok else nil
	}
	if h, handled := find_module_for_title(string(name), false); handled {
		return h
	}
	fn, ok := host_fn("kernel32.dll", "GetModuleHandleA", proc "system" (cstring) -> rawptr)
	return fn(name) if ok else nil
}

@(private)
copy_trunc_u8 :: proc(src: []u8, dst: [^]u8, sz: u32) -> u32 {
	if dst == nil || sz == 0 {
		SetLastError(ERROR_INSUFFICIENT_BUFFER)
		return 0
	}
	room := int(sz) - 1
	n := min(len(src), room)
	if n > 0 { mem.copy(dst, raw_data(src), n) }
	dst[n] = 0
	if n < len(src) {
		SetLastError(ERROR_INSUFFICIENT_BUFFER)
		return sz
	}
	SetLastError(0)
	return u32(n)
}

@(private)
copy_trunc_u16 :: proc(src: []u16, dst: [^]u16, sz: u32) -> u32 {
	if dst == nil || sz == 0 {
		SetLastError(ERROR_INSUFFICIENT_BUFFER)
		return 0
	}
	room := int(sz) - 1
	n := min(len(src), room)
	if n > 0 { mem.copy(dst, raw_data(src), n * 2) }
	dst[n] = 0
	if n < len(src) {
		SetLastError(ERROR_INSUFFICIENT_BUFFER)
		return sz
	}
	SetLastError(0)
	return u32(n)
}

HLE_GetModuleFileNameW :: proc "system" (mod: rawptr, out: [^]u16, sz: u32) -> u32 {
	context = hle_context()
	base := uintptr(mod)
	if mod == nil {
		b, ok := main_image()
		if !ok { base = 0 } else { base = b }
	}
	if p, ok := image_path(base, context.temp_allocator); ok {
		w := win32.utf8_to_utf16(p, context.temp_allocator)
		return copy_trunc_u16(w, out, sz)
	}
	fn, okf := host_fn("kernel32.dll", "GetModuleFileNameW", proc "system" (rawptr, [^]u16, u32) -> u32)
	return fn(mod, out, sz) if okf else 0
}

HLE_GetModuleFileNameA :: proc "system" (mod: rawptr, out: [^]u8, sz: u32) -> u32 {
	context = hle_context()
	base := uintptr(mod)
	if mod == nil {
		b, ok := main_image()
		if !ok { base = 0 } else { base = b }
	}
	if p, ok := image_path(base, context.temp_allocator); ok {
		return copy_trunc_u8(transmute([]u8)p, out, sz)
	}
	fn, okf := host_fn("kernel32.dll", "GetModuleFileNameA", proc "system" (rawptr, [^]u8, u32) -> u32)
	return fn(mod, out, sz) if okf else 0
}

HLE_LoadLibraryExA :: proc "system" (name: cstring, file: rawptr, flags: u32) -> rawptr {
	context = hle_context()
	if name != nil {
		runs := (flags & (0x1 | 0x2 | 0x20 | 0x40)) == 0
		if h, handled := find_module_for_title(string(name), runs); handled {
			return h
		}
	}
	fn, ok := host_fn("kernel32.dll", "LoadLibraryExA", proc "system" (cstring, rawptr, u32) -> rawptr)
	return fn(name, file, flags) if ok else nil
}

HLE_LoadLibraryExW :: proc "system" (name: [^]u16, file: rawptr, flags: u32) -> rawptr {
	context = hle_context()
	if name != nil {
		runs := (flags & (0x1 | 0x2 | 0x20 | 0x40)) == 0
		s := wptr_to_string(name, context.temp_allocator)
		if h, handled := find_module_for_title(s, runs); handled {
			return h
		}
	}
	fn, ok := host_fn("kernel32.dll", "LoadLibraryExW", proc "system" ([^]u16, rawptr, u32) -> rawptr)
	return fn(name, file, flags) if ok else nil
}

HLE_LoadLibraryA :: proc "system" (name: cstring) -> rawptr { context = hle_context(); return HLE_LoadLibraryExA(name, nil, 0) }
HLE_LoadLibraryW :: proc "system" (name: [^]u16) -> rawptr { context = hle_context(); return HLE_LoadLibraryExW(name, nil, 0) }

HLE_GetProcAddress :: proc "system" (mod: rawptr, name: [^]u8) -> rawptr {
	context = hle_context()
	mptr := mod
	if mptr == nil {
		if b, ok := main_image(); ok { mptr = rawptr(b) }
	}
	if m, ok := find_module_by_handle(mptr); ok {
		sname := fmt.tprintf("#%d", uintptr(name)) if uintptr(name) < 0x10000 else string(cstring(name))
		for e in m.exports {
			if e.name == sname {
				return rawptr(e.address)
			}
		}
		return nil
	}
	if _, is_title := image_path(uintptr(mptr), context.temp_allocator); !is_title && mptr != nil {
		var_buf: [260]u16
		gfn, gok := host_fn("kernel32.dll", "GetModuleFileNameW", proc "system" (rawptr, [^]u16, u32) -> u32)
		if gok {
			n := gfn(mptr, raw_data(var_buf[:]), 260)
			if n > 0 {
				path_s, _ := win32.utf16_to_utf8(var_buf[:min(int(n), 260)], context.temp_allocator)
				sidx := strings.last_index_byte(path_s, '\\')
				dll_name := path_s if sidx < 0 else path_s[sidx + 1:]
				key := fmt.tprintf("#%d", uintptr(name)) if uintptr(name) < 0x10000 else strings.clone(string(cstring(name)), context.temp_allocator)
				if addr, hok := registry_lookup(dll_name, key); hok {
					return rawptr(addr)
				}
			}
		}
	}
	fn, ok := host_fn("kernel32.dll", "GetProcAddress", proc "system" (rawptr, [^]u8) -> rawptr)
	return fn(mptr, name) if ok else nil
}

HLE_FreeLibrary :: proc "system" (mod: rawptr) -> i32 {
	context = hle_context()
	if _, ok := find_module_by_handle(mod); ok { return 1 }
	if _, ok := image_path(uintptr(mod), context.temp_allocator); ok { return 1 }
	fn, okf := host_fn("kernel32.dll", "FreeLibrary", proc "system" (rawptr) -> i32)
	return fn(mod) if okf else 0
}

HLE_DisableThreadLibraryCalls :: proc "system" (mod: rawptr) -> i32 {
	context = hle_context()
	sync.mutex_lock(&g_rt.mu)
	hook := g_rt.disable_thread_calls
	sync.mutex_unlock(&g_rt.mu)
	if hook != nil && hook(uintptr(mod)) {
		return 1
	}
	fn, ok := host_fn("kernel32.dll", "DisableThreadLibraryCalls", proc "system" (rawptr) -> i32)
	return fn(mod) if ok else 1
}

HLE_OutputDebugStringA :: proc "system" (t: cstring) { context = hle_context(); _ = t }
HLE_OutputDebugStringW :: proc "system" (t: [^]u16) { context = hle_context(); _ = t }

@(private) hle_exit :: proc "c" (code: i32) {
	context = hle_context()
	fn, ok := host_fn("ucrtbase.dll", "exit", proc "c" (i32))
	if ok { fn(code) }
	win32.ExitProcess(u32(code))
}
@(private) hle_abort :: proc "c" () {
	context = hle_context()
	fn, ok := host_fn("ucrtbase.dll", "abort", proc "c" ())
	if ok { fn() }
	win32.ExitProcess(3)
}
@(private) hle_terminate :: proc "c" () { context = hle_context(); hle_abort() }
@(private) hle_inv_param :: proc "c" () { context = hle_context(); hle_abort() }
@(private) hle_terminate_process :: proc "system" (proc_h: rawptr, code: u32) -> i32 {
	context = hle_context()
	fn, ok := host_fn("kernel32.dll", "TerminateProcess", proc "system" (rawptr, u32) -> i32)
	return fn(proc_h, code) if ok else 0
}
@(private) hle_unhandled_cb :: proc "system" (info: rawptr) -> i32 {
	context = hle_context()
	prev := intrinsics.atomic_load(&g_title_ex_filter)
	if prev == 0 { return 0 }
	f := cast(proc "system" (rawptr) -> i32)rawptr(prev)
	return f(info)
}
@(private) hle_set_unhandled :: proc "system" (filter: uintptr) -> uintptr {
	context = hle_context()
	fn, ok := host_fn("kernel32.dll", "SetUnhandledExceptionFilter", proc "system" (rawptr) -> uintptr)
	if ok { _ = fn(rawptr(hle_unhandled_cb)) }
	return intrinsics.atomic_exchange(&g_title_ex_filter, filter)
}

KERNEL_DLLS := [?]string{
	"kernel32.dll", "kernelbase.dll",
	"api-ms-win-core-libraryloader-*", "api-ms-win-core-debug-*",
	"api-ms-win-core-errorhandling-*", "api-ms-win-core-processthreads-*",
	"api-ms-win-crt-runtime-*",
}
KERNEL_EXPORTS := [?]Hle_Export {
	{name = "GetModuleHandleW", address = uintptr(rawptr(HLE_GetModuleHandleW))},
	{name = "GetModuleHandleA", address = uintptr(rawptr(HLE_GetModuleHandleA))},
	{name = "GetModuleFileNameW", address = uintptr(rawptr(HLE_GetModuleFileNameW))},
	{name = "GetModuleFileNameA", address = uintptr(rawptr(HLE_GetModuleFileNameA))},
	{name = "LoadLibraryExA", address = uintptr(rawptr(HLE_LoadLibraryExA))},
	{name = "LoadLibraryExW", address = uintptr(rawptr(HLE_LoadLibraryExW))},
	{name = "LoadLibraryA", address = uintptr(rawptr(HLE_LoadLibraryA))},
	{name = "LoadLibraryW", address = uintptr(rawptr(HLE_LoadLibraryW))},
	{name = "GetProcAddress", address = uintptr(rawptr(HLE_GetProcAddress))},
	{name = "FreeLibrary", address = uintptr(rawptr(HLE_FreeLibrary))},
	{name = "DisableThreadLibraryCalls", address = uintptr(rawptr(HLE_DisableThreadLibraryCalls))},
	{name = "OutputDebugStringA", address = uintptr(rawptr(HLE_OutputDebugStringA))},
	{name = "OutputDebugStringW", address = uintptr(rawptr(HLE_OutputDebugStringW))},
	{name = "exit", address = uintptr(rawptr(hle_exit))},
	{name = "abort", address = uintptr(rawptr(hle_abort))},
	{name = "terminate", address = uintptr(rawptr(hle_terminate))},
	{name = "_invalid_parameter_noinfo_noreturn", address = uintptr(rawptr(hle_inv_param))},
	{name = "TerminateProcess", address = uintptr(rawptr(hle_terminate_process))},
	{name = "SetUnhandledExceptionFilter", address = uintptr(rawptr(hle_set_unhandled))},
}

// =============================================================================
// lifecycle
// =============================================================================

App_Notify_Routine :: #type proc "system" (flag: u8, ctx: rawptr)
App_Notify_Reg :: struct {
	id:      uintptr,
	routine: App_Notify_Routine,
	ctx:     rawptr,
}

@(private)
lifecycle_state: struct {
	mu:          sync.Mutex,
	routines:    [dynamic]App_Notify_Reg,
	constrained: [dynamic]App_Notify_Reg,
}

fini_lifecycle :: proc() {
	sync.mutex_lock(&lifecycle_state.mu)
	defer sync.mutex_unlock(&lifecycle_state.mu)
	delete(lifecycle_state.routines)
	delete(lifecycle_state.constrained)
	lifecycle_state.routines = nil
	lifecycle_state.constrained = nil
}

@(private) lc_next_id: uintptr = 1

RegisterAppStateChangeNotification :: proc "system" (r: App_Notify_Routine, ctx: rawptr, out: ^uintptr) -> u32 {
	context = hle_context()
	if r == nil || out == nil { return 87 }
	id := intrinsics.atomic_add(&lc_next_id, 1)
	sync.mutex_lock(&lifecycle_state.mu)
	append(&lifecycle_state.routines, App_Notify_Reg{id = id, routine = r, ctx = ctx})
	sync.mutex_unlock(&lifecycle_state.mu)
	out^ = id
	return 0
}
UnregisterAppStateChangeNotification :: proc "system" (id: uintptr) {
	context = hle_context()
	sync.mutex_lock(&lifecycle_state.mu)
	defer sync.mutex_unlock(&lifecycle_state.mu)
	for r, i in lifecycle_state.routines {
		if r.id == id { ordered_remove(&lifecycle_state.routines, i); break }
	}
}
RegisterAppConstrainedChangeNotification :: proc "system" (r: App_Notify_Routine, ctx: rawptr, out: ^uintptr) -> u32 {
	context = hle_context()
	if r == nil || out == nil { return 87 }
	id := intrinsics.atomic_add(&lc_next_id, 1)
	sync.mutex_lock(&lifecycle_state.mu)
	append(&lifecycle_state.constrained, App_Notify_Reg{id = id, routine = r, ctx = ctx})
	sync.mutex_unlock(&lifecycle_state.mu)
	out^ = id
	return 0
}
UnregisterAppConstrainedChangeNotification :: proc "system" (id: uintptr) {
	context = hle_context()
	sync.mutex_lock(&lifecycle_state.mu)
	defer sync.mutex_unlock(&lifecycle_state.mu)
	for r, i in lifecycle_state.constrained {
		if r.id == id { ordered_remove(&lifecycle_state.constrained, i); break }
	}
}

end_title_and_exit :: proc() {
	win32.ExitProcess(0)
}

@(private) HLE_CreateWindowExW :: proc "system" (ex: u32, cls, title: [^]u16, st: u32, x, y, w, h: i32, par, menu, inst, param: rawptr) -> rawptr {
	context = hle_context()
	fn, ok := host_fn("user32.dll", "CreateWindowExW", proc "system" (u32, [^]u16, [^]u16, u32, i32, i32, i32, i32, rawptr, rawptr, rawptr, rawptr) -> rawptr)
	return fn(ex, cls, title, st, x, y, w, h, par, menu, inst, param) if ok else nil
}
@(private) HLE_CreateWindowExA :: proc "system" (ex: u32, cls, title: cstring, st: u32, x, y, w, h: i32, par, menu, inst, param: rawptr) -> rawptr {
	context = hle_context()
	fn, ok := host_fn("user32.dll", "CreateWindowExA", proc "system" (u32, cstring, cstring, u32, i32, i32, i32, i32, rawptr, rawptr, rawptr, rawptr) -> rawptr)
	return fn(ex, cls, title, st, x, y, w, h, par, menu, inst, param) if ok else nil
}
@(private) HLE_ShowWindow :: proc "system" (hwnd: rawptr, cmd: i32) -> i32 {
	context = hle_context()
	fn, ok := host_fn("user32.dll", "ShowWindow", proc "system" (rawptr, i32) -> i32)
	return fn(hwnd, cmd) if ok else 0
}

LIFECYCLE_DLLS := [?]string{
	"api-ms-win-core-psm-appnotify-*",
	"ext-ms-win-rtcore-ntuser-window-*",
}
LIFECYCLE_EXPORTS := [?]Hle_Export {
	{name = "RegisterAppStateChangeNotification", address = uintptr(rawptr(RegisterAppStateChangeNotification))},
	{name = "UnregisterAppStateChangeNotification", address = uintptr(rawptr(UnregisterAppStateChangeNotification))},
	{name = "RegisterAppConstrainedChangeNotification", address = uintptr(rawptr(RegisterAppConstrainedChangeNotification))},
	{name = "UnregisterAppConstrainedChangeNotification", address = uintptr(rawptr(UnregisterAppConstrainedChangeNotification))},
	{name = "CreateWindowExW", address = uintptr(rawptr(HLE_CreateWindowExW))},
	{name = "CreateWindowExA", address = uintptr(rawptr(HLE_CreateWindowExA))},
	{name = "ShowWindow", address = uintptr(rawptr(HLE_ShowWindow))},
}
