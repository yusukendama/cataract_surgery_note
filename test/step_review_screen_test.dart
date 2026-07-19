import 'package:cataract_surgery_note/src/data/app_database.dart';
import 'package:cataract_surgery_note/src/data/providers.dart';
import 'package:cataract_surgery_note/src/data/surgery_repository.dart';
import 'package:cataract_surgery_note/src/domain/surgery_models.dart';
import 'package:cataract_surgery_note/src/features/review/step_review_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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
        child: MaterialApp(home: StepReviewScreen(recordId: recordId)),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('11項目と症例メモの12タブと保存ボタンが表示される', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);

    await pumpScreen(tester, database, record.id);

    for (final step in surgicalStepsInDisplayOrder) {
      expect(find.widgetWithText(Tab, step.label), findsOneWidget);
    }
    expect(find.widgetWithText(Tab, '症例メモ'), findsOneWidget);
    expect(find.widgetWithText(Tab, '総手術時間'), findsOneWidget);
    expect(find.text('テノン嚢下麻酔'), findsNothing);
    expect(find.text('デキサート結膜下注射'), findsNothing);
    expect(find.text('保存'), findsOneWidget);
    expect(find.byType(ProcedureTimingCard), findsOneWidget);
  });

  testWidgets('タブ切替で該当工程のカードと症例メモ欄が表示される', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);

    await pumpScreen(tester, database, record.id);

    expect(
      find.descendant(
        of: find.byType(ProcedureTimingCard),
        matching: find.text('総手術時間'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(Tab, 'CCC'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(ProcedureTimingCard),
        matching: find.text('CCC'),
      ),
      findsOneWidget,
    );
    expect(find.text('自己評価・反省点'), findsOneWidget);
    expect(find.text('任意'), findsOneWidget);
    expect(find.widgetWithText(TextField, '反省点'), findsNothing);

    await tester.tap(find.text('自己評価・反省点'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '反省点'), findsOneWidget);

    await tester.ensureVisible(find.widgetWithText(Tab, '症例メモ'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(Tab, '症例メモ'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '症例全体のメモ'), findsOneWidget);
  });

  testWidgets('総手術時間と個別工程を並行して開始できる', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);

    await pumpScreen(tester, database, record.id);

    await tester.tap(find.byKey(const Key('procedure-start-button')));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(Tab, 'サイドポート作成'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('procedure-start-button')));
    await tester.pumpAndSettle();

    late SurgicalStepReview total;
    late SurgicalStepReview sidePort;
    await tester.runAsync(() async {
      final repository = SurgeryRepository(database);
      total = (await repository.getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.totalSurgeryTime,
      ))!;
      sidePort = (await repository.getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.sidePortCreation,
      ))!;
    });

    expect(total.isRunning, isTrue);
    expect(sidePort.isRunning, isTrue);
  });
}
