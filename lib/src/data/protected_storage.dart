import 'dart:async';

import 'package:flutter/services.dart';

/// The iOS application-container paths prepared before protected data is used.
class ProtectedStoragePaths {
  const ProtectedStoragePaths({
    required this.applicationSupportPath,
    required this.databasePath,
  });

  final String applicationSupportPath;
  final String databasePath;
}

/// Raised when iOS Data Protection is active and complete-protected data cannot
/// currently be accessed.
class ProtectedDataUnavailableException implements Exception {
  const ProtectedDataUnavailableException();

  @override
  String toString() => 'ProtectedDataUnavailableException';
}

/// Raised when an exact NSFileProtectionComplete attribute cannot be applied or
/// read back. Paths and native error descriptions are deliberately omitted.
class FileProtectionException implements Exception {
  const FileProtectionException();

  @override
  String toString() => 'FileProtectionException';
}

/// Raised when native storage protection succeeded but backup exclusion could
/// not be applied and read back.
///
/// This is deliberately distinct from [FileProtectionException] so the video
/// import layer can present the correct fail-closed recovery reason.
class BackupExclusionException implements Exception {
  const BackupExclusionException();

  @override
  String toString() => 'BackupExclusionException';
}

abstract interface class ProtectedDataRepository {
  Future<bool> get isAvailable;

  /// Emits the current value on listen and then each native availability
  /// transition.
  Stream<bool> get availabilityChanges;

  Future<void> requireAvailable();
}

abstract interface class FileProtectionRepository {
  /// Creates or repairs the known app-owned storage roots while the database is
  /// closed, then returns the paths the Dart layer must use.
  Future<ProtectedStoragePaths> prepareAppStorage();

  /// Applies and reads back NSFileProtectionComplete for a managed-video
  /// directory. The native side rejects paths outside Application Support/videos.
  Future<void> protectDirectoryAndVerify(String path);

  /// Applies and reads back NSFileProtectionComplete for a managed-video file.
  /// When requested, backup exclusion is also applied and read back.
  /// The native side rejects paths outside Application Support/videos.
  Future<void> protectFileAndVerify(
    String path, {
    required bool excludeFromBackup,
  });

  /// Read-only verification used while Drift owns the open database connection.
  /// A mismatch fails closed; repair happens only on the next closed bootstrap.
  Future<void> verifyDatabaseFiles();
}

/// Shared provider type when one implementation supplies both availability
/// gating and file-protection operations.
abstract interface class ProtectedStorageRepository
    implements ProtectedDataRepository, FileProtectionRepository {}

/// A platform-channel-free implementation for unit/widget tests and platforms
/// where iOS Data Protection does not apply.
///
/// Pass [paths] whenever [prepareAppStorage] is part of the exercised flow. The
/// default relative paths are inert placeholders intended for tests that only
/// need availability and protection verification to succeed.
final class NoopProtectedStorageRepository
    implements ProtectedStorageRepository {
  const NoopProtectedStorageRepository({
    this.paths = const ProtectedStoragePaths(
      applicationSupportPath: '.',
      databasePath: 'cataract_surgery_note.sqlite',
    ),
  });

  final ProtectedStoragePaths paths;

  @override
  Future<bool> get isAvailable async => true;

  @override
  Stream<bool> get availabilityChanges => Stream<bool>.value(true);

  @override
  Future<void> requireAvailable() async {}

  @override
  Future<ProtectedStoragePaths> prepareAppStorage() async => paths;

  @override
  Future<void> protectDirectoryAndVerify(String path) async {}

  @override
  Future<void> protectFileAndVerify(
    String path, {
    required bool excludeFromBackup,
  }) async {}

  @override
  Future<void> verifyDatabaseFiles() async {}
}

class MethodChannelProtectedStorageRepository
    implements ProtectedStorageRepository {
  MethodChannelProtectedStorageRepository({
    MethodChannel methodChannel = const MethodChannel(
      'cataract_surgery_note/protected_storage',
    ),
    EventChannel eventChannel = const EventChannel(
      'cataract_surgery_note/protected_data_events',
    ),
  }) : _methodChannel = methodChannel,
       _eventChannel = eventChannel;

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;
  Stream<bool>? _availabilityChanges;

  @override
  Future<bool> get isAvailable async {
    try {
      return await _methodChannel.invokeMethod<bool>(
            'isProtectedDataAvailable',
          ) ??
          false;
    } on PlatformException catch (error) {
      throw _mapPlatformException(error);
    }
  }

  @override
  Stream<bool> get availabilityChanges {
    return _availabilityChanges ??= _eventChannel
        .receiveBroadcastStream()
        .map<bool>((value) => value == true)
        .handleError((Object error) {
          if (error is PlatformException) {
            throw _mapPlatformException(error);
          }
          throw const FileProtectionException();
        })
        .asBroadcastStream();
  }

  @override
  Future<void> requireAvailable() async {
    if (!await isAvailable) {
      throw const ProtectedDataUnavailableException();
    }
  }

  @override
  Future<ProtectedStoragePaths> prepareAppStorage() async {
    try {
      final result = await _methodChannel.invokeMapMethod<String, Object?>(
        'prepareAppStorage',
      );
      final applicationSupportPath = result?['applicationSupportPath'];
      final databasePath = result?['databasePath'];
      if (applicationSupportPath is! String ||
          applicationSupportPath.isEmpty ||
          databasePath is! String ||
          databasePath.isEmpty) {
        throw const FileProtectionException();
      }
      return ProtectedStoragePaths(
        applicationSupportPath: applicationSupportPath,
        databasePath: databasePath,
      );
    } on PlatformException catch (error) {
      throw _mapPlatformException(error);
    }
  }

  @override
  Future<void> protectDirectoryAndVerify(String path) {
    return _invokeVoid('protectDirectoryAndVerify', <String, Object>{
      'path': path,
    });
  }

  @override
  Future<void> protectFileAndVerify(
    String path, {
    required bool excludeFromBackup,
  }) {
    return _invokeVoid('protectFileAndVerify', <String, Object>{
      'path': path,
      'excludeFromBackup': excludeFromBackup,
    });
  }

  @override
  Future<void> verifyDatabaseFiles() {
    return _invokeVoid('verifyDatabaseFiles');
  }

  Future<void> _invokeVoid(
    String method, [
    Map<String, Object>? arguments,
  ]) async {
    try {
      final verified = await _methodChannel.invokeMethod<bool>(
        method,
        arguments,
      );
      if (verified != true) {
        throw const FileProtectionException();
      }
    } on PlatformException catch (error) {
      throw _mapPlatformException(error);
    }
  }

  Exception _mapPlatformException(PlatformException error) {
    if (error.code == 'protected_data_unavailable') {
      return const ProtectedDataUnavailableException();
    }
    if (error.code == 'backup_exclusion_failed') {
      return const BackupExclusionException();
    }
    return const FileProtectionException();
  }
}
