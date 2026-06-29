import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if let controller = window?.rootViewController as? FlutterViewController {
      let backupChannel = FlutterMethodChannel(
        name: "cataract_surgery_note/backup",
        binaryMessenger: controller.binaryMessenger
      )
      backupChannel.setMethodCallHandler { call, result in
        guard call.method == "excludeFromBackup" else {
          result(FlutterMethodNotImplemented)
          return
        }
        guard
          let arguments = call.arguments as? [String: Any],
          let path = arguments["path"] as? String
        else {
          result(FlutterError(code: "invalid_arguments", message: nil, details: nil))
          return
        }

        var url = URL(fileURLWithPath: path)
        do {
          var resourceValues = URLResourceValues()
          resourceValues.isExcludedFromBackup = true
          try url.setResourceValues(resourceValues)
          result(nil)
        } catch {
          result(FlutterError(code: "backup_exclusion_failed", message: nil, details: nil))
        }
      }
    }
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
