class ProcedureTimingRules {
  const ProcedureTimingRules();

  Duration? calculateDuration({
    required int? startMilliseconds,
    required int? endMilliseconds,
  }) {
    if (startMilliseconds == null || endMilliseconds == null) {
      return null;
    }
    if (endMilliseconds <= startMilliseconds) {
      return null;
    }
    return Duration(milliseconds: endMilliseconds - startMilliseconds);
  }

  String? validateRange({
    required int? startMilliseconds,
    required int? endMilliseconds,
  }) {
    if (startMilliseconds == null || endMilliseconds == null) {
      return null;
    }
    if (endMilliseconds <= startMilliseconds) {
      return '終了時刻は開始時刻より後に設定してください。';
    }
    return null;
  }
}
