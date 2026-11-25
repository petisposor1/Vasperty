//! The console's audio DSP (`chad.dll`): streams that convolve blocks of
//! float samples with an impulse response (reverb), or run other block
//! transforms, on a coprocessor.
//!
//! A title connects once with a memory block for the DSP, activates
//! streams, and submits one command per block (gains, an input and an
//! output buffer). Activation hands back a status block whose second word is
//! the ticket of the last completed command and whose fourth is its result;
//! the title checks it one block later and treats a late command as an
//! overrun. Commands complete when submitted here.
//!
//! Because the hardware coprocessor's partitioned frequency-domain IR layout
//! is undocumented, convolution streams run a zero-allocation 4-channel
//! Hadamard Feedback Delay Network (FDN) reverb with per-line low-pass
//! damping, driven by each stream's channel count, IR length, and per-block
//! gains. Set `VICTORY_DSP_REVERB=0` to revert to dry silence.
#![allow(non_snake_case)]
#![allow(clippy::not_unsafe_ptr_arg_deref)]

use std::ffi::c_void;
use std::sync::{Mutex, OnceLock};

use super::xasync::E_INVALIDARG;
use super::xgameruntime::{HRESULT, S_OK};
use crate::{HleModule, hle_export};

const E_POINTER: HRESULT = 0x8000_4003_u32 as i32;
const E_OUTOFMEMORY: HRESULT = 0x8007_000E_u32 as i32;

const CONVOLUTION: u32 = 1;
/// Option bits that need a stereo stream, and one convolution refuses.
const STEREO_OPTIONS: u32 = 2 | 8;
const NOT_FOR_CONVOLUTION: u32 = 4;

/// Mutually-prime delay line lengths (in samples at 48 kHz: ~31 ms to ~72 ms)
/// for dense, metallic-free reverberation.
const DELAY_LENGTHS: [usize; 4] = [1487, 1993, 2657, 3469];

fn reverb_enabled() -> bool {
    static ENABLED: OnceLock<bool> = OnceLock::new();
    *ENABLED.get_or_init(|| {
        std::env::var("VICTORY_DSP_REVERB")
            .map(|v| v != "0")
            .unwrap_or(true)
    })
}

/// Zero-allocation 4-line Hadamard Feedback Delay Network (FDN) reverb.
struct ReverbEngine {
    lines: [Vec<f32>; 4],
    pos: [usize; 4],
    lp: [f32; 4],
    feedback: f32,
    damp: f32,
}

impl ReverbEngine {
    fn new(ir_floats: u32) -> Self {
        // Scale feedback gently with the requested IR buffer size (longer IRs
        // imply larger acoustic spaces), clamped well below unity for stability.
        let rt_factor = (ir_floats as f32 / 65536.0).clamp(0.0, 1.0);
        let feedback = 0.42 + 0.40 * rt_factor;
        let damp = 0.28;
        Self {
            lines: DELAY_LENGTHS.map(|n| vec![0.0; n]),
            pos: [0; 4],
            lp: [0.0; 4],
            feedback,
            damp,
        }
    }

    #[inline]
    fn flush_denormal(x: f32) -> f32 {
        if x.abs() < 1e-20 || !x.is_finite() {
            0.0
        } else {
            x
        }
    }

