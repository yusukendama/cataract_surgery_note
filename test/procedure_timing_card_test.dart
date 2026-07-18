import 'package:cataract_surgery_note/src/domain/surgery_models.dart';
import 'package:cataract_surgery_note/src/features/review/step_review_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  SurgicalStepReview review({int? start, int? end}) {
    return SurgicalStepReview(
      id: 'id',
      surgeryRecordId: 'record',
      step: SurgicalStep.nucleusRemoval,
      startMilliseconds: start,
      endMilliseconds: end,
      rating: StepRating.unreviewed,
      reflection: '',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
  }

  Future<void> pumpCard(WidgetTester tester, SurgicalStepReview timing) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProcedureTimingCard(
            step: timing.step,
            timing: timing,
            isSaving: false,
            onStart: () {},
            onEnd: () {},
            onReset: () {},
          ),
        ),
      ),
    );
  }

  testWidgets('未開始時は開始ボタンだけを表示する', (tester) async {
    await pumpCard(tester, review());
    expect(find.text('開始'), findsOneWidget);
    expect(find.text('終了'), findsNothing);
    expect(find.text('再設定'), findsNothing);
  });

  testWidgets('計測中は終了ボタンと状態を表示する', (tester) async {
    await pumpCard(tester, review(start: 1000));
    expect(find.text('計測中'), findsOneWidget);
    expect(find.text('開始'), findsNothing);
    expect(find.text('終了'), findsOneWidget);
    expect(find.text('再設定'), findsNothing);
  });

  testWidgets('完了時は再設定だけと時刻・所要時間を表示する', (tester) async {
    await pumpCard(tester, review(start: 1000, end: 66000));
    expect(find.text('開始'), findsNothing);
    expect(find.text('終了'), findsNothing);
    expect(find.text('再設定'), findsOneWidget);
    expect(find.text('開始時刻：0:01.0'), findsOneWidget);
    expect(find.text('終了時刻：1:06.0'), findsOneWidget);
    expect(find.text('所要時間：1分05秒'), findsOneWidget);
  });

  testWidgets('開始時刻をタップするとonTapStartが呼ばれる', (tester) async {
    var tapped = false;
    final timing = review(start: 1000, end: 66000);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProcedureTimingCard(
            step: timing.step,
            timing: timing,
            isSaving: false,
            onStart: () {},
            onEnd: () {},
            onReset: () {},
            onTapStart: () => tapped = true,
          ),
        ),
      ),
    );

    await tester.tap(find.text('開始時刻：0:01.0'));
    expect(tapped, isTrue);
  });

  testWidgets('終了時刻をタップするとonTapEndが呼ばれる', (tester) async {
    var tapped = false;
    final timing = review(start: 1000, end: 66000);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProcedureTimingCard(
            step: timing.step,
            timing: timing,
            isSaving: false,
            onStart: () {},
            onEnd: () {},
            onReset: () {},
            onTapEnd: () => tapped = true,
          ),
        ),
      ),
    );

    await tester.tap(find.text('終了時刻：1:06.0'));
    expect(tapped, isTrue);
  });
}
