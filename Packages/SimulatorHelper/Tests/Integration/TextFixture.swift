import UIKit
import WebKit

@main class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default", sessionRole: session.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

class SceneDelegate: UIResponder, UIWindowSceneDelegate, UITextViewDelegate, UITextFieldDelegate, WKScriptMessageHandler {
    var window: UIWindow?
    var token = ""
    var web: WKWebView!
    var webMode = false
    var inputEvents = 0
    var rejectEdits = false
    let editor = UITextView(frame: CGRect(x: 20, y: 100, width: 350, height: 300))
    let field = UITextField(frame: CGRect(x: 20, y: 100, width: 350, height: 60))
    var active: UIView { field.isHidden ? editor : field }
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        controller.view.backgroundColor = .white
        editor.font = .systemFont(ofSize: 24)
        editor.delegate = self
        field.font = .systemFont(ofSize: 24)
        field.delegate = self
        field.addTarget(self, action: #selector(changed), for: .editingChanged)
        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.userContentController.add(self, name: "state")
        web = WKWebView(frame: CGRect(x: 20, y: 100, width: 350, height: 350), configuration: webConfiguration)
        controller.view.addSubview(web)
        controller.view.addSubview(editor)
        controller.view.addSubview(field)
        self.window = window
        window.rootViewController = controller
        window.makeKeyAndVisible()
        reset(options.urlContexts.first?.url ?? ProcessInfo.processInfo.arguments.dropFirst().last.flatMap(URL.init(string:)))
    }
    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) { reset(contexts.first?.url) }
    func reset(_ url: URL?) {
        let items = URLComponents(url: url ?? URL(string: "textfixture://reset")!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func argument(_ name: String) -> String? { items.first { $0.name == name }?.value }
        token = argument("token") ?? ""
        let text = argument("text") ?? ""
        webMode = argument("kind") == "web"
        web.isHidden = !webMode
        rejectEdits = argument("kind") == "reject"
        let isField = argument("kind") == "field" || argument("kind") == "secure" || rejectEdits
        editor.isHidden = isField || webMode
        field.isHidden = !isField || webMode
        field.isSecureTextEntry = argument("kind") == "secure"
        editor.text = text
        field.text = text
        if webMode {
            let encoded = String(data: try! JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed), encoding: .utf8)!
            let location = Int(argument("location") ?? "") ?? text.utf16.count
            let length = Int(argument("length") ?? "") ?? 0
            web.loadHTMLString("""
            <meta name="viewport" content="width=device-width,initial-scale=1"><textarea id="editor" style="width:100%;height:250px;font-size:24px"></textarea>
            <script>const editor=document.getElementById('editor');editor.value=\(encoded);editor.setSelectionRange(\(location),\(location+length));let count=0;
            function report(){webkit.messageHandlers.state.postMessage({text:editor.value,inputEvents:count});}
            editor.addEventListener('input',()=>{count++;report();});report();</script>
            """, baseURL: nil)
            return
        }
        active.becomeFirstResponder()
        let location = Int(argument("location") ?? "") ?? text.utf16.count
        let length = Int(argument("length") ?? "") ?? 0
        if isField, let start = field.position(from: field.beginningOfDocument, offset: location),
           let end = field.position(from: start, offset: length) { field.selectedTextRange = field.textRange(from: start, to: end) }
        else { editor.selectedRange = NSRange(location: location, length: length) }
        changed()
    }
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool { !rejectEdits }
    func textViewDidChange(_ textView: UITextView) { changed() }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let value = message.body as? [String: Any], let text = value["text"] as? String else { return }
        inputEvents = value["inputEvents"] as? Int ?? 0
        save(text)
    }
    func save(_ text: String) {
        let data = try! JSONSerialization.data(withJSONObject: ["text": text, "token": token, "inputEvents": inputEvents, "uptime": ProcessInfo.processInfo.systemUptime])
        try! data.write(to: URL.documentsDirectory.appending(path: "state.json"), options: .atomic)
    }
    @objc func changed() {
        let text = field.isHidden ? editor.text! : field.text!
        save(text)
    }
}
