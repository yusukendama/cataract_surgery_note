import 'dart:io';

import 'package:cataract_surgery_note/src/data/app_database.dart';
import 'package:cataract_surgery_note/src/data/providers.dart';
import 'package:cataract_surgery_note/src/data/surgery_repository.dart';
import 'package:cataract_surgery_note/src/data/video_storage_repository.dart';
import 'package:cataract_surgery_note/src/domain/surgery_models.dart';
import 'package:cataract_surgery_note/src/features/records/record_detail_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Resolves every managed path to a real (non-null) file, standing in for a
/// case whose video is present without touching the platform file system.
class _PresentVideoStorage implements VideoStorageRepository {
  @override
  Future<File?> resolveVideo(String relativePath) async => File(relativePath);

  @override
  Future<StoredVideo> importVideo({
    required String surgeryRecordId,
    required String sourcePath,
    required String originalFileName,
  }) async => throw UnimplementedError();

  @override
  Future<void> deleteVideo(String relativePath) async {}

  @override
  Future<void> deleteVideosForRecord(String surgeryRecordId) async {}
}

/// Resolves every managed path to null, standing in for a case whose video
/// file is gone (e.g. after an iCloud restore that dropped the videos).
class _MissingVideoStorage implements VideoStorageRepository {
  @override
  Future<File?> resolveVideo(String relativePath) async => null;

  @override
  Future<StoredVideo> importVideo({
    required String surgeryRecordId,
    required String sourcePath,
    required String originalFileName,
  }) async => throw UnimplementedError();

  @override
  Future<void> deleteVideo(String relativePath) async {}

  @override
  Future<void> deleteVideosForRecord(String surgeryRecordId) async {}
}

void main() {
  Future<(AppDatabase, SurgeryRecord)> createRecord(WidgetTester tester) async {
    late AppDatabase database;
    late SurgeryRecord record;
    await tester.runAsync(() async {
      database = AppDatabase.memory();
      record = await SurgeryRepository(database).createRecord(
        surgeryDate: DateTime(2026, 7, 18),
        eyeSide: EyeSide.right,
      );
    });
    return (database, record);
  }

  Future<void> pumpScreen(
    WidgetTester tester,
    AppDatabase database,
    String recordId,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDatabaseProvider.overrideWith((ref) => database)],
        child: MaterialApp(home: RecordDetailScreen(recordId: recordId)),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('編集ダイアログで左右眼を修正するとタイトルへ反映される', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);

    await pumpScreen(tester, database, record.id);

    expect(find.text('2026/07/18 右眼'), findsOneWidget);

    await tester.tap(find.byTooltip('手術日・左右眼を変更'));
    await tester.pumpAndSettle();
    expect(find.text('手術日'), findsOneWidget);

    await tester.tap(find.text('左眼'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(find.text('2026/07/18 左眼'), findsOneWidget);
    expect(find.text('2026/07/18 右眼'), findsNothing);
  });

  testWidgets('編集ダイアログをキャンセルするとタイトルは変わらない', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);

    await pumpScreen(tester, database, record.id);

    await tester.tap(find.byTooltip('手術日・左右眼を変更'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('左眼'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('キャンセル'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(find.text('2026/07/18 右眼'), findsOneWidget);
  });

  testWidgets('動画ファイルが存在するときはバックアップ注意書きを表示する', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await tester.runAsync(() async {
      await SurgeryRepository(database).updateVideoReference(
        surgeryRecordId: record.id,
        videoPath: 'videos/${record.id}/present.mp4',
        videoDisplayName: 'present.mp4',
      );
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => database),
          videoStorageRepositoryProvider.overrideWithValue(
            _PresentVideoStorage(),
          ),
        ],
        child: MaterialApp(home: RecordDetailScreen(recordId: record.id)),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(find.text('present.mp4'), findsOneWidget);
    expect(
      find.text('アプリ内に保存した動画はバックアップされません。元の動画は別途保管してください。'),
      findsOneWidget,
    );
    expect(find.text('動画を変更'), findsOneWidget);
    expect(
      find.text('保存した動画が見つかりません。機種変更や端末の復元後は、元の動画を選び直してください。'),
      findsNothing,
    );
  });

  testWidgets('DBにパスがあり実ファイルが無いときは再選択を促す', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);
    await tester.runAsync(() async {
      await SurgeryRepository(database).updateVideoReference(
        surgeryRecordId: record.id,
        videoPath: 'videos/${record.id}/gone.mp4',
        videoDisplayName: 'gone.mp4',
      );
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => database),
          videoStorageRepositoryProvider.overrideWithValue(
            _MissingVideoStorage(),
          ),
        ],
        child: MaterialApp(home: RecordDetailScreen(recordId: record.id)),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('保存した動画が見つかりません。機種変更や端末の復元後は、元の動画を選び直してください。'),
      findsOneWidget,
    );
    expect(find.text('動画を再選択'), findsOneWidget);
    expect(find.text('登録済みの動画'), findsNothing);
  });
}
