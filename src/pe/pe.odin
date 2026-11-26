package vasperty_pe

import "core:strings"

DOS_MAGIC :: 0x5A4D
NT_SIGNATURE :: 0x00004550
OPT64_MAGIC :: 0x020B
MACHINE_AMD64 :: 0x8664

FILE_FLAG_RELOCS_STRIPPED :: 0x0001
FILE_FLAG_DLL :: 0x2000

SUBSYSTEM_WINDOWS_GUI :: 2
SUBSYSTEM_WINDOWS_CUI :: 3
SUBSYSTEM_XBOX :: 14
SUBSYSTEM_XBOX_CODE_CATALOG :: 17

DIR_EXPORT :: 0
DIR_IMPORT :: 1
DIR_EXCEPTION :: 3
DIR_BASERELOC :: 5
DIR_DEBUG :: 6
DIR_TLS :: 9
DIR_LOAD_CONFIG :: 10
DIR_DELAY_IMPORT :: 13

MAX_TLS_CALLBACKS :: 1024
MAX_IMPORT_THUNKS :: 65536
MAX_IMPORT_MODULES :: 4096

Pe_Error :: enum {
	None,
	Truncated,
	Not_Dos,
	Not_Pe,
	Unsupported_Format,
	Unsupported_Machine,
	Malformed,
}

Section_Info :: struct {
	name:            string,
	rva:             u32,
	virtual_size:    u32,
	file_offset:     u32,
	file_size:       u32,
	characteristics: u32,
}

Import_Entry :: struct {
	by_ordinal:   bool,
	ordinal:      u16,
	hint:         u16,
	name:         string,
	iat_slot_rva: u32,
}

Import_Module :: struct {
	dll:     string,
	entries: [dynamic]Import_Entry,
}

Export_Entry :: struct {
	ordinal: u16,
	has_rva: bool,
	rva:     u32,
	name:    string,
	forward: string,
}

Tls_Info :: struct {
	directory_rva: u32,
	callbacks_va:  u64,
	callback_rvas: [dynamic]u32,
}

Image_Info :: struct {
	machine:             u16,
	characteristics:     u16,
	timestamp:           u32,
	subsystem:           u16,
	dll_characteristics: u16,
	image_base:          u64,
	size_of_image:       u32,
	entry_rva:           u32,
	stack_reserve:       u64,
	stack_commit:        u64,
	sections:            [dynamic]Section_Info,
	imports:             [dynamic]Import_Module,
	delay_imports:       [dynamic]Import_Module,
	exports:             [dynamic]Export_Entry,
	has_tls:             bool,
	tls:                 Tls_Info,
	has_relocations:     bool,
	has_exception_table: bool,
	has_load_config:     bool,
}

@(private)
read_u16 :: proc(data: []u8, at: int) -> (u16, bool) {
	if at < 0 || at + 2 > len(data) {
		return 0, false
	}
	v := u16(data[at]) | (u16(data[at + 1]) << 8)
	return v, true
}

@(private)
read_u32 :: proc(data: []u8, at: int) -> (u32, bool) {
	if at < 0 || at + 4 > len(data) {
		return 0, false
	}
	v := u32(data[at]) |
		(u32(data[at + 1]) << 8) |
		(u32(data[at + 2]) << 16) |
		(u32(data[at + 3]) << 24)
	return v, true
}

@(private)
read_u64 :: proc(data: []u8, at: int) -> (u64, bool) {
	lo, ok0 := read_u32(data, at)
	hi, ok1 := read_u32(data, at + 4)
	if !ok0 || !ok1 {
		return 0, false
	}
	return u64(lo) | (u64(hi) << 32), true
}

@(private)
read_cstr_at :: proc(data: []u8, at: int, max_len: int, allocator := context.allocator) -> (string, bool) {
	if at < 0 || at >= len(data) {
		return "", false
	}
	limit := min(len(data), at + max_len)
	end := at
	for end < limit && data[end] != 0 {
		end += 1
	}
	if end == limit && (end >= len(data) || data[end] != 0) {
		return "", false
	}
	return strings.clone(string(data[at:end]), allocator), true
}

@(private)
destroy_modules :: proc(mods: ^[dynamic]Import_Module, allocator := context.allocator) {
	for &m in mods {
		delete(m.dll, allocator)
		for &e in m.entries {
			if len(e.name) > 0 {
				delete(e.name, allocator)
			}
		}
		delete(m.entries)
	}
	delete(mods^)
}

