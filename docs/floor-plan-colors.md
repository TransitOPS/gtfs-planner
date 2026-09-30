# Floorplan annotation style

Points and pathways are drawn over an operator-supplied plan whose colors and line weights are unknown. Every mark therefore carries a shape, label, halo or line cue in addition to its color, and the plan itself is faded so the marks read as the foreground.

Sources: colors in `lib/gtfs_planner_web/components/diagram_palette.ex`, sizes in `OVERLAY_BASE` (`assets/js/diagram_canvas_hook.js`), plan styling in the `#diagram-page` section of `assets/css/app.css`. The closures floorplan reuses the palette but has its own overlay code (`assets/js/pathway_evolutions_floorplan.js`).

## Palette roles

`DiagramPalette` emits each role as a `--diagram-*` custom property on `#diagram-page`.

| Role | Color | Cue |
| --- | --- | --- |
| Active stop | `#0B63E5` | filled circle, white ring, active label |
| Fallback stop | `#7C3AED` | diamond marker, fallback label |
| Other-level stop | `#4B5563` | outlined circle, level label |
| Pathway | `#0B63E5` | solid line, white casing, forward arrow |
| Inactive pathway | `#6B7280` | dotted line, unavailable label |
| Label | `#1F2937` | text label |
| Label halo | `#FFFFFF` | outline around label text |
| Ruler | `#2A3870` | tick marks, distance text |
| Focus | `#96305F` | 2px focus ring |
| Selection | `#C81870` | selection outline and handle |
| Building outline | `#374151` | heavy boundary |
| Error | `#B91C1C` | error icon, recovery text |
| Degraded | `#6B7280` | dashed boundary, degraded text |
| Journal open | `#B45309` | open marker, quiet dot, left accent |

Blue against white is 5.4:1 and against black 3.9:1. The item under the pointer takes the design system's action color (`--color-action`, `#C81870`), as does the point being edited.

## Halo and casing

- Point names and pathway signs have a 3px white halo, painted under the text.
- Each pathway line sits on a white casing that extends 1px beyond each side of the line.
- A point marker has a 2px white ring (a 4px white stroke painted under the fill).

## Sizes on screen

Sizes are CSS pixels and hold at every zoom of 100% or more. Below 100%, markers shrink linearly to 75% at the 50% minimum zoom; text and hit targets do not shrink. The overlay is re-sized when the window resizes.

| Element | Size |
| --- | --- |
| Point name | 12px, weight 500, normal case |
| Pathway sign, ruler label, elevator text | 11px |
| Platform, boarding (type 0) and entrance (type 2) marker | 12 x 20px upright rectangle |
| Node (type 3) marker | 12px circle |
| Boarding area (type 4) marker | 12px square |
| Pathway line | 2.5px; paired pathways 1.4 times that |
| Pathway arrowhead | 8px |
| Hit target for a point | 24 x 24px, centered on the marker |

## Label collision

Point names are shown from 85% zoom. Each name is tried at its default corner, then to the right, left, above and below its marker, and takes the first spot that overlaps no placed name and no other marker (2px clearance). A name with no free spot is hidden, and hovering its point shows the name in the tooltip. Names are placed in priority order (the selected point, then platforms, entrances, boarding areas and other nodes; ties keep document order), so a rerun gives the same result.

Pathway signs are shown from 110% zoom, saved ruler labels from 200%. Neither is checked for collisions.

## Plan wash

The plan image is drawn at 60% opacity over a gray ground, halfway between the page canvas (`--color-canvas`) and `--color-base-300`. The wash applies only to the editor's plan image, never to the overlay, so a white sheet reads as a lighter rectangle on the ground and its edge stays visible.

The value is fixed. A faint scan may need a stronger one; that would take a per-plan or user setting.

The wash is not applied in Align mode, where the floorplan is a separate image over the map with its own opacity slider. The closures floorplan fades its image to 62% in its own frame.
