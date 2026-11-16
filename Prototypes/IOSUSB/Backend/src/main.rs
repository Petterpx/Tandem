//! Independent USB prototype. See THIRD_PARTY.md for MIT upstream provenance.
use anyhow::{Context, Result, anyhow, bail};
use clap::Parser;
use idevice::{
    IdeviceService, ReadWrite, RsdService,
    core_device::{
        CallInfoBlob, DisplayServiceClient, GENERAL_PASTEBOARD, HevcDepacketizer,
        PasteboardServiceClient, RtpPacket, build_screen_audio_offer, build_screen_video_offer,
        build_start_audio_parameters, build_start_video_parameters,
        hid::{
            ButtonState, IndigoHidClient, TOUCHSCREEN_STATE_CONTACT, TOUCHSCREEN_STATE_RELEASE,
            UniversalHidServiceClient,
        },
    },
    core_device_proxy::CoreDeviceProxy,
    rsd::RsdHandshake,
    tcp::handle::{AdapterHandle, UdpSocketHandle},
    usbmuxd::{Connection, UsbmuxdAddr},
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    io::{BufRead, Read, Write},
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    time::{Duration, Instant},
};
use tokio::sync::{mpsc, watch};

const UPSTREAM_REV: &str = "89702099f4d7552f704f93b4526756abda319ceb";
const OP_TIMEOUT: Duration = Duration::from_secs(3);
const MAX_ACCESS_UNIT: usize = 16 * 1024 * 1024;
const MAX_TEXT_BYTES: usize = 8192;
const TEXT_TIMEOUT: Duration = Duration::from_secs(5);
type TouchHid = UniversalHidServiceClient<Box<dyn ReadWrite>>;
type ButtonHid = IndigoHidClient<Box<dyn ReadWrite>>;
type Pasteboard = PasteboardServiceClient<Box<dyn ReadWrite>>;

#[derive(Parser, Debug)]
#[command(about = "Experimental USB HEVC stream + persistent HID; stdin/stderr use NDJSON")]
struct Args {
    #[arg(long)]
    list: bool,
    #[arg(long)]
    probe: bool,
    #[arg(long)]
    self_test: bool,
    #[arg(long)]
    udid: Option<String>,
    #[arg(long)]
    duration: Option<f64>,
    #[arg(long)]
    metrics: Option<PathBuf>,
    /// Emit TUV1 length/timestamp headers around complete Annex-B access units.
    #[arg(long)]
    framed_video: bool,
}

fn event(value: Value) {
    let _ = writeln!(std::io::stderr().lock(), "{value}");
}
async fn bounded<T>(
    name: &str,
    f: impl std::future::Future<Output = Result<T, idevice::IdeviceError>>,
) -> Result<T> {
    match tokio::time::timeout(OP_TIMEOUT, f).await {
        Ok(Ok(value)) => Ok(value),
        Ok(Err(error)) => Err(anyhow!(
            "{}",
            short_error(&format!("{name}: {}", device_error_description(&error)))
        )),
        Err(_) => Err(anyhow!("{name}: timeout")),
    }
}

// The upstream CoreDevice error contains a plist Debug string, sometimes with
// an entire NSKeyedArchive userInfo byte array. Keep device prose and its code,
// but never send those archive bytes to the UI or NDJSON diagnostics.
fn debug_string_field(details: &str, key: &str) -> Option<String> {
    let after_key = details.split_once(&format!("\"{key}\""))?.1;
    let after_string = after_key.split_once("String(")?.1;
    serde_json::Deserializer::from_str(after_string)
        .into_iter::<String>()
        .next()?
        .ok()
}

fn localized_description(value: &plist::Value) -> Option<String> {
    match value {
        plist::Value::Dictionary(dict) => dict
            .get("NSLocalizedDescription")
            .and_then(plist::Value::as_string)
            .map(str::to_owned)
            .or_else(|| dict.values().find_map(localized_description)),
        plist::Value::Array(values) => values.iter().find_map(localized_description),
        _ => None,
    }
}

fn archive_description(details: &str) -> Option<String> {
    // Bound diagnostic parsing independently from the encoded video limit.
    if details.len() > 1024 * 1024 {
        return None;
    }
    for (_, remainder) in details
        .match_indices("Data([")
        .map(|(index, _)| (index, &details[index + 6..]))
    {
        let Some((numbers, _)) = remainder.split_once("])") else {
            continue;
        };
        let bytes: Option<Vec<u8>> = numbers
            .split(',')
            .take(65537)
            .map(|n| n.trim().parse().ok())
            .collect();
        let Some(bytes) = bytes.filter(|bytes| bytes.len() <= 65536) else {
            continue;
        };
        if let Ok(decoded) = ns_keyed_archive::decode::from_bytes(&bytes)
            && let Some(description) = localized_description(&decoded)
        {
            return Some(description);
        }
    }
    None
}

fn short_error(message: &str) -> String {
    let mut cleaned = String::new();
    let mut remainder = message;
    while let Some((prefix, after)) = remainder.split_once("Data([") {
        cleaned.push_str(prefix);
        cleaned.push_str("[binary data omitted]");
        remainder = after.split_once("])").map(|(_, tail)| tail).unwrap_or("");
    }
    cleaned.push_str(remainder);
    let single_line = cleaned.split_whitespace().collect::<Vec<_>>().join(" ");
    if single_line.chars().count() > 500 {
        format!("{}…", single_line.chars().take(499).collect::<String>())
    } else {
        single_line
    }
}

fn device_error_description(error: &idevice::IdeviceError) -> String {
    if let idevice::IdeviceError::Socket(cause) = error {
        return short_error(&format!("device socket I/O failed: {cause}"));
    }
    if let idevice::IdeviceError::CoreDevice(idevice::core_device::CoreDeviceError::DeviceError(
        details,
    )) = error
    {
        let description = debug_string_field(details, "NSLocalizedDescription")
            .or_else(|| archive_description(details));
        let domain = debug_string_field(details, "domain").unwrap_or_else(|| "CoreDevice".into());
        let code = details
            .split_once("\"code\"")
            .and_then(|(_, tail)| tail.split_once("Integer("))
            .and_then(|(_, tail)| tail.split_once(')'))
            .map(|(code, _)| code.trim());
        if let Some(description) = description {
            return short_error(&format!(
                "{domain}{}: {description}",
                code.map(|c| format!(" ({c})")).unwrap_or_default()
            ));
        }
    }
    short_error(&error.to_string())
}

#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
enum Command {
    Touch {
        id: Value,
        phase: Phase,
        x: f64,
        y: f64,
    },
    Button {
        id: Value,
        button: String,
    },
    Text {
        id: Value,
        text: String,
        #[serde(default)]
        submit: bool,
        #[serde(default)]
        replace: bool,
    },
    Key {
        id: Value,
        key: String,
    },
    Stop {
        #[serde(default)]
        id: Value,
    },
}

fn validate_text(text: &str) -> Result<()> {
    if text.is_empty() || text.len() > MAX_TEXT_BYTES {
        bail!("text must contain 1...8192 UTF-8 bytes")
    }
    if text.contains('\0') {
        bail!("text must not contain NUL")
    }
    Ok(())
}

