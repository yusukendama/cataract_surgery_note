import 'dart:async';

import 'package:cataract_surgery_note/src/domain/video_seek_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('seekTo完了前の連続タップを予定位置へ累積する', () async {
    final fake = _ControlledVideoSeek(
      position: const Duration(seconds: 20),
      duration: const Duration(minutes: 2),
    );
    final coordinator = fake.createCoordinator();

    final processing = coordinator.seekRelative(const Duration(seconds: 5));
    coordinator.seekRelative(const Duration(seconds: 5));
    coordinator.seekRelative(const Duration(seconds: 5));

    expect(fake.targets, [const Duration(seconds: 25)]);
    expect(coordinator.effectivePosition, const Duration(seconds: 35));

    fake.completeNext();
    await Future<void>.delayed(Duration.zero);
    expect(fake.targets, [
      const Duration(seconds: 25),
      const Duration(seconds: 35),
    ]);

    fake.completeNext();
    await processing;
    expect(fake.position, const Duration(seconds: 35));
  });

  test('戻る操作と進む操作を交互に行っても最終位置が正しい', () async {
    final fake = _ControlledVideoSeek(
      position: const Duration(seconds: 60),
      duration: const Duration(minutes: 2),
    );
    final coordinator = fake.createCoordinator();

    final processing = coordinator.seekRelative(const Duration(seconds: 15));
    coordinator.seekRelative(const Duration(seconds: -5));
    coordinator.seekRelative(const Duration(seconds: -15));

    fake.completeNext();
    await Future<void>.delayed(Duration.zero);
    expect(fake.targets.last, const Duration(seconds: 55));

    fake.completeNext();
    await processing;
    expect(fake.position, const Duration(seconds: 55));
  });

  test('先頭より前と末尾より後へのシークをクランプする', () async {
    final fake = _ControlledVideoSeek(
      position: const Duration(seconds: 3),
      duration: const Duration(seconds: 40),
    );
    final coordinator = fake.createCoordinator();

    final backward = coordinator.seekRelative(const Duration(seconds: -5));
    expect(fake.targets.single, Duration.zero);
    fake.completeNext();
    await backward;

    final forward = coordinator.seekTo(const Duration(seconds: 50));
    expect(fake.targets.last, const Duration(seconds: 40));
    fake.completeNext();
    await forward;
  });

  test('処理完了後の操作は実際の現在位置を新しい基準にする', () async {
    final fake = _ControlledVideoSeek(
      position: const Duration(seconds: 10),
      duration: const Duration(minutes: 2),
    );
    final coordinator = fake.createCoordinator();

    final first = coordinator.seekRelative(const Duration(seconds: 5));
    fake.completeNext();
    await first;

    fake.position = const Duration(seconds: 18);
    final second = coordinator.seekRelative(const Duration(seconds: 5));
    expect(fake.targets.last, const Duration(seconds: 23));
    fake.completeNext();
    await second;
  });
}

class _ControlledVideoSeek {
  _ControlledVideoSeek({required this.position, required this.duration});

  Duration position;
  final Duration duration;
  final List<Duration> targets = [];
  final List<Completer<void>> _completers = [];
  int _nextCompletion = 0;

  VideoSeekCoordinator createCoordinator() {
    return VideoSeekCoordinator(
      currentPosition: () => position,
      videoDuration: () => duration,
      seekTo: (target) {
        targets.add(target);
        final completer = Completer<void>();
        _completers.add(completer);
        return completer.future.then((_) => position = target);
      },
    );
  }

  void completeNext() {
    _completers[_nextCompletion++].complete();
  }
}
