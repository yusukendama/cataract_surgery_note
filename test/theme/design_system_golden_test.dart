import 'dart:math' as math;

import 'package:cataract_surgery_note/src/domain/surgery_models.dart';
import 'package:cataract_surgery_note/src/theme/app_localization.dart';
import 'package:cataract_surgery_note/src/theme/app_theme.dart';
import 'package:cataract_surgery_note/src/widgets/app_states.dart';
import 'package:cataract_surgery_note/src/widgets/video_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final fixture in _goldenFixtures) {
    testWidgets('design system ${fixture.name}', (tester) async {
      tester.view.devicePixelRatio = fixture.pixelRatio;
      tester.view.physicalSize = fixture.logicalSize * fixture.pixelRatio;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_DesignSystemPreview(fixture: fixture));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final semantics = tester.ensureSemantics();
      try {
        await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await expectLater(tester, meetsGuideline(textContrastGuideline));
        await expectLater(
          find.byKey(const Key('design-system-golden-root')),
          matchesGoldenFile('goldens/design_system/${fixture.name}.png'),
        );
        await _auditAllActionableSemantics(tester, fixture);
      } finally {
        semantics.dispose();
      }
    });
  }
}

Future<void> _auditAllActionableSemantics(
  WidgetTester tester,
  _GoldenFixture fixture,
) async {
  const expectedLabels = <String>{
    '症例全体のメモ',
    '右眼',
    '左眼',
    '保存',
    'もう一度試す',
    '新規症例',
  };
  final scale = fixture.pixelRatio;
  final safeViewport = Rect.fromLTRB(
    fixture.viewPadding.left * scale,
    fixture.viewPadding.top * scale,
    (fixture.logicalSize.width - fixture.viewPadding.right) * scale,
    (fixture.logicalSize.height -
            math.max(fixture.viewPadding.bottom, fixture.viewInsets.bottom)) *
        scale,
  );
  final seenLabels = <String>{};
  final accessibleLabels = <String>{};
  final lastGeometry = <String, Rect>{};
  final allGeometry = <String, Rect>{};
  final unlabeledNodes = <int>{};

  void collectAtCurrentPosition() {
    final renderView = tester.binding.renderViews.singleWhere(
      (view) => view.flutterView == tester.view,
    );
    final root = renderView.owner!.semanticsOwner!.rootSemanticsNode!;

    void visit(SemanticsNode node, Matrix4 parentTransform) {
      final transform = parentTransform.clone();
      if (node.transform case final nodeTransform?) {
        transform.multiply(nodeTransform);
      }
      final data = node.getSemanticsData();
      final isActionable =
          data.hasAction(SemanticsAction.tap) ||
          data.hasAction(SemanticsAction.longPress) ||
          data.hasAction(SemanticsAction.increase) ||
          data.hasAction(SemanticsAction.decrease);
      final rect = MatrixUtils.transformRect(transform, node.rect);
      if (isActionable && data.label.trim().isNotEmpty) {
        allGeometry[data.label.trim()] = rect;
      }
      if (isActionable &&
          !data.flagsCollection.isHidden &&
          rect.overlaps(safeViewport)) {
        final label = data.label.trim();
        if (label.isEmpty) {
          unlabeledNodes.add(node.id);
        } else {
          seenLabels.add(label);
          lastGeometry[label] = rect;
          final fullyInside =
              rect.left >= safeViewport.left - 0.01 &&
              rect.top >= safeViewport.top - 0.01 &&
              rect.right <= safeViewport.right + 0.01 &&
              rect.bottom <= safeViewport.bottom + 0.01;
          if (fullyInside &&
              rect.width >= 44 * scale &&
              rect.height >= 44 * scale) {
            accessibleLabels.add(label);
          }
        }
      }
      node.visitChildren((child) {
        visit(child, transform);
        return true;
      });
    }

    visit(root, Matrix4.identity());
  }

  final scrollable = find.byType(Scrollable).first;
  final position = tester.state<ScrollableState>(scrollable).position;
  final maxExtent = position.maxScrollExtent;
  for (var offset = 0.0; offset < maxExtent; offset += 40) {
    position.jumpTo(offset);
    await tester.pumpAndSettle();
    collectAtCurrentPosition();
  }
  position.jumpTo(maxExtent);
  await tester.pumpAndSettle();
  collectAtCurrentPosition();

  expect(
    unlabeledNodes,
    isEmpty,
    reason: 'Unlabeled actionable Semantics nodes',
  );
  expect(
    seenLabels.containsAll(expectedLabels),
    isTrue,
    reason:
        'Missing actionable nodes: ${expectedLabels.difference(seenLabels)} '
        'from $allGeometry',
  );
  final unreachable = seenLabels.difference(accessibleLabels);
  expect(
    unreachable,
    isEmpty,
    reason:
        'Actionable nodes never reached 44×44 inside Safe Area: '
        '${<String, Rect>{for (final label in unreachable) label: lastGeometry[label]!}}',
  );
}

class _GoldenFixture {
  const _GoldenFixture({
    required this.name,
    required this.logicalSize,
    required this.brightness,
    required this.textScale,
    required this.viewPadding,
    this.viewInsets = EdgeInsets.zero,
    this.pixelRatio = 1,
  });

  final String name;
  final Size logicalSize;
  final Brightness brightness;
  final double textScale;
  final EdgeInsets viewPadding;
  final EdgeInsets viewInsets;
  final double pixelRatio;
}

