//! `victory doctor`: hardware, runtime, DXIL validator, and cache diagnostics.

use std::path::PathBuf;

use anyhow::Result;
use victory_pipeline::{Cache, CacheStats};
use victory_shader::emit::validator::Validator;

pub fn run(prune_cache: bool) -> Result<()> {
    let cfg = victory_core::Config::load()?;
    let threads = std::thread::available_parallelism().map_or(1, usize::from);

    println!("Vasperty Diagnostics");
    println!("====================");
    println!(
        "Host        : {}/{} ({} logical CPUs)",
        std::env::consts::OS,
        std::env::consts::ARCH,
        threads
    );
    println!(
        "Config      : {}",
        cfg.source
            .as_ref()
            .map_or("(defaults + env)".to_owned(), |p| p.display().to_string())
    );
    println!("Cache dir   : {}", cfg.cache_dir.display());
    println!("Data dir    : {}", cfg.data_dir.display());

    let policy_ok = [&cfg.cache_dir, &cfg.data_dir]
        .into_iter()
        .chain(cfg.game_dir.iter())
        .chain(&cfg.test_titles)
        .all(|p| victory_core::ensure_outside_repo(p).is_ok());
    println!(
        "Asset policy: {}",
        if policy_ok { "PASS (all dirs outside repo)" } else { "VIOLATION" }
    );

    println!();
    println!("GPU & Display Capabilities");
    println!("--------------------------");
    #[cfg(windows)]
    let gpu_ready = match victory_gpu::probe_capabilities() {
        Some(caps) => {
            println!(
                "Adapter     : {} (vendor {:#06x}, device {:#06x})",
                caps.adapter_name, caps.vendor_id, caps.device_id
            );
            println!(
                "VRAM / Sys  : {:.0} MiB dedicated / {:.0} MiB shared",
                caps.dedicated_video_memory as f64 / (1024.0 * 1024.0),
                caps.shared_system_memory as f64 / (1024.0 * 1024.0)
            );
            println!("Shader Model: {}", caps.highest_shader_model);
            println!(
                "Mesh Shaders: {} (tier {})",
                yes_no(caps.mesh_shaders),
                caps.mesh_shader_tier
            );
            println!("Depth Bounds: {}", yes_no(caps.depth_bounds));
            println!("Heap Atom64 : {}", yes_no(caps.heap_atomics64));
            println!(
                "FMAD Fused  : {}",
                match caps.fuses_fmad {
                    Some(true) => "yes (matches RDNA2 precision)",
                    Some(false) => "no (driver does not fuse FMad)",
                    None => "unknown",
                }
            );
            println!(
                "Wave Ops    : {} (lanes {}..={})",
                yes_no(caps.wave_ops),
                caps.wave_lane_count_min,
                caps.wave_lane_count_max
            );
            println!(
                "D3D12 Tiers : Binding={}, Heap={}, Raytracing={}, VRS={}",
                caps.resource_binding_tier,
                caps.resource_heap_tier,
                caps.raytracing_tier,
                caps.vrs_tier
            );
            println!(
                "Display     : {} modes enumerated, max {} Hz, tearing={}",
                caps.display_mode_count,
                caps.max_refresh_hz,
                yes_no(caps.allow_tearing)
            );
            caps.highest_shader_model >= "SM 6.6" && caps.wave_ops
        }
        None => {
            println!("Adapter     : (no hardware/D3D12 device available)");
            false
        }
    };
    #[cfg(not(windows))]
    let gpu_ready = false;

    println!();
    println!("Shader Toolchain");
    println!("----------------");
    match Validator::default_path() {
        Some(path) => match Validator::load(Some(&path)) {
            Ok(_) => println!("dxil.dll    : OK ({})", path.display()),
            Err(e) => println!("dxil.dll    : FAILED at {} ({e})", path.display()),
        },
        None => match Validator::load(None) {
            Ok(_) => println!("dxil.dll    : OK (loaded from DLL search path)"),
            Err(e) => println!("dxil.dll    : not found ({e})"),
        },
    }

    println!();
    println!("Runtime Tuning Env");
    println!("------------------");
    for var in [
        "VICTORY_HDR",
        "VICTORY_VSYNC",
        "VICTORY_PIPELINE_WORKERS",
        "VICTORY_PIPELINE_BUDGET_MS",
        "VICTORY_DSTORAGE_WORKERS",
        "VICTORY_DSP_REVERB",
        "VICTORY_TRIGGER_RUMBLE_BLEND",
    ] {
        let val = std::env::var(var).unwrap_or_else(|_| "(default)".to_owned());
        println!("{var:<28}: {val}");
    }

    println!();
    println!("Pipeline Cache");
    println!("--------------");
    let mut dirs = vec![cfg.cache_dir.clone()];
    if let Ok(entries) = std::fs::read_dir(&cfg.cache_dir) {
        for entry in entries.flatten() {
            let p = entry.path();
            if p.is_dir() && p.file_name().is_some_and(|n| n.len() > 2) {
                dirs.push(p);
            }
        }
    }
    let (mut total, mut removed, mut freed) = (CacheStats::default(), 0usize, 0u64);
    let mut seen: Vec<PathBuf> = Vec::new();
    for dir in dirs {
        if seen.contains(&dir) {
            continue;
        }
        seen.push(dir.clone());
        if let Ok(cache) = Cache::open(&dir) {
            if prune_cache
                && let Ok((n, b)) = cache.prune_stale_temps()
            {
                removed += n;
                freed += b;
            }
            if let Ok(s) = cache.stats() {
                total.entries += s.entries;
                total.total_bytes += s.total_bytes;
                total.stale_temps += s.stale_temps;
                total.stale_temp_bytes += s.stale_temp_bytes;
            }
        }
    }
    println!(
        "Cached items: {} ({:.2} MiB)",
        total.entries,
        total.total_bytes as f64 / (1024.0 * 1024.0)
    );
    println!(
        "Stale temps : {} ({} bytes){}",
        total.stale_temps,
        total.stale_temp_bytes,
        if prune_cache {
            format!(" — pruned {removed} files ({freed} bytes)")
        } else {
            String::new()
        }
    );

    println!();
    println!(
        "Summary     : {}",
        if gpu_ready && policy_ok {
            "READY for translated Xbox Series execution"
        } else if !policy_ok {
            "CHECK ASSET POLICY PATHS"
        } else {
            "LIMITED (missing SM 6.6+ GPU or wave ops)"
        }
    );
    Ok(())
}

fn yes_no(v: bool) -> &'static str {
    if v { "yes" } else { "no" }
}

#[cfg(test)]
mod tests {
    #[test]
    fn doctor_report_succeeds() {
        super::run(false).expect("doctor diagnostics should complete");
    }
}
