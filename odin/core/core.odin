package vasperty_core

import "core:os"
import "core:path/filepath"
import "core:strings"

ROOT_MARKER_WIN :: "odin\\build.ps1"
ROOT_MARKER_LEGACY :: ".victory-root"

Policy_Error :: enum {
	None,
	Empty_Path,
	Inside_Repo,
	Io_Error,
}

Config :: struct {
	game_dir:           string,
	has_game_dir:       bool,
	cache_dir:          string,
	data_dir:           string,
	fidelityfx_dir:     string,
	has_fidelityfx_dir: bool,
	test_titles:        [dynamic]string,
	source:             string,
	has_source:         bool,
}

destroy_config :: proc(cfg: ^Config, allocator := context.allocator) {
	if cfg.has_game_dir {
		delete(cfg.game_dir, allocator)
	}
	delete(cfg.cache_dir, allocator)
	delete(cfg.data_dir, allocator)
	if cfg.has_fidelityfx_dir {
		delete(cfg.fidelityfx_dir, allocator)
	}
	if cfg.has_source {
		delete(cfg.source, allocator)
	}
	for title in cfg.test_titles {
		delete(title, allocator)
	}
	delete(cfg.test_titles)
	cfg^ = {}
}

// ensure_outside_repo verifies that `path` (even if not yet created) does not
// land inside any Vasperty source tree identified by `odin/build.ps1` or `.victory-root`.
ensure_outside_repo :: proc(path: string, allocator := context.allocator) -> Policy_Error {
	trimmed := strings.trim_space(path)
	if len(trimmed) == 0 {
		return .Empty_Path
	}

	abs_path: string
	owns_abs := false
	if filepath.is_abs(trimmed) {
		abs_path = trimmed
	} else {
		cwd, cwd_err := os.get_working_directory(allocator)
		if cwd_err != nil {
			return .Io_Error
		}
		defer delete(cwd, allocator)
		joined, join_err := filepath.join({cwd, trimmed}, allocator)
		if join_err != nil {
			return .Io_Error
		}
		abs_path = joined
		owns_abs = true
	}
	defer if owns_abs {
		delete(abs_path, allocator)
	}

	cleaned, clean_err := filepath.clean(abs_path, allocator)
	if clean_err != nil {
		return .Io_Error
	}
	defer delete(cleaned, allocator)

	cur := cleaned
	for len(cur) > 0 {
		marker, m_err := filepath.join({cur, ROOT_MARKER_WIN}, allocator)
		if m_err != nil {
			return .Io_Error
		}
		has_marker := os.is_file(marker)
		delete(marker, allocator)

		if !has_marker {
			legacy, l_err := filepath.join({cur, ROOT_MARKER_LEGACY}, allocator)
			if l_err != nil {
				return .Io_Error
			}
			has_marker = os.is_file(legacy)
			delete(legacy, allocator)
		}

		if has_marker {
			return .Inside_Repo
		}

		parent := filepath.dir(cur)
		if len(parent) == 0 || parent == cur {
			break
		}
		cur = parent
	}

	return .None
}

@(private)
parse_toml_quoted :: proc(raw: string) -> (val: string, ok: bool) {
	s := strings.trim_space(raw)
	// Strip trailing comment outside quotes.
	if len(s) >= 2 && (s[0] == '"' || s[0] == '\'') {
		quote := s[0]
		end := -1
		for i := 1; i < len(s); i += 1 {
			if s[i] == quote && (quote == '\'' || s[i - 1] != '\\') {
				end = i
				break
			}
		}
		if end > 0 {
			return s[1:end], true
		}
	}
	return "", false
}

@(private)
default_vasperty_dir :: proc(leaf: string, allocator := context.allocator) -> (string, bool) {
	if local, found := os.lookup_env("LOCALAPPDATA", allocator); found {
		defer delete(local, allocator)
		if len(local) > 0 {
			out, err := filepath.join({local, "Vasperty", leaf}, allocator)
			return out, err == nil
		}
	}
	if home, found := os.lookup_env("USERPROFILE", allocator); found {
		defer delete(home, allocator)
		if len(home) > 0 {
			out, err := filepath.join({home, "Vasperty", leaf}, allocator)
			return out, err == nil
		}
	}
	return strings.clone(leaf, allocator), true
}

@(private)
lookup_env_pair :: proc(primary, fallback: string, allocator := context.allocator) -> (string, bool) {
	if v, ok := os.lookup_env(primary, allocator); ok {
		if len(v) > 0 {
			return v, true
		}
		delete(v, allocator)
	}
	if v, ok := os.lookup_env(fallback, allocator); ok {
		if len(v) > 0 {
			return v, true
		}
		delete(v, allocator)
	}
	return "", false
}

