import 'dart:io';

import 'package:flutter/services.dart';

import 'surgery_video_picker.dart';

enum VideoSourceAccessFailureReason {
  protectedDataUnavailable,
  sourceNotFound,
  providerUnavailable,
  accessDenied,
}

class VideoSourceAccessException implements Exception {
  const VideoSourceAccessException(this.reason);

  final VideoSourceAccessFailureReason reason;
}

abstract interface class VideoSourceAccessLease {
  File get file;
  String? get sourceIdentifier;

  /// Releases any provider or security-scoped access held by this lease.
  /// Implementations must be idempotent.
  Future<void> release();
}

abstract interface class VideoSourceAccessRepository {
  Future<VideoSourceAccessLease> acquire(SelectedSurgeryVideo reference);
}

/// Uses an iOS security-scoped lease when running on iOS and a direct,
/// read-only file reference on other platforms.
class PlatformVideoSourceAccessRepository
    implements VideoSourceAccessRepository {
  const PlatformVideoSourceAccessRepository({
    MethodChannel methodChannel = const MethodChannel(
      'cataract_surgery_note/source_access',
    ),
    bool? isIOSOverride,
  }) : _methodChannel = methodChannel,
       _isIOSOverride = isIOSOverride;

  final MethodChannel _methodChannel;
  final bool? _isIOSOverride;

  @override
  Future<VideoSourceAccessLease> acquire(SelectedSurgeryVideo reference) async {
    if (!(_isIOSOverride ?? Platform.isIOS)) {
      return _DirectVideoSourceAccessLease(File(reference.path));
    }
    try {
      final response = await _methodChannel.invokeMapMethod<String, Object?>(
        'acquire',
        <String, Object>{'path': reference.path},
      );
      final token = response?['token'];
      if (token is! String || token.isEmpty) {
        throw const VideoSourceAccessException(
          VideoSourceAccessFailureReason.providerUnavailable,
        );
      }
      final identifier = response?['identifier'];
      return _MethodChannelVideoSourceAccessLease(
        file: File(reference.path),
        token: token,
        sourceIdentifier: identifier is String && identifier.isNotEmpty
            ? identifier
            : null,
        methodChannel: _methodChannel,
      );
    } on VideoSourceAccessException {
      rethrow;
    } on PlatformException catch (error) {
      if (error.code == 'protected_data_unavailable') {
        throw const VideoSourceAccessException(
          VideoSourceAccessFailureReason.protectedDataUnavailable,
        );
      }
      if (error.code == 'source_not_found') {
        throw const VideoSourceAccessException(
          VideoSourceAccessFailureReason.sourceNotFound,
        );
      }
      if (error.code == 'source_access_denied') {
        throw const VideoSourceAccessException(
          VideoSourceAccessFailureReason.accessDenied,
        );
      }
      throw const VideoSourceAccessException(
        VideoSourceAccessFailureReason.providerUnavailable,
      );
    } on MissingPluginException {
      throw const VideoSourceAccessException(
        VideoSourceAccessFailureReason.providerUnavailable,
      );
    }
  }
}

class _DirectVideoSourceAccessLease implements VideoSourceAccessLease {
  _DirectVideoSourceAccessLease(this.file);

  @override
  final File file;

  @override
  String? get sourceIdentifier => null;

  @override
  Future<void> release() async {}
}

class _MethodChannelVideoSourceAccessLease implements VideoSourceAccessLease {
  _MethodChannelVideoSourceAccessLease({
    required this.file,
    required this.token,
    required this.sourceIdentifier,
    required MethodChannel methodChannel,
  }) : _methodChannel = methodChannel;

  @override
  final File file;
  final String token;
  final MethodChannel _methodChannel;

  @override
  final String? sourceIdentifier;

  bool _released = false;

  @override
  Future<void> release() async {
    if (_released) {
      return;
    }
    _released = true;
    try {
      await _methodChannel.invokeMethod<void>('release', <String, Object>{
        'token': token,
      });
    } on MissingPluginException {
      // The app may be terminating and the native messenger already gone.
    } on PlatformException {
      // Release is best-effort at the channel boundary. Native leases are also
      // released when the application process exits.
    }
  }
}
