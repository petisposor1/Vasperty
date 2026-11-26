package vasperty_hle

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import win32 "core:sys/windows"
import vasperty_game "vasperty:game"

// All xgameruntime QueryApiImpl COM runtime providers + advapi32 ConsoleMode override.

// --- Provider / Interface Registry ---

Runtime_Interface_Entry :: struct {
	provider: Guid,
	iid:      Guid,
	object:   ^Runtime_Object,
}

find_runtime_interface :: proc(provider: Guid, iid: Guid) -> (^Runtime_Object, bool) {
	entries := [?]Runtime_Interface_Entry{
		// xasync
		{PROVIDER_XASYNC, PROVIDER_XASYNC, &XASYNC_OBJECT},
		// xuser
		{PROVIDER_XUSER, IID_XUSER, &XUSER_OBJECT},
		{PROVIDER_XUSER, PROVIDER_XUSER, &XUSER_OBJECT},
		{PROVIDER_XUSER, IID_XUSER_GAMERTAG, &XUSER_GAMERTAG_OBJECT},
		{PROVIDER_XUSER_DEVICE, IID_XUSER_DEVICE, &XUSER_DEVICE_OBJECT},
		// xsystem
		{PROVIDER_XSYSTEM, IID_XSYSTEM, &XSYSTEM_OBJECT},
		{PROVIDER_XSYSTEM, IID_XSYSTEM_2026, &XSYSTEM_OBJECT},
		{PROVIDER_ANALYTICS, PROVIDER_ANALYTICS, &XSYSTEM_ANALYTICS_OBJECT},
		// xgame
		{PROVIDER_XGAME_TITLE, IID_XGAME_TITLE, &XGAME_TITLE_OBJECT},
		{PROVIDER_XGAME_FEATURES, PROVIDER_XGAME_FEATURES, &XGAME_FEATURES_OBJECT},
		{PROVIDER_XGAME_INVITES, PROVIDER_XGAME_INVITES, &XGAME_INVITES_OBJECT},
		{PROVIDER_XGAME_EVENTS, PROVIDER_XGAME_EVENTS, &XGAME_EVENTS_OBJECT},
		// persistent local storage
		{PROVIDER_STORAGE, IID_STORAGE, &STORAGE_OBJECT},
		{PROVIDER_STORAGE, IID_STORAGE_2026, &STORAGE_OBJECT},
		// xnetworking
		{PROVIDER_XNET, PROVIDER_XNET, &XNET_OBJECT},
		{PROVIDER_XNET, IID_XNET_2026, &XNET_OBJECT},
		// xpackage
		{PROVIDER_XPACKAGE, IID_XPACKAGE_2026, &XPACKAGE_OBJECT},
		// display
		{PROVIDER_DISPLAY_HDR, IID_DISPLAY_HDR, &DISPLAY_HDR_OBJECT},
		{PROVIDER_DISPLAY_SHELL, PROVIDER_DISPLAY_SHELL, &DISPLAY_SHELL_OBJECT},
		{PROVIDER_DISPLAY_CAPTURE, IID_DISPLAY_CAPTURE_2026, &DISPLAY_CAPTURE_OBJECT},
		// xgamesave
		{PROVIDER_XGAMESAVE, PROVIDER_XGAMESAVE, &XGAMESAVE_OBJECT},
		{PROVIDER_XGAMESAVE, IID_XGAMESAVE_2026, &XGAMESAVE_OBJECT},
		// xstore
		{PROVIDER_XSTORE, IID_XSTORE_2026, &XSTORE_OBJECT},
		{PROVIDER_XSTORE, IID_XSTORE_DURABLES, &XSTORE_OBJECT},
		// xgameui
		{PROVIDER_XGAMEUI, IID_XGAMEUI_2026, &XGAMEUI_OBJECT},
		// speech
		{PROVIDER_SPEECH, IID_SPEECH, &SPEECH_OBJECT},
	}
	for e in entries {
		if guid_eq(e.provider, provider) && guid_eq(e.iid, iid) {
			return e.object, true
		}
	}
	return nil, false
}

// =============================================================================
// 1. xuser
// =============================================================================

PROVIDER_XUSER :: Guid{0x01acd177, 0x91f9, 0x4763, {0xa3, 0x8e, 0xcc, 0xbb, 0x55, 0xce, 0x32, 0xe0}}
IID_XUSER :: Guid{0xeb9bf948, 0x18dc, 0x4d82, {0xbb, 0xcc, 0x40, 0xe0, 0xa8, 0x09, 0xc4, 0xc0}}
IID_XUSER_GAMERTAG :: Guid{0xcef4fac0, 0x7676, 0x4a94, {0xa1, 0x19, 0x4c, 0x43, 0xf9, 0xeb, 0x5b, 0x74}}
PROVIDER_XUSER_DEVICE :: Guid{0x7d824997, 0x10dc, 0x45ab, {0x86, 0xb7, 0x27, 0x37, 0x76, 0x7c, 0x0b, 0xf1}}
IID_XUSER_DEVICE :: Guid{0x0cc6a956, 0xe7e1, 0x4fdf, {0x93, 0x41, 0x9d, 0x5d, 0xa6, 0x49, 0xeb, 0xc8}}

XUSER_NOT_FOUND :: HRESULT(-1994108668) // 0x89245104
XUSER_FAILED_TO_GET_TOKEN :: HRESULT(-1994108655) // 0x89245111
XUSER_XUID :: u64(0x0009000000000001)
XUSER_LOCAL_ID :: u64(1)

@(private) g_xuser_dummy: u8 = 0
@(private) g_xuser_add_id: u8 = 0
@(private) g_xuser_resolve_id: u8 = 0
@(private) g_xuser_token_id: u8 = 0

@(private) xuser_handle :: proc() -> rawptr { return rawptr(&g_xuser_dummy) }
@(private) xuser_dup :: proc "system" (_: ^Runtime_Object, _: rawptr, out: ^rawptr) -> HRESULT {
	context = hle_context()
	return put_ptr(out, xuser_handle())
}
@(private) xuser_close :: proc "system" (_: ^Runtime_Object, _: rawptr) {}
@(private) xuser_cmp :: proc "system" (_: ^Runtime_Object, a, b: rawptr) -> i32 {
	context = hle_context()
	return 0 if a == b else 1
}
@(private) xuser_add_async :: proc "system" (_: ^Runtime_Object, _: u32, b: ^Async_Block) -> HRESULT {
	context = hle_context()
	h := xuser_handle()
	return async_finished_with(b, rawptr(&g_xuser_add_id), S_OK, async_bytes(&h))
}
@(private) xuser_add_result :: proc "system" (_: ^Runtime_Object, b: ^Async_Block, out: ^rawptr) -> HRESULT {
	context = hle_context()
	return async_result_copy(b, rawptr(&g_xuser_add_id), out)
}
@(private) xuser_get_local_id :: proc "system" (_: ^Runtime_Object, _: rawptr, out: ^u64) -> HRESULT {
	context = hle_context()
	return put_ptr(out, XUSER_LOCAL_ID)
}
@(private) xuser_find_local :: proc "system" (_: ^Runtime_Object, id: u64, out: ^rawptr) -> HRESULT {
	context = hle_context()
	return put_ptr(out, xuser_handle()) if id == XUSER_LOCAL_ID else XUSER_NOT_FOUND
}
@(private) xuser_get_id :: proc "system" (_: ^Runtime_Object, _: rawptr, out: ^u64) -> HRESULT {
	context = hle_context()
	return put_ptr(out, XUSER_XUID)
}
@(private) xuser_find_id :: proc "system" (_: ^Runtime_Object, id: u64, out: ^rawptr) -> HRESULT {
	context = hle_context()
	return put_ptr(out, xuser_handle()) if id == XUSER_XUID else XUSER_NOT_FOUND
}
@(private) xuser_is_guest :: proc "system" (_: ^Runtime_Object, _: rawptr, out: ^bool) -> HRESULT {
	context = hle_context()
	return put_ptr(out, false)
}
@(private) xuser_state :: proc "system" (_: ^Runtime_Object, _: rawptr, out: ^u32) -> HRESULT {
	context = hle_context()
	return put_ptr(out, u32(0))
}
@(private) xuser_gamertag :: proc "system" (_: ^Runtime_Object, _: rawptr, comp: u32, sz: uint, buf: [^]u8, used: ^uint) -> HRESULT {
	context = hle_context()
	return put_string("" if comp == 2 else "Player", sz, buf, used)
}
@(private) xuser_age_group :: proc "system" (_: ^Runtime_Object, _: rawptr, out: ^u32) -> HRESULT {
	context = hle_context()
	return put_ptr(out, u32(3))
}
@(private) xuser_priv :: proc "system" (_: ^Runtime_Object, _: rawptr, _, _: u32, has: ^bool, reason: ^u32) -> HRESULT {
	context = hle_context()
	if reason != nil { reason^ = 0 }
	return put_ptr(has, true)
}
@(private) xuser_resolve_priv_async :: proc "system" (_: ^Runtime_Object, _: rawptr, _, _: u32, b: ^Async_Block) -> HRESULT {
	context = hle_context()
	return async_finished(b, rawptr(&g_xuser_resolve_id), S_OK)
}
@(private) xuser_resolve_priv_result :: proc "system" (_: ^Runtime_Object, b: ^Async_Block) -> HRESULT {
	context = hle_context()
	return XAsyncGetResult(b, rawptr(&g_xuser_resolve_id), 0, nil, nil)
}
@(private) xuser_token_async :: proc "system" (_: ^Runtime_Object, _: rawptr, _: u32, _, _: cstring, _: uint, _: rawptr, _: uint, _: rawptr, b: ^Async_Block) -> HRESULT {
	context = hle_context()
	return async_finished(b, rawptr(&g_xuser_token_id), XUSER_FAILED_TO_GET_TOKEN)
}
@(private) xuser_token_size :: proc "system" (_: ^Runtime_Object, b: ^Async_Block, out: ^uint) -> HRESULT {
	context = hle_context()
	return XAsyncGetResultSize(b, out)
}
@(private) xuser_token_result :: proc "system" (_: ^Runtime_Object, b: ^Async_Block, sz: uint, buf: rawptr, _: ^rawptr, used: ^uint) -> HRESULT {
	context = hle_context()
	return XAsyncGetResult(b, rawptr(&g_xuser_token_id), sz, buf, used)
}
@(private) xuser_register :: proc "system" (_: ^Runtime_Object, _, _, _: rawptr, out: ^u64) -> HRESULT {
	context = hle_context()
	return put_ptr(out, next_token())
}
@(private) xuser_unregister :: proc "system" (_: ^Runtime_Object, _: u64, _: bool) -> bool {
	context = hle_context()
	return true
}
@(private) xuser_find_device :: proc "system" (_: ^Runtime_Object, _: rawptr, out: ^rawptr) -> HRESULT {
	context = hle_context()
	return put_ptr(out, xuser_handle())
}

XUSER_VTABLE := [35]rawptr {
	rawptr(rt_missing), rawptr(rt_add_ref), rawptr(rt_add_ref),
	rawptr(xuser_dup), rawptr(xuser_close), rawptr(xuser_cmp),
	rawptr(rt_missing),
	rawptr(xuser_add_async), rawptr(xuser_add_result),
	rawptr(xuser_get_local_id), rawptr(xuser_find_local),
	rawptr(xuser_get_id), rawptr(xuser_find_id),
	rawptr(xuser_is_guest), rawptr(xuser_state), rawptr(xuser_gamertag),
	rawptr(rt_missing), rawptr(rt_missing), rawptr(rt_missing),
	rawptr(xuser_age_group), rawptr(xuser_priv),
	rawptr(xuser_resolve_priv_async), rawptr(xuser_resolve_priv_result),
	rawptr(xuser_token_async), rawptr(xuser_token_size), rawptr(xuser_token_result),
	rawptr(rt_missing), rawptr(rt_missing), rawptr(rt_missing),
	rawptr(rt_missing), rawptr(rt_missing), rawptr(rt_missing), rawptr(rt_missing),
	rawptr(xuser_register), rawptr(xuser_unregister),
}
XUSER_GAMERTAG_VTABLE := [4]rawptr{rawptr(rt_missing), rawptr(rt_add_ref), rawptr(rt_add_ref), rawptr(xuser_gamertag)}
XUSER_DEVICE_VTABLE := [6]rawptr{rawptr(rt_missing), rawptr(rt_add_ref), rawptr(rt_add_ref), rawptr(xuser_find_device), rawptr(xuser_register), rawptr(xuser_unregister)}

