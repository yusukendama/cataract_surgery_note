import 'package:cataract_surgery_note/src/features/review/step_review_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('15秒移動と再生の3操作だけを表示する', (tester) async {
    var backwardCount = 0;
    var toggleCount = 0;
    var forwardCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VideoTransportControls(
            isPlaying: false,
            onSeekBackward: () => backwardCount++,
            onTogglePlayback: () => toggleCount++,
            onSeekForward: () => forwardCount++,
          ),
        ),
      ),
    );

    final backward = find.byKey(const Key('seek-backward-15-seconds'));
    final toggle = find.byKey(const Key('toggle-video-playback'));
    final forward = find.byKey(const Key('seek-forward-15-seconds'));

    expect(backward, findsOneWidget);
    expect(toggle, findsOneWidget);
    expect(forward, findsOneWidget);
    expect(find.text('15秒'), findsNWidgets(2));
    expect(find.textContaining('0.2秒'), findsNothing);

    await tester.tap(backward);
    await tester.tap(toggle);
    await tester.tap(forward);

    expect(backwardCount, 1);
    expect(toggleCount, 1);
    expect(forwardCount, 1);
  });

  testWidgets('再生中は一時停止操作を表示する', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VideoTransportControls(
            isPlaying: true,
            onSeekBackward: () {},
            onTogglePlayback: () {},
            onSeekForward: () {},
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.pause), findsOneWidget);
    expect(find.byTooltip('一時停止'), findsOneWidget);
  });
}
