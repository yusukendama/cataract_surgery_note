import 'dart:convert';
import 'dart:io';

import 'package:cataract_surgery_note/src/data/app_database.dart';
import 'package:cataract_surgery_note/src/data/providers.dart';
import 'package:cataract_surgery_note/src/data/surgery_repository.dart';
import 'package:cataract_surgery_note/src/data/video_import_models.dart';
import 'package:cataract_surgery_note/src/data/video_storage_repository.dart';
import 'package:cataract_surgery_note/src/domain/surgery_models.dart';
import 'package:cataract_surgery_note/src/features/analysis/analysis_screen.dart';
import 'package:cataract_surgery_note/src/features/analysis/surgery_trend_chart.dart';
import 'package:cataract_surgery_note/src/features/review/step_review_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:video_player/video_player.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('グラフで症例選択後に詳細ボタンから工程位置へseekして停止する', (tester) async {
    await initializeDateFormatting('ja_JP');
    final fixtureDirectory = await Directory.systemTemp.createTemp(
      'cataract-direct-jump-',
    );
    final fixture = File('${fixtureDirectory.path}/direct_jump_fixture.mp4');
    await fixture.writeAsBytes(
      base64Decode(_fixtureBase64.replaceAll(RegExp(r'\s'), '')),
      flush: true,
    );
    final database = AppDatabase.memory();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await database.close();
      if (await fixtureDirectory.exists()) {
        await fixtureDirectory.delete(recursive: true);
      }
    });
    final repository = SurgeryRepository(database);
    const expectedMilliseconds = 1200;
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 8, 23),
      eyeSide: EyeSide.right,
    );
    final videoPath = 'videos/${record.id}/direct_jump_fixture.mp4';
    await repository.updateVideoReferenceIfCurrent(
      surgeryRecordId: record.id,
      expectedVideoPath: null,
      videoPath: videoPath,
      videoDisplayName: 'direct_jump_fixture.mp4',
    );
    final review = await repository.ensureStepReview(
      surgeryRecordId: record.id,
      step: SurgicalStep.capsulorhexis,
    );
    await repository.saveStepTiming(
      review: review.copyWith(
        startMilliseconds: expectedMilliseconds,
        endMilliseconds: 2200,
      ),
      expectedVideoPath: videoPath,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => database),
          surgeryRepositoryProvider.overrideWithValue(repository),
          videoStorageRepositoryProvider.overrideWithValue(
            _FixtureVideoStorage(fixture),
          ),
        ],
        child: const MaterialApp(home: AnalysisScreen()),
      ),
    );

    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('analysis-metric-selector'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(find.byKey(const Key('analysis-metric-selector')));
    await tester.pumpAndSettle();
    final cccMetric = find.byKey(
      Key('analysis-metric-${SurgicalStep.capsulorhexis.storageId}'),
    );
    if (cccMetric.evaluate().isEmpty) {
      await tester.dragUntilVisible(
        cccMetric,
        find.byType(ListView).last,
        const Offset(0, -200),
      );
    }
    await tester.tap(cccMetric);
    await tester.pumpAndSettle();

    final chart = find.byKey(const Key('analysis-chart-interaction'));
    await tester.ensureVisible(chart);
    await tester.pump();
    await tester.tapAt(_paintedPointCenter(tester, record.id));
    await tester.pump();

    expect(find.byType(AnalysisScreen), findsOneWidget);
    expect(find.byType(StepReviewScreen), findsNothing);
    expect(find.byType(VideoPlayer), findsNothing);

    final detailButton = find.byKey(const Key('analysis-open-selected'));
    await tester.dragUntilVisible(
      detailButton,
      find.byKey(const Key('analysis-content')),
      const Offset(0, -200),
    );
    await tester.pump();
    await tester.tap(detailButton);

    await _pumpUntil(
      tester,
      () =>
          find.byType(StepReviewScreen).evaluate().isNotEmpty &&
          find.text('CCCの開始位置へ移動しました').evaluate().isNotEmpty,
      maximumAttempts: 200,
    );

    final visibleTexts = tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data)
        .whereType<String>()
        .toList(growable: false);
    expect(
      find.text('CCCの開始位置へ移動しました'),
      findsWidgets,
      reason: 'Visible text after waiting: $visibleTexts',
    );
    final slider = tester.widget<Slider>(
      find.byKey(const Key('review-video-slider')),
    );
    expect((slider.value - expectedMilliseconds).abs(), lessThanOrEqualTo(100));
    final videoPlayer = tester.widget<VideoPlayer>(find.byType(VideoPlayer));
    final nativePosition = await tester.runAsync(
      () => videoPlayer.controller.position,
    );
    expect(nativePosition, isNotNull);
    expect(
      (nativePosition!.inMilliseconds - expectedMilliseconds).abs(),
      lessThanOrEqualTo(100),
    );
    expect(videoPlayer.controller.value.isPlaying, isFalse);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    final nativePositionAfterPauseWindow = await tester.runAsync(
      () => videoPlayer.controller.position,
    );
    expect(nativePositionAfterPauseWindow, isNotNull);
    expect(
      (nativePositionAfterPauseWindow!.inMilliseconds -
              nativePosition.inMilliseconds)
          .abs(),
      lessThanOrEqualTo(100),
    );
    expect(
      (nativePositionAfterPauseWindow.inMilliseconds - expectedMilliseconds)
          .abs(),
      lessThanOrEqualTo(100),
    );
    expect(videoPlayer.controller.value.isPlaying, isFalse);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    expect(find.byIcon(Icons.pause), findsNothing);
  }, skip: !Platform.isIOS);
}

