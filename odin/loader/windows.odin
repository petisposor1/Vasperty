package vasperty_loader

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import win32 "core:sys/windows"
import "core:unicode/utf16"

import vasperty_core "vasperty:core"
import vasperty_pe "vasperty:pe"

DLL_PROCESS_DETACH :: u32(0)
DLL_PROCESS_ATTACH :: u32(1)
DLL_THREAD_ATTACH :: u32(2)
DLL_THREAD_DETACH :: u32(3)

Loader_Error :: enum {
	None,
	Policy_Error,
	Io_Error,
	Load_Library_Failed,
	Tls_Redirect_Failed,
	Virtual_Protect_Failed,
	Thunk_Emit_Failed,
	Dll_Main_Failed,
}

Loaded_Image :: struct {
	module:       win32.HMODULE,
	path:         string,
	info:         vasperty_pe.Image_Info,
	thunk_blocks: [dynamic]Thunk_Block,
	tls_page:     rawptr,
	attached:     bool,
}

@(private)
clone_image_info :: proc(src: ^vasperty_pe.Image_Info, allocator := context.allocator) -> vasperty_pe.Image_Info {
	out: vasperty_pe.Image_Info
	out.machine = src.machine
	out.characteristics = src.characteristics
	out.timestamp = src.timestamp
	out.subsystem = src.subsystem
	out.dll_characteristics = src.dll_characteristics
	out.image_base = src.image_base
	out.size_of_image = src.size_of_image
	out.entry_rva = src.entry_rva
	out.stack_reserve = src.stack_reserve
	out.stack_commit = src.stack_commit
	out.has_relocations = src.has_relocations
	out.has_exception_table = src.has_exception_table
	out.has_load_config = src.has_load_config

	out.sections = make([dynamic]vasperty_pe.Section_Info, 0, len(src.sections), allocator)
	for &s in src.sections {
		c := s
		c.name = strings.clone(s.name, allocator)
		append(&out.sections, c)
	}

	clone_mods :: proc(mods: ^[dynamic]vasperty_pe.Import_Module, allocator := context.allocator) -> [dynamic]vasperty_pe.Import_Module {
		dst := make([dynamic]vasperty_pe.Import_Module, 0, len(mods), allocator)
		for &m in mods {
			cm := vasperty_pe.Import_Module{
				dll     = strings.clone(m.dll, allocator),
				entries = make([dynamic]vasperty_pe.Import_Entry, 0, len(m.entries), allocator),
			}
			for &e in m.entries {
				ce := e
				if len(e.name) > 0 do ce.name = strings.clone(e.name, allocator)
				append(&cm.entries, ce)
			}
			append(&dst, cm)
		}
		return dst
	}
	out.imports = clone_mods(&src.imports, allocator)
	out.delay_imports = clone_mods(&src.delay_imports, allocator)
	out.exports = make([dynamic]vasperty_pe.Export_Entry, allocator)

	if src.has_tls {
		out.has_tls = true
		out.tls.directory_rva = src.tls.directory_rva
		out.tls.callbacks_va = src.tls.callbacks_va
		out.tls.callback_rvas = make([dynamic]u32, 0, len(src.tls.callback_rvas), allocator)
		for rva in src.tls.callback_rvas do append(&out.tls.callback_rvas, rva)
	}
	return out
}

@(private)
utf8_to_utf16_nul :: proc(s: string, allocator := context.allocator) -> ([]u16, bool) {
	buf := make([]u16, len(s) + 1, allocator)
	n := utf16.encode_string(buf[:len(s)], s)
	buf[n] = 0
	return buf, true
}

