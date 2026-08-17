import Foundation
import UIKit

enum ProtectedStorageError: Error {
  case protectedDataUnavailable
  case invalidPath
  case unexpectedItem
  case fileProtectionFailed
  case backupExclusionFailed
}

enum ProtectedStorageFailureStage: String {
  case databaseDirectory = "database_directory"
  case databaseFile = "database_file"
  case databaseSidecar = "database_sidecar"
  case managedVideoDirectory = "managed_video_directory"
  case managedVideoFile = "managed_video_file"
}

struct StagedProtectedStorageError: Error {
  let error: ProtectedStorageError
  let stage: ProtectedStorageFailureStage
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

  /// Runs only while Drift is closed. Only the database family is a bootstrap
  /// dependency. Managed videos are converged by video maintenance and verified
  /// again on direct access, so one malformed video entry cannot hide every
  /// otherwise protected case record and review.
  func prepareAppStorage() throws -> PreparedStoragePaths {
    try requireProtectedDataAvailable()

    try prepareDatabaseDirectory()
    try prepareDatabaseFamily()

    return PreparedStoragePaths(
      applicationSupportPath: applicationSupportURL.path,
      databasePath: databaseURL.path
    )
  }

  func protectDirectoryAndVerify(path: String) throws {
    try requireProtectedDataAvailable()
    try perform(stage: .managedVideoDirectory) {
      let url = URL(fileURLWithPath: path, isDirectory: true)
      try requireManagedVideoURL(url, expectedDirectory: true)
      try applyAndVerifyCompleteProtection(to: url)
    }
  }

  func protectFileAndVerify(path: String, excludeFromBackup: Bool) throws {
    try requireProtectedDataAvailable()
    try perform(stage: .managedVideoFile) {
      let url = URL(fileURLWithPath: path, isDirectory: false)
      try requireManagedVideoURL(url, expectedDirectory: false)
      try applyAndVerifyCompleteProtection(to: url)
      if excludeFromBackup {
        try applyAndVerifyBackupExclusion(to: url)
      }
    }
  }

  /// Verifies the database family while Drift owns the connection. If SQLite
  /// has created a sidecar with a weaker inherited class, repair its metadata
  /// and read it back before returning protected data to Dart.
  func verifyDatabaseFiles() throws {
    try requireProtectedDataAvailable()
    try perform(stage: .databaseFile) {
      try requireRegularFileWithoutLink(databaseURL)
      try verifyOrRepairCompleteProtection(of: databaseURL)
    }
    for sidecar in existingDatabaseSidecars() {
      try perform(stage: .databaseSidecar) {
        try requireRegularFileWithoutLink(sidecar)
        try verifyOrRepairCompleteProtection(of: sidecar)
      }
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

  private func prepareDatabaseDirectory() throws {
    try perform(stage: .databaseDirectory) {
      if !fileManager.fileExists(atPath: documentsURL.path) {
        try fileManager.createDirectory(
          at: documentsURL,
          withIntermediateDirectories: true,
          attributes: [.protectionKey: FileProtectionType.complete]
        )
      }
      try requireDirectoryWithoutLink(documentsURL)
    }

    // Some iOS versions don't expose a stable protection attribute for the
    // app's standard Documents directory. Apply it when possible, but gate
    // access on the database file family below, whose contents are sensitive.
    do {
      try applyAndVerifyCompleteProtection(to: documentsURL)
    } catch {
      // Don't misclassify a lock transition as a tolerated directory
      // read-back difference.
      try requireProtectedDataAvailable()
    }
  }

  private func prepareDatabaseFamily() throws {
    try perform(stage: .databaseFile) {
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
    }

    for sidecar in existingDatabaseSidecars() {
      try perform(stage: .databaseSidecar) {
        try requireRegularFileWithoutLink(sidecar)
        try applyAndVerifyCompleteProtection(to: sidecar)
      }
    }
  }

  private func existingDatabaseSidecars() -> [URL] {
    ["-wal", "-shm", "-journal"].compactMap { suffix in
      let url = URL(fileURLWithPath: databaseURL.path + suffix)
      return fileManager.fileExists(atPath: url.path) ? url : nil
    }
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

  private func verifyOrRepairCompleteProtection(of url: URL) throws {
    do {
      try verifyCompleteProtection(of: url)
    } catch {
      try applyAndVerifyCompleteProtection(to: url)
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

  private func perform<T>(
    stage: ProtectedStorageFailureStage,
    _ operation: () throws -> T
  ) throws -> T {
    do {
      return try operation()
    } catch let error as StagedProtectedStorageError {
      throw error
    } catch let error as ProtectedStorageError {
      if case .protectedDataUnavailable = error {
        throw error
      }
      throw StagedProtectedStorageError(error: error, stage: stage)
    } catch {
      throw StagedProtectedStorageError(
        error: .fileProtectionFailed,
        stage: stage
      )
    }
  }
}
