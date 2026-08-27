import '../../domain/surgery_models.dart';

const _thirtySeconds = Duration(seconds: 30);
const _oneMinute = Duration(minutes: 1);
const _threeMinutes = Duration(minutes: 3);
const _fiveMinutes = Duration(minutes: 5);
const _maximumDurationMicroseconds = 9223372036854775807;
const _maximumMajorTickCount = 12;
const _largestDoubleLessThanOne = 0.9999999999999999;

final _maximumDurationMicrosecondsBigInt = BigInt.from(
  _maximumDurationMicroseconds,
);
final _microsecondsPerMinuteBigInt = BigInt.from(
  Duration.microsecondsPerMinute,
);

/// 手術時間グラフの縦軸スケール。
///
/// データの時間は丸めず、目盛り間隔と表示上限だけをキリの良い時間に揃える。
/// 主要目盛りは、30秒および `1・2・5 × 10^n` 分の候補から、現在の
/// レイアウトに収まる最も細かい規則的な間隔を選ぶ。
class DurationAxisScale {
  DurationAxisScale._({
    required this.interval,
    required this.maximum,
    required List<Duration> ticks,
    required this.isAtRepresentationLimit,
  }) : ticks = List<Duration>.unmodifiable(ticks);

  factory DurationAxisScale.forMaximum({
    required SurgicalStep step,
    required Duration maximumDuration,
    int maximumTickCount = _maximumMajorTickCount,
  }) {
    if (maximumDuration.isNegative) {
      throw ArgumentError.value(
        maximumDuration,
        'maximumDuration',
        '負の時間は指定できません',
      );
    }
    if (maximumTickCount < 2 || maximumTickCount > _maximumMajorTickCount) {
      throw RangeError.range(
        maximumTickCount,
        2,
        _maximumMajorTickCount,
        'maximumTickCount',
      );
    }

    final baseInterval = step.isTotalSurgeryTime
        ? _fiveMinutes
        : maximumDuration < _threeMinutes
        ? _thirtySeconds
        : _oneMinute;
    final maximumMicroseconds = BigInt.from(maximumDuration.inMicroseconds);
    final maximumTickCountBigInt = BigInt.from(maximumTickCount);
    final baseIntervalMicroseconds = BigInt.from(baseInterval.inMicroseconds);

    // 通常時。最大値より厳密に大きい最小の規則目盛りを上限とし、
    // 表示可能数に収まる最初の（最も細かい）候補を採用する。
    // ある候補の上限だけがoverflowしても、後続の粗い候補で上限が再び
    // 表現可能になることがあるため、有限な全候補の評価を継続する。
    for (final intervalMicroseconds in _candidateIntervalMicroseconds()) {
      if (intervalMicroseconds < baseIntervalMicroseconds) {
        continue;
      }
      final intervalCount =
          maximumMicroseconds ~/ intervalMicroseconds + BigInt.one;
      final roundedMaximum = intervalCount * intervalMicroseconds;
      if (roundedMaximum > _maximumDurationMicrosecondsBigInt) {
        continue;
      }
      final tickCount = intervalCount + BigInt.one;
      if (tickCount > maximumTickCountBigInt) {
        continue;
      }

      return DurationAxisScale._regular(
        intervalMicroseconds: intervalMicroseconds,
        maximumMicroseconds: roundedMaximum,
        tickCount: tickCount.toInt(),
      );
    }

    // Durationの表現上限時。非整列の末尾区間も仮想的な1枠として数え、
    // 実際の規則目盛りだけを生成する。最大値を不規則な目盛りとしては
    // 追加しない。
    for (final intervalMicroseconds in _candidateIntervalMicroseconds()) {
      if (intervalMicroseconds < baseIntervalMicroseconds) {
        continue;
      }
      if (intervalMicroseconds > maximumMicroseconds) {
        break;
      }
      final regularIntervalCount = maximumMicroseconds ~/ intervalMicroseconds;
      final hasRemainder =
          maximumMicroseconds % intervalMicroseconds != BigInt.zero;
      final virtualCount =
          regularIntervalCount +
          BigInt.one +
          (hasRemainder ? BigInt.one : BigInt.zero);
      if (virtualCount > maximumTickCountBigInt) {
        continue;
      }

      return DurationAxisScale._representationLimit(
        intervalMicroseconds: intervalMicroseconds,
        maximumDuration: maximumDuration,
        regularTickCount: (regularIntervalCount + BigInt.one).toInt(),
      );
    }

    // N=2等で候補列に適合する間隔が存在しない場合だけ、0とDへ縮退する。
    // D=0では30秒候補が必ず通常時に採用されるため、ここではD>0である。
    return DurationAxisScale._(
      interval: maximumDuration,
      maximum: maximumDuration,
      ticks: [Duration.zero, maximumDuration],
      isAtRepresentationLimit: true,
    );
  }

