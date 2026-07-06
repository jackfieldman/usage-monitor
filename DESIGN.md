---
version: alpha
name: Usage Monitor
description: Menu-bar gauge glyphs for Claude usage limits (values in Apple points; px ≡ pt)
colors:
  primary: "#30D159"    # level-low — under 50% used
  secondary: "#FF9E0A"  # level-mid — 50–79% used
  error: "#FF453B"      # level-high — 80%+ used
typography:
  label-md:
    fontFamily: SF Pro Text
    fontSize: 12px
    fontWeight: 500
    fontFeature: tnum
rounded:
  sm: 2px
  full: 999px
spacing:
  hairline: 1px
  inset: 2px
  gap: 4px
components:
  gauge-fill-low:
    backgroundColor: "{colors.primary}"
  gauge-fill-mid:
    backgroundColor: "{colors.secondary}"
  gauge-fill-high:
    backgroundColor: "{colors.error}"
  menubar-number:
    typography: "{typography.label-md}"
---

# Usage Monitor design

## Overview

Usage Monitor is a macOS menu-bar utility. Its entire visual surface is a
~22pt-tall glyph that must sit among Apple's own status icons (battery, Wi-Fi)
without looking foreign. The feel is **system-native and quiet**: hairline
outlines, the system label colour for chrome, colour used only to carry one
signal — how close a limit is to being hit. Nothing decorative; every pixel is
information. All drawing is AppKit (`UsageMonitor.swift`), resolution-
independent via `NSImage` drawing handlers, with 1pt strokes pixel-aligned on
half-pixel boundaries. Dimensions here are Apple points (`px` in tokens ≡ pt).

**Scope.** This design system governs the **menu-bar glyph and its menu** —
the product's visual identity. The first-run setup window and system
notifications are deliberately built from stock AppKit/macOS controls (default
system fonts, standard buttons and alerts) so they match the OS rather than the
glyph; they are intentionally outside these tokens and shouldn't grow a bespoke
visual language.

## Colors

Three level colours encode usage severity, mirroring Apple's traffic-light
semantics. Thresholds are the contract: **low < 50%**, **mid 50–79%**,
**high ≥ 80%** (`levelColor(_:)`).

- **Primary / level-low (#30D159):** green, healthy headroom.
- **Secondary / level-mid (#FF9E0A):** amber, worth a glance.
- **Error / level-high (#FF453B):** red, limit imminent.

All non-level chrome derives from the dynamic system `labelColor` (never a
literal hex) so the glyph adapts to light/dark menu bars: shell outlines and
cap nubs at 50% opacity, empty tracks at 18%, greyscale-style fills at
38/62/100% for low/mid/high. Three icon styles reuse the same thresholds:
Colour (tokens above), Greyscale (labelColor alphas), System Battery
(labelColor, switching to `error` at ≥ 80%).

## Typography

One text role: the percentage beside a glyph — 12pt system font (SF Pro),
medium weight, monospaced digits (`tnum`) so widths don't jitter as values
change, drawn in `labelColor`.

## Layout

The status-item image is 22pt tall with 2pt outer padding; glyph and number
are separated by a 4pt gap. In multi-battery mode gauges sit 10pt apart.
Fills inset 2pt from their shell.

## Shapes

- **Battery:** shell corner radius = 0.28 × body height; cap nub 1.5 × (0.36
  × height), radius 0.75pt; fill radius ≤ 2pt. Individual body 26×12pt,
  consolidated 28×16pt with stacked 1pt-gapped bars.
- **Bar chart:** three pill columns (radius = width/2), 4.5pt wide, 2pt
  apart, 15pt tall; a bar never renders below a 4.5pt dot.
- **Rings:** concentric arcs in an 18pt box, 2.2pt stroke, 0.6pt ring gap,
  round caps, sweeping clockwise from 12 o'clock.

## Do's and Don'ts

- **Do** keep chrome in `labelColor`-derived opacities; only level state may
  use the colour tokens.
- **Do** keep strokes at 1pt on half-pixel alignment — sharpness is the
  product.
- **Don't** introduce new hex literals in drawing code; add a token here
  first.
- **Don't** exceed ~16pt of glyph height inside the 22pt bar, or the icon
  reads as oversized next to Apple's.
