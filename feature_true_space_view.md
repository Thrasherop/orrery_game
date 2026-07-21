# Feature request: a "True space" (barycentric) trail/display mode

**One-liner:** Add a new path-frame option that draws every body from its *true
barycentric position* — `compress(position − barycenter)` — instead of the
current sun-anchored construction. This is the honest "spatial coordinates"
view: in a binary you'd see the sun wobble and the planets orbit as separate,
real motions, with no artifacts injected by anchoring on the sun.

This doc is self-contained — it assumes no prior context on the codebase.

---

## 1. Background: why this is wanted

The app draws a compressed view of the solar system. Distances are squ/compressed
non-linearly (`r^0.62`) so everything fits on screen, and the display is built
**sun-anchored**: every body's on-screen position is

```
display[i] = compress(sun − barycenter)  +  compress(body[i] − sun)
```

i.e. "the sun's compressed offset from the barycenter, plus each body's small
compressed *heliocentric* offset." (See `NBodySystem.refresh_display()` in
`src/core/nbody.gd`, and `Units.to_display` / `Units.dist_scale` in
`src/core/units.gd`.)

That split is deliberate — it keeps the inner planets' local orbit *shapes*
undistorted even when a heavy far companion drags the barycenter far away (a
single compression from a distant barycenter fisheye-warps a tight cluster into
pinched "W" shapes). The header comment on `refresh_display()` explains this.

**The side effect (the reason for this feature):** because every body's display
contains `compress(sun − barycenter)`, the **sun's own motion is baked into
every body's on-screen trail**. In a binary star system the sun swings hard
around the barycenter, and that swing gets stamped onto distant planets' trails —
even though a distant planet physically does *not* follow the fast swing (it
just orbits the combined mass smoothly). The result is a spurious "kink" in,
say, Neptune's trail.

This was verified quantitatively (diagnostic at `tests/binary_kink_test.gd`,
run headless). At trail-point spacing, in a binary with the sun peaking at
~13 km/s:

| Neptune's path (curvature per trail point) | turning |
|---|---|
| **Real trajectory** (barycentric) | **4.6°** — smooth |
| Honest single compression of it (`compress(pos−bary)`) | **3.0°** — smooth |
| "Sun-locked" view | 77.7° |
| "True motion" view | 58.3° |
| "Galaxy" view | 28.9° |

So the physics is smooth; the kink is purely a display construction. The
"honest single compression" row (3.0°) is exactly what this feature should draw.

**Accepted tradeoff:** this mode reintroduces the fisheye warp for tight
clusters far from the barycenter (e.g. light inner planets + a heavy distant
star). That's fine — it's an *opt-in* mode showing real compressed positions;
the default sun-anchored view is unchanged. Do **not** try to "fix" the fisheye;
it's inherent to a single radial compression and is the correct behavior here.

---

## 2. How the current display + trail system works (read before changing)

**Positions.** Each physics frame, `Simulation.tick()` (in
`src/sim/simulation.gd`) calls `nb.refresh_display(true)` to fill
`nb.disp: PackedVector3Array` (the sun-anchored display positions), then sets
each `SimBody.display_pos = nb.disp[i]`. `nb.disp` is **also used by collision
detection**, so it must stay sun-anchored — see §4.

**Trails.** Each `SimBody` (`src/sim/sim_body.gd`) stores a ring buffer of
*frame-independent* samples:
- `trail_days: PackedFloat64Array` — sim-day of each sample
- `trail_local: PackedVector3Array` — the body's display offset from its anchor
  (the sun for planets; the host for moons) at sample time
- `trail_anchor: PackedVector3Array` — the anchor's absolute display position at
  sample time
- `trail_verts: PackedVector3Array` — the cached mesh vertex for the *active*
  view mode (recomputed on mode switch)

Samples are pushed via `SimBody.trail_push(day, local, anchor, focus_abs)`.
`anchor + local` reconstructs the body's absolute sun-anchored display position.

