import 'package:flutter/material.dart';

import '../../icons/lucide_adapter.dart';
import '../../theme/app_font_weights.dart';
import 'ios_tactile.dart';

/// Block fill translucency hierarchy (issue #298): markdown blocks paint a
/// translucent tint instead of an opaque surface so the chat wallpaper and
/// frosted bubbles show through. Details are pure UI chrome (lowest opacity),
/// tables are data surfaces (middle), code blocks and preview islands carry
/// content that needs a readability mask (highest).
const double kBlockFillAlphaDetails = 0.55;
const double kBlockFillAlphaTable = 0.72;
const double kBlockFillAlphaContent = 0.90;

class PreviewBlockColors {
  const PreviewBlockColors({
    required this.body,
    required this.header,
    required this.border,
    required this.tabTrack,
    required this.tabSelected,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
  });

  final Color body;
  final Color header;
  final Color border;
  final Color tabTrack;
  final Color tabSelected;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;

  static PreviewBlockColors resolve(bool isDark, ColorScheme cs) {
    final surface = cs.surface;
    final onSurface = cs.onSurface;
    if (isDark) {
      return PreviewBlockColors(
        body: Color.alphaBlend(
          onSurface.withValues(alpha: 0.06),
          surface,
        ).withValues(alpha: kBlockFillAlphaContent),
        header: Color.alphaBlend(
          onSurface.withValues(alpha: 0.10),
          surface,
        ).withValues(alpha: kBlockFillAlphaContent),
        border: cs.outlineVariant.withValues(alpha: 0.35),
        tabTrack: Color.alphaBlend(
          onSurface.withValues(alpha: 0.05),
          surface,
        ).withValues(alpha: 0.75),
        tabSelected: Color.alphaBlend(
          onSurface.withValues(alpha: 0.12),
          surface,
        ).withValues(alpha: 0.95),
        textPrimary: const Color(0xFFE6E6E6),
        textSecondary: const Color(0xFFA0A0A0),
        textTertiary: const Color(0xFF707070),
      );
    }

    return PreviewBlockColors(
      body: Color.alphaBlend(
        onSurface.withValues(alpha: 0.03),
        surface,
      ).withValues(alpha: kBlockFillAlphaContent),
      header: Color.alphaBlend(
        onSurface.withValues(alpha: 0.06),
        surface,
      ).withValues(alpha: kBlockFillAlphaContent),
      border: cs.outlineVariant.withValues(alpha: 0.45),
      tabTrack: Color.alphaBlend(
        onSurface.withValues(alpha: 0.03),
        surface,
      ).withValues(alpha: 0.75),
      tabSelected: Color.alphaBlend(
        onSurface.withValues(alpha: 0.08),
        surface,
      ).withValues(alpha: 0.95),
      textPrimary: const Color(0xFF261208),
      textSecondary: const Color(0xFF46352B),
      textTertiary: const Color(0xFF5B4C43),
    );
  }
}

class PreviewTabButton extends StatefulWidget {
  const PreviewTabButton({
    super.key,
    required this.label,
    required this.selected,
    required this.colors,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final PreviewBlockColors colors;
  final VoidCallback onTap;

  @override
  State<PreviewTabButton> createState() => _PreviewTabButtonState();
}

class _PreviewTabButtonState extends State<PreviewTabButton> {
  bool _pressed = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final baseColor = widget.selected
        ? widget.colors.tabSelected
        : Colors.transparent;
    final hoverColor = Color.alphaBlend(
      widget.colors.textPrimary.withValues(alpha: _pressed ? 0.10 : 0.06),
      baseColor,
    );
    final bg = widget.selected || _pressed || _hovered
        ? hoverColor
        : Colors.transparent;

    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() {
          _hovered = false;
          _pressed = false;
        }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapCancel: () => setState(() => _pressed = false),
          onTapUp: (_) => setState(() => _pressed = false),
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(6),
            ),
            child: SelectionContainer.disabled(
              child: Text(
                widget.label,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.35,
                  fontWeight: widget.selected
                      ? AppFontWeights.semibold
                      : AppFontWeights.medium,
                  color: widget.selected
                      ? widget.colors.textPrimary
                      : widget.colors.textSecondary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class PreviewTextAction extends StatelessWidget {
  const PreviewTextAction({
    super.key,
    required this.icon,
    required this.label,
    required this.colors,
    this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String label;
  final PreviewBlockColors colors;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final active = enabled && onTap != null;
    final color = colors.textSecondary.withValues(alpha: active ? 0.88 : 0.38);

    return Tooltip(
      message: label,
      child: IosIconButton(
        onTap: onTap,
        enabled: active,
        semanticLabel: label,
        color: color,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        builder: (buttonColor) => Icon(icon, size: 14, color: buttonColor),
      ),
    );
  }
}

class PreviewLoadingView extends StatelessWidget {
  const PreviewLoadingView({super.key, required this.colors});
  final PreviewBlockColors colors;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: colors.textSecondary,
        ),
      ),
    );
  }
}

class PreviewErrorView extends StatelessWidget {
  const PreviewErrorView({super.key, required this.colors});
  final PreviewBlockColors colors;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Icon(Lucide.ImageOff, size: 48, color: colors.textTertiary),
    );
  }
}
