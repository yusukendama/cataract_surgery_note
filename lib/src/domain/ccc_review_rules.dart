class CccReviewRules {
  const CccReviewRules();

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
      return 'CCC終了位置は開始位置より後にしてください。';
    }
    return null;
  }
}
