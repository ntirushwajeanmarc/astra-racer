# Contributing to Astra Racer

Thanks for wanting to help. This is a small Godot project with a lot of
opinionated detail in it, so this file explains how the code is organised, what
the house style is, and what has to pass before a change is merged. Read it
once — after that the workflow is ordinary git.

## Getting set up

1. Install **Godot 4.7** (standard build, not .NET) and put `godot` on your
   `PATH`. Check it with `godot --version`.
2. Fork the repository on GitHub, then clone your fork:

   ```bash
   git clone https://github.com/<your-username>/astra-racer.git
   cd astra-racer
   godot --path .        # imports assets, then runs the menu
   ```

3. Install Python 3.10+ only if you intend to touch `tools/` or the rendering
   checks: `pip install -r requirements.txt`.
4. On a headless machine the rendering checks need a display: `xvfb-run python3
   tests/check_road_renders.py`.

The first Godot run builds a `.godot/` folder. It is generated, it is ignored by
git, and nothing in it should ever be committed.

## What to work on

- Check the **Issues** tab before starting something large, and open an issue
  for anything bigger than a bug fix or a small feature. It is much cheaper to
  agree on an approach before the code exists.
- Good first contributions: new circuit data, better AI lines, UI polish,
  additional checks, documentation.
- If you are reporting a bug, say what you did, what happened, what you expected,
  and paste any Godot error output. "It doesn't work" cannot be acted on.

## The workflow

Work on a branch, keep pull requests small, and open them against `main`.

```bash
git switch -c feature/tyre-slip-sound
# edit, run the checks, then:
git add -A
git commit -m "Add tyre scrub amplitude to the skid loop"
git push -u origin feature/tyre-slip-sound
```

Then open a pull request on GitHub. Describe **what changed and why** — the diff
already says what; the reviewer needs the reason. If the change is visual,
attach a screenshot or a short capture.

One pull request should do one thing. A PR that fixes a bug and also reformats
three files will be asked to split.

## Commit messages

A short imperative subject line, under about 70 characters, and a body that
explains the cause when it is not obvious:

```
Fix AI booking itself during the countdown

Cars are no longer locked on the grid, so a jump start can be judged. The
AI then drove off as soon as it had controls, which booked it every race.
It now holds position until the lights go out.
```

No "WIP" commits in a pull request — squash them or tidy the history first.

## House style

The code is written to be read by someone who was not there when it was written.

- **GDScript, typed.** `var speed := 0.0`, `func _ready() -> void:`. Typed code
  is what makes Godot's errors arrive at parse time rather than mid-race.
- **Comments explain why, not what.** Look at the top of `scripts/car/car.gd`:
  the file opens with the physics decision and the consequence of it. Every
  non-obvious constant says where its number came from.
- **`#` above the line it explains**, sentence case, wrapped around 80 columns.
- **One class per file**, with `class_name` matching the filename in
  `scripts/`. Tabs for indentation, as Godot's editor writes them.
- **Units in names and comments.** `max_lat_accel := 17.5  # m/s^2`,
  `speed_mps`, `distance_m`. A number without a unit has caused bugs here before.
- **Node paths are resolved once** in `_ready()` and kept in a typed field; no
  `get_node("../../Foo")` scattered through a frame loop.

Match the file you are editing. A change that reads differently from the code
around it will be asked to change, even if it works.

## Testing

Two suites, and both must pass before a PR is merged.

```bash
# invariants and behaviour, headless, a few seconds
godot --headless --path . scenes/test_runner.tscn

# the assembled game: does it actually render and race?
godot --headless --path . scenes/race.tscn -- --selftest --laps=1 --speed=4 --track=0
```

If you touched rendering, the HUD or an asset, also run the Python checks in
`tests/` — they are the only thing that proves the game *paints* what the
physics and the data say it should.

Every push to `main` and every pull request runs both suites on a clean Linux
machine in GitHub Actions (`.github/workflows/tests.yml`), with Godot installed
from the official release. The rendering checks in `tests/` are not part of it —
they need a real GPU — so run those yourself if your change touches how the game
looks.

Write a test with your fix where one is possible. The suite is deliberately
fast: prefer asserting in-process over spawning a browser or waiting on a
timer. A check that fails for the old behaviour and passes for the new one is
worth ten that pass either way.

## Assets and generated files

Several things in this repository are **generated** and must not be edited by
hand — they will be overwritten:

| generated | by |
|---|---|
| `scripts/track/track_data.gd` (circuit points) | `tools/gpx_to_track.py` |
| `assets/terrain/kigali_terrain.*` | `tools/build_terrain.py` |
| `assets/terrain/kigali_city.*` | `tools/build_city.py`, `tools/city_textures.py` |
| `assets/sky/*` | `tools/make_sky.py` |
| `audio/*.wav` | `tools/make_audio.py` |

Change the tool, then re-run it, and commit both the tool change and its output.
A hand-edited GLB cannot be reviewed and cannot be regenerated.

Art from the Kenney kits under `assets/models/` is third-party and carries its
own licence — see `assets/LICENSE-kenney-*.txt`. Do not paste in art,
sound or code from somewhere else unless its licence allows redistribution here,
and say where it came from in the pull request.

## Data that must stay out

- **No API keys, tokens or personal paths.** Nothing in the game needs a
  credential; if a tool of yours does, read it from an environment variable and
  keep it out of the repository.
- No downloaded map or elevation data beyond what `tools/` fetches, and no
  personal GPX tracks that you do not have the right to publish.
- No built `.godot/`, exported binaries or editor caches.

## How we work together

Be straightforward and technical: critique the code, not the person, and assume
the other person is arguing in good faith. Disagreement about a design is
welcome in an issue; it is not a reason to be rude. Anything harassing,
dismissive or personal is not welcome here, whoever writes it.

## Licence

By contributing you agree that your work is released under the MIT licence in
[LICENSE](LICENSE), the same terms as the rest of the project.
