/// A notice is based on server-published release metadata and this installed
/// package's build/certificate. Incoming chat payloads cannot supply version data.
class VerifiedAppUpdate {
  const VerifiedAppUpdate(this.id, this.build, this.url, this.sha256);
  final String id, url, sha256;
  final int build;
  static VerifiedAppUpdate? parse(Map<String, dynamic> installed, dynamic manifest, {DateTime? now}) {
    if (manifest is! Map || manifest['published'] != true || installed['package_id'] != 'app.calculatorspace.calculator_messenger' ||
        manifest['package_id'] != installed['package_id'] ||
        !const ['arm64-v8a', 'armeabi-v7a', 'x86_64'].contains(installed['abi']) || manifest['abi'] != installed['abi'] ||
        installed['build_number'] is! int ||
        manifest['build_number'] is! int || manifest['build_number'] <= installed['build_number'] ||
        installed['certificate_sha256'] is! String ||
        !RegExp(r'^[0-9A-F]{64}$').hasMatch(installed['certificate_sha256']) ||
        manifest['certificate_sha256'] != installed['certificate_sha256']) {
      return null;
    }
    final id = manifest['id'], hash = manifest['apk_sha256'], link = manifest['apk_url'];
    final published = DateTime.tryParse('${manifest['published_at']}');
    if (id is! String || !RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$').hasMatch(id) ||
        hash is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash) || link is! String ||
        published == null || published.isAfter(now ?? DateTime.now())) {
      return null;
    }
    final uri = Uri.tryParse(link);
    if (uri == null || uri.scheme != 'https' || uri.host != 'github.com' || uri.userInfo.isNotEmpty ||
        uri.port != 443 || uri.hasQuery || uri.hasFragment) {
      return null;
    }
    final segments = uri.pathSegments;
    if (segments.length != 6 || segments.take(4).join('/') != 'mvasagan099/Calculator-chat-apk/releases/download' ||
        segments.any((part) => part.isEmpty || part == '.' || part == '..' || part.contains('/') || part.contains('\\')) ||
        !segments.last.endsWith('.apk')) {
      return null;
    }
    return VerifiedAppUpdate(id, manifest['build_number'] as int, link, hash);
  }
}