  factory DurationAxisScale._regular({
    required BigInt intervalMicroseconds,
    required BigInt maximumMicroseconds,
    required int tickCount,
  }) {
    final interval = _durationFromMicroseconds(intervalMicroseconds);
    return DurationAxisScale._(
      interval: interval,
      maximum: _durationFromMicroseconds(maximumMicroseconds),
      ticks: [
        for (var index = 0; index < tickCount; index++)
          _durationFromMicroseconds(intervalMicroseconds * BigInt.from(index)),
      ],
      isAtRepresentationLimit: false,
    );
  }

  factory DurationAxisScale._representationLimit({
    required BigInt intervalMicroseconds,
    required Duration maximumDuration,
    required int regularTickCount,
  }) {
    final interval = _durationFromMicroseconds(intervalMicroseconds);
    return DurationAxisScale._(
      interval: interval,
      maximum: maximumDuration,
      ticks: [
        for (var index = 0; index < regularTickCount; index++)
          _durationFromMicroseconds(intervalMicroseconds * BigInt.from(index)),
      ],
      isAtRepresentationLimit: true,
    );
  }

  final Duration interval;
  final Duration maximum;
  final List<Duration> ticks;

  /// 有限な全候補で通常の上方1区間を確保できなかった場合だけtrue。
  final bool isAtRepresentationLimit;

  Duration get minimum => Duration.zero;

  /// 0.0〜1.0の縦軸上の位置を返す。入力値そのものは丸めない。
  double ratioFor(Duration duration) {
    final ratio = duration.inMicroseconds / maximum.inMicroseconds;
    // Duration上限近傍では、異なる整数値が同じdoubleへ丸められる場合が
    // ある。通常時の点は厳密に上限未満なので、画面外へ出さず1未満を保つ。
    if (duration < maximum && ratio >= 1) {
      return _largestDoubleLessThanOne;
    }
    return ratio;
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
        other.maximum == maximum &&
        other.isAtRepresentationLimit == isAtRepresentationLimit;
  }

  @override
  int get hashCode => Object.hash(interval, maximum, isAtRepresentationLimit);
}

Iterable<BigInt> _candidateIntervalMicroseconds() sync* {
  yield BigInt.from(_thirtySeconds.inMicroseconds);

  var magnitude = BigInt.one;
  const multipliers = [1, 2, 5];
  while (true) {
    for (final multiplier in multipliers) {
      final candidate =
          _microsecondsPerMinuteBigInt * magnitude * BigInt.from(multiplier);
      if (candidate > _maximumDurationMicrosecondsBigInt) {
        return;
      }
      yield candidate;
    }
    magnitude *= BigInt.from(10);
  }
}

Duration _durationFromMicroseconds(BigInt microseconds) {
  if (microseconds < BigInt.zero ||
      microseconds > _maximumDurationMicrosecondsBigInt) {
    throw StateError('Durationの表現範囲外です: $microseconds');
  }
  return Duration(microseconds: microseconds.toInt());
}
