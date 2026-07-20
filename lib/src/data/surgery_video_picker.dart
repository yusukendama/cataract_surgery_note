import 'dart:io';

import 'package:file_picker/file_picker.dart';

class SelectedSurgeryVideo {
  const SelectedSurgeryVideo({required this.path, required this.displayName});

  final String path;
  final String displayName;
}

abstract interface class SurgeryVideoPicker {
  Future<SelectedSurgeryVideo?> pickVideo();
}

class FilePickerSurgeryVideoPicker implements SurgeryVideoPicker {
  const FilePickerSurgeryVideoPicker();

  @override
  Future<SelectedSurgeryVideo?> pickVideo() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['mp4', 'mov', 'm4v'],
    );
    if (result == null) {
      return null;
    }
    final selected = result.files.single;
    final path = selected.path;
    if (path == null) {
      throw const FileSystemException('選択した動画のパスを取得できませんでした。');
    }
    return SelectedSurgeryVideo(path: path, displayName: selected.name);
  }
}
