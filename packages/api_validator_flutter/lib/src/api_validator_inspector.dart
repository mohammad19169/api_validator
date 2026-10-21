import 'dart:math' as math;

import 'package:api_validator/api_validator.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'inspector_model.dart';
import 'inspector_panel.dart';

/// A debug overlay that shows every API call your app made and whether it
/// matches your OpenAPI spec.
///
/// A small draggable badge shows how many calls conformed, had warnings or
/// had errors. Tapping it opens a panel listing the calls, newest first;
/// tapping a call shows each problem with its JSON path, plus the request
/// and response bodies.
///
/// The overlay is meant for developers only. [enabled] defaults to
/// [kDebugMode], so release builds get [child] back untouched.
///
/// ```dart
/// MaterialApp(
///   builder: ApiValidatorInspector.builder(checker),
///   home: const HomePage(),
/// );
/// ```
class ApiValidatorInspector extends StatefulWidget {
  /// Wraps [child] with the inspector for [checker].
  const ApiValidatorInspector({
    super.key,
    required this.checker,
    required this.child,
    this.enabled = kDebugMode,
    this.initialAlignment = Alignment.bottomRight,
    this.showWhenConforming = true,
  });

  /// The checker whose results are shown. Install an adapter
  /// (`api_validator_dio`, `api_validator_http`) so it receives
  /// your app's traffic.
  final ApiValidator checker;

  /// The app content.
  final Widget child;

  /// Whether the overlay is shown. When `false`, [child] is returned as is
  /// and the checker is not listened to.
  final bool enabled;

  /// Where the badge starts. It can then be dragged; it snaps to the
  /// nearest side, inside the safe area.
  final Alignment initialAlignment;

  /// Whether the badge stays visible while there are no errors or warnings.
  final bool showWhenConforming;

  /// A builder for [MaterialApp.builder] (or [WidgetsApp.builder]) that wraps
  /// the whole app, including every route, with the inspector.
  static TransitionBuilder builder(
    ApiValidator checker, {
    bool enabled = kDebugMode,
  }) =>
      (context, child) => ApiValidatorInspector(
        checker: checker,
        enabled: enabled,
        child: child ?? const SizedBox.shrink(),
      );

  @override
  State<ApiValidatorInspector> createState() => _ApiValidatorInspectorState();
}

class _ApiValidatorInspectorState extends State<ApiValidatorInspector> {
  static const _margin = 8.0;

  final GlobalKey _stackKey = GlobalKey();
  final GlobalKey _badgeKey = GlobalKey();
  InspectorModel? _model;
  OverlayEntry? _panelEntry;
  bool _panelInserted = false;
  Offset? _offset;

  @override
  void initState() {
    super.initState();
    if (widget.enabled) _model = InspectorModel(widget.checker);
  }