destroy_image :: proc(info: ^Image_Info, allocator := context.allocator) {
	for &s in info.sections {
		delete(s.name, allocator)
	}
	delete(info.sections)
	destroy_modules(&info.imports, allocator)
	destroy_modules(&info.delay_imports, allocator)
	for &e in info.exports {
		if len(e.name) > 0 {
			delete(e.name, allocator)
		}
		if len(e.forward) > 0 {
			delete(e.forward, allocator)
		}
	}
	delete(info.exports)
	if info.has_tls {
		delete(info.tls.callback_rvas)
	}
	info^ = {}
}

is_dll :: proc(info: ^Image_Info) -> bool {
	return (info.characteristics & FILE_FLAG_DLL) != 0
}

subsystem_name :: proc(subsystem: u16) -> string {
	switch subsystem {
	case SUBSYSTEM_WINDOWS_GUI:
		return "windows-gui"
	case SUBSYSTEM_WINDOWS_CUI:
		return "windows-cui"
	case SUBSYSTEM_XBOX:
		return "xbox"
	case SUBSYSTEM_XBOX_CODE_CATALOG:
		return "xbox-code-catalog"
	case:
		return "other"
	}
}

// Names every PE DllCharacteristics bit (upstream #1988).
dll_characteristics_names :: proc(flags: u16, allocator := context.allocator) -> string {
	Bit_Name :: struct {
		bit:  u16,
		name: string,
	}
	TABLE := [?]Bit_Name{
		{0x0020, "HIGH_ENTROPY_VA"},
		{0x0040, "DYNAMIC_BASE"},
		{0x0080, "FORCE_INTEGRITY"},
		{0x0100, "NX_COMPAT"},
		{0x0200, "NO_ISOLATION"},
		{0x0400, "NO_SEH"},
		{0x0800, "NO_BIND"},
		{0x1000, "APPCONTAINER"},
		{0x2000, "WDM_DRIVER"},
		{0x4000, "GUARD_CF"},
		{0x8000, "TERMINAL_SERVER_AWARE"},
	}
	b := strings.builder_make(allocator)
	for entry in TABLE {
		if (flags & entry.bit) != 0 {
			if strings.builder_len(b) > 0 {
				strings.write_string(&b, " | ")
			}
			strings.write_string(&b, entry.name)
		}
	}
	if strings.builder_len(b) == 0 {
		strings.write_string(&b, "NONE")
	}
	return strings.to_string(b)
}

import_count :: proc(info: ^Image_Info) -> int {
	total := 0
	for &m in info.imports {
		total += len(m.entries)
	}
	return total
}

rva_to_file_offset :: proc(sections: []Section_Info, rva: u32) -> (u32, bool) {
	for &s in sections {
		if rva < s.rva {
			continue
		}
		delta := rva - s.rva
		backed := s.file_size
		if s.virtual_size > 0 && s.virtual_size < backed {
			backed = s.virtual_size
		}
		if delta >= backed {
			continue
		}
		off := u64(s.file_offset) + u64(delta)
		if off > u64(max(u32)) {
			return 0, false
		}
		return u32(off), true
	}
	return 0, false
}

@(private)
parse_import_thunks :: proc(
	data: []u8,
	sections: []Section_Info,
	size_of_image: u32,
	int_rva: u32,
	iat_rva: u32,
	out: ^[dynamic]Import_Entry,
	allocator := context.allocator,
) -> Pe_Error {
	int_off, ok_off := rva_to_file_offset(sections, int_rva)
	if !ok_off {
		return .Malformed
	}
	cur := int(int_off)
	for i := 0; i < MAX_IMPORT_THUNKS; i += 1 {
		thunk, ok_t := read_u64(data, cur)
		if !ok_t {
			return .Malformed
		}
		if thunk == 0 {
			return .None
		}
		iat_slot := u64(iat_rva) + u64(i) * 8
		if iat_slot + 8 > u64(size_of_image) {
			return .Malformed
		}
		entry: Import_Entry
		entry.iat_slot_rva = u32(iat_slot)
		if (thunk & (u64(1) << 63)) != 0 {
			entry.by_ordinal = true
			entry.ordinal = u16(thunk & 0xFFFF)
		} else {
			hint_rva := u32(thunk & 0x7FFF_FFFF)
			hint_off, ok_h := rva_to_file_offset(sections, hint_rva)
			if !ok_h {
				return .Malformed
			}
			hint, ok_hv := read_u16(data, int(hint_off))
			if !ok_hv {
				return .Malformed
			}
			name, ok_name := read_cstr_at(data, int(hint_off) + 2, 1024, allocator)
			if !ok_name {
				return .Malformed
			}
			entry.hint = hint
			entry.name = name
		}
		append(out, entry)
		cur += 8
	}
	return .None
}

