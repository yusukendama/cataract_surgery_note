import Flutter
import UIKit

final class PrivacyShieldController {
  static let accessibilityIdentifier = "app-switcher-privacy-shield"

  private(set) weak var coveredWindow: UIWindow?
  private(set) var shieldView: UIView?

  var isInstalled: Bool {
    shieldView?.superview != nil
  }

  func install(on window: UIWindow?) {
    guard let window else { return }

    if let shieldView, shieldView.superview === window {
      window.bringSubviewToFront(shieldView)
      return
    }

    remove()
    let shield = UIView(frame: window.bounds)
    shield.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    shield.backgroundColor = UIColor(named: "LaunchBackground")
      ?? UIColor.systemBackground
    shield.isOpaque = true
    shield.isUserInteractionEnabled = true
    shield.accessibilityIdentifier = Self.accessibilityIdentifier
    window.addSubview(shield)
    window.bringSubviewToFront(shield)
    coveredWindow = window
    shieldView = shield
  }

  func remove() {
    shieldView?.removeFromSuperview()
    shieldView = nil
    coveredWindow = nil
  }
}

final class ProtectedDataEventStreamHandler: NSObject, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    events(UIApplication.shared.isProtectedDataAvailable)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  func publish(isAvailable: Bool) {
    eventSink?(isAvailable)
  }
}
