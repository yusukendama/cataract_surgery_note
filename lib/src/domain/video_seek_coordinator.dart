typedef VideoPositionReader = Duration Function();
typedef VideoDurationReader = Duration Function();
typedef VideoSeekCallback = Future<void> Function(Duration target);

/// Serializes video seeks while preserving every relative skip request.
///
/// While a seek is in progress, additional skips are accumulated against the
/// latest requested target rather than the player's not-yet-updated position.
class VideoSeekCoordinator {
  VideoSeekCoordinator({
    required VideoPositionReader currentPosition,
    required VideoDurationReader videoDuration,
    required VideoSeekCallback seekTo,
  }) : _currentPosition = currentPosition,
       _videoDuration = videoDuration,
       _seekTo = seekTo;

  final VideoPositionReader _currentPosition;
  final VideoDurationReader _videoDuration;
  final VideoSeekCallback _seekTo;

  Duration? _pendingTarget;
  Future<void>? _processingFuture;
  bool _disposed = false;

  /// Position requested by all taps so far, even if the player is still
  /// completing an earlier seek.
  Duration get effectivePosition => _pendingTarget ?? _currentPosition();

  Future<void> seekRelative(Duration offset) {
    if (_disposed) {
      return Future<void>.value();
    }
    final basePosition = _pendingTarget ?? _currentPosition();
    _pendingTarget = _bounded(basePosition + offset);
    return _startProcessing();
  }

  Future<void> seekTo(Duration target) {
    if (_disposed) {
      return Future<void>.value();
    }
    _pendingTarget = _bounded(target);
    return _startProcessing();
  }

  void dispose() {
    _disposed = true;
    _pendingTarget = null;
  }

  Future<void> _startProcessing() {
    final processing = _processingFuture;
    if (processing != null) {
      return processing;
    }
    final started = _drainPendingTargets();
    _processingFuture = started;
    return started;
  }

  Future<void> _drainPendingTargets() async {
    try {
      while (!_disposed) {
        final target = _pendingTarget;
        if (target == null) {
          return;
        }
        await _seekTo(target);
        if (_pendingTarget == target) {
          _pendingTarget = null;
        }
      }
    } finally {
      _pendingTarget = null;
      _processingFuture = null;
    }
  }

  Duration _bounded(Duration target) {
    final duration = _videoDuration();
    final maximum = duration < Duration.zero ? Duration.zero : duration;
    if (target < Duration.zero) {
      return Duration.zero;
    }
    if (target > maximum) {
      return maximum;
    }
    return target;
  }
}
