import "dart:async";
import "dart:convert";
import "dart:io";

import "package:cryptography_plus/cryptography_plus.dart";
import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/src/app_archive.dart";
import "package:flutter/material.dart";

Future<String> getFileHash(File file) async {
  try {
    // Dosya içeriğini okuyun
    final List<int> fileBytes = await file.readAsBytes();

    // blake2s algoritmasıyla hash hesaplayın

    final hash = await Blake2b().hash(fileBytes);

    // Hash'i utf-8 base64'e dönüştürün ve geri döndürün
    return base64.encode(hash.bytes);
  } catch (e) {
    debugPrint("Error reading file ${file.path}: $e");
    return "";
  }
}

Future<List<FileHashModel?>> verifyFileHashes(
  String oldHashFilePath,
  String newHashFilePath,
) async {
  if (oldHashFilePath == newHashFilePath) {
    return [];
  }

  final oldFile = File(oldHashFilePath);
  final newFile = File(newHashFilePath);

  if (!oldFile.existsSync() || !newFile.existsSync()) {
    throw Exception("Desktop Updater: Hash files do not exist");
  }

  final oldString = await oldFile.readAsString();
  final newString = await newFile.readAsString();

  // Decode as List<FileHashModel?>
  final oldHashes = (jsonDecode(oldString) as List<dynamic>)
      .map<FileHashModel?>(
        (e) => FileHashModel.fromJson(e as Map<String, dynamic>),
      )
      .toList();
  final newHashes = (jsonDecode(newString) as List<dynamic>)
      .map<FileHashModel?>(
        (e) => FileHashModel.fromJson(e as Map<String, dynamic>),
      )
      .toList();

  final changes = <FileHashModel?>[];

  for (final newHash in newHashes) {
    final oldHash = oldHashes.firstWhere(
      (element) => element?.filePath == newHash?.filePath,
      orElse: () => null,
    );

    if (oldHash == null || oldHash.calculatedHash != newHash?.calculatedHash) {
      changes.add(
        FileHashModel(
          filePath: newHash?.filePath ?? "",
          calculatedHash: newHash?.calculatedHash ?? "",
          length: newHash?.length ?? 0,
        ),
      );
    }
  }

  return changes;
}

// Dizin içindeki tüm dosyaların hash'lerini alıp bir dosyaya yazan fonksiyon
Future<String> genFileHashes({String? path}) async {
  path ??= Platform.resolvedExecutable;

  final directoryPath =
      path.substring(0, path.lastIndexOf(Platform.pathSeparator));

  var dir = Directory(directoryPath);

  if (Platform.isMacOS) {
    dir = dir.parent;
  }

  // Eğer belirtilen yol bir dizinse
  if (await dir.exists()) {
    // temp dizini oluşturulur
    final tempDir = await Directory.systemTemp.createTemp("desktop_updater");

    // temp dizinindeki dosyaları kopyala
    // dir + output.txt dosyası oluşturulur
    final outputFile =
        File("${tempDir.path}${Platform.pathSeparator}hashes.json");

    // Çıktı dosyasını açıyoruz
    final sink = outputFile.openWrite();

    // ignore: prefer_final_locals
    var hashList = <FileHashModel>[];

    // Dizin içindeki tüm dosyaları döngüyle okuyoruz
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        // Dosyanın hash'ini al
        final hash = await getFileHash(entity);

        final foundPath = entity.path.substring(dir.path.length + 1);

        // Dosya yolunu ve hash değerini yaz
        if (hash.isNotEmpty) {
          final hashObj = FileHashModel(
            filePath: foundPath,
            calculatedHash: hash,
            length: entity.lengthSync(),
          );
          hashList.add(hashObj);
        }
      }
    }

    // Dosya hash'lerini json formatına çevir
    final jsonStr = jsonEncode(hashList);

    // Çıktı dosyasına yaz
    sink.write(jsonStr);

    // Çıktıyı kaydediyoruz
    await sink.close();
    return outputFile.path;
  } else {
    throw Exception("Desktop Updater: Directory does not exist");
  }
}
