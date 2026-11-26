package vasperty_hle

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import win32 "core:sys/windows"
import vasperty_loader "vasperty:loader"
import vasperty_pe "vasperty:pe"

HRESULT :: distinct i32

S_OK :: HRESULT(0)
E_NOTIMPL :: HRESULT(-2147467263) // 0x80004001
E_NOINTERFACE :: HRESULT(-2147467262) // 0x80004002
E_POINTER :: HRESULT(-2147467261) // 0x80004003
E_ABORT :: HRESULT(-2147467260) // 0x80004004
E_FAIL :: HRESULT(-2147467259) // 0x80004005
E_PENDING :: HRESULT(-2147483638) // 0x8000000A
E_ILLEGAL_METHOD_CALL :: HRESULT(-2147483634) // 0x8000000E
E_INVALIDARG :: HRESULT(-2147024809) // 0x80070057
E_OUTOFMEMORY :: HRESULT(-2147024882) // 0x8007000E
E_NOT_SUFFICIENT_BUFFER :: HRESULT(-2147024774) // 0x8007007A
NOT_SUPPORTED :: HRESULT(-2147024846) // 0x80070032
END_OF_FILE :: HRESULT(-2147024858) // 0x80070026
INVALID_DATA :: HRESULT(-2147024883) // 0x8007000D

Guid :: struct {
	data1: u32,
	data2: u16,
	data3: u16,
	data4: [8]u8,
}

guid_make :: proc(d1: u32, d2: u16, d3: u16, d4: [8]u8) -> Guid {
	return Guid{data1 = d1, data2 = d2, data3 = d3, data4 = d4}
}

guid_eq :: proc(a, b: Guid) -> bool {
	return a.data1 == b.data1 && a.data2 == b.data2 && a.data3 == b.data3 && a.data4 == b.data4
}

guid_to_string :: proc(g: Guid, allocator := context.allocator) -> string {
	d := g.data4
	return fmt.aprintf(
		"%08x-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x",
		g.data1,
		g.data2,
		g.data3,
		d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7],
		allocator = allocator,
	)
}

Console_Model :: enum {
	Series_X,
	Series_S,
}

console_name :: proc(model: Console_Model) -> string {
	switch model {
	case .Series_X:
		return "Xbox Series X"
	case .Series_S:
		return "Xbox Series S"
	}
	return "Xbox Series X"
}

// console_title_memory returns (gpu_optimal_bytes, standard_bytes) title pools.
console_title_memory :: proc(model: Console_Model) -> (u64, u64) {
	GIB :: u64(1) << 30
	switch model {
	case .Series_X:
		return 10 * GIB, u64(3584) << 20
	case .Series_S:
		return 8 * GIB, 2 * GIB
	}
	return 10 * GIB, u64(3584) << 20
}

// Gpu_Hooks decouples vasperty:hle from vasperty:gpu (Phase 6) so HLE can
// build, link, and test standalone while GPU virtualization initializes later.
Gpu_Hooks :: struct {
	kernel_will_write:                  proc(addr: uintptr, len: uint) -> uintptr,
	kernel_end_write:                   proc(token: uintptr),
	title_memory_remapped:              proc(base: uintptr, size: uint),
	title_memory_aliased:               proc(alias: uintptr, backing: uintptr),
	configure_virtual_memory:           proc "system" (reserved: rawptr, count: u32, ranges: rawptr) -> HRESULT,
	create_device:                      proc "system" (adapter: rawptr, params: ^u32, iid: ^Guid, out: ^rawptr) -> HRESULT,
	serialize_root_signature:           proc "system" (desc: rawptr, version: u32, blob: ^rawptr, err_blob: ^rawptr) -> HRESULT,
	serialize_versioned_root_signature: proc "system" (desc: rawptr, blob: ^rawptr, err_blob: ^rawptr) -> HRESULT,
	create_root_deserializer:           proc "system" (src: rawptr, len: uint, iid: ^Guid, out: ^rawptr) -> HRESULT,
	use_shader_cache:                   proc(dir: string),
	iid_d3d12_device:                   [16]u8,
	log_crash:                          proc(msg: string),
	fidelityfx_host_device:             proc() -> rawptr,
	fidelityfx_host_texture:            proc(list: rawptr, resource: rawptr, state: u32) -> rawptr,
	fidelityfx_record:                  proc(list: rawptr, fn: proc(host_list: rawptr, user: rawptr) -> u32, user: rawptr) -> bool,
}

