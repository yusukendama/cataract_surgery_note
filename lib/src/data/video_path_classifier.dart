import 'package:path/path.dart' as p;

enum VideoPathKind { unregistered, managed, legacyExternal, invalidReference }

class VideoPathClassification {
  const VideoPathClassification._(this.kind, this.path);

  const VideoPathClassification.unregistered()
    : this._(VideoPathKind.unregistered, null);

  const VideoPathClassification.managed(String path)
    : this._(VideoPathKind.managed, path);

  const VideoPathClassification.legacyExternal(String path)
    : this._(VideoPathKind.legacyExternal, path);

  const VideoPathClassification.invalid(String? path)
    : this._(VideoPathKind.invalidReference, path);

  final VideoPathKind kind;
  final String? path;
}

bool isValidRecordId(String recordId) {
  return recordId.isNotEmpty &&
      recordId != '.' &&
      recordId != '..' &&
      !recordId.contains('\u0000') &&
      !recordId.contains('/') &&
      !recordId.contains('\\');
}

VideoPathClassification classifyVideoPath({
  required String recordId,
  required String? videoPath,
}) {
  if (videoPath == null) {
    return const VideoPathClassification.unregistered();
  }
  if (!isValidRecordId(recordId) || !_hasCanonicalSegments(videoPath)) {
    return VideoPathClassification.invalid(videoPath);
  }

  final segments = videoPath.split('/');
  if (segments.length == 3 &&
      segments[0] == 'videos' &&
      segments[1] == recordId &&
      _isSingleFileName(segments[2]) &&
      p.url.joinAll(segments) == videoPath) {
    return VideoPathClassification.managed(videoPath);
  }

  if (p.isAbsolute(videoPath) &&
      p.normalize(videoPath) == videoPath &&
      !_containsDotSegment(videoPath)) {
    return VideoPathClassification.legacyExternal(videoPath);
  }
  return VideoPathClassification.invalid(videoPath);
}

bool _hasCanonicalSegments(String path) {
  if (path.isEmpty || path.contains('\u0000') || path.contains('\\')) {
    return false;
  }
  if (path.contains('//')) {
    return false;
  }
  return !_containsDotSegment(path);
}

bool _containsDotSegment(String path) {
  return path.split('/').any((segment) => segment == '.' || segment == '..');
}

bool _isSingleFileName(String value) {
  return value.isNotEmpty &&
      value != '.' &&
      value != '..' &&
      !value.contains('/') &&
      !value.contains('\\') &&
      !value.contains('\u0000');
}

/// Compatibility helper. Prefer [classifyVideoPath] whenever a record ID is
/// available because a managed path is only valid for that same record.
bool isManagedVideoPath(String path) {
  final segments = path.split('/');
  if (segments.length != 3) {
    return false;
  }
  return classifyVideoPath(recordId: segments[1], videoPath: path).kind ==
      VideoPathKind.managed;
}
