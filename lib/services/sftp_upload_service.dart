import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class SftpUploadService {
  final String host;
  final int port;
  final String username;
  final String? password;
  final String? privateKey;

  SftpUploadService({
    required this.host,
    this.port = 22,
    required this.username,
    this.password,
    this.privateKey,
  });

  /// Scans the local upload queue folder and uploads any pending video files via SFTP.
  /// Successfully uploaded files are deleted from the local disk.
  Future<void> uploadPendingFiles(String remoteDirPath) async {
    final docDir = await _getVisibleDirectory();
    final queueDir = Directory(p.join(docDir.path, 'esp32_upload_queue'));

    if (!await queueDir.exists()) {
      debugPrint('[SFTP] Queue directory does not exist. Nothing to upload.');
      return;
    }

    final files = queueDir.listSync().whereType<File>().where((f) => f.path.endsWith('.mp4')).toList();
    if (files.isEmpty) {
      debugPrint('[SFTP] No pending files found in upload queue.');
      return;
    }

    debugPrint('==================================================');
    debugPrint('[SFTP START] Uploading ${files.length} pending video files to $host...');
    debugPrint('==================================================');

    SSHClient? client;
    try {
      debugPrint('[SFTP] Connecting to SSH server $host:$port as $username...');
      client = SSHClient(
        await SSHSocket.connect(host, port, timeout: const Duration(seconds: 15)),
        username: username,
        onPasswordRequest: password != null ? () => password! : null,
        identities: privateKey != null ? SSHKeyPair.fromPem(privateKey!) : null,
      );

      debugPrint('[SFTP] Handshake completed. Starting SFTP client...');
      final sftp = await client.sftp();

      for (final file in files) {
        final fileName = p.basename(file.path);
        final remotePath = '$remoteDirPath/$fileName';

        debugPrint('--------------------------------------------------');
        debugPrint('[SFTP UPLOADING] File: $fileName -> $remotePath');
        debugPrint('--------------------------------------------------');

        try {
          final remoteFile = await sftp.open(
            remotePath,
            mode: SftpFileOpenMode.create | SftpFileOpenMode.write,
          );

          final fileStream = file.openRead().cast<Uint8List>();
          await remoteFile.write(fileStream);

          debugPrint('[SFTP SUCCESS] ✓ Uploaded: $fileName');
          await file.delete();
        } catch (fileErr) {
          debugPrint('[SFTP FILE ERROR] ✗ Failed uploading $fileName: $fileErr');
        }
      }
    } catch (e) {
      debugPrint('[SFTP ERROR] SSH/SFTP Connection Error: $e');
    } finally {
      client?.close();
      debugPrint('==================================================');
      debugPrint('[SFTP COMPLETE] SFTP upload run finished.');
      debugPrint('==================================================');
    }
  }

  Future<Directory> _getVisibleDirectory() async {
    if (Platform.isAndroid) {
      final downloadDir = Directory('/storage/emulated/0/Download/monitoring_driver');
      if (!await downloadDir.exists()) {
        try {
          await downloadDir.create(recursive: true);
        } catch (_) {
          final extDir = await getExternalStorageDirectory();
          return extDir!;
        }
      }
      return downloadDir;
    } else {
      return await getApplicationDocumentsDirectory();
    }



  }
}
