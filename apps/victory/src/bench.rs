//! `victory bench`: deterministic zero-asset microbenchmarks for Vasperty's
//! hot paths (texture detiling, BCPack tables, GFX10 -> DXIL translation).

use std::hint::black_box;
use std::time::{Duration, Instant};

use anyhow::Result;
use victory_formats::bcpack::Tables;
use victory_formats::texture::{Desc, Dimension, Layout, Swizzle};
use victory_formats::xma::{Decoder as XmaDecoder, FRAME_SAMPLES as XMA_FRAME_SAMPLES};
use victory_shader::native::{ComputeIo, StageIo};
use victory_shader::{Container, HwStage, NativeProgram, emit, io, ir, resource, structure};

pub fn run(iters: usize) -> Result<()> {
    let iters = iters.max(1);
    let threads = std::thread::available_parallelism().map_or(1, usize::from);
    println!("Vasperty Microbenchmarks ({iters} iterations/workload, {threads} CPUs)");
    println!("==================================================================");

    // 1. 2D BC7 1024x1024 parallel texture detile (1 MiB)
    bench_detile_2d(iters)?;

    // 2. 3D RGBA8 64x64x32 parallel volume detile (512 KiB)
    bench_detile_3d(iters)?;

    // 3. BCPack built-in table parse (`bcpack-tables.bin`)
    bench_bcpack_tables(iters)?;

    // 4. XMA2 stereo frame decode throughput (`victory-formats::xma`)
    bench_xma2_decode(iters)?;

    // 5. GFX10 -> IR -> Structure -> Resource -> I/O -> DXIL SM 6.6 pipeline
    bench_shader_translate(iters)?;

    Ok(())
}

fn bench_detile_2d(iters: usize) -> Result<()> {
    // 1024x1024 BC7 = 256x256 elements x 16 bytes = 1 MiB
    let desc = Desc {
        dimension: Dimension::Tex2d,
        width: 1024,
        height: 1024,
        depth: 1,
        mips: 1,
        element_bytes: 16,
        block: 4,
        samples: 1,
        swizzle: Swizzle::SW_64KB_S,
    };
    let layout = Layout::new(&desc).map_err(|e| anyhow::anyhow!("2D layout: {e:?}"))?;
    let elem_w = (1024 / 4) as usize;
    let elem_h = (1024 / 4) as usize;
    let row_pitch = elem_w * 16;
    let linear_len = row_pitch * elem_h;
    let src_linear: Vec<u8> = (0..linear_len).map(|i| (i.wrapping_mul(17) & 0xff) as u8).collect();
    let mut tiled = vec![0u8; layout.size as usize];
    let mut out_linear = vec![0u8; linear_len];
    layout
        .tile(&mut tiled, 0, 0, &src_linear, row_pitch, linear_len)
        .map_err(|e| anyhow::anyhow!("2D tile: {e:?}"))?;

    // Warm up
    layout
        .detile(&tiled, 0, 0, &mut out_linear, row_pitch, linear_len)
        .map_err(|e| anyhow::anyhow!("2D detile warmup: {e:?}"))?;

    let started = Instant::now();
    for _ in 0..iters {
        layout
            .detile(
                black_box(&tiled),
                0,
                0,
                black_box(&mut out_linear),
                row_pitch,
                linear_len,
            )
            .map_err(|e| anyhow::anyhow!("2D detile: {e:?}"))?;
    }
    report_throughput("Detile 2D BC7 1024x1024", linear_len, iters, started.elapsed());
    Ok(())
}

fn bench_detile_3d(iters: usize) -> Result<()> {
    // 64x64x32 RGBA8 = 512 KiB
    let desc = Desc {
        dimension: Dimension::Tex3d,
        width: 64,
        height: 64,
        depth: 32,
        mips: 1,
        element_bytes: 4,
        block: 1,
        samples: 1,
        swizzle: Swizzle::SW_64KB_S,
    };
    let layout = Layout::new(&desc).map_err(|e| anyhow::anyhow!("3D layout: {e:?}"))?;
    let row_pitch = 64 * 4;
    let depth_pitch = row_pitch * 64;
    let linear_len = depth_pitch * 32;
    let src_linear: Vec<u8> = (0..linear_len)
        .map(|i: usize| (i.wrapping_mul(31) & 0xff) as u8)
        .collect();
    let mut tiled = vec![0u8; layout.size as usize];
    let mut out_linear = vec![0u8; linear_len];
    layout
        .tile(&mut tiled, 0, 0, &src_linear, row_pitch, depth_pitch)
        .map_err(|e| anyhow::anyhow!("3D tile: {e:?}"))?;

    layout
        .detile(&tiled, 0, 0, &mut out_linear, row_pitch, depth_pitch)
        .map_err(|e| anyhow::anyhow!("3D detile warmup: {e:?}"))?;

    let started = Instant::now();
    for _ in 0..iters {
        layout
            .detile(
                black_box(&tiled),
                0,
                0,
                black_box(&mut out_linear),
                row_pitch,
                depth_pitch,
            )
            .map_err(|e| anyhow::anyhow!("3D detile: {e:?}"))?;
    }
    report_throughput("Detile 3D RGBA8 64x64x32", linear_len, iters, started.elapsed());
    Ok(())
}

fn bench_bcpack_tables(iters: usize) -> Result<()> {
    let rounds = iters.saturating_mul(20);
    let _ = Tables::builtin().map_err(|e| anyhow::anyhow!("{e}"))?;
    let started = Instant::now();
    for _ in 0..rounds {
        let t = Tables::builtin().map_err(|e| anyhow::anyhow!("{e}"))?;
        black_box(t);
    }
    let elapsed = started.elapsed();
    let per_us = elapsed.as_secs_f64() * 1e6 / rounds as f64;
    let ops_sec = rounds as f64 / elapsed.as_secs_f64().max(1e-9);
    println!("{:<28}: {per_us:8.1} us/parse  ({ops_sec:8.1} parses/s)", "BCPack tables parse");
    Ok(())
}

