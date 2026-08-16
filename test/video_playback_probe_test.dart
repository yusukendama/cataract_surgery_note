import 'dart:async';
import 'dart:io';

import 'package:cataract_surgery_note/src/data/video_import_models.dart';
import 'package:cataract_surgery_note/src/data/video_import_preflight.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final _source = File('/unused/playback-probe-source.mp4');

void main() {
  test('production playback time limits remain the v1.1 contract', () {
    expect(
      VideoPlayerPlaybackProbe.defaultInitializationTimeout,
      const Duration(seconds: 10),
    );
    expect(
      VideoPlayerPlaybackProbe.defaultProgressTimeout,
      const Duration(seconds: 3),
    );
    expect(
      VideoPlayerPlaybackProbe.defaultSeekTimeout,
      const Duration(seconds: 5),
    );
    expect(
      VideoPlayerPlaybackProbe.defaultTotalTimeout,
      const Duration(seconds: 20),
    );
  });

  test('mutes before play and returns positive playback evidence', () async {
    final controller = _FakePlaybackController(
      positionValue: const Duration(milliseconds: 100),
    );
    final evidence = await _probeFor(controller).probe(_source);

    expect(evidence.duration, const Duration(seconds: 12));
    expect(evidence.width, 1920);
    expect(evidence.height, 1080);
    expect(evidence.aspectRatio, closeTo(16 / 9, 0.000001));
    expect(
      controller.calls.indexOf('volume:0.0'),
      lessThan(controller.calls.indexOf('play')),
    );
    expect(
      controller.calls.indexOf('pause'),
      lessThan(controller.calls.indexOf('seek:5000000')),
    );
    expect(controller.calls.last, 'dispose');
  });

  group('progress threshold is min(100 ms, duration / 4)', () {
    final cases = <({Duration duration, Duration threshold})>[
      (
        duration: const Duration(milliseconds: 200),
        threshold: const Duration(milliseconds: 50),
      ),
      (
        duration: const Duration(seconds: 10),
        threshold: const Duration(milliseconds: 100),
      ),
    ];

    for (final testCase in cases) {
      test('accepts the exact threshold for ${testCase.duration}', () async {
        final controller = _FakePlaybackController(
          durationValue: testCase.duration,
          positionValue: testCase.threshold,
        );

        await expectLater(_probeFor(controller).probe(_source), completes);
        expect(controller.calls.last, 'dispose');
      });

      test(
        'rejects one microsecond below it for ${testCase.duration}',
        () async {
          final controller = _FakePlaybackController(
            durationValue: testCase.duration,
            positionValue: testCase.threshold - const Duration(microseconds: 1),
          );

          await _expectProbeFailure(
            _shortProgressProbe(controller),
            controller,
            VideoPlaybackProbeFailureReason.noProgress,
          );
        },
      );
    }
  });

  test('seeks to min(5 seconds, duration / 2) only above 2 seconds', () async {
    final cases = <({Duration duration, Duration? expectedSeek})>[
      (duration: const Duration(seconds: 2), expectedSeek: null),
      (
        duration: const Duration(seconds: 6),
        expectedSeek: const Duration(seconds: 3),
      ),
      (
        duration: const Duration(seconds: 12),
        expectedSeek: const Duration(seconds: 5),
      ),
    ];

    for (final testCase in cases) {
      final controller = _FakePlaybackController(
        durationValue: testCase.duration,
        positionValue: const Duration(milliseconds: 100),
      );

      await _probeFor(controller).probe(_source);

      final seekCalls = controller.calls
          .where((call) => call.startsWith('seek:'))
          .toList();
      if (testCase.expectedSeek == null) {
        expect(seekCalls, isEmpty);
      } else {
        expect(seekCalls, <String>[
          'seek:${testCase.expectedSeek!.inMicroseconds}',
        ]);
      }
      expect(controller.calls.last, 'dispose');
    }
  });

  test('rejects a non-positive duration and disposes', () async {
    final controller = _FakePlaybackController(durationValue: Duration.zero);

    await _expectProbeFailure(
      _probeFor(controller),
      controller,
      VideoPlaybackProbeFailureReason.invalidDuration,
    );
  });

  test('rejects invalid dimensions and aspect ratio and disposes', () async {
    final controllers = <_FakePlaybackController>[
      _FakePlaybackController(widthValue: 0),
      _FakePlaybackController(heightValue: double.infinity),
      _FakePlaybackController(aspectRatioValue: double.nan),
    ];

    for (final controller in controllers) {
      await _expectProbeFailure(
        _probeFor(controller),
        controller,
        VideoPlaybackProbeFailureReason.invalidDimensions,
      );
    }
  });

  test('rejects playback that never progresses and disposes', () async {
    final controller = _FakePlaybackController(positionValue: Duration.zero);

    await _expectProbeFailure(
      _shortProgressProbe(controller),
      controller,
      VideoPlaybackProbeFailureReason.noProgress,
    );
  });

  test('maps a seek operation failure and disposes', () async {
    final controller = _FakePlaybackController(
      positionValue: const Duration(milliseconds: 100),
      seekBehavior: () async => throw StateError('seek rejected'),
    );

    await _expectProbeFailure(
      _probeFor(controller),
      controller,
      VideoPlaybackProbeFailureReason.seek,
    );
  });

  test('maps a controller error after seek and disposes', () async {
    late _FakePlaybackController controller;
    controller = _FakePlaybackController(
      positionValue: const Duration(milliseconds: 100),
      seekBehavior: () async => controller.hasErrorValue = true,
    );

    await _expectProbeFailure(
      _probeFor(controller),
      controller,
      VideoPlaybackProbeFailureReason.seek,
    );
  });

  test('a stage timeout is typed and cleanup still runs', () async {
    final never = Completer<void>();
    final controller = _FakePlaybackController(
      initializeBehavior: () => never.future,
    );
    final probe = VideoPlayerPlaybackProbe(
      controllerFactory: (_) => controller,
      initializationTimeout: const Duration(milliseconds: 15),
      progressTimeout: const Duration(milliseconds: 50),
      seekTimeout: const Duration(milliseconds: 50),
      totalTimeout: const Duration(milliseconds: 250),
      progressPollInterval: const Duration(milliseconds: 1),
      cleanupTimeout: const Duration(milliseconds: 10),
    );

    await _expectProbeFailure(
      probe,
      controller,
      VideoPlaybackProbeFailureReason.timedOut,
    );
  });

  test('the total timeout aborts detached work and disposes', () async {
    final initialization = Completer<void>();
    final controller = _FakePlaybackController(
      initializeBehavior: () => initialization.future,
    );
    final probe = VideoPlayerPlaybackProbe(
      controllerFactory: (_) => controller,
      initializationTimeout: const Duration(seconds: 1),
      progressTimeout: const Duration(seconds: 1),
      seekTimeout: const Duration(seconds: 1),
      totalTimeout: const Duration(milliseconds: 20),
      progressPollInterval: const Duration(milliseconds: 1),
      cleanupTimeout: const Duration(milliseconds: 10),
    );
    final elapsed = Stopwatch()..start();

    await _expectProbeFailure(
      probe,
      controller,
      VideoPlaybackProbeFailureReason.timedOut,
    );
    elapsed.stop();
    expect(elapsed.elapsed, lessThan(const Duration(milliseconds: 250)));

    initialization.complete();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(controller.calls, isNot(contains('play')));
  });

  test(
    'an explicit DRM platform signal is distinguished and disposed',
    () async {
      final controller = _FakePlaybackController(
        initializeBehavior: () async =>
            throw PlatformException(code: 'content_protected'),
      );

      await _expectProbeFailure(
        _probeFor(controller),
        controller,
        VideoPlaybackProbeFailureReason.protectedMedia,
      );
    },
  );

  test(
    'cancellation interrupts a stage and disposes without resuming',
    () async {
      final initializationStarted = Completer<void>();
      final initialization = Completer<void>();
      final controller = _FakePlaybackController(
        initializeBehavior: () {
          initializationStarted.complete();
          return initialization.future;
        },
      );
      final token = VideoImportCancellationToken();
      final operation = _probeFor(
        controller,
      ).probe(_source, cancellationToken: token);
      await initializationStarted.future;

      token.cancel();

      await expectLater(
        operation,
        throwsA(
          isA<VideoImportException>().having(
            (error) => error.code,
            'code',
            VideoImportErrorCode.userCanceled,
          ),
        ),
      );
      expect(controller.calls, contains('dispose'));

      initialization.complete();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(controller.calls, isNot(contains('play')));
    },
  );

  test('a hanging dispose cannot block the probe indefinitely', () async {
    final dispose = Completer<void>();
    final controller = _FakePlaybackController(
      positionValue: const Duration(milliseconds: 100),
      disposeBehavior: () => dispose.future,
    );
    final elapsed = Stopwatch()..start();

    final evidence = await _probeFor(controller).probe(_source);

    elapsed.stop();
    expect(evidence.duration, const Duration(seconds: 12));
    expect(controller.calls.last, 'dispose');
    expect(elapsed.elapsed, lessThan(const Duration(milliseconds: 250)));
  });

  test('a hanging pause still reaches bounded disposal', () async {
    final pause = Completer<void>();
    final controller = _FakePlaybackController(
      positionValue: const Duration(milliseconds: 100),
      pauseBehavior: () => pause.future,
    );
    final elapsed = Stopwatch()..start();

    await _expectProbeFailure(
      _shortProgressProbe(controller),
      controller,
      VideoPlaybackProbeFailureReason.timedOut,
    );

    elapsed.stop();
    expect(controller.calls.last, 'dispose');
    expect(elapsed.elapsed, lessThan(const Duration(milliseconds: 250)));
  });
}

