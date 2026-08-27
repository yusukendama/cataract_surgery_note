import 'dart:math' as math;

/// A local calendar date without a time, UTC offset, or time-zone semantics.
///
/// Analysis uses this value for ordering and horizontal distances so daylight
/// saving transitions can never turn a calendar day into 23 or 25 hours.
final class CalendarDay implements Comparable<CalendarDay> {
  const CalendarDay(this.year, this.month, this.day)
    : assert(month >= 1 && month <= 12),
      assert(day >= 1 && day <= 31);

  factory CalendarDay.fromDateTime(DateTime value) {
    return CalendarDay(value.year, value.month, value.day);
  }

  final int year;
  final int month;
  final int day;

  /// A continuous proleptic-Gregorian day number.
  ///
  /// The implementation is the civil-date algorithm by Howard Hinnant. It is
  /// integer-only and therefore independent of local midnight and DST.
  int get ordinal {
    var adjustedYear = year;
    if (month <= 2) {
      adjustedYear--;
    }
    final era = _floorDivide(adjustedYear, 400);
    final yearOfEra = adjustedYear - era * 400;
    final adjustedMonth = month + (month > 2 ? -3 : 9);
    final dayOfYear = (153 * adjustedMonth + 2) ~/ 5 + day - 1;
    final dayOfEra =
        yearOfEra * 365 + yearOfEra ~/ 4 - yearOfEra ~/ 100 + dayOfYear;
    return era * 146097 + dayOfEra;
  }

  CalendarDay addDays(int days) {
    // UTC is used only as a calendar arithmetic engine. No local offset or
    // elapsed-hour difference participates in the result.
    final value = DateTime.utc(year, month, day).add(Duration(days: days));
    return CalendarDay(value.year, value.month, value.day);
  }

  CalendarDay addMonths(int months) {
    final zeroBasedMonth = month - 1 + months;
    final targetYear = year + _floorDivide(zeroBasedMonth, 12);
    final targetMonth =
        zeroBasedMonth - _floorDivide(zeroBasedMonth, 12) * 12 + 1;
    final targetDay = math.min(day, daysInMonth(targetYear, targetMonth));
    return CalendarDay(targetYear, targetMonth, targetDay);
  }

  CalendarDay addYears(int years) {
    final targetYear = year + years;
    return CalendarDay(
      targetYear,
      month,
      math.min(day, daysInMonth(targetYear, month)),
    );
  }

  DateTime toLocalDateTime() => DateTime(year, month, day);

  static int daysInMonth(int year, int month) {
    return switch (month) {
      1 || 3 || 5 || 7 || 8 || 10 || 12 => 31,
      4 || 6 || 9 || 11 => 30,
      2 => _isLeapYear(year) ? 29 : 28,
      _ => throw ArgumentError.value(month, 'month'),
    };
  }

  static bool _isLeapYear(int year) {
    return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
  }

  @override
  int compareTo(CalendarDay other) {
    final yearComparison = year.compareTo(other.year);
    if (yearComparison != 0) {
      return yearComparison;
    }
    final monthComparison = month.compareTo(other.month);
    if (monthComparison != 0) {
      return monthComparison;
    }
    return day.compareTo(other.day);
  }

  bool isBefore(CalendarDay other) => compareTo(other) < 0;
  bool isAfter(CalendarDay other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) {
    return other is CalendarDay &&
        other.year == year &&
        other.month == month &&
        other.day == day;
  }

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() =>
      '$year-${month.toString().padLeft(2, '0')}-'
      '${day.toString().padLeft(2, '0')}';
}

int _floorDivide(int value, int divisor) {
  final quotient = value ~/ divisor;
  final remainder = value % divisor;
  // Dart's integer division truncates toward zero while calendar arithmetic
  // needs floor division when crossing into a negative year.
  return value < 0 && remainder != 0 ? quotient - 1 : quotient;
}
