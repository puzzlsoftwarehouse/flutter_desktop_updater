import "dart:convert";
import "dart:io";

import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/src/file_hash.dart";
import "package:http/http.dart" as http;
import "package:path/path.dart" as path;

Future<ItemModel?> versionCheckFunction({
  required String appArchiveUrl,
}) async {
  final executablePath = Platform.resolvedExecutable;

  final directoryPath = executablePath.substring(
    0,
    executablePath.lastIndexOf(Platform.pathSeparator),
  );

  var dir = Directory(directoryPath);

  if (Platform.isMacOS) {
    dir = dir.parent;
  }

  // Eğer belirtilen yol bir dizinse
  if (await dir.exists()) {
    final tempDir = await Directory.systemTemp.createTemp("desktop_updater");
    final client = http.Client();

    final appArchive = http.Request("GET", Uri.parse(appArchiveUrl));
    final appArchiveResponse = await client.send(appArchive);

    // temp dizinindeki dosyaları kopyala
    // dir + output.txt dosyası oluşturulur
    final outputFile =
        File("${tempDir.path}${Platform.pathSeparator}app-archive.json");

    // Çıktı dosyasını açıyoruz
    final sink = outputFile.openWrite();

    // Save the file
    await appArchiveResponse.stream.pipe(sink);

    // Close the file
    await sink.close();

    if (!outputFile.existsSync()) {
      throw Exception("Desktop Updater: App archive do not exist");
    }

    final appArchiveString = await outputFile.readAsString();

    // Decode as List<FileHashModel?>
    final appArchiveDecoded = AppArchiveModel.fromJson(
      jsonDecode(appArchiveString),
    );

    final versions = appArchiveDecoded.items
        .where(
          (element) => element.platform == Platform.operatingSystem,
        )
        .toList();

    if (versions.isEmpty) {
      throw Exception("Desktop Updater: No version found for this platform");
    }

    // Get the latest version with shortVersion number
    final latestVersion = versions.reduce(
      (value, element) {
        if (value.shortVersion > element.shortVersion) {
          return value;
        }
        return element;
      },
    );

    late String? currentVersion;

    if (Platform.isLinux) {
      final exePath = await File("/proc/self/exe").resolveSymbolicLinks();
      final appPath = path.dirname(exePath);
      final assetPath = path.join(appPath, "data", "flutter_assets");
      final versionPath = path.join(assetPath, "version.json");
      final versionJson = jsonDecode(await File(versionPath).readAsString());
      currentVersion = versionJson["build_number"];
    } else {
      await DesktopUpdater().getCurrentVersion().then(
        (value) {
          currentVersion = value;
        },
      );
    }

    if (currentVersion == null) {
      throw Exception("Desktop Updater: Current version is null");
    }

    if (latestVersion.shortVersion > int.parse(currentVersion!)) {
      final tempDir = await Directory.systemTemp.createTemp("desktop_updater");
      final client = http.Client();

      final newHashFileUrl = "${latestVersion.url}/hashes.json";
      final newHashFileRequest = http.Request("GET", Uri.parse(newHashFileUrl));
      final newHashFileResponse = await client.send(newHashFileRequest);

      if (newHashFileResponse.statusCode != 200) {
        client.close();
        throw const HttpException("Failed to download hashes.json");
      }

      final outputFile =
          File("${tempDir.path}${Platform.pathSeparator}hashes.json");
      final sink = outputFile.openWrite();

      await newHashFileResponse.stream.listen(
        sink.add,
        onDone: () async {
          await sink.close();
          client.close();
        },
        onError: (e) async {
          await sink.close();
          client.close();
          throw e;
        },
        cancelOnError: true,
      ).asFuture();

      final oldHashFilePath = await genFileHashes();
      final newHashFilePath = outputFile.path;

      final changedFiles = await verifyFileHashes(
        oldHashFilePath,
        newHashFilePath,
      );

      return latestVersion.copyWith(
        changedFiles: changedFiles,
        appName: appArchiveDecoded.appName,
      );
    }
  }
  return null;
}