fn verify_pasteboard_text(actual: Option<&str>, expected: &str) -> Result<()> {
    if actual != Some(expected) {
        bail!("native pasteboard verification failed")
    }
    Ok(())
}

fn keyboard_usage(key: &str) -> Option<u64> {
    Some(match key {
        "enter" => 0x28,
        "escape" => 0x29,
        "delete" => 0x2a,
        "tab" => 0x2b,
        "home" => 0x4a,
        "end" => 0x4d,
        "right" => 0x4f,
        "left" => 0x50,
        "down" => 0x51,
        "up" => 0x52,
        _ => return None,
    })
}

// Mark a key before the write: a canceled write can still reach the phone.
// Successful up removes it; failed/canceled operations retain it for cleanup.
#[derive(Default)]
struct KeyboardState {
    held: Vec<u64>,
}
impl KeyboardState {
    fn mark_down(&mut self, usage: u64) {
        if !self.held.contains(&usage) {
            self.held.push(usage);
        }
    }
    fn mark_up(&mut self, usage: u64) {
        self.held.retain(|held| *held != usage);
    }
    async fn down(&mut self, hid: &mut ButtonHid, usage: u64) -> Result<()> {
        self.mark_down(usage);
        // Do not surface upstream payload/error Debug: it may contain text.
        hid.send_keyboard(usage, ButtonState::Down)
            .await
            .map_err(|_| anyhow!("native keyboard down failed"))
    }
    async fn up(&mut self, hid: &mut ButtonHid, usage: u64) -> Result<()> {
        hid.send_keyboard(usage, ButtonState::Up)
            .await
            .map_err(|_| anyhow!("native keyboard release failed"))?;
        self.mark_up(usage);
        Ok(())
    }
    async fn press(&mut self, hid: &mut ButtonHid, usage: u64) -> Result<()> {
        self.down(hid, usage).await?;
        tokio::time::sleep(Duration::from_millis(30)).await;
        self.up(hid, usage).await
    }
    async fn paste(&mut self, hid: &mut ButtonHid, submit: bool, replace: bool) -> Result<()> {
        if replace {
            self.down(hid, 0xe3).await?; // Left Command
            self.press(hid, 0x04).await?; // A (select all in the focused field)
            self.up(hid, 0xe3).await?;
        }
        self.down(hid, 0xe3).await?; // Left Command
        self.press(hid, 0x19).await?; // V
        self.up(hid, 0xe3).await?;
        if submit {
            tokio::time::sleep(Duration::from_millis(50)).await;
            self.press(hid, 0x28).await?;
        }
        Ok(())
    }
    async fn cleanup(&mut self, hid: &mut ButtonHid) -> bool {
        let result = tokio::time::timeout(Duration::from_millis(1500), async {
            let mut released = true;
            for usage in self.held.clone().into_iter().rev() {
                match tokio::time::timeout(
                    Duration::from_millis(500),
                    hid.send_keyboard(usage, ButtonState::Up),
                )
                .await
                {
                    Ok(Ok(())) => self.mark_up(usage),
                    _ => released = false,
                }
            }
            released
        })
        .await;
        result.unwrap_or(false)
    }
}

struct NativeText {
    adapter: AdapterHandle,
    handshake: RsdHandshake,
    pasteboard: Option<Pasteboard>,
    advertised: bool,
}
impl NativeText {
    async fn set_text(&mut self, text: &str) -> Result<()> {
        if !self.advertised {
            bail!("native pasteboard service unavailable")
        }
        if self.pasteboard.is_none() {
            self.pasteboard = Some(
                Pasteboard::connect_rsd(&mut self.adapter, &mut self.handshake)
                    .await
                    .map_err(|_| anyhow!("native pasteboard connection failed"))?,
            );
        }
        let pasteboard = self.pasteboard.as_mut().unwrap();
        pasteboard
            .set_text(text, GENERAL_PASTEBOARD)
            .await
            .map_err(|_| anyhow!("native pasteboard write failed"))?;
        // Verify only this operation's own write before sending any HID event.
        // Neither the intended nor observed clipboard value enters diagnostics.
        let snapshot = pasteboard
            .get(GENERAL_PASTEBOARD)
            .await
            .map_err(|_| anyhow!("native pasteboard verification failed"))?;
        verify_pasteboard_text(snapshot.text().as_deref(), text)
    }
}
#[derive(Clone, Copy, Debug, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
enum Phase {
    Down,
    Move,
    Up,
}
impl Phase {
    fn name(self) -> &'static str {
        match self {
            Self::Down => "down",
            Self::Move => "move",
            Self::Up => "up",
        }
    }
}
#[derive(Debug, Default)]
struct Pointer {
    active: Option<(u16, u16)>,
}
impl Pointer {
    fn prepare(&self, phase: Phase, x: f64, y: f64) -> Result<(u16, u16)> {
        if !x.is_finite()
            || !y.is_finite()
            || !(0.0..=1.0).contains(&x)
            || !(0.0..=1.0).contains(&y)
        {
            bail!("coordinates must be finite and in 0...1")
        }
        match (phase, self.active.is_some()) {
            (Phase::Down, true) => bail!("touch already down"),
            (Phase::Move | Phase::Up, false) => bail!("touch is not down"),
            _ => {}
        }
        Ok(((x * 65535.0).round() as u16, (y * 65535.0).round() as u16))
    }
    fn cleanup(&mut self) -> Option<(u16, u16)> {
        self.active.take()
    }
}

#[derive(Default)]
struct Counters {
    packets: AtomicU64,
    bytes: AtomicU64,
    frames: AtomicU64,
    frames_during_touch: AtomicU64,
    input_sent: AtomicU64,
    input_rejected: AtomicU64,
    sequence_gaps: AtomicU64,
    dropped_access_units: AtomicU64,
    active: AtomicBool,
    ever_video: AtomicBool,
}
impl Counters {
    fn snapshot(&self, elapsed: Duration) -> Value {
        json!({
            "rtp_packets":self.packets.load(Ordering::Relaxed), "annex_b_bytes":self.bytes.load(Ordering::Relaxed),
            "rtp_frame_markers":self.frames.load(Ordering::Relaxed), "rtp_frame_markers_during_touch":self.frames_during_touch.load(Ordering::Relaxed),
            "input_sent":self.input_sent.load(Ordering::Relaxed), "input_rejected":self.input_rejected.load(Ordering::Relaxed),
            "rtp_sequence_gaps":self.sequence_gaps.load(Ordering::Relaxed), "elapsed_ms":elapsed.as_millis(),
            "dropped_access_units":self.dropped_access_units.load(Ordering::Relaxed),
            "frame_metric":"RTP marker with depacketizer output, not decoded/displayed frames"
        })
    }
}

