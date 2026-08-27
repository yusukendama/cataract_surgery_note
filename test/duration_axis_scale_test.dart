import 'package:cataract_surgery_note/src/domain/surgery_models.dart';
import 'package:cataract_surgery_note/src/features/analysis/duration_axis_scale.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DurationAxisScale representative fixtures', () {
    test('0秒は30秒上限の2目盛りにする', () {
      final axis = _individual(Duration.zero);

      _expectAxis(
        axis,
        interval: const Duration(seconds: 30),
        maximum: const Duration(seconds: 30),
        ticks: const [Duration.zero, Duration(seconds: 30)],
      );
      expect(axis.ticks.map(axis.labelFor), ['0秒', '30秒']);
      expect(axis.ratioFor(Duration.zero), 0);
    });

    test('3分未満は30秒刻みで最大値の上に1区間を設ける', () {
      final axis = _individual(const Duration(minutes: 2, seconds: 18));

      _expectAxis(
        axis,
        interval: const Duration(seconds: 30),
        maximum: const Duration(minutes: 2, seconds: 30),
        ticks: const [
          Duration.zero,
          Duration(seconds: 30),
          Duration(minutes: 1),
          Duration(minutes: 1, seconds: 30),
          Duration(minutes: 2),
          Duration(minutes: 2, seconds: 30),
        ],
      );
      expect(axis.ticks.map(axis.labelFor), [
        '0秒',
        '30秒',
        '1分',
        '1分30秒',
        '2分',
        '2分30秒',
      ]);
    });

    test('3分境界の直前と一致で基準間隔を切り替える', () {
      final before = _individual(
        const Duration(minutes: 2, seconds: 59, milliseconds: 999),
      );
      final at = _individual(const Duration(minutes: 3));

      expect(before.interval, const Duration(seconds: 30));
      expect(before.maximum, const Duration(minutes: 3));
      expect(at.interval, const Duration(minutes: 1));
      expect(at.maximum, const Duration(minutes: 4));
      expect(at.ticks.map(at.labelFor), ['0分', '1分', '2分', '3分', '4分']);
    });

    test('4分12秒は従来どおり1分刻みにする', () {
      final axis = _individual(const Duration(minutes: 4, seconds: 12));

      _expectAxis(
        axis,
        interval: const Duration(minutes: 1),
        maximum: const Duration(minutes: 5),
        ticks: _minuteTicks(0, 5),
      );
    });

    test('12件ちょうどまでは1分刻みを維持する', () {
      final axis = _individual(
        const Duration(minutes: 10, seconds: 59, milliseconds: 999),
      );

      expect(axis.interval, const Duration(minutes: 1));
      expect(axis.maximum, const Duration(minutes: 11));
      expect(axis.ticks, _minuteTicks(0, 11));
      expect(axis.ticks, hasLength(12));
    });

    test('11分ちょうどから2分刻みへ規則的に切り替える', () {
      final axis = _individual(const Duration(minutes: 11));

      _expectAxis(
        axis,
        interval: const Duration(minutes: 2),
        maximum: const Duration(minutes: 12),
        ticks: _minuteTicks(0, 12, step: 2),
      );
    });

    for (final fixture in <({String name, Duration maximum})>[
      (name: '一致', maximum: const Duration(minutes: 13)),
      (name: '途中', maximum: const Duration(minutes: 13, seconds: 42)),
      (
        name: '直前',
        maximum: const Duration(
          minutes: 13,
          seconds: 59,
          milliseconds: 999,
          microseconds: 999,
        ),
      ),
    ]) {
      test('核処理13分台（${fixture.name}）は全偶数分を2分刻みで表示する', () {
        final axis = _individual(fixture.maximum);

        _expectAxis(
          axis,
          interval: const Duration(minutes: 2),
          maximum: const Duration(minutes: 14),
          ticks: _minuteTicks(0, 14, step: 2),
        );
        expect(axis.ticks.map(axis.labelFor), [
          '0分',
          '2分',
          '4分',
          '6分',
          '8分',
          '10分',
          '12分',
          '14分',
        ]);
      });
    }

    test('14分ちょうどでも上に2分の1区間を設ける', () {
      final axis = _individual(const Duration(minutes: 14));

      expect(axis.interval, const Duration(minutes: 2));
      expect(axis.maximum, const Duration(minutes: 16));
      expect(axis.ticks, _minuteTicks(0, 16, step: 2));
    });

    test('目盛り境界の直前・一致・直後で厳密に上の規則上限を選ぶ', () {
      final before = _individual(
        const Duration(minutes: 13, seconds: 59, microseconds: 999999),
      );
      final at = _individual(const Duration(minutes: 14));
      final after = _individual(const Duration(minutes: 14, microseconds: 1));

      expect(before.maximum, const Duration(minutes: 14));
      expect(at.maximum, const Duration(minutes: 16));
      expect(after.maximum, const Duration(minutes: 16));
      expect(before.interval, const Duration(minutes: 2));
      expect(at.interval, const Duration(minutes: 2));
      expect(after.interval, const Duration(minutes: 2));
    });

    test('表示可能数6では13分42秒を5分刻みにする', () {
      final axis = _individual(
        const Duration(minutes: 13, seconds: 42),
        maximumTickCount: 6,
      );

      _expectAxis(
        axis,
        interval: const Duration(minutes: 5),
        maximum: const Duration(minutes: 15),
        ticks: _minuteTicks(0, 15, step: 5),
      );
    });

    test('表示可能数2では13分42秒を20分刻みの2件にする', () {
      final axis = _individual(
        const Duration(minutes: 13, seconds: 42),
        maximumTickCount: 2,
      );

      _expectAxis(
        axis,
        interval: const Duration(minutes: 20),
        maximum: const Duration(minutes: 20),
        ticks: const [Duration.zero, Duration(minutes: 20)],
      );
    });

    test('総手術時間は5分基準を維持する', () {
      final axis = _total(const Duration(minutes: 18, seconds: 42));

      _expectAxis(
        axis,
        interval: const Duration(minutes: 5),
        maximum: const Duration(minutes: 20),
        ticks: _minuteTicks(0, 20, step: 5),
      );
      expect(axis.ticks.map(axis.labelFor), ['0分', '5分', '10分', '15分', '20分']);
    });

    test('総手術時間が目盛りと一致しても上に1区間を設ける', () {
      final axis = _total(const Duration(minutes: 20));

      expect(axis.interval, const Duration(minutes: 5));
      expect(axis.maximum, const Duration(minutes: 25));
      expect(axis.ticks, _minuteTicks(0, 25, step: 5));
    });

    test('総手術時間50分は12件の5分目盛りに収まる', () {
      final axis = _total(const Duration(minutes: 50));

      expect(axis.interval, const Duration(minutes: 5));
      expect(axis.maximum, const Duration(minutes: 55));
      expect(axis.ticks, _minuteTicks(0, 55, step: 5));
      expect(axis.ticks, hasLength(12));
    });

    test('総手術時間55分は10分刻みへ切り替える', () {
      final axis = _total(const Duration(minutes: 55));

      _expectAxis(
        axis,
        interval: const Duration(minutes: 10),
        maximum: const Duration(minutes: 60),
        ticks: _minuteTicks(0, 60, step: 10),
      );
    });
  });

  group('DurationAxisScale large values and representation limit', () {
    test('丸め上げ可能な巨大値は巨大listを作らず規則的な粗い間隔を選ぶ', () {
      const duration = Duration(days: 100000);
      final axis = _individual(duration);

      _expectAxis(
        axis,
        interval: const Duration(minutes: 20000000),
        maximum: const Duration(minutes: 160000000),
        ticks: _minuteTicks(0, 160000000, step: 20000000),
      );
      expect(axis.isAtRepresentationLimit, isFalse);
    });

    test('候補上限がoverflowしても後続の粗い候補を評価する', () {
      const duration = Duration(minutes: 145000000000);
      final axis = _individual(duration, maximumTickCount: 9);

      _expectAxis(
        axis,
        interval: const Duration(minutes: 50000000000),
        maximum: const Duration(minutes: 150000000000),
        ticks: const [
          Duration.zero,
          Duration(minutes: 50000000000),
          Duration(minutes: 100000000000),
          Duration(minutes: 150000000000),
        ],
      );
      expect(axis.isAtRepresentationLimit, isFalse);
    });

    test('表現上限の非整列値は仮想上端枠を予約し最大値をtickへ追加しない', () {
      const duration = Duration(microseconds: 9223372036854775807);
      final axis = _individual(duration, maximumTickCount: 8);

      _expectAxis(
        axis,
        interval: const Duration(minutes: 50000000000),
        maximum: duration,
        ticks: const [
          Duration.zero,
          Duration(minutes: 50000000000),
          Duration(minutes: 100000000000),
          Duration(minutes: 150000000000),
        ],
        representationLimit: true,
      );
      expect(axis.ticks.last, lessThan(duration));
      expect(axis.ratioFor(duration), 1);
    });

    test('表現上限の整列値は最後の規則目盛りを最大値と一致させる', () {
      const duration = Duration(minutes: 150000000000);
      final axis = _individual(duration, maximumTickCount: 8);

      _expectAxis(
        axis,
        interval: const Duration(minutes: 50000000000),
        maximum: duration,
        ticks: const [
          Duration.zero,
          Duration(minutes: 50000000000),
          Duration(minutes: 100000000000),
          Duration(minutes: 150000000000),
        ],
        representationLimit: true,
      );
    });

    test('表示可能数2で候補がない表現上限値だけI=Dへ最終縮退する', () {
      const duration = Duration(microseconds: 9223372036854775807);
      final axis = _individual(duration, maximumTickCount: 2);

      _expectAxis(
        axis,
        interval: duration,
        maximum: duration,
        ticks: const [Duration.zero, duration],
        representationLimit: true,
      );
    });

    test('通常時の上限直前はdouble丸め後も有限かつ1未満へ収める', () {
      const duration = Duration(microseconds: 8999999999999999999);
      final axis = _individual(duration);

      expect(axis.maximum, const Duration(minutes: 150000000000));
      expect(axis.isAtRepresentationLimit, isFalse);
      expect(axis.ratioFor(duration).isFinite, isTrue);
      expect(axis.ratioFor(duration), lessThan(1));
      expect(
        axis.ratioFor(duration),
        closeTo(duration.inMicroseconds / axis.maximum.inMicroseconds, 1e-15),
      );
    });
  });

  group('DurationAxisScale invariants', () {
    test('現行の全個別工程へ同じ共有規則を適用する', () {
      const maximum = Duration(minutes: 13, seconds: 42);
      for (final step in activeIndividualSurgicalSteps) {
        final axis = DurationAxisScale.forMaximum(
          step: step,
          maximumDuration: maximum,
        );
        expect(axis.interval, const Duration(minutes: 2), reason: step.label);
        expect(axis.maximum, const Duration(minutes: 14), reason: step.label);
        expect(axis.ticks, _minuteTicks(0, 14, step: 2));
      }
    });

    test('元のマイクロ秒値を量子化せず比率へ変換する', () {
      final axis = _individual(
        const Duration(minutes: 2, seconds: 12, milliseconds: 345),
      );
      const duration = Duration(
        minutes: 1,
        seconds: 6,
        milliseconds: 789,
        microseconds: 321,
      );

      expect(
        axis.ratioFor(duration),
        closeTo(duration.inMicroseconds / axis.maximum.inMicroseconds, 1e-12),
      );
    });

    test('通常fixtureは0始まり・一意・昇順の等差数列で上端余白を持つ', () {
      final fixtures = <({SurgicalStep step, Duration maximum, int count})>[
        (step: SurgicalStep.capsulorhexis, maximum: Duration.zero, count: 12),
        (
          step: SurgicalStep.capsulorhexis,
          maximum: const Duration(minutes: 2, seconds: 59),
          count: 12,
        ),
        (
          step: SurgicalStep.nucleusRemoval,
          maximum: const Duration(minutes: 13, seconds: 42),
          count: 12,
        ),
        (
          step: SurgicalStep.nucleusRemoval,
          maximum: const Duration(days: 100000),
          count: 12,
        ),
        (
          step: SurgicalStep.totalSurgeryTime,
          maximum: const Duration(minutes: 55),
          count: 12,
        ),
      ];

      for (final fixture in fixtures) {
        final axis = DurationAxisScale.forMaximum(
          step: fixture.step,
          maximumDuration: fixture.maximum,
          maximumTickCount: fixture.count,
        );
        expect(axis.isAtRepresentationLimit, isFalse);
        expect(axis.ticks.first, Duration.zero);
        expect(axis.ticks.last, axis.maximum);
        expect(axis.maximum, greaterThan(fixture.maximum));
        expect(axis.ticks.length, lessThanOrEqualTo(fixture.count));
        expect(axis.ticks.toSet(), hasLength(axis.ticks.length));
        for (var index = 1; index < axis.ticks.length; index++) {
          expect(axis.ticks[index], greaterThan(axis.ticks[index - 1]));
          expect(axis.ticks[index] - axis.ticks[index - 1], axis.interval);
        }
      }
    });

    test('Nが減少してもより細かい候補へ戻らない', () {
      const maximum = Duration(minutes: 13, seconds: 42);
      Duration? previousInterval;
      for (final count in [12, 11, 8, 6, 3, 2]) {
        final axis = _individual(maximum, maximumTickCount: count);
        if (previousInterval != null) {
          expect(axis.interval, greaterThanOrEqualTo(previousInterval));
        }
        expect(axis.ticks.length, lessThanOrEqualTo(count));
        previousInterval = axis.interval;
      }
    });

    test('各Nで条件を満たす最小の候補を選ぶ', () {
      const maximum = Duration(minutes: 13, seconds: 42);
      const expected = {
        12: Duration(minutes: 2),
        11: Duration(minutes: 2),
        8: Duration(minutes: 2),
        6: Duration(minutes: 5),
        3: Duration(minutes: 10),
        2: Duration(minutes: 20),
      };

      for (final entry in expected.entries) {
        expect(
          _individual(maximum, maximumTickCount: entry.key).interval,
          entry.value,
          reason: 'N=${entry.key}',
        );
      }
    });

    test('負値と範囲外の表示可能数を拒否する', () {
      expect(
        () => _individual(const Duration(seconds: -1)),
        throwsArgumentError,
      );
      expect(
        () => _individual(Duration.zero, maximumTickCount: 1),
        throwsRangeError,
      );
      expect(
        () => _individual(Duration.zero, maximumTickCount: 13),
        throwsRangeError,
      );
    });

    test('主要目盛りlistは外部から変更できない', () {
      final axis = _individual(const Duration(minutes: 4));

      expect(
        () => axis.ticks.add(const Duration(minutes: 100)),
        throwsUnsupportedError,
      );
    });
  });
}

DurationAxisScale _individual(Duration maximum, {int maximumTickCount = 12}) {
  return DurationAxisScale.forMaximum(
    step: SurgicalStep.nucleusRemoval,
    maximumDuration: maximum,
    maximumTickCount: maximumTickCount,
  );
}

DurationAxisScale _total(Duration maximum, {int maximumTickCount = 12}) {
  return DurationAxisScale.forMaximum(
    step: SurgicalStep.totalSurgeryTime,
    maximumDuration: maximum,
    maximumTickCount: maximumTickCount,
  );
}

List<Duration> _minuteTicks(int start, int end, {int step = 1}) {
  return [
    for (var minute = start; minute <= end; minute += step)
      Duration(minutes: minute),
  ];
}

void _expectAxis(
  DurationAxisScale actual, {
  required Duration interval,
  required Duration maximum,
  required List<Duration> ticks,
  bool representationLimit = false,
}) {
  expect(actual.interval, interval);
  expect(actual.maximum, maximum);
  expect(actual.ticks, ticks);
  expect(actual.isAtRepresentationLimit, representationLimit);
}
