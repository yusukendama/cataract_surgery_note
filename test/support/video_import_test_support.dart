import 'dart:io';

import 'package:cataract_surgery_note/src/data/file_sha256.dart';
import 'package:cataract_surgery_note/src/data/surgery_video_picker.dart';
import 'package:cataract_surgery_note/src/data/video_import_models.dart';
import 'package:cataract_surgery_note/src/data/video_import_preflight.dart';
import 'package:path/path.dart' as p;

const VideoPlaybackEvidence testVideoPlaybackEvidence = VideoPlaybackEvidence(
  duration: Duration(seconds: 12),
  width: 1920,
  height: 1080,
);

Future<VerifiedVideoCandidate> verifiedVideoCandidateForFile(
  File file, {
  String? displayName,
  int selectionGeneration = 1,
  String? sourceIdentifier,
  VideoPlaybackEvidence playbackEvidence = testVideoPlaybackEvidence,
}) async {
  final stat = await file.stat();
  final effectiveDisplayName = displayName ?? p.basename(file.path);
  return VerifiedVideoCandidate(
    path: file.path,
    displayName: effectiveDisplayName,
    normalizedExtension: const VideoSelectionPolicy().normalizeExtension(
      effectiveDisplayName,
    ),
    selectionGeneration: selectionGeneration,
    sourceSize: stat.size,
    sourceModifiedAt: stat.modified,
    sha256: await sha256OfFile(file),
    playbackEvidence: playbackEvidence,
    sourceIdentifier: sourceIdentifier,
  );
}

VerifiedVideoCandidate verifiedVideoCandidateForFileSync(
  File file, {
  String? displayName,
  int selectionGeneration = 1,
  String? sourceIdentifier,
  VideoPlaybackEvidence playbackEvidence = testVideoPlaybackEvidence,
}) {
  final stat = file.statSync();
  final effectiveDisplayName = displayName ?? p.basename(file.path);
  return VerifiedVideoCandidate(
    path: file.path,
    displayName: effectiveDisplayName,
    normalizedExtension: const VideoSelectionPolicy().normalizeExtension(
      effectiveDisplayName,
    ),
    selectionGeneration: selectionGeneration,
    sourceSize: stat.size,
    sourceModifiedAt: stat.modified,
    sha256: sha256OfBytes(file.readAsBytesSync()),
    playbackEvidence: playbackEvidence,
    sourceIdentifier: sourceIdentifier,
  );
}

/// Test double for call sites that exercise service/storage behavior rather
/// than source admission itself.
class PassThroughVideoImportPreflight implements VideoImportPreflight {
  const PassThroughVideoImportPreflight();

  @override
  Future<VideoSelectionPreflightResult> inspectSelection(
    SelectedSurgeryVideo selection, {
    required int selectionGeneration,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) async {
    cancellationToken?.throwIfCancelled(VideoImportPhase.sourceAccess);
    return VideoSelectionReady(
      verifiedVideoCandidateForFileSync(
        File(selection.path),
        displayName: selection.displayName,
        selectionGeneration: selectionGeneration,
      ),
    );
  }

  @override
  Future<VerifiedVideoCandidate> revalidateForImport(
    VerifiedVideoCandidate candidate, {
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) async {
    cancellationToken?.throwIfCancelled(VideoImportPhase.sourceAccess);
    return candidate;
  }

  @override
  Future<T> withRevalidatedImport<T>(
    VerifiedVideoCandidate candidate, {
    required Future<T> Function(VerifiedVideoCandidate admittedCandidate)
    operation,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) async {
    cancellationToken?.throwIfCancelled(VideoImportPhase.sourceAccess);
    return operation(candidate);
  }
}
