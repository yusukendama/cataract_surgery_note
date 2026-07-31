import 'package:cataract_surgery_note/src/features/review/step_review_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('5秒と15秒の4スキップ操作と再生操作を表示する', (tester) async {
    var backward5Count = 0;
    var forward5Count = 0;
    var backward15Count = 0;
    var forward15Count = 0;
    var toggleCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VideoTransportControls(
            isPlaying: false,
            onSeekBackward5: () => backward5Count++,
            onSeekForward5: () => forward5Count++,
            onSeekBackward15: () => backward15Count++,
            onSeekForward15: () => forward15Count++,
            onTogglePlayback: () => toggleCount++,
          ),
        ),
      ),
    );

    final backward5 = find.byKey(const Key('seek-backward-5-seconds'));
    final forward5 = find.byKey(const Key('seek-forward-5-seconds'));
    final backward15 = find.byKey(const Key('seek-backward-15-seconds'));
    final forward15 = find.byKey(const Key('seek-forward-15-seconds'));
    final toggle = find.byKey(const Key('toggle-video-playback'));

    expect(backward5, findsOneWidget);
    expect(forward5, findsOneWidget);
    expect(backward15, findsOneWidget);
    expect(forward15, findsOneWidget);
    expect(toggle, findsOneWidget);
    expect(find.text('5秒'), findsNWidgets(2));
    expect(find.text('15秒'), findsNWidgets(2));
    expect(find.textContaining('0.2秒'), findsNothing);

    final backward15Center = tester.getCenter(backward15);
    final backward5Center = tester.getCenter(backward5);
    final toggleCenter = tester.getCenter(toggle);
    final forward5Center = tester.getCenter(forward5);
    final forward15Center = tester.getCenter(forward15);

    expect(backward15Center.dy, toggleCenter.dy);
    expect(backward5Center.dy, toggleCenter.dy);
    expect(forward5Center.dy, toggleCenter.dy);
    expect(forward15Center.dy, toggleCenter.dy);
    expect(backward15Center.dx, lessThan(backward5Center.dx));
    expect(backward5Center.dx, lessThan(toggleCenter.dx));
    expect(toggleCenter.dx, lessThan(forward5Center.dx));
    expect(forward5Center.dx, lessThan(forward15Center.dx));
    expect(tester.getSize(backward5).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(forward5).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(backward15).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(forward15).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(toggle).height, greaterThanOrEqualTo(56));

    await tester.tap(backward5);
    await tester.tap(forward5);
    await tester.tap(backward15);
    await tester.tap(forward15);
    await tester.tap(toggle);

    expect(backward5Count, 1);
    expect(forward5Count, 1);
    expect(backward15Count, 1);
    expect(forward15Count, 1);
    expect(toggleCount, 1);
  });

  testWidgets('再生状態に応じて再生と一時停止を表示する', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VideoTransportControls(
            isPlaying: true,
            onSeekBackward5: () {},
            onSeekForward5: () {},
            onSeekBackward15: () {},
            onSeekForward15: () {},
            onTogglePlayback: () {},
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.pause), findsOneWidget);
    expect(find.byTooltip('一時停止'), findsOneWidget);

    final semantics = tester.ensureSemantics();
    expect(
      tester.getSemantics(find.byKey(const Key('toggle-video-playback'))).label,
      '一時停止',
    );
    semantics.dispose();
  });

  testWidgets('各操作の方向と秒数をSemanticsで識別できる', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VideoTransportControls(
            isPlaying: false,
            onSeekBackward5: () {},
            onSeekForward5: () {},
            onSeekBackward15: () {},
            onSeekForward15: () {},
            onTogglePlayback: () {},
          ),
        ),
      ),
    );

    expect(
      tester
          .getSemantics(find.byKey(const Key('seek-backward-5-seconds')))
          .label,
      '5秒戻る',
    );
    expect(
      tester
          .getSemantics(find.byKey(const Key('seek-forward-5-seconds')))
          .label,
      '5秒進む',
    );
    expect(
      tester
          .getSemantics(find.byKey(const Key('seek-backward-15-seconds')))
          .label,
      '15秒戻る',
    );
    expect(
      tester
          .getSemantics(find.byKey(const Key('seek-forward-15-seconds')))
          .label,
      '15秒進む',
    );
    expect(
      tester.getSemantics(find.byKey(const Key('toggle-video-playback'))).label,
      '再生',
    );
    semantics.dispose();
  });

  testWidgets('横幅288と大きな文字でも全操作へアクセスできる', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: 288,
                child: VideoTransportControls(
                  isPlaying: false,
                  onSeekBackward5: () {},
                  onSeekForward5: () {},
                  onSeekBackward15: () {},
                  onSeekForward15: () {},
                  onTogglePlayback: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('seek-backward-5-seconds')), findsOneWidget);
    expect(find.byKey(const Key('seek-forward-5-seconds')), findsOneWidget);
    expect(find.byKey(const Key('seek-backward-15-seconds')), findsOneWidget);
    expect(find.byKey(const Key('seek-forward-15-seconds')), findsOneWidget);
    expect(find.byKey(const Key('toggle-video-playback')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
