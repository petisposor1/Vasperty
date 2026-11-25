package vasperty_loader

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:sync"

@(private)
next_staging_id: u64 = 0

write_if_changed :: proc(path: string, data: []u8, allocator := context.allocator) -> bool {
	if existing, err := os.read_entire_file_from_path(path, allocator); err == nil {
		same := len(existing) == len(data)
		if same {
			for i := 0; i < len(data); i += 1 {
				if existing[i] != data[i] {
					same = false
					break
				}
			}
		}
		delete(existing, allocator)
		if same {
			return true
		}
	}

	dir := filepath.dir(path)
	if !os.is_dir(dir) {
		return false
	}
	base := filepath.base(path)
	if len(base) == 0 {
		base = "image"
	}

	pid := os.get_pid()
	seq := sync.atomic_add(&next_staging_id, 1)
	tmp_name := fmt.aprintf(".%s.%d.%d.tmp", base, pid, seq, allocator = allocator)
	defer delete(tmp_name, allocator)

	staging, j_err := filepath.join({dir, tmp_name}, allocator)
	if j_err != nil {
		return false
	}
	defer delete(staging, allocator)

	if w_err := os.write_entire_file(staging, data); w_err != nil {
		_ = os.remove(staging)
		return false
	}
	if r_err := os.rename(staging, path); r_err != nil {
		_ = os.remove(staging)
		return false
	}
	return true
}
