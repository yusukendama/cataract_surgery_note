Duration? procedureDurationBetween(
  int? startMilliseconds,
  int? endMilliseconds,
) {
  if (startMilliseconds == null ||
      endMilliseconds == null ||
      endMilliseconds <= startMilliseconds) {
    return null;
  }
  return Duration(milliseconds: endMilliseconds - startMilliseconds);
}

String formatTimelineMilliseconds(int? milliseconds) {
  if (milliseconds == null) {
    return '未設定';
  }
  final duration = Duration(milliseconds: milliseconds);
  final minutes = duration.inMinutes;
  final seconds = duration.inSeconds % 60;
  final tenths = (duration.inMilliseconds % 1000) ~/ 100;
  return '$minutes:${seconds.toString().padLeft(2, '0')}.$tenths';
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
