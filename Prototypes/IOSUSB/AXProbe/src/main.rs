//! Independent native AX protocol experiment; no product integration or app input.
use anyhow::{Context, Result, anyhow, bail};
use clap::{Parser, ValueEnum};
use idevice::{
    Idevice, IdeviceService, ReadWrite, RsdService,
    core_device_proxy::CoreDeviceProxy,
    dvt::{
        message::{AuxValue, Message},
        remote_server::RemoteServerClient,
    },
    lockdown::LockdownClient,
    provider::IdeviceProvider,
    rsd::RsdHandshake,
    usbmuxd::{Connection, UsbmuxdAddr},
};
use plist::Value;
use rustls::{
    DigitallySignedStruct, SignatureScheme,
    client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
    pki_types::{CertificateDer, PrivateKeyDer, ServerName, UnixTime, pem::PemObject},
};
use serde_json::{Value as Json, json};
use std::{borrow::Cow, collections::HashSet, sync::Arc, time::Duration};

const SERVICE: &str = "com.apple.accessibility.axAuditDaemon.remoteserver.shim.remote";
const USB_SERVICE: &str = "com.apple.accessibility.axAuditDaemon.remoteserver";
const TIMEOUT: Duration = Duration::from_secs(8);
const CLEANUP_GRACE: Duration = Duration::from_millis(500);
type Remote = RemoteServerClient<Box<dyn ReadWrite>>;
const HIERARCHY_ATTRIBUTE: &str = "_AXHierarchyElementsAttribute";

fn connection_phase(phase: &'static str) {
    // Fixed phase labels only: no pairing fields, certificate bytes, or device IDs.
    eprintln!("{}", json!({"event":"connection_phase", "phase":phase}));
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum HierarchyMode {
    Minimal,
    Full,
    Both,
}

#[derive(Parser)]
#[command(about = "Experimental native USB AX metadata / bounded inspector-focus walk")]
struct Args {
    /// Required for any device access. Without this flag only usage is printed.
    #[arg(long)]
    probe: bool,
    #[arg(long)]
    udid: Option<String>,
    /// Use CoreDevice/RSD rather than the default direct USB lockdown service.
    #[arg(long)]
    rsd: bool,
    /// Explicitly move INSPECTOR focus (not VoiceOver focus), up to this many nodes.
    /// May scroll the app and briefly highlight elements; does not activate them.
    #[arg(long, value_parser = clap::value_parser!(u16).range(1..=500))]
    walk: Option<u16>,
    /// Attributes to query while each node holds the inspector focus.
    #[arg(
        long,
        value_delimiter = ',',
        default_value = "Label,Identifier,Value,Frame,Traits"
    )]
    attributes: Vec<String>,
    /// Read first/last special element (0/1); never called unless specified.
    #[arg(long, value_delimiter = ',', value_parser = clap::value_parser!(u8).range(0..=1))]
    special: Vec<u8>,
    /// Read native hierarchy on each walked/special element. Full reuses the
    /// original attribute metadata from a focus event, when supplied by iOS.
    #[arg(long, value_enum, num_args = 0..=1, default_missing_value = "minimal")]
    hierarchy: Option<HierarchyMode>,
    /// Enable the transient Inspector for these experiments, then disable it
    /// during cleanup. Inspector focus may scroll or highlight the app.
    #[arg(long)]
    inspector_enable: bool,
}

struct AxTransport(Remote);

