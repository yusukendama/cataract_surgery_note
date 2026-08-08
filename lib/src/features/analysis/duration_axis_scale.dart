import '../../domain/surgery_models.dart';

const _thirtySeconds = Duration(seconds: 30);
const _oneMinute = Duration(minutes: 1);
const _threeMinutes = Duration(minutes: 3);
const _fiveMinutes = Duration(minutes: 5);

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
    final intervalCount =
        maximumDuration.inMicroseconds ~/ interval.inMicroseconds + 1;

    return DurationAxisScale._(
      interval: interval,
      maximum: interval * intervalCount,
    );
  }

  final Duration interval;
  final Duration maximum;

  Duration get minimum => Duration.zero;

  List<Duration> get ticks {
    final tickCount = maximum.inMicroseconds ~/ interval.inMicroseconds;
    return List.generate(
      tickCount + 1,
      (index) => interval * index,
      growable: false,
    );
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
