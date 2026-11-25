package vasperty_cli

import "core:fmt"
import "core:os"
import vasperty_app "vasperty:app"
import vasperty_hle "vasperty:hle"

usage :: proc() {
	fmt.println("Vasperty Native Odin CLI (Phases 1-7 Complete)")
	fmt.println("Usage:")
	fmt.println("  vasperty.exe status")
	fmt.println("  vasperty.exe config")
	fmt.println("  vasperty.exe doctor [--prune-cache]")
	fmt.println("  vasperty.exe inspect <pe-path> [--imports] [--exports]")
	fmt.println("  vasperty.exe census <paths...> [--strict] [--missing]")
	fmt.println("  vasperty.exe translate <paths...> [--validate]")
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
		if len(rest) < 1 {
			fmt.eprintln("inspect requires <pe-path>")
			os.exit(2)
		}
		show_imp, show_exp := false, false
		for a in rest[1:] {
			if a == "--imports" { show_imp = true }
			if a == "--exports" { show_exp = true }
		}
		os.exit(vasperty_app.app_inspect(rest[0], show_imp, show_exp))

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
		paths := make([dynamic]string, 0, len(rest), context.temp_allocator)
		for a in rest {
			if a == "--validate" { validate = true }
			else { append(&paths, a) }
		}
		if len(paths) == 0 {
			fmt.eprintln("translate requires at least one path")
			os.exit(2)
		}
		_, code := vasperty_app.app_translate(paths[:], validate)
		os.exit(code)

	case "run":
		if len(rest) < 1 {
			fmt.eprintln("run requires <exe-path>")
			os.exit(2)
		}
		strict, execute, zero := false, false, false
		console := vasperty_hle.Console_Model.Series_X
		for a in rest[1:] {
			if a == "--strict" { strict = true }
			else if a == "--execute" { execute = true }
			else if a == "--zero" { zero = true }
			else if a == "--series-s" { console = .Series_S }
		}
		os.exit(vasperty_app.app_run(rest[0], strict, execute, zero, console))

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