/// Framed mode rejects discontinuous/malformed access units instead of allowing
/// upstream's reorder buffer to emit old NALs under a newer packet's marker.
/// Raw mode retains the original upstream behavior. No incomplete AU is flushed
/// on EOF or timestamp change. All output still uses upstream depacketization.
#[derive(Default)]
struct FramedVideo {
    depacketizer: HevcDepacketizer,
    sequence: Option<u16>,
    timestamp: Option<u32>,
    access_unit: Vec<u8>,
    received_bytes: usize,
    damaged: bool,
    fragment_active: bool,
    synchronized: bool,
}

impl FramedVideo {
    fn reset_access_unit(&mut self) {
        self.timestamp = None;
        self.access_unit.clear();
        self.received_bytes = 0;
        self.damaged = false;
        self.fragment_active = false;
    }

    fn valid_payload(&mut self, payload: &[u8]) -> bool {
        if payload.len() < 2 || payload[0] & 0x80 != 0 || payload[1] & 7 == 0 {
            return false;
        }
        match (payload[0] >> 1) & 0x3f {
            0..=47 => !self.fragment_active,
            48 => {
                if self.fragment_active {
                    return false;
                }
                let mut offset = 2;
                let mut count = 0;
                while offset + 2 <= payload.len() {
                    let length =
                        u16::from_be_bytes([payload[offset], payload[offset + 1]]) as usize;
                    offset += 2;
                    let Some(nal) = payload.get(offset..offset + length) else {
                        return false;
                    };
                    if nal.len() < 2
                        || (nal[0] >> 1) & 0x3f >= 48
                        || nal[0] & 0x80 != 0
                        || nal[1] & 7 == 0
                    {
                        return false;
                    }
                    count += 1;
                    offset += length;
                }
                count > 0 && offset == payload.len()
            }
            49 => {
                if payload.len() < 4 {
                    return false;
                }
                let start = payload[2] & 0x80 != 0;
                let end = payload[2] & 0x40 != 0;
                if payload[2] & 0x3f >= 48 || (start && end) || (start == self.fragment_active) {
                    return false;
                }
                self.fragment_active = !end;
                true
            }
            _ => false,
        }
    }

    // Before seeing a marker/timestamp boundary, require a configuration NAL,
    // AUD or the first slice of a picture. This rejects joining mid-slice.
    fn starts_access_unit(payload: &[u8]) -> bool {
        if payload.len() < 2 {
            return false;
        }
        match (payload[0] >> 1) & 0x3f {
            0..=31 => payload.get(2).is_some_and(|b| b & 0x80 != 0),
            32..=35 => true,
            48 => {
                if payload.len() < 4 {
                    return false;
                }
                let length = u16::from_be_bytes([payload[2], payload[3]]) as usize;
                payload
                    .get(4..4 + length)
                    .is_some_and(Self::starts_access_unit)
            }
            49 => {
                payload.len() >= 4
                    && payload[2] & 0x80 != 0
                    && payload[2] & 0x3f <= 31
                    && payload[3] & 0x80 != 0
            }
            _ => false,
        }
    }

    /// Returns (framed bytes, rejected AU count). Header timestamp is elapsed
    /// host microseconds at receipt of the marker, not a device presentation TS.
    fn push(&mut self, packet: &RtpPacket<'_>, elapsed_us: u64) -> (Option<Vec<u8>>, u64) {
        let gap = self
            .sequence
            .is_some_and(|seq| packet.sequence_number != seq.wrapping_add(1));
        self.sequence = Some(packet.sequence_number);
        let mut rejected = 0;
        if self.timestamp.is_some_and(|ts| ts != packet.timestamp) {
            // A timestamp change without a preceding marker leaves an AU open.
            rejected += 1;
            self.reset_access_unit();
            self.depacketizer = HevcDepacketizer::new();
            self.synchronized = true;
        }
        if self.timestamp.is_none() {
            self.timestamp = Some(packet.timestamp);
            if !self.synchronized && !Self::starts_access_unit(packet.payload) {
                self.damaged = true;
            }
        }
        self.received_bytes = self.received_bytes.saturating_add(packet.payload.len());
        if gap || self.received_bytes > MAX_ACCESS_UNIT {
            self.damaged = true;
        }
        if !self.damaged && !self.valid_payload(packet.payload) {
            self.damaged = true;
        }
        if !self.damaged {
            self.depacketizer
                .push(packet.sequence_number, packet.timestamp, packet.payload);
            let output = self.depacketizer.take_output();
            if self.access_unit.len().saturating_add(output.len()) > MAX_ACCESS_UNIT {
                self.damaged = true;
            } else {
                self.access_unit.extend_from_slice(&output);
            }
        }
        if self.damaged {
            self.access_unit.clear();
            self.depacketizer = HevcDepacketizer::new();
        }
        if !packet.marker {
            return (None, rejected);
        }
        self.synchronized = true;
        let framed = if !self.damaged && !self.fragment_active && !self.access_unit.is_empty() {
            let mut framed = Vec::with_capacity(16 + self.access_unit.len());
            framed.extend_from_slice(b"TUV1");
            framed.extend_from_slice(&(self.access_unit.len() as u32).to_be_bytes());
            framed.extend_from_slice(&elapsed_us.to_be_bytes());
            framed.append(&mut self.access_unit);
            Some(framed)
        } else {
            rejected += 1;
            self.depacketizer = HevcDepacketizer::new();
            None
        };
        self.reset_access_unit();
        (framed, rejected)
    }
}

async fn devices() -> Result<Vec<idevice::usbmuxd::UsbmuxdDevice>> {
    let mut mux = bounded("usbmuxd", UsbmuxdAddr::default().connect(0)).await?;
    Ok(bounded("USB enumeration", mux.get_devices())
        .await?
        .into_iter()
        .filter(|d| d.connection_type == Connection::Usb)
        .collect())
}

async fn connect(udid: &str) -> Result<(AdapterHandle, RsdHandshake)> {
    let dev = devices()
        .await?
        .into_iter()
        .find(|d| d.udid == udid)
        .ok_or_else(|| anyhow!("requested USB device not found"))?;
    let provider = dev.to_provider(UsbmuxdAddr::default(), "TandemIndependentUSBPrototype");
    let proxy = bounded(
        "CoreDevice proxy (unlock and trust this Mac first)",
        CoreDeviceProxy::connect(&provider),
    )
    .await?;
    let port = proxy.tunnel_info().server_rsd_port;
    let mut adapter = proxy.create_software_tunnel()?.to_async_handle();
    let stream = tokio::time::timeout(OP_TIMEOUT, adapter.connect(port))
        .await
        .context("RSD TCP timeout")??;
    let handshake = bounded("RSD handshake", RsdHandshake::new(stream)).await?;
    Ok((adapter, handshake))
}

