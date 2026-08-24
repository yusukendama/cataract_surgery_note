import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/surgery_models.dart';

class AnalysisMetricSelector extends StatelessWidget {
  const AnalysisMetricSelector({
    required this.selectedStep,
    required this.onTap,
    super.key,
  });

  final SurgicalStep selectedStep;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        key: const Key('analysis-metric-selector'),
        title: const Text('表示する時間'),
        subtitle: Text(selectedStep.label),
        trailing: const Icon(Icons.unfold_more),
        onTap: onTap,
      ),
    );
  }
}

Future<SurgicalStep?> showAnalysisMetricPicker({
  required BuildContext context,
  required SurgicalStep selectedStep,
}) {
  return showModalBottomSheet<SurgicalStep>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: SizedBox(
        height: math.min(MediaQuery.sizeOf(context).height * 0.7, 620),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                '表示する時間',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: surgicalStepsInDisplayOrder.length,
                itemBuilder: (context, index) {
                  final step = surgicalStepsInDisplayOrder[index];
                  return ListTile(
                    key: Key('analysis-metric-${step.storageId}'),
                    title: Text(step.label),
                    trailing: step == selectedStep
                        ? const Icon(Icons.check)
                        : null,
                    selected: step == selectedStep,
                    onTap: () => Navigator.pop(context, step),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
