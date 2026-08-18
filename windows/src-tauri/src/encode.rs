//! H.264 encoding via a Media Foundation Transform (Task 8.1).
//!
//! Mirrors the encoder contract the Mac side proved in Phase 2, because the
//! receiver's WebCodecs decoder is the same on both ends:
//!
//!   * **No B-frames.** WebCodecs in low-latency mode cannot reorder, so a
//!     single B-frame stalls the pipeline. Baseline profile makes them
//!     structurally impossible rather than merely switched off — the CODECAPI
//!     knobs below are belt-and-braces, and are allowed to fail.
//!   * **Annex-B with in-band SPS/PPS before every IDR**, since `configure()` is
//!     called without a `description`.
//!   * **A forced IDR when a client connects**, or the receiver shows nothing
//!     until the next scheduled keyframe.

#![cfg(target_os = "windows")]

use crate::annexb;
use crate::convert::Nv12;
use core::mem::ManuallyDrop;
use std::sync::Once;
use windows::core::{Interface, VARIANT};
use windows::Win32::Foundation::E_FAIL;
use windows::Win32::Media::MediaFoundation::*;
use windows::Win32::System::Com::{CoInitializeEx, CoTaskMemFree, COINIT_MULTITHREADED};

static MF_INIT: Once = Once::new();

fn ensure_mf() {
    MF_INIT.call_once(|| unsafe {
        // Both results are ignored on purpose: RPC_E_CHANGED_MODE only means
        // another component already chose an apartment, and a second MFStartup
        // is harmless. Failing here would be less useful than failing at the
        // first real call with a specific error.
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        let _ = MFStartup(MF_VERSION, MFSTARTUP_NOSOCKET);
    });
}

/// Width and height (or numerator and denominator) packed into one u64, which
/// is how Media Foundation stores paired attributes.
fn pack(hi: u32, lo: u32) -> u64 {
    ((hi as u64) << 32) | lo as u64
}

pub struct EncodedFrame {
    pub data: Vec<u8>,
    pub keyframe: bool,
}

pub struct H264Encoder {
    transform: IMFTransform,
    codec_api: Option<ICodecAPI>,
    fps: u32,
    frame: i64,
    /// SPS/PPS taken from the negotiated output type, used to repair any IDR the
    /// encoder emits without them.
    sequence_header: Vec<u8>,
}

impl H264Encoder {
    pub fn new(width: u32, height: u32, fps: u32, bitrate: u32) -> windows::core::Result<Self> {
        ensure_mf();
        let transform = find_encoder()?;

        unsafe {
            // Output type MUST be set before the input type: the H.264 MFT
            // rejects an input type while it still has no idea what it is
            // producing. This ordering is not interchangeable.
            let out = MFCreateMediaType()?;
            out.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
            out.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_H264)?;
            out.SetUINT32(&MF_MT_AVG_BITRATE, bitrate)?;
            out.SetUINT64(&MF_MT_FRAME_SIZE, pack(width, height))?;
            out.SetUINT64(&MF_MT_FRAME_RATE, pack(fps, 1))?;
            out.SetUINT64(&MF_MT_PIXEL_ASPECT_RATIO, pack(1, 1))?;
            out.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32)?;
            // Baseline: the profile has no B-frames at all, so the "no
            // reordering" contract holds even if the CODECAPI calls below are
            // ignored by a given encoder.
            out.SetUINT32(&MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_Base.0 as u32)?;
            transform.SetOutputType(0, &out, 0)?;