const _goldenFixtures = <_GoldenFixture>[
  _GoldenFixture(
    name: 'phone_portrait_light_text_1',
    logicalSize: Size(320, 568),
    brightness: Brightness.light,
    textScale: 1,
    viewPadding: EdgeInsets.fromLTRB(0, 59, 0, 34),
  ),
  _GoldenFixture(
    name: 'phone_portrait_dark_text_2',
    logicalSize: Size(320, 568),
    brightness: Brightness.dark,
    textScale: 2,
    viewPadding: EdgeInsets.fromLTRB(0, 59, 0, 34),
  ),
  _GoldenFixture(
    name: 'phone_landscape_light_text_2_keyboard',
    logicalSize: Size(568, 320),
    brightness: Brightness.light,
    textScale: 2,
    viewPadding: EdgeInsets.fromLTRB(59, 0, 21, 21),
    viewInsets: EdgeInsets.only(bottom: 160),
  ),
  _GoldenFixture(
    name: 'large_phone_portrait_dark_text_1',
    logicalSize: Size(430, 932),
    brightness: Brightness.dark,
    textScale: 1,
    viewPadding: EdgeInsets.fromLTRB(0, 59, 0, 34),
  ),
  _GoldenFixture(
    name: 'ipad_portrait_light_text_2',
    logicalSize: Size(768, 1024),
    brightness: Brightness.light,
    textScale: 2,
    viewPadding: EdgeInsets.fromLTRB(0, 24, 0, 20),
  ),
  _GoldenFixture(
    name: 'ipad_landscape_dark_text_2_dpr_3',
    logicalSize: Size(1024, 768),
    brightness: Brightness.dark,
    textScale: 2,
    viewPadding: EdgeInsets.fromLTRB(0, 24, 0, 20),
    pixelRatio: 3,
  ),
  _GoldenFixture(
    name: 'ipad_compact_light_text_2_keyboard',
    logicalSize: Size(320, 1024),
    brightness: Brightness.light,
    textScale: 2,
    viewPadding: EdgeInsets.fromLTRB(0, 24, 0, 20),
    viewInsets: EdgeInsets.only(bottom: 300),
  ),
  _GoldenFixture(
    name: 'ipad_compact_dark_text_2_keyboard',
    logicalSize: Size(320, 1024),
    brightness: Brightness.dark,
    textScale: 2,
    viewPadding: EdgeInsets.fromLTRB(0, 24, 0, 20),
    viewInsets: EdgeInsets.only(bottom: 300),
  ),
];

class _DesignSystemPreview extends StatelessWidget {
  const _DesignSystemPreview({required this.fixture});

  final _GoldenFixture fixture;

  @override
  Widget build(BuildContext context) {
    final padding = EdgeInsets.fromLTRB(
      math.max(fixture.viewPadding.left - fixture.viewInsets.left, 0),
      math.max(fixture.viewPadding.top - fixture.viewInsets.top, 0),
      math.max(fixture.viewPadding.right - fixture.viewInsets.right, 0),
      math.max(fixture.viewPadding.bottom - fixture.viewInsets.bottom, 0),
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: fixture.brightness == Brightness.dark
          ? ThemeMode.dark
          : ThemeMode.light,
      supportedLocales: appSupportedLocales,
      localizationsDelegates: appLocalizationsDelegates,
      localeResolutionCallback: resolveAppLocale,
      builder: (context, child) => MediaQuery(
        data: MediaQueryData(
          size: fixture.logicalSize,
          devicePixelRatio: fixture.pixelRatio,
          textScaler: TextScaler.linear(fixture.textScale),
          platformBrightness: fixture.brightness,
          viewPadding: fixture.viewPadding,
          viewInsets: fixture.viewInsets,
          padding: padding,
          systemGestureInsets: fixture.viewPadding,
        ),
        child: child!,
      ),
      home: const RepaintBoundary(
        key: Key('design-system-golden-root'),
        child: _PreviewScreen(),
      ),
    );
  }
}

class _PreviewScreen extends StatelessWidget {
  const _PreviewScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('白内障執刀ノート')),
      body: SafeArea(
        child: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.all(16),
          children: [
            const AppEmptyState(
              icon: Icons.note_add_outlined,
              title: 'まだ症例がありません',
              message: '手術動画を選び、工程時間と振り返りを記録しましょう。',
            ),
            const SizedBox(height: 16),
            const VideoSurface(
              padding: EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.videocam_outlined),
                  SizedBox(width: 8),
                  Expanded(child: Text('選択した動画を確認できます')),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const TextField(
              key: Key('golden-input'),
              decoration: InputDecoration(labelText: '症例全体のメモ'),
            ),
            const SizedBox(height: 16),
            SegmentedButton<EyeSide>(
              key: const Key('golden-eye-side'),
              segments: const [
                ButtonSegment(value: EyeSide.right, label: Text('右眼')),
                ButtonSegment(value: EyeSide.left, label: Text('左眼')),
              ],
              selected: const {EyeSide.right},
              onSelectionChanged: (_) {},
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('golden-save'),
              onPressed: () {},
              icon: const Icon(Icons.save),
              label: const Text('保存'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('golden-retry'),
              onPressed: () {},
              icon: const Icon(Icons.refresh),
              label: const Text('もう一度試す'),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('golden-fab'),
        onPressed: () {},
        icon: const Icon(Icons.add),
        label: const Text('新規症例'),
      ),
    );
  }
}