load_prepared :: proc(
	prepared: ^Prepared_Image,
	cache_dir: string,
	allocator := context.allocator,
) -> (img: Loaded_Image, err: Loader_Error) {
	if vasperty_core.ensure_outside_repo(cache_dir, allocator) != .None {
		return img, .Policy_Error
	}
	if mk_err := os.make_directory_all(cache_dir); mk_err != nil {
		if !os.is_dir(cache_dir) do return img, .Io_Error
	}

	fname := prepared_file_name(prepared, allocator)
	defer delete(fname, allocator)
	path, j_err := filepath.join({cache_dir, fname}, allocator)
	if j_err != nil do return img, .Io_Error

	if !write_if_changed(path, prepared.bytes, allocator) {
		delete(path, allocator)
		return img, .Io_Error
	}

	wpath, _ := utf8_to_utf16_nul(path, allocator)
	mod := win32.LoadLibraryExW(win32.wstring(&wpath[0]), nil, {})
	delete(wpath, allocator)
	if mod == nil {
		delete(path, allocator)
		return img, .Load_Library_Failed
	}

	info_copy := clone_image_info(&prepared.info, allocator)
	var_page: rawptr = nil
	if !vasperty_pe.is_dll(&info_copy) {
		_, page, ok_tls := tls_redirect(uintptr(mod), &info_copy)
		if !ok_tls {
			_ = win32.FreeLibrary(mod)
			vasperty_pe.destroy_image(&info_copy, allocator)
			delete(path, allocator)
			return img, .Tls_Redirect_Failed
		}
		var_page = page
	}

	img = Loaded_Image{
		module       = mod,
		path         = path,
		info         = info_copy,
		thunk_blocks = make([dynamic]Thunk_Block, allocator),
		tls_page     = var_page,
	}
	return img, .None
}

loaded_base :: proc(img: ^Loaded_Image) -> uintptr {
	return uintptr(img.module)
}

loaded_export_name :: proc(img: ^Loaded_Image, name: string, allocator := context.allocator) -> (uintptr, bool) {
	cname := strings.clone_to_cstring(name, allocator)
	defer delete(cname, allocator)
	p := win32.GetProcAddress(img.module, cname)
	return uintptr(p), p != nil
}

loaded_export_symbol :: proc(img: ^Loaded_Image, sym: ^vasperty_pe.Import_Entry, allocator := context.allocator) -> (uintptr, bool) {
	if sym.by_ordinal {
		p := win32.GetProcAddress(img.module, transmute(win32.LPCSTR)uintptr(sym.ordinal))
		return uintptr(p), p != nil
	}
	return loaded_export_name(img, sym.name, allocator)
}

loaded_bind_imports :: proc(
	img: ^Loaded_Image,
	resolver: Import_Resolver,
	policy: Unimplemented_Policy,
	allocator := context.allocator,
) -> (report: Bind_Report, err: Loader_Error) {
	report.missing = make([dynamic]Missing_Import, allocator)

	Slot_Patch :: struct {
		rva:  u32,
		addr: uintptr,
	}
	Unres_Item :: struct {
		rva: u32,
		dll: string,
		sym: string,
	}
	slots := make([dynamic]Slot_Patch, allocator)
	unresolved := make([dynamic]Unres_Item, allocator)
	defer {
		delete(slots)
		for u in unresolved do delete(u.sym, allocator)
		delete(unresolved)
	}

	scan_modules :: proc(
		mods: ^[dynamic]vasperty_pe.Import_Module,
		resolver: Import_Resolver,
		report: ^Bind_Report,
		slots: ^[dynamic]Slot_Patch,
		unresolved: ^[dynamic]Unres_Item,
		allocator := context.allocator,
	) {
		for &m in mods {
			for &e in m.entries {
				res := resolver.resolve(resolver.user_data, m.dll, &e)
				if res.found {
					switch res.provenance {
					case .Hle:   report.hle += 1
					case .Host:  report.host += 1
					case .Title: report.title += 1
					}
					append(slots, Slot_Patch{rva = e.iat_slot_rva, addr = res.address})
				} else {
					sym_str: string
					if e.by_ordinal {
						obuf: [16]u8
						sym_str = strings.clone(fmt.bprintf(obuf[:], "#%d", e.ordinal), allocator)
					} else {
						sym_str = strings.clone(e.name, allocator)
					}
					append(unresolved, Unres_Item{rva = e.iat_slot_rva, dll = m.dll, sym = sym_str})
				}
			}
		}
	}

	scan_modules(&img.info.imports, resolver, &report, &slots, &unresolved, allocator)
	scan_modules(&img.info.delay_imports, resolver, &report, &slots, &unresolved, allocator)

	if len(unresolved) > 0 {
		blk, ok_b := thunk_block_new(len(unresolved), allocator)
		if !ok_b {
			destroy_bind_report(&report, allocator)
			return report, .Thunk_Emit_Failed
		}
		for u in unresolved {
			addr, ok_e := thunk_block_emit(&blk, u.dll, u.sym, policy, allocator)
			if !ok_e {
				thunk_block_destroy(&blk, allocator)
				destroy_bind_report(&report, allocator)
				return report, .Thunk_Emit_Failed
			}
			append(&slots, Slot_Patch{rva = u.rva, addr = addr})
			append(&report.missing, Missing_Import{
				dll    = strings.clone(u.dll, allocator),
				symbol = strings.clone(u.sym, allocator),
			})
		}
		if !thunk_block_seal(&blk) {
			thunk_block_destroy(&blk, allocator)
			destroy_bind_report(&report, allocator)
			return report, .Thunk_Emit_Failed
		}
		append(&img.thunk_blocks, blk)
	}

	base := loaded_base(img)
	for sp in slots {
		slot_ptr := (^u64)(base + uintptr(sp.rva))
		old: win32.DWORD = 0
		if win32.VirtualProtect(rawptr(slot_ptr), 8, win32.PAGE_READWRITE, &old) == false {
			destroy_bind_report(&report, allocator)
			return report, .Virtual_Protect_Failed
		}
		slot_ptr^ = u64(sp.addr)
		ignored: win32.DWORD = 0
		_ = win32.VirtualProtect(rawptr(slot_ptr), 8, old, &ignored)
	}

	return report, .None
}

