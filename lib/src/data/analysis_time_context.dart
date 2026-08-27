import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../domain/calendar_day.dart';

final class AnalysisTimeContext {
  const AnalysisTimeContext({
    required this.now,
    required this.timezoneIdentifier,
  });

  final DateTime now;
  final String timezoneIdentifier;

  CalendarDay get localDay => CalendarDay.fromDateTime(now);
}

abstract interface class AnalysisTimeContextSource {
  Future<AnalysisTimeContext> read();
  Stream<void> get changes;
}

final class PlatformAnalysisTimeContextSource
    implements AnalysisTimeContextSource {
  PlatformAnalysisTimeContextSource({
    MethodChannel methodChannel = const MethodChannel(
      'cataract_surgery_note/analysis_time_context',
    ),
    EventChannel eventChannel = const EventChannel(
      'cataract_surgery_note/analysis_time_events',
    ),
    DateTime Function()? now,
    bool? usePlatformChannels,
  }) : _methodChannel = methodChannel,
       _eventChannel = eventChannel,
       _now = now ?? DateTime.now,
       _usePlatformChannels =
           usePlatformChannels ?? (Platform.isIOS || Platform.isAndroid);

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;
  final DateTime Function() _now;
  final bool _usePlatformChannels;

  Stream<void>? _changes;

  @override
  Future<AnalysisTimeContext> read() async {
    if (!_usePlatformChannels) {
      final now = _now();
      return AnalysisTimeContext(
        now: now,
        timezoneIdentifier: 'dart:${now.timeZoneName}',
      );
    }
    String identifier;
    try {
      identifier =
          await _methodChannel.invokeMethod<String>('timezoneIdentifier') ?? '';
    } on MissingPluginException {
      // Widget tests and unsupported development platforms have no native
      // registrar. Production iOS supplies the IANA identifier below.
      final now = _now();
      identifier = 'dart:${now.timeZoneName}';
    } on PlatformException {
      rethrow;
    }
    if (identifier.isEmpty) {
      throw StateError('timezone identifierを取得できませんでした。');
    }
    return AnalysisTimeContext(now: _now(), timezoneIdentifier: identifier);
  }

  @override
  Stream<void> get changes {
    if (!_usePlatformChannels) {
      return const Stream<void>.empty();
    }
    return _changes ??= _eventChannel
        .receiveBroadcastStream()
        .map<void>((_) {})
        .handleError((Object error) {
          // A 60-second scheduler fallback remains authoritative when native
          // notifications are unavailable. Do not terminate the monitor.
        });
  }
}

abstract interface class AnalysisScheduledTask {
  void cancel();
}

abstract interface class AnalysisScheduler {
  AnalysisScheduledTask schedule(Duration delay, void Function() callback);
}

final class TimerAnalysisScheduler implements AnalysisScheduler {
  const TimerAnalysisScheduler();

  @override
  AnalysisScheduledTask schedule(Duration delay, void Function() callback) {
    return _TimerScheduledTask(Timer(delay, callback));
  }
}

final class _TimerScheduledTask implements AnalysisScheduledTask {
  _TimerScheduledTask(this._timer);

  final Timer _timer;

  @override
  void cancel() => _timer.cancel();
}

typedef AnalysisTimeContextChanged =
    void Function(AnalysisTimeContext previous, AnalysisTimeContext current);

/// Owns one re-armed timer plus the native clock/time-zone subscription.
final class AnalysisClockMonitor {
  AnalysisClockMonitor({
    required AnalysisTimeContextSource source,
    AnalysisScheduler scheduler = const TimerAnalysisScheduler(),
    this.maximumPollInterval = const Duration(seconds: 60),
  }) : _source = source,
       _scheduler = scheduler;

  final AnalysisTimeContextSource _source;
  final AnalysisScheduler _scheduler;
  final Duration maximumPollInterval;

  AnalysisScheduledTask? _task;
  StreamSubscription<void>? _subscription;
  AnalysisTimeContext? _current;
  AnalysisTimeContextChanged? _onChanged;
  int _generation = 0;
  int? _readingGeneration;

  bool get isActive => _onChanged != null;

  Future<void> start({
    required AnalysisTimeContext initialContext,
    required AnalysisTimeContextChanged onChanged,
  }) async {
    stop();
    _current = initialContext;
    _onChanged = onChanged;
    final generation = _generation;
    _subscription = _source.changes.listen((_) {
      _check(generation).ignore();
    });
    await _check(generation);
  }

  void stop() {
    _generation++;
    _task?.cancel();
    _task = null;
    _subscription?.cancel().ignore();
    _subscription = null;
    _onChanged = null;
  }

  Future<void> checkNow() => _check(_generation);

  Future<void> _check(int generation) async {
    if (_onChanged == null ||
        generation != _generation ||
        _readingGeneration == generation) {
      return;
    }
    _readingGeneration = generation;
    try {
      final next = await _source.read();
      if (_onChanged == null || generation != _generation) {
        return;
      }
      final previous = _current;
      _current = next;
      if (previous != null &&
          (previous.localDay != next.localDay ||
              previous.timezoneIdentifier != next.timezoneIdentifier)) {
        _onChanged!(previous, next);
      }
      // The callback may synchronously stop the monitor (for example while a
      // timezone-sensitive Snapshot is refreshed). Never resurrect a timer
      // owned by the generation that callback just cancelled.
      if (_onChanged != null && generation == _generation) {
        _arm(next, generation);
      }
    } on Object {
      // Native notifications are an optimisation. A transient context read
      // failure must not permanently remove the <=60 second polling fallback.
      if (_onChanged != null && generation == _generation) {
        _task?.cancel();
        _task = _scheduler.schedule(maximumPollInterval, () {
          _check(generation).ignore();
        });
      }
    } finally {
      // A read from an obsolete generation can complete after stop/start.
      // It must not release the latch owned by the newer generation.
      if (_readingGeneration == generation) {
        _readingGeneration = null;
      }
    }
  }

  void _arm(AnalysisTimeContext context, int generation) {
    _task?.cancel();
    final nextDay = DateTime(
      context.now.year,
      context.now.month,
      context.now.day + 1,
    );
    var untilMidnight = nextDay.difference(context.now);
    if (untilMidnight <= Duration.zero) {
      untilMidnight = const Duration(milliseconds: 1);
    }
    final delay = untilMidnight < maximumPollInterval
        ? untilMidnight
        : maximumPollInterval;
    _task = _scheduler.schedule(delay, () {
      _check(generation).ignore();
    });
  }

  void dispose() => stop();
}
