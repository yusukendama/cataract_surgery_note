import 'package:cataract_surgery_note/src/domain/ccc_review_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const rules = CccReviewRules();

  test('CCC所要時間を計算する', () {
    final duration = rules.calculateDuration(
      startMilliseconds: 1000,
      endMilliseconds: 4500,
    );

    expect(duration, const Duration(milliseconds: 3500));
  });

  test('開始または終了がnullの場合は所要時間を返さない', () {
    expect(
      rules.calculateDuration(startMilliseconds: null, endMilliseconds: 1000),
      isNull,
    );
    expect(
      rules.calculateDuration(startMilliseconds: 1000, endMilliseconds: null),
      isNull,
    );
  });

  test('終了が開始以前の場合はバリデーションエラーにする', () {
    expect(
      rules.validateRange(startMilliseconds: 2000, endMilliseconds: 2000),
      isNotNull,
    );
    expect(
      rules.validateRange(startMilliseconds: 3000, endMilliseconds: 2000),
      isNotNull,
    );
  });
}