// One media session for the complete connection. Audio is attempted once as
// upstream does, but video may still authenticate HID when audio is unavailable.
async fn start_stream(
    adapter: &mut AdapterHandle,
    handshake: &mut RsdHandshake,
) -> Result<(
    DisplayServiceClient<Box<dyn ReadWrite>>,
    UdpSocketHandle,
    UdpSocketHandle,
)> {
    let mut client = bounded(
        "display service",
        DisplayServiceClient::connect_rsd(adapter, handshake),
    )
    .await?;
    let audio = adapter.bind_udp(0).await?;
    let video = adapter.bind_udp(0).await?;
    let host = adapter.host_ip().to_string();
    let peer = adapter.peer_ip().to_string();
    let info = CallInfoBlob {
        call_id: 0,
        client_version: 1,
        device_type: "Mac17,7".into(),
        framework_version: "2205.3.1".into(),
        os_version: "25F71".into(),
        device_name: None,
        audio_device_uid: None,
    };
    let session = uuid::Uuid::new_v4();
    let audio_setup = async {
        let audio_offer =
            build_screen_audio_offer(&uuid::Uuid::new_v4().to_string().to_uppercase(), &info)?;
        bounded(
            "audio start",
            client.start_media_stream(build_start_audio_parameters(
                &host,
                audio.local_port(),
                &peer,
                50000,
                audio_offer,
                140,
                session,
            )),
        )
        .await?;
        Ok::<_, anyhow::Error>(())
    }
    .await;
    if let Err(error) = audio_setup {
        event(
            json!({"event":"audio_unavailable","stage":"audio start","message":short_error(&format!("{error:#}")),"video_will_be_attempted":true,"retry":false}),
        );
    }
    let setup = async {
        let video_offer = build_screen_video_offer(
            &uuid::Uuid::new_v4().to_string().to_uppercase(),
            &info,
            uuid::Uuid::new_v4().as_u128() as u32,
        )?;
        bounded(
            "video start",
            client.start_media_stream(build_start_video_parameters(
                &host,
                video.local_port(),
                &peer,
                50001,
                video_offer,
                140,
                1,
                session,
            )),
        )
        .await?;
        Ok::<_, anyhow::Error>(())
    }
    .await;
    if let Err(e) = setup {
        let _ = bounded("partial stream stop", client.stop_media_stream()).await;
        return Err(e);
    }
    Ok((client, audio, video))
}

async fn probe(udid: &str) -> Result<Value> {
    let (mut adapter, mut handshake) = connect(udid).await?;
    let display = handshake
        .services
        .contains_key(DisplayServiceClient::<Box<dyn ReadWrite>>::rsd_service_name().as_ref());
    let mut display_client = bounded(
        "display support service",
        DisplayServiceClient::connect_rsd(&mut adapter, &mut handshake),
    )
    .await?;
    let media_support_info = serde_json::to_value(
        bounded(
            "media support info",
            display_client.get_media_support_info(),
        )
        .await?,
    )?;
    let mut hid = bounded(
        "UniversalHID",
        TouchHid::connect_rsd(&mut adapter, &mut handshake),
    )
    .await?;
    let surfaces = bounded("HID surfaces", hid.list_connected_services()).await?;
    let indigo = handshake
        .services
        .contains_key(ButtonHid::rsd_service_name().as_ref());
    let pasteboard = handshake
        .services
        .contains_key(Pasteboard::rsd_service_name().as_ref());
    Ok(
        json!({"ok":display,"usb":true,"display_service":display,"universal_hid":true,"indigo_hid":indigo,"pasteboard_service":pasteboard,"text":pasteboard && indigo,"text_probe_scope":"service advertisement only; no clipboard access or keyboard event","media_started":false,"input_sent":false,"media_support_info":media_support_info,
        "surfaces":surfaces.into_iter().map(|s|json!({"service_id":s.service_id,"product":s.product,"usage_page":s.primary_usage_page,"usage":s.primary_usage})).collect::<Vec<_>>() }),
    )
}

// Dedicated blocking stdin thread avoids Tokio's uncancellable stdin worker
// keeping the runtime alive after duration, disconnection, or stop. Bounded
// messages and line length prevent unbounded buffering; EOF is explicit.
fn stdin_commands() -> mpsc::Receiver<Option<String>> {
    let (tx, rx) = mpsc::channel(64);
    std::thread::spawn(move || {
        let mut reader = std::io::stdin().lock();
        loop {
            let mut bytes = Vec::new();
            match reader.by_ref().take(16385).read_until(b'\n', &mut bytes) {
                Ok(0) => break,
                Ok(_) if bytes.len() > 16384 => {
                    event(
                        json!({"event":"error","message":"stdin line exceeds 16KiB; closing input"}),
                    );
                    break;
                }
                Ok(_) => {
                    if tx
                        .blocking_send(Some(String::from_utf8_lossy(&bytes).into_owned()))
                        .is_err()
                    {
                        return;
                    }
                }
                Err(_) => break,
            }
        }
        let _ = tx.blocking_send(None);
    });
    rx
}

