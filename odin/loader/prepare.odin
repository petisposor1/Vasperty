package vasperty_loader

import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:slice"

import vasperty_pe "vasperty:pe"

Prepare_Error :: enum {
	None,
	Pe_Error,
	Missing_Header,
	Overflow,
	Bad_Bounds,
}

Prepared_Image :: struct {
	info:          vasperty_pe.Image_Info,
	bytes:         []u8,
	original_hash: [32]u8,
}

@(private)
IMPORT_DESCRIPTOR_SIZE :: u32(20)
@(private)
IMAGE_REL_BASED_DIR64 :: u16(10)

@(private)
rd_u16 :: #force_inline proc(b: []u8, at: int) -> (u16, bool) {
	if at < 0 || at + 2 > len(b) do return 0, false
	return u16(b[at]) | (u16(b[at + 1]) << 8), true
}

@(private)
rd_u32 :: #force_inline proc(b: []u8, at: int) -> (u32, bool) {
	if at < 0 || at + 4 > len(b) do return 0, false
	return u32(b[at]) | (u32(b[at + 1]) << 8) | (u32(b[at + 2]) << 16) | (u32(b[at + 3]) << 24), true
}

@(private)
wr_u16 :: #force_inline proc(b: []u8, at: int, v: u16) -> bool {
	if at < 0 || at + 2 > len(b) do return false
	b[at] = u8(v)
	b[at + 1] = u8(v >> 8)
	return true
}

@(private)
wr_u32 :: #force_inline proc(b: []u8, at: int, v: u32) -> bool {
	if at < 0 || at + 4 > len(b) do return false
	b[at] = u8(v)
	b[at + 1] = u8(v >> 8)
	b[at + 2] = u8(v >> 16)
	b[at + 3] = u8(v >> 24)
	return true
}

@(private)
wr_u64 :: #force_inline proc(b: []u8, at: int, v: u64) -> bool {
	return wr_u32(b, at, u32(v)) && wr_u32(b, at + 4, u32(v >> 32))
}

@(private)
file_header_offset :: proc(data: []u8) -> (int, bool) {
	lfanew, ok := rd_u32(data, 0x3C)
	if !ok do return 0, false
	return int(lfanew) + 4, true
}

@(private)
opt_header_offset :: proc(data: []u8) -> (int, bool) {
	fh, ok := file_header_offset(data)
	if !ok do return 0, false
	return fh + 20, true
}

@(private)
data_dir_offset :: proc(data: []u8, index: int) -> (int, bool) {
	opt, ok := opt_header_offset(data)
	if !ok do return 0, false
	cnt, ok_c := rd_u32(data, opt + 108)
	if !ok_c || index < 0 || u32(index) >= cnt do return 0, false
	return opt + 112 + index * 8, true
}

destroy_prepared_image :: proc(p: ^Prepared_Image, allocator := context.allocator) {
	vasperty_pe.destroy_image(&p.info, allocator)
	if len(p.bytes) > 0 {
		delete(p.bytes, allocator)
	}
	p^ = {}
}

prepared_file_name :: proc(p: ^Prepared_Image, allocator := context.allocator) -> string {
	h := p.original_hash
	encoded := hex.encode(h[:8], allocator)
	defer delete(encoded, allocator)
	return fmt.aprintf("vasperty-image-%s.dll", string(encoded), allocator = allocator)
}

@(private)
Reloc_Patch :: struct {
	offset: int,
	target: u32,
}

@(private)
collect_dir64_relocs :: proc(bytes: []u8, info: ^vasperty_pe.Image_Info, allocator := context.allocator) -> [dynamic]Reloc_Patch {
	out := make([dynamic]Reloc_Patch, allocator)
	dd_at, ok_dd := data_dir_offset(bytes, vasperty_pe.DIR_BASERELOC)
	if !ok_dd do return out
	rva, ok_r := rd_u32(bytes, dd_at)
	sz, ok_s := rd_u32(bytes, dd_at + 4)
	if !ok_r || !ok_s || sz == 0 do return out
	start_u32, ok_off := vasperty_pe.rva_to_file_offset(info.sections[:], rva)
	if !ok_off do return out

	at := int(start_u32)
	end := min(len(bytes), at + int(sz))
	for at + 8 <= end {
		page, ok_p := rd_u32(bytes, at)
		blk, ok_b := rd_u32(bytes, at + 4)
		if !ok_p || !ok_b do break
		block := int(blk)
		if block < 8 || at + block > end do break
		for entry := at + 8; entry + 2 <= at + block; entry += 2 {
			e, _ := rd_u16(bytes, entry)
			if (e >> 12) == IMAGE_REL_BASED_DIR64 {
				append(&out, Reloc_Patch{offset = entry, target = page + u32(e & 0x0FFF)})
			}
		}
		at += block
	}
	return out
}

