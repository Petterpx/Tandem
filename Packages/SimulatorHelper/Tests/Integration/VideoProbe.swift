import UIKit

/// A disposable simulator fixture with a visible counter and changing background.
/// Set SIMCTL_CHILD_VIDEO_PROBE_ROTATE=1 on `simctl launch` to exercise rotations.
@main final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default", sessionRole: session.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = VideoProbeController()
        window.makeKeyAndVisible()
        self.window = window
    }
}

final class VideoProbeController: UIViewController {
    private var displayLink: CADisplayLink?
    private var frameNumber = 0
    private var scheduledRotations = false
    private let label = UILabel()
    private let square = UIView()
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        label.frame = CGRect(x: 20, y: 100, width: 380, height: 100)
        label.textColor = .white
        label.font = .monospacedSystemFont(ofSize: 30, weight: .bold)
        label.accessibilityIdentifier = "frame-counter"
        square.frame = CGRect(x: 0, y: 280, width: 100, height: 180)
        square.backgroundColor = .cyan
        view.addSubview(square)
        view.addSubview(label)
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !scheduledRotations, ProcessInfo.processInfo.environment["VIDEO_PROBE_ROTATE"] == "1" else { return }
        scheduledRotations = true
        let changes: [(Double, UIInterfaceOrientationMask)] = [
            (2, .landscapeLeft), (5, .portrait), (8, .landscapeRight), (11, .portrait),
        ]
        for (delay, orientation) in changes {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: orientation))
            }
        }
    }

    @objc private func tick(_ sender: CADisplayLink) {
        frameNumber += 1
        label.text = String(format: "frame %06d", frameNumber)
        square.frame.origin.x = CGFloat((frameNumber * 5) % 280)
        view.backgroundColor = UIColor(red: CGFloat(frameNumber % 120) / 120, green: 0.15, blue: 0.2, alpha: 1)
    }
}
