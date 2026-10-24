import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

class WindowsUpdateRelease {
  const WindowsUpdateRelease({
    required this.version,
    required this.notes,
    required this.installerUrl,
  });

  final String version;
  final String notes;
  final Uri installerUrl;
}

class WindowsUpdateService {
  static final Uri _latestReleaseUri =
      Uri.https('api.github.com', '/repos/theLuni/lumino/releases/latest');
  static final RegExp _versionPattern =
      RegExp(r'^\s*v?(\d+)\.(\d+)\.(\d+)(?:\+(\d+))?(?:[-+].*)?\s*$');
  static const int _maxInstallerBytes = 300 * 1024 * 1024;

  final http.Client _client = http.Client();

  Future<WindowsUpdateRelease?> checkForUpdate() async {
    final packageInfo = await PackageInfo.fromPlatform();
    final response = await _client.get(
      _latestReleaseUri,
      headers: const {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'Lumino-Updater',
      },
    ).timeout(const Duration(seconds: 20));
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'GitHub returned HTTP ${response.statusCode} while checking updates.',
        uri: _latestReleaseUri,
      );
    }

    final release = _decodeRelease(response.body);
    if (_compareVersions(release.version, packageInfo.version) <= 0) {
      return null;
    }
    return release;
  }

  Future<File> downloadInstaller(WindowsUpdateRelease release) async {
    final directory = await Directory.systemTemp.createTemp('lumino-update-');
    final file = File('${directory.path}${Platform.pathSeparator}Lumino.exe');
    var keepDownloadedFile = false;
    try {
      final request = http.Request('GET', release.installerUrl)
        ..headers['User-Agent'] = 'Lumino-Updater';
      final response =
          await _client.send(request).timeout(const Duration(minutes: 2));
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'GitHub returned HTTP ${response.statusCode} while downloading the update.',
          uri: release.installerUrl,
        );
      }
      final expectedLength = response.contentLength;
      if (expectedLength != null && expectedLength > _maxInstallerBytes) {
        throw const HttpException(
            'The update installer is unexpectedly large.');
      }

      final sink = file.openWrite();
      var receivedLength = 0;
      try {
        await for (final chunk
            in response.stream.timeout(const Duration(minutes: 2))) {
          receivedLength += chunk.length;
          if (receivedLength > _maxInstallerBytes) {
            throw const HttpException(
                'The update installer is unexpectedly large.');
          }
          sink.add(chunk);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      if (expectedLength != null && receivedLength != expectedLength) {
        throw const HttpException(
            'The update installer download was incomplete.');
      }
      final header = await file.open();
      final signature = await header.read(2);
      await header.close();
      if (signature.length != 2 ||
          signature[0] != 0x4D ||
          signature[1] != 0x5A) {
        throw const HttpException(
            'The downloaded update is not a Windows executable.');
      }
      if (!await _containsInnoSetupMarker(file)) {
        throw const HttpException(
          'The downloaded update is not an Inno Setup installer.',
        );
      }
      keepDownloadedFile = true;
      return file;
    } finally {
      if (!keepDownloadedFile) {
        await directory.delete(recursive: true);
      }
    }
  }

  void dispose() => _client.close();

  Future<bool> _containsInnoSetupMarker(File file) async {
    const marker = 'Inno Setup Setup Data';
    const carryLength = marker.length - 1;
    var carry = '';
    await for (final chunk in file.openRead()) {
      final window = carry + latin1.decode(chunk);
      if (window.contains(marker)) return true;
      carry = window.length <= carryLength
          ? window
          : window.substring(window.length - carryLength);
    }
    return false;
  }

  WindowsUpdateRelease _decodeRelease(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
          'GitHub returned an invalid release response.');
    }
    final version = decoded['name'];
    final assets = decoded['assets'];
    if (version is! String || _versionPattern.matchAsPrefix(version) == null) {
      throw const FormatException(
          'The GitHub release has no valid version name.');
    }
    if (assets is! List) {
      throw const FormatException(
          'The GitHub release does not contain installer assets.');
    }

    Map<String, dynamic>? installer;
    for (final asset in assets) {
      if (asset is Map<String, dynamic> &&
          asset['name'] is String &&
          (asset['name'] as String).toLowerCase() == 'lumino.exe' &&
          asset['browser_download_url'] is String) {
        installer = asset;
        break;
      }
    }
    if (installer == null) {
      throw const FormatException(
        'The GitHub release does not contain a Lumino.exe installer asset.',
      );
    }

    final installerUrl =
        Uri.tryParse(installer['browser_download_url'] as String);
    if (installerUrl == null ||
        installerUrl.scheme != 'https' ||
        installerUrl.host != 'github.com') {
      throw const FormatException('The GitHub installer URL is invalid.');
    }
    return WindowsUpdateRelease(
      version: version.trim(),
      notes:
          decoded['body'] is String ? (decoded['body'] as String).trim() : '',
      installerUrl: installerUrl,
    );
  }

  int _compareVersions(String first, String second) {
    final firstMatch = _versionPattern.firstMatch(first);
    final secondMatch = _versionPattern.firstMatch(second);
    if (firstMatch == null || secondMatch == null) {
      throw const FormatException('Could not compare application versions.');
    }
    for (var index = 1; index <= 4; index++) {
      final left = int.tryParse(firstMatch.group(index) ?? '0') ?? 0;
      final right = int.tryParse(secondMatch.group(index) ?? '0') ?? 0;
      if (left != right) return left.compareTo(right);
    }
    return 0;
  }
}