// prepare_image patches an x64 PE32+ executable/DLL so Windows maps it safely
// as a DLL without executing its original entry point, imports, or TLS callbacks.
prepare_image :: proc(original: []u8, allocator := context.allocator) -> (out: Prepared_Image, err: Prepare_Error) {
	info, pe_err := vasperty_pe.parse_image(original, allocator)
	if pe_err != .None {
		return out, .Pe_Error
	}

	bytes, alloc_err := slice.clone(original, allocator)
	if alloc_err != nil {
		vasperty_pe.destroy_image(&info, allocator)
		return out, .Bad_Bounds
	}

	fh, ok_fh := file_header_offset(bytes)
	opt, ok_opt := opt_header_offset(bytes)
	if !ok_fh || !ok_opt {
		delete(bytes, allocator)
		vasperty_pe.destroy_image(&info, allocator)
		return out, .Missing_Header
	}

	// Mark DLL, clear entry point, zero checksum, strip FORCE_INTEGRITY (0x0080).
	if !wr_u16(bytes, fh + 18, info.characteristics | vasperty_pe.FILE_FLAG_DLL) ||
		!wr_u32(bytes, opt + 16, 0) ||
		!wr_u32(bytes, opt + 64, 0) ||
		!wr_u16(bytes, opt + 70, info.dll_characteristics & ~u16(0x0080)) {
		delete(bytes, allocator)
		vasperty_pe.destroy_image(&info, allocator)
		return out, .Bad_Bounds
	}

	// Redirect DIR_IMPORT to its null terminator so OS allocates static TLS while resolving nothing.
	if imp_at, ok_imp := data_dir_offset(bytes, vasperty_pe.DIR_IMPORT); ok_imp {
		rva, ok_r := rd_u32(bytes, imp_at)
		if !ok_r {
			delete(bytes, allocator)
			vasperty_pe.destroy_image(&info, allocator)
			return out, .Bad_Bounds
		}
		if rva != 0 {
			delta := u64(len(info.imports)) * u64(IMPORT_DESCRIPTOR_SIZE)
			if u64(rva) + delta > u64(max(u32)) {
				delete(bytes, allocator)
				vasperty_pe.destroy_image(&info, allocator)
				return out, .Overflow
			}
			terminator := rva + u32(delta)
			if !wr_u32(bytes, imp_at, terminator) || !wr_u32(bytes, imp_at + 4, IMPORT_DESCRIPTOR_SIZE) {
				delete(bytes, allocator)
				vasperty_pe.destroy_image(&info, allocator)
				return out, .Bad_Bounds
			}
		}
	}

	// Clear DIR_BOUND_IMPORT (index 11)
	if bound_at, ok_b := data_dir_offset(bytes, 11); ok_b {
		_ = wr_u64(bytes, bound_at, 0)
	}

	// Clear TLS callbacks pointer + suppress DIR64 relocation targeting it.
	if info.has_tls && info.tls.callbacks_va != 0 {
		tls_off, ok_to := vasperty_pe.rva_to_file_offset(info.sections[:], info.tls.directory_rva)
		if !ok_to || !wr_u64(bytes, int(tls_off) + 24, 0) {
			delete(bytes, allocator)
			vasperty_pe.destroy_image(&info, allocator)
			return out, .Bad_Bounds
		}
		field_rva := info.tls.directory_rva + 24
		relocs := collect_dir64_relocs(bytes, &info, allocator)
		defer delete(relocs)
		for rp in relocs {
			if rp.target == field_rva {
				_ = wr_u16(bytes, rp.offset, 0)
			}
		}
	}

	ctx: hash.Context
	hash.init(&ctx, .SHA256)
	hash.update(&ctx, original)
	hash.final(&ctx, out.original_hash[:])

	out.info = info
	out.bytes = bytes
	return out, .None
}
