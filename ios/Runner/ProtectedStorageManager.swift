import Foundation
import UIKit

enum ProtectedStorageError: Error {
  case protectedDataUnavailable
  case invalidPath
  case unexpectedItem
  case fileProtectionFailed
  case backupExclusionFailed
}

struct PreparedStoragePaths {
  let applicationSupportPath: String
  let databasePath: String
}

final class ProtectedStorageManager {
  static let databaseFileName = "cataract_surgery_note.sqlite"

  private let fileManager: FileManager
  private let applicationSupportURL: URL
  private let documentsURL: URL
  private let protectedDataAvailable: () -> Bool

  init(
    fileManager: FileManager = .default,
    applicationSupportURL: URL? = nil,
    documentsURL: URL? = nil,
    protectedDataAvailable: @escaping () -> Bool = {
      UIApplication.shared.isProtectedDataAvailable
    }
  ) {
    self.fileManager = fileManager
    self.applicationSupportURL = applicationSupportURL
      ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    self.documentsURL = documentsURL
      ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    self.protectedDataAvailable = protectedDataAvailable
  }

  var isProtectedDataAvailable: Bool {
    protectedDataAvailable()
  }

  var videosURL: URL {
    applicationSupportURL.appendingPathComponent("videos", isDirectory: true)
  }

  var databaseURL: URL {
    documentsURL.appendingPathComponent(Self.databaseFileName, isDirectory: false)
  }

  /// Runs only while Drift is closed. Existing app-owned data is converged to
  /// complete protection before the database or a managed video can be used.
  func prepareAppStorage() throws -> PreparedStoragePaths {
    try requireProtectedDataAvailable()

    try createProtectedDirectoryIfNeeded(applicationSupportURL)
    try createProtectedDirectoryIfNeeded(videosURL)
    try convergeManagedVideoTree()

    try createProtectedDirectoryIfNeeded(documentsURL)
    try prepareDatabaseFamily()

    return PreparedStoragePaths(
      applicationSupportPath: applicationSupportURL.path,
      databasePath: databaseURL.path
    )
  }

  func protectDirectoryAndVerify(path: String) throws {
    try requireProtectedDataAvailable()
    let url = URL(fileURLWithPath: path, isDirectory: true)
    try requireManagedVideoURL(url, expectedDirectory: true)
    try applyAndVerifyCompleteProtection(to: url)
  }

  func protectFileAndVerify(path: String, excludeFromBackup: Bool) throws {
    try requireProtectedDataAvailable()
    let url = URL(fileURLWithPath: path, isDirectory: false)
    try requireManagedVideoURL(url, expectedDirectory: false)
    try applyAndVerifyCompleteProtection(to: url)
    if excludeFromBackup {
      try applyAndVerifyBackupExclusion(to: url)
    }
  }

  /// Verification is intentionally read-only because Drift may own an open
  /// SQLite connection. Repair is deferred until the next closed bootstrap.
  func verifyDatabaseFiles() throws {
    try requireProtectedDataAvailable()
    try verifyCompleteProtection(of: documentsURL)
    try verifyCompleteProtection(of: databaseURL)
    for sidecar in existingDatabaseSidecars() {
      try verifyCompleteProtection(of: sidecar)
    }
  }

  func applyAndVerifyBackupExclusionForManagedPath(_ path: String) throws {
    try requireProtectedDataAvailable()
    let url = URL(fileURLWithPath: path)
    let values = try url.resourceValues(forKeys: [.isDirectoryKey])
    let isDirectory = values.isDirectory == true
    try requireManagedVideoURL(url, expectedDirectory: isDirectory)
    try applyAndVerifyBackupExclusion(to: url)
  }

  private func prepareDatabaseFamily() throws {
    if !fileManager.fileExists(atPath: databaseURL.path) {
      let created = fileManager.createFile(
        atPath: databaseURL.path,
        contents: Data(),
        attributes: [.protectionKey: FileProtectionType.complete]
      )
      guard created else {
        throw ProtectedStorageError.fileProtectionFailed
      }
    }
    try requireRegularFileWithoutLink(databaseURL)
    try applyAndVerifyCompleteProtection(to: databaseURL)

    for sidecar in existingDatabaseSidecars() {
      try requireRegularFileWithoutLink(sidecar)
      try applyAndVerifyCompleteProtection(to: sidecar)
    }
  }

  private func existingDatabaseSidecars() -> [URL] {
    ["-wal", "-shm", "-journal"].compactMap { suffix in
      let url = URL(fileURLWithPath: databaseURL.path + suffix)
      return fileManager.fileExists(atPath: url.path) ? url : nil
    }
  }

