## What this changes

<!-- One or two sentences. What was broken or missing, and what does this do about it? -->

## Why this way

<!-- The approach, and anything you rejected. Link the issue if there is one: Closes #12 -->

## How it was checked

<!-- Tick what you actually ran. Paste the summary line, not the whole log. -->

- [ ] `godot --headless --path . scenes/test_runner.tscn` — `102 checks, 0 failed`
- [ ] `godot --headless --path . scenes/race.tscn -- --selftest --laps=1 --speed=4 --track=0`
- [ ] the Python checks in `tests/` (rendering, HUD or asset changes)
- [ ] ran the game and drove a lap
- [ ] screenshot or capture attached (visual changes)

## Anything a reviewer should know

<!-- Generated assets you regenerated, new tools, anything deliberately left out. -->