    /// Processes `frames` samples of `channels` (1 or 2, interleaved) from
    /// `input` into `output`, applying `gains`.
    fn process(&mut self, input: &[f32], output: &mut [f32], frames: usize, channels: usize, gains: [f32; 2]) {
        let g0 = if gains[0].is_finite() { gains[0].clamp(-4.0, 4.0) } else { 0.0 };
        let g1 = if gains[1].is_finite() { gains[1].clamp(-4.0, 4.0) } else { 0.0 };
        let wet_gain = if channels == 2 {
            0.5 * (g0.abs() + g1.abs())
        } else {
            g0.abs()
        };
        if wet_gain == 0.0 {
            output.fill(0.0);
            return;
        }
        let fb = self.feedback;
        let damp = self.damp;
        let keep = 1.0 - damp;
        for f in 0..frames {
            let (in_l, in_r) = if channels == 2 {
                (input[f * 2] * g0, input[f * 2 + 1] * g1)
            } else {
                let s = input[f] * g0;
                (s, s)
            };
            // Read current delayed samples and apply one-pole low-pass damping.
            let mut d = [0.0f32; 4];
            for i in 0..4 {
                let raw = self.lines[i][self.pos[i]];
                let filtered = Self::flush_denormal(raw * keep + self.lp[i] * damp);
                self.lp[i] = filtered;
                d[i] = filtered;
            }
            // Normalized 4x4 Hadamard feedback matrix (energy-preserving).
            let h0 = 0.5 * (d[0] + d[1] + d[2] + d[3]);
            let h1 = 0.5 * (d[0] - d[1] + d[2] - d[3]);
            let h2 = 0.5 * (d[0] + d[1] - d[2] - d[3]);
            let h3 = 0.5 * (d[0] - d[1] - d[2] + d[3]);
            let next = [
                Self::flush_denormal(h0 * fb + in_l * 0.5),
                Self::flush_denormal(h1 * fb + in_r * 0.5),
                Self::flush_denormal(h2 * fb + in_l * 0.5),
                Self::flush_denormal(h3 * fb - in_r * 0.5),
            ];
            for i in 0..4 {
                self.lines[i][self.pos[i]] = next[i];
                self.pos[i] += 1;
                if self.pos[i] == self.lines[i].len() {
                    self.pos[i] = 0;
                }
            }
            if channels == 2 {
                // Decorrelated stereo tap mix from opposite delay lines.
                let out_l = (d[0] + d[2] - d[1] * 0.35 + in_l * 0.15).clamp(-4.0, 4.0);
                let out_r = (d[1] + d[3] - d[2] * 0.35 + in_r * 0.15).clamp(-4.0, 4.0);
                output[f * 2] = out_l;
                output[f * 2 + 1] = out_r;
            } else {
                let out_m = (0.5 * (d[0] + d[1] + d[2] + d[3]) + in_l * 0.15).clamp(-4.0, 4.0);
                output[f] = out_m;
            }
        }
    }
}

pub struct Dsp {
    max_streams: u32,
    active: Mutex<u32>,
}

/// What activation describes.
#[repr(C, packed)]
pub struct StreamDesc {
    kind: u32,
    options: u32,
    frames: u32,
    channels: u32,
    ir_floats: u32,
    ir: *const f32,
}

/// The status block a stream's owner polls.
#[repr(C)]
pub struct Status {
    submitted: u32,
    completed: u32,
    reserved: u32,
    result: HRESULT,
}

pub struct Stream {
    dsp: *mut Dsp,
    kind: u32,
    frames: u32,
    channels: u32,
    reverb: Option<ReverbEngine>,
    status: Box<Status>,
}

/// One block of work.
#[repr(C)]
pub struct Command {
    gains: [f32; 2],
    input: *const f32,
    output: *mut f32,
    reserved: u64,
}

pub extern "system" fn XDspConnectWithMaximumStreamLimit(
    base: *mut c_void,
    base_length: u32,
    ir_seconds: u32,
    max_streams: u32,
    max_channels: u32,
    out: *mut *mut Dsp,
) -> HRESULT {
    if base.is_null()
        || !(0x1_0000..=0x1F40_0000).contains(&base_length)
        || ir_seconds > 0x80
        || max_streams > 0x100
        || max_channels > 2
    {
        return E_INVALIDARG;
    }
    if out.is_null() {
        return E_POINTER;
    }
    tracing::info!(
        base_length,
        ir_seconds,
        max_streams,
        max_channels,
        "audio DSP connected"
    );
    let dsp = Box::new(Dsp {
        max_streams,
        active: Mutex::new(0),
    });
    // SAFETY: checked non-null.
    unsafe { out.write(Box::into_raw(dsp)) };
    S_OK
}

pub extern "system" fn XDspDisconnect(dsp: *mut Dsp) -> HRESULT {
    if dsp.is_null() {
        return E_INVALIDARG;
    }
    // SAFETY: made by `XDspConnectWithMaximumStreamLimit`; disconnected
    // once, after its streams.
    drop(unsafe { Box::from_raw(dsp) });
    S_OK
}

fn valid(desc: &StreamDesc) -> bool {
    let (kind, options, frames, channels) = (desc.kind, desc.options, desc.frames, desc.channels);
    let shape = if kind == CONVOLUTION {
        (1..=2).contains(&channels)
            && matches!(frames, 0x200 | 0x400)
            && options & NOT_FOR_CONVOLUTION == 0
    } else {
        channels == 1 && matches!(frames, 0x200 | 0x400 | 0x800)
    };
    shape && (options & STEREO_OPTIONS == 0 || channels == 2)
}

