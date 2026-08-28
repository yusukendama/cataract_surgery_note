import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';

class VideoRegistrationGuidanceScreen extends StatelessWidget {
  const VideoRegistrationGuidanceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Semantics(headingLevel: 1, child: const Text('登録できる動画の目安')),
      ),
      body: SafeArea(
        child: ListView(
          key: const Key('video-registration-guidance'),
          padding: AppSpacing.screen,
          children: const [
            _GuidanceSection(
              title: '対応の目安',
              children: [
                Text('対応の目安は、MP4ファイル、H.264（AVC）映像、AAC音声です。音声がない動画も利用できます。'),
                SizedBox(height: AppSpacing.small),
                Text('詳細設定を選べる場合は、8bit、4:2:0、progressiveを目安にしてください。'),
                SizedBox(height: AppSpacing.small),
                Text(
                  '「.mp4」というファイル名でも、内部設定やファイルの状態によって再生できない場合があります。'
                  '用意した動画も、選択時に再生確認を行います。',
                ),
              ],
            ),
            SizedBox(height: AppSpacing.large),
            _GuidanceSection(
              title: '外部で動画を用意する場合',
              children: [
                _NumberedGuidanceItem(number: 1, text: '所属施設で承認された方法を確認します。'),
                _NumberedGuidanceItem(
                  number: 2,
                  text: '原則として、施設が承認した端末内・オフラインの方法で、元動画を上書きせず別ファイルを作成します。',
                ),
                _NumberedGuidanceItem(
                  number: 3,
                  text: 'MP4、H.264 / AVC、8bit、4:2:0、progressive、AACまたは音声なしを出力の目安にします。',
                ),
                _NumberedGuidanceItem(
                  number: 4,
                  text: 'トリミング、結合、速度変更、フレーム補間、不要な切り抜きは行いません。',
                ),
                _NumberedGuidanceItem(
                  number: 5,
                  text: '用意したファイルを白内障執刀ノートで改めて選択します。',
                ),
                _NumberedGuidanceItem(
                  number: 6,
                  text: '登録後に冒頭、中間、終端、動画の長さ、向き、音声を確認します。',
                ),
              ],
            ),
            SizedBox(height: AppSpacing.large),
            _WarningSection(
              icon: Icons.health_and_safety_outlined,
              title: '医療情報の取り扱い',
              paragraphs: [
                '手術動画は機微な医療情報として取り扱ってください。映像だけでなく、音声、ファイル名、メタデータにも患者を識別できる情報が含まれる場合があります。',
                '所属施設が明示的に承認していないWebサイトやクラウド変換サービスへ動画をアップロードしないでください。'
                    '使用できる方法が不明な場合は、所属施設の情報管理・個人情報保護担当者へ確認してください。',
                '「端末内処理」と表示する第三者アプリでも、テレメトリ、クラッシュログ、キャッシュ、バックアップ、'
                    'クラウド同期の有無を白内障執刀ノートは保証できません。',
                '変換元と変換後のファイルが残る場合があります。保管と廃棄は所属施設の規程に従ってください。'
                    '実際の患者動画をアプリのサポートへ送付しないでください。',
              ],
            ),
            SizedBox(height: AppSpacing.large),
            _WarningSection(
              icon: Icons.schedule_outlined,
              title: '工程位置について',
              paragraphs: [
                '変換により動画の長さや時刻位置が変わる場合があります。工程位置が記録済みの症例では、'
                    '以前その症例で使用したファイルから変換・編集・再書き出しした動画、または同じファイルか判断できない動画を'
                    '「同じ動画」として登録しないでください。工程位置を消去する選択肢を使用すると、既存の工程位置は消去されます。',
              ],
            ),
            SizedBox(height: AppSpacing.large),
            _GuidanceSection(
              title: 'サポート範囲',
              children: [
                Text(
                  '白内障執刀ノートのサポート対象は、登録できる動画の目安、再選択、アプリのエラーコードまでです。'
                  '第三者ツールの操作、契約、料金、出力品質、安全性、保存、削除、障害はサポート対象外です。',
                ),
              ],
            ),
            SizedBox(height: AppSpacing.large),
          ],
        ),
      ),
    );
  }
}

Future<void> openVideoRegistrationGuidance(BuildContext context) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => const VideoRegistrationGuidanceScreen(),
    ),
  );
}

class _GuidanceSection extends StatelessWidget {
  const _GuidanceSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          headingLevel: 2,
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
        const SizedBox(height: AppSpacing.small),
        ...children,
      ],
    );
  }
}

class _WarningSection extends StatelessWidget {
  const _WarningSection({
    required this.icon,
    required this.title,
    required this.paragraphs,
  });

  final IconData icon;
  final String title;
  final List<String> paragraphs;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: AppSpacing.card,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(child: Icon(icon, color: colorScheme.primary)),
                const SizedBox(width: AppSpacing.small),
                Expanded(
                  child: Semantics(
                    headingLevel: 2,
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.small),
            for (var index = 0; index < paragraphs.length; index++) ...[
              if (index > 0) const SizedBox(height: AppSpacing.small),
              Text(paragraphs[index]),
            ],
          ],
        ),
      ),
    );
  }
}

class _NumberedGuidanceItem extends StatelessWidget {
  const _NumberedGuidanceItem({required this.number, required this.text});

  final int number;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.small),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: AppSpacing.large,
            child: Text(
              '$number.',
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
