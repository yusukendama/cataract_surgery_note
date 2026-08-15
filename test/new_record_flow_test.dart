import 'dart:io';

import 'package:cataract_surgery_note/src/data/app_database.dart';
import 'package:cataract_surgery_note/src/data/providers.dart';
import 'package:cataract_surgery_note/src/data/surgery_repository.dart';
import 'package:cataract_surgery_note/src/data/surgery_video_picker.dart';
import 'package:cataract_surgery_note/src/domain/surgery_models.dart';
import 'package:cataract_surgery_note/src/features/records/new_record_screen.dart';
import 'package:cataract_surgery_note/src/features/records/record_list_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _QueueVideoPicker implements SurgeryVideoPicker {
  _QueueVideoPicker(this.results);

  final List<SelectedSurgeryVideo?> results;

  @override
  Future<SelectedSurgeryVideo?> pickVideo() async => results.removeAt(0);
}

void main() {
  late AppDatabase database;
  late Directory tempDirectory;

  setUp(() async {
    database = AppDatabase.memory();
    tempDirectory = await Directory.systemTemp.createTemp('new_record_flow_');
  });

  tearDown(() async {
    await database.close();
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  Future<void> pumpList(WidgetTester tester, SurgeryVideoPicker picker) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => database),
          surgeryVideoPickerProvider.overrideWithValue(picker),
        ],
        child: MaterialApp(
          home: RecordListScreen(
            newRecordScreenBuilder: (video) =>
                NewRecordScreen(initialVideo: video, enableVideoPreview: false),
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(seconds: 1));
  }

  Future<int> recordCount(WidgetTester tester) async {
    late int count;
    await tester.runAsync(() async {
      count = (await SurgeryRepository(
        database,
      ).watchableListSnapshot()).length;
    });
    return count;
  }

  testWidgets('最初の動画選択をキャンセルしても空症例を作成しない', (tester) async {
    await pumpList(tester, _QueueVideoPicker([null]));

    await tester.tap(find.text('新規症例'));
    await tester.pumpAndSettle();

    expect(find.byType(NewRecordScreen), findsNothing);
    expect(await recordCount(tester), 0);
  });

  testWidgets('動画選択後は日付と左右眼が未選択で破棄確認を表示する', (tester) async {
    final video = File('${tempDirectory.path}/first.mp4');
    await tester.runAsync(() => video.writeAsBytes(List<int>.filled(32, 1)));
    await pumpList(
      tester,
      _QueueVideoPicker([
        SelectedSurgeryVideo(path: video.path, displayName: 'first.mp4'),
      ]),
    );

    await tester.tap(find.text('新規症例'));
    await tester.pumpAndSettle();

    expect(find.byType(NewRecordScreen), findsOneWidget);
    expect(find.text('first.mp4'), findsOneWidget);
    expect(find.byKey(const Key('surgery-date-error')), findsNothing);
    expect(find.byKey(const Key('eye-side-error')), findsNothing);
    await tester.drag(find.byType(ListView).last, const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(find.text('未選択'), findsOneWidget);
    final register = tester.widget<ButtonStyleButton>(
      find.byKey(const Key('register-record-button')),
    );
    expect(register.onPressed, isNotNull);
    await tester.tap(find.byKey(const Key('register-record-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('surgery-date-error')), findsOneWidget);
    expect(find.byKey(const Key('eye-side-error')), findsOneWidget);
    expect(await recordCount(tester), 0);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('入力内容を破棄しますか？'), findsOneWidget);
    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();
    expect(find.byType(NewRecordScreen), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('破棄'));
    await tester.pumpAndSettle();
    expect(find.byType(NewRecordScreen), findsNothing);
    expect(await recordCount(tester), 0);
  });

  testWidgets('動画変更で日付と左右眼をリセットし変更キャンセルでは維持する', (tester) async {
    final first = File('${tempDirectory.path}/first.mp4');
    final second = File('${tempDirectory.path}/second.mp4');
    await tester.runAsync(() async {
      await first.writeAsBytes(List<int>.filled(32, 1));
      await second.writeAsBytes(List<int>.filled(32, 2));
    });
    final picker = _QueueVideoPicker([
      SelectedSurgeryVideo(path: first.path, displayName: 'first.mp4'),
      null,
      SelectedSurgeryVideo(path: second.path, displayName: 'second.mp4'),
    ]);
    await pumpList(tester, picker);
    await tester.tap(find.text('新規症例'));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView).last, const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.tap(find.text('手術日（必須）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('左眼'));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView).last, const Offset(0, 500));
    await tester.pumpAndSettle();
    await tester.tap(find.text('動画を変更'));
    await tester.pumpAndSettle();
    expect(find.text('first.mp4'), findsOneWidget);
    await tester.drag(find.byType(ListView).last, const Offset(0, -500));
    await tester.pumpAndSettle();
    final eyeSelector = find.byWidgetPredicate(
      (widget) => widget is SegmentedButton<EyeSide>,
    );
    expect(tester.widget<SegmentedButton<EyeSide>>(eyeSelector).selected, {
      EyeSide.left,
    });

    await tester.drag(find.byType(ListView).last, const Offset(0, 500));
    await tester.pumpAndSettle();
    await tester.tap(find.text('動画を変更'));
    await tester.pumpAndSettle();
    expect(find.text('second.mp4'), findsOneWidget);
    await tester.drag(find.byType(ListView).last, const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(find.textContaining('再確認してください'), findsOneWidget);
    await tester.drag(find.byType(ListView).last, const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(find.text('未選択'), findsOneWidget);
    expect(
      tester.widget<SegmentedButton<EyeSide>>(eyeSelector).selected,
      isEmpty,
    );
  });

  testWidgets('必須情報を入力すると症例登録ボタンが有効になる', (tester) async {
    final video = File('${tempDirectory.path}/surgery.mp4');
    await tester.runAsync(() => video.writeAsBytes(List<int>.filled(128, 3)));
    await pumpList(
      tester,
      _QueueVideoPicker([
        SelectedSurgeryVideo(path: video.path, displayName: 'surgery.mp4'),
      ]),
    );
    await tester.tap(find.text('新規症例'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).last, const Offset(0, -500));
    await tester.pumpAndSettle();

    await tester.tap(find.text('手術日（必須）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('右眼'));
    await tester.pumpAndSettle();

    final registerFinder = find.byKey(const Key('register-record-button'));
    expect(
      tester.widget<ButtonStyleButton>(registerFinder).onPressed,
      isNotNull,
    );
  });
}