XUSER_OBJECT := Runtime_Object{vtable = raw_data(XUSER_VTABLE[:]), area = "user"}
XUSER_GAMERTAG_OBJECT := Runtime_Object{vtable = raw_data(XUSER_GAMERTAG_VTABLE[:]), area = "user gamertag"}
XUSER_DEVICE_OBJECT := Runtime_Object{vtable = raw_data(XUSER_DEVICE_VTABLE[:]), area = "user devices"}

// =============================================================================
// 2. xsystem (+ advapi32 ConsoleMode registry overrides)
// =============================================================================

PROVIDER_XSYSTEM :: Guid{0xe349bd1a, 0xfc20, 0x4e40, {0xb9, 0x9c, 0x41, 0x78, 0xcc, 0x6b, 0x40, 0x9f}}
IID_XSYSTEM :: Guid{0x6fd71f09, 0x7513, 0x49f0, {0x89, 0xbc, 0xbf, 0xaf, 0x5d, 0xf6, 0xf8, 0x52}}
IID_XSYSTEM_2026 :: Guid{0x1861cf2e, 0xe18b, 0x4834, {0xa9, 0xf5, 0xb4, 0xa4, 0xe6, 0xef, 0xb4, 0xcf}}
PROVIDER_ANALYTICS :: Guid{0xb884675d, 0xb738, 0x4a9c, {0x81, 0x5d, 0x9a, 0x9a, 0x1e, 0x0c, 0x6c, 0x9b}}

XSYS_CONSOLE_ID :: "00000000000000000000000000000000000001"
XSYS_SANDBOX :: "RETAIL"
XSYS_DEVICE_ID :: "VkljdG9yeSBvZmZsaW5lIGRldmljZSBpZGVudGl0eSE="

XSystem_Version :: struct {
	major, minor, build, revision: u16,
}

XSystem_Analytics_Info :: struct {
	os:         XSystem_Version,
	hosting_os: XSystem_Version,
	family:     [64]u8,
	form:       [64]u8,
}

@(private) xs_console_id :: proc "system" (_: ^Runtime_Object, sz: uint, buf: [^]u8, used: ^uint) -> HRESULT {
	context = hle_context()
	return put_string(XSYS_CONSOLE_ID, sz, buf, used)
}
@(private) xs_sandbox_id :: proc "system" (_: ^Runtime_Object, sz: uint, buf: [^]u8, used: ^uint) -> HRESULT {
	context = hle_context()
	return put_string(XSYS_SANDBOX, sz, buf, used)
}
@(private) xs_device_id :: proc "system" (_: ^Runtime_Object, sz: uint, buf: [^]u8, used: ^uint) -> HRESULT {
	context = hle_context()
	return put_string(XSYS_DEVICE_ID, sz, buf, used)
}
@(private) xs_analytics :: proc "system" (_: ^Runtime_Object, out: ^XSystem_Analytics_Info) -> ^XSystem_Analytics_Info {
	context = hle_context()
	if out == nil {
		return nil
	}
	info := XSystem_Analytics_Info{
		os         = {10, 0, 22000, 0},
		hosting_os = {10, 0, 22000, 0},
	}
	copy(info.family[:], "Xbox")
	copy(info.form[:], console_name(current_console()))
	out^ = info
	return out
}

XSYSTEM_VTABLE := [6]rawptr{
	rawptr(rt_missing), rawptr(rt_add_ref), rawptr(rt_add_ref),
	rawptr(xs_console_id), rawptr(xs_sandbox_id), rawptr(xs_device_id),
}
XSYSTEM_ANALYTICS_VTABLE := [4]rawptr{
	rawptr(rt_missing), rawptr(rt_add_ref), rawptr(rt_add_ref), rawptr(xs_analytics),
}
XSYSTEM_OBJECT := Runtime_Object{vtable = raw_data(XSYSTEM_VTABLE[:]), area = "system"}
XSYSTEM_ANALYTICS_OBJECT := Runtime_Object{vtable = raw_data(XSYSTEM_ANALYTICS_VTABLE[:]), area = "analytics"}

// Registry ConsoleMode override
@(private) OEM_REG_KEY_SENTINEL: u8 = 0
@(private) oem_key :: proc() -> rawptr { return rawptr(&OEM_REG_KEY_SENTINEL) }
REG_HKEY_LOCAL_MACHINE :: uintptr(0xFFFFFFFF80000002)

console_mode_dword :: proc(m: Console_Model) -> u32 {
	return 0x64 if m == .Series_X else 0x60
}

@(private)
wide_eq_ascii_ci :: proc(p: [^]u16, expected: string) -> bool {
	if p == nil {
		return false
	}
	s := wptr_to_string(p, context.temp_allocator)
	return strings.equal_fold(s, expected)
}

@(private)
reg_open_check :: proc(root: rawptr, sub: [^]u16, out: ^rawptr) -> (u32, bool) {
	if root == oem_key() {
		return 2, true // ERROR_FILE_NOT_FOUND
	}
	if uintptr(root) == REG_HKEY_LOCAL_MACHINE &&
		wide_eq_ascii_ci(sub, `Software\Microsoft\Windows NT\CurrentVersion\OEM`) &&
		out != nil {
		out^ = oem_key()
		return 0, true
	}
	return 0, false
}

RegOpenKeyW :: proc "system" (root: rawptr, sub: [^]u16, out: ^rawptr) -> u32 {
	context = hle_context()
	if rc, handled := reg_open_check(root, sub, out); handled {
		return rc
	}
	fn_addr, ok := host_function("advapi32.dll", "RegOpenKeyW")
	if !ok { return 2 }
	fn := cast(proc "system" (rawptr, [^]u16, ^rawptr) -> u32)rawptr(fn_addr)
	return fn(root, sub, out)
}

RegOpenKeyExW :: proc "system" (root: rawptr, sub: [^]u16, opts: u32, sam: u32, out: ^rawptr) -> u32 {
	context = hle_context()
	if rc, handled := reg_open_check(root, sub, out); handled {
		return rc
	}
	fn_addr, ok := host_function("advapi32.dll", "RegOpenKeyExW")
	if !ok { return 2 }
	fn := cast(proc "system" (rawptr, [^]u16, u32, u32, ^rawptr) -> u32)rawptr(fn_addr)
	return fn(root, sub, opts, sam, out)
}

RegQueryValueExW :: proc "system" (key: rawptr, name: [^]u16, reserved: ^u32, kind: ^u32, data: [^]u8, size: ^u32) -> u32 {
	context = hle_context()
	if key != oem_key() {
		fn_addr, ok := host_function("advapi32.dll", "RegQueryValueExW")
		if !ok { return 2 }
		fn := cast(proc "system" (rawptr, [^]u16, ^u32, ^u32, [^]u8, ^u32) -> u32)rawptr(fn_addr)
		return fn(key, name, reserved, kind, data, size)
	}
	if !wide_eq_ascii_ci(name, "ConsoleMode") {
		return 2
	}
	if data != nil && size == nil {
		return 87
	}
	if kind != nil {
		kind^ = 4 // REG_DWORD
	}
	if size == nil {
		return 0
	}
	room := size^
	size^ = 4
	if data == nil {
		return 0
	}
	if room < 4 {
		return 234 // ERROR_MORE_DATA
	}
	v := console_mode_dword(current_console())
	mem.copy(data, &v, 4)
	return 0
}

RegCloseKey :: proc "system" (key: rawptr) -> u32 {
	context = hle_context()
	if key == oem_key() {
		return 0
	}
	fn_addr, ok := host_function("advapi32.dll", "RegCloseKey")
	if !ok { return 0 }
	fn := cast(proc "system" (rawptr) -> u32)rawptr(fn_addr)
	return fn(key)
}

DEVICE_TYPE_DLLS := [?]string{"advapi32.dll", "api-ms-win-core-registry-*"}
DEVICE_TYPE_EXPORTS := [?]Hle_Export {
	{name = "RegOpenKeyW", address = uintptr(rawptr(RegOpenKeyW))},
	{name = "RegOpenKeyExW", address = uintptr(rawptr(RegOpenKeyExW))},
	{name = "RegQueryValueExW", address = uintptr(rawptr(RegQueryValueExW))},
	{name = "RegCloseKey", address = uintptr(rawptr(RegCloseKey))},
}

// =============================================================================
// 3. xgame
// =============================================================================

PROVIDER_XGAME_TITLE :: Guid{0x973a344e, 0x24bf, 0x4d0f, {0x84, 0x57, 0x56, 0xc5, 0x34, 0x89, 0x2b, 0x29}}
IID_XGAME_TITLE :: Guid{0x2549f142, 0x6419, 0x4a06, {0x97, 0xb5, 0x93, 0x1a, 0xab, 0x7c, 0x2f, 0x34}}
PROVIDER_XGAME_FEATURES :: Guid{0x8836fe87, 0xedb9, 0x4fe3, {0x8d, 0xad, 0x05, 0xf0, 0xd2, 0xcd, 0x5b, 0x40}}
PROVIDER_XGAME_INVITES :: Guid{0x0651aae2, 0x4012, 0x4077, {0xbf, 0x84, 0x8b, 0x90, 0x97, 0x09, 0x0e, 0x2c}}
PROVIDER_XGAME_EVENTS :: Guid{0xbbfbdcc7, 0xbfe7, 0x409b, {0xa5, 0xca, 0xed, 0xf0, 0x54, 0x96, 0x0b, 0x4d}}

@(private) xgame_title_id :: proc "system" (_: ^Runtime_Object, out: ^u32) -> HRESULT {
	context = hle_context()
	return put_ptr(out, current_title(context.temp_allocator).id)
}
@(private) xgame_launch_new :: proc "system" (_: ^Runtime_Object, exe: cstring, args: cstring, _user: rawptr) {
	context = hle_context()
	_ = exe; _ = args
	end_title_and_exit()
}
@(private) xgame_feature_avail :: proc "system" (_: ^Runtime_Object, feature: u32) -> bool {
	context = hle_context()
	// Users=18, Package=19, Store=15, GameSave=12, Networking=13, TaskQueue=1, Display=11, GameUi=14, Speech=17
	switch feature {
	case 1, 11, 12, 13, 14, 15, 17, 18, 19:
		return true
	}
	return false
}
@(private) xgame_reg_invite :: proc "system" (_: ^Runtime_Object, _, _, _: rawptr, out: ^u64) -> HRESULT {
	context = hle_context()
	return put_ptr(out, next_token())
}
@(private) xgame_unreg_invite :: proc "system" (_: ^Runtime_Object, _: u64, _: bool) -> bool { context = hle_context(); return true }
@(private) xgame_write_event :: proc "system" (_: ^Runtime_Object, _: rawptr, _, _: cstring) -> HRESULT { context = hle_context(); return S_OK }

XGAME_TITLE_VTABLE := [5]rawptr{rawptr(rt_missing), rawptr(rt_add_ref), rawptr(rt_add_ref), rawptr(xgame_title_id), rawptr(xgame_launch_new)}
XGAME_FEATURES_VTABLE := [4]rawptr{rawptr(rt_missing), rawptr(rt_add_ref), rawptr(rt_add_ref), rawptr(xgame_feature_avail)}
XGAME_INVITES_VTABLE := [5]rawptr{rawptr(rt_missing), rawptr(rt_add_ref), rawptr(rt_add_ref), rawptr(xgame_reg_invite), rawptr(xgame_unreg_invite)}
XGAME_EVENTS_VTABLE := [4]rawptr{rawptr(rt_missing), rawptr(rt_add_ref), rawptr(rt_add_ref), rawptr(xgame_write_event)}

XGAME_TITLE_OBJECT := Runtime_Object{vtable = raw_data(XGAME_TITLE_VTABLE[:]), area = "title"}
XGAME_FEATURES_OBJECT := Runtime_Object{vtable = raw_data(XGAME_FEATURES_VTABLE[:]), area = "features"}
XGAME_INVITES_OBJECT := Runtime_Object{vtable = raw_data(XGAME_INVITES_VTABLE[:]), area = "invites"}
XGAME_EVENTS_OBJECT := Runtime_Object{vtable = raw_data(XGAME_EVENTS_VTABLE[:]), area = "events"}