async fn input_loop(
    mut hid: TouchHid,
    mut indigo: Option<ButtonHid>,
    mut native_text: NativeText,
    mut commands: mpsc::Receiver<Option<String>>,
    mut stop: watch::Receiver<bool>,
    counts: Arc<Counters>,
) -> String {
    let mut pointer = Pointer::default();
    let mut home_held = false;
    let mut keyboard = KeyboardState::default();
    let reason = loop {
        let line = tokio::select! {
            biased;
            _=stop.changed()=>break "shutdown".to_string(),
            cmd=commands.recv()=>match cmd {Some(Some(s))=>s,_=>break "stdin_eof".to_string()}
        };
        let started = Instant::now();
        let cmd = match serde_json::from_str::<Command>(&line) {
            Ok(c) => c,
            Err(e) => {
                counts.input_rejected.fetch_add(1, Ordering::Relaxed);
                event(
                    json!({"event":"input_ack","id":serde_json::from_str::<Value>(&line).ok().and_then(|v|v.get("id").cloned()),"sent":false,"error":format!("invalid input command at line {} column {}", e.line(), e.column())}),
                );
                continue;
            }
        };
        match cmd {
            Command::Stop { id } => {
                event(json!({"event":"stop_ack","id":id}));
                break "stop_command".to_string();
            }
            Command::Text {
                id,
                text,
                submit,
                replace,
            } => {
                let validation = validate_text(&text).and_then(|()| {
                    if indigo.is_none() {
                        bail!("native keyboard service unavailable")
                    }
                    Ok(())
                });
                if let Err(error) = validation {
                    counts.input_rejected.fetch_add(1, Ordering::Relaxed);
                    event(
                        json!({"event":"input_ack","id":id,"op":"text","sent":false,"error":error.to_string()}),
                    );
                    continue;
                }
                // The media stream stays open. SET and readback verification
                // complete before any select-all or paste HID events;
                // no automatic replay occurs after any partial/uncertain send.
                let operation = async {
                    native_text.set_text(&text).await?;
                    keyboard
                        .paste(indigo.as_mut().unwrap(), submit, replace)
                        .await
                };
                let result = tokio::select! {
                    biased;
                    _ = stop.changed() => Err(anyhow!("text input canceled")),
                    result = tokio::time::timeout(TEXT_TIMEOUT, operation) =>
                        result.unwrap_or_else(|_| Err(anyhow!("native text input timeout; device effect uncertain"))),
                };
                let sent = result.is_ok();
                if sent {
                    counts.input_sent.fetch_add(1, Ordering::Relaxed);
                } else {
                    counts.input_rejected.fetch_add(1, Ordering::Relaxed);
                    // A canceled request/reply cannot safely reuse this stream.
                    native_text.pasteboard = None;
                }
                let released = keyboard.cleanup(indigo.as_mut().unwrap()).await;
                event(
                    json!({"event":"input_ack","id":id,"op":"text","text_bytes":text.len(),"replace":replace,"sent":sent,"keys_released":released,"latency_ms":started.elapsed().as_secs_f64()*1000.0,"error":result.as_ref().err().map(|e|e.to_string()),"ack_scope":"pasteboard SET acknowledged, readback verified and HID writes completed; target field insertion unconfirmed","retry":false}),
                );
                if !released {
                    break "keyboard_cleanup_failed".to_string();
                }
                if *stop.borrow() {
                    break "shutdown".to_string();
                }
            }
            Command::Key { id, key } => {
                let Some(usage) = keyboard_usage(&key).filter(|_| indigo.is_some()) else {
                    counts.input_rejected.fetch_add(1, Ordering::Relaxed);
                    event(
                        json!({"event":"input_ack","id":id,"op":"key","sent":false,"error":"unsupported key or native keyboard service unavailable"}),
                    );
                    continue;
                };
                let result = tokio::select! {
                    biased;
                    _ = stop.changed() => Err(anyhow!("key input canceled")),
                    result = tokio::time::timeout(OP_TIMEOUT, keyboard.press(indigo.as_mut().unwrap(), usage)) =>
                        result.unwrap_or_else(|_| Err(anyhow!("native keyboard timeout; device effect uncertain"))),
                };
                let sent = result.is_ok();
                if sent {
                    counts.input_sent.fetch_add(1, Ordering::Relaxed);
                } else {
                    counts.input_rejected.fetch_add(1, Ordering::Relaxed);
                }
                let released = keyboard.cleanup(indigo.as_mut().unwrap()).await;
                event(
                    json!({"event":"input_ack","id":id,"op":"key","key":key,"sent":sent,"keys_released":released,"latency_ms":started.elapsed().as_secs_f64()*1000.0,"error":result.as_ref().err().map(|e|e.to_string()),"ack_scope":"host transport write; device effect unconfirmed","retry":false}),
                );
                if !released {
                    break "keyboard_cleanup_failed".to_string();
                }
                if *stop.borrow() {
                    break "shutdown".to_string();
                }
            }
            Command::Touch { id, phase, x, y } => {
                let (nx, ny) = match pointer.prepare(phase, x, y) {
                    Ok(p) => p,
                    Err(e) => {
                        counts.input_rejected.fetch_add(1, Ordering::Relaxed);
                        event(
                            json!({"event":"input_ack","id":id,"sent":false,"error":e.to_string()}),
                        );
                        continue;
                    }
                };
                // Retain last coordinates before send: a timeout may mean the
                // device received it, so shutdown must still attempt release.
                pointer.active = Some((nx, ny));
                if phase == Phase::Down {
                    counts.active.store(true, Ordering::Relaxed)
                }
                let result = bounded(
                    "touch send",
                    hid.send_touchscreen(
                        if phase == Phase::Up {
                            TOUCHSCREEN_STATE_RELEASE
                        } else {
                            TOUCHSCREEN_STATE_CONTACT
                        },
                        nx,
                        ny,
                        None,
                    ),
                )
                .await;
                let sent = result.is_ok();
                if sent {
                    counts.input_sent.fetch_add(1, Ordering::Relaxed);
                    if phase == Phase::Up {
                        pointer.active = None;
                        counts.active.store(false, Ordering::Relaxed)
                    }
                }
                event(
                    json!({"event":"input_ack","id":id,"op":"touch","phase":phase.name(),"sent":sent,"latency_ms":started.elapsed().as_secs_f64()*1000.0,"error":result.as_ref().err().map(|e|e.to_string()),"ack_scope":"host transport write; device effect unconfirmed"}),
                );
                if !sent {
                    break "touch_transport_error".to_string();
                }
            }
            Command::Button { id, button } => {
                if button != "home" || indigo.is_none() {
                    counts.input_rejected.fetch_add(1, Ordering::Relaxed);
                    event(
                        json!({"event":"input_ack","id":id,"sent":false,"error":"only home is supported; Indigo service must be available"}),
                    );
                    continue;
                }
                let button_hid = indigo.as_mut().unwrap();
                home_held = true;
                let result = async {
                    bounded(
                        "home down",
                        button_hid.send_button(0x0c, 0x40, ButtonState::Down),
                    )
                    .await?;
                    tokio::time::sleep(Duration::from_millis(80)).await;
                    bounded(
                        "home up",
                        button_hid.send_button(0x0c, 0x40, ButtonState::Up),
                    )
                    .await
                }
                .await;
                let sent = result.is_ok();
                if sent {
                    home_held = false;
                    counts.input_sent.fetch_add(1, Ordering::Relaxed);
                }
                event(
                    json!({"event":"input_ack","id":id,"op":"button","button":"home","sent":sent,"latency_ms":started.elapsed().as_secs_f64()*1000.0,"error":result.as_ref().err().map(|e|e.to_string()),"ack_scope":"host transport write; device effect unconfirmed"}),
                );
                if !sent {
                    break "button_transport_error".to_string();
                }
            }
        }
    };
    if let Some((x, y)) = pointer.cleanup() {
        let result = bounded(
            "touch cleanup",
            hid.send_touchscreen(TOUCHSCREEN_STATE_RELEASE, x, y, None),
        )
        .await;
        event(json!({"event":"touch_cleanup","sent":result.is_ok(),"reason":reason}));
    }
    counts.active.store(false, Ordering::Relaxed);
    if !keyboard.held.is_empty() {
        if let Some(hid) = indigo.as_mut() {
            let released = keyboard.cleanup(hid).await;
            event(json!({"event":"keyboard_cleanup","sent":released}));
        }
    }
    if home_held {
        if let Some(hid) = indigo.as_mut() {
            let result =
                bounded("home cleanup", hid.send_button(0x0c, 0x40, ButtonState::Up)).await;
            event(json!({"event":"button_cleanup","sent":result.is_ok()}));
        }
    }
    reason
}

