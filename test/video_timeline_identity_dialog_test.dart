import 'package:cataract_surgery_note/src/features/video_import/video_timeline_identity_dialog.dart';
import 'package:cataract_surgery_note/src/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('no timeline identity is selected initially', (tester) async {
    final context = await _pumpHost(tester);
    final future = showVideoTimelineIdentityDialog(context: context);
    await tester.pumpAndSettle();

    final continueButton = tester.widget<FilledButton>(
      find.byKey(const Key('continue-with-timeline-identity')),
    );
    expect(continueButton.onPressed, isNull);

    final semantics = tester.ensureSemantics();
    expect(
      tester.getSemantics(find.text('選択した動画について確認してください')).headingLevel,
      1,
    );
    semantics.dispose();

    await tester.tap(find.text('キャンセル'));
    expect(await future, isNull);
  });

  testWidgets('same and unchanged declaration is returned explicitly', (
    tester,
  ) async {
    final context = await _pumpHost(tester);
    final future = showVideoTimelineIdentityDialog(context: context);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('timeline-identity-same-unchanged')));
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('continue-with-timeline-identity')),
          )
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const Key('continue-with-timeline-identity')));

    expect(await future, VideoTimelineIdentityDecision.sameUnchanged);
  });

  testWidgets('changed or unknown declaration warns and is returned', (
    tester,
  ) async {
    final context = await _pumpHost(tester);
    final future = showVideoTimelineIdentityDialog(context: context);
    await tester.pumpAndSettle();

    expect(find.textContaining('判断できない場合'), findsOneWidget);
    await tester.tap(
      find.byKey(const Key('timeline-identity-changed-or-unknown')),
    );
    await tester.pump();
    expect(find.textContaining('工程位置は消去されます'), findsOneWidget);
    await tester.tap(find.byKey(const Key('continue-with-timeline-identity')));

    expect(await future, VideoTimelineIdentityDecision.changedOrUnknown);
  });

  testWidgets('dialog remains scrollable on a narrow high-text-scale view', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 568),
            textScaler: TextScaler.linear(2),
          ),
          child: Builder(
            builder: (value) {
              context = value;
              return const Scaffold(body: SizedBox.expand());
            },
          ),
        ),
      ),
    );

    final future = showVideoTimelineIdentityDialog(context: context);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(Scrollable), findsWidgets);
    await tester.tap(find.text('キャンセル'));
    expect(await future, isNull);
  });
}

Future<BuildContext> _pumpHost(WidgetTester tester) async {
  late BuildContext context;
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: Builder(
        builder: (value) {
          context = value;
          return const Scaffold(body: SizedBox.expand());
        },
      ),
    ),
  );
  return context;
}