// =============================================================================
// 4. storage (Persistent Local Storage)
// =============================================================================

PROVIDER_STORAGE :: Guid{0xf4faf4d4, 0x2d04, 0x4fce, {0xb3, 0xe0, 0x47, 0x4a, 0x71, 0x3a, 0x3e, 0x84}}
IID_STORAGE :: Guid{0xd29411df, 0x0794, 0x4553, {0x8b, 0x27, 0x95, 0xfc, 0x02, 0xd0, 0xf7, 0x5d}}
IID_STORAGE_2026 :: Guid{0x41a4e10c, 0x5a7e, 0x41d9, {0x8c, 0x37, 0x37, 0xbd, 0xe6, 0x2a, 0x07, 0xd6}}

Storage_Space_Info :: struct {
	available_free: u64,
	total_free:     u64,
	used:           u64,
	total:          u64,
}

@(private) g_storage_prompt_id: u8 = 0

@(private)
dir_used_bytes :: proc(dir: string) -> u64 {
	if len(dir) == 0 || !os.exists(dir) {
		return 0
	}
	f, err := os.open(dir)
	if err != nil {
		return 0
	}
	defer os.close(f)
	entries, derr := os.read_dir(f, -1, context.temp_allocator)
	if derr != nil {
		return 0
	}
	total: u64 = 0
	for e in entries {
		if e.type == .Directory {
			total += dir_used_bytes(e.fullpath)
		} else {
			total += u64(max(e.size, 0))
		}
	}
	return total
}

disk_free_bytes :: proc(path: string) -> u64 {
	if len(path) == 0 {
		return u64(1) << 40
	}
	wpath := win32.utf8_to_wstring(path, context.temp_allocator)
	avail, total, free_b: win32.ULARGE_INTEGER
	if win32.GetDiskFreeSpaceExW(wpath, &avail, &total, &free_b) {
		return u64(avail)
	}
	return u64(1) << 40
}

@(private)
storage_folder :: proc(allocator := context.allocator) -> (string, bool) {
	t := current_title(context.temp_allocator)
	if len(t.storage) == 0 {
		return "", false
	}
	letter, ok := mount_virtual_drive(t.storage)
	if !ok {
		return "", false
	}
	return fmt.aprintf("%c:\\", letter, allocator = allocator), true
}

@(private)
storage_space :: proc() -> Storage_Space_Info {
	t := current_title(context.temp_allocator)
	used := dir_used_bytes(t.storage)
	free_quota := t.storage_bytes - min(t.storage_bytes, used)
	avail := min(free_quota, disk_free_bytes(t.storage))
	return Storage_Space_Info{
		available_free = avail,
		total_free     = free_quota,
		used           = used,
		total          = t.storage_bytes,
	}
}

@(private) storage_path_size :: proc "system" (_: ^Runtime_Object, out: ^uint) -> HRESULT {
	context = hle_context()
	f, ok := storage_folder(context.temp_allocator)
	if !ok { return NOT_SUPPORTED }
	return put_ptr(out, uint(len(f) + 1))
}
@(private) storage_path :: proc "system" (_: ^Runtime_Object, sz: uint, buf: [^]u8, used: ^uint) -> HRESULT {
	context = hle_context()
	f, ok := storage_folder(context.temp_allocator)
	if !ok { return NOT_SUPPORTED }
	if sz <= uint(len(f)) {
		return E_FAIL
	}
	return put_string(f, sz, buf, used)
}
@(private) storage_space_info :: proc "system" (_: ^Runtime_Object, out: ^Storage_Space_Info) -> HRESULT {
	context = hle_context()
	return put_ptr(out, storage_space())
}
@(private) storage_prompt_async :: proc "system" (_: ^Runtime_Object, bytes: u64, b: ^Async_Block) -> HRESULT {
	context = hle_context()
	hr := S_OK if bytes <= storage_space().total_free else E_ABORT
	return async_finished(b, rawptr(&g_storage_prompt_id), hr)
}
@(private) storage_prompt_result :: proc "system" (_: ^Runtime_Object, b: ^Async_Block) -> HRESULT {
	context = hle_context()
	return XAsyncGetResult(b, rawptr(&g_storage_prompt_id), 0, nil, nil)
}

STORAGE_VTABLE := [8]rawptr{
	rawptr(rt_missing), rawptr(rt_add_ref), rawptr(rt_add_ref),
	rawptr(storage_path_size), rawptr(storage_path), rawptr(storage_space_info),
	rawptr(storage_prompt_async), rawptr(storage_prompt_result),
}
STORAGE_OBJECT := Runtime_Object{vtable = raw_data(STORAGE_VTABLE[:]), area = "persistent local storage"}

// =============================================================================
// 5. xnetworking
// =============================================================================

PROVIDER_XNET :: Guid{0x37e56907, 0x2f10, 0x41e8, {0xb7, 0x2f, 0x36, 0xed, 0xb1, 0x85, 0x33, 0x1a}}
IID_XNET_2026 :: Guid{0xbf2346b2, 0x39af, 0x4658, {0xb5, 0xea, 0x44, 0x71, 0x3c, 0x7e, 0x83, 0xb3}}
XNET_UNREACHABLE :: HRESULT(-2147023665) // 0x800704CF

Connectivity_Hint :: struct {
	level:                  u32,
	cost:                   u32,
	interface_type:         u32,
	initialized:            bool,
	approaching_data_limit: bool,
	over_data_limit:        bool,
	roaming:                bool,
}

@(private) g_xnet_port_id: u8 = 0
@(private) g_xnet_sec_id: u8 = 0

@(private) xnet_udp_port :: proc "system" (_: ^Runtime_Object, out: ^u16) -> HRESULT { context = hle_context(); return put_ptr(out, u16(3074)) }
@(private) xnet_udp_port_async :: proc "system" (_: ^Runtime_Object, b: ^Async_Block) -> HRESULT {
	context = hle_context()
	p: u16 = 3074
	return async_finished_with(b, rawptr(&g_xnet_port_id), S_OK, async_bytes(&p))
}
@(private) xnet_udp_port_result :: proc "system" (_: ^Runtime_Object, b: ^Async_Block, out: ^u16) -> HRESULT {
	context = hle_context()
	return async_result_copy(b, rawptr(&g_xnet_port_id), out)
}
@(private) xnet_sec_async :: proc "system" (_: ^Runtime_Object, _url: cstring, b: ^Async_Block) -> HRESULT {
	context = hle_context()
	return async_finished(b, rawptr(&g_xnet_sec_id), XNET_UNREACHABLE)
}
@(private) xnet_sec_utf16_async :: proc "system" (_: ^Runtime_Object, _url: [^]u16, b: ^Async_Block) -> HRESULT {
	context = hle_context()
	return async_finished(b, rawptr(&g_xnet_sec_id), XNET_UNREACHABLE)
}
@(private) xnet_sec_size :: proc "system" (_: ^Runtime_Object, b: ^Async_Block, out: ^uint) -> HRESULT {
	context = hle_context()
	return XAsyncGetResultSize(b, out)
}
@(private) xnet_sec_result :: proc "system" (_: ^Runtime_Object, b: ^Async_Block, sz: uint, used: ^uint, buf: [^]u8, _: ^rawptr) -> HRESULT {
	context = hle_context()
	return XAsyncGetResult(b, rawptr(&g_xnet_sec_id), sz, rawptr(buf), used)
}
@(private) xnet_verify_cert :: proc "system" (_: ^Runtime_Object, _, _: rawptr) -> HRESULT { context = hle_context(); return XNET_UNREACHABLE }
@(private) xnet_conn_hint :: proc "system" (_: ^Runtime_Object, out: ^Connectivity_Hint) -> HRESULT {
	context = hle_context()
	return put_ptr(out, Connectivity_Hint{level = 1, initialized = true})
}
@(private) xnet_reg :: proc "system" (_: ^Runtime_Object, _, _, _: rawptr, out: ^u64) -> HRESULT { context = hle_context(); return put_ptr(out, next_token()) }
@(private) xnet_unreg :: proc "system" (_: ^Runtime_Object, _: u64, _: bool) -> bool { context = hle_context(); return true }

XNET_VTABLE := [18]rawptr{
	rawptr(rt_missing), rawptr(rt_add_ref), rawptr(rt_add_ref),
	rawptr(xnet_udp_port), rawptr(xnet_udp_port_async), rawptr(xnet_udp_port_result),
	rawptr(xnet_reg), rawptr(xnet_unreg),
	rawptr(xnet_sec_async), rawptr(xnet_sec_size), rawptr(xnet_sec_result),
	rawptr(xnet_sec_utf16_async), rawptr(xnet_sec_size), rawptr(xnet_sec_result),
	rawptr(xnet_verify_cert), rawptr(xnet_conn_hint),
	rawptr(xnet_reg), rawptr(xnet_unreg),
}
XNET_OBJECT := Runtime_Object{vtable = raw_data(XNET_VTABLE[:]), area = "networking"}

// =============================================================================
// 6. xpackage
// =============================================================================

PROVIDER_XPACKAGE :: Guid{0xaf406016, 0xe850, 0x4aa8, {0xa8, 0x8d, 0x2f, 0x3d, 0xcb, 0x9d, 0xac, 0x7e}}
IID_XPACKAGE_2026 :: Guid{0x0b9d556e, 0xab70, 0x43f4, {0xba, 0xa0, 0x99, 0x99, 0xac, 0x4c, 0xb0, 0x40}}
XPACKAGE_NO_PACKAGE :: HRESULT(-1994108408) // 0x89245208

XPackage_Progress :: struct {
	total_bytes:     u64,
	installed_bytes: u64,
	launch_bytes:    u64,
	launchable:      bool,
	completed:       bool,
}

@(private) g_xpkg_mon_dummy: u8 = 0
@(private) g_xpkg_install_id: u8 = 0
@(private) g_xpkg_mount_id: u8 = 0