async fn receive_video(
    udp: UdpSocketHandle,
    mut stop: watch::Receiver<bool>,
    counts: Arc<Counters>,
    sink: std::sync::mpsc::SyncSender<Vec<u8>>,
    framed_video: bool,
) -> String {
    let mut depacketizer = HevcDepacketizer::new();
    let mut framed = FramedVideo::default();
    let mut previous = None;
    let mut frame_output = false;
    let started = Instant::now();
    let mut stats = tokio::time::interval(Duration::from_secs(1));
    let mut last_packet = Instant::now();
    let mut reported_idle = 0u64;
    loop {
        tokio::select! {
            _=stop.changed()=>return "shutdown".into(),
            _=stats.tick()=>{
                event(json!({"event":"video_stats","metrics":counts.snapshot(started.elapsed())}));
                let idle=last_packet.elapsed().as_secs();
                if idle/5>reported_idle {reported_idle=idle/5;event(json!({"event":"video_idle","seconds":idle}));}
                if idle>=30 {return "video_idle_timeout_30s".into()}
            },
            received=udp.recv()=>match received {
                Ok(datagram)=>{
                    last_packet=Instant::now();reported_idle=0;
                    let Some(packet)=RtpPacket::parse(&datagram.data) else {continue};
                    if packet.payload_type!=100 {continue}
                    counts.packets.fetch_add(1,Ordering::Relaxed);
                    if let Some(seq)=previous {let missing=packet.sequence_number.wrapping_sub(seq).wrapping_sub(1);if missing>0 && missing<32768 {counts.sequence_gaps.fetch_add(missing as u64,Ordering::Relaxed);}}
                    previous=Some(packet.sequence_number);
                    let output=if framed_video {
                        let (output,rejected)=framed.push(&packet,started.elapsed().as_micros().min(u64::MAX as u128) as u64);
                        if rejected>0 {
                            counts.dropped_access_units.fetch_add(rejected,Ordering::Relaxed);
                            event(json!({"event":"video_frame_dropped","count":rejected,"rtp_timestamp":packet.timestamp,"reason":"incomplete_or_invalid_access_unit"}));
                        }
                        output.unwrap_or_default()
                    } else {
                        depacketizer.push(packet.sequence_number,packet.timestamp,packet.payload);
                        depacketizer.take_output()
                    };
                    if !output.is_empty() {
                        frame_output=true;
                        let length=output.len()-if framed_video {16}else{0};
                        if let Err(e)=sink.try_send(output) {return format!("video_output_error: {e}")}
                        counts.bytes.fetch_add(length as u64,Ordering::Relaxed);
                        if !counts.ever_video.swap(true,Ordering::Relaxed) {event(json!({"event":"video_started","elapsed_ms":started.elapsed().as_millis()}));}
                    }
                    if packet.marker {
                        if frame_output {
                            let frame=counts.frames.fetch_add(1,Ordering::Relaxed)+1;
                            let active=counts.active.load(Ordering::Relaxed);
                            if active {counts.frames_during_touch.fetch_add(1,Ordering::Relaxed);}
                            event(json!({"event":"frame","index":frame,"rtp_timestamp":packet.timestamp,"touch_active":active,"kind":"rtp_access_unit_marker"}));
                        }
                        frame_output=false;
                    }
                },
                Err(_)=>return "video_transport_disconnected".into(),
            }
        }
    }
}

async fn run(args: &Args) -> Result<Value> {
    let udid = args
        .udid
        .as_deref()
        .context("--udid is required (use --list)")?;
    let started = Instant::now();
    let counts = Arc::new(Counters::default());
    let (mut adapter, mut handshake) = connect(udid).await?;
    let (mut media, audio, video) = start_stream(&mut adapter, &mut handshake).await?;
    let setup = async {
        tokio::time::sleep(Duration::from_millis(300)).await;
        let hid = bounded(
            "UniversalHID",
            TouchHid::connect_rsd(&mut adapter, &mut handshake),
        )
        .await?;
        let indigo = match bounded(
            "IndigoHID",
            ButtonHid::connect_rsd(&mut adapter, &mut handshake),
        )
        .await
        {
            Ok(h) => Some(h),
            Err(_) => None,
        };
        Ok::<_, anyhow::Error>((hid, indigo))
    }
    .await;
    let (hid, indigo) = match setup {
        Ok(h) => h,
        Err(e) => {
            let _ = bounded("media stop", media.stop_media_stream()).await;
            return Err(e);
        }
    };
    let home = indigo.is_some();
    let pasteboard_available = handshake
        .services
        .contains_key(Pasteboard::rsd_service_name().as_ref());
    let text_available = home && pasteboard_available;
    let native_text = NativeText {
        adapter,
        handshake,
        pasteboard: None,
        advertised: pasteboard_available,
    };
    let (shutdown, stop) = watch::channel(false);
    let (sink, rx) = std::sync::mpsc::sync_channel::<Vec<u8>>(256);
    let (writer_done, writer_finished) = tokio::sync::oneshot::channel();
    let writer_shutdown = shutdown.clone();
    std::thread::spawn(move || {
        let mut out = std::io::stdout().lock();
        while let Ok(buf) = rx.recv() {
            if out.write_all(&buf).and_then(|_| out.flush()).is_err() {
                let _ = writer_shutdown.send(true);
                break;
            }
        }
        let _ = writer_done.send(());
    });
    let audio_stop = stop.clone();
    let audio_task = tokio::spawn(async move {
        let mut stop = audio_stop;
        loop {
            tokio::select! {_=stop.changed()=>break,value=audio.recv()=>{if value.is_err(){break}}}
        }
    });
    let mut video_task = tokio::spawn(receive_video(
        video,
        stop.clone(),
        counts.clone(),
        sink,
        args.framed_video,
    ));
    // Keep the pasteboard request future on this task. The pinned upstream's
    // generic RSD/pasteboard future does not expose a sufficiently general Send
    // bound for tokio::spawn; media reception still runs in its own task.
    let input_task = input_loop(
        hid,
        indigo,
        native_text,
        stdin_commands(),
        stop.clone(),
        counts.clone(),
    );
    tokio::pin!(input_task);
    event(
        json!({"event":"ready","protocol_version":1,"codec":"hevc_annex_b","video_framing":if args.framed_video {"tuv1"}else{"raw"},"transport":"usb_coredevice","single_media_session":true,"touch":true,"home":home,"keyboard":home,"text":text_available,"text_method":"native_pasteboard_cmd_v","text_max_utf8_bytes":MAX_TEXT_BYTES,"text_availability_scope":"RSD service advertisement; connection deferred until text command"}),
    );
    let timer = async {
        if let Some(duration) = args.duration {
            tokio::time::sleep(Duration::from_secs_f64(duration)).await;
        } else {
            std::future::pending::<()>().await;
        }
    };
    tokio::pin!(timer);
    let mut writer_stop = stop.clone();
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    let mut input_done = false;
    let mut video_done = false;
    let reason = tokio::select! {
        value=&mut input_task=>{input_done=true;value},
        value=&mut video_task=>{video_done=true;value.unwrap_or_else(|_|"video_task_error".into())},
        _=&mut timer=>"duration_elapsed".into(),
        _=tokio::signal::ctrl_c()=>"sigint".into(),
        _=terminate.recv()=>"sigterm".into(),
        _=writer_stop.changed()=>"output_closed".into(),
    };
    let _ = shutdown.send(true);
    // Keep the auth-gating stream alive until all outstanding contacts have
    // received their bounded, best-effort release attempt.
    if !input_done
        && tokio::time::timeout(Duration::from_secs(10), &mut input_task)
            .await
            .is_err()
    {
        event(json!({"event":"error","message":"input cleanup exceeded deadline"}));
    }
    if !video_done {
        if tokio::time::timeout(Duration::from_secs(1), &mut video_task)
            .await
            .is_err()
        {
            video_task.abort();
        }
    }
    let _ = tokio::time::timeout(Duration::from_secs(1), writer_finished).await;
    audio_task.abort();
    let stopped = bounded("media stop", media.stop_media_stream())
        .await
        .is_ok();
    event(json!({"event":"disconnected","reason":reason,"media_stop_sent":stopped}));
    Ok(
        json!({"schema_version":1,"upstream_revision":UPSTREAM_REV,"reason":reason,"single_media_session":true,"media_stop_sent":stopped,"metrics":counts.snapshot(started.elapsed())}),
    )
}

