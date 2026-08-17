import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';

enum OnboardingScreenMode { initial, replay }

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen.initial({required this.onComplete, super.key})
    : mode = OnboardingScreenMode.initial;

  const OnboardingScreen.replay({super.key})
    : mode = OnboardingScreenMode.replay,
      onComplete = null;

  final OnboardingScreenMode mode;
  final Future<void> Function()? onComplete;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  static final _lastPageIndex = _pages.length - 1;

  final PageController _pageController = PageController();
  int _pageIndex = 0;
  bool _isCompleting = false;

  bool get _isReplay => widget.mode == OnboardingScreenMode.replay;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canSystemPop = _isReplay || _pageIndex == 0;
    return PopScope<void>(
      canPop: canSystemPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_isReplay && _pageIndex > 0) {
          unawaited(_moveToPage(_pageIndex - 1));
        }
      },
      child: Scaffold(
        key: const Key('onboarding-screen'),
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: Text(_isReplay ? 'アプリの使い方' : '白内障執刀ノート'),
          actions: [
            if (_isReplay)
              TextButton(
                key: const Key('onboarding-top-close'),
                onPressed: _isCompleting ? null : _closeReplay,
                child: const Text('閉じる'),
              )
            else if (_pageIndex < _lastPageIndex)
              TextButton(
                key: const Key('onboarding-skip'),
                onPressed: _isCompleting
                    ? null
                    : () => unawaited(_moveToPage(_lastPageIndex)),
                child: const Text('スキップ'),
              ),
            const SizedBox(width: AppSpacing.small),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              Expanded(
                child: PageView.builder(
                  key: const Key('onboarding-pages'),
                  controller: _pageController,
                  physics: _isCompleting
                      ? const NeverScrollableScrollPhysics()
                      : const PageScrollPhysics(),
                  itemCount: _pages.length,
                  onPageChanged: (index) {
                    if (mounted) {
                      setState(() => _pageIndex = index);
                    }
                  },
                  itemBuilder: (context, index) {
                    return _OnboardingPage(
                      key: ValueKey('onboarding-page-$index'),
                      page: _pages[index],
                      index: index,
                    );
                  },
                ),
              ),
              _PageIndicator(pageIndex: _pageIndex, pageCount: _pages.length),
              const SizedBox(height: AppSpacing.medium),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.medium,
                  0,
                  AppSpacing.medium,
                  AppSpacing.medium,
                ),
                child: _buildNavigation(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNavigation(BuildContext context) {
    final onLastPage = _pageIndex == _lastPageIndex;
    final primaryLabel = onLastPage
        ? _isReplay
              ? '閉じる'
              : 'はじめる'
        : '次へ';
    final primaryKey = onLastPage
        ? _isReplay
              ? const Key('onboarding-finish-close')
              : const Key('onboarding-finish')
        : const Key('onboarding-next');

    final primary = FilledButton(
      key: primaryKey,
      onPressed: _isCompleting
          ? null
          : onLastPage
          ? _isReplay
                ? _closeReplay
                : () => unawaited(_completeInitial())
          : () => unawaited(_moveToPage(_pageIndex + 1)),
      child: _isCompleting && onLastPage
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(primaryLabel),
    );

    if (_pageIndex == 0) {
      return SizedBox(width: double.infinity, child: primary);
    }
    return Row(
      children: [
        Expanded(
          child: TextButton(
            key: const Key('onboarding-back'),
            onPressed: _isCompleting
                ? null
                : () => unawaited(_moveToPage(_pageIndex - 1)),
            child: const Text('戻る'),
          ),
        ),
        const SizedBox(width: AppSpacing.small),
        Expanded(child: primary),
      ],
    );
  }

  Future<void> _moveToPage(int index) async {
    if (_isCompleting || index < 0 || index >= _pages.length) {
      return;
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      _pageController.jumpToPage(index);
      return;
    }
    await _pageController.animateToPage(
      index,
      duration: AppMotion.standard,
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _completeInitial() async {
    if (_isCompleting) {
      return;
    }
    setState(() => _isCompleting = true);
    try {
      await widget.onComplete!();
    } finally {
      if (mounted) {
        setState(() => _isCompleting = false);
      }
    }
  }

  void _closeReplay() {
    if (!_isCompleting) {
      unawaited(Navigator.of(context).maybePop());
    }
  }
}

Future<void> openOnboardingGuide(BuildContext context) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(builder: (_) => const OnboardingScreen.replay()),
  );
}

class _OnboardingPage extends StatelessWidget {
  const _OnboardingPage({required this.page, required this.index, super.key});

  final _OnboardingPageData page;
  final int index;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          key: ValueKey('onboarding-page-scroll-$index'),
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.medium,
            AppSpacing.medium,
            AppSpacing.medium,
            AppSpacing.small,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: constraints.maxHeight > 24
                  ? constraints.maxHeight - 24
                  : 0,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ExcludeSemantics(
                  child: Icon(page.icon, size: 64, color: colorScheme.primary),
                ),
                const SizedBox(height: AppSpacing.large),
                Semantics(
                  header: true,
                  child: Text(
                    page.title,
                    key: ValueKey('onboarding-page-title-$index'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (page.body.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.small),
                  Text(
                    page.body,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: AppSpacing.large),
                for (
                  var itemIndex = 0;
                  itemIndex < page.items.length;
                  itemIndex++
                ) ...[
                  if (itemIndex > 0) const SizedBox(height: AppSpacing.small),
                  _OnboardingItem(item: page.items[itemIndex]),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _OnboardingItem extends StatelessWidget {
  const _OnboardingItem({required this.item});

  final _OnboardingItemData item;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppRadii.medium),
      ),
      child: Padding(
        padding: AppSpacing.card,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ExcludeSemantics(
              child: Icon(item.icon, color: colorScheme.primary),
            ),
            const SizedBox(width: AppSpacing.medium),
            Expanded(child: Text(item.text)),
          ],
        ),
      ),
    );
  }
}

