import 'package:flutter/painting.dart';

import 'colors.dart';

abstract final class DashText {
  static const family = 'Archivo';

  static TextStyle _style({
    required double size,
    double weight = 500,
    double width = 100,
    Color? color,
    double letterSpacing = 0,
    double height = 1.0,
  }) {
    return TextStyle(
      fontFamily: family,
      fontSize: size,
      color: color ?? DashColors.bone,
      height: height,
      letterSpacing: letterSpacing,
      fontVariations: [
        FontVariation('wght', weight),
        FontVariation('wdth', width),
      ],
      fontFeatures: const [FontFeature.tabularFigures()],
    );
  }

  // The gauge styles are read every animation frame, so their variation
  // lists are built once; only the theme colour is applied per access.
  static final TextStyle _speedBase = _style(size: 196, weight: 600, width: 125, letterSpacing: -6);
  static final TextStyle _socBase = _style(size: 72, weight: 600, width: 125, letterSpacing: -2);
  static final TextStyle _socUnitBase = _style(size: 24, weight: 500, width: 100);
  static final TextStyle _scaleBase = _style(size: 20, weight: 500, width: 88);
  static final TextStyle _clockBase = _style(size: 28, weight: 500, width: 100, letterSpacing: 1);

  static TextStyle get speed => _speedBase.copyWith(color: DashColors.bone);
  static TextStyle get soc => _socBase.copyWith(color: DashColors.bone);
  static TextStyle get socUnit => _socUnitBase.copyWith(color: DashColors.ash);

  static TextStyle value(double size, {Color? color}) =>
      _style(size: size, weight: 500, width: 100, color: color ?? DashColors.bone, letterSpacing: -size * 0.02);

  static TextStyle caption(double size, {Color? color}) =>
      _style(size: size, weight: 400, width: 100, color: color ?? DashColors.ash);

  static TextStyle mode(Color color, {double size = 30}) =>
      _style(size: size, weight: 600, width: 112, color: color, letterSpacing: size * 0.18);

  static TextStyle get scale => _scaleBase.copyWith(color: DashColors.ash);

  static TextStyle get clock => _clockBase.copyWith(color: DashColors.bone);

  static TextStyle title(double size, {Color? color}) =>
      _style(size: size, weight: 600, width: 105, color: color ?? DashColors.bone, letterSpacing: -size * 0.01);
}