VideoPlayerPlaybackProbe _probeFor(_FakePlaybackController controller) {
  return VideoPlayerPlaybackProbe(
    controllerFactory: (_) => controller,
    initializationTimeout: const Duration(milliseconds: 100),
    progressTimeout: const Duration(milliseconds: 100),
    seekTimeout: const Duration(milliseconds: 100),
    totalTimeout: const Duration(milliseconds: 500),
    progressPollInterval: const Duration(milliseconds: 1),
    cleanupTimeout: const Duration(milliseconds: 10),
  );
}

VideoPlayerPlaybackProbe _shortProgressProbe(
  _FakePlaybackController controller,
) {
  return VideoPlayerPlaybackProbe(
    controllerFactory: (_) => controller,
    initializationTimeout: const Duration(milliseconds: 100),
    progressTimeout: const Duration(milliseconds: 15),
    seekTimeout: const Duration(milliseconds: 100),
    totalTimeout: const Duration(milliseconds: 500),
    progressPollInterval: const Duration(milliseconds: 1),
    cleanupTimeout: const Duration(milliseconds: 10),
  );
}

Future<void> _expectProbeFailure(
  VideoPlayerPlaybackProbe probe,
  _FakePlaybackController controller,
  VideoPlaybackProbeFailureReason reason,
) async {
  await expectLater(
    probe.probe(_source),
    throwsA(
      isA<VideoPlaybackProbeException>().having(
        (error) => error.reason,
        'reason',
        reason,
      ),
    ),
  );
  expect(controller.calls, contains('pause'));
  expect(controller.calls, contains('dispose'));
}

