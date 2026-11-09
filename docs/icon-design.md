# AutoMeetingRecorder（AMR）icon

2026-11-09 update: retain the waveform/note composition and transparent macOS silhouette; recolor from teal to BEDI brand blue #0075FF / #005FD2 with navy #0E2241 transcript lines and a white page. Edited with the built-in image generation tool, exported through sips/iconutil. No company logo or text is added.

Current asset paths remain `code/Resources/AppIconSource.png`, `AppIcon.png`, and `AppIcon.icns`. The application is now AutoMeetingRecorder 0.2.0.

The earlier design record follows for provenance.

2026-11-06. Original app artwork generated with the built-in image generation tool, then exported without compositional edits using macOS `sips` and `iconutil`.

Direction: deep petrol-teal macOS rounded tile; ivory folded note sheet; turquoise waveform above two transcript lines. No lettering, so it remains legible in the Dock and Finder. The palette follows the app's teal accents. Transparency outside the silhouette is preserved.

Validation: visually inspected 64px and 256px renders; iconutil round-trip decode succeeded; app bundle references the icon and passes strict code-sign verification. Packaging version is 0.1.1 (build 2), to distinguish the icon update. An already-installed Applications copy is not modified automatically.

Assets live in `code/Resources/`: `AppIconSource.png` (original 1254px), `AppIcon.png` (1024px), `AppIcon.icns` (16–1024px representations). Export script: `code/script/build_icon.sh`. `CFBundleIconFile` and the build script reference the packaged icon.

## Generation prompt

Create ONE production-ready macOS desktop app icon for MeetingScribe, a private local-first meeting recorder that turns conversations into meeting notes. Final icon asset, not a mockup or grid. Square composition, genuine transparent background outside a large centered rounded-square tile occupying about 86% of the canvas. Rich deep petrol teal, subtly lit satin ceramic with a restrained jade highlight. Central original symbol: ivory-white rounded note sheet with an elegantly folded upper-right corner; a bold turquoise waveform of five rounded vertical bars above two short dark-teal transcript lines. One cohesive voice-becomes-notes glyph, generous whitespace, thick precise geometry, recognizable at 32px. Restrained depth, straight-on view. No text, initials, numerals, badge, recording dot, sparkle, microphone, headphones, existing logos, watermark, or scenery. Do not crop the tile or shadow.
