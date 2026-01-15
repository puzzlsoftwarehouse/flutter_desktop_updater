import "dart:async";
import "dart:io";

import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/src/download.dart";
import "package:path/path.dart" as path;

/// Modified updateAppFunction to return a stream of UpdateProgress.
/// The stream emits total kilobytes, received kilobytes, and the currently downloading file's name.
Future<Stream<UpdateProgress>> updateAppFunction({
  required String remoteUpdateFolder,
  required List<FileHashModel?> changes,
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

  final responseStream = StreamController<UpdateProgress>();

  try {
    if (await dir.exists()) {
      if (changes.isEmpty) {
        print("No updates required.");
        await responseStream.close();
        return responseStream.stream;
      }

      var receivedBytes = 0.0;
      final totalFiles = changes.length;
      var completedFiles = 0;

      // Calculate total length in KB
      final totalLengthKB = changes.fold<double>(
        0,
        (previousValue, element) =>
            previousValue + ((element?.length ?? 0) / 1024.0),
      );

      // Track download results
      final downloadResults = <Map<String, dynamic>>[];
      final updateFolder = Directory(path.join(dir.path, "update"));

      final changesFutureList = <Future<dynamic>>[];

      for (final file in changes) {
        if (file != null) {
          final startTime = DateTime.now();
          changesFutureList.add(
            downloadFile(
              remoteUpdateFolder,
              file.filePath,
              dir.path,
              (received, total) {
                receivedBytes += received;
                responseStream.add(
                  UpdateProgress(
                    totalBytes: totalLengthKB,
                    receivedBytes: receivedBytes,
                    currentFile: file.filePath,
                    totalFiles: totalFiles,
                    completedFiles: completedFiles,
                  ),
                );
              },
            ).then((_) async {
              completedFiles += 1;
              final endTime = DateTime.now();
              final duration = endTime.difference(startTime);

              // Get file info
              final fullPath = path.join(updateFolder.path, file.filePath);
              final downloadedFile = File(fullPath);
              int fileSize = 0;
              bool fileExists = false;

              try {
                if (await downloadedFile.exists()) {
                  fileExists = true;
                  fileSize = await downloadedFile.length();
                }
              } catch (e) {
                // Ignore errors getting file size
              }

              downloadResults.add({
                "file": file.filePath,
                "status": "success",
                "size": fileSize,
                "expectedSize": file.length,
                "duration": duration.inMilliseconds,
                "startTime": startTime.toIso8601String(),
                "endTime": endTime.toIso8601String(),
                "exists": fileExists,
              });

              responseStream.add(
                UpdateProgress(
                  totalBytes: totalLengthKB,
                  receivedBytes: receivedBytes,
                  currentFile: file.filePath,
                  totalFiles: totalFiles,
                  completedFiles: completedFiles,
                ),
              );
              print("Completed: ${file.filePath}");
            }).catchError((error, stackTrace) {
              final endTime = DateTime.now();
              final duration = endTime.difference(startTime);

              downloadResults.add({
                "file": file.filePath,
                "status": "failed",
                "size": 0,
                "expectedSize": file.length,
                "duration": duration.inMilliseconds,
                "startTime": startTime.toIso8601String(),
                "endTime": endTime.toIso8601String(),
                "error": error.toString(),
                "exists": false,
              });

              print("ERROR: Failed to download file: ${file.filePath}");
              print("  Error: $error");
              print("  Stack trace: $stackTrace");
              responseStream.addError(
                Exception(
                  "Failed to download update file:\n"
                  "  File: ${file.filePath}\n"
                  "  Remote folder: $remoteUpdateFolder\n"
                  "  Error: $error"
                ),
                stackTrace,
              );
              return null;
            }),
          );
        }
      }

      unawaited(
        Future.wait(changesFutureList).then((_) async {
          // Generate and save download log
          await _saveDownloadLog(
            updateFolder: updateFolder,
            downloadResults: downloadResults,
            remoteUpdateFolder: remoteUpdateFolder,
            totalFiles: totalFiles,
          );

          await responseStream.close();
        }),
      );

      return responseStream.stream;
    }
  } catch (e, stackTrace) {
    print("ERROR: Failed to initialize update process");
    print("  Executable path: $executablePath");
    print("  Directory path: ${dir.path}");
    print("  Remote update folder: $remoteUpdateFolder");
    print("  Number of files to update: ${changes.length}");
    print("  Error: $e");
    print("  Stack trace: $stackTrace");
    responseStream.addError(
      Exception(
        "Failed to initialize update process:\n"
        "  Directory: ${dir.path}\n"
        "  Remote folder: $remoteUpdateFolder\n"
        "  Files to update: ${changes.length}\n"
        "  Error: $e"
      ),
      stackTrace,
    );
    await responseStream.close();
  }

  return responseStream.stream;
}

/// Saves a detailed log of the download process
Future<void> _saveDownloadLog({
  required Directory updateFolder,
  required List<Map<String, dynamic>> downloadResults,
  required String remoteUpdateFolder,
  required int totalFiles,
}) async {
  try {
    final timestamp = DateTime.now();
    final logFileName = "download_${timestamp.millisecondsSinceEpoch}.log";
    
    // Determine log directory based on platform
    Directory? logDir;
    if (Platform.isMacOS) {
      final appSupportDir = Platform.environment['HOME'];
      if (appSupportDir != null) {
        // Try to get bundle identifier from Info.plist
        final bundleId = await _getBundleIdFromInfoPlist();
        if (bundleId != null) {
          logDir = Directory(
            path.join(
              appSupportDir,
              "Library",
              "Application Support",
              bundleId,
              "logs",
            ),
          );
          // Create log directory if it doesn't exist
          if (!await logDir.exists()) {
            await logDir.create(recursive: true);
          }
        }
      }
    }

    // Fallback to update folder if no log directory found
    if (logDir == null || !await logDir.exists()) {
      logDir = updateFolder;
    }

    final logFile = File(path.join(logDir.path, logFileName));
    final sink = logFile.openWrite();

    // Calculate statistics
    final successful = downloadResults.where((r) => r["status"] == "success").length;
    final failed = downloadResults.where((r) => r["status"] == "failed").length;
    final totalSize = downloadResults.fold<int>(
      0,
      (sum, r) => sum + (r["size"] as int? ?? 0),
    );
    final expectedSize = downloadResults.fold<int>(
      0,
      (sum, r) => sum + (r["expectedSize"] as int? ?? 0),
    );
    final totalDuration = downloadResults.fold<int>(
      0,
      (sum, r) => sum + (r["duration"] as int? ?? 0),
    );

    // Write log header
    sink.writeln("=" * 80);
    sink.writeln("DOWNLOAD LOG - ${timestamp.toIso8601String()}");
    sink.writeln("=" * 80);
    sink.writeln("");
    sink.writeln("SUMMARY:");
    sink.writeln("  Remote folder: $remoteUpdateFolder");
    sink.writeln("  Update folder: ${updateFolder.path}");
    sink.writeln("  Total files: $totalFiles");
    sink.writeln("  Successful downloads: $successful");
    sink.writeln("  Failed downloads: $failed");
    sink.writeln("  Total downloaded size: ${_formatBytes(totalSize)}");
    sink.writeln("  Expected total size: ${_formatBytes(expectedSize)}");
    sink.writeln("  Total download time: ${_formatDuration(Duration(milliseconds: totalDuration))}");
    if (successful > 0) {
      sink.writeln("  Average download time: ${_formatDuration(Duration(milliseconds: totalDuration ~/ successful))}");
    }
    sink.writeln("");

    // Write detailed file information
    sink.writeln("=" * 80);
    sink.writeln("DETAILED FILE INFORMATION");
    sink.writeln("=" * 80);
    sink.writeln("");

    // Group by status
    final successfulFiles = downloadResults.where((r) => r["status"] == "success").toList();
    final failedFiles = downloadResults.where((r) => r["status"] == "failed").toList();

    if (successfulFiles.isNotEmpty) {
      sink.writeln("SUCCESSFUL DOWNLOADS (${successfulFiles.length}):");
      sink.writeln("-" * 80);
      for (final result in successfulFiles) {
        final file = result["file"] as String;
        final size = result["size"] as int;
        final expectedSize = result["expectedSize"] as int;
        final duration = Duration(milliseconds: result["duration"] as int);
        final startTime = result["startTime"] as String;
        final endTime = result["endTime"] as String;
        final sizeMatch = size == expectedSize ? "✓" : "⚠";

        sink.writeln("  File: $file");
        sink.writeln("    Status: SUCCESS $sizeMatch");
        sink.writeln("    Size: ${_formatBytes(size)} (expected: ${_formatBytes(expectedSize)})");
        sink.writeln("    Duration: ${_formatDuration(duration)}");
        sink.writeln("    Start: $startTime");
        sink.writeln("    End: $endTime");
        sink.writeln("");
      }
    }

    if (failedFiles.isNotEmpty) {
      sink.writeln("FAILED DOWNLOADS (${failedFiles.length}):");
      sink.writeln("-" * 80);
      for (final result in failedFiles) {
        final file = result["file"] as String;
        final expectedSize = result["expectedSize"] as int;
        final duration = Duration(milliseconds: result["duration"] as int);
        final error = result["error"] as String? ?? "Unknown error";
        final startTime = result["startTime"] as String;
        final endTime = result["endTime"] as String;

        sink.writeln("  File: $file");
        sink.writeln("    Status: FAILED ✗");
        sink.writeln("    Expected size: ${_formatBytes(expectedSize)}");
        sink.writeln("    Duration: ${_formatDuration(duration)}");
        sink.writeln("    Start: $startTime");
        sink.writeln("    End: $endTime");
        sink.writeln("    Error: $error");
        sink.writeln("");
      }
    }

    // Write directory tree with sizes
    sink.writeln("=" * 80);
    sink.writeln("DIRECTORY STRUCTURE WITH SIZES");
    sink.writeln("=" * 80);
    sink.writeln("");

    if (await updateFolder.exists()) {
      await _writeDirectoryTree(sink, updateFolder, updateFolder.path, 0);
    }

    sink.writeln("");
    sink.writeln("=" * 80);
    sink.writeln("END OF LOG");
    sink.writeln("=" * 80);

    await sink.close();
    
    // Print summary to console (minimal)
    print("Download log saved to: ${logFile.path}");
    print("Summary: $successful/$totalFiles successful, ${_formatBytes(totalSize)} downloaded");
    if (failed > 0) {
      print("Warning: $failed file(s) failed to download. See log for details.");
    }
  } catch (e, stackTrace) {
    print("ERROR: Failed to save download log: $e");
    print("Stack trace: $stackTrace");
  }
}

/// Gets bundle identifier from Info.plist (macOS)
Future<String?> _getBundleIdFromInfoPlist() async {
  if (!Platform.isMacOS) return null;
  
  try {
    final executablePath = Platform.resolvedExecutable;
    // Extract bundle path from executable path
    // /Applications/app.app/Contents/MacOS/app -> /Applications/app.app
    final bundleMatch = RegExp(r'^(.+\.app)/Contents/').firstMatch(executablePath);
    if (bundleMatch != null) {
      final bundlePath = bundleMatch.group(1);
      final infoPlistPath = path.join(bundlePath!, "Contents", "Info.plist");
      
      final infoPlistFile = File(infoPlistPath);
      if (await infoPlistFile.exists()) {
        // Read and parse Info.plist
        final content = await infoPlistFile.readAsString();
        
        // Simple XML parsing for CFBundleIdentifier
        // Look for <key>CFBundleIdentifier</key> followed by <string>value</string>
        final bundleIdMatch = RegExp(
          r'<key>CFBundleIdentifier</key>\s*<string>([^<]+)</string>',
          caseSensitive: false,
        ).firstMatch(content);
        
        if (bundleIdMatch != null) {
          return bundleIdMatch.group(1);
        }
      }
    }
  } catch (e) {
    // If we can't read Info.plist, fall back to extraction from path
    print("Warning: Could not read Info.plist, using fallback: $e");
  }
  
  // Fallback: try to extract from executable path
  final executablePath = Platform.resolvedExecutable;
  final match = RegExp(r'/([^/]+)\.app/Contents/').firstMatch(executablePath);
  if (match != null) {
    final appName = match.group(1);
    // Try common bundle ID patterns
    final possibleIds = [
      "com.puzzl.$appName",
      "com.$appName",
      "$appName",
    ];
    // Return first one that might work (we'll let the system handle if it doesn't exist)
    return possibleIds.first;
  }
  
  return null;
}

/// Formats bytes to human-readable string
String _formatBytes(int bytes) {
  if (bytes < 1024) {
    return "$bytes B";
  } else if (bytes < 1024 * 1024) {
    return "${(bytes / 1024).toStringAsFixed(2)} KB";
  } else if (bytes < 1024 * 1024 * 1024) {
    return "${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB";
  } else {
    return "${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB";
  }
}

/// Formats duration to human-readable string
String _formatDuration(Duration duration) {
  if (duration.inMilliseconds < 1000) {
    return "${duration.inMilliseconds}ms";
  } else if (duration.inSeconds < 60) {
    return "${duration.inSeconds}s";
  } else {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return "${minutes}m ${seconds}s";
  }
}

/// Writes directory tree with sizes to the log
Future<void> _writeDirectoryTree(
  IOSink sink,
  Directory dir,
  String basePath,
  int indent,
) async {
  try {
    final entries = dir.listSync();
    entries.sort((a, b) {
      // Directories first, then files
      if (a is Directory && b is File) return -1;
      if (a is File && b is Directory) return 1;
      return a.path.compareTo(b.path);
    });

    for (final entry in entries) {
      final relativePath = path.relative(entry.path, from: basePath);
      final indentStr = "  " * indent;
      
      if (entry is Directory) {
        int dirSize = 0;
        try {
          dirSize = await _getDirectorySize(entry);
        } catch (e) {
          // Ignore errors
        }
        sink.writeln("$indentStr📁 $relativePath/ (${_formatBytes(dirSize)})");
        await _writeDirectoryTree(sink, entry, basePath, indent + 1);
      } else if (entry is File) {
        int fileSize = 0;
        try {
          fileSize = await entry.length();
        } catch (e) {
          // Ignore errors
        }
        sink.writeln("$indentStr📄 $relativePath (${_formatBytes(fileSize)})");
      }
    }
  } catch (e) {
    // Ignore errors when listing directory
  }
}

/// Calculates total size of a directory recursively
Future<int> _getDirectorySize(Directory dir) async {
  int size = 0;
  try {
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File) {
        try {
          size += await entity.length();
        } catch (e) {
          // Ignore errors
        }
      }
    }
  } catch (e) {
    // Ignore errors
  }
  return size;
}