// Device certificates from lockdown pairing are not public DNS identities.
// Match the exact paired device certificate and still verify TLS signatures.
#[derive(Debug)]
struct PairedDeviceVerifier(CertificateDer<'static>);

impl ServerCertVerifier for PairedDeviceVerifier {
    fn verify_server_cert(
        &self,
        leaf: &CertificateDer<'_>,
        _chain: &[CertificateDer<'_>],
        _name: &ServerName<'_>,
        _ocsp: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        if leaf.as_ref() != self.0.as_ref() {
            return Err(rustls::Error::General(
                "AX server certificate differs from local device pairing".into(),
            ));
        }
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            signature,
            &rustls::crypto::ring::default_provider().signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            signature,
            &rustls::crypto::ring::default_provider().signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        rustls::crypto::ring::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }
}

async fn strip_service_tls(
    socket: Box<dyn ReadWrite>,
    pairing: &idevice::pairing_file::PairingFile,
) -> Result<Box<dyn ReadWrite>> {
    use tokio::io::AsyncWriteExt;
    connection_phase("ax_service_tls_config");
    let config = rustls::ClientConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_protocol_versions(&[&rustls::version::TLS12])
    .context("AX service TLS protocol config")?
    .dangerous()
    .with_custom_certificate_verifier(Arc::new(PairedDeviceVerifier(
        pairing.device_certificate.clone(),
    )))
    .with_client_auth_cert(
        vec![pairing.host_certificate.clone()],
        PrivateKeyDer::from_pem_slice(&pairing.host_private_key)
            .context("AX service in-memory pairing key parse")?,
    )
    .context("AX service TLS client identity config")?;
    let connector = tokio_rustls::TlsConnector::from(Arc::new(config));
    connection_phase("ax_service_tls_handshake");
    let mut tls = connector
        .connect(
            ServerName::try_from("Device").context("AX service TLS server name")?,
            socket,
        )
        .await
        .context("AX service TLS handshake before plaintext DTX")?;
    connection_phase("ax_service_tls_flush");
    tls.flush()
        .await
        .context("AX service TLS handshake flush")?;
    // Deliberately do not send close_notify: AX speaks bare DTX after TLS auth.
    let (socket, _) = tls.into_inner();
    connection_phase("ax_service_plaintext_transport_ready");
    Ok(socket)
}

impl RsdService for AxTransport {
    fn rsd_service_name() -> Cow<'static, str> {
        Cow::Borrowed(SERVICE)
    }

    async fn from_stream(stream: Box<dyn ReadWrite>) -> Result<Self, idevice::IdeviceError> {
        // .shim.remote uses lockdown framing before DTX. Native dtservicehub does not.
        let mut service = Idevice::new(stream, "TandemAXProbe");
        service.rsd_checkin().await?;
        let socket = service
            .get_socket()
            .ok_or(idevice::IdeviceError::NoEstablishedConnection)?;
        // AX does not use the Instruments published-capabilities exchange.
        // Creating the client starts its reader but sends no handshake message.
        Ok(Self(Remote::with_label(socket, "TandemAXProbe")))
    }
}

fn dict(entries: impl IntoIterator<Item = (impl Into<String>, Value)>) -> Value {
    Value::Dictionary(entries.into_iter().map(|(k, v)| (k.into(), v)).collect())
}

fn wrapped(kind: &str, value: Value) -> Value {
    dict([("ObjectType", Value::String(kind.into())), ("Value", value)])
}

fn pass(value: Value) -> Value {
    wrapped("passthrough", value)
}

fn element(identifier: &[u8]) -> Value {
    wrapped(
        "AXAuditElement_v1",
        pass(dict([(
            "PlatformElementValue_v1",
            pass(Value::Data(identifier.to_vec())),
        )])),
    )
}

fn attribute(name: &str) -> Value {
    wrapped(
        "AXAuditElementAttribute_v1",
        pass(dict([(
            "AttributeNameValue_v1",
            pass(Value::String(name.into())),
        )])),
    )
}

fn find_full_attribute(value: &Value, name: &str) -> Option<Value> {
    match value {
        Value::Dictionary(fields) => {
            if fields.get("ObjectType").and_then(Value::as_string)
                == Some("AXAuditElementAttribute_v1")
                && unbox(value)
                    .as_dictionary()
                    .and_then(|d| d.get("AttributeNameValue_v1"))
                    .and_then(Value::as_string)
                    == Some(name)
            {
                return Some(value.clone());
            }
            fields.values().find_map(|v| find_full_attribute(v, name))
        }
        Value::Array(values) => values.iter().find_map(|v| find_full_attribute(v, name)),
        _ => None,
    }
}

fn identifier(value: &Value) -> Option<Vec<u8>> {
    let value = unbox(value);
    let fields = value.as_dictionary()?;
    if let Some(bytes) = fields
        .get("PlatformElementValue_v1")
        .and_then(Value::as_data)
    {
        return Some(bytes.to_vec());
    }
    ["ElementValue_v1", "AuditElementValue_v1"]
        .into_iter()
        .find_map(|name| fields.get(name).and_then(identifier))
}

/// Only ChildrenValue_v1 establishes parentage. Other fields survive verbatim;
/// absent children and geometry remain unknown, rather than being fabricated.
fn hierarchy_nodes(value: &Value) -> Vec<Json> {
    fn collect(value: &Value, path: String, parent_path: Option<&str>, output: &mut Vec<Json>) {
        let unboxed = unbox(value);
        if let Some(values) = unboxed.as_array() {
            for (index, node) in values.iter().enumerate() {
                collect(node, format!("{path}[{index}]"), parent_path, output);
            }
            return;
        }
        let Some(fields) = unboxed.as_dictionary() else {
            return;
        };
        if !fields.contains_key("AuditElementValue_v1") {
            return;
        }
        let children = fields.get("ChildrenValue_v1");
        let children_status = match children {
            None => "not_provided",
            Some(Value::Array(_)) => "provided",
            Some(_) => "unexpected_type",
        };
        output.push(json!({
            "path":path, "parent_path":parent_path,
            "platform_identifier":identifier(&unboxed).map(|bytes| hex(&bytes)),
            "role":fields.get("HumanReadableRoleDescriptionValue_v1").map(as_json),
            "description":fields.get("HumanReadableDescriptionValue_v1").map(as_json),
            "ignored":fields.get("IsIgnoredValue_v1").map(as_json),
            "children_status":children_status, "fields":as_json(&unboxed),
        }));
        if let Some(Value::Array(children)) = children {
            for (index, child) in children.iter().enumerate() {
                collect(
                    child,
                    format!("{path}.ChildrenValue_v1[{index}]"),
                    Some(&path),
                    output,
                );
            }
        }
    }
    let mut nodes = Vec::new();
    collect(value, "$".into(), None, &mut nodes);
    nodes
}

/// Preserve all AX fields, including fields not yet understood, without instantiating
/// Objective-C/Python objects. Class tags remain in the raw message if needed.
fn unbox(value: &Value) -> Value {
    match value {
        Value::Dictionary(d) => {
            if d.contains_key("ObjectType")
                && let Some(inner) = d.get("Value")
            {
                return unbox(inner);
            }
            Value::Dictionary(d.iter().map(|(k, v)| (k.clone(), unbox(v))).collect())
        }
        Value::Array(a) => Value::Array(a.iter().map(unbox).collect()),
        _ => value.clone(),
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn as_json(value: &Value) -> Json {
    match value {
        Value::Data(bytes) => json!({"data_hex":hex(bytes)}),
        Value::Array(a) => Json::Array(a.iter().map(as_json).collect()),
        Value::Dictionary(d) => {
            Json::Object(d.iter().map(|(k, v)| (k.clone(), as_json(v))).collect())
        }
        _ => serde_json::to_value(value).unwrap_or_else(|_| json!(format!("{value:?}"))),
    }
}

fn aux_value(value: &AuxValue) -> Result<Value> {
    Ok(match value {
        AuxValue::Array(bytes) => ns_keyed_archive::decode::from_bytes(bytes)?,
        AuxValue::String(s) => Value::String(s.clone()),
        AuxValue::U32(n) => Value::Integer((*n).into()),
        AuxValue::I64(n) => Value::Integer((*n).into()),
        AuxValue::Double(n) => Value::Real(*n),
        AuxValue::PrimitiveDictionary(entries) => Value::Array(
            entries
                .iter()
                .flat_map(|(_, values)| values.iter())
                .map(aux_value)
                .collect::<Result<_>>()?,
        ),
        AuxValue::Null => Value::String("<null>".into()),
    })
}

fn event_payload_raw(message: &Message) -> Result<Value> {
    let values = message
        .aux
        .as_ref()
        .map(|a| a.values.as_slice())
        .unwrap_or(&[]);
    let mut decoded = values.iter().map(aux_value).collect::<Result<Vec<_>>>()?;
    Ok(if decoded.len() == 1 {
        decoded.remove(0)
    } else {
        Value::Array(decoded)
    })
}

fn header_u32(message: &Message, offset: usize) -> u32 {
    u32::from_le_bytes(
        message.message_header.serialize()[offset..offset + 4]
            .try_into()
            .unwrap(),
    )
}

struct AxClient {
    remote: Remote,
    // No channels/other callers are created, so public call_method increments once
    // per send. Correlate replies using the public serialized header since upstream
    // does not expose its correlated-reply method outside the crate.
    sent: u32,
}

impl AxClient {
    async fn send(&mut self, selector: &str, args: Vec<Value>, reply: bool) -> Result<u32> {
        self.sent += 1;
        let args = if args.is_empty() {
            None
        } else {
            Some(args.into_iter().map(AuxValue::archived_value).collect())
        };
        tokio::time::timeout(
            TIMEOUT,
            self.remote.call_method(0, Some(selector), args, reply),
        )
        .await
        .context(format!("{selector}: send timeout"))??;
        Ok(self.sent)
    }

    async fn invoke_raw(&mut self, selector: &str, args: Vec<Value>) -> Result<Value> {
        let id = self.send(selector, args, true).await?;
        tokio::time::timeout(TIMEOUT, async {
            loop {
                let message = self.remote.read_message(0).await?;
                if header_u32(&message, 16) == id && header_u32(&message, 20) != 0 {
                    // DTX ERROR/FAULT are not successful attribute values.
                    if matches!(message.payload_header.serialize()[0], 4 | 0x10 | 0x11) {
                        bail!("{selector}: DTX error {:?}", message.data);
                    }
                    return Ok(message
                        .data
                        .as_ref()
                        .cloned()
                        .unwrap_or(Value::String("<null>".into())));
                }
            }
        })
        .await
        .context(format!("{selector}: response timeout"))?
    }

    async fn invoke(&mut self, selector: &str, args: Vec<Value>) -> Result<Value> {
        Ok(unbox(&self.invoke_raw(selector, args).await?))
    }

    async fn next_focus(&mut self) -> Result<Value> {
        // Inspector focus may scroll the app and show a cursor, even when visuals
        // were previously disabled. Cleanup must explicitly hide that cursor.
        let options = pass(dict([
            ("direction", pass(Value::Integer(4.into()))),
            ("allowNonAX", pass(Value::Integer(0.into()))),
            ("includeContainers", pass(Value::Integer(1.into()))),
        ]));
        self.send("deviceInspectorMoveWithOptions:", vec![options], false)
            .await?;
        tokio::time::timeout(TIMEOUT, async {
            loop {
                let message = self.remote.read_message(0).await?;
                if message.data.as_ref().and_then(Value::as_string)
                    == Some("hostInspectorCurrentElementChanged:")
                {
                    let payload = event_payload_raw(&message)?;
                    return Ok(match payload {
                        Value::Array(mut values) if !values.is_empty() => values.remove(0),
                        other => other,
                    });
                }
            }
        })
        .await
        .context("inspector focus event timeout")?
    }

    async fn walk(
        &mut self,
        limit: u16,
        attributes: &[String],
        hierarchy: Option<HierarchyMode>,
    ) -> Result<()> {
        self.send(
            "deviceSetAppMonitoringEnabled:",
            vec![Value::Boolean(true)],
            false,
        )
        .await?;
        self.send(
            "deviceInspectorSetMonitoredEventType:",
            vec![Value::Integer(0.into())],
            false,
        )
        .await?;
        self.walk_nodes(limit, attributes, hierarchy).await
    }

    async fn walk_nodes(
        &mut self,
        limit: u16,
        attributes: &[String],
        hierarchy: Option<HierarchyMode>,
    ) -> Result<()> {
        let mut visited = HashSet::new();
        for index in 0..limit {
            let raw_focus = self.next_focus().await?;
            let focus = unbox(&raw_focus);
            let identifier = identifier(&focus).ok_or_else(|| {
                anyhow!(
                    "focus event missing platform element identifier: {:?}",
                    as_json(&focus)
                )
            })?;
            if !visited.insert(identifier.clone()) {
                println!(
                    "{}",
                    json!({"event":"walk_finished", "reason":"repeated_identifier", "count":visited.len(), "complete_tree":false})
                );
                return Ok(());
            }
            let mut fields = serde_json::Map::new();
            for name in attributes {
                let value = self
                    .invoke(
                        "deviceElement:valueForAttribute:",
                        vec![element(&identifier), attribute(name)],
                    )
                    .await?;
                fields.insert(name.clone(), as_json(&value));
            }
            println!(
                "{}",
                json!({"event":"element", "index":index, "platform_identifier":hex(&identifier), "focus":as_json(&focus), "attributes":fields})
            );
            if let Some(mode) = hierarchy {
                self.read_hierarchy(
                    &identifier,
                    Some(&raw_focus),
                    mode,
                    json!({"walk_index":index}),
                )
                .await?;
            }
        }
        println!(
            "{}",
            json!({"event":"walk_finished", "reason":"limit", "count":visited.len(), "complete_tree":false})
        );
        Ok(())
    }

    async fn read_hierarchy(
        &mut self,
        identifier: &[u8],
        focus: Option<&Value>,
        mode: HierarchyMode,
        source: Json,
    ) -> Result<()> {
        let modes = match mode {
            HierarchyMode::Minimal => &[false][..],
            HierarchyMode::Full => &[true][..],
            HierarchyMode::Both => &[false, true][..],
        };
        for full in modes {
            let flavor = if *full { "full" } else { "minimal" };
            let request_attribute = if *full {
                let Some(metadata) =
                    focus.and_then(|f| find_full_attribute(f, HIERARCHY_ATTRIBUTE))
                else {
                    println!(
                        "{}",
                        json!({"event":"hierarchy_skipped", "mode":flavor, "source":source, "reason":"focus_event_did_not_supply_full_attribute_metadata"})
                    );
                    continue;
                };
                metadata
            } else {
                attribute(HIERARCHY_ATTRIBUTE)
            };
            let raw = self
                .invoke_raw(
                    "deviceElement:valueForAttribute:",
                    vec![element(identifier), request_attribute],
                )
                .await?;
            let nodes = hierarchy_nodes(&raw);
            println!(
                "{}",
                json!({"event":"hierarchy", "mode":flavor, "source":source,
                "platform_identifier":hex(identifier), "node_count":nodes.len(),
                "complete_tree":false, "nodes":nodes, "raw":as_json(&raw)})
            );
        }
        Ok(())
    }

    async fn experiments(&mut self, args: &Args) -> Result<()> {
        for special in &args.special {
            let raw = self
                .invoke_raw(
                    "deviceFetchSpecialElement:",
                    vec![Value::Integer((*special).into())],
                )
                .await?;
            let id = identifier(&raw);
            println!(
                "{}",
                json!({"event":"special_element", "special":special,
                "platform_identifier":id.as_ref().map(|bytes| hex(bytes)), "raw":as_json(&raw)})
            );
            if let Some(mode) = args.hierarchy {
                if let Some(id) = id {
                    self.read_hierarchy(&id, Some(&raw), mode, json!({"special":special}))
                        .await?;
                } else {
                    println!(
                        "{}",
                        json!({"event":"hierarchy_skipped", "source":{"special":special}, "reason":"special_element_did_not_supply_identifier"})
                    );
                }
            }
        }
        if let Some(limit) = args.walk {
            self.walk(limit, &args.attributes, args.hierarchy).await?;
        }
        Ok(())
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    if !args.probe {
        println!("No device access. Use --help; --probe is required to connect.");
        return Ok(());
    }
    if args.attributes.len() > 32 {
        bail!("at most 32 attributes per element");
    }
    if args.hierarchy.is_some() && args.walk.is_none() && args.special.is_empty() {
        bail!(
            "--hierarchy requires --walk or --special; it never moves inspector focus implicitly"
        );
    }
    run(args).await
}

async fn run(args: Args) -> Result<()> {
    connection_phase("usbmux_connect");
    let mut mux = tokio::time::timeout(TIMEOUT, UsbmuxdAddr::default().connect(0))
        .await
        .context("usbmux connection timeout")?
        .context("usbmux connection")?;
    connection_phase("usb_enumeration");
    let candidates = tokio::time::timeout(TIMEOUT, mux.get_devices())
        .await
        .context("USB enumeration timeout")?
        .context("USB enumeration")?
        .into_iter()
        .filter(|d| d.connection_type == Connection::Usb)
        .filter(|d| args.udid.as_ref().is_none_or(|u| *u == d.udid))
        .collect::<Vec<_>>();
    if candidates.len() != 1 {
        bail!(
            "expected one USB device; found {} (use --udid)",
            candidates.len()
        );
    }
    let provider = candidates[0].to_provider(UsbmuxdAddr::default(), "TandemAXProbe");
    if !args.rsd {
        let remote = tokio::time::timeout(TIMEOUT, connect_usb(&provider))
            .await
            .context("USB AX connect timeout")??;
        return query(AxClient { remote, sent: 0 }, &args).await;
    }
    let proxy = tokio::time::timeout(TIMEOUT, CoreDeviceProxy::connect(&provider)).await??;
    let port = proxy.tunnel_info().server_rsd_port;
    let mut adapter = proxy.create_software_tunnel()?.to_async_handle();
    let stream = tokio::time::timeout(TIMEOUT, adapter.connect(port)).await??;
    let mut discovery = tokio::time::timeout(TIMEOUT, RsdHandshake::new(stream)).await??;
    let advertised = discovery
        .services
        .get(SERVICE)
        .context("native AX RSD service not advertised")?;
    println!(
        "{}",
        json!({"event":"service", "name":SERVICE, "port":advertised.port, "uses_remote_xpc":advertised.uses_remote_xpc, "capabilities_handshake":"skipped_for_AX"})
    );
    let AxTransport(remote) = tokio::time::timeout(
        TIMEOUT,
        AxTransport::connect_rsd(&mut adapter, &mut discovery),
    )
    .await??;
    // Keep the tunnel adapter alive through the last AX request.
    query(AxClient { remote, sent: 0 }, &args).await
}

async fn connect_usb(provider: &dyn IdeviceProvider) -> Result<Remote> {
    connection_phase("usbmux_read_pair_record");
    let pairing = provider
        .get_pairing_file()
        .await
        .context("read pairing record from OS usbmuxd")?;
    connection_phase("lockdown_connect");
    let mut lockdown = LockdownClient::connect(provider)
        .await
        .context("USB lockdown connection")?;
    connection_phase("lockdown_start_session_tls");
    lockdown
        .start_session(&pairing)
        .await
        .context("lockdown StartSession and session TLS handshake")?;
    connection_phase("lockdown_start_ax_service");
    let (port, ssl) = lockdown
        .start_service(USB_SERVICE)
        .await
        .context("lockdown StartService AX daemon")?;
    connection_phase("ax_service_usb_connect");
    let mut socket = provider
        .connect(port)
        .await
        .context("AX service USB port connection")?
        .get_socket()
        .context("missing USB service socket")?;
    if ssl {
        socket = strip_service_tls(socket, &pairing)
            .await
            .context("AX service TLS authentication and strip")?;
    }
    connection_phase("lockdown_socket_shutdown");
    lockdown
        .shutdown()
        .await
        .context("lockdown TLS socket shutdown after AX service connected")?;
    connection_phase("ax_dtx_client_start");
    println!(
        "{}",
        json!({"event":"service", "name":USB_SERVICE, "transport":"direct_usb", "service_ssl":ssl, "tls_mode":if ssl {"TLS1.2_auth_then_plain_DTX"} else {"none"}, "capabilities_handshake":"skipped_for_AX"})
    );
    Ok(Remote::with_label(socket, "TandemAXProbeUSB"))
}

async fn query(mut client: AxClient, args: &Args) -> Result<()> {
    for selector in ["deviceCapabilities", "deviceAccessibilitySettings"] {
        let value = client.invoke(selector, vec![]).await?;
        println!(
            "{}",
            json!({"event":"metadata", "selector":selector, "value":as_json(&value)})
        );
    }
    let result = tokio::select! {
        value = tokio::time::timeout(Duration::from_secs(100), async {
            if args.inspector_enable {
                client.send("deviceInspectorEnable:", vec![Value::Boolean(true)], false).await?;
            }
            client.experiments(args).await
        }) =>
            value.context("AX experiments exceeded 100 seconds").and_then(|value| value),
        signal = tokio::signal::ctrl_c() => signal.context("Ctrl-C handler failed").and(Err(anyhow!("probe interrupted"))),
    };
    // Outside the cancellable experiment future: timeouts and Ctrl-C still
    // attempt cleanup. These transient states are disabled, not restored to an
    // unknown prior state. Do not use alongside another Inspector client.
    let mut cleanup_error = None;
    let cleanup_needed = args.walk.is_some() || args.inspector_enable;
    for selector in if cleanup_needed {
        // Disabling Inspector alone does not clear the green cursor. Hide it
        // first; the daemon asynchronously resets its cursor frame to zero.
        &[
            "deviceInspectorShowVisuals:",
            "deviceSetAppMonitoringEnabled:",
            "deviceInspectorEnable:",
        ][..]
    } else {
        &[][..]
    } {
        let cleanup = client
            .send(selector, vec![Value::Boolean(false)], false)
            .await;
        println!(
            "{}",
            json!({"event":"cleanup", "selector":selector,
            "sent":cleanup.is_ok(), "verification":"transport_write_only",
            "error":cleanup.as_ref().err().map(ToString::to_string)})
        );
        if let Err(error) = cleanup {
            cleanup_error.get_or_insert(error);
        }
    }
    if cleanup_needed {
        // Keep the connection alive while the device's async hide-cursor work
        // can run. This allowance does not verify that the cursor disappeared.
        tokio::time::sleep(CLEANUP_GRACE).await;
        println!(
            "{}",
            json!({"event":"cleanup_grace", "waited_ms":CLEANUP_GRACE.as_millis(), "verification":"not_observed"})
        );
    }
    result.and(cleanup_error.map_or(Ok(()), Err))
}

#[cfg(test)]
mod tests {
    use super::*;
    use idevice::dvt::message::{Aux, MessageHeader, PayloadHeader};

    #[test]
    fn serializable_element_unboxes_without_losing_identifier() {
        let value = unbox(&element(&[0, 2, 0xff]));
        assert_eq!(
            value.as_dictionary().unwrap()["PlatformElementValue_v1"].as_data(),
            Some(&[0, 2, 0xff][..])
        );
        assert_eq!(
            as_json(&value)["PlatformElementValue_v1"]["data_hex"],
            "0002ff"
        );
    }

    #[test]
    fn focus_event_archive_and_header_are_decoded() {
        let payload = wrapped(
            "AXAuditInspectorFocus_v1",
            pass(dict([("ElementValue_v1", element(&[7, 8]))])),
        );
        let message = Message::new(
            MessageHeader::new(0, 1, 33, 1, 0, false),
            PayloadHeader::method_invocation(),
            Some(Aux::from_values(vec![AuxValue::archived_value(payload)])),
            Some(Value::String("hostInspectorCurrentElementChanged:".into())),
        );
        assert_eq!(header_u32(&message, 16), 33);
        assert_eq!(header_u32(&message, 20), 1);
        let value = unbox(&event_payload_raw(&message).unwrap());
        assert!(
            value
                .as_dictionary()
                .unwrap()
                .contains_key("ElementValue_v1")
        );
    }

    #[test]
    fn full_hierarchy_attribute_keeps_all_device_supplied_metadata() {
        let full = wrapped(
            "AXAuditElementAttribute_v1",
            pass(dict([
                (
                    "AttributeNameValue_v1",
                    pass(Value::String(HIERARCHY_ATTRIBUTE.into())),
                ),
                ("DisplayAsTree_v1", pass(Value::Boolean(true))),
                ("FutureMetadata_v9", pass(Value::Data(vec![1, 2, 3]))),
            ])),
        );
        let focus = wrapped(
            "AXAuditInspectorFocus_v1",
            pass(dict([(
                "InspectorSectionsValue_v1",
                pass(Value::Array(vec![wrapped(
                    "AXAuditInspectorSection_v1",
                    pass(dict([
                        (
                            "IdentifierValue_v1",
                            pass(Value::String("Hierarchy_v1".into())),
                        ),
                        (
                            "ElementAttributesValue_v1",
                            pass(Value::Array(vec![full.clone()])),
                        ),
                    ])),
                )])),
            )])),
        );
        assert_eq!(find_full_attribute(&focus, HIERARCHY_ATTRIBUTE), Some(full));
        assert!(find_full_attribute(&focus, "MissingAttribute").is_none());
    }

    #[test]
    fn hierarchy_preserves_real_parentage_unknown_fields_and_missing_children() {
        let child = wrapped(
            "AXAuditNode_v1",
            pass(dict([
                ("AuditElementValue_v1", element(&[3, 4])),
                (
                    "HumanReadableRoleDescriptionValue_v1",
                    pass(Value::String("button".into())),
                ),
                (
                    "FutureGeometry_v9",
                    pass(Value::String("unknown-format".into())),
                ),
            ])),
        );
        let parent = wrapped(
            "AXAuditNode_v1",
            pass(dict([
                ("AuditElementValue_v1", element(&[1, 2])),
                ("ChildrenValue_v1", pass(Value::Array(vec![child]))),
            ])),
        );
        let nodes = hierarchy_nodes(&parent);
        assert_eq!(nodes.len(), 2);
        assert_eq!(nodes[0]["platform_identifier"], "0102");
        assert!(nodes[0]["parent_path"].is_null());
        assert_eq!(nodes[0]["children_status"], "provided");
        assert_eq!(nodes[1]["parent_path"], "$");
        assert_eq!(nodes[1]["platform_identifier"], "0304");
        assert_eq!(nodes[1]["children_status"], "not_provided");
        assert_eq!(nodes[1]["fields"]["FutureGeometry_v9"], "unknown-format");
        assert!(nodes.iter().all(|node| node.get("bounds").is_none()));
        assert!(hierarchy_nodes(&Value::String("<null>".into())).is_empty());
    }

    #[tokio::test]
    async fn inspector_cleanup_hides_cursor_before_disabling_after_error() {
        use tokio::io::AsyncWriteExt;
        for explicit_enable in [true, false] {
            let args = if explicit_enable {
                Args::try_parse_from(["ax", "--probe", "--inspector-enable", "--special", "0"])
            } else {
                // A walk requests the same cleanup even without explicit enable.
                Args::try_parse_from(["ax", "--probe", "--walk", "1", "--special", "0"])
            }
            .unwrap();
            let (transport, mut peer) = tokio::io::duplex(16384);
            let client = AxClient {
                remote: Remote::new(transport),
                sent: 0,
            };
            let server = tokio::spawn(async move {
                for expected in ["deviceCapabilities", "deviceAccessibilitySettings"] {
                    let request = Message::from_reader(&mut peer).await.unwrap();
                    assert_eq!(
                        request.data.as_ref().and_then(Value::as_string),
                        Some(expected)
                    );
                    let response = Message::new(
                        MessageHeader::new(0, 1, header_u32(&request, 16), 1, 0, false),
                        PayloadHeader::method_invocation(),
                        None,
                        Some(Value::Array(vec![])),
                    );
                    let mut bytes = response.serialize();
                    bytes[32] = 3;
                    peer.write_all(&bytes).await.unwrap();
                }
                if explicit_enable {
                    let enable = Message::from_reader(&mut peer).await.unwrap();
                    assert_eq!(
                        enable.data.as_ref().and_then(Value::as_string),
                        Some("deviceInspectorEnable:")
                    );
                    assert_eq!(
                        aux_value(&enable.aux.unwrap().values[0])
                            .unwrap()
                            .as_boolean(),
                        Some(true)
                    );
                }
                let special = Message::from_reader(&mut peer).await.unwrap();
                assert_eq!(
                    special.data.as_ref().and_then(Value::as_string),
                    Some("deviceFetchSpecialElement:")
                );
                assert_eq!(
                    aux_value(&special.aux.as_ref().unwrap().values[0])
                        .unwrap()
                        .as_unsigned_integer(),
                    Some(0)
                );
                let response = Message::new(
                    MessageHeader::new(0, 1, header_u32(&special, 16), 1, 0, false),
                    PayloadHeader::method_invocation(),
                    None,
                    Some(Value::String("unavailable".into())),
                );
                let mut bytes = response.serialize();
                bytes[32] = 4;
                peer.write_all(&bytes).await.unwrap();
                for expected in [
                    "deviceInspectorShowVisuals:",
                    "deviceSetAppMonitoringEnabled:",
                    "deviceInspectorEnable:",
                ] {
                    let disable = Message::from_reader(&mut peer).await.unwrap();
                    assert_eq!(
                        disable.data.as_ref().and_then(Value::as_string),
                        Some(expected)
                    );
                    assert_eq!(
                        aux_value(&disable.aux.unwrap().values[0])
                            .unwrap()
                            .as_boolean(),
                        Some(false)
                    );
                }
                peer
            });
            let started = std::time::Instant::now();
            assert!(
                query(client, &args)
                    .await
                    .unwrap_err()
                    .to_string()
                    .contains("DTX error")
            );
            assert!(started.elapsed() >= CLEANUP_GRACE);
            server.await.unwrap();
        }
    }

    #[tokio::test]
    async fn metadata_reply_is_correlated_amid_events_and_stale_replies() {
        use tokio::io::AsyncWriteExt;
        let (transport, mut peer) = tokio::io::duplex(16384);
        let mut client = AxClient {
            remote: Remote::new(transport),
            sent: 0,
        };
        let server = tokio::spawn(async move {
            let request = Message::from_reader(&mut peer).await.unwrap();
            assert_eq!(
                request.data.as_ref().and_then(Value::as_string),
                Some("deviceCapabilities")
            );
            assert_eq!(header_u32(&request, 16), 1);
            assert!(request.aux.is_none());
            for (id, conversation, data) in [
                (99, 0, Value::String("hostEvent:".into())),
                (999, 1, Value::String("stale".into())),
                (1, 1, Value::Array(vec![Value::String("nativeAX".into())])),
            ] {
                let message = Message::new(
                    MessageHeader::new(0, 1, id, conversation, 0, false),
                    PayloadHeader::method_invocation(),
                    None,
                    Some(data),
                );
                let mut bytes = message.serialize();
                if conversation != 0 {
                    bytes[32] = 3;
                } // DTX OBJECT response
                peer.write_all(&bytes).await.unwrap();
            }
            peer // Keep the mock socket alive until the test consumes the reply.
        });
        let reply = client.invoke("deviceCapabilities", vec![]).await.unwrap();
        assert_eq!(reply.as_array().unwrap()[0].as_string(), Some("nativeAX"));
        server.await.unwrap();
    }
}
