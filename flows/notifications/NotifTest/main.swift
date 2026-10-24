import UIKit
import UserNotifications

final class ViewController: UIViewController {
    let status = UILabel()
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let title = UILabel()
        title.text = "Notification test"
        status.text = "Asking"
        status.accessibilityIdentifier = "status"
        let ask = UIButton(type: .system)
        ask.setTitle("Ask again", for: .normal)
        ask.addTarget(self, action: #selector(askTapped), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [title, status, ask])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                                     stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        askTapped()
    }
    @objc func askTapped() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async { self.status.text = granted ? "Granted" : "Denied" }
        }
    }
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = ViewController()
        window?.makeKeyAndVisible()
        return true
    }
}