  @override
  void didUpdateWidget(ApiValidatorInspector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled && _model == null) {
      _model = InspectorModel(widget.checker);
    } else if (!widget.enabled && _model != null) {
      _disposeModel();
    } else {
      _model?.checker = widget.checker;
    }
  }

  @override
  void dispose() {
    _disposeModel();
    super.dispose();
  }

  void _disposeModel() {
    _removePanelEntry();
    _model?.dispose();
    _model = null;
    _offset = null;
  }

  void _openPanel() {
    final model = _model;
    if (model == null || _panelEntry != null) return;
    model.refresh();
    setState(() {
      _panelEntry = OverlayEntry(
        builder: (context) {
          _panelInserted = true;
          return _withFallbacks(
            context,
            InspectorPanel(model: model, onClose: _closePanel),
          );
        },
      );
    });
  }

  void _closePanel() {
    setState(_removePanelEntry);
  }

  void _removePanelEntry() {
    final entry = _panelEntry;
    if (entry == null) return;
    _panelEntry = null;
    if (_panelInserted) entry.remove();
    _panelInserted = false;
    entry.dispose();
  }

  RenderBox? _box(GlobalKey key) {
    final object = key.currentContext?.findRenderObject();
    return object is RenderBox && object.hasSize ? object : null;
  }

  void _startDrag(DragStartDetails details) {
    if (_offset != null) return;
    final stack = _box(_stackKey);
    final badge = _box(_badgeKey);
    if (stack == null || badge == null) return;
    setState(() {
      _offset = stack.globalToLocal(badge.localToGlobal(Offset.zero));
    });
  }

  void _drag(DragUpdateDetails details) {
    final offset = _offset;
    if (offset == null) return;
    setState(() => _offset = offset + details.delta);
  }

  void _endDrag(DragEndDetails details) {
    final offset = _offset;
    final stack = _box(_stackKey);
    final badge = _box(_badgeKey);
    if (offset == null || stack == null || badge == null) return;
    final padding = MediaQuery.maybePaddingOf(context) ?? EdgeInsets.zero;
    final size = stack.size;
    final minX = padding.left + _margin;
    final maxX = math.max(
      minX,
      size.width - badge.size.width - padding.right - _margin,
    );
    final minY = padding.top + _margin;
    final maxY = math.max(
      minY,
      size.height - badge.size.height - padding.bottom - _margin,
    );
    final centerX = offset.dx + badge.size.width / 2;
    setState(() {
      _offset = Offset(
        centerX < size.width / 2 ? minX : maxX,
        offset.dy.clamp(minY, maxY),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final model = _model;
    if (!widget.enabled || model == null) return widget.child;
    final panelEntry = _panelEntry;
    final stack = Stack(
      key: _stackKey,
      fit: StackFit.passthrough,
      children: [
        widget.child,
        if (panelEntry == null)
          ListenableBuilder(
            listenable: model,
            builder: (context, _) => _badgeLayer(context, model),
          ),
        if (panelEntry != null)
          Positioned.fill(
            child: Overlay(
              key: ObjectKey(panelEntry),
              initialEntries: [panelEntry],
            ),
          ),
      ],
    );
    if (Directionality.maybeOf(context) == null) {
      return Directionality(textDirection: TextDirection.ltr, child: stack);
    }
    return stack;
  }

  Widget _badgeLayer(BuildContext context, InspectorModel model) {
    final hasIssues = model.errorCount > 0 || model.warningCount > 0;
    if (!widget.showWhenConforming && !hasIssues) {
      return const SizedBox.shrink();
    }
    final badge = _Badge(
      key: _badgeKey,
      model: model,
      onTap: _openPanel,
      onPanStart: _startDrag,
      onPanUpdate: _drag,
      onPanEnd: _endDrag,
    );
    final offset = _offset;
    if (offset == null) {
      return Positioned.fill(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Align(alignment: widget.initialAlignment, child: badge),
          ),
        ),
      );
    }
    return Positioned(left: offset.dx, top: offset.dy, child: badge);
  }

  /// Supplies the inherited widgets the panel needs when the inspector is
  /// used outside a [MaterialApp].
  Widget _withFallbacks(BuildContext context, Widget child) {
    var result = child;
    if (Localizations.of<MaterialLocalizations>(
          context,
          MaterialLocalizations,
        ) ==
        null) {
      result = Localizations(
        locale: const Locale('en'),
        delegates: const [
          DefaultMaterialLocalizations.delegate,
          DefaultWidgetsLocalizations.delegate,
        ],
        child: result,
      );
    }
    if (MediaQuery.maybeOf(context) == null) {
      result = MediaQuery.fromView(view: View.of(context), child: result);
    }
    return result;
  }
}

class _Badge extends StatelessWidget {
  const _Badge({
    super.key,
    required this.model,
    required this.onTap,
    required this.onPanStart,
    required this.onPanUpdate,
    required this.onPanEnd,
  });

  final InspectorModel model;
  final VoidCallback onTap;
  final GestureDragStartCallback onPanStart;
  final GestureDragUpdateCallback onPanUpdate;
  final GestureDragEndCallback onPanEnd;

  @override
  Widget build(BuildContext context) {
    final errors = model.errorCount;
    final warnings = model.warningCount;
    final conforming = model.conformingCount;
    final color = errors > 0
        ? InspectorColors.error
        : warnings > 0
        ? InspectorColors.warning
        : InspectorColors.conforming;
    const textStyle = TextStyle(
      color: Colors.white,
      fontSize: 13,
      fontWeight: FontWeight.w600,
    );
    return Semantics(
      button: true,
      label:
          'API validation: $errors with errors, $warnings with warnings, '
          '$conforming conforming. Tap to open the inspector.',
      excludeSemantics: true,
      child: GestureDetector(
        key: const ValueKey('api-validator-badge'),
        onTap: onTap,
        onPanStart: onPanStart,
        onPanUpdate: onPanUpdate,
        onPanEnd: onPanEnd,
        child: Material(
          elevation: 6,
          color: color,
          shape: const StadiumBorder(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.check, size: 16, color: Colors.white),
                Text(' $conforming  ', style: textStyle),
                const Icon(
                  Icons.warning_amber_rounded,
                  size: 16,
                  color: Colors.white,
                ),
                Text(' $warnings  ', style: textStyle),
                const Icon(Icons.close, size: 16, color: Colors.white),
                Text(' $errors', style: textStyle),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