xpackage_identifier :: proc(allocator := context.allocator) -> string {
	return fmt.aprintf("%08X", current_title(context.temp_allocator).id, allocator = allocator)
}
@(private) xpkg_is_ours :: proc(id: cstring) -> bool {
	s, ok := cstr_to_string(id)
	return ok && s == xpackage_identifier(context.temp_allocator)
}
@(private) xpkg_cur_id :: proc "system" (_: ^Runtime_Object, sz: uint, buf: [^]u8) -> HRESULT {
	context = hle_context()
	return put_string(xpackage_identifier(context.temp_allocator), sz, buf, nil)
}
@(private) xpkg_is_packaged :: proc "system" (_: ^Runtime_Object) -> bool { context = hle_context(); return true }
@(private) xpkg_create_mon :: proc "system" (_: ^Runtime_Object, id: cstring, _sc: u32, _s: rawptr, _iv: u32, _q: rawptr, out: ^rawptr) -> HRESULT {
	context = hle_context()
	if !xpkg_is_ours(id) { return XPACKAGE_NO_PACKAGE }
	return put_ptr(out, rawptr(&g_xpkg_mon_dummy))
}
@(private) xpkg_close_mon :: proc "system" (_: ^Runtime_Object, _: rawptr) {}
@(private) xpkg_progress :: proc "system" (_: ^Runtime_Object, _: rawptr, out: ^XPackage_Progress) {
	context = hle_context()
	b := u64(0)
	if base, ok := main_image(); ok {
		if exe_p, has := image_path(base, context.temp_allocator); has {
			b = dir_used_bytes(filepath.dir(exe_p))
		}
	}
	_ = put_ptr(out, XPackage_Progress{total_bytes = b, installed_bytes = b, launch_bytes = b, launchable = true, completed = true})
}
@(private) xpkg_reg_prog :: proc "system" (_: ^Runtime_Object, _, _, _: rawptr, out: ^u64) -> HRESULT { context = hle_context(); return put_ptr(out, next_token()) }
@(private) xpkg_unreg_prog :: proc "system" (_: ^Runtime_Object, _: rawptr, _: u64, _: bool) -> bool { context = hle_context(); return true }
@(private) xpkg_find_avail :: proc "system" (_: ^Runtime_Object, id: cstring, _: u32, _: rawptr, out: ^u32) -> HRESULT {
	context = hle_context()
	if !xpkg_is_ours(id) { return XPACKAGE_NO_PACKAGE }
	return put_ptr(out, u32(0))
}
@(private) xpkg_chg_order :: proc "system" (_: ^Runtime_Object, id: cstring, _: u32, _: rawptr) -> HRESULT {
	context = hle_context()
	return S_OK if xpkg_is_ours(id) else XPACKAGE_NO_PACKAGE
}
@(private) xpkg_install_async :: proc "system" (_: ^Runtime_Object, id: cstring, _: u32, _: rawptr, _: u32, _: bool, b: ^Async_Block) -> HRESULT {
	context = hle_context()
	if xpkg_is_ours(id) {
		m := rawptr(&g_xpkg_mon_dummy)
		return async_finished_with(b, rawptr(&g_xpkg_install_id), S_OK, async_bytes(&m))
	}
	return async_finished(b, rawptr(&g_xpkg_install_id), XPACKAGE_NO_PACKAGE)
}
@(private) xpkg_install_res :: proc "system" (_: ^Runtime_Object, b: ^Async_Block, out: ^rawptr) -> HRESULT {
	context = hle_context()
	return async_result_copy(b, rawptr(&g_xpkg_install_id), out)
}
@(private) xpkg_est_dl :: proc "system" (_: ^Runtime_Object, id: cstring, _: u32, _: rawptr, bytes: ^u64, confirm: ^bool) -> HRESULT {
	context = hle_context()
	if !xpkg_is_ours(id) { return XPACKAGE_NO_PACKAGE }
	if confirm != nil { confirm^ = false }
	return put_ptr(bytes, u64(0))
}
@(private) xpkg_uninstall_chunks :: proc "system" (_: ^Runtime_Object, id: cstring, _: u32, _: rawptr) -> HRESULT {
	context = hle_context()
	return S_OK if xpkg_is_ours(id) else XPACKAGE_NO_PACKAGE
}
@(private) xpkg_mount_path :: proc "system" (_: ^Runtime_Object, _: rawptr, _: uint, _: [^]u8) -> HRESULT { context = hle_context(); return E_INVALIDARG }
@(private) xpkg_close_mount :: proc "system" (_: ^Runtime_Object, _: rawptr) {}
@(private) xpkg_uninstall_pkg :: proc "system" (_: ^Runtime_Object, _: cstring) -> bool { context = hle_context(); return false }
@(private) xpkg_mount_async :: proc "system" (_: ^Runtime_Object, _: cstring, b: ^Async_Block) -> HRESULT {
	context = hle_context()
	return async_finished(b, rawptr(&g_xpkg_mount_id), XPACKAGE_NO_PACKAGE)
}
@(private) xpkg_mount_res :: proc "system" (_: ^Runtime_Object, b: ^Async_Block, out: ^rawptr) -> HRESULT {
	context = hle_context()
	return async_result_copy(b, rawptr(&g_xpkg_mount_id), out)
}
@(private) xpkg_enum :: proc "system" (_: ^Runtime_Object, _, _: u32, _, _: rawptr) -> HRESULT { context = hle_context(); return S_OK }

XPACKAGE_VTABLE := [40]rawptr{
	rawptr(rt_missing), rawptr(rt_add_ref), rawptr(rt_add_ref),
	rawptr(xpkg_cur_id), rawptr(xpkg_is_packaged), rawptr(xpkg_create_mon), rawptr(xpkg_close_mon), rawptr(xpkg_progress),
	rawptr(rt_missing), rawptr(xpkg_reg_prog), rawptr(xpkg_unreg_prog), rawptr(rt_missing), rawptr(xpkg_find_avail),
	rawptr(rt_missing), rawptr(xpkg_chg_order), rawptr(rt_missing), rawptr(xpkg_install_async), rawptr(xpkg_install_res),
	rawptr(xpkg_est_dl), rawptr(xpkg_uninstall_chunks),
	rawptr(rt_missing), rawptr(rt_missing), rawptr(rt_missing), rawptr(rt_missing), rawptr(rt_missing),
	rawptr(xpkg_mount_path), rawptr(xpkg_close_mount),
	rawptr(rt_missing), rawptr(rt_missing), rawptr(rt_missing), rawptr(rt_missing), rawptr(rt_missing),
	rawptr(rt_missing), rawptr(rt_missing), rawptr(xpkg_uninstall_pkg),
	rawptr(rt_missing), rawptr(rt_missing), rawptr(xpkg_mount_async), rawptr(xpkg_mount_res), rawptr(xpkg_enum),
}
XPACKAGE_OBJECT := Runtime_Object{vtable = raw_data(XPACKAGE_VTABLE[:]), area = "package"}

// =============================================================================
// 7. display
// =============================================================================

PROVIDER_DISPLAY_HDR :: Guid{0x03f0fe74, 0xfdd9, 0x4e5c, {0xb6, 0x30, 0xf9, 0x33, 0x9c, 0x47, 0xac, 0xc5}}
IID_DISPLAY_HDR :: Guid{0x35f07670, 0x706e, 0x4bfb, {0x94, 0x76, 0x09, 0x07, 0x98, 0xc5, 0xeb, 0xf3}}
PROVIDER_DISPLAY_SHELL :: Guid{0x1b339674, 0x328d, 0x4283, {0xa2, 0x00, 0x31, 0x71, 0xf1, 0x8d, 0x36, 0x39}}
PROVIDER_DISPLAY_CAPTURE :: Guid{0xa4f1aee2, 0x4bf1, 0x4485, {0xb0, 0x08, 0xa7, 0xc2, 0x6d, 0x52, 0xac, 0x27}}
IID_DISPLAY_CAPTURE_2026 :: Guid{0x22e672d7, 0xb4e3, 0x406c, {0xbd, 0x50, 0x8f, 0x0d, 0x25, 0x23, 0x6f, 0x9e}}

@(private) Power_Reason_Context :: struct {
	version: u32,
	flags:   u32,
	reason:  win32.LPCWSTR,
}
@(private) g_disp_deferral_dummy: u8 = 0

@(private) disp_try_hdr :: proc "system" (_: ^Runtime_Object, _pref: u32, _info: rawptr) -> u32 { context = hle_context(); return 2 }
@(private) disp_launch_uri :: proc "system" (_: ^Runtime_Object, _user: rawptr, _uri: cstring) -> HRESULT { context = hle_context(); return NOT_SUPPORTED }
@(private) disp_acquire_deferral :: proc "system" (_: ^Runtime_Object, out: ^rawptr) -> HRESULT {
	context = hle_context()
	if out == nil { return E_INVALIDARG }
	if addr, ok := host_function("kernel32.dll", "PowerCreateRequest"); ok {
		if set_addr, ok2 := host_function("kernel32.dll", "PowerSetRequest"); ok2 {
			pcreate := cast(proc "system" (^Power_Reason_Context) -> win32.HANDLE)rawptr(addr)
			pset := cast(proc "system" (win32.HANDLE, i32) -> win32.BOOL)rawptr(set_addr)
			ctx := Power_Reason_Context{
				version = 0,
				flags   = 1,
				reason  = win32.utf8_to_wstring("Title display deferral", context.temp_allocator),
			}
			req := pcreate(&ctx)
			if uintptr(req) != ~uintptr(0) && req != nil {
				if pset(req, 0) { // PowerRequestDisplayRequired = 0
					out^ = rawptr(req)
					return S_OK
				}
				_ = win32.CloseHandle(req)
			}
		}
	}
	out^ = rawptr(&g_disp_deferral_dummy)
	return S_OK
}
@(private) disp_close_deferral :: proc "system" (_: ^Runtime_Object, h: rawptr) {
	context = hle_context()
	if h == nil || h == rawptr(&g_disp_deferral_dummy) {
		return
	}
	if clr_addr, ok := host_function("kernel32.dll", "PowerClearRequest"); ok {
		pclr := cast(proc "system" (win32.HANDLE, i32) -> win32.BOOL)rawptr(clr_addr)
		_ = pclr(win32.HANDLE(h), 0)
	}
	_ = win32.CloseHandle(win32.HANDLE(h))
}
@(private) disp_screenshot :: proc "system" (_: ^Runtime_Object, _user: rawptr, _res: rawptr) -> HRESULT { context = hle_context(); return NOT_SUPPORTED }

DISPLAY_HDR_VTABLE := [5]rawptr{rawptr(rt_missing), rawptr(rt_add_ref), rawptr(rt_add_ref), rawptr(rt_missing), rawptr(disp_try_hdr)}
DISPLAY_SHELL_VTABLE := [6]rawptr{rawptr(rt_missing), rawptr(rt_add_ref), rawptr(rt_add_ref), rawptr(disp_launch_uri), rawptr(disp_acquire_deferral), rawptr(disp_close_deferral)}
DISPLAY_CAPTURE_VTABLE := [6]rawptr{rawptr(rt_missing), rawptr(rt_add_ref), rawptr(rt_add_ref), rawptr(rt_missing), rawptr(rt_missing), rawptr(disp_screenshot)}

DISPLAY_HDR_OBJECT := Runtime_Object{vtable = raw_data(DISPLAY_HDR_VTABLE[:]), area = "hdr"}
DISPLAY_SHELL_OBJECT := Runtime_Object{vtable = raw_data(DISPLAY_SHELL_VTABLE[:]), area = "shell"}
DISPLAY_CAPTURE_OBJECT := Runtime_Object{vtable = raw_data(DISPLAY_CAPTURE_VTABLE[:]), area = "capture"}

// =============================================================================
// 8. xgamesave (transactional versioned disk save store)
// =============================================================================

PROVIDER_XGAMESAVE :: Guid{0x704c3f58, 0xe629, 0x4cc2, {0xb1, 0x97, 0x30, 0x51, 0x1b, 0x99, 0x6f, 0xe2}}
IID_XGAMESAVE_2026 :: Guid{0x1bfff3af, 0xf14a, 0x40a3, {0x8e, 0x35, 0x9a, 0xda, 0x90, 0x65, 0x93, 0xf9}}

XGS_INVALID_CONTAINER_NAME :: HRESULT(-2138898431) // 0x80830001
XGS_NO_ACCESS :: HRESULT(-2138898430) // 0x80830002
XGS_OUT_OF_LOCAL_STORAGE :: HRESULT(-2138898429) // 0x80830003
XGS_UPDATE_TOO_BIG :: HRESULT(-2138898427) // 0x80830005
XGS_QUOTA_EXCEEDED :: HRESULT(-2138898426) // 0x80830006
XGS_BUFFER_TOO_SMALL :: HRESULT(-2138898425) // 0x80830007
XGS_BLOB_NOT_FOUND :: HRESULT(-2138898424) // 0x80830008

XGS_QUOTA :: u64(256) << 20
XGS_MAX_UPDATE :: uint(16) << 20

Save_Container_Info :: struct {
	name:          cstring,
	display_name:  cstring,
	blob_count:    u32,
	total_size:    u64,
	last_modified: i64,
	needs_sync:    bool,
}

Save_Blob_Info :: struct {
	name: cstring,
	size: u32,
}

Save_Blob_Data :: struct {
	info: Save_Blob_Info,
	data: [^]u8,
}

Save_Provider :: struct {
	root: string,
}

Save_Container :: struct {
	name: string,
	dir:  string,
}

Save_Change :: struct {
	name: string,
	data: []u8,
	del:  bool,
}

Save_Update :: struct {
	name:    string,
	display: string,
	dir:     string,
	changes: [dynamic]Save_Change,
}

@(private) g_saves_mu: sync.Mutex
@(private) g_xgs_init_id: u8 = 0
@(private) g_xgs_quota_id: u8 = 0
@(private) g_xgs_del_id: u8 = 0
@(private) g_xgs_read_id: u8 = 0
@(private) g_xgs_submit_id: u8 = 0

@(private) xgs_live_mu: sync.Mutex
@(private) xgs_providers: [dynamic]^Save_Provider
@(private) xgs_containers: [dynamic]^Save_Container
@(private) xgs_updates: [dynamic]^Save_Update

