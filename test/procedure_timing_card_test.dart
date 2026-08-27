import 'package:cataract_surgery_note/src/domain/procedure_arrival_time.dart';
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

  Future<void> pumpCard(
    WidgetTester tester,
    SurgicalStepReview timing, {
    ProcedureArrivalTimeResult? arrivalTime,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProcedureTimingCard(
            step: timing.step,
            timing: timing,
            arrivalTime:
                arrivalTime ??
                (timing.step.isTotalSurgeryTime
                    ? const ProcedureArrivalTimeResult.status(
                        ProcedureArrivalTimeStatus.notApplicable,
                      )
                    : const ProcedureArrivalTimeResult.available(
                        Duration(seconds: 3),
                      )),
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
            arrivalTime: const ProcedureArrivalTimeResult.available(
              Duration(seconds: 3),
            ),
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
            arrivalTime: const ProcedureArrivalTimeResult.available(
              Duration(seconds: 3),
            ),
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
            arrivalTime: const ProcedureArrivalTimeResult.available(
              Duration(seconds: 3),
            ),
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

  testWidgets('完了工程へ工程到達時間を所要時間と併記する', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpCard(
      tester,
      review(start: 250000, end: 380000),
      arrivalTime: const ProcedureArrivalTimeResult.available(
        Duration(minutes: 3, seconds: 40),
      ),
    );

    expect(find.text('所要時間：2分10秒'), findsOneWidget);
    expect(find.text('開始まで：3分40秒'), findsOneWidget);
    expect(
      tester.getSemantics(find.text('開始まで：3分40秒')).label,
      '手術開始から3分40秒で開始',
    );
    semantics.dispose();
  });

  testWidgets('計測中でも工程到達時間を表示する', (tester) async {
    await pumpCard(
      tester,
      review(start: 250000),
      arrivalTime: const ProcedureArrivalTimeResult.available(
        Duration(minutes: 3, seconds: 40),
      ),
    );

    expect(find.text('計測中'), findsOneWidget);
    expect(find.text('開始まで：3分40秒'), findsOneWidget);
    expect(find.byKey(const Key('procedure-end-button')), findsOneWidget);
  });

  testWidgets('未登録・時間記録なし・総手術開始未登録を区別する', (tester) async {
    await pumpCard(
      tester,
      review(),
      arrivalTime: const ProcedureArrivalTimeResult.status(
        ProcedureArrivalTimeStatus.stepStartMissing,
      ),
    );
    expect(find.text('開始まで：未登録'), findsOneWidget);

    await pumpCard(
      tester,
      review(isSkipped: true),
      arrivalTime: const ProcedureArrivalTimeResult.status(
        ProcedureArrivalTimeStatus.skipped,
      ),
    );
    expect(find.text('開始まで：時間記録なし'), findsOneWidget);

    await pumpCard(
      tester,
      review(start: 250000),
      arrivalTime: const ProcedureArrivalTimeResult.status(
        ProcedureArrivalTimeStatus.totalSurgeryStartMissing,
      ),
    );
    expect(find.text('開始まで：—'), findsOneWidget);
    expect(find.text('「総手術時間」の開始位置を登録すると「開始まで」が表示されます。'), findsOneWidget);
  });

  testWidgets('不整合は負値でなく状態別の要確認表示とSemanticsを使う', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpCard(
      tester,
      review(start: 50000),
      arrivalTime: const ProcedureArrivalTimeResult.status(
        ProcedureArrivalTimeStatus.beforeTotalSurgeryStart,
      ),
    );

    expect(find.text('開始まで：要確認'), findsOneWidget);
    expect(find.text('工程開始位置を確認してください'), findsOneWidget);
    expect(find.textContaining('-'), findsNothing);
    expect(
      tester.getSemantics(find.text('開始まで：要確認')).label,
      '工程到達時間。工程開始位置を確認してください。',
    );
    semantics.dispose();
  });

  testWidgets('総手術時間カードへ開始までを表示しない', (tester) async {
    await pumpCard(
      tester,
      review(step: SurgicalStep.totalSurgeryTime, start: 30000, end: 400000),
      arrivalTime: const ProcedureArrivalTimeResult.status(
        ProcedureArrivalTimeStatus.notApplicable,
      ),
    );

    expect(find.textContaining('開始まで'), findsNothing);
    expect(find.text('所要時間：6分10秒'), findsOneWidget);
  });
}
