import 'package:cataract_surgery_note/src/domain/surgery_models.dart';
import 'package:cataract_surgery_note/src/features/review/step_review_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  SurgicalStepReview review({
    int? start,
    int? end,
    bool isSkipped = false,
    SurgicalStep step = SurgicalStep.nucleusRemoval,
  }) {
    return SurgicalStepReview(
      id: 'id',
      surgeryRecordId: 'record',
      step: step,
      startMilliseconds: start,
      endMilliseconds: end,
      isSkipped: isSkipped,
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
            onSkip: timing.step.isTotalSurgeryTime ? null : () {},
          ),
        ),
      ),
    );
  }

  testWidgets('未開始時は大きな開始ボタンと時間記録なし操作を表示する', (tester) async {
    await pumpCard(tester, review());
    final startButton = find.byKey(const Key('procedure-start-button'));
    expect(startButton, findsOneWidget);
    expect(tester.getSize(startButton).height, greaterThanOrEqualTo(48));
    expect(find.textContaining('開始時刻'), findsNothing);
    expect(find.text('この工程を終了'), findsNothing);
    expect(find.text('再設定'), findsNothing);
    expect(find.text('今回は時間を記録しない'), findsOneWidget);
  });

  testWidgets('計測中は大きな終了ボタンと状態を表示する', (tester) async {
    await pumpCard(tester, review(start: 1000));
    expect(find.text('計測中'), findsOneWidget);
    expect(find.text('この工程を開始'), findsNothing);
    final endButton = find.byKey(const Key('procedure-end-button'));
    expect(endButton, findsOneWidget);
    expect(tester.getSize(endButton).height, greaterThanOrEqualTo(48));
    expect(find.text('開始時刻：0:01.0'), findsOneWidget);
    expect(find.textContaining('終了時刻'), findsNothing);
    expect(find.text('再設定'), findsNothing);
    expect(find.text('今回は時間を記録しない'), findsOneWidget);
  });

  testWidgets('完了時は再設定だけと時刻・所要時間を表示する', (tester) async {
    await pumpCard(tester, review(start: 1000, end: 66000));
    expect(find.text('この工程を開始'), findsNothing);
    expect(find.text('この工程を終了'), findsNothing);
    expect(find.text('再設定'), findsOneWidget);
    expect(find.text('開始時刻：0:01.0'), findsOneWidget);
    expect(find.text('終了時刻：1:06.0'), findsOneWidget);
    expect(find.text('所要時間：1分05秒'), findsOneWidget);
    expect(find.text('今回は時間を記録しない'), findsNothing);
  });

  testWidgets('時間記録なしでは開始・終了を隠して再設定だけを表示する', (tester) async {
    await pumpCard(tester, review(isSkipped: true));

    expect(find.text('時間記録なし'), findsOneWidget);
    expect(find.text('この工程を開始'), findsNothing);
    expect(find.text('この工程を終了'), findsNothing);
    expect(find.text('今回は時間を記録しない'), findsNothing);
    expect(find.text('再設定'), findsOneWidget);
  });

  testWidgets('総手術時間には時間記録なし操作を表示しない', (tester) async {
    await pumpCard(tester, review(step: SurgicalStep.totalSurgeryTime));

    expect(find.text('この工程を開始'), findsOneWidget);
    expect(find.text('今回は時間を記録しない'), findsNothing);
  });

  testWidgets('時間記録なし操作でonSkipを呼ぶ', (tester) async {
    var called = false;
    final timing = review();
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
            onSkip: () => called = true,
          ),
        ),
      ),
    );

    await tester.tap(find.text('今回は時間を記録しない'));
    expect(called, isTrue);
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