pub extern "system" fn XDspActivate(
    dsp: *mut Dsp,
    desc: *const StreamDesc,
    status: *mut *const Status,
    stream: *mut *mut Stream,
) -> HRESULT {
    if status.is_null() || stream.is_null() {
        return E_POINTER;
    }
    if dsp.is_null() || desc.is_null() {
        return E_INVALIDARG;
    }
    // SAFETY: checked non-null; the title passes its description.
    let desc = unsafe { &*desc };
    if !valid(desc) {
        return E_INVALIDARG;
    }
    let (kind, options, frames, channels) = (desc.kind, desc.options, desc.frames, desc.channels);
    tracing::debug!(
        kind,
        options,
        frames,
        channels,
        "audio DSP stream activated"
    );
    {
        // SAFETY: a connection from `XDspConnectWithMaximumStreamLimit`.
        let dsp = unsafe { &*dsp };
        let mut active = dsp.active.lock().unwrap_or_else(|e| e.into_inner());
        if *active >= dsp.max_streams {
            return E_OUTOFMEMORY;
        }
        *active += 1;
    }
    let new = Box::new(Stream {
        dsp,
        kind: desc.kind,
        frames: desc.frames,
        channels: desc.channels,
        reverb: (desc.kind == CONVOLUTION && reverb_enabled())
            .then(|| ReverbEngine::new(desc.ir_floats)),
        status: Box::new(Status {
            submitted: 0,
            completed: 0,
            reserved: 0,
            result: S_OK,
        }),
    });
    // SAFETY: checked non-null.
    unsafe {
        status.write(&*new.status);
        stream.write(Box::into_raw(new));
    }
    S_OK
}

pub extern "system" fn XDspDeactivate(stream: *mut Stream) -> HRESULT {
    if stream.is_null() {
        return E_INVALIDARG;
    }
    // SAFETY: made by `XDspActivate`; deactivated once.
    let stream = unsafe { Box::from_raw(stream) };
    // SAFETY: the connection outlives its streams.
    let dsp = unsafe { &*stream.dsp };
    *dsp.active.lock().unwrap_or_else(|e| e.into_inner()) -= 1;
    S_OK
}

/// Completes the command at once: convolution streams run the FDN reverb
/// engine; non-convolution transforms output zeros.
pub extern "system" fn XDspSubmitCommand(
    stream: *mut Stream,
    command: *const Command,
    ticket: *mut u32,
) -> HRESULT {
    if stream.is_null() || command.is_null() {
        return E_INVALIDARG;
    }
    // SAFETY: a stream from `XDspActivate`, the title's command.
    let (stream, command) = unsafe { (&mut *stream, &*command) };
    if !command.output.is_null() {
        let samples = (stream.frames * stream.channels) as usize;
        if stream.kind == CONVOLUTION
            && !command.input.is_null()
            && let Some(reverb) = stream.reverb.as_mut()
        {
            // SAFETY: input and output buffers hold `frames * channels` floats.
            let input = unsafe { std::slice::from_raw_parts(command.input, samples) };
            // SAFETY: output buffer holds `frames * channels` writable floats.
            let output = unsafe { std::slice::from_raw_parts_mut(command.output, samples) };
            reverb.process(
                input,
                output,
                stream.frames as usize,
                stream.channels as usize,
                command.gains,
            );
        } else {
            // SAFETY: the title's output buffer holds one block of the stream.
            unsafe { std::ptr::write_bytes(command.output, 0, samples) };
        }
    }
    let status = &mut *stream.status;
    let next = status.submitted.wrapping_add(1);
    // SAFETY: the status block is read by title code on other threads.
    unsafe {
        std::ptr::write_volatile(&mut status.submitted, next);
        std::ptr::write_volatile(&mut status.result, S_OK);
        std::ptr::write_volatile(&mut status.completed, next);
    }
    if !ticket.is_null() {
        // SAFETY: optional out parameter.
        unsafe { ticket.write(next) };
    }
    S_OK
}

