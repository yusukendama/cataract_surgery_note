import '../../domain/surgery_models.dart';

const _thirtySeconds = Duration(seconds: 30);
const _oneMinute = Duration(minutes: 1);
const _threeMinutes = Duration(minutes: 3);
const _fiveMinutes = Duration(minutes: 5);
const _maximumDurationMicroseconds = 9223372036854775807;
const _maximumTickCount = 12;

/// 手術時間グラフの縦軸スケール。
///
/// データの時間は丸めず、目盛り間隔と表示上限だけをキリの良い時間に揃える。
class DurationAxisScale {
  const DurationAxisScale._({required this.interval, required this.maximum});

  factory DurationAxisScale.forMaximum({
    required SurgicalStep step,
    required Duration maximumDuration,
  }) {
    if (maximumDuration.isNegative) {
      throw ArgumentError.value(
        maximumDuration,
        'maximumDuration',
        '負の時間は指定できません',
      );
    }

    final interval = step.isTotalSurgeryTime
        ? _fiveMinutes
        : maximumDuration < _threeMinutes
        ? _thirtySeconds
        : _oneMinute;
    final maximumMicroseconds = maximumDuration.inMicroseconds;
    final intervalMicroseconds = interval.inMicroseconds;
    final intervalCount = maximumMicroseconds ~/ intervalMicroseconds + 1;
    final canRoundUp =
        intervalCount <= _maximumDurationMicroseconds ~/ intervalMicroseconds;

    return DurationAxisScale._(
      interval: interval,
      maximum: canRoundUp
          ? Duration(microseconds: intervalMicroseconds * intervalCount)
          : maximumDuration,
    );
  }

  final Duration interval;
  final Duration maximum;

  Duration get minimum => Duration.zero;

  List<Duration> get ticks {
    final maximumMicroseconds = maximum.inMicroseconds;
    final intervalMicroseconds = interval.inMicroseconds;
    final regularIntervalCount = maximumMicroseconds ~/ intervalMicroseconds;
    final hasIrregularMaximum = maximumMicroseconds % intervalMicroseconds != 0;
    final fullTickCount =
        regularIntervalCount + 1 + (hasIrregularMaximum ? 1 : 0);

    if (fullTickCount <= _maximumTickCount) {
      return List<Duration>.unmodifiable([
        for (var index = 0; index <= regularIntervalCount; index++)
          Duration(microseconds: intervalMicroseconds * index),
        if (hasIrregularMaximum) maximum,
      ]);
    }

    // Keep the normal scale unchanged, but sample a bounded number of its
    // regular grid lines for corrupted or otherwise extreme stored values.
    // Reserve the last slot for a non-aligned maximum when rounding upward is
    // impossible at Duration's signed 64-bit limit.
    final regularTickCount = _maximumTickCount - (hasIrregularMaximum ? 1 : 0);
    final divisor = regularTickCount - 1;
    return List<Duration>.unmodifiable([
      for (var slot = 0; slot < regularTickCount; slot++)
        Duration(
          microseconds:
              _scaledIndex(
                value: regularIntervalCount,
                multiplier: slot,
                divisor: divisor,
              ) *
              intervalMicroseconds,
        ),
      if (hasIrregularMaximum) maximum,
    ]);
  }

  /// 0.0〜1.0の縦軸上の位置を返す。入力値そのものは丸めない。
  double ratioFor(Duration duration) {
    return duration.inMicroseconds / maximum.inMicroseconds;
  }

  String labelFor(Duration tick) {
    if (tick == Duration.zero) {
      return interval == _thirtySeconds ? '0秒' : '0分';
    }

    final minutes = tick.inMinutes;
    final seconds = tick.inSeconds % Duration.secondsPerMinute;
    if (seconds == 0) {
      return '$minutes分';
    }
    if (minutes == 0) {
      return '$seconds秒';
    }
    return '$minutes分$seconds秒';
  }

  @override
  bool operator ==(Object other) {
    return other is DurationAxisScale &&
        other.interval == interval &&
        other.maximum == maximum;
  }

  @override
  int get hashCode => Object.hash(interval, maximum);
}

/// Returns `(value * multiplier) ~/ divisor` without overflowing [int].
///
/// Callers pass `0 <= multiplier <= divisor`: the first product stays within
/// [value], while the remainder product is bounded by `divisor * divisor`.
int _scaledIndex({
  required int value,
  required int multiplier,
  required int divisor,
}) {
  final quotient = value ~/ divisor;
  final remainder = value % divisor;
  return quotient * multiplier + (remainder * multiplier) ~/ divisor;
}