fini_xgamesave :: proc() {
	sync.mutex_lock(&xgs_live_mu)
	defer sync.mutex_unlock(&xgs_live_mu)
	for p in xgs_providers {
		delete(p.root)
		free(p)
	}
	delete(xgs_providers)
	xgs_providers = nil
	for c in xgs_containers {
		delete(c.name)
		delete(c.dir)
		free(c)
	}
	delete(xgs_containers)
	xgs_containers = nil
	for u in xgs_updates {
		for ch in u.changes {
			delete(ch.name)
			if len(ch.data) > 0 { delete(ch.data) }
		}
		delete(u.changes)
		delete(u.name)
		delete(u.display)
		delete(u.dir)
		free(u)
	}
	delete(xgs_updates)
	xgs_updates = nil
}

@(private)
xgs_valid_container_name :: proc(name: string) -> bool {
	if len(name) == 0 || len(name) > 256 {
		return false
	}
	for b in transmute([]u8)name {
		switch b {
		case 'A'..='Z', 'a'..='z', '0'..='9', '_', '-', '.', '/':
		case: return false
		}
	}
	return true
}

@(private)
xgs_encode_name :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for ch in transmute([]u8)s {
		switch ch {
		case 'A'..='Z', 'a'..='z', '0'..='9', '-', '_':
			strings.write_byte(&b, ch)
		case:
			fmt.sbprintf(&b, "%%%02X", ch)
		}
	}
	return strings.to_string(b)
}

@(private)
xgs_container_dir :: proc(root: string, name: string, allocator := context.allocator) -> string {
	enc := xgs_encode_name(name, context.temp_allocator)
	if len(enc) > 100 { enc = enc[:100] }
	h := vasperty_game.city64(transmute([]u8)name)
	folder := fmt.tprintf("%s_%016x", enc, h)
	p, _ := filepath.join({root, folder}, allocator)
	return p
}

@(private)
xgs_write_manifest :: proc(ver_dir: string, name, display: string, blob_names: []string) -> bool {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, name)
	strings.write_byte(&b, '\n')
	strings.write_string(&b, display)
	strings.write_byte(&b, '\n')
	for bn in blob_names {
		strings.write_string(&b, bn)
		strings.write_byte(&b, '\n')
	}
	mp, _ := filepath.join({ver_dir, "manifest"}, context.temp_allocator)
	return os.write_entire_file(mp, transmute([]u8)strings.to_string(b)) == nil
}

XGS_Version :: struct {
	num:     u64,
	dir:     string,
	name:    string,
	display: string,
	blobs:   [dynamic]string,
}

@(private)
xgs_destroy_version :: proc(v: ^XGS_Version, alloc := context.allocator) {
	delete(v.dir, alloc)
	delete(v.name, alloc)
	delete(v.display, alloc)
	for b in v.blobs { delete(b, alloc) }
	delete(v.blobs)
}

@(private)
xgs_current_version :: proc(cdir: string, alloc := context.allocator) -> (XGS_Version, bool) {
	if !os.exists(cdir) {
		return {}, false
	}
	f, err := os.open(cdir)
	if err != nil { return {}, false }
	defer os.close(f)
	entries, derr := os.read_dir(f, -1, context.temp_allocator)
	if derr != nil { return {}, false }

	best_num: u64 = 0
	found_any := false
	best_dir := ""
	for e in entries {
		if e.type != .Directory || !strings.has_prefix(e.name, "v") {
			continue
		}
		if strings.contains(e.name, ".") { continue }
		num, ok := strconv.parse_u64_of_base(e.name[1:], 10)
		if !ok { continue }
		if !found_any || num > best_num {
			found_any = true
			best_num = num
			best_dir = e.fullpath
		}
	}
	if !found_any { return {}, false }

	mp, _ := filepath.join({best_dir, "manifest"}, context.temp_allocator)
	mbytes, merr := os.read_entire_file(mp, context.temp_allocator)
	if merr != nil { return {}, false }
	lines := strings.split_lines(string(mbytes), context.temp_allocator)
	if len(lines) < 2 { return {}, false }

	v := XGS_Version{
		num     = best_num,
		dir     = strings.clone(best_dir, alloc),
		name    = strings.clone(lines[0], alloc),
		display = strings.clone(lines[1], alloc),
		blobs   = make([dynamic]string, 0, max(len(lines) - 2, 0), alloc),
	}
	for i := 2; i < len(lines); i += 1 {
		if len(lines[i]) > 0 {
			append(&v.blobs, strings.clone(lines[i], alloc))
		}
	}
	return v, true
}

@(private)
xgs_blob_file :: proc(ver_dir: string, idx: int, allocator := context.temp_allocator) -> string {
	p, _ := filepath.join({ver_dir, fmt.tprintf("%d", idx)}, allocator)
	return p
}

@(private)
xgs_remove_tree :: proc(path: string) {
	if !os.exists(path) { return }
	if os.is_dir(path) {
		f, err := os.open(path)
		if err == nil {
			entries, derr := os.read_dir(f, -1, context.temp_allocator)
			os.close(f)
			if derr == nil {
				for e in entries {
					xgs_remove_tree(e.fullpath)
				}
			}
		}
		_ = win32.RemoveDirectoryW(win32.utf8_to_wstring(path, context.temp_allocator))
	} else {
		_ = win32.DeleteFileW(win32.utf8_to_wstring(path, context.temp_allocator))
	}
}

@(private) xgs_init_async :: proc "system" (_: ^Runtime_Object, _user: rawptr, config: cstring, _sync: bool, b: ^Async_Block) -> HRESULT {
	context = hle_context()
	t := current_title(context.temp_allocator)
	if len(t.saves) == 0 {
		return async_finished(b, rawptr(&g_xgs_init_id), XGS_NO_ACCESS)
	}
	cfg, has_cfg := cstr_to_string(config)
	if !has_cfg || len(cfg) == 0 { cfg = "default" }
	xuid_hex := fmt.tprintf("%016X", XUSER_XUID)
	enc_cfg := xgs_encode_name(cfg, context.temp_allocator)
	root, _ := filepath.join({t.saves, xuid_hex, enc_cfg})
	if err := os.make_directory_all(root); err != nil {
		delete(root)
		return async_finished(b, rawptr(&g_xgs_init_id), XGS_NO_ACCESS)
	}
	prov := new(Save_Provider)
	prov.root = root
	sync.mutex_lock(&xgs_live_mu)
	append(&xgs_providers, prov)
	sync.mutex_unlock(&xgs_live_mu)
	return async_finished_with(b, rawptr(&g_xgs_init_id), S_OK, async_bytes(&prov))
}
@(private) xgs_init_res :: proc "system" (_: ^Runtime_Object, b: ^Async_Block, out: ^^Save_Provider) -> HRESULT {
	context = hle_context()
	return async_result_copy(b, rawptr(&g_xgs_init_id), out)
}
@(private) xgs_close_prov :: proc "system" (_: ^Runtime_Object, prov: ^Save_Provider) {
	context = hle_context()
	if prov == nil { return }
	sync.mutex_lock(&xgs_live_mu)
	defer sync.mutex_unlock(&xgs_live_mu)
	for p, i in xgs_providers {
		if p == prov {
			ordered_remove(&xgs_providers, i)
			delete(p.root)
			free(p)
			break
		}
	}
}
@(private) xgs_quota_async :: proc "system" (_: ^Runtime_Object, prov: ^Save_Provider, b: ^Async_Block) -> HRESULT {
	context = hle_context()
	if prov == nil { return async_finished(b, rawptr(&g_xgs_quota_id), E_INVALIDARG) }
	sync.mutex_lock(&g_saves_mu)
	used := dir_used_bytes(prov.root)
	rem := i64(min(XGS_QUOTA - min(XGS_QUOTA, used), disk_free_bytes(prov.root)))
	sync.mutex_unlock(&g_saves_mu)
	return async_finished_with(b, rawptr(&g_xgs_quota_id), S_OK, async_bytes(&rem))
}
@(private) xgs_quota_res :: proc "system" (_: ^Runtime_Object, b: ^Async_Block, out: ^i64) -> HRESULT {
	context = hle_context()
	return async_result_copy(b, rawptr(&g_xgs_quota_id), out)
}
@(private) xgs_delete_async :: proc "system" (_: ^Runtime_Object, prov: ^Save_Provider, name_c: cstring, b: ^Async_Block) -> HRESULT {
	context = hle_context()
	name, ok := cstr_to_string(name_c)
	if prov == nil || !ok { return async_finished(b, rawptr(&g_xgs_del_id), E_INVALIDARG) }
	if !xgs_valid_container_name(name) { return async_finished(b, rawptr(&g_xgs_del_id), XGS_INVALID_CONTAINER_NAME) }
	cdir := xgs_container_dir(prov.root, name, context.temp_allocator)
	sync.mutex_lock(&g_saves_mu)
	if v, has := xgs_current_version(cdir, context.temp_allocator); has && v.name == name {
		xgs_remove_tree(cdir)
	}
	sync.mutex_unlock(&g_saves_mu)
	return async_finished(b, rawptr(&g_xgs_del_id), S_OK)
}
@(private) xgs_delete_res :: proc "system" (_: ^Runtime_Object, b: ^Async_Block) -> HRESULT {
	context = hle_context()
	return XAsyncGetResult(b, rawptr(&g_xgs_del_id), 0, nil, nil)
}

Save_Container_Callback :: #type proc "system" (info: ^Save_Container_Info, ctx: rawptr) -> bool
Save_Blob_Callback :: #type proc "system" (info: ^Save_Blob_Info, ctx: rawptr) -> bool

@(private) xgs_report_containers :: proc(root: string, filter_name: string, use_filter: bool, ctx: rawptr, cb: Save_Container_Callback) {
	if !os.exists(root) { return }
	Item :: struct { name, display: cstring, count: u32, size: u64, mtime: i64 }
	items := make([dynamic]Item, 0, 8, context.temp_allocator)

	sync.mutex_lock(&g_saves_mu)
	f, err := os.open(root)
	if err == nil {
		entries, derr := os.read_dir(f, -1, context.temp_allocator)
		os.close(f)
		if derr == nil {
			for e in entries {
				if e.type != .Directory { continue }
				v, ok := xgs_current_version(e.fullpath, context.temp_allocator)
				if !ok { continue }
				if use_filter && v.name != filter_name { continue }
				total_sz: u64 = 0
				for _, bi in v.blobs {
					if fi, ferr := os.stat(xgs_blob_file(v.dir, bi), context.temp_allocator); ferr == nil {
						total_sz += u64(max(fi.size, 0))
					}
				}
				append(&items, Item{
					name    = strings.clone_to_cstring(v.name, context.temp_allocator),
					display = strings.clone_to_cstring(v.display, context.temp_allocator),
					count   = u32(len(v.blobs)),
					size    = total_sz,
					mtime   = 0,
				})
			}
		}
	}
	sync.mutex_unlock(&g_saves_mu)

	for &it in items {
		info := Save_Container_Info{
			name          = it.name,
			display_name  = it.display,
			blob_count    = it.count,
			total_size    = it.size,
			last_modified = it.mtime,
			needs_sync    = false,
		}
		if !cb(&info, ctx) { break }
	}
}

