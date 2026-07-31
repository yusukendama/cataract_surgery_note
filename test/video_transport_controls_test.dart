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

    expect(tester.getCenter(backward5).dy, tester.getCenter(toggle).dy);
    expect(tester.getCenter(forward5).dy, tester.getCenter(toggle).dy);
    expect(
      tester.getCenter(backward15).dy,
      greaterThan(tester.getCenter(toggle).dy),
    );
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

  testWidgets('横幅320と大きな文字でも全操作へアクセスできる', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: 320,
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
