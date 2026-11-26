package vasperty_loader

import vasperty_pe "vasperty:pe"

Provenance :: enum {
	Hle,
	Host,
	Title,
}

Resolution :: struct {
	found:      bool,
	address:    uintptr,
	provenance: Provenance,
}

Import_Resolver :: struct {
	user_data: rawptr,
	resolve:   proc(user_data: rawptr, dll: string, entry: ^vasperty_pe.Import_Entry) -> Resolution,
}

Missing_Import :: struct {
	dll:    string,
	symbol: string,
}

Bind_Report :: struct {
	hle:     int,
	host:    int,
	title:   int,
	missing: [dynamic]Missing_Import,
}

destroy_bind_report :: proc(r: ^Bind_Report, allocator := context.allocator) {
	for &m in r.missing {
		delete(m.dll, allocator)
		delete(m.symbol, allocator)
	}
	delete(r.missing)
	r^ = {}
}
