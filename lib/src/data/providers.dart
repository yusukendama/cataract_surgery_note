import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/surgery_models.dart';
import 'app_database.dart';
import 'record_video_service.dart';
import 'surgery_repository.dart';
import 'video_storage_repository.dart';

final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final database = AppDatabase();
  ref.onDispose(database.close);
  return database;
});

final surgeryRepositoryProvider = Provider<SurgeryRepository>((ref) {
  return SurgeryRepository(ref.watch(appDatabaseProvider));
});

final videoStorageRepositoryProvider = Provider<VideoStorageRepository>((ref) {
  return LocalVideoStorageRepository();
});

final recordVideoServiceProvider = Provider<RecordVideoService>((ref) {
  return RecordVideoService(
    surgeryRepository: ref.watch(surgeryRepositoryProvider),
    videoStorageRepository: ref.watch(videoStorageRepositoryProvider),
  );
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

final surgeryRecordProvider = FutureProvider.family<SurgeryRecord?, String>((
  ref,
  recordId,
) {
  return ref.watch(surgeryRepositoryProvider).getRecord(recordId);
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