Title_Info :: struct {
	id:            u32,
	store_id:      string,
	storage_bytes: u64,
	storage:       string,
	saves:         string,
}

destroy_title_info :: proc(info: ^Title_Info, allocator := context.allocator) {
	delete(info.store_id, allocator)
	delete(info.storage, allocator)
	delete(info.saves, allocator)
	info^ = {}
}

Hle_Export :: struct {
	name:    string,
	address: uintptr,
}

Hle_Module :: struct {
	name:    string,
	dlls:    []string,
	exports: []Hle_Export,
}

// module_serves returns true when a HLE module handles `dll` (case-insensitive,
// optional trailing `*` wildcard for API set patterns).
module_serves :: proc(m: ^Hle_Module, dll: string) -> bool {
	lower := strings.to_lower(dll, context.temp_allocator)
	for pattern in m.dlls {
		p_lower := strings.to_lower(pattern, context.temp_allocator)
		if strings.has_suffix(p_lower, "*") {
			prefix := p_lower[:len(p_lower) - 1]
			if strings.has_prefix(lower, prefix) {
				return true
			}
		} else if lower == p_lower {
			return true
		}
	}
	return false
}

Host_Policy :: struct {
	allow: [dynamic]string,
}

DEFAULT_HOST_ALLOW := [?]string {
	"api-ms-win-core-*",
	"api-ms-win-eventing-*",
	"api-ms-win-security-*",
	"api-ms-win-crt-*",
	"kernel32.dll",
	"kernelbase.dll",
	"ntdll.dll",
	"ucrtbase.dll",
	"vcruntime140*",
	"msvcp140*",
	"ws2_32.dll",
	"bcrypt.dll",
	"crypt32.dll",
	"ncrypt.dll",
	"winhttp.dll",
	"sspicli.dll",
	"cabinet.dll",
	"avrt.dll",
	"ext-ms-win-rtcore-ntuser-*",
	"api-ms-win-shcore-*",
	"msvcp_win.dll",
	"ole32.dll",
	"oleaut32.dll",
	"advapi32.dll",
	"iphlpapi.dll",
	"dbghelp.dll",
	"xaudio2_9.dll",
	"mfplat.dll",
	"mfreadwrite.dll",
}

default_host_policy :: proc(allocator := context.allocator) -> Host_Policy {
	policy := Host_Policy{
		allow = make([dynamic]string, 0, len(DEFAULT_HOST_ALLOW), allocator),
	}
	for s in DEFAULT_HOST_ALLOW {
		append(&policy.allow, strings.clone(s, allocator))
	}
	return policy
}

none_host_policy :: proc(allocator := context.allocator) -> Host_Policy {
	return Host_Policy{allow = make([dynamic]string, 0, 0, allocator)}
}

destroy_host_policy :: proc(p: ^Host_Policy, allocator := context.allocator) {
	for s in p.allow {
		delete(s, allocator)
	}
	delete(p.allow)
	p^ = {}
}

host_policy_allows :: proc(p: ^Host_Policy, dll: string) -> bool {
	lower := strings.to_lower(dll, context.temp_allocator)
	for pattern in p.allow {
		if strings.has_suffix(pattern, "*") {
			if strings.has_prefix(lower, pattern[:len(pattern) - 1]) {
				return true
			}
		} else if lower == pattern {
			return true
		}
	}
	return false
}

@(private)
LOAD_LIBRARY_SEARCH_SYSTEM32 :: u32(0x00000800)

foreign import kernel32_hle_rt "system:Kernel32.lib"
@(default_calling_convention = "system")
foreign kernel32_hle_rt {
	GetModuleHandleW      :: proc(lpModuleName: win32.LPCWSTR) -> win32.HMODULE ---
	SetLastError          :: proc(dwErrCode: win32.DWORD) ---
	GetLastError          :: proc() -> win32.DWORD ---
	SetProcessInformation :: proc(hProcess: win32.HANDLE, class: i32, info: rawptr, size: u32) -> win32.BOOL ---
}

