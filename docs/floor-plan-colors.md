# Floorplan Annotation Style Spec

## Colors

| Element                     | Color      | Hex       |
| --------------------------- | ---------- | --------- |
| Stops (dots)                | Red-orange | `#0080FF` |
| Stop labels (text)          | Red-orange | `#0080FF` |
| Active stop (dot)           | Blue       | `#FF4500` |
| Active stop label (text)    | Blue       | `#FF4500` |
| Pathways (lines)            | Magenta    | `#FF00FF` |
| Pathway labels (text)       | Magenta    | `#FF00FF` |
| Multi-level markers         | Magenta    | `#FF00FF` |
| Active pathway (line)       | Blue       | `#FF4500` |
| Active pathway label (text) | Blue       | `#FF4500` |

## Halo Outline

All annotation elements — dots, lines, multi-level markers, and text labels — receive a **white halo outline**:

- **Color:** White (`#FFFFFF`)
- **Width:** 1px

The halo renders behind/beneath the primary element to provide separation from the underlying grayscale blueprint.

## Text

Label text matches the color of its parent element (stop or pathway) and uses the same halo treatment.

## Tooltips

Tooltips match the color of the element they are associated with (red-orange for stops, magenta for pathways/multi-level markers, blue for active elements).
