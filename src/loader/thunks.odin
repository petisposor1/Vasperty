package vasperty_loader

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import win32 "core:sys/windows"

foreign import k32_extra "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign k32_extra {
	FlushInstructionCache :: proc(hProcess: win32.HANDLE, lpBaseAddress: rawptr, dwSize: uint) -> win32.BOOL ---
	IsDebuggerPresent :: proc() -> win32.BOOL ---
	DebugBreak :: proc() ---
	ExitProcess :: proc(uExitCode: u32) ---
}

Unimplemented_Policy :: enum {
	Trap,
	Return_Zero,
}

Import_Site :: struct {
	dll:    string,
	symbol: string,
	policy: Unimplemented_Policy,
	calls:  u64,
}

THUNK_SIZE :: uint(32)

Thunk_Block :: struct {
	base:  rawptr,
	len:   uint,
	used:  uint,
	sites: [dynamic]^Import_Site,
}

@(private)
unimplemented_calls_total: u64 = 0
@(private)
crash_log_mu: sync.Mutex
@(private)
crash_log_path_buf: [512]u8
@(private)
crash_log_path_len: int = 0

unimplemented_call_count :: proc() -> u64 {
	return sync.atomic_load(&unimplemented_calls_total)
}

crash_log_set_path :: proc(path: string) {
	sync.mutex_lock(&crash_log_mu)
	defer sync.mutex_unlock(&crash_log_mu)
	n := min(len(path), len(crash_log_path_buf))
	copy(crash_log_path_buf[:n], path[:n])
	crash_log_path_len = n
}

crash_log_write :: proc(msg: string) {
	sync.mutex_lock(&crash_log_mu)
	defer sync.mutex_unlock(&crash_log_mu)
	if crash_log_path_len <= 0 do return
	p := string(crash_log_path_buf[:crash_log_path_len])
	f, err := os.open(p, os.O_WRONLY | os.O_CREATE | os.O_APPEND, os.Permissions_Read_Write_All)
	if err != nil do return
	defer _ = os.close(f)
	_, _ = os.write(f, transmute([]u8)msg)
	nl := [1]u8{'\n'}
	_, _ = os.write(f, nl[:])
}

unimplemented_import :: proc "system" (site: ^Import_Site) -> u64 {
	context = {}
	_ = sync.atomic_add(&unimplemented_calls_total, 1)
	if site == nil do return 0
	prev := sync.atomic_add(&site.calls, 1)
	if site.policy == .Return_Zero {
		if prev == 0 {
			// Best-effort diagnostic without heap dependency inside trap handler
			crash_log_write(site.dll)
		}
		return 0
	}
	msg_buf: [256]u8
	msg := fmt.bprintf(msg_buf[:], "Vasperty: unimplemented import %s!%s called", site.dll, site.symbol)
	crash_log_write(msg)
	if IsDebuggerPresent() != false {
		DebugBreak()
	}
	ExitProcess(1)
	return 0
}

thunk_block_new :: proc(count: int, allocator := context.allocator) -> (Thunk_Block, bool) {
	n := max(1, count)
	raw_bytes := uint(n) * THUNK_SIZE
	len_aligned := (raw_bytes + 4095) & ~uint(4095)
	base := win32.VirtualAlloc(nil, len_aligned, win32.MEM_COMMIT | win32.MEM_RESERVE, win32.PAGE_READWRITE)
	if base == nil {
		return {}, false
	}
	return Thunk_Block{
		base  = base,
		len   = len_aligned,
		used  = 0,
		sites = make([dynamic]^Import_Site, allocator),
	}, true
}

thunk_block_emit :: proc(
	b: ^Thunk_Block,
	dll: string,
	symbol: string,
	policy: Unimplemented_Policy,
	allocator := context.allocator,
) -> (uintptr, bool) {
	if b.used + THUNK_SIZE > b.len {
		return 0, false
	}
	site := new(Import_Site, allocator)
	site.dll = strings.clone(dll, allocator)
	site.symbol = strings.clone(symbol, allocator)
	site.policy = policy
	append(&b.sites, site)

	code: [32]u8
	for i := 0; i < 32; i += 1 do code[i] = 0xCC

	site_addr := u64(uintptr(site))
	handler_addr := u64(uintptr(rawptr(unimplemented_import)))

	// mov rcx, imm64
	code[0] = 0x48; code[1] = 0xB9
	for k: uint = 0; k < 8; k += 1 do code[2 + k] = u8(site_addr >> (8 * k))
	// mov rax, imm64
	code[10] = 0x48; code[11] = 0xB8
	for k: uint = 0; k < 8; k += 1 do code[12 + k] = u8(handler_addr >> (8 * k))
	// jmp rax
	code[20] = 0xFF; code[21] = 0xE0

	dst := ([^]u8)(uintptr(b.base) + uintptr(b.used))
	for i := 0; i < 32; i += 1 do dst[i] = code[i]
	addr := uintptr(b.base) + uintptr(b.used)
	b.used += THUNK_SIZE
	return addr, true
}

thunk_block_seal :: proc(b: ^Thunk_Block) -> bool {
	if b.base == nil do return false
	old: win32.DWORD = 0
	if win32.VirtualProtect(b.base, b.len, win32.PAGE_EXECUTE_READ, &old) == false {
		return false
	}
	_ = FlushInstructionCache(win32.GetCurrentProcess(), b.base, b.len)
	return true
}

thunk_block_destroy :: proc(b: ^Thunk_Block, allocator := context.allocator) {
	if b.base != nil {
		_ = win32.VirtualFree(b.base, 0, win32.MEM_RELEASE)
	}
	for s in b.sites {
		delete(s.dll, allocator)
		delete(s.symbol, allocator)
		free(s, allocator)
	}
	delete(b.sites)
	b^ = {}
}
