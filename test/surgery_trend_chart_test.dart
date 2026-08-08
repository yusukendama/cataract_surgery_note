import 'package:cataract_surgery_note/src/features/analysis/date_label_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('selectDateLabelIndices', () {
    test('症例が1件のときは先頭のみを返す', () {
      expect(
        selectDateLabelIndices(pointCount: 1, plotWidth: 240, minimumGap: 40),
        [0],
      );
    });

    test('全ラベルが収まるときは全症例分を返す', () {
      expect(
        selectDateLabelIndices(pointCount: 5, plotWidth: 240, minimumGap: 40),
        [0, 1, 2, 3, 4],
      );
    });

    test('先頭と末尾は常に含まれる', () {
      for (final pointCount in [2, 3, 5, 12, 30, 100, 365]) {
        final indices = selectDateLabelIndices(
          pointCount: pointCount,
          plotWidth: 240,
          minimumGap: 40,
        );
        expect(indices.first, 0, reason: 'pointCount=$pointCount で最初の症例が欠けている');
        expect(
          indices.last,
          pointCount - 1,
          reason: 'pointCount=$pointCount で最新の症例が欠けている',
        );
      }
    });

    test('採用したラベルの中心間距離は常に minimumGap 以上', () {
      const plotWidth = 240.0;
      const minimumGap = 40.0;
      for (final pointCount in [2, 3, 5, 12, 30, 100, 365]) {
        final indices = selectDateLabelIndices(
          pointCount: pointCount,
          plotWidth: plotWidth,
          minimumGap: minimumGap,
        );
        final step = plotWidth / (pointCount - 1);
        for (var i = 1; i < indices.length; i++) {
          final gap = (indices[i] - indices[i - 1]) * step;
          expect(
            gap,
            greaterThanOrEqualTo(minimumGap),
            reason: 'pointCount=$pointCount でラベルが重なる (gap=$gap)',
          );
        }
      }
    });

    test('返すインデックスは昇順かつ範囲内', () {
      final indices = selectDateLabelIndices(
        pointCount: 100,
        plotWidth: 240,
        minimumGap: 40,
      );
      expect(indices, orderedEquals(indices.toList()..sort()));
      expect(indices.toSet().length, indices.length);
      expect(indices.every((index) => index >= 0 && index < 100), isTrue);
    });

    test('症例数が多いと中間地点付近のラベルも残る', () {
      final indices = selectDateLabelIndices(
        pointCount: 50,
        plotWidth: 240,
        minimumGap: 40,
      );
      expect(indices.length, greaterThanOrEqualTo(3));
      final middle = indices.sublist(1, indices.length - 1);
      expect(middle.any((index) => index > 15 && index < 35), isTrue);
    });

    test('先頭と末尾すら並べられない幅では最新のみを返す', () {
      expect(
        selectDateLabelIndices(pointCount: 20, plotWidth: 30, minimumGap: 40),
        [19],
      );
    });
  });
}
