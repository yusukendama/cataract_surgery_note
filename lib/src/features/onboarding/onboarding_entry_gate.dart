import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/onboarding_state_repository.dart';
import '../../data/providers.dart';
import '../../theme/app_tokens.dart';
import 'onboarding_screen.dart';

enum _OnboardingEntryState { checking, onboarding, ready }

class OnboardingEntryGate extends ConsumerStatefulWidget {
  const OnboardingEntryGate({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<OnboardingEntryGate> createState() =>
      _OnboardingEntryGateState();
}

class _OnboardingEntryGateState extends ConsumerState<OnboardingEntryGate> {
  _OnboardingEntryState _state = _OnboardingEntryState.checking;
  OnboardingStateRepository? _stateRepository;
  bool _completionStarted = false;

  @override
  void initState() {
    super.initState();
    unawaited(_resolveEntry());
  }

  @override
  Widget build(BuildContext context) {
    return switch (_state) {
      _OnboardingEntryState.checking => const _OnboardingDecisionLoading(),
      _OnboardingEntryState.onboarding => OnboardingScreen.initial(
        onComplete: _completeOnboarding,
      ),
      _OnboardingEntryState.ready => widget.child,
    };
  }

  Future<void> _resolveEntry() async {
    late final OnboardingStateRepository repository;
    int? completedVersion;
    try {
      repository = ref.read(onboardingStateRepositoryProvider);
      _stateRepository = repository;
      completedVersion = await repository.readCompletedVersion();
      if (completedVersion != null && completedVersion < 0) {
        throw const FormatException('Invalid onboarding version.');
      }
    } on Object {
      _showReady();
      return;
    }

    if (completedVersion != null &&
        completedVersion >= currentOnboardingVersion) {
      _showReady();
      return;
    }

    late final bool hasRecords;
    try {
      hasRecords = await ref.read(onboardingRecordExistsProvider.future);
    } on Object {
      _showReady();
      return;
    }

    if (hasRecords) {
      _showReady();
      unawaited(_markExistingUserComplete(repository));
      return;
    }

    if (mounted) {
      setState(() => _state = _OnboardingEntryState.onboarding);
    }
  }

  Future<void> _completeOnboarding() async {
    if (_completionStarted) {
      return;
    }
    _completionStarted = true;
    final repository = _stateRepository;
    if (repository != null) {
      try {
        await repository.writeCompletedVersion(currentOnboardingVersion);
      } on Object {
        // Onboarding preferences are not allowed to block protected records.
      }
    }
    _showReady();
  }

  Future<void> _markExistingUserComplete(
    OnboardingStateRepository repository,
  ) async {
    try {
      await repository.writeCompletedVersion(currentOnboardingVersion);
    } on Object {
      // Existing users must reach their records even if preferences fail.
    }
  }

  void _showReady() {
    if (mounted) {
      setState(() => _state = _OnboardingEntryState.ready);
    }
  }
}

class _OnboardingDecisionLoading extends StatelessWidget {
  const _OnboardingDecisionLoading();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('onboarding-decision-loading'),
      body: SafeArea(
        child: Center(
          child: Semantics(
            container: true,
            liveRegion: true,
            label: '起動しています',
            child: const Padding(
              padding: AppSpacing.screen,
              child: CircularProgressIndicator(),
            ),
          ),
        ),
      ),
    );
  }
}
