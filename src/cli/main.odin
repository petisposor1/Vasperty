package vasperty_cli

import "core:fmt"
import "core:os"
import "core:strconv"
import vasperty_app "vasperty:app"
import vasperty_hle "vasperty:hle"
import vasperty_shader "vasperty:shader"

usage :: proc() {
	fmt.println("Vasperty CLI")
	fmt.println("Usage:")
	fmt.println("  vasperty.exe status")
	fmt.println("  vasperty.exe config")
	fmt.println("  vasperty.exe doctor [--prune-cache]")
	fmt.println("  vasperty.exe inspect <pe-path> [--imports] [--exports]")
	fmt.println("  vasperty.exe census <paths...> [--strict] [--missing]")
	fmt.println("  vasperty.exe translate <paths...> [--validate] [--wave16|--wave32|--wave64] [--jobs N]")
	fmt.println("  vasperty.exe probe <archives...> [--scan]")
	fmt.println("  vasperty.exe run <exe> [--strict] [--zero] [--execute] [--series-s]")
	fmt.println("  vasperty.exe bench [seconds]")
}

main :: proc() {
	if len(os.args) < 2 {
		usage()
		os.exit(0)
	}
	cmd := os.args[1]
	rest := os.args[2:]

	switch cmd {
	case "status":
		os.exit(vasperty_app.app_status())

	case "config":
		os.exit(vasperty_app.app_config())

	case "doctor":
		prune := false
		for a in rest {
			if a == "--prune-cache" { prune = true }
		}
		os.exit(vasperty_app.app_doctor(prune))

	case "inspect":
		show_imp, show_exp := false, false
		path := ""
		for a in rest {
			if a == "--imports" { show_imp = true }
			else if a == "--exports" { show_exp = true }
			else if path == "" { path = a }
		}
		if path == "" {
			fmt.eprintln("inspect requires <pe-path>")
			os.exit(2)
		}
		os.exit(vasperty_app.app_inspect(path, show_imp, show_exp))

	case "census":
		strict, missing := false, false
		paths := make([dynamic]string, 0, len(rest), context.temp_allocator)
		for a in rest {
			if a == "--strict" { strict = true }
			else if a == "--missing" { missing = true }
			else { append(&paths, a) }
		}
		if len(paths) == 0 {
			fmt.eprintln("census requires at least one path")
			os.exit(2)
		}
		os.exit(vasperty_app.app_census(paths[:], strict, missing))

	case "translate":
		validate := false
		wave := vasperty_shader.Target_Wave_Mode.Auto
		jobs := 0
		paths := make([dynamic]string, 0, len(rest), context.temp_allocator)
		for i := 0; i < len(rest); i += 1 {
			a := rest[i]
			if a == "--validate" { validate = true }
			else if a == "--wave16" { wave = .Wave16 }
			else if a == "--wave32" { wave = .Wave32 }
			else if a == "--wave64" { wave = .Wave64 }
			else if a == "--jobs" {
				if i + 1 >= len(rest) {
					fmt.eprintln("translate: --jobs requires a positive integer")
					os.exit(2)
				}
				i += 1
				v, ok := strconv.parse_int(rest[i])
				if !ok || v <= 0 {
					fmt.eprintln("translate: --jobs must be >= 1")
					os.exit(2)
				}
				jobs = v
			} else { append(&paths, a) }
		}
		if len(paths) == 0 {
			fmt.eprintln("translate requires at least one path")
			os.exit(2)
		}
		_, code := vasperty_app.app_translate(paths[:], validate, wave, jobs)
		os.exit(code)

	case "probe":
		scan := false
		paths := make([dynamic]string, 0, len(rest), context.temp_allocator)
		for a in rest {
			if a == "--scan" { scan = true }
			else { append(&paths, a) }
		}
		if len(paths) == 0 {
			fmt.eprintln("probe requires at least one archive path")
			os.exit(2)
		}
		os.exit(vasperty_app.app_probe(paths[:], scan))

	case "run":
		strict, execute, zero := false, false, false
		console := vasperty_hle.Console_Model.Series_X
		exe := ""
		for a in rest {
			if a == "--strict" { strict = true }
			else if a == "--execute" { execute = true }
			else if a == "--zero" { zero = true }
			else if a == "--series-s" { console = .Series_S }
			else if exe == "" { exe = a }
		}
		if exe == "" {
			fmt.eprintln("run requires <exe-path>")
			os.exit(2)
		}
		os.exit(vasperty_app.app_run(exe, strict, execute, zero, console))

	case "bench":
		secs := 2.0
		if len(rest) >= 1 {
			secs = vasperty_app.parse_bench_seconds(rest[0])
		}
		os.exit(vasperty_app.app_bench(secs))

	case:
		usage()
		os.exit(2)
	}
}
