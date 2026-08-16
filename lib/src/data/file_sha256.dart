import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

String sha256OfBytes(List<int> bytes) {
  final digest = _Sha256Digest()..add(bytes);
  return digest.close();
}

Future<String> sha256OfFile(
  File file, {
  void Function(int bytesRead, int totalBytes)? onProgress,
  bool Function()? isCancelled,
  Future<void>? cancellationSignal,
  Future<int> Function(File file)? readLength,
  Stream<List<int>> Function(File file)? openRead,
}) async {
  final digest = _Sha256Digest();
  final totalBytes = await (readLength?.call(file) ?? file.length());
  var bytesRead = 0;
  var reachedEnd = false;
  final iterator = StreamIterator<List<int>>(
    openRead?.call(file) ?? file.openRead(),
  );
  try {
    while (true) {
      _throwIfHashCancelled(isCancelled);
      var cancellationWon = false;
      final hasNext = cancellationSignal == null
          ? await iterator.moveNext()
          : await Future.any<bool>(<Future<bool>>[
              iterator.moveNext(),
              cancellationSignal.then((_) {
                cancellationWon = true;
                return false;
              }),
            ]);
      if (cancellationWon) {
        throw const FileSystemException('動画の確認をキャンセルしました。');
      }
      if (!hasNext) {
        reachedEnd = true;
        break;
      }
      _throwIfHashCancelled(isCancelled);
      final chunk = iterator.current;
      digest.add(chunk);
      bytesRead += chunk.length;
      onProgress?.call(bytesRead, totalBytes);
    }
    _throwIfHashCancelled(isCancelled);
    return digest.close();
  } finally {
    if (!reachedEnd) {
      await iterator.cancel().timeout(
        const Duration(seconds: 1),
        onTimeout: () {},
      );
    }
  }
}

void _throwIfHashCancelled(bool Function()? isCancelled) {
  if (isCancelled?.call() ?? false) {
    throw const FileSystemException('動画の確認をキャンセルしました。');
  }
}

class _Sha256Digest {
  static const List<int> _roundConstants = <int>[
    0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2,
  ];

  final List<int> _state = <int>[
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19,
  ];
  final Uint8List _block = Uint8List(64);
  var _blockLength = 0;
  var _byteLength = 0;

  void add(List<int> bytes) {
    _byteLength += bytes.length;
    var offset = 0;
    while (offset < bytes.length) {
      final count = (64 - _blockLength).clamp(0, bytes.length - offset);
      _block.setRange(_blockLength, _blockLength + count, bytes, offset);
      _blockLength += count;
      offset += count;
      if (_blockLength == 64) {
        _compress(_block);
        _blockLength = 0;
      }
    }
  }

  String close() {
    final bitLength = _byteLength * 8;
    _block[_blockLength++] = 0x80;
    if (_blockLength > 56) {
      _block.fillRange(_blockLength, 64, 0);
      _compress(_block);
      _blockLength = 0;
    }
    _block.fillRange(_blockLength, 56, 0);
    for (var index = 0; index < 8; index++) {
      _block[63 - index] = (bitLength >> (index * 8)) & 0xff;
    }
    _compress(_block);
    return _state
        .map((value) => (value & 0xffffffff).toRadixString(16).padLeft(8, '0'))
        .join();
  }

  void _compress(Uint8List block) {
    final words = Uint32List(64);
    final data = ByteData.sublistView(block);
    for (var index = 0; index < 16; index++) {
      words[index] = data.getUint32(index * 4, Endian.big);
    }
    for (var index = 16; index < 64; index++) {
      final s0 =
          _rotateRight(words[index - 15], 7) ^
          _rotateRight(words[index - 15], 18) ^
          (words[index - 15] >> 3);
      final s1 =
          _rotateRight(words[index - 2], 17) ^
          _rotateRight(words[index - 2], 19) ^
          (words[index - 2] >> 10);
      words[index] =
          (words[index - 16] + s0 + words[index - 7] + s1) & 0xffffffff;
    }

    var a = _state[0];
    var b = _state[1];
    var c = _state[2];
    var d = _state[3];
    var e = _state[4];
    var f = _state[5];
    var g = _state[6];
    var h = _state[7];
    for (var index = 0; index < 64; index++) {
      final sum1 =
          _rotateRight(e, 6) ^ _rotateRight(e, 11) ^ _rotateRight(e, 25);
      final choose = (e & f) ^ ((~e) & g);
      final temporary1 =
          (h + sum1 + choose + _roundConstants[index] + words[index]) &
          0xffffffff;
      final sum0 =
          _rotateRight(a, 2) ^ _rotateRight(a, 13) ^ _rotateRight(a, 22);
      final majority = (a & b) ^ (a & c) ^ (b & c);
      final temporary2 = (sum0 + majority) & 0xffffffff;
      h = g;
      g = f;
      f = e;
      e = (d + temporary1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (temporary1 + temporary2) & 0xffffffff;
    }
    _state[0] = (_state[0] + a) & 0xffffffff;
    _state[1] = (_state[1] + b) & 0xffffffff;
    _state[2] = (_state[2] + c) & 0xffffffff;
    _state[3] = (_state[3] + d) & 0xffffffff;
    _state[4] = (_state[4] + e) & 0xffffffff;
    _state[5] = (_state[5] + f) & 0xffffffff;
    _state[6] = (_state[6] + g) & 0xffffffff;
    _state[7] = (_state[7] + h) & 0xffffffff;
  }

  int _rotateRight(int value, int amount) {
    return ((value >> amount) | (value << (32 - amount))) & 0xffffffff;
  }
}
