class GitMetadata {
  const GitMetadata({
    this.branch = '',
    this.prNumber = 0,
    this.prState = '',
    this.prUrl = '',
  });
  final String branch, prState, prUrl;
  final int prNumber;
  bool get isEmpty => branch.isEmpty && prNumber == 0;
  static String text(Object? value, int max) =>
      value is String &&
          value.length <= max &&
          !value.runes.any((c) => c < 32 || c >= 127 && c < 160)
      ? value
      : '';
  static Uri? pullRequestUri(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !RegExp(r'^/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[1-9][0-9]*$')
            .hasMatch(uri.path)) {
      return null;
    }
    return uri;
  }

  factory GitMetadata.fromJson(Object? value) {
    if (value is! Map) return const GitMetadata();
    final number = value['prNumber'];
    final n = number is int && number > 0 && number < 10000000000 ? number : 0;
    final url = text(value['prUrl'], 2048),
        uri = pullRequestUri(text(value['prUrl'], 2048));
    return GitMetadata(
      branch: text(value['branch'], 256),
      prNumber: n,
      prState:
          const {'OPEN', 'DRAFT', 'MERGED', 'CLOSED'}.contains(value['prState'])
          ? value['prState'] as String
          : '',
      prUrl: n > 0 && uri != null && uri.pathSegments.last == '$n' ? url : '',
    );
  }
  Map<String, dynamic> toJson() => {
    'branch': branch,
    'prNumber': prNumber,
    'prState': prState,
    'prUrl': prUrl,
  };
}