  private func convergeManagedVideoTree() throws {
    try applyAndVerifyCompleteProtection(to: videosURL)
    try applyAndVerifyBackupExclusion(to: videosURL)

    var enumerationFailed = false
    guard let enumerator = fileManager.enumerator(
      at: videosURL,
      includingPropertiesForKeys: [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
      ],
      options: [],
      errorHandler: { _, _ in
        enumerationFailed = true
        return false
      }
    ) else {
      throw ProtectedStorageError.fileProtectionFailed
    }

    for case let url as URL in enumerator {
      let values = try url.resourceValues(
        forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
      )
      guard values.isSymbolicLink != true else {
        throw ProtectedStorageError.invalidPath
      }
      if values.isDirectory == true {
        try requireManagedVideoURL(url, expectedDirectory: true)
        try applyAndVerifyCompleteProtection(to: url)
      } else if values.isRegularFile == true {
        try requireManagedVideoURL(url, expectedDirectory: false)
        try applyAndVerifyCompleteProtection(to: url)
        try applyAndVerifyBackupExclusion(to: url)
      } else {
        throw ProtectedStorageError.unexpectedItem
      }
    }
    guard !enumerationFailed else {
      throw ProtectedStorageError.fileProtectionFailed
    }
  }

  private func createProtectedDirectoryIfNeeded(_ url: URL) throws {
    if !fileManager.fileExists(atPath: url.path) {
      try fileManager.createDirectory(
        at: url,
        withIntermediateDirectories: true,
        attributes: [.protectionKey: FileProtectionType.complete]
      )
    }
    try requireDirectoryWithoutLink(url)
    try applyAndVerifyCompleteProtection(to: url)
  }

  private func requireManagedVideoURL(
    _ url: URL,
    expectedDirectory: Bool
  ) throws {
    if expectedDirectory {
      try requireDirectoryWithoutLink(url)
    } else {
      try requireRegularFileWithoutLink(url)
    }

    let canonicalRoot = videosURL.resolvingSymlinksInPath().standardizedFileURL
    let canonicalTarget = url.resolvingSymlinksInPath().standardizedFileURL
    let rootPath = canonicalRoot.path
    let targetPath = canonicalTarget.path
    guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else {
      throw ProtectedStorageError.invalidPath
    }

    let relativeComponents = Array(
      canonicalTarget.pathComponents.dropFirst(canonicalRoot.pathComponents.count)
    )
    if expectedDirectory {
      guard relativeComponents.count <= 1 else {
        throw ProtectedStorageError.invalidPath
      }
    } else {
      guard relativeComponents.count == 2 else {
        throw ProtectedStorageError.invalidPath
      }
    }
  }

  private func requireDirectoryWithoutLink(_ url: URL) throws {
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    guard attributes[.type] as? FileAttributeType == .typeDirectory else {
      throw ProtectedStorageError.unexpectedItem
    }
  }

  private func requireRegularFileWithoutLink(_ url: URL) throws {
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular else {
      throw ProtectedStorageError.unexpectedItem
    }
  }

  private func applyAndVerifyCompleteProtection(to url: URL) throws {
    do {
      try fileManager.setAttributes(
        [.protectionKey: FileProtectionType.complete],
        ofItemAtPath: url.path
      )
      try verifyCompleteProtection(of: url)
    } catch let error as ProtectedStorageError {
      throw error
    } catch {
      throw ProtectedStorageError.fileProtectionFailed
    }
  }

  private func verifyCompleteProtection(of url: URL) throws {
    do {
      let attributes = try fileManager.attributesOfItem(atPath: url.path)
      let value = attributes[.protectionKey]
      let rawValue: String?
      if let protection = value as? FileProtectionType {
        rawValue = protection.rawValue
      } else {
        rawValue = value as? String
      }
#if targetEnvironment(simulator)
      // iOS Simulator accepts protection attributes but does not expose their
      // read-back value. Device builds still require the exact value below.
      if value == nil {
        return
      }
#endif
      guard rawValue == FileProtectionType.complete.rawValue else {
        throw ProtectedStorageError.fileProtectionFailed
      }
    } catch let error as ProtectedStorageError {
      throw error
    } catch {
      throw ProtectedStorageError.fileProtectionFailed
    }
  }

  private func applyAndVerifyBackupExclusion(to url: URL) throws {
    do {
      var mutableURL = url
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try mutableURL.setResourceValues(values)
      let verified = try mutableURL.resourceValues(
        forKeys: [.isExcludedFromBackupKey]
      )
      guard verified.isExcludedFromBackup == true else {
        throw ProtectedStorageError.backupExclusionFailed
      }
    } catch let error as ProtectedStorageError {
      throw error
    } catch {
      throw ProtectedStorageError.backupExclusionFailed
    }
  }

  private func requireProtectedDataAvailable() throws {
    guard protectedDataAvailable() else {
      throw ProtectedStorageError.protectedDataUnavailable
    }
  }
}
