import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import '../../theme/tokens.dart';

/// Round touch target with press scale and haptics, used by the media and
/// call controls.
class MediaButton extends StatefulWidget {
  const MediaButton({
    super.key,
    this.icon,
    this.child,
    required this.onTap,
    this.size = 44,
    this.iconSize = 22,
    this.color,
    this.background,
  }) : assert(icon != null || child != null);

  final IconData? icon;

  /// Drawn in place of [icon], for glyphs that are not Material icons.
  final Widget? child;
  final VoidCallback onTap;
  final double size;
  final double iconSize;
  final Color? color;
  final Color? background;

  @override
  State<MediaButton> createState() => _MediaButtonState();
}

class _MediaButtonState extends State<MediaButton> {
  bool _down = false;

  void _set(bool d) {
    if (_down != d) setState(() => _down = d);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      onTap: () {
        HapticFeedback.lightImpact();
        widget.onTap();
      },
      child: AnimatedScale(
        scale: _down ? 0.92 : 1,
        duration: DashMotion.fast,
        child: Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(shape: BoxShape.circle, color: widget.background),
          child: widget.child ?? Icon(widget.icon, size: widget.iconSize, color: widget.color),
        ),
      ),
    );
  }
}
