import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:openapi_conformance/openapi_conformance.dart';

import 'inspector_model.dart';

/// Colors used for the three result states.
abstract final class InspectorColors {
  /// Results without errors or warnings.
  static const conforming = Color(0xFF2E7D32);

  /// Results with warnings only.
  static const warning = Color(0xFFF9A825);

  /// Results with errors.
  static const error = Color(0xFFC62828);

  /// The color for [result].
  static Color of(ConformanceResult result) {
    if (!result.isConforming) return error;
    if (result.warnings.isNotEmpty) return warning;
    return conforming;
  }
}

/// The icon for [result].
IconData iconFor(ConformanceResult result) {
  if (!result.isConforming) return Icons.error;
  if (result.warnings.isNotEmpty) return Icons.warning_amber_rounded;
  return Icons.check_circle;
}

/// Which results the panel lists.
enum InspectorFilter {
  /// Every result.
  all,

  /// Results with errors.
  errors,

  /// Results with warnings and no errors.
  warnings,
}

/// The full-screen inspector panel: a filterable list of results and a
/// detail view for one result.
class InspectorPanel extends StatefulWidget {
  /// Creates the panel.
  const InspectorPanel({super.key, required this.model, required this.onClose});

  /// The results to show.
  final InspectorModel model;

  /// Called when the user closes the panel.
  final VoidCallback onClose;

  @override
  State<InspectorPanel> createState() => _InspectorPanelState();
}

class _InspectorPanelState extends State<InspectorPanel> {
  InspectorFilter _filter = InspectorFilter.all;
  String _query = '';
  ConformanceResult? _selected;

  bool _matches(ConformanceResult result) {
    final passesFilter = switch (_filter) {
      InspectorFilter.all => true,
      InspectorFilter.errors => !result.isConforming,
      InspectorFilter.warnings =>
        result.isConforming && result.warnings.isNotEmpty,
    };
    if (!passesFilter) return false;
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return true;
    final path = result.exchange.request.uri.path.toLowerCase();
    final template = result.operation?.path.toLowerCase() ?? '';
    return path.contains(query) || template.contains(query);
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const ValueKey('conformance-panel'),
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        child: ListenableBuilder(
          listenable: widget.model,
          builder: (context, _) {
            final selected = _selected;
            if (selected != null) {
              return ExchangeDetail(
                result: selected,
                onBack: () => setState(() => _selected = null),
              );
            }
            return _buildList(context);
          },
        ),
      ),
    );
  }

  Widget _buildList(BuildContext context) {
    final model = widget.model;
    final visible = model.results.where(_matches).toList();
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'API conformance',
                  style: theme.textTheme.titleLarge,
                ),
              ),
              TextButton.icon(
                key: const ValueKey('conformance-clear'),
                onPressed: model.results.isEmpty ? null : model.clear,
                icon: const Icon(Icons.delete_sweep_outlined),
                label: const Text('Clear'),
              ),
              IconButton(
                key: const ValueKey('conformance-close'),
                tooltip: 'Close inspector',
                onPressed: widget.onClose,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: TextField(
            key: const ValueKey('conformance-search'),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Filter by path',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (value) => setState(() => _query = value),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            children: [
              _chip(InspectorFilter.all, 'All (${model.results.length})'),
              _chip(InspectorFilter.errors, 'Errors (${model.errorCount})'),
              _chip(
                InspectorFilter.warnings,
                'Warnings (${model.warningCount})',
              ),
            ],
          ),
        ),
        const Divider(height: 16),
        Expanded(
          child: visible.isEmpty
              ? Center(
                  child: Text(
                    model.results.isEmpty
                        ? 'No API calls recorded yet'
                        : 'No calls match the filter',
                    style: theme.textTheme.bodyMedium,
                  ),
                )
              : ListView.separated(
                  key: const ValueKey('conformance-list'),
                  itemCount: visible.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) =>
                      _row(context, visible[index]),
                ),
        ),
      ],
    );
  }

  Widget _chip(InspectorFilter filter, String label) => ChoiceChip(
    key: ValueKey('conformance-filter-${filter.name}'),
    label: Text(label),
    selected: _filter == filter,
    onSelected: (_) => setState(() => _filter = filter),
  );

  Widget _row(BuildContext context, ConformanceResult result) {
    final request = result.exchange.request;
    final status = result.exchange.response?.statusCode;
    final issues = result.violations.length;
    return ListTile(
      dense: true,
      leading: Icon(iconFor(result), color: InspectorColors.of(result)),
      title: Text(
        '${request.method} ${result.operation?.path ?? request.uri.path}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        issues == 0
            ? request.uri.path
            : '$issues issue${issues == 1 ? '' : 's'} · ${request.uri.path}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(status?.toString() ?? '—'),
      onTap: () => setState(() => _selected = result),
    );
  }
}

