//! Windows desktop capture via DXGI Desktop Duplication (Task 8.1).
//!
//! This captures the EXISTING desktop rather than creating a virtual display.
//! That distinction is what keeps the reverse direction free: making the Mac a
//! second display *for* Windows would need an Indirect Display Driver, which is
//! a signed driver requiring an EV certificate and Microsoft attestation.
//! Duplicating the real desktop needs neither.
//!
//! Only compiled on Windows; every other platform gets a stub so the rest of the
//! app still builds.

#![cfg(target_os = "windows")]

use std::time::Instant;
use windows::core::Interface;
use windows::Win32::Foundation::HMODULE;
use windows::Win32::Graphics::Direct3D::D3D_DRIVER_TYPE_HARDWARE;
use windows::Win32::Graphics::Direct3D11::{
    D3D11CreateDevice, ID3D11Device, ID3D11DeviceContext, ID3D11Texture2D,
    D3D11_CPU_ACCESS_READ, D3D11_CREATE_DEVICE_BGRA_SUPPORT, D3D11_MAPPED_SUBRESOURCE,
    D3D11_MAP_READ, D3D11_SDK_VERSION, D3D11_TEXTURE2D_DESC, D3D11_USAGE_STAGING,
};
use windows::Win32::Graphics::Dxgi::{
    IDXGIDevice, IDXGIOutput1, IDXGIOutputDuplication, IDXGIResource, DXGI_ERROR_ACCESS_LOST,
    DXGI_ERROR_WAIT_TIMEOUT, DXGI_OUTDUPL_FRAME_INFO,
};

/// One captured frame, BGRA8, tightly packed.
pub struct Frame {
    pub width: u32,
    pub height: u32,
    pub bgra: Vec<u8>,
}

#[derive(Default, Clone, Copy)]
pub struct CaptureStats {
    pub frames: u64,
    /// AcquireNextFrame returned no new content. An idle desktop produces these
    /// constantly and they are NOT dropped frames.
    pub idle: u64,
    /// Duplication was lost and rebuilt — happens on resolution changes, UAC
    /// prompts, and full-screen apps taking exclusive mode.
    pub reinits: u64,
}

pub struct DesktopCapture {
    device: ID3D11Device,
    context: ID3D11DeviceContext,
    duplication: IDXGIOutputDuplication,
    staging: Option<ID3D11Texture2D>,
    width: u32,
    height: u32,
    pub stats: CaptureStats,
    started: Instant,
}

impl DesktopCapture {
    pub fn new() -> windows::core::Result<Self> {
        let (device, context) = create_device()?;
        let (duplication, width, height) = create_duplication(&device)?;
        Ok(Self {
            device,
            context,
            duplication,
            staging: None,
            width,
            height,
            stats: CaptureStats::default(),
            started: Instant::now(),
        })
    }

    pub fn size(&self) -> (u32, u32) {
        (self.width, self.height)
    }

    pub fn fps(&self) -> f64 {
        let secs = self.started.elapsed().as_secs_f64();
        if secs <= 0.0 { 0.0 } else { self.stats.frames as f64 / secs }
    }

    /// Waits up to `timeout_ms` for a new frame.
    ///
    /// `Ok(None)` means the desktop simply did not change — the normal state of
    /// an idle screen, not a failure. Callers must not treat it as an error or
    /// they will log a river of noise.
    pub fn next_frame(&mut self, timeout_ms: u32) -> windows::core::Result<Option<Frame>> {
        let mut info = DXGI_OUTDUPL_FRAME_INFO::default();
        let mut resource: Option<IDXGIResource> = None;

        match unsafe { self.duplication.AcquireNextFrame(timeout_ms, &mut info, &mut resource) } {
            Ok(()) => {}
            Err(e) if e.code() == DXGI_ERROR_WAIT_TIMEOUT => {
                self.stats.idle += 1;
                return Ok(None);
            }
            Err(e) if e.code() == DXGI_ERROR_ACCESS_LOST => {
                // Resolution change, UAC prompt, or a full-screen app taking
                // exclusive mode. Rebuild rather than dying.
                self.reinit()?;
                return Ok(None);
            }
            Err(e) => return Err(e),
        }

        // LastPresentTime == 0 means only the mouse moved; the desktop image is
        // unchanged, so there is nothing new to encode.
        if info.LastPresentTime == 0 {
            unsafe { self.duplication.ReleaseFrame()? };
            self.stats.idle += 1;
            return Ok(None);
        }

        let Some(resource) = resource else {
            unsafe { self.duplication.ReleaseFrame()? };
            self.stats.idle += 1;
            return Ok(None);
        };

        let result = self.copy_frame(&resource);
        unsafe { self.duplication.ReleaseFrame()? };
        let frame = result?;
        self.stats.frames += 1;
        Ok(Some(frame))
    }

