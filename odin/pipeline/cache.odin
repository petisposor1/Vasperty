package vasperty_pipeline

import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"

import vasperty_core "vasperty:core"

Cache_Key :: struct {
	digest: [32]u8,
}

Cache :: struct {
	root: string,
}

Cache_Stats :: struct {
	entries:          int,
	total_bytes:      u64,
	stale_temps:      int,
	stale_temp_bytes: u64,
}

Cache_Error :: enum {
	None,
	Inside_Repo,
	Io_Error,
	Convert_Failed,
	Staging_Exhausted,
}

@(private)
staging_counter: u64 = 0

cache_key_from_parts :: proc(converter_id: string, version: u32, parts: [][]u8) -> Cache_Key {
	ctx: hash.Context
	hash.init(&ctx, .SHA256)
	hash.update(&ctx, transmute([]u8)converter_id)
	sep := [1]u8{0}
	hash.update(&ctx, sep[:])
	ver := [4]u8{
		u8(version),
		u8(version >> 8),
		u8(version >> 16),
		u8(version >> 24),
	}
	hash.update(&ctx, ver[:])
	for p in parts {
		if len(p) > 0 {
			hash.update(&ctx, p)
		}
	}
	out: Cache_Key
	hash.final(&ctx, out.digest[:])
	return out
}

cache_key_hex :: proc(key: Cache_Key, allocator := context.allocator) -> string {
	k := key
	encoded := hex.encode(k.digest[:], allocator)
	return string(encoded)
}

cache_open :: proc(root: string, allocator := context.allocator) -> (c: Cache, err: Cache_Error) {
	if p_err := vasperty_core.ensure_outside_repo(root, allocator); p_err != .None {
		return c, .Inside_Repo
	}
	if mk_err := os.make_directory_all(root); mk_err != nil {
		if !os.is_dir(root) {
			return c, .Io_Error
		}
	}
	c.root = strings.clone(root, allocator)
	return c, .None
}

cache_destroy :: proc(c: ^Cache, allocator := context.allocator) {
	if len(c.root) > 0 {
		delete(c.root, allocator)
	}
	c^ = {}
}

cache_path_for :: proc(c: ^Cache, key: Cache_Key, allocator := context.allocator) -> (string, bool) {
	hex_key := cache_key_hex(key, allocator)
	defer delete(hex_key, allocator)
	out, err := filepath.join({c.root, hex_key[:2], hex_key[2:]}, allocator)
	return out, err == nil
}

@(private)
create_staging_file :: proc(dir: string, allocator := context.allocator) -> (path: string, file: ^os.File, err: Cache_Error) {
	pid := os.get_pid()
	for attempt := 0; attempt < 128; attempt += 1 {
		n := sync.atomic_add(&staging_counter, 1)
		name := fmt.aprintf(".tmp-%d-%d", pid, n, allocator = allocator)
		defer delete(name, allocator)
		candidate, j_err := filepath.join({dir, name}, allocator)
		if j_err != nil {
			return "", nil, .Io_Error
		}
		f, o_err := os.open(candidate, os.O_WRONLY | os.O_CREATE | os.O_EXCL, os.Permissions_Read_Write_All)
		if o_err == nil {
			return candidate, f, .None
		}
		delete(candidate, allocator)
	}
	return "", nil, .Staging_Exhausted
}

