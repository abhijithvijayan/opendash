import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/widgets/indicators/telltale_icons.dart';
import 'package:opendash/theme/colors.dart';

// A render smoke-test for every telltale glyph (catches a painter that
// throws). It does NOT compare against a golden image: golden pixels differ
// across platforms/font stacks and would fail on CI. To regenerate the
// review image test/widgets/goldens/telltales.png, temporarily re-add the
// matchesGoldenFile line below and run with --update-goldens.
void main() {
  testWidgets('every telltale glyph renders', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 360));
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Container(
          color: const Color(0xFF0B0D10),
          padding: const EdgeInsets.all(24),
          child: Wrap(
            spacing: 36,
            runSpacing: 36,
            children: [
              for (final g in TelltaleGlyph.values)
                SizedBox(
                  width: 120,
                  child: Column(
                    children: [
                      TelltaleIcon(glyph: g, color: DashColors.bone, size: 56, label: g == TelltaleGlyph.speedLimit ? '80' : null),
                      const SizedBox(height: 6),
                      Text(g.name, style: const TextStyle(color: Color(0xFF9AA3AD), fontSize: 13), textAlign: TextAlign.center),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    expect(find.byType(Wrap), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
