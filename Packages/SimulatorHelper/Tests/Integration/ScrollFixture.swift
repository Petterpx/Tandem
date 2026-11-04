import UIKit

// Test-only instrumentation: actual guest UIKit delivery, not host ACK/video inference.
final class ProbeApplication: UIApplication {
    override func sendEvent(_ event: UIEvent) {
        for touch in event.allTouches ?? [] {
            let phase: String
            switch touch.phase {
            case .began: phase = "began"
            case .moved: phase = "moved"
            case .ended: phase = "ended"
            case .cancelled: phase = "cancelled"
            default: continue
            }
            let point = touch.location(in: touch.window)
            Probe.shared.record("touch", ["phase": phase, "eventTimestamp": touch.timestamp,
                                           "x": point.x, "y": point.y])
        }
        super.sendEvent(event)
    }
}

final class Probe {
    static let shared = Probe()
    var events: [[String: Any]] = []
    var droppedEvents = 0
    var saving = false
    var lastSaveMilliseconds = 0.0
    var maximumSaveMilliseconds = 0.0
    var active = false
    var activeFrames = 0
    var ready = false
    let writer = DispatchQueue(label: "local.tandem.scroll-fixture.evidence", qos: .utility)
    weak var controller: ScrollController?
    func record(_ kind: String, _ values: [String: Any] = [:]) {
        var row = values
        row["kind"] = kind
        row["uptime"] = ProcessInfo.processInfo.systemUptime
        events.append(row)
        if events.count > 4096 {
            events.removeFirst(1024)
            droppedEvents += 1024
        }
    }
    func save() {
        guard let controller, !saving else { return }
        let button = controller.button.convert(controller.button.bounds, to: controller.view)
        let size = controller.view.bounds.size
        let state: [String: Any] = ["uptime": ProcessInfo.processInfo.systemUptime,
            "events": events, "droppedEvents": droppedEvents,
            "saveLastMilliseconds": lastSaveMilliseconds, "saveMaxMilliseconds": maximumSaveMilliseconds,
            "offset": controller.table.contentOffset.y,
            "dragging": controller.table.isDragging, "decelerating": controller.table.isDecelerating,
            "panState": controller.table.panGestureRecognizer.state.rawValue,
            "buttonTaps": controller.buttonTaps,
            "buttonX": button.midX / size.width, "buttonY": button.midY / size.height]
        saving = true
        writer.async {
            let start = ProcessInfo.processInfo.systemUptime
            if let data = try? JSONSerialization.data(withJSONObject: state) {
                try? data.write(to: URL.documentsDirectory.appending(path: "scroll-state.json"), options: .atomic)
            }
            let duration = (ProcessInfo.processInfo.systemUptime - start) * 1000
            DispatchQueue.main.async {
                self.lastSaveMilliseconds = duration
                self.maximumSaveMilliseconds = max(self.maximumSaveMilliseconds, duration)
                self.saving = false
            }
        }
    }
}

final class ScrollController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    let table = UITableView(frame: .zero, style: .plain)
    let button = UIButton(type: .system)
    var buttonTaps = 0
    var displayLink: CADisplayLink?
    var saveTimer: Timer?
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        button.setTitle("Recovery button: 0", for: .normal)
        button.addTarget(self, action: #selector(tapped), for: .touchUpInside)
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 60
        table.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        table.panGestureRecognizer.addTarget(self, action: #selector(panChanged))
        for subview in [button, table] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            button.heightAnchor.constraint(equalToConstant: 48),
            table.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 8),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor)])
        Probe.shared.controller = self
        let link = CADisplayLink(target: self, selector: #selector(frame))
        link.add(to: .main, forMode: .common)
        displayLink = link
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in Probe.shared.save() }
        RunLoop.main.add(timer, forMode: .common)
        saveTimer = timer
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1000 }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        cell.textLabel?.text = "Native scroll row \(indexPath.row)"
        cell.backgroundColor = indexPath.row.isMultiple(of: 2) ? .systemGray6 : .systemBackground
        return cell
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { recordScroll("dragBegin") }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        recordScroll("dragEnd", ["willDecelerate": decelerate])
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { recordScroll("decelerationEnd") }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { recordScroll("scroll") }
    func recordScroll(_ kind: String, _ extra: [String: Any] = [:]) {
        var values = extra
        values["offset"] = table.contentOffset.y
        values["dragging"] = table.isDragging
        values["decelerating"] = table.isDecelerating
        values["panState"] = table.panGestureRecognizer.state.rawValue
        Probe.shared.record(kind, values)
    }
    @objc func panChanged() { recordScroll("pan") }
    @objc func frame() {
        recordScroll("frame")
        let probe = Probe.shared
        if probe.active, !probe.ready {
            probe.activeFrames += 1
            if probe.activeFrames >= 3 {
                probe.ready = true
                probe.record("ready")
                probe.save()
            }
        }
    }
    @objc func tapped() {
        buttonTaps += 1
        button.setTitle("Recovery button: \(buttonTaps)", for: .normal)
        Probe.shared.record("button", ["count": buttonTaps])
        Probe.shared.save()
    }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default", sessionRole: session.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func sceneDidBecomeActive(_ scene: UIScene) {
        Probe.shared.active = true
        Probe.shared.activeFrames = 0
    }
    func sceneWillResignActive(_ scene: UIScene) {
        Probe.shared.active = false
        Probe.shared.activeFrames = 0
    }
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = ScrollController()
        self.window = window
        window.makeKeyAndVisible()
    }
}

@main enum Entry {
    static func main() { UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, NSStringFromClass(ProbeApplication.self), NSStringFromClass(AppDelegate.self)) }
}
