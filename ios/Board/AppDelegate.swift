import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // 현장에서 폰이 흔들려도 '실행 취소' 팝업이 뜨지 않게
        application.applicationSupportsShakeToEdit = false
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = BoardViewController()
        window?.makeKeyAndVisible()
        return true
    }
}