foreign import winmm_hle "system:Winmm.lib"
@(default_calling_convention = "system")
foreign winmm_hle {
	timeBeginPeriod :: proc(uPeriod: u32) -> u32 ---
}

Runtime_State :: struct {
	mu:                    sync.Mutex,
	console:               Console_Model,
	main_image:            uintptr,
	images:                map[uintptr]string,
	title:                 Title_Info,
	host_modules:          map[string]win32.HMODULE,
	title_dll_loader:      proc(user: rawptr, file: string) -> (base: uintptr, handled: bool, err: bool),
	title_dll_loader_user: rawptr,
	disable_thread_calls:  proc(base: uintptr) -> bool,
	modules:               [dynamic]Hle_Module,
	gpu_hooks:             Gpu_Hooks,
	initialized:           bool,
}

@(private)
g_rt: Runtime_State

@(private)
g_hle_allocator: runtime.Allocator

@(private)
hle_context :: proc "contextless" () -> runtime.Context {
	ctx := runtime.default_context()
	if g_hle_allocator.procedure != nil {
		ctx.allocator = g_hle_allocator
	}
	return ctx
}

init_hle :: proc() {
	g_hle_allocator = context.allocator
	sync.mutex_lock(&g_rt.mu)
	if g_rt.initialized {
		sync.mutex_unlock(&g_rt.mu)
		return
	}
	g_rt.console = .Series_X
	g_rt.images = make(map[uintptr]string)
	g_rt.host_modules = make(map[string]win32.HMODULE)
	g_rt.modules = make([dynamic]Hle_Module)
	g_rt.gpu_hooks.iid_d3d12_device = [16]u8{
		0x5B, 0xDF, 0x98, 0x18, 0x1B, 0xD1, 0x5E, 0x4C,
		0xAB, 0xD3, 0xB3, 0x76, 0x05, 0xEE, 0xE8, 0xF3,
	}
	g_rt.initialized = true
	sync.mutex_unlock(&g_rt.mu)
	register_all_modules()
}

fini_hle :: proc() {
	fini_xasync()
	fini_dstorage()
	fini_gameinput()
	fini_dsp()
	fini_audio()
	fini_apu()
	fini_xgamesave()
	fini_files()

	sync.mutex_lock(&g_rt.mu)
	defer sync.mutex_unlock(&g_rt.mu)
	if !g_rt.initialized {
		return
	}
	for _, path in g_rt.images {
		delete(path)
	}
	delete(g_rt.images)
	for k, _ in g_rt.host_modules {
		delete(k)
	}
	delete(g_rt.host_modules)
	destroy_title_info(&g_rt.title)
	for &m in g_rt.modules {
		delete(m.dlls)
		delete(m.exports)
	}
	delete(g_rt.modules)
	g_rt.images = nil
	g_rt.host_modules = nil
	g_rt.modules = nil
	g_rt.initialized = false
}

set_console :: proc(model: Console_Model) {
	sync.mutex_lock(&g_rt.mu)
	defer sync.mutex_unlock(&g_rt.mu)
	g_rt.console = model
}

current_console :: proc() -> Console_Model {
	sync.mutex_lock(&g_rt.mu)
	defer sync.mutex_unlock(&g_rt.mu)
	return g_rt.console
}

set_gpu_hooks :: proc(hooks: Gpu_Hooks) {
	sync.mutex_lock(&g_rt.mu)
	defer sync.mutex_unlock(&g_rt.mu)
	g_rt.gpu_hooks = hooks
}

get_gpu_hooks :: proc() -> Gpu_Hooks {
	sync.mutex_lock(&g_rt.mu)
	defer sync.mutex_unlock(&g_rt.mu)
	return g_rt.gpu_hooks
}

set_main_image :: proc(base: uintptr) {
	sync.mutex_lock(&g_rt.mu)
	defer sync.mutex_unlock(&g_rt.mu)
	g_rt.main_image = base
}