Offset _paintedPointCenter(WidgetTester tester, String recordId) {
  final paint = find.descendant(
    of: find.byType(SurgeryTrendChart),
    matching: find.byWidgetPredicate(
      (widget) => widget is CustomPaint && widget.painter is TrendChartPainter,
    ),
  );
  final painter =
      tester.widget<CustomPaint>(paint).painter! as TrendChartPainter;
  final local = painter.layout.points
      .singleWhere((point) => point.point.recordId == recordId)
      .offset;
  return tester.getTopLeft(paint) + local;
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int maximumAttempts = 100,
}) async {
  for (var attempt = 0; attempt < maximumAttempts && !condition(); attempt++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(condition(), isTrue, reason: '非同期条件が期限内に成立しませんでした。');
}

class _FixtureVideoStorage implements VideoStorageRepository {
  const _FixtureVideoStorage(this.fixture);

  final File fixture;

  @override
  Future<void> deleteVideo(String relativePath) async {}

  @override
  Future<void> deleteVideosForRecord(String surgeryRecordId) async {}

  @override
  Future<StoredVideo> importVideo({
    required String surgeryRecordId,
    required VerifiedVideoCandidate candidate,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) {
    throw UnsupportedError('Integration fixture is read-only.');
  }

  @override
  Future<File> resolveVideo(String relativePath) async => fixture;
}

// Three-second, 320×180, H.264/yuv420p MP4 generated solely as a deterministic
// local test fixture. Keeping it encoded in source avoids external downloads
// and exercises the same file-backed iOS video_player path as production.
const _fixtureBase64 = '''
AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAd0bW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAC7gAAQAAAQAA
AAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAA
Bp50cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAC7gAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAA
AAAAAAAAAAAAAABAAAAAAUAAAAC0AAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAu4AAAEAAABAAAAAAYWbWRpYQAAACBtZGhk
AAAAAAAAAAAAAAAAAAA8AAAAtABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAAFwW1p
bmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAABYFzdGJsAAAAwXN0c2QA
AAAAAAAAAQAAALFhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAUAAtABIAAAASAAAAAAAAAABFUxhdmM2Mi4yOC4xMDIgbGli
eDI2NAAAAAAAAAAAAAAAGP//AAAAN2F2Y0MBZAAN/+EAGmdkAA2s2UFBn58BEAAAAwAQAAADA8DxQplgAQAGaOvjyyLA/fj4AAAA
ABBwYXNwAAAAAQAAAAEAAAAUYnRydAAAAAAAABZlAAAAAAAAABhzdHRzAAAAAAAAAAEAAABaAAACAAAAABRzdHNzAAAAAAAAAAEA
AAABAAAC4GN0dHMAAAAAAAAAWgAAAAEAAAQAAAAAAQAACgAAAAABAAAEAAAAAAEAAAAAAAAAAQAAAgAAAAABAAAKAAAAAAEAAAQA
AAAAAQAAAAAAAAABAAACAAAAAAEAAAoAAAAAAQAABAAAAAABAAAAAAAAAAEAAAIAAAAAAQAACgAAAAABAAAEAAAAAAEAAAAAAAAA
AQAAAgAAAAABAAAKAAAAAAEAAAQAAAAAAQAAAAAAAAABAAACAAAAAAEAAAoAAAAAAQAABAAAAAABAAAAAAAAAAEAAAIAAAAAAQAA
CgAAAAABAAAEAAAAAAEAAAAAAAAAAQAAAgAAAAABAAAKAAAAAAEAAAQAAAAAAQAAAAAAAAABAAACAAAAAAEAAAoAAAAAAQAABAAA
AAABAAAAAAAAAAEAAAIAAAAAAQAACgAAAAABAAAEAAAAAAEAAAAAAAAAAQAAAgAAAAABAAAKAAAAAAEAAAQAAAAAAQAAAAAAAAAB
AAACAAAAAAEAAAoAAAAAAQAABAAAAAABAAAAAAAAAAEAAAIAAAAAAQAACgAAAAABAAAEAAAAAAEAAAAAAAAAAQAAAgAAAAABAAAK
AAAAAAEAAAQAAAAAAQAAAAAAAAABAAACAAAAAAEAAAoAAAAAAQAABAAAAAABAAAAAAAAAAEAAAIAAAAAAQAACgAAAAABAAAEAAAA
AAEAAAAAAAAAAQAAAgAAAAABAAAKAAAAAAEAAAQAAAAAAQAAAAAAAAABAAACAAAAAAEAAAoAAAAAAQAABAAAAAABAAAAAAAAAAEA
AAIAAAAAAQAACgAAAAABAAAEAAAAAAEAAAAAAAAAAQAAAgAAAAABAAAKAAAAAAEAAAQAAAAAAQAAAAAAAAABAAACAAAAAAEAAAoA
AAAAAQAABAAAAAABAAAAAAAAAAEAAAIAAAAAAQAACgAAAAABAAAEAAAAAAEAAAAAAAAAAQAAAgAAAAABAAAEAAAAABxzdHNjAAAA
AAAAAAEAAAABAAAAWgAAAAEAAAF8c3RzegAAAAAAAAAAAAAAWgAAAu4AAAAQAAAADQAAAA0AAAANAAAAFgAAAA8AAAANAAAADQAA
ABYAAAAPAAAADQAAAA0AAAAWAAAADwAAAA0AAAANAAAAFgAAAA8AAAANAAAADQAAABYAAAAPAAAADQAAAA0AAAAWAAAADwAAAA0A
AAANAAAAFgAAAA8AAAANAAAADQAAABYAAAAPAAAADQAAAA0AAAAWAAAADwAAAA0AAAANAAAAFgAAAA8AAAANAAAADQAAABYAAAAP
AAAADQAAAA0AAAAWAAAADwAAAA0AAAANAAAAFgAAAA8AAAANAAAADQAAABYAAAAPAAAADQAAAA0AAAAWAAAADwAAAA0AAAANAAAA
FgAAAA8AAAANAAAADQAAABYAAAAPAAAADQAAAA0AAAAWAAAADwAAAA0AAAANAAAAFgAAAA8AAAANAAAADQAAABYAAAAPAAAADQAA
AA0AAAAWAAAADwAAAA0AAAANAAAAFgAAABRzdGNvAAAAAAAAAAEAAAekAAAAYnVkdGEAAABabWV0YQAAAAAAAAAhaGRscgAAAAAA
AAAAbWRpcmFwcGwAAAAAAAAAAAAAAAAtaWxzdAAAACWpdG9vAAAAHWRhdGEAAAABAAAAAExhdmY2Mi4xMi4xMDIAAAAIZnJlZQAA
CG5tZGF0AAACrgYF//+q3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NSByMzIyMiBiMzU2MDVhIC0gSC4yNjQvTVBFRy00
IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4ub3JnL3gyNjQuaHRtbCAtIG9wdGlv
bnM6IGNhYmFjPTEgcmVmPTMgZGVibG9jaz0xOjA6MCBhbmFseXNlPTB4MzoweDExMyBtZT1oZXggc3VibWU9NyBwc3k9MSBwc3lf
cmQ9MS4wMDowLjAwIG1peGVkX3JlZj0xIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MSA4eDhkY3Q9MSBjcW09MCBk
ZWFkem9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3FwX29mZnNldD0tMiB0aHJlYWRzPTYgbG9va2FoZWFkX3RocmVhZHM9
MSBzbGljZWRfdGhyZWFkcz0wIG5yPTAgZGVjaW1hdGU9MSBpbnRlcmxhY2VkPTAgYmx1cmF5X2NvbXBhdD0wIGNvbnN0cmFpbmVk
X2ludHJhPTAgYmZyYW1lcz0zIGJfcHlyYW1pZD0yIGJfYWRhcHQ9MSBiX2JpYXM9MCBkaXJlY3Q9MSB3ZWlnaHRiPTEgb3Blbl9n
b3A9MCB3ZWlnaHRwPTIga2V5aW50PTI1MCBrZXlpbnRfbWluPTI1IHNjZW5lY3V0PTQwIGludHJhX3JlZnJlc2g9MCByY19sb29r
YWhlYWQ9NDAgcmM9Y3JmIG1idHJlZT0xIGNyZj0yMy4wIHFjb21wPTAuNjAgcXBtaW49MCBxcG1heD02OSBxcHN0ZXA9NCBpcF9y
YXRpbz0xLjQwIGFxPTE6MS4wMACAAAAAOGWIhAA3//728P4FNlYEUJcRzeidMx+/Fbi6NDe9zgACrU8Qb7gsE2lPYBBAAAGfEd0S
uCykEB2RAAAADEGaJGxDf/6nhAAD/AAAAAlBnkJ4hX8AA1MAAAAJAZ5hdEJ/AAQ8AAAACQGeY2pCfwAEPQAAABJBmmhJqEFomUwI
b//+p4QAA/0AAAALQZ6GRREsK/8AA1MAAAAJAZ6ldEJ/AAQ9AAAACQGep2pCfwAEPAAAABJBmqxJqEFsmUwIb//+p4QAA/wAAAAL
QZ7KRRUsK/8AA1MAAAAJAZ7pdEJ/AAQ8AAAACQGe62pCfwAEPAAAABJBmvBJqEFsmUwIb//+p4QAA/0AAAALQZ8ORRUsK/8AA1MA
AAAJAZ8tdEJ/AAQ9AAAACQGfL2pCfwAEPAAAABJBmzRJqEFsmUwIb//+p4QAA/wAAAALQZ9SRRUsK/8AA1MAAAAJAZ9xdEJ/AAQ8
AAAACQGfc2pCfwAEPAAAABJBm3hJqEFsmUwIb//+p4QAA/0AAAALQZ+WRRUsK/8AA1IAAAAJAZ+1dEJ/AAQ9AAAACQGft2pCfwAE
PQAAABJBm7xJqEFsmUwIb//+p4QAA/wAAAALQZ/aRRUsK/8AA1MAAAAJAZ/5dEJ/AAQ8AAAACQGf+2pCfwAEPQAAABJBm+BJqEFs
mUwIb//+p4QAA/0AAAALQZ4eRRUsK/8AA1IAAAAJAZ49dEJ/AAQ8AAAACQGeP2pCfwAEPQAAABJBmiRJqEFsmUwIb//+p4QAA/wA
AAALQZ5CRRUsK/8AA1MAAAAJAZ5hdEJ/AAQ8AAAACQGeY2pCfwAEPQAAABJBmmhJqEFsmUwIb//+p4QAA/0AAAALQZ6GRRUsK/8A
A1MAAAAJAZ6ldEJ/AAQ9AAAACQGep2pCfwAEPAAAABJBmqxJqEFsmUwIb//+p4QAA/wAAAALQZ7KRRUsK/8AA1MAAAAJAZ7pdEJ/
AAQ8AAAACQGe62pCfwAEPAAAABJBmvBJqEFsmUwIb//+p4QAA/0AAAALQZ8ORRUsK/8AA1MAAAAJAZ8tdEJ/AAQ9AAAACQGfL2pC
fwAEPAAAABJBmzRJqEFsmUwIb//+p4QAA/wAAAALQZ9SRRUsK/8AA1MAAAAJAZ9xdEJ/AAQ8AAAACQGfc2pCfwAEPAAAABJBm3hJ
qEFsmUwIb//+p4QAA/0AAAALQZ+WRRUsK/8AA1IAAAAJAZ+1dEJ/AAQ9AAAACQGft2pCfwAEPQAAABJBm7xJqEFsmUwIb//+p4QA
A/wAAAALQZ/aRRUsK/8AA1MAAAAJAZ/5dEJ/AAQ8AAAACQGf+2pCfwAEPQAAABJBm+BJqEFsmUwIb//+p4QAA/0AAAALQZ4eRRUs
K/8AA1IAAAAJAZ49dEJ/AAQ8AAAACQGeP2pCfwAEPQAAABJBmiRJqEFsmUwIb//+p4QAA/wAAAALQZ5CRRUsK/8AA1MAAAAJAZ5h
dEJ/AAQ8AAAACQGeY2pCfwAEPQAAABJBmmhJqEFsmUwIb//+p4QAA/0AAAALQZ6GRRUsK/8AA1MAAAAJAZ6ldEJ/AAQ9AAAACQGe
p2pCfwAEPAAAABJBmqxJqEFsmUwIb//+p4QAA/wAAAALQZ7KRRUsK/8AA1MAAAAJAZ7pdEJ/AAQ8AAAACQGe62pCfwAEPAAAABJB
mvBJqEFsmUwIb//+p4QAA/0AAAALQZ8ORRUsK/8AA1MAAAAJAZ8tdEJ/AAQ9AAAACQGfL2pCfwAEPAAAABJBmzRJqEFsmUwIZ//+
nhAAD5gAAAALQZ9SRRUsK/8AA1MAAAAJAZ9xdEJ/AAQ8AAAACQGfc2pCfwAEPAAAABJBm3hJqEFsmUwIV//+OEAAPSEAAAALQZ+W
RRUsK/8AA1IAAAAJAZ+1dEJ/AAQ9AAAACQGft2pCfwAEPQAAABJBm7lJqEFsmUwIT//98QAAl4A=
''';