parse_image :: proc(data: []u8, allocator := context.allocator) -> (info: Image_Info, err: Pe_Error) {
	info.sections = make([dynamic]Section_Info, allocator)
	info.imports = make([dynamic]Import_Module, allocator)
	info.delay_imports = make([dynamic]Import_Module, allocator)
	info.exports = make([dynamic]Export_Entry, allocator)

	dos_magic, ok_dos := read_u16(data, 0)
	if !ok_dos {
		destroy_image(&info, allocator)
		return info, .Truncated
	}
	if dos_magic != DOS_MAGIC {
		destroy_image(&info, allocator)
		return info, .Not_Dos
	}

	lfanew_u32, ok_lf := read_u32(data, 0x3C)
	if !ok_lf {
		destroy_image(&info, allocator)
		return info, .Truncated
	}
	lfanew := int(lfanew_u32)
	sig, ok_sig := read_u32(data, lfanew)
	if !ok_sig {
		destroy_image(&info, allocator)
		return info, .Truncated
	}
	if sig != NT_SIGNATURE {
		destroy_image(&info, allocator)
		return info, .Not_Pe
	}

	fh := lfanew + 4
	machine, ok_m := read_u16(data, fh)
	num_sections, ok_ns := read_u16(data, fh + 2)
	timestamp, ok_ts := read_u32(data, fh + 4)
	opt_size, ok_os := read_u16(data, fh + 16)
	chars, ok_ch := read_u16(data, fh + 18)
	if !ok_m || !ok_ns || !ok_ts || !ok_os || !ok_ch {
		destroy_image(&info, allocator)
		return info, .Truncated
	}
	if machine != MACHINE_AMD64 {
		destroy_image(&info, allocator)
		return info, .Unsupported_Machine
	}

	opt := fh + 20
	if int(opt_size) < 112 || opt + int(opt_size) > len(data) {
		destroy_image(&info, allocator)
		return info, .Truncated
	}
	opt_magic, _ := read_u16(data, opt)
	if opt_magic != OPT64_MAGIC {
		destroy_image(&info, allocator)
		return info, .Unsupported_Format
	}

	entry_rva, _ := read_u32(data, opt + 16)
	image_base, _ := read_u64(data, opt + 24)
	size_of_image, _ := read_u32(data, opt + 56)
	subsystem, _ := read_u16(data, opt + 68)
	dll_chars, _ := read_u16(data, opt + 70)
	stack_reserve, _ := read_u64(data, opt + 72)
	stack_commit, _ := read_u64(data, opt + 80)
	num_rva_sizes, _ := read_u32(data, opt + 108)

	info.machine = machine
	info.characteristics = chars
	info.timestamp = timestamp
	info.subsystem = subsystem
	info.dll_characteristics = dll_chars
	info.image_base = image_base
	info.size_of_image = size_of_image
	info.entry_rva = entry_rva
	info.stack_reserve = stack_reserve
	info.stack_commit = stack_commit

	sec_table := opt + int(opt_size)
	for i := 0; i < int(num_sections); i += 1 {
		base := sec_table + i * 40
		if base + 40 > len(data) {
			destroy_image(&info, allocator)
			return info, .Truncated
		}
		raw_name := data[base : base + 8]
		name_end := 0
		for name_end < 8 && raw_name[name_end] != 0 {
			name_end += 1
		}
		vsize, _ := read_u32(data, base + 8)
		vrva, _ := read_u32(data, base + 12)
		fsize, _ := read_u32(data, base + 16)
		foff, _ := read_u32(data, base + 20)
		schars, _ := read_u32(data, base + 36)

		if fsize > 0 {
			end := u64(foff) + u64(fsize)
			if end > u64(len(data)) {
				destroy_image(&info, allocator)
				return info, .Malformed
			}
		}

		append(&info.sections, Section_Info{
			name            = strings.clone(string(raw_name[:name_end]), allocator),
			rva             = vrva,
			virtual_size    = vsize,
			file_offset     = foff,
			file_size       = fsize,
			characteristics = schars,
		})
	}

	read_dir :: proc(data: []u8, opt: int, num_dirs: u32, idx: int) -> (rva: u32, size: u32, present: bool) {
		if idx < 0 || u32(idx) >= num_dirs {
			return 0, 0, false
		}
		at := opt + 112 + idx * 8
		r, ok0 := read_u32(data, at)
		s, ok1 := read_u32(data, at + 4)
		if !ok0 || !ok1 || r == 0 || s == 0 {
			return 0, 0, false
		}
		return r, s, true
	}

	_, _, has_reloc := read_dir(data, opt, num_rva_sizes, DIR_BASERELOC)
	_, _, has_exc := read_dir(data, opt, num_rva_sizes, DIR_EXCEPTION)
	_, _, has_lc := read_dir(data, opt, num_rva_sizes, DIR_LOAD_CONFIG)
	info.has_relocations = has_reloc && (chars & FILE_FLAG_RELOCS_STRIPPED) == 0
	info.has_exception_table = has_exc
	info.has_load_config = has_lc

	// Standard Import Table
	if imp_rva, _, has_imp := read_dir(data, opt, num_rva_sizes, DIR_IMPORT); has_imp {
		imp_off, ok_io := rva_to_file_offset(info.sections[:], imp_rva)
		if !ok_io {
			destroy_image(&info, allocator)
			return info, .Malformed
		}
		cur := int(imp_off)
		for m := 0; m < MAX_IMPORT_MODULES; m += 1 {
			int_rva, ok0 := read_u32(data, cur)
			name_rva, ok1 := read_u32(data, cur + 12)
			iat_rva, ok2 := read_u32(data, cur + 16)
			if !ok0 || !ok1 || !ok2 {
				destroy_image(&info, allocator)
				return info, .Malformed
			}
			if int_rva == 0 && name_rva == 0 && iat_rva == 0 {
				break
			}
			name_off, ok_no := rva_to_file_offset(info.sections[:], name_rva)
			if !ok_no {
				destroy_image(&info, allocator)
				return info, .Malformed
			}
			dll, ok_dll := read_cstr_at(data, int(name_off), 512, allocator)
			if !ok_dll {
				destroy_image(&info, allocator)
				return info, .Malformed
			}
			mod: Import_Module
			mod.dll = dll
			mod.entries = make([dynamic]Import_Entry, allocator)
			lookup := int_rva if int_rva != 0 else iat_rva
			if t_err := parse_import_thunks(data, info.sections[:], size_of_image, lookup, iat_rva, &mod.entries, allocator); t_err != .None {
				delete(mod.dll, allocator)
				for &e in mod.entries {
					if len(e.name) > 0 do delete(e.name, allocator)
				}
				delete(mod.entries)
				destroy_image(&info, allocator)
				return info, t_err
			}
			append(&info.imports, mod)
			cur += 20
		}
	}

	// TLS Callbacks
	if tls_rva, _, has_tls := read_dir(data, opt, num_rva_sizes, DIR_TLS); has_tls {
		tls_off, ok_to := rva_to_file_offset(info.sections[:], tls_rva)
		if !ok_to {
			destroy_image(&info, allocator)
			return info, .Malformed
		}
		callbacks_va, ok_cb := read_u64(data, int(tls_off) + 24)
		if !ok_cb {
			destroy_image(&info, allocator)
			return info, .Malformed
		}
		info.has_tls = true
		info.tls.directory_rva = tls_rva
		info.tls.callbacks_va = callbacks_va
		info.tls.callback_rvas = make([dynamic]u32, allocator)
		if callbacks_va != 0 {
			if callbacks_va < image_base || callbacks_va - image_base > u64(max(u32)) {
				destroy_image(&info, allocator)
				return info, .Malformed
			}
			arr_rva := u32(callbacks_va - image_base)
			arr_off, ok_ao := rva_to_file_offset(info.sections[:], arr_rva)
			if !ok_ao {
				destroy_image(&info, allocator)
				return info, .Malformed
			}
			cur := int(arr_off)
			for i := 0; i < MAX_TLS_CALLBACKS; i += 1 {
				va, ok_va := read_u64(data, cur)
				if !ok_va {
					destroy_image(&info, allocator)
					return info, .Malformed
				}
				if va == 0 {
					break
				}
				if va < image_base || va - image_base > u64(max(u32)) {
					destroy_image(&info, allocator)
					return info, .Malformed
				}
				append(&info.tls.callback_rvas, u32(va - image_base))
				cur += 8
			}
		}
	}

	return info, .None
}
