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

final class VideoSourceAccessManager {
  private struct Lease {
    let url: URL
    let startedSecurityScope: Bool
  }

  private var leases: [String: Lease] = [:]
  private let protectedDataAvailable: () -> Bool

  init(
    protectedDataAvailable: @escaping () -> Bool = {
      UIApplication.shared.isProtectedDataAvailable
    }
  ) {
    self.protectedDataAvailable = protectedDataAvailable
  }

  var activeLeaseCount: Int {
    leases.count
  }

  func acquire(path: String) throws -> [String: String] {
    guard protectedDataAvailable() else {
      throw SourceAccessError.protectedDataUnavailable
    }
    guard !path.isEmpty else {
      throw SourceAccessError.invalidPath
    }
    let url = URL(fileURLWithPath: path).standardizedFileURL
    let startedSecurityScope = url.startAccessingSecurityScopedResource()
    guard FileManager.default.fileExists(atPath: url.path) else {
      if startedSecurityScope {
        url.stopAccessingSecurityScopedResource()
      }
      throw SourceAccessError.sourceNotFound
    }
    guard FileManager.default.isReadableFile(atPath: url.path) else {
      if startedSecurityScope {
        url.stopAccessingSecurityScopedResource()
      }
      throw SourceAccessError.accessDenied
    }
    guard protectedDataAvailable() else {
      if startedSecurityScope {
        url.stopAccessingSecurityScopedResource()
      }
      throw SourceAccessError.protectedDataUnavailable
    }

    let token = UUID().uuidString
    leases[token] = Lease(
      url: url,
      startedSecurityScope: startedSecurityScope
    )
    var response = ["token": token]
    if let identifier = try? url.resourceValues(
      forKeys: [.fileResourceIdentifierKey]
    ).fileResourceIdentifier {
      response["identifier"] = String(describing: identifier)
    }
    return response
  }

  func release(token: String) {
    guard let lease = leases.removeValue(forKey: token) else { return }
    if lease.startedSecurityScope {
      lease.url.stopAccessingSecurityScopedResource()
    }
  }

  func releaseAll() {
    let activeLeases = Array(leases.values)
    leases.removeAll()
    for lease in activeLeases where lease.startedSecurityScope {
      lease.url.stopAccessingSecurityScopedResource()
    }
  }

  deinit {
    releaseAll()
  }

  enum SourceAccessError: Error {
    case protectedDataUnavailable
    case invalidPath
    case sourceNotFound
    case accessDenied
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate {
  let protectedStorageManager = ProtectedStorageManager()
  let privacyShieldController = PrivacyShieldController()
  let protectedDataEventStreamHandler = ProtectedDataEventStreamHandler()
  private let analysisTimeEventStreamHandler = AnalysisTimeEventStreamHandler()
  private let videoSourceAccessManager = VideoSourceAccessManager()

  private var backupChannel: FlutterMethodChannel?
  private var protectedStorageChannel: FlutterMethodChannel?
  private var protectedDataEventChannel: FlutterEventChannel?
  private var videoSourceAccessChannel: FlutterMethodChannel?
  private var analysisTimeMethodChannel: FlutterMethodChannel?
  private var analysisTimeEventChannel: FlutterEventChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let registrar = registrar(forPlugin: "ProtectedStoragePlugin") {
      let messenger = registrar.messenger()
      configureBackupChannel(binaryMessenger: messenger)
      configureProtectedStorageChannels(binaryMessenger: messenger)
      configureVideoSourceAccessChannel(binaryMessenger: messenger)
      configureAnalysisTimeChannels(binaryMessenger: messenger)
    }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(protectedDataWillBecomeUnavailable),
      name: UIApplication.protectedDataWillBecomeUnavailableNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(protectedDataDidBecomeAvailable),
      name: UIApplication.protectedDataDidBecomeAvailableNotification,
      object: nil
    )
    if application.applicationState != .active
      || !application.isProtectedDataAvailable {
      privacyShieldController.install(on: window)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func configureAnalysisTimeChannels(
    binaryMessenger: FlutterBinaryMessenger
  ) {
    let methodChannel = FlutterMethodChannel(
      name: "cataract_surgery_note/analysis_time_context",
      binaryMessenger: binaryMessenger
    )
    methodChannel.setMethodCallHandler { call, result in
      guard call.method == "timezoneIdentifier" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(TimeZone.autoupdatingCurrent.identifier)
    }
    analysisTimeMethodChannel = methodChannel

    let eventChannel = FlutterEventChannel(
      name: "cataract_surgery_note/analysis_time_events",
      binaryMessenger: binaryMessenger
    )
    eventChannel.setStreamHandler(analysisTimeEventStreamHandler)
    analysisTimeEventChannel = eventChannel
  }

  private func configureVideoSourceAccessChannel(
    binaryMessenger: FlutterBinaryMessenger
  ) {
    let channel = FlutterMethodChannel(
      name: "cataract_surgery_note/source_access",
      binaryMessenger: binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "provider_unavailable", message: nil, details: nil))
        return
      }
      guard let arguments = call.arguments as? [String: Any] else {
        result(FlutterError(code: "invalid_arguments", message: nil, details: nil))
        return
      }
      switch call.method {
      case "acquire":
        guard let path = arguments["path"] as? String else {
          result(FlutterError(code: "invalid_arguments", message: nil, details: nil))
          return
        }
        do {
          result(try self.videoSourceAccessManager.acquire(path: path))
        } catch VideoSourceAccessManager.SourceAccessError.protectedDataUnavailable {
          result(
            FlutterError(
              code: "protected_data_unavailable",
              message: nil,
              details: nil
            )
          )
        } catch VideoSourceAccessManager.SourceAccessError.sourceNotFound {
          result(FlutterError(code: "source_not_found", message: nil, details: nil))
        } catch VideoSourceAccessManager.SourceAccessError.accessDenied {
          result(FlutterError(code: "source_access_denied", message: nil, details: nil))
        } catch {
          result(FlutterError(code: "provider_unavailable", message: nil, details: nil))
        }
      case "release":
        guard let token = arguments["token"] as? String else {
          result(FlutterError(code: "invalid_arguments", message: nil, details: nil))
          return
        }
        self.videoSourceAccessManager.release(token: token)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    videoSourceAccessChannel = channel
  }