main_image :: proc() -> (uintptr, bool) {
	sync.mutex_lock(&g_rt.mu)
	defer sync.mutex_unlock(&g_rt.mu)
	return g_rt.main_image, g_rt.main_image != 0
}

set_image_path :: proc(base: uintptr, path: string) {
	sync.mutex_lock(&g_rt.mu)
	defer sync.mutex_unlock(&g_rt.mu)
	if !g_rt.initialized {
		g_rt.images = make(map[uintptr]string)
		g_rt.host_modules = make(map[string]win32.HMODULE)
		g_rt.modules = make([dynamic]Hle_Module)
		g_rt.initialized = true
	}
	if old, ok := g_rt.images[base]; ok {
		delete(old)
	}
	g_rt.images[base] = strings.clone(path)
}

forget_image :: proc(base: uintptr) {
	sync.mutex_lock(&g_rt.mu)
	defer sync.mutex_unlock(&g_rt.mu)
	if old, ok := g_rt.images[base]; ok {
		delete(old)
		delete_key(&g_rt.images, base)
	}
}

image_path :: proc(base: uintptr, allocator := context.allocator) -> (string, bool) {
	sync.mutex_lock(&g_rt.mu)
	defer sync.mutex_unlock(&g_rt.mu)
	p, ok := g_rt.images[base]
	if !ok {
		return "", false
	}
	return strings.clone(p, allocator), true
}

image_named :: proc(file: string) -> (uintptr, bool) {
	sync.mutex_lock(&g_rt.mu)
	defer sync.mutex_unlock(&g_rt.mu)
	f_lower := strings.to_lower(file, context.temp_allocator)
	for base, path in g_rt.images {
		idx := strings.last_index_any(path, "/\\")
		base_name := path if idx < 0 else path[idx + 1:]
		if strings.to_lower(base_name, context.temp_allocator) == f_lower {
			return base, true
		}
	}
	return 0, false
}

set_title_dll_loader :: proc(
	loader: proc(user: rawptr, file: string) -> (uintptr, bool, bool),
	user: rawptr = nil,
) {
	sync.mutex_lock(&g_rt.mu)
	defer sync.mutex_unlock(&g_rt.mu)
	g_rt.title_dll_loader = loader
	g_rt.title_dll_loader_user = user
}

set_disable_thread_calls_hook :: proc(hook: proc(base: uintptr) -> bool) {
	sync.mutex_lock(&g_rt.mu)
	defer sync.mutex_unlock(&g_rt.mu)
	g_rt.disable_thread_calls = hook
}

set_title :: proc(info: Title_Info) {
	sync.mutex_lock(&g_rt.mu)
	defer sync.mutex_unlock(&g_rt.mu)
	destroy_title_info(&g_rt.title)
	g_rt.title = Title_Info{
		id            = info.id,
		store_id      = strings.clone(info.store_id),
		storage_bytes = info.storage_bytes,
		storage       = strings.clone(info.storage),
		saves         = strings.clone(info.saves),
	}
}

current_title :: proc(allocator := context.allocator) -> Title_Info {
	sync.mutex_lock(&g_rt.mu)
	defer sync.mutex_unlock(&g_rt.mu)
	return Title_Info{
		id            = g_rt.title.id,
		store_id      = strings.clone(g_rt.title.store_id, allocator),
		storage_bytes = g_rt.title.storage_bytes,
		storage       = strings.clone(g_rt.title.storage, allocator),
		saves         = strings.clone(g_rt.title.saves, allocator),
	}
}

// use_console_timers disables Windows power throttling and sets 1 ms timer
// resolution so Sleep/thread waits behave predictably as on console.
use_console_timers :: proc() {
	ProcessPowerThrottling :: 4
	POWER_THROTTLING_PROCESS_CURRENT_VERSION :: 1
	POWER_THROTTLING_PROCESS_EXECUTION_SPEED :: 0x1
	Power_Throttling_State :: struct {
		version:      u32,
		control_mask: u32,
		state_mask:   u32,
	}
	state := Power_Throttling_State{
		version      = POWER_THROTTLING_PROCESS_CURRENT_VERSION,
		control_mask = POWER_THROTTLING_PROCESS_EXECUTION_SPEED,
		state_mask   = 0,
	}
	_ = SetProcessInformation(
		win32.GetCurrentProcess(),
		ProcessPowerThrottling,
		&state,
		size_of(Power_Throttling_State),
	)
	_ = timeBeginPeriod(1)
}