cache_read_or_convert_parts :: proc(
	c: ^Cache,
	converter_id: string,
	version: u32,
	parts: [][]u8,
	user_data: rawptr,
	convert_proc: proc(user_data: rawptr, parts: [][]u8, allocator := context.allocator) -> ([]u8, bool),
	allocator := context.allocator,
) -> (data: []u8, path: string, hit: bool, err: Cache_Error) {
	key := cache_key_from_parts(converter_id, version, parts)
	target, p_ok := cache_path_for(c, key, allocator)
	if !p_ok {
		return nil, "", false, .Io_Error
	}

	if existing, r_err := os.read_entire_file_from_path(target, allocator); r_err == nil {
		return existing, target, true, .None
	}

	output, c_ok := convert_proc(user_data, parts, allocator)
	if !c_ok {
		delete(target, allocator)
		return nil, "", false, .Convert_Failed
	}

	shard := filepath.dir(target)
	if mk_err := os.make_directory_all(shard); mk_err != nil {
		if !os.is_dir(shard) {
			delete(output, allocator)
			delete(target, allocator)
			return nil, "", false, .Io_Error
		}
	}

	tmp_path, f, st_err := create_staging_file(shard, allocator)
	if st_err != .None {
		delete(output, allocator)
		delete(target, allocator)
		return nil, "", false, st_err
	}
	defer delete(tmp_path, allocator)

	written_ok := true
	total_written := 0
	for total_written < len(output) {
		n, w_err := os.write(f, output[total_written:])
		if w_err != nil || n == 0 {
			written_ok = false
			break
		}
		total_written += n
	}
	_ = os.close(f)

	if !written_ok {
		_ = os.remove(tmp_path)
		delete(output, allocator)
		delete(target, allocator)
		return nil, "", false, .Io_Error
	}

	if ren_err := os.rename(tmp_path, target); ren_err != nil {
		// Another writer may have won a concurrent race on Windows; check target before failing.
		if existing, r2_err := os.read_entire_file_from_path(target, allocator); r2_err == nil {
			_ = os.remove(tmp_path)
			delete(output, allocator)
			return existing, target, true, .None
		}
		_ = os.remove(tmp_path)
		delete(output, allocator)
		delete(target, allocator)
		return nil, "", false, .Io_Error
	}

	return output, target, false, .None
}

cache_stats :: proc(c: ^Cache, allocator := context.allocator) -> (stats: Cache_Stats, err: Cache_Error) {
	if !os.is_dir(c.root) {
		return stats, .None
	}
	root_f, r_err := os.open(c.root)
	if r_err != nil {
		return stats, .Io_Error
	}
	shards, rd_err := os.read_all_directory(root_f, allocator)
	_ = os.close(root_f)
	if rd_err != nil {
		return stats, .Io_Error
	}
	defer os.file_info_slice_delete(shards, allocator)

	for sh in shards {
		if sh.type != .Directory {
			continue
		}
		sf, s_err := os.open(sh.fullpath)
		if s_err != nil {
			continue
		}
		items, id_err := os.read_all_directory(sf, allocator)
		_ = os.close(sf)
		if id_err != nil {
			continue
		}
		for it in items {
			if it.type != .Regular {
				continue
			}
			if strings.has_prefix(it.name, ".tmp-") {
				stats.stale_temps += 1
				stats.stale_temp_bytes += u64(max(0, it.size))
			} else {
				stats.entries += 1
				stats.total_bytes += u64(max(0, it.size))
			}
		}
		os.file_info_slice_delete(items, allocator)
	}
	return stats, .None
}

cache_prune_stale_temps :: proc(c: ^Cache, allocator := context.allocator) -> (removed: int, freed: u64, err: Cache_Error) {
	if !os.is_dir(c.root) {
		return 0, 0, .None
	}
	root_f, r_err := os.open(c.root)
	if r_err != nil {
		return 0, 0, .Io_Error
	}
	shards, rd_err := os.read_all_directory(root_f, allocator)
	_ = os.close(root_f)
	if rd_err != nil {
		return 0, 0, .Io_Error
	}
	defer os.file_info_slice_delete(shards, allocator)

	for sh in shards {
		if sh.type != .Directory {
			continue
		}
		sf, s_err := os.open(sh.fullpath)
		if s_err != nil {
			continue
		}
		items, id_err := os.read_all_directory(sf, allocator)
		_ = os.close(sf)
		if id_err != nil {
			continue
		}
		for it in items {
			if it.type != .Regular || !strings.has_prefix(it.name, ".tmp-") {
				continue
			}
			sz := u64(max(0, it.size))
			if os.remove(it.fullpath) == nil {
				removed += 1
				freed += sz
			}
		}
		os.file_info_slice_delete(items, allocator)
	}
	return removed, freed, .None
}