**View modes** live in `src/core/trail_frames.gd` (`class_name TrailFrames`):
```
enum { MODE_LOCAL, MODE_INERTIAL, MODE_GALAXY, MODE_FOCUS }
const MODE_NAMES := ["Sun-locked", "True motion", "Galaxy", "Focus"]
```
Three static functions turn a stored sample into a mesh vertex:
- `vertex(day, local, anchor, focus_abs)` — for a live push
- `vertex_hist(day, local, anchor)` — for a mode-switch rebuild
  (`SimBody.trail_rebuild()` calls this over every stored sample)
- `anchor_now(b, sun, now_day)` — where the `TrailView` node sits this frame
  (mesh vertices are relative to it)

Current per-mode vertex math (note they're all built from `local`/`anchor`,
which are sun-anchored):
```
MODE_LOCAL   : local                              # relative to the sun
MODE_INERTIAL: anchor + local                     # absolute sun-anchored
MODE_GALAXY  : anchor + local + GAL_V * day        # absolute + linear galactic drift
MODE_FOCUS   : anchor + local - focus_abs          # relative to the focus body
```
**The invariant every mode preserves:** `newest_vertex + anchor_now == body.display_pos`,
so a trail always ends exactly at its body.

**Mode selection is already generic** — adding an enum entry is mostly automatic:
- `Events.set_trail_mode(m)` (`src/autoload/events.gd`) sets `TrailFrames.mode`,
  persists via `Prefs`, emits `trail_mode_changed`.
- `src/ui/settings_panel.gd` builds one toggle button per `MODE_NAMES` entry
  (loop ~line 116) with tooltips from its local `MODE_TIPS` array — **add a tip**.
- `src/ui/hud.gd` (~line 215) cycles modes on a key press via
  `(mode + 1) % MODE_NAMES.size()` — auto-includes a new mode.
- `src/core/prefs.gd` clamps the saved mode to `MODE_NAMES.size()` — auto-OK.
- On `trail_mode_changed`, `Simulation._rebuild_trail_verts()` calls
  `SimBody.trail_rebuild()` on every body (lossless re-render from raw samples).

**Important — physics vs render split:** the physics runs through a compiled
native kernel on most platforms (`src/sim/native_kernel.gd`,
`Simulation._step_physics_native`). That kernel computes its own sun-anchored
`disp` for *collision detection*. But the **rendered** `nb.disp` is recomputed
in GDScript by `nb.refresh_display(true)` inside `tick()` every frame. So this
feature is **pure GDScript + rendering — do NOT touch the C++ kernel in
`native/`.** Collisions stay on the kernel's sun-anchored frame regardless.

---

## 3. Proposed implementation

Add a mode, e.g. `MODE_TRUE` named `"True space"` (final name is the user's
call — see the note in `feature_requests.md` about renaming; confirm with them).
It renders `compress(body − barycenter)`, optionally plus the galactic drift so
it still "streams through the galaxy" like Galaxy mode.

### 3a. Store the raw barycentric position per trail sample

The stored `local`/`anchor` are sun-anchored and **cannot** be turned into a
faithful barycentric position — you need the raw data. Add to `SimBody`:
```
var trail_bary := PackedVector3Array()   # body position minus barycenter, AU (raw)
```
Maintain it in lockstep with the other trail arrays in `trail_push()`,
`trail_clear()`, and the ring-buffer eviction (the `remove_at(0)` block). Give
`trail_push()` a new `bary: Vector3` parameter and store it.

Store **raw AU** (not pre-compressed) so the compression lives in one place and
a mode switch can recompute cleanly.

### 3b. Feed the barycentric position in at every push site

Trails are pushed from a few places in `src/sim/simulation.gd`:
- planet/custom sampling: `_sample_planet_trails()` (native path) and the inline
  block in `_step_physics_gdscript()` (fallback path)
- moon sampling: `_apply_moon_display()`
- railed bodies: `_drive_railed()`
- Kepler-mode (no physics): `_tick_moons_kepler()`, `backfill_planet_trail()`