// parse_manifest_xml extracts TitleId, StoreId, and PersistentLocalStorage/SizeMB
// from MicrosoftGame.config XML text.
parse_manifest_xml :: proc(xml: string, data_dir: string, allocator := context.allocator) -> Title_Info {
	decode_entities := proc(raw: string, alloc: runtime.Allocator) -> string {
		b := strings.builder_make(alloc)
		i := 0
		for i < len(raw) {
			if raw[i] == '&' {
				if semi := strings.index_byte(raw[i:], ';'); semi > 0 {
					ent := raw[i + 1 : i + semi]
					if ent == "amp" {
						strings.write_byte(&b, '&'); i += semi + 1; continue
					} else if ent == "lt" {
						strings.write_byte(&b, '<'); i += semi + 1; continue
					} else if ent == "gt" {
						strings.write_byte(&b, '>'); i += semi + 1; continue
					} else if ent == "quot" {
						strings.write_byte(&b, '"'); i += semi + 1; continue
					} else if ent == "apos" {
						strings.write_byte(&b, '\''); i += semi + 1; continue
					} else if len(ent) >= 2 && ent[0] == '#' {
						cp: u64 = 0
						ok := false
						if ent[1] == 'x' || ent[1] == 'X' {
							cp, ok = strconv.parse_u64_of_base(ent[2:], 16)
						} else {
							cp, ok = strconv.parse_u64_of_base(ent[1:], 10)
						}
						if ok && cp > 0 && cp <= 0x10FFFF {
							strings.write_rune(&b, rune(cp))
							i += semi + 1
							continue
						}
					}
				}
			}
			strings.write_byte(&b, raw[i])
			i += 1
		}
		return strings.to_string(b)
	}

	// Strip XML comments first into temp memory.
	cleaned_b := strings.builder_make(context.temp_allocator)
	p := 0
	for p < len(xml) {
		if strings.has_prefix(xml[p:], "<!--") {
			if end := strings.index(xml[p + 4:], "-->"); end >= 0 {
				p += 4 + end + 3
				continue
			}
			break
		}
		strings.write_byte(&cleaned_b, xml[p])
		p += 1
	}
	cleaned := strings.to_string(cleaned_b)

	find_tag_value :: proc(doc: string, tag: string) -> (string, bool) {
		open_a := fmt.tprintf("<%s>", tag)
		open_b := fmt.tprintf("<%s ", tag)
		close_t := fmt.tprintf("</%s>", tag)
		pos := strings.index(doc, open_a)
		gt_offset := 0
		if pos >= 0 {
			gt_offset = pos + len(open_a)
		} else {
			pos = strings.index(doc, open_b)
			if pos < 0 {
				return "", false
			}
			gt := strings.index_byte(doc[pos:], '>')
			if gt < 0 {
				return "", false
			}
			if gt > 0 && doc[pos + gt - 1] == '/' {
				return "", false
			}
			gt_offset = pos + gt + 1
		}
		end := strings.index(doc[gt_offset:], close_t)
		if end < 0 {
			return "", false
		}
		return strings.trim_space(doc[gt_offset : gt_offset + end]), true
	}

	info := Title_Info{}
	if tid_raw, ok := find_tag_value(cleaned, "TitleId"); ok {
		tid := decode_entities(tid_raw, context.temp_allocator)
		if parsed, ok_id := strconv.parse_u64_of_base(strings.trim_space(tid), 16); ok_id {
			info.id = u32(parsed)
		}
	}
	if sid_raw, ok := find_tag_value(cleaned, "StoreId"); ok {
		info.store_id = decode_entities(strings.trim_space(sid_raw), allocator)
	} else {
		info.store_id = strings.clone("", allocator)
	}
	if pls_raw, ok := find_tag_value(cleaned, "PersistentLocalStorage"); ok {
		if smb_raw, ok_sz := find_tag_value(pls_raw, "SizeMB"); ok_sz {
			if mb, ok_mb := strconv.parse_u64_of_base(strings.trim_space(smb_raw), 10); ok_mb {
				info.storage_bytes = mb << 20
			}
		}
	}

	if len(data_dir) > 0 && info.id != 0 {
		id_hex := fmt.tprintf("%08X", info.id)
		storage_p, _ := filepath.join({data_dir, "titles", id_hex, "storage"}, allocator)
		saves_p, _ := filepath.join({data_dir, "titles", id_hex, "saves"}, allocator)
		info.storage = storage_p
		info.saves = saves_p
	} else {
		info.storage = strings.clone("", allocator)
		info.saves = strings.clone("", allocator)
	}
	return info
}

