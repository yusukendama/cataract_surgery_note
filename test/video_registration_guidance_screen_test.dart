import 'package:cataract_surgery_note/src/features/video_import/video_registration_guidance_screen.dart';
import 'package:cataract_surgery_note/src/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('offline guidance contains the required profile and warnings', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: const VideoRegistrationGuidanceScreen(),
      ),
    );

    expect(find.text('登録できる動画の目安'), findsOneWidget);
    expect(find.text('対応の目安'), findsOneWidget);
    expect(find.textContaining('H.264（AVC）'), findsOneWidget);
    expect(find.textContaining('8bit、4:2:0、progressive'), findsWidgets);

    await _scrollTo(tester, '医療情報の取り扱い');
    expect(find.textContaining('機微な医療情報'), findsOneWidget);
    expect(find.textContaining('承認していないWebサイト'), findsOneWidget);
    expect(find.textContaining('実際の患者動画'), findsOneWidget);

    await _scrollTo(tester, '工程位置について');
    expect(find.textContaining('同じファイルか判断できない動画'), findsOneWidget);
    expect(find.textContaining('既存の工程位置は消去されます'), findsOneWidget);

    await _scrollTo(tester, 'サポート範囲');
    expect(find.textContaining('第三者ツールの操作、契約、料金'), findsOneWidget);

    // The bundled screen has no browser, sharing, or external-app action.
    expect(find.byType(TextButton), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
  });

  testWidgets('page and section titles expose their heading levels', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: const VideoRegistrationGuidanceScreen(),
      ),
    );
    final semantics = tester.ensureSemantics();

    expect(tester.getSemantics(find.text('登録できる動画の目安')).headingLevel, 1);
    expect(tester.getSemantics(find.text('対応の目安')).headingLevel, 2);

    await _scrollTo(tester, '医療情報の取り扱い');
    expect(tester.getSemantics(find.text('医療情報の取り扱い')).headingLevel, 2);

    semantics.dispose();
  });

  testWidgets('guidance scrolls without overflow at narrow large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: const MediaQuery(
          data: MediaQueryData(
            size: Size(320, 568),
            textScaler: TextScaler.linear(2),
          ),
          child: VideoRegistrationGuidanceScreen(),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    await _scrollTo(tester, 'サポート範囲');
    expect(tester.takeException(), isNull);
    expect(find.text('サポート範囲'), findsOneWidget);
  });

  testWidgets('route helper opens the bundled screen', (tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Builder(
          builder: (value) {
            context = value;
            return const Scaffold(body: Text('入口'));
          },
        ),
      ),
    );

    final navigation = openVideoRegistrationGuidance(context);
    await tester.pumpAndSettle();
    expect(find.byType(VideoRegistrationGuidanceScreen), findsOneWidget);

    Navigator.of(tester.element(find.byType(VideoRegistrationGuidanceScreen)))
        .pop();
    await tester.pumpAndSettle();
    await navigation;
  });
}

Future<void> _scrollTo(WidgetTester tester, String text) async {
  await tester.scrollUntilVisible(
    find.text(text),
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}
