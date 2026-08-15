import 'dart:async';

/// Serializes mutations that target the same surgery record.
///
/// Repository methods are intentionally re-entrant so a service can hold the
/// record lock across a file/DB operation and safely call another repository
/// mutation without deadlocking.
class RecordMutationCoordinator {
  final Map<String, Future<void>> _tails = <String, Future<void>>{};

  Future<T> run<T>(String recordId, Future<T> Function() action) async {
    if (Zone.current[this] == recordId) {
      return action();
    }

    final previous = _tails[recordId] ?? Future<void>.value();
    final release = Completer<void>();
    _tails[recordId] = release.future;

    try {
      await previous.catchError((Object _) {});
      return await runZoned(
        action,
        zoneValues: <Object?, Object?>{this: recordId},
      );
    } finally {
      release.complete();
      if (identical(_tails[recordId], release.future)) {
        _tails.remove(recordId);
      }
    }
  }
}

sealed class SurgeryMutationException implements Exception {
  const SurgeryMutationException(this.message);

  final String message;

  @override
  String toString() => message;
}

final class SurgeryRecordNotFoundException extends SurgeryMutationException {
  const SurgeryRecordNotFoundException(String recordId)
    : super('症例が削除されたか、存在しません: $recordId');
}

final class SurgicalStepReviewNotFoundException
    extends SurgeryMutationException {
  const SurgicalStepReviewNotFoundException(String reviewId)
    : super('工程記録が削除されたか、存在しません: $reviewId');
}

final class VideoReferenceConflictException extends SurgeryMutationException {
  const VideoReferenceConflictException({
    required this.expectedPath,
    required this.currentPath,
  }) : super('操作中に登録動画が変更されました。最新状態を読み込んでください。');

  final String? expectedPath;
  final String? currentPath;
}

final class InvalidRecordIdentifierException extends SurgeryMutationException {
  const InvalidRecordIdentifierException(String recordId)
    : super('不正な症例IDです: $recordId');
}
