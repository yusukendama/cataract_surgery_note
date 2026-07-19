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

  testWidgets('12工程と症例メモの13タブと保存ボタンが表示される', (tester) async {
    final (database, record) = await createRecord(tester);
    addTearDown(database.close);

    await pumpScreen(tester, database, record.id);

    for (final step in surgicalStepsInDisplayOrder) {
      expect(find.widgetWithText(Tab, step.label), findsOneWidget);
    }
    expect(find.widgetWithText(Tab, '症例メモ'), findsOneWidget);
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
        matching: find.text('テノン嚢下麻酔'),
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
}