            let inp = MFCreateMediaType()?;
            inp.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
            inp.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_NV12)?;
            inp.SetUINT64(&MF_MT_FRAME_SIZE, pack(width, height))?;
            inp.SetUINT64(&MF_MT_FRAME_RATE, pack(fps, 1))?;
            inp.SetUINT64(&MF_MT_PIXEL_ASPECT_RATIO, pack(1, 1))?;
            inp.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32)?;
            transform.SetInputType(0, &inp, 0)?;

            // Best-effort: not every encoder exposes these, and none of them are
            // required for correctness given Baseline above.
            if let Ok(attrs) = transform.GetAttributes() {
                let _ = attrs.SetUINT32(&MF_LOW_LATENCY, 1);
            }
        }

        let codec_api = transform.cast::<ICodecAPI>().ok();
        if let Some(api) = &codec_api {
            unsafe {
                let _ = api.SetValue(&CODECAPI_AVEncCommonLowLatency, &VARIANT::from(true));
                let _ = api.SetValue(&CODECAPI_AVEncMPVDefaultBPictureCount, &VARIANT::from(0u32));
            }
        }

        let sequence_header = unsafe { read_sequence_header(&transform) };

        unsafe {
            // No COMMAND_FLUSH here. The Microsoft H.264 MFT returns E_FAIL for
            // a flush issued before streaming has begun — there is nothing to
            // flush yet — and the encoder is freshly created anyway.
            transform.ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0)?;
            transform.ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0)?;
        }

        Ok(Self { transform, codec_api, fps: fps.max(1), frame: 0, sequence_header })
    }

    /// Feeds one frame and returns whatever access units came back.
    ///
    /// Zero is a normal answer: encoders buffer, and the first call after a
    /// flush routinely produces nothing.
    pub fn encode(&mut self, nv12: &Nv12, force_idr: bool) -> windows::core::Result<Vec<EncodedFrame>> {
        if force_idr {
            if let Some(api) = &self.codec_api {
                unsafe {
                    let _ = api.SetValue(&CODECAPI_AVEncVideoForceKeyFrame, &VARIANT::from(1u32));
                }
            }
        }

        unsafe {
            let buffer = MFCreateMemoryBuffer(nv12.data.len() as u32)?;
            let mut dst: *mut u8 = std::ptr::null_mut();
            buffer.Lock(&mut dst, None, None)?;
            std::ptr::copy_nonoverlapping(nv12.data.as_ptr(), dst, nv12.data.len());
            buffer.Unlock()?;
            buffer.SetCurrentLength(nv12.data.len() as u32)?;

            let sample = MFCreateSample()?;
            sample.AddBuffer(&buffer)?;
            // Media Foundation timestamps are 100-nanosecond units.
            let duration = 10_000_000i64 / self.fps as i64;
            sample.SetSampleTime(self.frame * duration)?;
            sample.SetSampleDuration(duration)?;
            self.frame += 1;

            self.transform.ProcessInput(0, &sample, 0)?;
        }

        self.drain()
    }

    fn drain(&mut self) -> windows::core::Result<Vec<EncodedFrame>> {
        let mut frames = Vec::new();
        loop {
            let info = unsafe { self.transform.GetOutputStreamInfo(0)? };
            let allocates_for_us = info.dwFlags
                & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES.0 as u32
                    | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES.0 as u32)
                != 0;

            let supplied = if allocates_for_us {
                None
            } else {
                unsafe {
                    let sample = MFCreateSample()?;
                    // cbSize can be 0 before the first output; a zero-length
                    // buffer would fail the call rather than the encode.
                    sample.AddBuffer(&MFCreateMemoryBuffer(info.cbSize.max(1 << 16))?)?;
                    Some(sample)
                }
            };

            let mut out = MFT_OUTPUT_DATA_BUFFER {
                dwStreamID: 0,
                pSample: ManuallyDrop::new(supplied),
                dwStatus: 0,
                pEvents: ManuallyDrop::new(None),
            };
            let mut status = 0u32;
            let result = unsafe {
                self.transform
                    .ProcessOutput(0, std::slice::from_mut(&mut out), &mut status)
            };

            let sample = unsafe { ManuallyDrop::take(&mut out.pSample) };
            unsafe { ManuallyDrop::drop(&mut out.pEvents) };

            match result {
                Ok(()) => {}
                // The expected way this loop ends, not a failure.
                Err(e) if e.code() == MF_E_TRANSFORM_NEED_MORE_INPUT => break,
                Err(e) if e.code() == MF_E_TRANSFORM_STREAM_CHANGE => {
                    // The encoder renegotiated; its parameter sets may have
                    // changed, so re-read them before continuing.
                    self.sequence_header = unsafe { read_sequence_header(&self.transform) };
                    continue;
                }
                Err(e) => return Err(e),
            }

            let Some(sample) = sample else { continue };
            let bytes = unsafe {
                let buffer = sample.ConvertToContiguousBuffer()?;
                let mut ptr: *mut u8 = std::ptr::null_mut();
                let mut len = 0u32;
                buffer.Lock(&mut ptr, None, Some(&mut len))?;
                let bytes = std::slice::from_raw_parts(ptr, len as usize).to_vec();
                buffer.Unlock()?;
                bytes
            };
            if bytes.is_empty() {
                continue;
            }

            let keyframe = annexb::has_idr(&bytes);
            // Repair rather than trust. An IDR without an SPS in front of it does
            // not make the receiver error — it makes it show nothing, which is
            // far harder to diagnose from the sending side.
            let data = if keyframe
                && !annexb::has_parameter_sets(&bytes)
                && !self.sequence_header.is_empty()
            {
                let mut fixed = self.sequence_header.clone();
                fixed.extend_from_slice(&bytes);
                fixed
            } else {
                bytes
            };
            frames.push(EncodedFrame { data, keyframe });
        }
        Ok(frames)
    }
}

