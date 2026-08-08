/// 横軸に表示する日付ラベルのインデックスを選ぶ。
///
/// 表示可能な幅では先頭と末尾を含め、隣り合うラベルの中心間距離を
/// [minimumGap] 以上に保つ。両端すら並べられない場合は末尾だけを返す。
List<int> selectDateLabelIndices({
  required int pointCount,
  required double plotWidth,
  required double minimumGap,
}) {
  if (pointCount <= 0) {
    return const [];
  }
  if (pointCount == 1) {
    return const [0];
  }

  final pointSpacing = plotWidth / (pointCount - 1);
  final selectedIndices = <int>[0];

  for (var index = 1; index < pointCount - 1; index++) {
    final distanceFromPrevious = (index - selectedIndices.last) * pointSpacing;
    if (distanceFromPrevious >= minimumGap) {
      selectedIndices.add(index);
    }
  }

  final lastIndex = pointCount - 1;
  while (selectedIndices.length > 1 &&
      (lastIndex - selectedIndices.last) * pointSpacing < minimumGap) {
    selectedIndices.removeLast();
  }
  if ((lastIndex - selectedIndices.last) * pointSpacing < minimumGap) {
    return [lastIndex];
  }

  return [...selectedIndices, lastIndex];
}