  override func applicationWillResignActive(_ application: UIApplication) {
    privacyShieldController.install(on: window)
    super.applicationWillResignActive(application)
  }

  override func applicationDidEnterBackground(_ application: UIApplication) {
    privacyShieldController.install(on: window)
    super.applicationDidEnterBackground(application)
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    if application.isProtectedDataAvailable {
      privacyShieldController.remove()
    } else {
      privacyShieldController.install(on: window)
    }
  }

  private func configureBackupChannel(binaryMessenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
        name: "cataract_surgery_note/backup",
        binaryMessenger: binaryMessenger
      )
    channel.setMethodCallHandler { call, result in
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
        try self.protectedStorageManager
          .applyAndVerifyBackupExclusionForManagedPath(path)
        result(true)
      } catch {
        result(
          FlutterError(
            code: "backup_exclusion_failed",
            message: "バックアップ除外属性を確認できませんでした。",
            details: nil
          )
        )
      }
    }
    backupChannel = channel
  }

  private func configureProtectedStorageChannels(
    binaryMessenger: FlutterBinaryMessenger
  ) {
    let methodChannel = FlutterMethodChannel(
      name: "cataract_surgery_note/protected_storage",
      binaryMessenger: binaryMessenger
    )
    methodChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(
          FlutterError(
            code: "file_protection_failed",
            message: "保存領域の保護属性を確認できませんでした。",
            details: nil
          )
        )
        return
      }
      self.handleProtectedStorageCall(call, result: result)
    }
    protectedStorageChannel = methodChannel

    let eventChannel = FlutterEventChannel(
      name: "cataract_surgery_note/protected_data_events",
      binaryMessenger: binaryMessenger
    )
    eventChannel.setStreamHandler(protectedDataEventStreamHandler)
    protectedDataEventChannel = eventChannel
  }

  private func handleProtectedStorageCall(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    do {
      switch call.method {
      case "isProtectedDataAvailable":
        result(protectedStorageManager.isProtectedDataAvailable)
      case "prepareAppStorage":
        let paths = try protectedStorageManager.prepareAppStorage()
        result([
          "applicationSupportPath": paths.applicationSupportPath,
          "databasePath": paths.databasePath,
        ])
      case "protectDirectoryAndVerify":
        let path = try requiredPath(from: call)
        try protectedStorageManager.protectDirectoryAndVerify(path: path)
        result(true)
      case "protectFileAndVerify":
        let arguments = try requiredArguments(from: call)
        guard
          let path = arguments["path"] as? String,
          let excludeFromBackup = arguments["excludeFromBackup"] as? Bool
        else {
          throw ProtectedStorageError.invalidPath
        }
        try protectedStorageManager.protectFileAndVerify(
          path: path,
          excludeFromBackup: excludeFromBackup
        )
        result(true)
      case "verifyDatabaseFiles":
        try protectedStorageManager.verifyDatabaseFiles()
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    } catch let error as StagedProtectedStorageError {
      result(flutterError(for: error))
    } catch let error as ProtectedStorageError {
      result(flutterError(for: error))
    } catch {
      result(flutterError(for: .fileProtectionFailed))
    }
  }

  private func requiredPath(from call: FlutterMethodCall) throws -> String {
    let arguments = try requiredArguments(from: call)
    guard let path = arguments["path"] as? String, !path.isEmpty else {
      throw ProtectedStorageError.invalidPath
    }
    return path
  }

  private func requiredArguments(
    from call: FlutterMethodCall
  ) throws -> [String: Any] {
    guard let arguments = call.arguments as? [String: Any] else {
      throw ProtectedStorageError.invalidPath
    }
    return arguments
  }

  private func flutterError(for error: ProtectedStorageError) -> FlutterError {
    flutterError(for: error, details: nil)
  }

  private func flutterError(for error: StagedProtectedStorageError) -> FlutterError {
    flutterError(for: error.error, details: error.stage.rawValue)
  }

  private func flutterError(
    for error: ProtectedStorageError,
    details: String?
  ) -> FlutterError {
    switch error {
    case .protectedDataUnavailable:
      return FlutterError(
        code: "protected_data_unavailable",
        message: "端末のロックを解除して、もう一度お試しください。",
        details: details
      )
    case .backupExclusionFailed:
      return FlutterError(
        code: "backup_exclusion_failed",
        message: "バックアップ除外属性を確認できませんでした。",
        details: details
      )
    case .invalidPath, .unexpectedItem, .fileProtectionFailed:
      return FlutterError(
        code: "file_protection_failed",
        message: "保存領域の保護属性を確認できませんでした。",
        details: details
      )
    }
  }

  @objc private func protectedDataWillBecomeUnavailable(
    _ notification: Notification
  ) {
    privacyShieldController.install(on: window)
    videoSourceAccessManager.releaseAll()
    protectedDataEventStreamHandler.publish(isAvailable: false)
  }

  @objc private func protectedDataDidBecomeAvailable(
    _ notification: Notification
  ) {
    protectedDataEventStreamHandler.publish(isAvailable: true)
  }
}