/// Everything known about one exchange: request, operation, status,
/// violations and bodies.
class ExchangeDetail extends StatefulWidget {
  /// Creates the detail view.
  const ExchangeDetail({super.key, required this.result, required this.onBack});

  /// The result to show.
  final ConformanceResult result;

  /// Called when the user goes back to the list.
  final VoidCallback onBack;

  @override
  State<ExchangeDetail> createState() => _ExchangeDetailState();
}

class _ExchangeDetailState extends State<ExchangeDetail> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: exchangeReport(widget.result)));
    if (mounted) setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    final exchange = result.exchange;
    final request = exchange.request;
    final response = exchange.response;
    final theme = Theme.of(context);
    final operation = result.operation;
    return Column(
      key: const ValueKey('conformance-detail'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 8, 0),
          child: Row(
            children: [
              IconButton(
                key: const ValueKey('conformance-back'),
                tooltip: 'Back',
                onPressed: widget.onBack,
                icon: const Icon(Icons.arrow_back),
              ),
              Icon(iconFor(result), color: InspectorColors.of(result)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  result.label,
                  style: theme.textTheme.titleMedium,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton.icon(
                key: const ValueKey('conformance-copy'),
                onPressed: _copy,
                icon: Icon(_copied ? Icons.check : Icons.copy),
                label: Text(_copied ? 'Copied' : 'Copy report'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _Section(
                title: 'Request',
                child: SelectableText('${request.method} ${request.uri}'),
              ),
              _Section(
                title: 'Operation',
                child: Text(
                  operation == null
                      ? 'Not found in spec'
                      : operation.operationId == null
                      ? operation.key
                      : '${operation.key} (${operation.operationId})',
                ),
              ),
              _Section(
                title: 'Status',
                child: Text(
                  response == null
                      ? 'No response received'
                      : result.responseKey == null
                      ? '${response.statusCode} (not declared in spec)'
                      : '${response.statusCode} (matches ${result.responseKey})',
                ),
              ),
              _Section(
                title: 'Violations (${result.violations.length})',
                child: result.violations.isEmpty
                    ? const Text('None. This exchange matches the spec.')
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final violation in result.violations)
                            _ViolationTile(violation: violation),
                        ],
                      ),
              ),
              _Section(
                title: 'Request body',
                child: BodyView(text: formatBody(request.body)),
              ),
              if (response != null)
                _Section(
                  title: 'Response body',
                  child: BodyView(text: formatBody(response.body)),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
          child,
        ],
      ),
    );
  }
}

class _ViolationTile extends StatelessWidget {
  const _ViolationTile({required this.violation});

  final Violation violation;

  @override
  Widget build(BuildContext context) {
    final color = violation.isError
        ? InspectorColors.error
        : InspectorColors.warning;
    final theme = Theme.of(context);
    final path = violation.jsonPath;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: color, width: 4)),
        color: color.withValues(alpha: 0.08),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${violation.isError ? 'ERROR' : 'WARNING'} · '
            '${violation.location.label}',
            style: theme.textTheme.labelSmall?.copyWith(color: color),
          ),
          if (path != null)
            Text(
              path,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontWeight: FontWeight.bold,
              ),
            ),
          Text(violation.message),
        ],
      ),
    );
  }
}

/// Shows a body in a monospace font, truncating long bodies until the user
/// asks to see everything.
class BodyView extends StatefulWidget {
  /// Creates a body view. A `null` [text] means there is no body.
  const BodyView({super.key, required this.text, this.maxCharacters = 4000});

  /// The formatted body, or `null`.
  final String? text;

  /// How many characters are shown before "Show all" is offered.
  final int maxCharacters;

  @override
  State<BodyView> createState() => _BodyViewState();
}

class _BodyViewState extends State<BodyView> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final text = widget.text;
    if (text == null) return const Text('(no body)');
    final truncated = !_expanded && text.length > widget.maxCharacters;
    final shown = truncated ? text.substring(0, widget.maxCharacters) : text;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: SelectableText(
            truncated ? '$shown…' : shown,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
        if (truncated)
          TextButton(
            onPressed: () => setState(() => _expanded = true),
            child: Text('Show all (${text.length} characters)'),
          ),
      ],
    );
  }
}