loaded_run_tls_callbacks :: proc(img: ^Loaded_Image, reason: u32, reserved: rawptr = nil) {
	if !img.info.has_tls do return
	Tls_Callback :: proc "system" (module: win32.HMODULE, reason: u32, reserved: rawptr)
	base := loaded_base(img)
	for rva in img.info.tls.callback_rvas {
		cb := Tls_Callback(rawptr(base + uintptr(rva)))
		cb(img.module, reason, reserved)
	}
}

loaded_attach :: proc(img: ^Loaded_Image) -> Loader_Error {
	loaded_run_tls_callbacks(img, DLL_PROCESS_ATTACH)
	if vasperty_pe.is_dll(&img.info) && img.info.entry_rva != 0 {
		Dll_Main :: proc "system" (module: win32.HMODULE, reason: u32, reserved: rawptr) -> i32
		dm := Dll_Main(rawptr(loaded_base(img) + uintptr(img.info.entry_rva)))
		if dm(img.module, DLL_PROCESS_ATTACH, nil) == 0 {
			return .Dll_Main_Failed
		}
	}
	img.attached = true
	return .None
}

loaded_detach :: proc(img: ^Loaded_Image) {
	if !img.attached do return
	img.attached = false
	loaded_run_tls_callbacks(img, DLL_PROCESS_DETACH)
	if vasperty_pe.is_dll(&img.info) && img.info.entry_rva != 0 {
		Dll_Main :: proc "system" (module: win32.HMODULE, reason: u32, reserved: rawptr) -> i32
		dm := Dll_Main(rawptr(loaded_base(img) + uintptr(img.info.entry_rva)))
		_ = dm(img.module, DLL_PROCESS_DETACH, nil)
	}
}

loaded_unload :: proc(img: ^Loaded_Image, allocator := context.allocator) {
	if img.attached {
		loaded_detach(img)
	}
	if img.module != nil {
		_ = win32.FreeLibrary(img.module)
	}
	for &tb in img.thunk_blocks {
		thunk_block_destroy(&tb, allocator)
	}
	delete(img.thunk_blocks)
	tls_free_page(img.tls_page)
	vasperty_pe.destroy_image(&img.info, allocator)
	if len(img.path) > 0 {
		delete(img.path, allocator)
	}
	img^ = {}
}