fn self_test() -> Result<()> {
    let mut pointer = Pointer::default();
    assert_eq!(pointer.prepare(Phase::Down, 0.0, 1.0)?, (0, 65535));
    assert!(pointer.prepare(Phase::Move, 0.5, 0.5).is_err());
    assert!(pointer.prepare(Phase::Down, f64::NAN, 0.0).is_err());
    assert!(pointer.prepare(Phase::Down, -0.1, 0.0).is_err());
    pointer.active = Some((123, 456));
    assert!(pointer.prepare(Phase::Down, 0.5, 0.5).is_err());
    assert_eq!(pointer.prepare(Phase::Move, 0.5, 0.5)?, (32768, 32768));
    assert_eq!(pointer.cleanup(), Some((123, 456)));
    assert_eq!(pointer.cleanup(), None);
    let mut datagram = vec![0x80, 0xe4, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1];
    datagram.extend_from_slice(&[0x26, 1, 0xaa, 0xbb]);
    let packet = RtpPacket::parse(&datagram).context("RTP parse")?;
    assert!(packet.marker);
    let mut depacketizer = HevcDepacketizer::new();
    depacketizer.push(packet.sequence_number, packet.timestamp, packet.payload);
    let output = depacketizer.take_output();
    assert_eq!(output, vec![0, 0, 0, 1, 0x26, 1, 0xaa, 0xbb]);
    assert!(RtpPacket::parse(&[0u8; 12]).is_none());
    assert!(
        serde_json::from_str::<Command>(r#"{"id":1,"op":"touch","phase":"move","x":0.5,"y":0.5}"#)
            .is_ok()
    );
    assert!(serde_json::from_str::<Command>(r#"{"id":1,"op":"tap","x":0.5,"y":0.5}"#).is_err());
    let mut framed = FramedVideo::default();
    let (output, rejected) = framed.push(&packet, 0x0102030405060708);
    let output = output.context("TUV1 self-test frame")?;
    assert_eq!(rejected, 0);
    assert_eq!(&output[..4], b"TUV1");
    assert_eq!(u32::from_be_bytes(output[4..8].try_into()?), 8);
    assert_eq!(
        u64::from_be_bytes(output[8..16].try_into()?),
        0x0102030405060708
    );
    assert_eq!(&output[16..], &[0, 0, 0, 1, 0x26, 1, 0xaa, 0xbb]);
    Ok(())
}

#[tokio::main]
async fn main() {
    let args = Args::parse();
    let result = async {
        if let Some(d) = args.duration {
            if !d.is_finite() || d <= 0.0 || d > 86400.0 {
                bail!("duration must be in (0,86400]")
            }
        }
        if args.self_test {
            self_test()?;
            println!("{}", json!({"ok":true,"self_test":true}));
            return Ok(());
        }
        if args.list {
            println!(
                "{}",
                json!(
                    devices()
                        .await?
                        .into_iter()
                        .map(|d| json!({"udid":d.udid,"device_id":d.device_id,"connection":"usb"}))
                        .collect::<Vec<_>>()
                )
            );
            return Ok(());
        }
        if args.probe {
            println!(
                "{}",
                probe(args.udid.as_deref().context("--probe requires --udid")?).await?
            );
            return Ok(());
        }
        let metrics = run(&args).await?;
        if let Some(path) = &args.metrics {
            std::fs::write(path, serde_json::to_vec_pretty(&metrics)?).context("write metrics")?;
        }
        event(json!({"event":"summary","result":metrics}));
        Ok::<_, anyhow::Error>(())
    }
    .await;
    if let Err(e) = result {
        event(json!({"event":"error","message":short_error(&format!("{e:#}"))}));
        std::process::exit(1)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pasteboard_readback_must_match_own_write_exactly_without_exposing_text() {
        assert!(verify_pasteboard_text(Some("中文 😀"), "中文 😀").is_ok());
        for actual in [None, Some("old clipboard secret"), Some("中文 😀 ")] {
            assert_eq!(
                verify_pasteboard_text(actual, "中文 😀")
                    .unwrap_err()
                    .to_string(),
                "native pasteboard verification failed"
            );
        }
    }

    #[test]
    fn unicode_text_protocol_is_bounded_and_rejects_extra_fields() {
        let input =
            serde_json::to_string(&json!({"id":7,"op":"text","text":"中文 ASCII 😀"})).unwrap();
        let Command::Text {
            text,
            submit,
            replace,
            ..
        } = serde_json::from_str(&input).unwrap()
        else {
            panic!("expected text command");
        };
        assert_eq!(text, "中文 ASCII 😀");
        assert!(!submit);
        assert!(!replace);
        assert!(validate_text(&text).is_ok());
        assert!(validate_text(&"a".repeat(8192)).is_ok());
        assert!(validate_text(&"a".repeat(8193)).is_err());
        assert!(validate_text(&"中".repeat(2731)).is_err());
        assert!(validate_text("").is_err());
        assert!(validate_text("a\0b").is_err());
        assert!(
            serde_json::from_value::<Command>(
                json!({"id":1,"op":"text","text":"x","clipboard":true})
            )
            .is_err()
        );
        assert!(
            serde_json::from_value::<Command>(
                json!({"id":1,"op":"text","text":"x","submit":"yes"})
            )
            .is_err()
        );
        assert!(
            serde_json::from_value::<Command>(
                json!({"id":1,"op":"text","text":"x","replace":"yes"})
            )
            .is_err()
        );
    }

    #[test]
    fn text_replace_is_explicit_and_does_not_imply_submit() {
        let Command::Text {
            replace,
            submit,
            text,
            ..
        } = serde_json::from_value(json!({"id":1,"op":"text","text":"替换 😀","replace":true}))
            .unwrap()
        else {
            panic!("expected text command");
        };
        assert!(replace);
        assert!(!submit);
        assert_eq!(text, "替换 😀");
    }

    #[test]
    fn native_keyboard_tracks_canceled_down_and_reverse_release_order() {
        let mut state = KeyboardState::default();
        state.mark_down(0xe3);
        state.mark_down(0x19);
        state.mark_down(0x19);
        assert_eq!(
            state.held.iter().rev().copied().collect::<Vec<_>>(),
            vec![0x19, 0xe3]
        );
        state.mark_up(0x19);
        assert_eq!(state.held, vec![0xe3]);
        state.mark_up(0xe3);
        assert!(state.held.is_empty());
        assert_eq!(keyboard_usage("enter"), Some(0x28));
        assert_eq!(keyboard_usage("delete"), Some(0x2a));
        assert_eq!(keyboard_usage("left"), Some(0x50));
        assert_eq!(keyboard_usage("中文"), None);
    }

    fn feed(
        video: &mut FramedVideo,
        seq: u16,
        ts: u32,
        marker: bool,
        payload: &[u8],
    ) -> (Option<Vec<u8>>, u64) {
        let mut datagram = vec![
            0x80,
            100 | if marker { 0x80 } else { 0 },
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            1,
        ];
        datagram[2..4].copy_from_slice(&seq.to_be_bytes());
        datagram[4..8].copy_from_slice(&ts.to_be_bytes());
        datagram.extend_from_slice(payload);
        video.push(&RtpPacket::parse(&datagram).unwrap(), 123456)
    }

    #[test]
    fn protocol_rtp_pointer_and_eof_release() {
        super::self_test().unwrap()
    }

    #[test]
    fn tuv1_aggregates_config_and_picture_until_marker() {
        let mut video = FramedVideo::default();
        assert_eq!(
            feed(&mut video, 65535, 10, false, &[0x40, 1, 0xaa]),
            (None, 0)
        );
        let (frame, rejected) = feed(&mut video, 0, 10, true, &[0x26, 1, 0x80, 0xbb]);
        assert_eq!(rejected, 0);
        let frame = frame.unwrap();
        let payload = &[0, 0, 0, 1, 0x40, 1, 0xaa, 0, 0, 0, 1, 0x26, 1, 0x80, 0xbb];
        assert_eq!(&frame[16..], payload);
        assert_eq!(&frame[..4], b"TUV1");
        assert_eq!(
            u32::from_be_bytes(frame[4..8].try_into().unwrap()) as usize,
            payload.len()
        );
        assert_eq!(u64::from_be_bytes(frame[8..16].try_into().unwrap()), 123456);
    }

    #[test]
    fn tuv1_reassembles_complete_fragmented_nal_only() {
        let mut video = FramedVideo::default();
        assert_eq!(
            feed(&mut video, 1, 10, false, &[98, 1, 0x80 | 19, 0x80, 0xaa]),
            (None, 0)
        );
        let (frame, rejected) = feed(&mut video, 2, 10, true, &[98, 1, 0x40 | 19, 0xbb]);
        assert_eq!(rejected, 0);
        assert_eq!(
            &frame.unwrap()[16..],
            &[0, 0, 0, 1, 38, 1, 0x80, 0xaa, 0xbb]
        );
        assert_eq!(
            feed(&mut video, 3, 20, true, &[98, 1, 0x80 | 19, 0x80]),
            (None, 1)
        );
        assert_eq!(feed(&mut video, 4, 30, true, &[]), (None, 1));
        assert!(feed(&mut video, 5, 40, true, &[0x26, 1, 0x80]).0.is_some());
    }

    #[test]
    fn tuv1_drops_loss_and_never_merges_unterminated_picture() {
        let mut video = FramedVideo::default();
        assert_eq!(feed(&mut video, 1, 10, false, &[0x26, 1, 0x80]), (None, 0));
        assert_eq!(feed(&mut video, 3, 10, true, &[0x26, 1, 0x00]), (None, 1));
        assert!(feed(&mut video, 4, 20, true, &[0x26, 1, 0x80]).0.is_some());
        assert_eq!(
            feed(&mut video, 5, 30, false, &[0x26, 1, 0x80, 0xaa]),
            (None, 0)
        );
        let (frame, rejected) = feed(&mut video, 6, 40, true, &[0x26, 1, 0x80, 0xbb]);
        assert_eq!(rejected, 1);
        assert_eq!(&frame.unwrap()[16..], &[0, 0, 0, 1, 0x26, 1, 0x80, 0xbb]);
        // On EOF the unmarked AU remains buffered, with no framed output.
        assert_eq!(feed(&mut video, 7, 50, false, &[0x26, 1, 0x80]), (None, 0));
    }

    #[test]
    fn tuv1_rejects_truncated_aggregation_mid_picture_join_and_oversize() {
        let mut video = FramedVideo::default();
        assert_eq!(feed(&mut video, 1, 10, true, &[0x26, 1, 0x00]), (None, 1));
        // A valid first AP NAL followed by an incomplete length/data entry must
        // not leak the first NAL as a complete frame.
        assert_eq!(
            feed(
                &mut video,
                2,
                20,
                true,
                &[96, 1, 0, 3, 0x26, 1, 0x80, 0, 10, 1]
            ),
            (None, 1)
        );
        let mut oversized = vec![0; MAX_ACCESS_UNIT + 1];
        oversized[..3].copy_from_slice(&[0x26, 1, 0x80]);
        assert_eq!(feed(&mut video, 3, 30, true, &oversized), (None, 1));
        assert!(video.access_unit.is_empty());
        assert!(feed(&mut video, 4, 40, true, &[0x26, 1, 0x80]).0.is_some());
    }

    #[tokio::test]
    async fn device_error_keeps_stage_code_and_plain_reason() {
        let detail = r#"Dictionary({"domain": String("com.apple.CoreDeviceError"), "code": Integer(9022), "userInfo": Dictionary({"NSLocalizedDescription": String("A phone or VoIP call is currently in progress on the device.")})})"#;
        let error = idevice::IdeviceError::CoreDevice(
            idevice::core_device::CoreDeviceError::DeviceError(detail.into()),
        );
        let public = bounded("video start", async { Err::<(), _>(error) })
            .await
            .unwrap_err()
            .to_string();
        assert_eq!(
            public,
            "video start: com.apple.CoreDeviceError (9022): A phone or VoIP call is currently in progress on the device."
        );
        assert!(!public.contains("Dictionary"));
    }

    #[test]
    fn device_error_decodes_archived_user_info_without_logging_bytes() {
        let mut info = plist::Dictionary::new();
        info.insert(
            "NSLocalizedDescription".into(),
            "Audio is unavailable during a call.".into(),
        );
        let bytes = ns_keyed_archive::encode::encode_to_bytes(info.into()).unwrap();
        let detail = format!(
            "Dictionary({{\"domain\": String(\"com.apple.CoreDeviceError\"), \"code\": Integer(9022), \"userInfo\": {:?}}})",
            plist::Value::Data(bytes)
        );
        let error = idevice::IdeviceError::CoreDevice(
            idevice::core_device::CoreDeviceError::DeviceError(detail),
        );
        let public = device_error_description(&error);
        assert_eq!(
            public,
            "com.apple.CoreDeviceError (9022): Audio is unavailable during a call."
        );
        assert!(!public.contains("Data(["));
        assert!(!public.contains("NSKeyed"));
    }

    #[test]
    fn public_error_fallback_removes_binary_arrays_and_caps_unicode_length() {
        assert_eq!(
            short_error("audio start: Data([98, 112, 108, 105, 115, 116]) failed"),
            "audio start: [binary data omitted] failed"
        );
        let long = short_error(&format!("video start: {}", "错误".repeat(400)));
        assert_eq!(long.chars().count(), 500);
        assert!(long.starts_with("video start:"));
        assert!(long.ends_with('…'));
        let socket = idevice::IdeviceError::Socket(std::io::Error::new(
            std::io::ErrorKind::ConnectionReset,
            "connection reset by peer",
        ));
        assert!(device_error_description(&socket).contains("connection reset by peer"));
    }
}
