import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'git_metadata.dart';
import 'ui_common.dart';

class GitMetadataView extends StatelessWidget {
  const GitMetadataView({super.key, required this.metadata});
  final GitMetadata metadata;
  @override
  Widget build(BuildContext context) {
    if (metadata.isEmpty) return const SizedBox.shrink();
    final pr = metadata.prNumber > 0
        ? '#${metadata.prNumber}${metadata.prState.isEmpty ? '' : ' · ${metadata.prState.toLowerCase()}'}'
        : '';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (metadata.branch.isNotEmpty) ...[
          Icon(Icons.account_tree_outlined, size: 12, color: context.mutedInk),
          const SizedBox(width: 4),
          Flexible(
            child: Tooltip(
              message: metadata.branch,
              child: Text(
                metadata.branch,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: context.mutedInk, fontSize: 11),
              ),
            ),
          ),
        ],
        if (pr.isNotEmpty) ...[
          const SizedBox(width: 8),
          Flexible(
            child: InkWell(
              key: const ValueKey('open-current-pr'),
              onTap: metadata.prUrl.isEmpty
                  ? null
                  : () async {
                      final uri = GitMetadata.pullRequestUri(metadata.prUrl);
                      if (uri == null) return;
                      var opened = false;
                      try {
                        opened = await launchUrl(
                          uri,
                          mode: LaunchMode.externalApplication,
                        );
                      } catch (_) {}
                      if (!opened && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Could not open the pull request.'),
                          ),
                        );
                      }
                    },
              child: Tooltip(
                message: metadata.prUrl.isEmpty ? pr : metadata.prUrl,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    pr,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: metadata.prUrl.isEmpty
                          ? context.mutedInk
                          : context.accent,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
