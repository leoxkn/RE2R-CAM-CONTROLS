# CLAUDE.md

Project notes for AI-assisted work on RE2R CAM CONTROLS.

## Project

- REFramework Lua camera mod for Resident Evil 2 Remake (PC), one file: `RE2R_CAM_CONTROLS.lua`.
- Features: Normal / ADS FOV, camera offset and ADS offset (X/Y), smooth aim zoom, quick camera transitions, 3 preset slots, toggle hotkey (default F3), Reset all overrides.
- Tested on the non-ray-tracing (DX11) version of the game.
- Settings file: `reframework\data\RE2R_CAM_CONTROLS.json`.
- Released on Nexus Mods; the zip in Releases matches the Nexus file.

## Rules

- **Measure first, never guess.** Game values and structures are found with read-only scan scripts that run in game and log their results.
- **Scans never write into the game.** Any build that writes into game memory says so up front and states exactly what it writes.
- **No other mods' code or methods.** Everything is reverse engineered for this project.
- **Full scripts only**, never snippets or partial diffs.
- Every game access is wrapped in `pcall`; every write is reversible and restored on toggle off and script reset.
- Structs are never written back whole through `set_field` (that broke the camera once); inline values are written as single floats at offsets taken from type information, verified against the game's own field values first.

## Code notes

- Lua allows 200 local names per chunk: group state into tables or `do … end` blocks.
- REFramework ImGui has `imgui.combo`, but not `begin_combo` / `selectable`.
- The script uses Windows (CRLF) line endings; `.gitattributes` keeps them byte-for-byte so the repo file matches the release.
- Check syntax with `local f, e = load(src); return tostring(e)` (a nil error means it compiles).

## Repo

- Commits use the GitHub noreply email; no co-author or session lines in commit messages.
- `CHANGELOG.md` is updated with every version; the README keeps installation at the end.
