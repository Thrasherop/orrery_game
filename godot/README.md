# Orrery — Solar System Simulation (Godot)

Godot 4.4 rewrite of the single-file three.js prototype in the repo root
(`index.html`), with full feature parity: Kepler ephemeris (Standish J2000
elements), live N-body gravity with adaptive leapfrog integration, collisions
and mergers, custom body injection, mass/G editing, realtime orbit trails,
procedural planet textures, moons, Saturn's rings, and the milky-way starfield.

Orbit trails support four reference frames (`src/core/trail_frames.gd`),
switchable live with no reset — Sun-locked (paths pinned to the Sun/host,
clean rings), True motion (inertial barycentric), Galaxy (the system
drifting through the Milky Way) and Focus (relative to the selected body —
retrograde loops).

## Running

Open this folder (`godot/`) in Godot 4.4+ and press Play, or:

```
godot --path godot
```

## Controls

- Drag to orbit, scroll to zoom, right/middle-drag to pan
- Click a planet (or its label / rail entry) to select and follow it
- `Space` pause · `O` orbits · `L` labels · `V` velocity vectors · `P` cycle path frame · `Esc` deselect / close panel
- "Add body…" in the left rail injects a custom body around the currently
  selected body (a moon of it; sun or nothing selected → a free sun-orbiting
  body) and switches the whole system to live N-body gravity — the camera
  frames the proposed position while the form is open. User-added bodies are
  always simulated, independent of the catalog-moon settings
- Every moon/custom body's info card has a "Simulated" switch: off puts the
  body "on rails" (a frozen circular orbit — no gravity, no collisions, no
  physics cost); the bottom-left "Physics load" drawer names the bodies
  forcing the integrator's smallest steps

## Architecture

```
src/
  core/     pure math, no Node dependencies (Kepler solver, leapfrog N-body,
            time conversions, display compression)
  data/     body catalog (elements, stats, texture configs, moons, palettes)
  sim/      Simulation node: clock, mode switching (Kepler <-> N-body),
            seeding, mergers, trails; SimBody runtime state
  world/    3D views: body/sun views, trails, starfield, impact effects,
            add-body preview, orbit camera rig with picking
  gfx/      procedural texture factory + shaders
  ui/       HUD panels (brand, rail, info card, dock, add panel, labels,
            toast) built in code with a shared theme
  autoload/ Events: global signal bus + shared UI state
```

The simulation layer is renderer-agnostic: `core/nbody.gd` integrates in
double precision (PackedFloat64Array), and views only read per-frame
`SimBody` state (display positions, trails, stats).