// host_module loads a DLL strictly from System32 without holding g_rt.mu
// across LoadLibraryExW to avoid deadlocking under the OS loader lock.
host_module :: proc(dll: string) -> (win32.HMODULE, bool) {
	key := strings.to_lower(dll, context.temp_allocator)
	sync.mutex_lock(&g_rt.mu)
	if h, ok := g_rt.host_modules[key]; ok {
		sync.mutex_unlock(&g_rt.mu)
		return h, h != nil
	}
	sync.mutex_unlock(&g_rt.mu)

	wide_name := win32.utf8_to_wstring(key, context.temp_allocator)
	h := win32.LoadLibraryExW(wide_name, nil, transmute(win32.LoadLibraryEx_Flags)LOAD_LIBRARY_SEARCH_SYSTEM32)
	if h == nil {
		return nil, false
	}

	sync.mutex_lock(&g_rt.mu)
	defer sync.mutex_unlock(&g_rt.mu)
	if existing, ok := g_rt.host_modules[key]; ok {
		return existing, existing != nil
	}
	g_rt.host_modules[strings.clone(key)] = h
	return h, true
}

host_resolve_symbol :: proc(dll: string, name: string, ordinal: u16, by_ordinal: bool) -> (uintptr, bool) {
	mod, ok := host_module(dll)
	if !ok {
		return 0, false
	}
	if by_ordinal {
		p := win32.GetProcAddress(mod, cstring(rawptr(uintptr(ordinal))))
		return uintptr(p), p != nil
	}
	cname := strings.clone_to_cstring(name, context.temp_allocator)
	p := win32.GetProcAddress(mod, cname)
	return uintptr(p), p != nil
}

host_function :: proc(dll: string, name: string) -> (uintptr, bool) {
	return host_resolve_symbol(dll, name, 0, false)
}

registry_lookup :: proc(dll: string, symbol: string) -> (uintptr, bool) {
	if !g_rt.initialized {
		init_hle()
	}
	sync.mutex_lock(&g_rt.mu)
	defer sync.mutex_unlock(&g_rt.mu)
	for &m in g_rt.modules {
		if !module_serves(&m, dll) {
			continue
		}
		for exp in m.exports {
			if exp.name == symbol {
				return exp.address, true
			}
		}
	}
	return 0, false
}

find_module_by_handle :: proc(h: rawptr) -> (^Hle_Module, bool) {
	sync.mutex_lock(&g_rt.mu)
	defer sync.mutex_unlock(&g_rt.mu)
	for &m in g_rt.modules {
		if rawptr(&m) == h {
			return &m, true
		}
	}
	return nil, false
}

find_module_serving :: proc(dll: string) -> (^Hle_Module, bool) {
	sync.mutex_lock(&g_rt.mu)
	defer sync.mutex_unlock(&g_rt.mu)
	for &m in g_rt.modules {
		if module_serves(&m, dll) {
			return &m, true
		}
	}
	return nil, false
}

Hle_Resolver :: struct {
	policy: Host_Policy,
}

make_hle_resolver :: proc(policy: Host_Policy) -> Hle_Resolver {
	if !g_rt.initialized {
		init_hle()
	}
	return Hle_Resolver{policy = policy}
}