For each, pass the body's barycentric position in AU. In physics mode that's
`Vector3(nb.px[i], nb.py[i], nb.pz[i]) - nb.barycenter()`. In Kepler mode the
barycenter is the sun at the origin, so it's just the heliocentric position.
(Compute the barycenter once per frame, not per body.)

### 3c. Add the vertex math in TrailFrames

```
MODE_TRUE:  Units.to_display(bary) + GAL_V * day   # faithful barycentric [+ drift]
```
- `vertex()` / `vertex_hist()` gain access to the sample's `bary` (add a param;
  `trail_rebuild()` passes `trail_bary[i]`).
- `anchor_now()` for `MODE_TRUE`: `-GAL_V * now_day` (same as Galaxy) if you keep
  the drift, else `Vector3.ZERO`.
- `trail_visible()`: return `true` (like Galaxy/True-motion).

### 3d. Move the BODY positions to the barycentric frame in this mode

The trail must still end at its body (the invariant), so when `MODE_TRUE` is
active, `tick()` must set each `SimBody.display_pos` to the same barycentric
compression the trail uses: `Units.to_display(pos_i - barycenter)` (+ drift
handled by `anchor_now`, i.e. the body itself sits at the un-drifted value).
Keep `nb.disp` (sun-anchored) intact for collisions — compute the barycentric
render positions **separately** (a small helper, only when this mode is active).

Moons are a secondary concern (sub-pixel at galactic zoom): it's acceptable for
a first cut to leave moons on their existing host-anchored display in this mode,
or to defer them. Call this out to the user.

---

## 4. Gotchas / invariants (don't break these)

- **Collisions must stay on the sun-anchored frame.** `nb.disp` feeds
  `swept_distance()` collision tests and the native kernel. Do not repurpose it;
  compute barycentric positions in a separate buffer for rendering only.
- **Never edit the C++ kernel** (`native/`) for this — it's rendering only.
- **Body + trail move together.** If you draw the trail barycentric but leave the
  body dot sun-anchored, the trail detaches from its planet. §3d handles this.
- **Mode switching is lossless** and rebuilds from raw samples — that's why 3a
  stores raw AU. Verify switching in/out of the new mode looks right (existing
  modes must be unaffected).
- **`trail_bary` must be kept perfectly in sync** with the other trail arrays
  (same length, same eviction), or `trail_rebuild()` will index-mismatch.

---

## 5. Verification

- **Quantitative:** adapt `tests/binary_kink_test.gd` (already in the repo). It
  builds a binary and prints per-mode trail curvature. Add the new mode; it
  should read ~3–5° (matching Neptune's real trajectory), vs 29–78° for the
  sun-anchored modes. Run headless:
  `<godot-console-exe> --headless --path . res://tests/binary_kink_test.tscn`
  (A new `class_name` needs one `--headless --editor --quit --path .` pass first.)
- **Visual:** `tests/visual_trails.tscn` boots a twin-sun scenario and cycles all
  path-frame modes, saving `trail_*.png`. Add the new mode and eyeball that
  Neptune (and the outer planets) draw smooth arcs while the sun visibly wobbles.
- **Regression:** the existing modes must be byte-unchanged. Run the smoke +
  visual suites (see the console-exe workflow) and confirm no diff in the other
  modes' screenshots.

---

## 6. Files you'll touch

- `src/core/trail_frames.gd` — new enum entry, `MODE_NAMES`, vertex math.
- `src/sim/sim_body.gd` — `trail_bary` storage; `trail_push` param; clear/evict/rebuild.
- `src/sim/simulation.gd` — pass barycentric AU into every `trail_push`; set
  barycentric `display_pos` in the new mode; a small barycentric-display helper.
- `src/ui/settings_panel.gd` — add a `MODE_TIPS` entry for the new mode.
- (Auto: `events.gd`, `hud.gd`, `prefs.gd` already generalize over `MODE_NAMES`.)
- `tests/binary_kink_test.gd`, `tests/visual_trails.gd` — extend for verification.

**Out of scope / do not touch:** anything in `native/`, the physics integrator,
collision detection.