@(private) xgs_container_info :: proc "system" (_: ^Runtime_Object, prov: ^Save_Provider, name_c: cstring, ctx: rawptr, cb: Save_Container_Callback) -> HRESULT {
	context = hle_context()
	name, ok := cstr_to_string(name_c)
	if prov == nil || !ok || cb == nil { return E_INVALIDARG }
	if !xgs_valid_container_name(name) { return XGS_INVALID_CONTAINER_NAME }
	xgs_report_containers(prov.root, name, true, ctx, cb)
	return S_OK
}
@(private) xgs_enum_containers :: proc "system" (_: ^Runtime_Object, prov: ^Save_Provider, ctx: rawptr, cb: Save_Container_Callback) -> HRESULT {
	context = hle_context()
	if prov == nil || cb == nil { return E_INVALIDARG }
	xgs_report_containers(prov.root, "", false, ctx, cb)
	return S_OK
}
@(private) xgs_create_container :: proc "system" (_: ^Runtime_Object, prov: ^Save_Provider, name_c: cstring, out: ^^Save_Container) -> HRESULT {
	context = hle_context()
	name, ok := cstr_to_string(name_c)
	if prov == nil || !ok { return E_INVALIDARG }
	if !xgs_valid_container_name(name) { return XGS_INVALID_CONTAINER_NAME }
	c := new(Save_Container)
	c.name = strings.clone(name)
	c.dir = xgs_container_dir(prov.root, name)
	sync.mutex_lock(&xgs_live_mu)
	append(&xgs_containers, c)
	sync.mutex_unlock(&xgs_live_mu)
	return put_ptr(out, c)
}
@(private) xgs_close_container :: proc "system" (_: ^Runtime_Object, cont: ^Save_Container) {
	context = hle_context()
	if cont == nil { return }
	sync.mutex_lock(&xgs_live_mu)
	defer sync.mutex_unlock(&xgs_live_mu)
	for c, i in xgs_containers {
		if c == cont {
			ordered_remove(&xgs_containers, i)
			delete(c.name)
			delete(c.dir)
			free(c)
			break
		}
	}
}
@(private) xgs_enum_blobs :: proc "system" (_: ^Runtime_Object, c: ^Save_Container, prefix_c: cstring, ctx: rawptr, cb: Save_Blob_Callback) -> HRESULT {
	context = hle_context()
	if c == nil || cb == nil { return E_INVALIDARG }
	prefix, has_p := cstr_to_string(prefix_c)
	if !has_p { prefix = "" }

	sync.mutex_lock(&g_saves_mu)
	v, ok := xgs_current_version(c.dir, context.temp_allocator)
	if !ok || v.name != c.name {
		sync.mutex_unlock(&g_saves_mu)
		return S_OK
	}
	sizes := make([]u32, len(v.blobs), context.temp_allocator)
	for _, bi in v.blobs {
		if fi, ferr := os.stat(xgs_blob_file(v.dir, bi), context.temp_allocator); ferr == nil {
			sizes[bi] = u32(fi.size)
		}
	}
	sync.mutex_unlock(&g_saves_mu)

	for bn, bi in v.blobs {
		if !strings.has_prefix(bn, prefix) { continue }
		info := Save_Blob_Info{
			name = strings.clone_to_cstring(bn, context.temp_allocator),
			size = sizes[bi],
		}
		if !cb(&info, ctx) { break }
	}
	return S_OK
}
@(private) xgs_read_blobs_sync :: proc(c: ^Save_Container, names: [^]cstring, count: ^u32, out_blobs: [^]Save_Blob_Data) -> HRESULT {
	if c == nil || names == nil || count == nil || out_blobs == nil { return E_INVALIDARG }
	n := int(count^)
	if n == 0 { return E_INVALIDARG }

	sync.mutex_lock(&g_saves_mu)
	defer sync.mutex_unlock(&g_saves_mu)
	v, ok := xgs_current_version(c.dir, context.temp_allocator)
	if !ok || v.name != c.name {
		count^ = 0
		return XGS_BLOB_NOT_FOUND
	}

	buf := cast([^]u8)rawptr(out_blobs)
	data_off := n * size_of(Save_Blob_Data)
	// First compute sizes and verify every requested blob exists.
	total_needed := data_off
	found_idxs := make([]int, n, context.temp_allocator)
	blob_bytes := make([][]u8, n, context.temp_allocator)
	for i in 0 ..< n {
		bn, ok_n := cstr_to_string(names[i])
		if !ok_n { return E_INVALIDARG }
		found_idx := -1
		for vn, vi in v.blobs {
			if vn == bn {
				found_idx = vi
				break
			}
		}
		if found_idx < 0 {
			count^ = 0
			return XGS_BLOB_NOT_FOUND
		}
		found_idxs[i] = found_idx
		bytes, berr := os.read_entire_file(xgs_blob_file(v.dir, found_idx), context.temp_allocator)
		if berr != nil { return XGS_NO_ACCESS }
		blob_bytes[i] = bytes
		total_needed += len(bn) + 1 + len(bytes)
	}
	cursor := data_off
	for i in 0 ..< n {
		bn := string(names[i])
		mem.copy(rawptr(uintptr(buf) + uintptr(cursor)), raw_data(bn), len(bn))
		buf[cursor + len(bn)] = 0
		name_ptr := cstring(rawptr(uintptr(buf) + uintptr(cursor)))
		cursor += len(bn) + 1

		data_ptr: [^]u8 = nil
		if len(blob_bytes[i]) > 0 {
			mem.copy(rawptr(uintptr(buf) + uintptr(cursor)), raw_data(blob_bytes[i]), len(blob_bytes[i]))
			data_ptr = cast([^]u8)rawptr(uintptr(buf) + uintptr(cursor))
			cursor += len(blob_bytes[i])
		}
		out_blobs[i] = Save_Blob_Data{
			info = Save_Blob_Info{name = name_ptr, size = u32(len(blob_bytes[i]))},
			data = data_ptr,
		}
	}
	_ = total_needed
	return S_OK
}
@(private) xgs_read_blobs :: proc "system" (_: ^Runtime_Object, c: ^Save_Container, names: [^]cstring, count: ^u32, blobs_size: uint, out_blobs: [^]Save_Blob_Data) -> HRESULT {
	context = hle_context()
	if uintptr(out_blobs) < 0x10000 { return E_INVALIDARG }
	_ = blobs_size
	return xgs_read_blobs_sync(c, names, count, out_blobs)
}
@(private) xgs_read_async :: proc "system" (_: ^Runtime_Object, c: ^Save_Container, names: [^]cstring, count: u32, b: ^Async_Block) -> HRESULT {
	context = hle_context()
	if c == nil || names == nil || count == 0 { return async_finished(b, rawptr(&g_xgs_read_id), E_INVALIDARG) }
	sync.mutex_lock(&g_saves_mu)
	v, ok := xgs_current_version(c.dir, context.temp_allocator)
	if !ok || v.name != c.name {
		sync.mutex_unlock(&g_saves_mu)
		return async_finished(b, rawptr(&g_xgs_read_id), XGS_BLOB_NOT_FOUND)
	}
	payload_sz := int(count) * size_of(Save_Blob_Data)
	blob_bytes := make([][]u8, int(count), context.temp_allocator)
	blob_names := make([]string, int(count), context.temp_allocator)
	for i in 0 ..< int(count) {
		bn, ok_n := cstr_to_string(names[i])
		if !ok_n { sync.mutex_unlock(&g_saves_mu); return async_finished(b, rawptr(&g_xgs_read_id), E_INVALIDARG) }
		blob_names[i] = bn
		fidx := -1
		for vn, vi in v.blobs {
			if vn == bn { fidx = vi; break }
		}
		if fidx < 0 { sync.mutex_unlock(&g_saves_mu); return async_finished(b, rawptr(&g_xgs_read_id), XGS_BLOB_NOT_FOUND) }
		bytes, berr := os.read_entire_file(xgs_blob_file(v.dir, fidx), context.temp_allocator)
		if berr != nil { sync.mutex_unlock(&g_saves_mu); return async_finished(b, rawptr(&g_xgs_read_id), XGS_NO_ACCESS) }
		blob_bytes[i] = bytes
		payload_sz += len(bn) + 1 + len(bytes)
	}
	sync.mutex_unlock(&g_saves_mu)

	// Store compact count + serialized payload directly in async result.
	payload := make([]u8, payload_sz, context.temp_allocator)
	cursor := int(count) * size_of(Save_Blob_Data)
	entries := cast([^]Save_Blob_Data)raw_data(payload)
	for i in 0 ..< int(count) {
		copy(payload[cursor:], blob_names[i])
		payload[cursor + len(blob_names[i])] = 0
		noff := cursor
		cursor += len(blob_names[i]) + 1
		doff := cursor
		if len(blob_bytes[i]) > 0 {
			copy(payload[cursor:], blob_bytes[i])
			cursor += len(blob_bytes[i])
		}
		entries[i] = Save_Blob_Data{
			info = Save_Blob_Info{name = cstring(rawptr(uintptr(noff))), size = u32(len(blob_bytes[i]))},
			data = cast([^]u8)rawptr(uintptr(doff)) if len(blob_bytes[i]) > 0 else nil,
		}
	}
	return async_finished_with(b, rawptr(&g_xgs_read_id), S_OK, payload)
}
@(private) xgs_read_result :: proc "system" (_: ^Runtime_Object, b: ^Async_Block, count: u32, out_blobs: [^]Save_Blob_Data) -> HRESULT {
	context = hle_context()
	sz: uint = 0
	hr := XAsyncGetResultSize(b, &sz)
	if i32(hr) < 0 { return hr }
	if out_blobs == nil || uint(count) * size_of(Save_Blob_Data) > sz {
		return XGS_BUFFER_TOO_SMALL
	}
	hr = XAsyncGetResult(b, rawptr(&g_xgs_read_id), sz, rawptr(out_blobs), nil)
	if i32(hr) < 0 { return hr }
	// Relocate offset pointers to destination buffer base.
	base := uintptr(out_blobs)
	for i in 0 ..< int(count) {
		out_blobs[i].info.name = cstring(rawptr(base + uintptr(rawptr(out_blobs[i].info.name))))
		if out_blobs[i].info.size > 0 {
			out_blobs[i].data = cast([^]u8)rawptr(base + uintptr(rawptr(out_blobs[i].data)))
		}
	}
	return S_OK
}
@(private) xgs_create_update :: proc "system" (_: ^Runtime_Object, c: ^Save_Container, display_c: cstring, out: ^^Save_Update) -> HRESULT {
	context = hle_context()
	if c == nil || out == nil { return E_INVALIDARG }
	disp, ok_d := cstr_to_string(display_c)
	if !ok_d { disp = c.name }
	u := new(Save_Update)
	u.name = strings.clone(c.name)
	u.display = strings.clone(disp)
	u.dir = strings.clone(c.dir)
	sync.mutex_lock(&xgs_live_mu)
	append(&xgs_updates, u)
	sync.mutex_unlock(&xgs_live_mu)
	out^ = u
	return S_OK
}
@(private) xgs_close_update :: proc "system" (_: ^Runtime_Object, upd: ^Save_Update) {
	context = hle_context()
	if upd == nil { return }
	sync.mutex_lock(&xgs_live_mu)
	defer sync.mutex_unlock(&xgs_live_mu)
	for u, i in xgs_updates {
		if u == upd {
			ordered_remove(&xgs_updates, i)
			for ch in u.changes {
				delete(ch.name)
				if len(ch.data) > 0 { delete(ch.data) }
			}
			delete(u.changes)
			delete(u.name)
			delete(u.display)
			delete(u.dir)
			free(u)
			break
		}
	}
}
@(private) xgs_write_blob :: proc "system" (_: ^Runtime_Object, u: ^Save_Update, name_c: cstring, data: [^]u8, size: uint) -> HRESULT {
	context = hle_context()
	name, ok := cstr_to_string(name_c)
	if u == nil || !ok || len(name) == 0 || (data == nil && size > 0) {
		return E_INVALIDARG
	}
	if size > XGS_MAX_UPDATE { return XGS_UPDATE_TOO_BIG }
	cp: []u8 = nil
	if size > 0 {
		cp = make([]u8, int(size))
		mem.copy(raw_data(cp), data, int(size))
	}
	append(&u.changes, Save_Change{name = strings.clone(name), data = cp, del = false})
	return S_OK
}
@(private) xgs_delete_blob :: proc "system" (_: ^Runtime_Object, u: ^Save_Update, name_c: cstring) -> HRESULT {
	context = hle_context()
	name, ok := cstr_to_string(name_c)
	if u == nil || !ok || len(name) == 0 { return E_INVALIDARG }
	append(&u.changes, Save_Change{name = strings.clone(name), del = true})
	return S_OK
}
@(private) xgs_submit_async :: proc "system" (_: ^Runtime_Object, u: ^Save_Update, b: ^Async_Block) -> HRESULT {
	context = hle_context()
	if u == nil { return async_finished(b, rawptr(&g_xgs_submit_id), E_INVALIDARG) }
	sync.mutex_lock(&g_saves_mu)
	defer sync.mutex_unlock(&g_saves_mu)

	cur, has_cur := xgs_current_version(u.dir, context.temp_allocator)
	if has_cur && cur.name != u.name {
		return async_finished(b, rawptr(&g_xgs_submit_id), XGS_NO_ACCESS)
	}
	Entry :: struct { name: string, kept: string, data: []u8, from_disk: bool }
	blobs := make([dynamic]Entry, 0, 16, context.temp_allocator)
	if has_cur {
		for bn, bi in cur.blobs {
			append(&blobs, Entry{name = bn, kept = xgs_blob_file(cur.dir, bi), from_disk = true})
		}
	}
	for ch in u.changes {
		for i := len(blobs) - 1; i >= 0; i -= 1 {
			if blobs[i].name == ch.name {
				ordered_remove(&blobs, i)
			}
		}
		if !ch.del {
			append(&blobs, Entry{name = ch.name, data = ch.data, from_disk = false})
		}
	}
	slice.sort_by(blobs[:], proc(a, b: Entry) -> bool { return a.name < b.name })

	next_ver := (cur.num + 1) if has_cur else u64(1)
	if err := os.make_directory_all(u.dir); err != nil {
		return async_finished(b, rawptr(&g_xgs_submit_id), XGS_NO_ACCESS)
	}
	staging, _ := filepath.join({u.dir, fmt.tprintf("v%d.new", next_ver)}, context.temp_allocator)
	xgs_remove_tree(staging)
	if err := os.make_directory_all(staging); err != nil {
		return async_finished(b, rawptr(&g_xgs_submit_id), XGS_NO_ACCESS)
	}

	bnames := make([]string, len(blobs), context.temp_allocator)
	for entry, idx in blobs {
		bnames[idx] = entry.name
		dst := xgs_blob_file(staging, idx)
		if entry.from_disk {
			if !win32.CreateHardLinkW(
				win32.utf8_to_wstring(dst, context.temp_allocator),
				win32.utf8_to_wstring(entry.kept, context.temp_allocator),
				nil,
			) {
				if raw, rerr := os.read_entire_file(entry.kept, context.temp_allocator); rerr == nil {
					_ = os.write_entire_file(dst, raw)
				}
			}
		} else {
			_ = os.write_entire_file(dst, entry.data)
		}
	}
	if !xgs_write_manifest(staging, u.name, u.display, bnames) {
		xgs_remove_tree(staging)
		return async_finished(b, rawptr(&g_xgs_submit_id), XGS_NO_ACCESS)
	}
	final_dir, _ := filepath.join({u.dir, fmt.tprintf("v%d", next_ver)}, context.temp_allocator)
	if !win32.MoveFileExW(
		win32.utf8_to_wstring(staging, context.temp_allocator),
		win32.utf8_to_wstring(final_dir, context.temp_allocator),
		win32.MOVEFILE_WRITE_THROUGH,
	) {
		xgs_remove_tree(staging)
		return async_finished(b, rawptr(&g_xgs_submit_id), XGS_NO_ACCESS)
	}
	if has_cur {
		xgs_remove_tree(cur.dir)
	}
	return async_finished(b, rawptr(&g_xgs_submit_id), S_OK)
}
@(private) xgs_submit_res :: proc "system" (_: ^Runtime_Object, b: ^Async_Block) -> HRESULT {
	context = hle_context()
	return XAsyncGetResult(b, rawptr(&g_xgs_submit_id), 0, nil, nil)
}