    fn copy_frame(&mut self, resource: &IDXGIResource) -> windows::core::Result<Frame> {
        let source: ID3D11Texture2D = resource.cast()?;

        // The duplicated texture lives on the GPU and cannot be read directly;
        // a STAGING copy is the only way to get CPU access.
        if self.staging.is_none() {
            let mut desc = D3D11_TEXTURE2D_DESC::default();
            unsafe { source.GetDesc(&mut desc) };
            desc.Usage = D3D11_USAGE_STAGING;
            desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ.0 as u32;
            desc.BindFlags = 0;
            desc.MiscFlags = 0;
            self.width = desc.Width;
            self.height = desc.Height;
            let mut staging: Option<ID3D11Texture2D> = None;
            unsafe { self.device.CreateTexture2D(&desc, None, Some(&mut staging))? };
            self.staging = staging;
        }
        let staging = self.staging.as_ref().unwrap();
        unsafe { self.context.CopyResource(staging, &source) };

        let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
        unsafe { self.context.Map(staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped))? };

        let width = self.width as usize;
        let height = self.height as usize;
        let row_bytes = width * 4;
        let mut bgra = vec![0u8; row_bytes * height];
        unsafe {
            let src = mapped.pData as *const u8;
            // RowPitch is usually WIDER than the visible row — copying the whole
            // buffer in one go would shear the image.
            for y in 0..height {
                std::ptr::copy_nonoverlapping(
                    src.add(y * mapped.RowPitch as usize),
                    bgra.as_mut_ptr().add(y * row_bytes),
                    row_bytes,
                );
            }
            self.context.Unmap(staging, 0);
        }

        Ok(Frame { width: self.width, height: self.height, bgra })
    }

    fn reinit(&mut self) -> windows::core::Result<()> {
        self.stats.reinits += 1;
        self.staging = None;
        let (duplication, width, height) = create_duplication(&self.device)?;
        self.duplication = duplication;
        self.width = width;
        self.height = height;
        Ok(())
    }
}

fn create_device() -> windows::core::Result<(ID3D11Device, ID3D11DeviceContext)> {
    let mut device: Option<ID3D11Device> = None;
    let mut context: Option<ID3D11DeviceContext> = None;
    unsafe {
        D3D11CreateDevice(
            None,
            D3D_DRIVER_TYPE_HARDWARE,
            // Not None: this parameter is Param<HMODULE>, and only interface
            // params accept None.
            HMODULE::default(),
            // BGRA_SUPPORT because the duplicated desktop is always BGRA8.
            D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            None,
            D3D11_SDK_VERSION,
            Some(&mut device),
            None,
            Some(&mut context),
        )?;
    }
    Ok((device.unwrap(), context.unwrap()))
}

fn create_duplication(
    device: &ID3D11Device,
) -> windows::core::Result<(IDXGIOutputDuplication, u32, u32)> {
    unsafe {
        let dxgi: IDXGIDevice = device.cast()?;
        let adapter = dxgi.GetAdapter()?;
        // Output 0 = primary display. Multi-monitor selection is Task 8.4.
        let output1: IDXGIOutput1 = adapter.EnumOutputs(0)?.cast()?;
        let duplication = output1.DuplicateOutput(device)?;

        // Ask the duplication rather than IDXGIOutput::GetDesc: the latter is
        // gated behind the GDI feature because DXGI_OUTPUT_DESC carries an
        // HMONITOR, and pulling in GDI for a width and a height is not a trade
        // worth making.
        let desc = unsafe { duplication.GetDesc() };
        Ok((duplication, desc.ModeDesc.Width, desc.ModeDesc.Height))
    }
}
