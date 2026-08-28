import Flutter
import SQLite3
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  func testLaunchBackgroundContainsRequiredLightAndDarkColors() throws {
    let dynamicColor = try XCTUnwrap(
      UIColor(named: "LaunchBackground", in: .main, compatibleWith: nil)
    )
    let light = dynamicColor.resolvedColor(
      with: UITraitCollection(userInterfaceStyle: .light)
    )
    let dark = dynamicColor.resolvedColor(
      with: UITraitCollection(userInterfaceStyle: .dark)
    )

    assertColor(light, red: 0, green: 109, blue: 119)
    assertColor(dark, red: 0, green: 63, blue: 69)
  }

  func testJapaneseLocalizationIsBundled() {
    XCTAssertNotNil(Bundle.main.path(forResource: "ja", ofType: "lproj"))
  }

  func testBackupExclusionIsReadBackForDirectoryAndFinalFile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "backup-exclusion-\(UUID().uuidString)",
      isDirectory: true
    )
    let finalFile = root.appendingPathComponent("managed.mp4")
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false
    )
    XCTAssertTrue(
      FileManager.default.createFile(
        atPath: finalFile.path,
        contents: Data([0x00, 0x01, 0x02])
      )
    )

    try BackupExclusionAttribute.applyAndVerify(path: root.path)
    try BackupExclusionAttribute.applyAndVerify(path: finalFile.path)

    let rootValues = try root.resourceValues(
      forKeys: [.isExcludedFromBackupKey]
    )
    let fileValues = try finalFile.resourceValues(
      forKeys: [.isExcludedFromBackupKey]
    )
    XCTAssertEqual(rootValues.isExcludedFromBackup, true)
    XCTAssertEqual(fileValues.isExcludedFromBackup, true)
  }

  func testProtectedStorageBootstrapAppliesCompleteProtectionToDatabase() throws {
    let fixture = try makeProtectedStorageFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let paths = try fixture.manager.prepareAppStorage()

    XCTAssertEqual(paths.applicationSupportPath, fixture.support.path)
    XCTAssertEqual(paths.databasePath, fixture.manager.databaseURL.path)
    try assertCompleteProtection(fixture.documents)
    try assertCompleteProtection(fixture.manager.databaseURL)
    try assertExcludedFromBackup(fixture.manager.databaseURL)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: fixture.manager.videosURL.path)
    )
  }

  func testProtectedStorageBootstrapRepairsExistingDatabaseAndSidecars() throws {
    let fixture = try makeProtectedStorageFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try FileManager.default.createDirectory(
      at: fixture.documents,
      withIntermediateDirectories: true
    )
    XCTAssertTrue(
      FileManager.default.createFile(
        atPath: fixture.manager.databaseURL.path,
        contents: Data()
      )
    )
    let wal = URL(fileURLWithPath: fixture.manager.databaseURL.path + "-wal")
    let shm = URL(fileURLWithPath: fixture.manager.databaseURL.path + "-shm")
    let journal = URL(fileURLWithPath: fixture.manager.databaseURL.path + "-journal")
    for sidecar in [wal, shm, journal] {
      XCTAssertTrue(
        FileManager.default.createFile(atPath: sidecar.path, contents: Data())
      )
    }
    for url in [fixture.manager.databaseURL, wal, shm, journal] {
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.none],
        ofItemAtPath: url.path
      )
    }

    _ = try fixture.manager.prepareAppStorage()

    for url in [fixture.manager.databaseURL, wal, shm, journal] {
      try assertCompleteProtection(url)
      try assertExcludedFromBackup(url)
    }
  }

  func testVideoTreeFailureDoesNotBlockProtectedDatabaseBootstrap() throws {
    let fixture = try makeProtectedStorageFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try FileManager.default.createDirectory(
      at: fixture.manager.videosURL,
      withIntermediateDirectories: true
    )
    let unexpected = fixture.manager.videosURL.appendingPathComponent(
      "unexpected-root-file.mp4"
    )
    XCTAssertTrue(
      FileManager.default.createFile(
        atPath: unexpected.path,
        contents: Data([0x00, 0x01])
      )
    )

    let paths = try fixture.manager.prepareAppStorage()

    XCTAssertEqual(paths.databasePath, fixture.manager.databaseURL.path)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: fixture.manager.databaseURL.path)
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: unexpected.path))
  }

  func testProtectedStorageDoesNotStartWhenProtectedDataIsUnavailable() throws {
    let fixture = try makeProtectedStorageFixture(isAvailable: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    XCTAssertThrowsError(try fixture.manager.prepareAppStorage()) { error in
      guard case ProtectedStorageError.protectedDataUnavailable = error else {
        return XCTFail("Expected protectedDataUnavailable")
      }
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.support.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.documents.path))
  }

  func testVideoSourceAccessRejectsUnavailableDataAndReleasesAllLeases() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "source-access-\(UUID().uuidString)",
      isDirectory: true
    )
    let source = root.appendingPathComponent("source.mp4")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false
    )
    XCTAssertTrue(
      FileManager.default.createFile(
        atPath: source.path,
        contents: Data([0x00, 0x01])
      )
    )
    var isAvailable = true
    let manager = VideoSourceAccessManager(
      protectedDataAvailable: { isAvailable }
    )

    let lease = try manager.acquire(path: source.path)
    let token = try XCTUnwrap(lease["token"])
    XCTAssertEqual(manager.activeLeaseCount, 1)

    isAvailable = false
    manager.releaseAll()
    XCTAssertEqual(manager.activeLeaseCount, 0)
    manager.release(token: token)
    XCTAssertEqual(manager.activeLeaseCount, 0)

    XCTAssertThrowsError(try manager.acquire(path: source.path)) { error in
      guard case VideoSourceAccessManager.SourceAccessError.protectedDataUnavailable = error else {
        return XCTFail("Expected protectedDataUnavailable")
      }
    }
    XCTAssertEqual(manager.activeLeaseCount, 0)

    var availabilityChecks = 0
    let interruptedManager = VideoSourceAccessManager(
      protectedDataAvailable: {
        availabilityChecks += 1
        return availabilityChecks == 1
      }
    )
    XCTAssertThrowsError(
      try interruptedManager.acquire(path: source.path)
    ) { error in
      guard case VideoSourceAccessManager.SourceAccessError.protectedDataUnavailable = error else {
        return XCTFail("Expected interrupted protectedDataUnavailable")
      }
    }
    XCTAssertEqual(availabilityChecks, 2)
    XCTAssertEqual(interruptedManager.activeLeaseCount, 0)
  }

  func testProtectedStorageRejectsPathsOutsideManagedVideos() throws {
    let fixture = try makeProtectedStorageFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try fixture.manager.prepareAppStorage()
    let outside = fixture.root.appendingPathComponent("outside.mp4")
    XCTAssertTrue(
      FileManager.default.createFile(
        atPath: outside.path,
        contents: Data()
      )
    )

    XCTAssertThrowsError(
      try fixture.manager.protectFileAndVerify(
        path: outside.path,
        excludeFromBackup: true
      )
    )
  }

  func testDatabaseFamilyRemainsCompleteAcrossWalCheckpointAndReopen() throws {
    let fixture = try makeProtectedStorageFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try fixture.manager.prepareAppStorage()

    var database: OpaquePointer?
    defer {
      if let database {
        sqlite3_close(database)
      }
    }
    database = try openDatabase(at: fixture.manager.databaseURL)
    try execute(
      "PRAGMA journal_mode=WAL; CREATE TABLE protected_test(value INTEGER); "
        + "INSERT INTO protected_test(value) VALUES (1);",
      on: database
    )
    let wal = URL(fileURLWithPath: fixture.manager.databaseURL.path + "-wal")
    let shm = URL(fileURLWithPath: fixture.manager.databaseURL.path + "-shm")
    for sidecar in [wal, shm]
    where FileManager.default.fileExists(atPath: sidecar.path) {
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.none],
        ofItemAtPath: sidecar.path
      )
    }
    try fixture.manager.verifyDatabaseFiles()
    try assertExcludedFromBackup(fixture.manager.databaseURL)
    for sidecar in [wal, shm]
    where FileManager.default.fileExists(atPath: sidecar.path) {
      try assertCompleteProtection(sidecar)
      try assertExcludedFromBackup(sidecar)
    }

    var logFrames = Int32()
    var checkpointedFrames = Int32()
    XCTAssertEqual(
      sqlite3_wal_checkpoint_v2(
        database,
        nil,
        SQLITE_CHECKPOINT_TRUNCATE,
        &logFrames,
        &checkpointedFrames
      ),
      SQLITE_OK
    )
    try fixture.manager.verifyDatabaseFiles()
    try assertExcludedFromBackup(fixture.manager.databaseURL)
    XCTAssertEqual(sqlite3_close(database), SQLITE_OK)
    database = nil

    database = try openDatabase(at: fixture.manager.databaseURL)
    try execute(
      "PRAGMA journal_mode=WAL; INSERT INTO protected_test(value) VALUES (2);",
      on: database
    )
    try fixture.manager.verifyDatabaseFiles()
    try assertExcludedFromBackup(fixture.manager.databaseURL)
    for sidecar in [wal, shm]
    where FileManager.default.fileExists(atPath: sidecar.path) {
      try assertExcludedFromBackup(sidecar)
    }
    XCTAssertEqual(sqlite3_close(database), SQLITE_OK)
    database = nil
  }

  func testPrivacyShieldIsOpaqueTopmostAndIdempotent() throws {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
    let content = UIView(frame: window.bounds)
    window.addSubview(content)
    let controller = PrivacyShieldController()

    controller.install(on: window)
    controller.install(on: window)

    let shield = try XCTUnwrap(controller.shieldView)
    XCTAssertTrue(controller.isInstalled)
    XCTAssertTrue(window.subviews.last === shield)
    XCTAssertTrue(shield.isOpaque)
    XCTAssertEqual(shield.alpha, 1)
    XCTAssertEqual(
      shield.accessibilityIdentifier,
      PrivacyShieldController.accessibilityIdentifier
    )
    XCTAssertEqual(
      window.subviews.filter {
        $0.accessibilityIdentifier
          == PrivacyShieldController.accessibilityIdentifier
      }.count,
      1
    )

    controller.remove()
    XCTAssertFalse(controller.isInstalled)
    XCTAssertNil(shield.superview)
  }

  func testSceneManifestUsesRunnerSceneDelegate() throws {
    let manifest = try XCTUnwrap(
      Bundle.main.object(
        forInfoDictionaryKey: "UIApplicationSceneManifest"
      ) as? [String: Any]
    )
    XCTAssertEqual(
      manifest["UIApplicationSupportsMultipleScenes"] as? Bool,
      false
    )
    let configurations = try XCTUnwrap(
      manifest["UISceneConfigurations"] as? [String: Any]
    )
    let applicationConfigurations = try XCTUnwrap(
      configurations["UIWindowSceneSessionRoleApplication"]
        as? [[String: Any]]
    )
    let configuration = try XCTUnwrap(applicationConfigurations.first)

    XCTAssertEqual(
      configuration["UISceneClassName"] as? String,
      "UIWindowScene"
    )
    XCTAssertEqual(
      configuration["UISceneConfigurationName"] as? String,
      "flutter"
    )
    XCTAssertEqual(
      configuration["UISceneDelegateClassName"] as? String,
      "Runner.SceneDelegate"
    )
    XCTAssertEqual(
      configuration["UISceneStoryboardFile"] as? String,
      "Main"
    )
  }

  func testSceneResignAndBackgroundKeepSinglePrivacyShield() throws {
    let delegate = AppDelegate()
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
    window.addSubview(UIView(frame: window.bounds))

    delegate.connectSceneWindow(
      window,
      isActive: false,
      protectedDataAvailable: true
    )
    delegate.sceneWillResignActive(window: window)
    delegate.sceneWillResignActive(window: window)
    delegate.sceneDidEnterBackground(window: window)

    XCTAssertTrue(delegate.sceneWindow === window)
    XCTAssertTrue(delegate.privacyShieldController.isInstalled)
    XCTAssertTrue(delegate.privacyShieldController.coveredWindow === window)
    XCTAssertEqual(
      window.subviews.filter {
        $0.accessibilityIdentifier
          == PrivacyShieldController.accessibilityIdentifier
      }.count,
      1
    )
  }

  func testSceneBecomesVisibleOnlyWhenProtectedDataIsAvailable() {
    let delegate = AppDelegate()
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))

    delegate.connectSceneWindow(
      window,
      isActive: true,
      protectedDataAvailable: true
    )
    XCTAssertFalse(delegate.privacyShieldController.isInstalled)

    delegate.sceneDidBecomeActive(
      window: window,
      protectedDataAvailable: false
    )
    XCTAssertTrue(delegate.privacyShieldController.isInstalled)

    delegate.sceneDidBecomeActive(
      window: window,
      protectedDataAvailable: true
    )
    XCTAssertFalse(delegate.privacyShieldController.isInstalled)
  }

  func testDisconnectClearsOnlyTheRegisteredSceneWindow() {
    let delegate = AppDelegate()
    let registeredWindow = UIWindow(
      frame: CGRect(x: 0, y: 0, width: 320, height: 640)
    )
    let unrelatedWindow = UIWindow(
      frame: CGRect(x: 0, y: 0, width: 320, height: 640)
    )
    delegate.connectSceneWindow(
      registeredWindow,
      isActive: false,
      protectedDataAvailable: false
    )

    delegate.disconnectSceneWindow(unrelatedWindow)
    XCTAssertTrue(delegate.sceneWindow === registeredWindow)
    XCTAssertTrue(delegate.privacyShieldController.isInstalled)

    delegate.disconnectSceneWindow(registeredWindow)
    XCTAssertNil(delegate.sceneWindow)
    XCTAssertFalse(delegate.privacyShieldController.isInstalled)
  }

  func testPrivacyManifestKeepsTrackingAndCollectionDisabled() throws {
    let url = try XCTUnwrap(
      Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy")
    )
    let data = try Data(contentsOf: url)
    let plist = try XCTUnwrap(
      PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: nil
      ) as? [String: Any]
    )

    XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
    XCTAssertEqual(
      (plist["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty,
      true
    )
    let accessedAPITypes = try XCTUnwrap(
      plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]]
    )
    XCTAssertEqual(accessedAPITypes.count, 1)
    let fileTimestamp = try XCTUnwrap(accessedAPITypes.first)
    XCTAssertEqual(
      fileTimestamp["NSPrivacyAccessedAPIType"] as? String,
      "NSPrivacyAccessedAPICategoryFileTimestamp"
    )
    XCTAssertEqual(
      Set(
        fileTimestamp["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? []
      ),
      Set(["C617.1", "3B52.1"])
    )
  }

  private func assertColor(
    _ color: UIColor,
    red: CGFloat,
    green: CGFloat,
    blue: CGFloat,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    var actualRed: CGFloat = 0
    var actualGreen: CGFloat = 0
    var actualBlue: CGFloat = 0
    var actualAlpha: CGFloat = 0
    XCTAssertTrue(
      color.getRed(
        &actualRed,
        green: &actualGreen,
        blue: &actualBlue,
        alpha: &actualAlpha
      ),
      file: file,
      line: line
    )
    XCTAssertEqual(actualRed * 255, red, accuracy: 0.5, file: file, line: line)
    XCTAssertEqual(
      actualGreen * 255,
      green,
      accuracy: 0.5,
      file: file,
      line: line
    )
    XCTAssertEqual(
      actualBlue * 255,
      blue,
      accuracy: 0.5,
      file: file,
      line: line
    )
    XCTAssertEqual(actualAlpha, 1, accuracy: 0.001, file: file, line: line)
  }

  private func makeProtectedStorageFixture(
    isAvailable: Bool = true
  ) throws -> (
    root: URL,
    support: URL,
    documents: URL,
    manager: ProtectedStorageManager
  ) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "protected-storage-\(UUID().uuidString)",
      isDirectory: true
    )
    let support = root.appendingPathComponent("Application Support", isDirectory: true)
    let documents = root.appendingPathComponent("Documents", isDirectory: true)
    let manager = ProtectedStorageManager(
      applicationSupportURL: support,
      documentsURL: documents,
      protectedDataAvailable: { isAvailable }
    )
    return (root, support, documents, manager)
  }

  private func assertCompleteProtection(
    _ url: URL,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let value = attributes[.protectionKey]
    let rawValue = (value as? FileProtectionType)?.rawValue
      ?? value as? String
#if targetEnvironment(simulator)
    // Simulator file systems don't expose NSFileProtectionKey. Successful
    // set/read-back behavior must be verified on a physical device.
    if value == nil {
      return
    }
#endif
    XCTAssertEqual(
      rawValue,
      FileProtectionType.complete.rawValue,
      file: file,
      line: line
    )
  }

  private func assertExcludedFromBackup(
    _ url: URL,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
    XCTAssertEqual(values.isExcludedFromBackup, true, file: file, line: line)
  }

  private func execute(
    _ sql: String,
    on database: OpaquePointer?,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    var errorMessage: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
    let message = errorMessage.map { String(cString: $0) } ?? "SQLite error"
    if let errorMessage {
      sqlite3_free(errorMessage)
    }
    XCTAssertEqual(result, SQLITE_OK, message, file: file, line: line)
    if result != SQLITE_OK {
      throw NSError(domain: "RunnerTests.SQLite", code: Int(result))
    }
  }

  private func openDatabase(at url: URL) throws -> OpaquePointer {
    var database: OpaquePointer?
    let result = sqlite3_open(url.path, &database)
    guard result == SQLITE_OK, let database else {
      if let database {
        sqlite3_close(database)
      }
      throw NSError(domain: "RunnerTests.SQLite", code: Int(result))
    }
    return database
  }
}