pub(crate) fn module() -> HleModule {
    HleModule {
        name: "dsp",
        dlls: &["chad.dll"],
        exports: vec![
            hle_export!(XDspConnectWithMaximumStreamLimit),
            hle_export!(XDspDisconnect),
            hle_export!(XDspActivate),
            hle_export!(XDspDeactivate),
            hle_export!(XDspSubmitCommand),
        ],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn convolution_stream_as_the_title_drives_it() {
        let mut base = vec![0u8; 0x10_0000];
        let mut dsp = std::ptr::null_mut();
        assert_eq!(
            XDspConnectWithMaximumStreamLimit(
                base.as_mut_ptr().cast(),
                0x10_0000,
                24,
                0x80,
                1,
                &mut dsp
            ),
            S_OK
        );
        let ir = vec![0f32; 0x800];
        // Stereo convolution with option 2, as the title asks for.
        let desc = StreamDesc {
            kind: CONVOLUTION,
            options: 2,
            frames: 0x400,
            channels: 2,
            ir_floats: 0x800,
            ir: ir.as_ptr(),
        };
        let (mut status, mut stream) = (std::ptr::null(), std::ptr::null_mut());
        assert_eq!(XDspActivate(dsp, &desc, &mut status, &mut stream), S_OK);
        let mut output = vec![1f32; 0x800];
        let input = vec![0.5f32; 0x800];
        let command = Command {
            gains: [1.0, 1.0],
            input: input.as_ptr(),
            output: output.as_mut_ptr(),
            reserved: 0,
        };
        let mut ticket = 0;
        assert_eq!(XDspSubmitCommand(stream, &command, &mut ticket), S_OK);
        // SAFETY: the stream's status block.
        let (completed, result) = unsafe { ((*status).completed, (*status).result) };
        assert_eq!((completed, result), (ticket, S_OK));
        assert!(output.iter().all(|s| s.is_finite()));
        assert!(
            output.iter().any(|&s| s.abs() > 1e-4),
            "convolution stream with non-zero input and gains should produce reverb output"
        );
        // Zero gains produce exact silence.
        let silent_cmd = Command {
            gains: [0.0, 0.0],
            input: input.as_ptr(),
            output: output.as_mut_ptr(),
            reserved: 0,
        };
        assert_eq!(XDspSubmitCommand(stream, &silent_cmd, &mut ticket), S_OK);
        assert!(output.iter().all(|&s| s == 0.0));
        assert_eq!(XDspDeactivate(stream), S_OK);

        // Mono streams refuse stereo options; transforms are mono only.
        let bad = StreamDesc {
            channels: 1,
            ..desc
        };
        assert_eq!(
            XDspActivate(dsp, &bad, &mut status, &mut stream),
            E_INVALIDARG
        );
        let transform = StreamDesc {
            kind: 2,
            options: 0,
            channels: 1,
            ir_floats: 0,
            ir: std::ptr::null(),
            ..desc
        };
        assert_eq!(
            XDspActivate(dsp, &transform, &mut status, &mut stream),
            S_OK
        );
        assert_eq!(XDspDeactivate(stream), S_OK);
        assert_eq!(XDspDisconnect(dsp), S_OK);
    }

    #[test]
    fn fdn_reverb_produces_decaying_stereo_tail_and_stays_bounded() {
        let mut engine = ReverbEngine::new(32768);
        let frames = 0x400;
        let mut input = vec![0.0f32; frames * 2];
        input[0] = 1.0;
        input[1] = 0.5;
        let mut output = vec![0.0f32; frames * 2];
        // Feed an impulse, then several blocks of silence to verify the tail
        // builds up across delay lines and decays cleanly without diverging.
        engine.process(&input, &mut output, frames, 2, [1.0, 1.0]);
        input.fill(0.0);
        let mut energies = Vec::new();
        for _ in 0..16 {
            engine.process(&input, &mut output, frames, 2, [1.0, 1.0]);
            assert!(output.iter().all(|s| s.is_finite() && s.abs() <= 4.0));
            let energy: f32 = output.iter().map(|s| s * s).sum();
            energies.push(energy);
        }
        let peak = energies.iter().copied().fold(0.0f32, f32::max);
        assert!(peak > 1e-4, "expected audible reverb tail, peak energy={peak}");
        assert!(
            *energies.last().unwrap() < peak,
            "reverb tail must decay over time: {energies:?}"
        );
    }
}