impl Drop for H264Encoder {
    fn drop(&mut self) {
        unsafe {
            let _ = self.transform.ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
            let _ = self.transform.ProcessMessage(MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
        }
    }
}

/// SPS/PPS blob from the negotiated output type, or empty if absent.
unsafe fn read_sequence_header(transform: &IMFTransform) -> Vec<u8> {
    let Ok(current) = transform.GetOutputCurrentType(0) else {
        return Vec::new();
    };
    match current.GetBlobSize(&MF_MT_MPEG_SEQUENCE_HEADER) {
        Ok(size) if size > 0 => {
            let mut buf = vec![0u8; size as usize];
            if current.GetBlob(&MF_MT_MPEG_SEQUENCE_HEADER, &mut buf, None).is_ok() {
                buf
            } else {
                Vec::new()
            }
        }
        _ => Vec::new(),
    }
}

/// Picks a synchronous NV12 -> H.264 encoder.
///
/// SYNCMFT deliberately: hardware encoders are asynchronous and require the
/// event-driven MFT model, which is a substantially larger amount of machinery.
/// The software encoder ships with every Windows install, so this always
/// resolves; moving to hardware is a later optimisation, not a correctness fix.
fn find_encoder() -> windows::core::Result<IMFTransform> {
    let input = MFT_REGISTER_TYPE_INFO {
        guidMajorType: MFMediaType_Video,
        guidSubtype: MFVideoFormat_NV12,
    };
    let output = MFT_REGISTER_TYPE_INFO {
        guidMajorType: MFMediaType_Video,
        guidSubtype: MFVideoFormat_H264,
    };

    unsafe {
        let mut activates: *mut Option<IMFActivate> = std::ptr::null_mut();
        let mut count = 0u32;
        MFTEnumEx(
            MFT_CATEGORY_VIDEO_ENCODER,
            MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_SORTANDFILTER,
            Some(&input),
            Some(&output),
            &mut activates,
            &mut count,
        )?;

        if activates.is_null() || count == 0 {
            return Err(windows::core::Error::from_hresult(E_FAIL));
        }

        // Take the first and release the rest. MFTEnumEx hands back a
        // CoTaskMemAlloc'd array of live COM references; dropping the array
        // without clearing every slot leaks all but one encoder.
        let mut chosen: Option<IMFActivate> = None;
        for i in 0..count as usize {
            let slot = &mut *activates.add(i);
            let taken = slot.take();
            if i == 0 {
                chosen = taken;
            }
        }
        CoTaskMemFree(Some(activates as *const core::ffi::c_void));

        let activate = chosen.ok_or_else(|| windows::core::Error::from_hresult(E_FAIL))?;
        activate.ActivateObject::<IMFTransform>()
    }
}
