import 'package:flutter/material.dart';

import 'controller.dart';
import 'network_models.dart';

class ComputersList extends StatelessWidget {
  const ComputersList({
    super.key,
    required this.app,
    required this.onSelect,
    required this.workspaceBuilder,
  });
  final AppController app;
  final ValueChanged<String> onSelect;
  final Widget Function(BuildContext, String, String) workspaceBuilder;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Padding(
        padding: EdgeInsets.fromLTRB(20, 22, 20, 10),
        child: Text(
          'Computers',
          style: TextStyle(color: Color(0xff98a8b9), fontSize: 12),
        ),
      ),
      for (final computer in app.computers) ...[
        _row(context, computer),
        if (app.selectedComputerId == computer.origin.computerId &&
            app.computerWorkspacesExpanded)
          for (final workspace in app.sidebarWorkspaces.entries)
            Padding(
              padding: const EdgeInsets.only(left: 18),
              child: workspaceBuilder(context, workspace.key, workspace.value),
            ),
      ],
    ],
  );
  Widget _row(BuildContext context, ComputerInfo computer) {
    final id = computer.origin.computerId,
        label = app.computerLabel(computer.origin.computerId);
    final selected = app.selectedComputerId == id;
    final color = switch (computer.state) {
      ComputerState.live => const Color(0xff9ed48f),
      ComputerState.attention => const Color(0xffeac572),
      _ => const Color(0xff97a9bc),
    };
    return Semantics(
      label: 'Computer $label',
      button: true,
      selected: selected,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        decoration: BoxDecoration(
          color: selected ? const Color(0xff2b3e52) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: InkWell(
          key: ValueKey('computer-$id'),
          borderRadius: BorderRadius.circular(6),
          onTap: () {
            if (selected) {
              app.toggleComputerWorkspaces();
            } else {
              onSelect('computer:$id');
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Tooltip(
                  message: selected && app.computerWorkspacesExpanded
                      ? 'Collapse workspaces'
                      : 'Expand workspaces',
                  child: Icon(
                    selected && app.computerWorkspacesExpanded
                        ? Icons.expand_more
                        : Icons.chevron_right,
                    size: 16,
                    color: const Color(0xff97a9bc),
                  ),
                ),
                const SizedBox(width: 4),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    Icons.computer,
                    size: 17,
                    color: selected
                        ? const Color(0xffa1c2e6)
                        : const Color(0xff97a9bc),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Tooltip(
                        message: label,
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: selected
                                ? Colors.white
                                : const Color(0xffcad4df),
                            fontSize: 13,
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Container(
                            width: 5,
                            height: 5,
                            decoration: BoxDecoration(
                              color: color,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 5),
                          Expanded(
                            child: Text(
                              computer.stateLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: color, fontSize: 10),
                            ),
                          ),
                        ],
                      ),
                      if (computer.message.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text(
                            computer.message,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xffb8c5d3),
                              fontSize: 10,
                              height: 1.3,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
