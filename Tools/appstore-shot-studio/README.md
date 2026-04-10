# App Store Shot Studio

Local tool for composing App Store marketing screenshots from raw device captures.

## What It Does

- accepts a screenshot exported from iPhone or Simulator
- places it inside the matching included device mockup for the selected preset
- adds a single marketing line above the mockup
- exports a PNG in common App Store dimensions
- can export all supported presets in one pass
- includes ready-to-edit text templates
- lets you define a custom three-stop gradient background
- can switch between a pure gradient background and a gradient with decorative accents
- lets you choose the font for the text above the mockup
- lets you tune font size and font weight independently
- lets you move the text vertically while keeping it above the mockup safe area
- auto-fits imported screenshots into the frame

## Included Presets

- iPhone 6.9" portrait: `1320 x 2868`
- iPhone 6.5" portrait: `1242 x 2688`
- iPhone 5.5" portrait: `1242 x 2208`
- iPad 13" portrait: `2064 x 2752`

## Run It

Option 1: open directly in a browser

- open [Tools/appstore-shot-studio/index.html](index.html)

Option 2: serve it locally

```bash
cd Tools/appstore-shot-studio
python3 -m http.server 8080
```

Then open `http://localhost:8080`.

## Workflow

1. Export a clean screenshot from device or Simulator.
2. Drop the image into the tool.
3. Pick the App Store preset you need.
4. Enter the text you want above the mockup.
5. Adjust zoom and position until the composition is balanced.
6. Download the final PNG.

## Extra Controls

- `Copy template`: fills the text field with a reusable marketing angle
- `Export base name`: controls the output filename prefix
- `Gradient Background`: lets you tune three color stops and gradient angle
- `Gradient-only background`: removes the decorative accent shapes and leaves only the gradient
- `Font`: switches the typeface used for the top text
- `Font weight`: switches between regular, semibold, and bold text rendering
- `Font size`: scales the top text independently from the device mockup
- `Text vertical position`: moves the text block up or down, but keeps it from slipping under the mockup
- `Image fit`: choose between `stretch`, `cover`, and `contain`
- `Fit now`: reapplies the current fit mode without reimporting the image
- `Auto-fit on import`: resets zoom and offsets when you load a new screenshot
- `Show device mockup`: lets you switch between the fixed bezel mockup and a cleaner edge-to-edge layout
- `Export All Presets`: downloads every supported size automatically

## Notes

- iPhone presets use `mockup_apple_iphone_17_pro_max_2025.png` and the tool keys out its baked checkerboard background automatically
- the iPad 13" preset uses `mockup_apple_ipad_air_4_1be2891561.png`
- the top text is automatically constrained to the space above the mockup, even after changing font size or vertical offset
- the output is a flattened PNG, ready for further polish in Figma if needed