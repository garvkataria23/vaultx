import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var privacyView: UIView?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationWillResignActive(_ application: UIApplication) {
    // Add an opaque view over the Flutter view so the iOS task switcher
    // snapshot shows nothing. iOS captures the snapshot immediately after
    // applicationWillResignActive returns, so this must be synchronous.
    if privacyView == nil, let window = window {
      let shield = UIView(frame: window.bounds)
      shield.backgroundColor = UIColor.systemBackground
      shield.tag = 0xDEAD  // arbitrary marker tag
      shield.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      window.addSubview(shield)
      window.bringSubviewToFront(shield)
      privacyView = shield
    }
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    // Remove the privacy shield so the user sees the app content again.
    privacyView?.removeFromSuperview()
    privacyView = nil
  }
}
