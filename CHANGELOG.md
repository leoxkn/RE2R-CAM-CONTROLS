# Changelog

## v3.0

**New**
- ADS offset: separate left/right and up/down offset for the aiming view, covering every weapon and the knife.
- Presets: 3 slots, each saving the whole setup (Normal and ADS FOV, all four offsets).
  Left-click to save or load; right-click a saved slot to Overwrite, Clear or Cancel (Esc also cancels). Hovering a slot shows what its clicks do.

**Improved**
- Smooth aim zoom: aiming in and out runs on its own even 0.20 s curve instead of following the game's slow zoom.
- Quick camera transitions: the camera's position now moves between views as fast as the FOV, so both finish together.
- Seamless transitions between different values of all overrides.

**Fixed**
- The view being left (e.g. the end of letting go of aim) no longer moves when the other offset changes.
- A small wiggle after Reset.

**Changed**
- Default toggle hotkey is now F3.
- "Default" FOV renamed to "Normal"; "Reset to Defaults" renamed to "Reset all overrides".
- Settings are saved to `RE2R_CAM_CONTROLS.json` (v2.x used `RE2R_FOV_CONFIG.json`, which is not read).

## v2.1 (2026-10-29)

**Fixed**
- The camera flipping upside down.
- Wrong FOV values learned from menus, the inventory and item examine.
- Slider value slightly off from the real view.
- Reset not fully resetting.
- Aiming needed after changing the in-game FOV setting (the game's value is now read live).
- Very low FOV snapping to the default view.

Drop-in update; settings carry over from v2.0.

## v2.0 (2026-10-27)

Renamed from **RE2R FOV** to **RE2R CAM CONTROLS**.

**New**
- Camera offset, left/right and up/down.
- Toggle hotkey for all overrides.
- On-screen ON/OFF notice when toggling.
- Two-step Reset (Confirm / Cancel).

## v1.0 (2026-10-25)

First release as **RE2R FOV**: separate Default and ADS field of view sliders.