fn bench_xma2_decode(iters: usize) -> Result<()> {
    let mut decoder = XmaDecoder::new(2, 48_000);
    let mut pcm = Vec::with_capacity(XMA_FRAME_SAMPLES * 2);
    // Synthetic bit-padded silence XMA2 frame (fixed 512-sample subframes).
    let frame = [0u8; 64];
    let rounds = iters.saturating_mul(200);
    let _ = decoder.decode(&frame, frame.len() * 8, &mut pcm);
    let started = Instant::now();
    for _ in 0..rounds {
        pcm.clear();
        let _ = decoder.decode(black_box(&frame), frame.len() * 8, &mut pcm);
    }
    let elapsed = started.elapsed();
    let per_us = elapsed.as_secs_f64() * 1e6 / rounds as f64;
    let frame_rt_us = (XMA_FRAME_SAMPLES as f64 / 48_000.0) * 1e6;
    let realtime = frame_rt_us / per_us.max(1e-6);
    println!(
        "{:<28}: {per_us:8.1} us/frame  ({realtime:7.1}x 48kHz realtime)",
        "XMA2 stereo 512-samp frame"
    );
    Ok(())
}

fn bench_shader_translate(iters: usize) -> Result<()> {
    // Representative GFX10 wave32 compute shader using whole-wave float product prefix + LDS write.
    let sop1 = |sdst: u8, op: u8, ssrc0: u8| -> u32 {
        0xBE80_0000 | (u32::from(sdst) << 16) | (u32::from(op) << 8) | u32::from(ssrc0)
    };
    let vop2 = |vdst: u8, op: u8, src0: u16, vsrc1: u8| -> u32 {
        (u32::from(op) << 25)
            | (u32::from(vdst) << 17)
            | (u32::from(vsrc1) << 9)
            | u32::from(src0)
    };
    let dpp16 = |vsrc0: u8, ctrl: u16| -> u32 {
        (0xF << 28) | (0xF << 24) | (u32::from(ctrl) << 8) | u32::from(vsrc0)
    };
    let mut words = Vec::with_capacity(22);
    words.push(sop1(0, 0x3D, 193)); // s_or_saveexec_b32 s0, -1
    words.extend([0xD501_0001u32, (242u32) | (256u32 << 9)]); // v_cndmask_b32 v1, 1.0, v0, s0
    for shift in [1u16, 2, 4, 8] {
        words.push(vop2(1, 0x08, 0xFA, 1)); // v_mul_f32 v1, v1_dpp, v1
        words.push(dpp16(1, 0x110 + shift));
    }
    words.extend([0xD760_0002u32, 257 | ((128 + 15) << 9)]); // v_readlane_b32 s2, v1, 15
    words.extend([sop1(126, 0x03, 255), 0xFFFF_0000]); // s_mov_b32 exec_lo, 0xFFFF0000
    words.push(vop2(1, 0x08, 2, 1)); // v_mul_f32 v1, s2, v1
    words.push(sop1(126, 0x03, 0)); // s_mov_b32 exec_lo, s0
    words.extend([0xD834_0000u32, 0x0000_0100]); // ds_write_b32 v0, v1
    words.push(0xBF81_0000); // s_endpgm
    let code: Vec<u8> = words.iter().flat_map(|w| w.to_le_bytes()).collect();
    let native = NativeProgram {
        stage: HwStage::Cs,
        wave64: false,
        vgprs: 16,
        layout: vec![],
        used: vec![],
        io: StageIo::Cs(ComputeIo {
            rsrc2: 1 << 15,
            threads: [32, 1, 1],
        }),
        code,
    };
    let container = Container {
        digest: [0; 16],
        version: (1, 0),
        parts: vec![],
    };

    let translate_once = || -> Result<usize> {
        let p = ir::build(&native.code, native.wave64, native.vgprs)?;
        let st = structure::structure(&p)?;
        let res = resource::track(&p, &native.layout, native.stage, Some(&st))?;
        let shader_io = io::raise(&p, &native)?;
        let out = emit::emit(&container, &native, &p, &st, &shader_io, &res)?;
        Ok(out.dxil.len())
    };

    let dxil_bytes = translate_once()?;
    let rounds = iters.saturating_mul(50);
    let started = Instant::now();
    for _ in 0..rounds {
        let len = translate_once()?;
        black_box(len);
    }
    let elapsed = started.elapsed();
    let per_us = elapsed.as_secs_f64() * 1e6 / rounds as f64;
    let shaders_sec = rounds as f64 / elapsed.as_secs_f64().max(1e-9);
    println!(
        "{:<28}: {per_us:8.1} us/shader ({shaders_sec:8.1} shaders/s, {dxil_bytes} B DXIL)",
        "Shader GFX10->DXIL (wave)"
    );
    Ok(())
}

fn report_throughput(name: &str, bytes_per_iter: usize, iters: usize, elapsed: Duration) {
    let secs = elapsed.as_secs_f64().max(1e-9);
    let total_mb = (bytes_per_iter as f64 * iters as f64) / 1e6;
    let mb_s = total_mb / secs;
    let ms_iter = secs * 1e3 / iters as f64;
    println!("{name:<28}: {mb_s:8.1} MB/s   ({ms_iter:7.2} ms/iter)");
}

#[cfg(test)]
mod tests {
    #[test]
    fn bench_suite_runs_cleanly() {
        super::run(1).expect("bench workloads should complete");
    }
}