XGAMESAVE_VTABLE := [30]rawptr{
	rawptr(rt_missing), rawptr(rt_add_ref), rawptr(rt_add_ref),
	rawptr(rt_missing),
	rawptr(xgs_init_async), rawptr(xgs_init_res), rawptr(xgs_close_prov),
	rawptr(rt_missing),
	rawptr(xgs_quota_async), rawptr(xgs_quota_res),
	rawptr(rt_missing),
	rawptr(xgs_delete_async), rawptr(xgs_delete_res),
	rawptr(xgs_container_info), rawptr(xgs_enum_containers), rawptr(rt_missing),
	rawptr(xgs_create_container), rawptr(xgs_close_container),
	rawptr(rt_missing), rawptr(xgs_enum_blobs), rawptr(xgs_read_blobs),
	rawptr(xgs_read_async), rawptr(xgs_read_result),
	rawptr(xgs_create_update), rawptr(xgs_close_update),
	rawptr(xgs_write_blob), rawptr(xgs_delete_blob),
	rawptr(rt_missing),
	rawptr(xgs_submit_async), rawptr(xgs_submit_res),
}
XGAMESAVE_OBJECT := Runtime_Object{vtable = raw_data(XGAMESAVE_VTABLE[:]), area = "game save"}

// =============================================================================
// 9. xstore
// =============================================================================

PROVIDER_XSTORE :: Guid{0x0dd112ac, 0x7c24, 0x448c, {0xb9, 0x2b, 0x39, 0x60, 0xfb, 0x5b, 0xd3, 0x0c}}
IID_XSTORE_2026 :: Guid{0xb09d803c, 0x2414, 0x4a05, {0x82, 0xc6, 0x66, 0xdf, 0xdc, 0x9e, 0x9a, 0x44}}
IID_XSTORE_DURABLES :: Guid{0x2d42fea5, 0xe71d, 0x4b76, {0x97, 0xcd, 0xc5, 0x0a, 0xfb, 0xb3, 0xae, 0x5d}}
XSTORE_NETWORK_ERROR :: HRESULT(-1994108159) // 0x89245301

Store_Game_License :: struct {
	sku_store_id:               [18]u8,
	is_active:                  bool,
	is_trial_owned_by_this_user: bool,
	is_disc_license:            bool,
	is_trial:                   bool,
	trial_seconds_remaining:    u32,
	trial_unique_id:            [64]u8,
	expiration:                 i64,
}

@(private) g_xst_ctx_dummy: u8 = 0
@(private) g_xst_query_dummy: u8 = 0
@(private) g_xst_valid_dummy: u8 = 0
@(private) g_xst_invalid_dummy: u8 = 0
@(private) g_xst_fail_id: u8 = 0
@(private) g_xst_query_id: u8 = 0
@(private) g_xst_lic_id: u8 = 0
@(private) g_xst_game_id: u8 = 0

@(private) xst_status :: proc "system" (_: ^Runtime_Object, b: ^Async_Block) -> HRESULT { context = hle_context(); return XAsyncGetStatus(b, false) }
@(private) xst_create_ctx :: proc "system" (_: ^Runtime_Object, _: rawptr, out: ^rawptr) -> HRESULT {
	context = hle_context()
	return put_ptr(out, rawptr(&g_xst_ctx_dummy))
}
@(private) xst_close :: proc "system" (_: ^Runtime_Object, _: rawptr) {}
@(private) xst_assoc_async :: proc "system" (_: ^Runtime_Object, _: rawptr, _, _: u32, b: ^Async_Block) -> HRESULT {
	context = hle_context()
	return async_finished(b, rawptr(&g_xst_fail_id), XSTORE_NETWORK_ERROR)
}
@(private) xst_entitled_async :: proc "system" (_: ^Runtime_Object, _: rawptr, _, _: u32, b: ^Async_Block) -> HRESULT {
	context = hle_context()
	h := rawptr(&g_xst_query_dummy)
	return async_finished_with(b, rawptr(&g_xst_query_id), S_OK, async_bytes(&h))
}
@(private) xst_query_res :: proc "system" (_: ^Runtime_Object, b: ^Async_Block, out: ^rawptr) -> HRESULT {
	context = hle_context()
	return async_result_copy(b, rawptr(&g_xst_query_id), out)
}
@(private) xst_enum_prods :: proc "system" (_: ^Runtime_Object, _, _, _: rawptr) -> HRESULT { context = hle_context(); return S_OK }
@(private) xst_has_more :: proc "system" (_: ^Runtime_Object, _: rawptr) -> bool { context = hle_context(); return false }
@(private) xst_next_page :: proc "system" (_: ^Runtime_Object, _: rawptr, b: ^Async_Block) -> HRESULT {
	context = hle_context()
	return async_finished(b, rawptr(&g_xst_query_id), E_ILLEGAL_METHOD_CALL)
}
@(private) xst_lic_pkg_async :: proc "system" (_: ^Runtime_Object, _: rawptr, pkg: cstring, b: ^Async_Block) -> HRESULT {
	context = hle_context()
	s, ok := cstr_to_string(pkg)
	ours := ok && s == xpackage_identifier(context.temp_allocator)
	h := rawptr(&g_xst_valid_dummy) if ours else rawptr(&g_xst_invalid_dummy)
	return async_finished_with(b, rawptr(&g_xst_lic_id), S_OK, async_bytes(&h))
}
@(private) xst_lic_dur_async :: proc "system" (_: ^Runtime_Object, _: rawptr, _: cstring, b: ^Async_Block) -> HRESULT {
	context = hle_context()
	h := rawptr(&g_xst_invalid_dummy)
	return async_finished_with(b, rawptr(&g_xst_lic_id), S_OK, async_bytes(&h))
}
@(private) xst_lic_res :: proc "system" (_: ^Runtime_Object, b: ^Async_Block, out: ^rawptr) -> HRESULT {
	context = hle_context()
	return async_result_copy(b, rawptr(&g_xst_lic_id), out)
}
@(private) xst_lic_valid :: proc "system" (_: ^Runtime_Object, h: rawptr) -> bool {
	context = hle_context()
	return h == rawptr(&g_xst_valid_dummy)
}
@(private) xst_game_lic_async :: proc "system" (_: ^Runtime_Object, _: rawptr, b: ^Async_Block) -> HRESULT {
	context = hle_context()
	gl := Store_Game_License{is_active = true}
	t := current_title(context.temp_allocator)
	sku := fmt.tprintf("%s/0010", t.store_id)
	n := min(len(sku), len(gl.sku_store_id) - 1)
	copy(gl.sku_store_id[:n], sku[:n])
	return async_finished_with(b, rawptr(&g_xst_game_id), S_OK, async_bytes(&gl))
}
@(private) xst_game_lic_res :: proc "system" (_: ^Runtime_Object, b: ^Async_Block, out: ^Store_Game_License) -> HRESULT {
	context = hle_context()
	return async_result_copy(b, rawptr(&g_xst_game_id), out)
}
@(private) xst_cons_async :: proc "system" (_: ^Runtime_Object, _: rawptr, _: cstring, b: ^Async_Block) -> HRESULT {
	context = hle_context()
	return async_finished(b, rawptr(&g_xst_fail_id), XSTORE_NETWORK_ERROR)
}
@(private) xst_fulfill_async :: proc "system" (_: ^Runtime_Object, _: rawptr, _: cstring, _: u32, _: rawptr, b: ^Async_Block) -> HRESULT {
	context = hle_context()
	return async_finished(b, rawptr(&g_xst_fail_id), XSTORE_NETWORK_ERROR)
}
@(private) xst_userid_async :: proc "system" (_: ^Runtime_Object, _: rawptr, _, _: cstring, b: ^Async_Block) -> HRESULT {
	context = hle_context()
	return async_finished(b, rawptr(&g_xst_fail_id), XSTORE_NETWORK_ERROR)
}
@(private) xst_size_status :: proc "system" (_: ^Runtime_Object, b: ^Async_Block, _: ^uint) -> HRESULT { context = hle_context(); return XAsyncGetStatus(b, false) }
@(private) xst_str_status :: proc "system" (_: ^Runtime_Object, b: ^Async_Block, _: uint, _: rawptr) -> HRESULT { context = hle_context(); return XAsyncGetStatus(b, false) }
@(private) xst_cnt_status :: proc "system" (_: ^Runtime_Object, b: ^Async_Block, _: ^u32) -> HRESULT { context = hle_context(); return XAsyncGetStatus(b, false) }
@(private) xst_arr_status :: proc "system" (_: ^Runtime_Object, b: ^Async_Block, _: u32, _: rawptr) -> HRESULT { context = hle_context(); return XAsyncGetStatus(b, false) }
@(private) xst_pui_async :: proc "system" (_: ^Runtime_Object, _: rawptr, _, _, _: cstring, b: ^Async_Block) -> HRESULT {
	context = hle_context()
	return async_finished(b, rawptr(&g_xst_fail_id), XSTORE_NETWORK_ERROR)
}
@(private) xst_ppage_async :: proc "system" (_: ^Runtime_Object, _: rawptr, _: cstring, b: ^Async_Block) -> HRESULT {
	context = hle_context()
	return async_finished(b, rawptr(&g_xst_fail_id), XSTORE_NETWORK_ERROR)
}
@(private) xst_redeem_async :: proc "system" (_: ^Runtime_Object, _: rawptr, _: cstring, _: rawptr, _: uint, _: bool, b: ^Async_Block) -> HRESULT {
	context = hle_context()
	return async_finished(b, rawptr(&g_xst_fail_id), XSTORE_NETWORK_ERROR)
}
@(private) xst_updates_async :: proc "system" (_: ^Runtime_Object, _: rawptr, b: ^Async_Block) -> HRESULT {
	context = hle_context()
	return async_finished(b, rawptr(&g_xst_fail_id), XSTORE_NETWORK_ERROR)
}
@(private) xst_install_async :: proc "system" (_: ^Runtime_Object, _: rawptr, _: rawptr, _: uint, b: ^Async_Block) -> HRESULT {
	context = hle_context()
	return async_finished(b, rawptr(&g_xst_fail_id), XSTORE_NETWORK_ERROR)
}
@(private) xst_pkg_id :: proc "system" (_: ^Runtime_Object, store_id_c: cstring, sz: uint, buf: [^]u8) -> HRESULT {
	context = hle_context()
	sid, ok := cstr_to_string(store_id_c)
	t := current_title(context.temp_allocator)
	if !ok || len(t.store_id) == 0 || sid != t.store_id {
		return E_INVALIDARG
	}
	return put_string(xpackage_identifier(context.temp_allocator), sz, buf, nil)
}
@(private) xst_reg :: proc "system" (_: ^Runtime_Object, _, _, _, _: rawptr, out: ^u64) -> HRESULT { context = hle_context(); return put_ptr(out, next_token()) }
@(private) xst_unreg :: proc "system" (_: ^Runtime_Object, _: rawptr, _: u64, _: bool) -> bool { context = hle_context(); return true }

