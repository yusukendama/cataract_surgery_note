import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/surgery_models.dart';
import '../domain/surgery_trend.dart';
import 'app_database.dart';
import 'analysis_time_context.dart';
import 'onboarding_state_repository.dart';
import 'protected_storage.dart';
import 'record_video_service.dart';
import 'surgery_repository.dart';
import 'surgery_video_picker.dart';
import 'video_import_preflight.dart';
import 'video_storage_repository.dart';

final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final database = AppDatabase();
  ref.onDispose(database.close);
  return database;
});

final surgeryRepositoryProvider = Provider<SurgeryRepository>((ref) {
  return SurgeryRepository(ref.watch(appDatabaseProvider));
});

final analysisTimeContextSourceProvider = Provider<AnalysisTimeContextSource>((
  ref,
) {
  return PlatformAnalysisTimeContextSource();
});

final analysisSchedulerProvider = Provider<AnalysisScheduler>((ref) {
  return const TimerAnalysisScheduler();
});

final onboardingStateRepositoryProvider = Provider<OnboardingStateRepository>((
  ref,
) {
  return SharedPreferencesOnboardingStateRepository();
});

final onboardingRecordExistsProvider = FutureProvider<bool>((ref) {
  return ref.watch(surgeryRepositoryProvider).hasAnyRecords();
});

final protectedStorageRepositoryProvider = Provider<ProtectedStorageRepository>(
  (ref) {
    return MethodChannelProtectedStorageRepository();
  },
);

final videoImportPreflightProvider = Provider<VideoImportPreflight>((ref) {
  return DefaultVideoImportPreflight(
    protectedDataRepository: ref.watch(protectedStorageRepositoryProvider),
  );
});

final videoStorageRepositoryProvider = Provider<VideoStorageRepository>((ref) {
  final protectedStorage = ref.watch(protectedStorageRepositoryProvider);
  return LocalVideoStorageRepository(
    protectedDataRepository: protectedStorage,
    fileProtectionRepository: protectedStorage,
  );
});

final surgeryVideoPickerProvider = Provider<SurgeryVideoPicker>((ref) {
  return const FilePickerSurgeryVideoPicker();
});

final recordVideoServiceProvider = Provider<RecordVideoService>((ref) {
  return RecordVideoService(
    surgeryRepository: ref.watch(surgeryRepositoryProvider),
    videoStorageRepository: ref.watch(videoStorageRepositoryProvider),
    videoImportPreflight: ref.watch(videoImportPreflightProvider),
  );
});

final videoStorageMaintenanceProvider =
    FutureProvider<VideoStorageMaintenanceReport?>((ref) {
      return ref.watch(recordVideoServiceProvider).initialize();
    });

final recordVideoFileProvider = FutureProvider.family<File?, String>((
  ref,
  recordId,
) async {
  final record = await ref.watch(surgeryRecordProvider(recordId).future);
  if (record == null) {
    return null;
  }
  return ref.watch(recordVideoServiceProvider).resolveVideoForRecord(record);
});

final surgeryRecordsProvider = FutureProvider<List<SurgeryRecord>>((ref) {
  return ref.watch(surgeryRepositoryProvider).watchableListSnapshot();
});

final surgeryRecordProgressProvider =
    FutureProvider<List<SurgeryRecordProgress>>((ref) {
      return ref
          .watch(surgeryRepositoryProvider)
          .fetchRecordProgressSnapshots();
    });

final recordProcedureTimingSnapshotProvider =
    FutureProvider.family<RecordProcedureTimingSnapshot, String>((
      ref,
      recordId,
    ) {
      return ref
          .watch(surgeryRepositoryProvider)
          .fetchRecordProcedureTimingSnapshot(recordId);
    });

final surgeryAnalysisProvider =
    FutureProvider.autoDispose<SurgeryAnalysisSnapshot>((ref) async {
      final repository = ref.watch(surgeryRepositoryProvider);
      final timeSource = ref.watch(analysisTimeContextSourceProvider);
      for (var attempt = 0; attempt < 2; attempt++) {
        final before = await timeSource.read();
        final snapshot = await repository.fetchAnalysisSnapshot();
        final after = await timeSource.read();
        if (before.timezoneIdentifier == after.timezoneIdentifier) {
          final referenceDate = DateTime(
            after.now.year,
            after.now.month,
            after.now.day,
          );
          return snapshot.withDisplayContext(
            referenceDate: referenceDate,
            timezoneIdentifier: after.timezoneIdentifier,
          );
        }
      }
      throw StateError('分析データ取得中にtimezoneが繰り返し変更されました。');
    });

final surgeryRecordProvider = FutureProvider.family<SurgeryRecord?, String>((
  ref,
  recordId,
) {
  return ref.watch(surgeryRepositoryProvider).getRecord(recordId);
});

final recordVideoStateProvider =
    FutureProvider.family<RecordVideoState, String>((ref, recordId) async {
      final record = await ref.watch(surgeryRecordProvider(recordId).future);
      if (record == null) {
        throw StateError('症例が見つかりません。');
      }
      return ref.watch(recordVideoServiceProvider).inspectVideoState(record);
    });

/// List-specific cache key for lightweight video-reference inspection.
///
/// Equality deliberately ignores record metadata that cannot affect video
/// availability. A changed video reference creates a new family instance even
/// if an explicit invalidation is missed, while ordinary list rebuilds reuse
/// the existing file check.
class RecordVideoStateRequest {
  const RecordVideoStateRequest(this.record);

  final SurgeryRecord record;

  @override
  bool operator ==(Object other) {
    return other is RecordVideoStateRequest &&
        other.record.id == record.id &&
        other.record.videoPath == record.videoPath;
  }

  @override
  int get hashCode => Object.hash(record.id, record.videoPath);
}

final recordVideoStateByReferenceProvider =
    FutureProvider.family<RecordVideoState, RecordVideoStateRequest>((
      ref,
      request,
    ) {
      return ref
          .watch(recordVideoServiceProvider)
          .inspectVideoState(request.record);
    });

final cccReviewProvider = FutureProvider.family<SurgicalStepReview, String>((
  ref,
  recordId,
) {
  return ref
      .watch(surgeryRepositoryProvider)
      .ensureStepReview(
        surgeryRecordId: recordId,
        step: SurgicalStep.capsulorhexis,
      );
});

final stepReviewsProvider =
    FutureProvider.family<List<SurgicalStepReview>, String>((ref, recordId) {
      return ref.watch(surgeryRepositoryProvider).ensureStepReviews(recordId);
    });

final recordHasRecordedTimingsProvider = FutureProvider.family<bool, String>((
  ref,
  recordId,
) {
  return ref.watch(surgeryRepositoryProvider).hasRecordedTimings(recordId);
});
