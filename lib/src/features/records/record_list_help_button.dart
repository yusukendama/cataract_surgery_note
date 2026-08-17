import 'dart:async';

import 'package:flutter/material.dart';

import '../onboarding/onboarding_screen.dart';
import '../video_import/video_registration_guidance_screen.dart';

enum _RecordListHelpDestination { onboarding, videoGuidance }

class RecordListHelpButton extends StatelessWidget {
  const RecordListHelpButton({super.key});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_RecordListHelpDestination>(
      key: const Key('record-list-help-menu'),
      tooltip: 'ヘルプ',
      icon: const Icon(Icons.help_outline),
      onSelected: (destination) {
        switch (destination) {
          case _RecordListHelpDestination.onboarding:
            unawaited(openOnboardingGuide(context));
          case _RecordListHelpDestination.videoGuidance:
            unawaited(openVideoRegistrationGuidance(context));
        }
      },
      itemBuilder: (context) => const [
        PopupMenuItem(
          value: _RecordListHelpDestination.onboarding,
          child: ListTile(
            leading: Icon(Icons.auto_stories_outlined),
            title: Text('アプリの使い方'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          value: _RecordListHelpDestination.videoGuidance,
          child: ListTile(
            leading: Icon(Icons.video_file_outlined),
            title: Text('再登録できる動画の目安'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
    );
  }
}