class _PageIndicator extends StatelessWidget {
  const _PageIndicator({required this.pageIndex, required this.pageCount});

  final int pageIndex;
  final int pageCount;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final label = '$pageCountページ中${pageIndex + 1}ページ目';
    return Semantics(
      key: const Key('onboarding-page-indicator'),
      container: true,
      liveRegion: true,
      label: label,
      child: ExcludeSemantics(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(pageCount, (index) {
            final selected = index == pageIndex;
            return AnimatedContainer(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : AppMotion.standard,
              width: selected ? 24 : 8,
              height: 8,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                color: selected
                    ? colorScheme.primary
                    : colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(AppRadii.small),
              ),
            );
          }),
        ),
      ),
    );
  }
}

class _OnboardingPageData {
  const _OnboardingPageData({
    required this.icon,
    required this.title,
    required this.body,
    required this.items,
  });

  final IconData icon;
  final String title;
  final String body;
  final List<_OnboardingItemData> items;
}

class _OnboardingItemData {
  const _OnboardingItemData({required this.icon, required this.text});

  final IconData icon;
  final String text;
}

const _pages = <_OnboardingPageData>[
  _OnboardingPageData(
    icon: Icons.visibility_outlined,
    title: '手術を、振り返りにつなげる',
    body: '白内障手術の動画と工程記録を症例ごとにまとめ、振り返りと分析に活用できます。',
    items: [
      _OnboardingItemData(
        icon: Icons.video_library_outlined,
        text: '症例と動画をまとめて管理',
      ),
      _OnboardingItemData(icon: Icons.timer_outlined, text: '工程ごとの開始・終了位置を記録'),
      _OnboardingItemData(
        icon: Icons.edit_note_outlined,
        text: '自己評価、反省点、症例メモで振り返り',
      ),
    ],
  ),
  _OnboardingPageData(
    icon: Icons.video_file_outlined,
    title: '動画を選んで症例を記録',
    body: '新規症例から手術動画を選び、手術日と左右眼を登録します。登録後は、動画を見ながら工程ごとに記録できます。',
    items: [
      _OnboardingItemData(
        icon: Icons.looks_one_outlined,
        text: 'ファイル選択画面から手術動画を選ぶ',
      ),
      _OnboardingItemData(icon: Icons.looks_two_outlined, text: '手術日と左右眼を入力する'),
      _OnboardingItemData(
        icon: Icons.looks_3_outlined,
        text: '動画を見ながら工程と振り返りを記録する',
      ),
    ],
  ),
  _OnboardingPageData(
    icon: Icons.health_and_safety_outlined,
    title: '医療情報を安全に取り扱う',
    body: '',
    items: [
      _OnboardingItemData(
        icon: Icons.smartphone_outlined,
        text: '症例記録とアプリ内に保存した動画は、この端末のアプリ領域に保存されます。本アプリ独自のクラウド同期・共有機能はありません。',
      ),
      _OnboardingItemData(
        icon: Icons.backup_outlined,
        text: 'アプリ内の動画は端末バックアップの対象外です。選択元の動画は、所属施設の規程に従って別途保管してください。',
      ),
      _OnboardingItemData(
        icon: Icons.privacy_tip_outlined,
        text: '動画、音声、ファイル名、メタデータに患者を識別できる情報が含まれる場合があります。所属施設の規程に従って取り扱ってください。',
      ),
    ],
  ),
];