XSTORE_VTABLE := [77]rawptr{
	rawptr(rt_missing), rawptr(rt_add_ref), rawptr(rt_add_ref),
	rawptr(xst_create_ctx), rawptr(xst_close),
	rawptr(xst_assoc_async), rawptr(xst_query_res),
	rawptr(rt_missing), rawptr(rt_missing),
	rawptr(xst_entitled_async), rawptr(xst_query_res),
	rawptr(rt_missing), rawptr(rt_missing), rawptr(rt_missing), rawptr(rt_missing),
	rawptr(xst_enum_prods), rawptr(xst_has_more), rawptr(xst_next_page), rawptr(xst_query_res), rawptr(xst_close),
	rawptr(xst_lic_pkg_async), rawptr(xst_lic_res), rawptr(xst_lic_valid), rawptr(xst_close),
	rawptr(rt_missing), rawptr(rt_missing), rawptr(rt_missing), rawptr(rt_missing),
	rawptr(xst_game_lic_async), rawptr(xst_game_lic_res),
	rawptr(rt_missing), rawptr(rt_missing), rawptr(rt_missing),
	rawptr(xst_cons_async), rawptr(xst_cnt_status),
	rawptr(xst_fulfill_async), rawptr(xst_cnt_status),
	rawptr(xst_userid_async), rawptr(xst_size_status), rawptr(xst_str_status),
	rawptr(xst_userid_async), rawptr(xst_size_status), rawptr(xst_str_status),
	rawptr(rt_missing), rawptr(rt_missing), rawptr(rt_missing),
	rawptr(rt_missing), rawptr(rt_missing), rawptr(rt_missing),
	rawptr(xst_pui_async), rawptr(xst_status),
	rawptr(rt_missing), rawptr(rt_missing),
	rawptr(xst_redeem_async), rawptr(xst_status),
	rawptr(xst_updates_async), rawptr(xst_cnt_status), rawptr(xst_arr_status),
	rawptr(rt_missing), rawptr(rt_missing),
	rawptr(xst_install_async), rawptr(xst_status),
	rawptr(xst_install_async), rawptr(xst_cnt_status), rawptr(xst_arr_status),
	rawptr(xst_pkg_id),
	rawptr(xst_reg), rawptr(xst_unreg), rawptr(xst_reg), rawptr(xst_unreg),
	rawptr(rt_missing),
	rawptr(xst_lic_dur_async), rawptr(xst_lic_res),
	rawptr(rt_missing), rawptr(rt_missing),
	rawptr(xst_ppage_async), rawptr(xst_status),
}
XSTORE_OBJECT := Runtime_Object{vtable = raw_data(XSTORE_VTABLE[:]), area = "store"}

// =============================================================================
// 10. xgameui
// =============================================================================

PROVIDER_XGAMEUI :: Guid{0xdfcd4649, 0x4ff8, 0x4043, {0xba, 0x07, 0x35, 0xd6, 0x07, 0xdf, 0x98, 0xb0}}
IID_XGAMEUI_2026 :: Guid{0xeaf669df, 0x5542, 0x4590, {0x99, 0xa3, 0x8d, 0xc0, 0x61, 0xf8, 0x37, 0xcc}}

@(private) g_xui_profile_id: u8 = 0
@(private) g_xui_text_id: u8 = 0

xgameui_text_prompt_hook: proc(title, desc, def: string, max_len: u32) -> (string, bool)

@(private) xui_profile_async :: proc "system" (_: ^Runtime_Object, b: ^Async_Block, _u: rawptr, _xuid: u64) -> HRESULT {
	context = hle_context()
	return async_finished(b, rawptr(&g_xui_profile_id), S_OK)
}
@(private) xui_profile_res :: proc "system" (_: ^Runtime_Object, b: ^Async_Block) -> HRESULT {
	context = hle_context()
	return XAsyncGetResult(b, rawptr(&g_xui_profile_id), 0, nil, nil)
}

xui_clamp_utf8_chars :: proc(s: string, max_chars: u32, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	count: u32 = 0
	for r in s {
		if count >= max_chars {
			break
		}
		strings.write_rune(&b, r)
		count += 1
	}
	return strings.to_string(b)
}

@(private) xui_text_async :: proc "system" (_: ^Runtime_Object, b: ^Async_Block, title_c, desc_c, def_c: cstring, scope, max_len: u32) -> HRESULT {
	context = hle_context()
	title, _ := cstr_to_string(title_c)
	desc, _ := cstr_to_string(desc_c)
	def_s, _ := cstr_to_string(def_c)
	eff_max := u32(1024) if (max_len == 0 || scope == 31) else min(max_len, u32(1024))
	if xgameui_text_prompt_hook != nil {
		typed, ok := xgameui_text_prompt_hook(title, desc, def_s, eff_max)
		if !ok {
			return async_finished(b, rawptr(&g_xui_text_id), E_ABORT)
		}
		limited := xui_clamp_utf8_chars(typed, eff_max, context.temp_allocator)
		out := make([]u8, len(limited) + 1, context.temp_allocator)
		copy(out, limited)
		out[len(limited)] = 0
		return async_finished_with(b, rawptr(&g_xui_text_id), S_OK, out)
	}
	return async_finished(b, rawptr(&g_xui_text_id), E_ABORT)
}
@(private) xui_text_size :: proc "system" (_: ^Runtime_Object, b: ^Async_Block, out: ^u32) -> HRESULT {
	context = hle_context()
	sz: uint = 0
	hr := XAsyncGetResultSize(b, &sz)
	if i32(hr) < 0 { return hr }
	return put_ptr(out, u32(sz))
}
@(private) xui_text_res :: proc "system" (_: ^Runtime_Object, b: ^Async_Block, sz: u32, buf: [^]u8, used: ^u32) -> HRESULT {
	context = hle_context()
	w: uint = 0
	hr := XAsyncGetResult(b, rawptr(&g_xui_text_id), uint(sz), rawptr(buf), &w)
	if i32(hr) < 0 || used == nil { return hr }
	return put_ptr(used, u32(w))
}

XGAMEUI_VTABLE := [20]rawptr{
	rawptr(rt_missing), rawptr(rt_add_ref), rawptr(rt_add_ref),
	rawptr(rt_missing), rawptr(rt_missing), rawptr(rt_missing), rawptr(rt_missing),
	rawptr(xui_profile_async), rawptr(xui_profile_res),
	rawptr(rt_missing), rawptr(rt_missing), rawptr(rt_missing), rawptr(rt_missing), rawptr(rt_missing),
	rawptr(rt_missing), rawptr(rt_missing), rawptr(rt_missing),
	rawptr(xui_text_async), rawptr(xui_text_size), rawptr(xui_text_res),
}
XGAMEUI_OBJECT := Runtime_Object{vtable = raw_data(XGAMEUI_VTABLE[:]), area = "game ui"}

// =============================================================================
// 11. speech
// =============================================================================

PROVIDER_SPEECH :: Guid{0x3e241977, 0x6237, 0x41e9, {0x85, 0x59, 0x10, 0x2c, 0x2d, 0x99, 0x83, 0xf1}}
IID_SPEECH :: Guid{0xd722b373, 0x8c4d, 0x4692, {0x9e, 0x51, 0xd6, 0xad, 0x9b, 0x37, 0xaa, 0x7d}}

@(private) SPEECH_SILENCE_WAV := [44]u8{
	'R','I','F','F', 0x24,0,0,0, 'W','A','V','E','f','m','t',' ',
	0x10,0,0,0, 1,0, 1,0, 0x80,0x3E,0,0, 0,0x7D,0,0,
	2,0, 0x10,0, 'd','a','t','a', 0,0,0,0,
}
@(private) g_speech_synth_dummy: u8 = 0
@(private) g_speech_stream_dummy: u8 = 0

@(private) sp_enum_voices :: proc "system" (_: ^Runtime_Object, _, _: rawptr) -> HRESULT { context = hle_context(); return S_OK }
@(private) sp_create :: proc "system" (_: ^Runtime_Object, out: ^rawptr) -> HRESULT { context = hle_context(); return put_ptr(out, rawptr(&g_speech_synth_dummy)) }
@(private) sp_close :: proc "system" (_: ^Runtime_Object, _: rawptr) -> HRESULT { context = hle_context(); return S_OK }
@(private) sp_set_voice :: proc "system" (_: ^Runtime_Object, _: rawptr) -> HRESULT { context = hle_context(); return S_OK }
@(private) sp_set_custom :: proc "system" (_: ^Runtime_Object, _: rawptr, _: cstring) -> HRESULT { context = hle_context(); return S_OK }
@(private) sp_create_stream :: proc "system" (_: ^Runtime_Object, _: rawptr, _: cstring, out: ^rawptr) -> HRESULT { context = hle_context(); return put_ptr(out, rawptr(&g_speech_stream_dummy)) }
@(private) sp_stream_size :: proc "system" (_: ^Runtime_Object, _: rawptr, out: ^uint) -> HRESULT { context = hle_context(); return put_ptr(out, uint(len(SPEECH_SILENCE_WAV))) }
@(private) sp_stream_data :: proc "system" (_: ^Runtime_Object, _: rawptr, sz: uint, buf: [^]u8, used: ^uint) -> HRESULT {
	context = hle_context()
	if buf == nil || sz < uint(len(SPEECH_SILENCE_WAV)) {
		return E_NOT_SUFFICIENT_BUFFER
	}
	mem.copy(buf, raw_data(SPEECH_SILENCE_WAV[:]), len(SPEECH_SILENCE_WAV))
	if used != nil {
		used^ = uint(len(SPEECH_SILENCE_WAV))
	}
	return S_OK
}

SPEECH_VTABLE := [22]rawptr{
	rawptr(rt_missing), rawptr(rt_add_ref), rawptr(rt_add_ref),
	rawptr(rt_missing), rawptr(rt_missing), rawptr(rt_missing), rawptr(rt_missing), rawptr(rt_missing),
	rawptr(sp_enum_voices), rawptr(sp_create), rawptr(sp_close),
	rawptr(sp_set_voice), rawptr(sp_set_custom),
	rawptr(sp_create_stream), rawptr(sp_close), rawptr(sp_stream_size), rawptr(sp_stream_data),
	rawptr(rt_missing), rawptr(rt_missing), rawptr(rt_missing), rawptr(rt_missing),
	rawptr(sp_create_stream),
}
SPEECH_OBJECT := Runtime_Object{vtable = raw_data(SPEECH_VTABLE[:]), area = "accessibility"}