// load_config resolves paths from environment variables, optional TOML config,
// and safe OS-local defaults outside the repository.
load_config :: proc(allocator := context.allocator) -> (cfg: Config, err: Policy_Error) {
	cfg.test_titles = make([dynamic]string, allocator)

	config_path := ""
	owns_cfg_path := false
	explicit_cfg := false
	if env_cfg, found := lookup_env_pair("VASPERTY_CONFIG", "VICTORY_CONFIG", allocator); found {
		config_path = env_cfg
		owns_cfg_path = true
		explicit_cfg = true
	} else if os.is_file("vasperty.toml") {
		config_path = "vasperty.toml"
	} else {
		config_path = "victory.toml"
	}
	defer if owns_cfg_path {
		delete(config_path, allocator)
	}

	file_game := ""
	file_cache := ""
	file_data := ""
	file_ffx := ""
	defer {
		if len(file_game) > 0 do delete(file_game, allocator)
		if len(file_cache) > 0 do delete(file_cache, allocator)
		if len(file_data) > 0 do delete(file_data, allocator)
		if len(file_ffx) > 0 do delete(file_ffx, allocator)
	}

	if os.is_file(config_path) {
		raw_bytes, read_err := os.read_entire_file_from_path(config_path, allocator)
		if read_err == nil {
			defer delete(raw_bytes, allocator)
			cfg.source = strings.clone(config_path, allocator)
			cfg.has_source = true
			in_paths := false
			it := string(raw_bytes)
			for line in strings.split_lines_iterator(&it) {
				trimmed := strings.trim_space(line)
				if len(trimmed) == 0 || trimmed[0] == '#' {
					continue
				}
				if trimmed[0] == '[' {
					in_paths = trimmed == "[paths]"
					continue
				}
				if !in_paths {
					continue
				}
				eq := strings.index_byte(trimmed, '=')
				if eq <= 0 {
					continue
				}
				key := strings.trim_space(trimmed[:eq])
				val, val_ok := parse_toml_quoted(trimmed[eq + 1:])
				if !val_ok {
					continue
				}
				switch key {
				case "game_dir":
					if len(file_game) > 0 do delete(file_game, allocator)
					file_game = strings.clone(val, allocator)
				case "cache_dir":
					if len(file_cache) > 0 do delete(file_cache, allocator)
					file_cache = strings.clone(val, allocator)
				case "data_dir":
					if len(file_data) > 0 do delete(file_data, allocator)
					file_data = strings.clone(val, allocator)
				case "fidelityfx_dir":
					if len(file_ffx) > 0 do delete(file_ffx, allocator)
					file_ffx = strings.clone(val, allocator)
				}
			}
		} else if explicit_cfg {
			destroy_config(&cfg, allocator)
			return cfg, .Io_Error
		}
	} else if explicit_cfg {
		destroy_config(&cfg, allocator)
		return cfg, .Io_Error
	}

	if env_game, ok_g := lookup_env_pair("VASPERTY_GAME_DIR", "VICTORY_GAME_DIR", allocator); ok_g {
		cfg.game_dir = env_game
		cfg.has_game_dir = true
	}
	if !cfg.has_game_dir && len(file_game) > 0 {
		cfg.game_dir = strings.clone(file_game, allocator)
		cfg.has_game_dir = true
	}

	if env_ffx, ok_f := lookup_env_pair("VASPERTY_FIDELITYFX_DIR", "VICTORY_FIDELITYFX_DIR", allocator); ok_f {
		cfg.fidelityfx_dir = env_ffx
		cfg.has_fidelityfx_dir = true
	}
	if !cfg.has_fidelityfx_dir && len(file_ffx) > 0 {
		cfg.fidelityfx_dir = strings.clone(file_ffx, allocator)
		cfg.has_fidelityfx_dir = true
	}

	if env_cache, ok_c := lookup_env_pair("VASPERTY_CACHE_DIR", "VICTORY_CACHE_DIR", allocator); ok_c {
		cfg.cache_dir = env_cache
	}
	if len(cfg.cache_dir) == 0 {
		if len(file_cache) > 0 {
			cfg.cache_dir = strings.clone(file_cache, allocator)
		} else {
			d, _ := default_vasperty_dir("cache", allocator)
			cfg.cache_dir = d
		}
	}

	if env_data, ok_d := lookup_env_pair("VASPERTY_DATA_DIR", "VICTORY_DATA_DIR", allocator); ok_d {
		cfg.data_dir = env_data
	}
	if len(cfg.data_dir) == 0 {
		if len(file_data) > 0 {
			cfg.data_dir = strings.clone(file_data, allocator)
		} else {
			d, _ := default_vasperty_dir("data", allocator)
			cfg.data_dir = d
		}
	}

	if env_titles, ok_t := lookup_env_pair("VASPERTY_TEST_TITLES", "VICTORY_TEST_TITLES", allocator); ok_t {
		defer delete(env_titles, allocator)
		it := env_titles
		for item in strings.split_iterator(&it, ";") {
			trimmed := strings.trim_space(item)
			if len(trimmed) > 0 {
				append(&cfg.test_titles, strings.clone(trimmed, allocator))
			}
		}
	}

	if p_err := ensure_outside_repo(cfg.cache_dir, allocator); p_err != .None {
		destroy_config(&cfg, allocator)
		return cfg, p_err
	}
	if p_err := ensure_outside_repo(cfg.data_dir, allocator); p_err != .None {
		destroy_config(&cfg, allocator)
		return cfg, p_err
	}

	return cfg, .None
}
