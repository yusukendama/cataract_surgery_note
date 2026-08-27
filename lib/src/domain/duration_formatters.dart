// A Duration stores microseconds in a signed 64-bit integer on native Dart.
// Validate millisecond values before invoking its constructor, which multiplies
// them by 1,000 and may otherwise overflow.
const maximumSafeDurationMilliseconds = 9223372036854775;

Duration? procedureDurationBetween(
  int? startMilliseconds,
  int? endMilliseconds,
) {
  if (startMilliseconds == null ||
      endMilliseconds == null ||
      endMilliseconds <= startMilliseconds) {
    return null;
  }

  final difference =
      BigInt.from(endMilliseconds) - BigInt.from(startMilliseconds);
  if (difference > BigInt.from(maximumSafeDurationMilliseconds)) {
    return null;
  }

  return Duration(milliseconds: difference.toInt());
}

String formatTimelineMilliseconds(int? milliseconds) {
  if (milliseconds == null) {
    return '未設定';
  }

  // Format the integer directly. Constructing Duration first can overflow for
  // valid SQLite signed 64-bit boundary values because Duration stores
  // microseconds rather than milliseconds.
  final value = BigInt.from(milliseconds);
  final magnitude = value.abs();
  final minutes = magnitude ~/ BigInt.from(60000);
  final seconds = (magnitude ~/ BigInt.from(1000)) % BigInt.from(60);
  final tenths = (magnitude % BigInt.from(1000)) ~/ BigInt.from(100);
  final sign = value.isNegative ? '-' : '';
  return '$sign$minutes:${seconds.toString().padLeft(2, '0')}.$tenths';
}

String formatProcedureDuration(Duration? duration) {
  if (duration == null) {
    return '未設定';
  }
  final minutes = duration.inMinutes;
  final seconds = duration.inSeconds % 60;
  if (minutes == 0) {
    return '$seconds秒';
  }
  return '$minutes分${seconds.toString().padLeft(2, '0')}秒';
}

/// Formats a validated, non-negative procedure-arrival duration.
///
/// Arrival time is derived from two millisecond positions on the same video
/// timeline. Callers must classify invalid positions before formatting so a
/// negative value can never be hidden as an ordinary elapsed time.
String formatProcedureArrivalDuration(Duration duration) {
  if (duration.isNegative) {
    throw ArgumentError.value(duration, 'duration', '工程到達時間には0以上の値を指定してください。');
  }

  final totalSeconds = duration.inMilliseconds ~/ 1000;
  final hours = totalSeconds ~/ Duration.secondsPerHour;
  final minutes =
      (totalSeconds ~/ Duration.secondsPerMinute) % Duration.minutesPerHour;
  final seconds = totalSeconds % Duration.secondsPerMinute;
  if (hours > 0) {
    return '$hours時間'
        '${minutes.toString().padLeft(2, '0')}分'
        '${seconds.toString().padLeft(2, '0')}秒';
  }
  if (minutes > 0) {
    return '$minutes分${seconds.toString().padLeft(2, '0')}秒';
  }
  return '$seconds秒';
}

String formatMinutesSeconds(Duration duration) {
  final totalSeconds = duration.inMilliseconds.abs() ~/ 1000;
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

String formatSignedMinutesSeconds(Duration duration) {
  final prefix = duration.isNegative ? '-' : '+';
  return '$prefix${formatMinutesSeconds(duration)}';
}