destroy_hle_resolver :: proc(r: ^Hle_Resolver, allocator := context.allocator) {
	destroy_host_policy(&r.policy, allocator)
}

hle_resolve :: proc(r: ^Hle_Resolver, dll: string, entry: ^vasperty_pe.Import_Entry) -> vasperty_loader.Resolution {
	sym_name := ""
	if entry.by_ordinal {
		sym_name = fmt.tprintf("#%d", entry.ordinal)
	} else {
		sym_name = entry.name
	}
	if addr, ok := registry_lookup(dll, sym_name); ok {
		return vasperty_loader.Resolution{found = true, address = addr, provenance = .Hle}
	}
	if host_policy_allows(&r.policy, dll) {
		if addr, ok := host_resolve_symbol(dll, entry.name, entry.ordinal, entry.by_ordinal); ok {
			return vasperty_loader.Resolution{found = true, address = addr, provenance = .Host}
		}
	}
	return vasperty_loader.Resolution{found = false}
}

@(private)
hle_resolver_trampoline :: proc(user_data: rawptr, dll: string, entry: ^vasperty_pe.Import_Entry) -> vasperty_loader.Resolution {
	r := cast(^Hle_Resolver)user_data
	return hle_resolve(r, dll, entry)
}

as_loader_resolver :: proc(r: ^Hle_Resolver) -> vasperty_loader.Import_Resolver {
	return vasperty_loader.Import_Resolver{
		user_data = rawptr(r),
		resolve   = hle_resolver_trampoline,
	}
}

register_module :: proc(name: string, dlls: []string, exports: []Hle_Export) {
	sync.mutex_lock(&g_rt.mu)
	defer sync.mutex_unlock(&g_rt.mu)
	d_copy := make([]string, len(dlls))
	copy(d_copy, dlls)
	e_copy := make([]Hle_Export, len(exports))
	copy(e_copy, exports)
	append(&g_rt.modules, Hle_Module{name = name, dlls = d_copy, exports = e_copy})
}

register_all_modules :: proc() {
	register_module("kernel", KERNEL_DLLS[:], KERNEL_EXPORTS[:])
	register_module("xgameruntime", XGAMERUNTIME_DLLS[:], XGAMERUNTIME_EXPORTS[:])
	register_module("gameinput", GAMEINPUT_DLLS[:], GAMEINPUT_EXPORTS[:])
	register_module("d3d12x", D3D12X_DLLS[:], D3D12X_EXPORTS[:])
	register_module("audio", AUDIO_DLLS[:], AUDIO_EXPORTS[:])
	register_module("dsp", DSP_DLLS[:], DSP_EXPORTS[:])
	register_module("xg", XG_DLLS[:], XG_EXPORTS[:])
	register_module("apu", APU_DLLS[:], APU_EXPORTS[:])
	register_module("media", MEDIA_DLLS[:], MEDIA_EXPORTS[:])
	register_module("dstorage", DSTORAGE_DLLS[:], DSTORAGE_EXPORTS[:])
	register_module("files", FILES_DLLS[:], FILES_EXPORTS[:])
	register_module("lifecycle", LIFECYCLE_DLLS[:], LIFECYCLE_EXPORTS[:])
	register_module("net", NET_DLLS[:], NET_EXPORTS[:])
	register_module("rpcrt4", RPCRT4_DLLS[:], RPCRT4_EXPORTS[:])
	register_module("xmem", XMEM_DLLS[:], XMEM_EXPORTS[:])
	register_module("device type", DEVICE_TYPE_DLLS[:], DEVICE_TYPE_EXPORTS[:])
	if ffx_serving() {
		register_module("fidelityfx", FIDELITYFX_DLLS[:], FIDELITYFX_EXPORTS[:])
	}
}

// load_title_file returns full file contents when readable from host FS.
@(private)
hle_read_file :: proc(path: string, allocator := context.allocator) -> ([]u8, bool) {
	data, err := os.read_entire_file(path, allocator)
	if err != nil {
		return nil, false
	}
	return data, true
}