final class _FakePlaybackController implements VideoPlaybackController {
  _FakePlaybackController({
    this.durationValue = const Duration(seconds: 12),
    this.positionValue = Duration.zero,
    this.widthValue = 1920,
    this.heightValue = 1080,
    this.aspectRatioValue = 16 / 9,
    this.initializeBehavior,
    this.pauseBehavior,
    this.seekBehavior,
    this.disposeBehavior,
  });

  final List<String> calls = <String>[];
  bool isInitializedValue = false;
  bool hasErrorValue = false;
  final Duration durationValue;
  final Duration positionValue;
  final double widthValue;
  final double heightValue;
  final double aspectRatioValue;
  final Future<void> Function()? initializeBehavior;
  final Future<void> Function()? pauseBehavior;
  final Future<void> Function()? seekBehavior;
  final Future<void> Function()? disposeBehavior;

  @override
  bool get isInitialized => isInitializedValue;

  @override
  bool get hasError => hasErrorValue;

  @override
  Duration get duration => durationValue;

  @override
  Duration get position => positionValue;

  @override
  double get width => widthValue;

  @override
  double get height => heightValue;

  @override
  double get aspectRatio => aspectRatioValue;

  @override
  Future<void> initialize() async {
    calls.add('initialize');
    await initializeBehavior?.call();
    isInitializedValue = true;
  }

  @override
  Future<void> setVolume(double volume) async {
    calls.add('volume:$volume');
  }

  @override
  Future<void> play() async {
    calls.add('play');
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    await pauseBehavior?.call();
  }

  @override
  Future<void> seekTo(Duration position) async {
    calls.add('seek:${position.inMicroseconds}');
    await seekBehavior?.call();
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    await disposeBehavior?.call();
  }
}
