# Orrery — Solar System Simulation (Godot)

Godot 4.4 rewrite of the single-file three.js prototype in the repo root
(`index.html`), with full feature parity: Kepler ephemeris (Standish J2000
elements), live N-body gravity with adaptive leapfrog integration, collisions
and mergers, custom body injection, mass/G editing, realtime orbit trails,
procedural planet textures, moons, Saturn's rings, and the milky-way starfield.

## Running

Open this folder (`godot/`) in Godot 4.4+ and press Play, or:

```
godot --path godot
```

## Controls

- Drag to orbit, scroll to zoom, right/middle-drag to pan
- Click a planet (or its label / rail entry) to select and follow it
- `Space` pause · `O` orbits · `L` labels · `V` velocity vectors · `Esc` deselect / close panel
- "Add body…" in the left rail injects a custom body and switches the whole
  system to live N-body gravity

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
