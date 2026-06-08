import 'dart:convert';

import 'package:upgrader/upgrader.dart';
import 'package:version/version.dart';

/// An [UpgraderStore] that checks the latest GitHub Release for a new version.
///
/// Tag names must follow SemVer with an optional leading "v", e.g. "v1.0.3"
/// or "1.0.3". Pre-release tags are ignored.
class GitHubReleasesStore extends UpgraderStore {
  GitHubReleasesStore({required this.owner, required this.repo});

  final String owner;
  final String repo;

  @override
  Future<UpgraderVersionInfo> getVersionInfo({
    required UpgraderState state,
    required Version installedVersion,
    required String? country,
    required String? language,
  }) async {
    final uri = Uri.https(
      'api.github.com',
      '/repos/$owner/$repo/releases/latest',
    );

    try {
      final response = await state.client.get(
        uri,
        headers: {'Accept': 'application/vnd.github+json'},
      );

      if (response.statusCode != 200) return UpgraderVersionInfo();

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final tagName = data['tag_name'] as String? ?? '';
      final htmlUrl = data['html_url'] as String? ?? '';
      final body = data['body'] as String? ?? '';

      // Strip leading "v" and parse; ignore drafts and pre-releases.
      final isDraft = data['draft'] as bool? ?? false;
      final isPrerelease = data['prerelease'] as bool? ?? false;
      if (isDraft || isPrerelease) return UpgraderVersionInfo();

      final clean = tagName.startsWith('v') ? tagName.substring(1) : tagName;
      final appStoreVersion = Version.parse(clean);

      return UpgraderVersionInfo(
        installedVersion: installedVersion,
        appStoreVersion: appStoreVersion,
        appStoreListingURL: htmlUrl,
        releaseNotes: body.isNotEmpty ? body : null,
      );
    } catch (_) {
      return UpgraderVersionInfo();
    }
  }
}
