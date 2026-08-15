import Flutter
import UIKit

enum BackupExclusionAttribute {
  static func applyAndVerify(path: String) throws {
    var url = URL(fileURLWithPath: path)
    var resourceValues = URLResourceValues()
    resourceValues.isExcludedFromBackup = true
    try url.setResourceValues(resourceValues)
    let verifiedValues = try url.resourceValues(
      forKeys: [.isExcludedFromBackupKey]
    )
    guard verifiedValues.isExcludedFromBackup == true else {
      throw NSError(
        domain: "cataract_surgery_note.backup",
        code: 1,
        userInfo: [
          NSLocalizedDescriptionKey: "Backup exclusion could not be verified."
        ]
      )
    }
  }
}

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
        do {
          try BackupExclusionAttribute.applyAndVerify(path: path)
          result(true)
        } catch {
          result(
            FlutterError(
              code: "backup_exclusion_failed",
              message: error.localizedDescription,
              details: nil
            )
          )
        }
      }
    }
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
