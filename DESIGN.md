---
name: Snek
description: A tactile illustrated arcade cabinet wrapped around fast multiplayer snake.
colors:
  arena: "#d8cbbb"
  io-arena: "#121923"
  ink: "#090d0b"
  panel: "#111610"
  panel-raised: "#1a2118"
  cream: "#f6e6c7"
  cream-muted: "#b8ad95"
  leaf: "#83bf35"
  leaf-dark: "#385f22"
  tomato: "#e33b32"
  tomato-dark: "#a92021"
  gold: "#f3b52a"
  gold-dark: "#a66813"
  player-leaf: "#51cf66"
  player-berry: "#ff6b6b"
  player-sun: "#fcc419"
  player-river: "#339af0"
  player-grape: "#845ef7"
  player-cow: "#f6e6c7"
typography:
  micro:
    fontSize: "0.625rem"
  small:
    fontSize: "0.75rem"
  body-compact:
    fontSize: "0.9rem"
  action:
    fontSize: "1.35rem"
  stat:
    fontSize: "1.8rem"
  compact-headline:
    fontSize: "clamp(2.35rem, 7vw, 4.5rem)"
  end-headline:
    fontSize: "clamp(2.35rem, 7vw, 3.25rem)"
  display:
    fontFamily: "Snek Display, Arial Narrow, sans-serif"
    fontSize: "clamp(4.4rem, 7vw, 7.3rem)"
    fontWeight: 900
    lineHeight: 0.82
    letterSpacing: "-0.04em"
  headline:
    fontFamily: "Snek Display, Arial Narrow, sans-serif"
    fontSize: "clamp(3rem, 6vw, 5.8rem)"
    fontWeight: 900
    lineHeight: 0.86
    letterSpacing: "-0.04em"
  body:
    fontFamily: "Avenir Next, Avenir, Segoe UI, Helvetica, Arial, sans-serif"
    fontSize: "clamp(0.94rem, 1.4vw, 1.12rem)"
    lineHeight: 1.48
  label:
    fontFamily: "Avenir Next, Avenir, Segoe UI, Helvetica, Arial, sans-serif"
    fontSize: "0.75rem"
    fontWeight: 900
    lineHeight: 1
    letterSpacing: "0.09em"
rounded:
  preview: "3px"
  control: "5px"
  field: "7px"
  deck: "9px"
  panel: "14px"
  cabinet: "22px 22px 12px 12px"
spacing:
  xs: "7px"
  sm: "12px"
  md: "18px"
  lg: "24px"
  xl: "clamp(24px, 4vw, 46px)"
components:
  action-quick:
    backgroundColor: "{colors.leaf}"
    textColor: "{colors.ink}"
    typography: "{typography.display}"
    rounded: "{rounded.control}"
    padding: "11px 18px"
  action-code:
    backgroundColor: "{colors.gold}"
    textColor: "{colors.ink}"
    typography: "{typography.display}"
    rounded: "{rounded.control}"
    padding: "11px 18px"
  action-create:
    backgroundColor: "{colors.tomato}"
    textColor: "{colors.ink}"
    typography: "{typography.display}"
    rounded: "{rounded.control}"
    padding: "11px 18px"
  input:
    backgroundColor: "{colors.panel-raised}"
    textColor: "{colors.cream}"
    rounded: "{rounded.field}"
    padding: "12px 15px"
    height: "54px"
---

# Design System: Snek

## Overview

**Creative North Star: “The Illustrated Arcade Cabinet”**

Snek’s landing flow is a physical-feeling game machine rather than a generic launcher. A large illustrated arena establishes the game first; one dark cabinet contains the menu, lobby join, and lobby creation states. Chunky controls, print-like art, clipped corners, and shallow mechanical shadows make the interface playful while the form fields remain crisp and conventional.

The experience is energetic but legible: near-black surfaces carry warm cream copy, while leaf green, sunflower gold, and tomato red each signal a distinct action. The in-game surface is intentionally quieter and full-bleed so the moving snakes, pickups, hazards, nameplates, chat, and HUD own the player’s attention.

**Key characteristics:**

- Illustrated multiplayer arena paired with a single arcade-control cabinet.
- Warm, earthy base palette with three unmistakable action colors.
- Heavy, compressed uppercase display type and neutral system body copy.
- Tactile depth from offset bases, inset seams, and restrained drop shadows.
- Dense controls that reflow without horizontal page overflow.

## Colors

The landing palette is warm and screen-printed: charcoal and moss surfaces, cream text, leaf green, tomato red, and sunflower gold.

### Primary

- **Leaf Green** (`#83bf35`): Quick Join, the main Join action, live status, selected Classical controls, and positive focus feedback.
- **Deep Leaf** (`#385f22`): supporting icon strokes and darker structural green.

### Secondary

- **Tomato Red** (`#e33b32`): Create Lobby, title emphasis, and error borders. Its dark partner (`#a92021`) forms the physical button base.
- **Sunflower Gold** (`#f3b52a`): Join With Code, highlighted join copy, selection, focus outlines, and rare-value cues. Its dark partner (`#a66813`) forms the button base.

### Neutral

- **Near-black Ink** (`#090d0b`): page ground and dark text on colored actions.
- **Cabinet Panel** (`#111610`): control-deck surface.
- **Raised Panel** (`#1a2118`): inputs and secondary dark surfaces.
- **Warm Cream** (`#f6e6c7`): primary copy and the feature footer.
- **Muted Cream** (`#b8ad95`): descriptions, labels, and non-primary status text.

**The Three-Action Rule.** Green means fastest play, gold means directed entry, and red means creation. Keep those roles stable; do not assign these colors decoratively to unrelated primary actions.

In gameplay, the full-bleed arena uses a lighter parchment board for Classical/Arcade and `#121923` for IO. IO artwork adds deep violet, acid lime, coral, and cyan so continuous 360-degree play reads as a distinct, more kinetic mode.

## Typography

**Display Font:** Snek Display, the bundled Montserrat Black weight, with Arial Narrow and sans-serif fallbacks.
**Body Font:** Avenir Next with Avenir, Segoe UI, Helvetica, Arial, and sans-serif fallbacks.

**Character:** The display face supplies arcade-poster weight and short, punchy labels. The body stack stays plain and highly readable so instructions and live data do not compete with the artwork.

### Hierarchy

- **Display** (900, `clamp(4.4rem, 7vw, 7.3rem)`, `0.82`): the split “Outmove the room” landing statement; uppercase with `-0.04em` tracking.
- **Headline** (900, `clamp(3rem, 6vw, 5.8rem)`, `0.86`): join/create panel headings; uppercase with one colored line.
- **Action Title** (900, `clamp(1.15rem, 2.1vw, 1.9rem)`, `1`): cabinet actions and primary submit buttons.
- **Body** (`clamp(0.94rem, 1.4vw, 1.12rem)`, `1.48`): short descriptions, generally capped near `42ch`.
- **Label** (900, `0.75rem`, `0.09em`): uppercase form legends, field labels, and navigation controls.

**The Short-Burst Rule.** Use the black display face for headlines, labels, and actions—not paragraphs. Long or dynamic copy stays in the body stack and must be allowed to wrap.

## Layout

The page shell is capped at `1500px` with fluid `16–36px` side padding. Above `1080px`, the first view is a two-column composition: `1.16fr` for the arena art and a minimum `430px` cabinet column, vertically centered with a `34–70px` gap. The art preserves its aspect ratio and is capped at `76svh`; the cabinet switches between menu, join, and create panels in place.

At `1080px` and below, the layout becomes one column capped at `760px`: arena first, cabinet second. At `650px`, body padding drops to `12px`, cabinet and deck borders slim down, controls tighten, mode rows use a `104px` preview, and room settings stack. At `390px`, verbose live-count labels disappear and footer type contracts. All flexible grid columns use `minmax(0, 1fr)` or `min-width: 0`; button text and user-facing values may wrap, but the page must never gain horizontal scrolling.

The game page is a separate full-viewport operating surface: body and canvas fill `100vw × 100dvh` and hide page overflow. HUD, chat, nameplates, and modal panels are fixed overlays. Respect safe-area insets on mobile and keep overlays inside the viewport.

## Elevation & Depth

Depth is structural and arcade-like, not glassy. The cabinet uses a `28px` dark bottom slab plus a diffuse `42px` shadow; colored actions use `5–8px` darker bases; artwork uses a broad drop shadow; and controls use inset highlights to suggest painted plastic. Panels remain opaque. Gameplay overlays use compact dark fills and smaller shadows so they stay readable without obscuring motion.

Motion is brief and physical: control hover movement lasts `150ms` with `ease-out`, the landing art enters once over `620ms` using `cubic-bezier(0.16, 1, 0.3, 1)`, and reduced-motion preferences collapse animation and transition durations to `0.01ms`.

**The Mechanical-Depth Rule.** Use shadows to show a button base, cabinet seam, or overlay separation. Do not introduce translucent glass panels, ornamental glow fields, or bouncy/elastic easing.

## Shapes

The silhouette language mixes mildly rounded controls with clipped cabinet geometry. Fields and submit buttons use `7px` corners; action buttons use `5px`; mode previews use `3px`; the cabinet uses `22px 22px 12px 12px`. Status and footer plates use clipped `11–12px` chamfers instead of large pills. Circular forms are reserved for joystick parts, indicator lights, radio marks, and illustrated snake body nodes.

Illustrated edibles are round and bright. Hazards are darker and angular. Sprite artwork may carry restrained print texture, while hitboxes and interactive boundaries remain simple and server-defined.

## Components

### Arcade Actions

- **Shape:** full-width, `5px` radius, three-column icon/text/arrow layout, minimum `66–84px` height.
- **Variants:** leaf Quick Join, gold Join With Code, tomato Create Lobby.
- **States:** hover shifts `4px` right and brightens; active also moves `2px` down; keyboard focus gets a `3px` gold outline with `4px` offset.
- **Constraint:** the label column must keep `min-width: 0` and wrap rather than forcing overflow.

### Primary Submit Buttons

- **Shape:** full-width, `7px` radius, minimum `62–70px` height, text and arrow at opposite ends.
- **Variants:** leaf for joining, tomato for creating, dark/gold outline for finding an open game.
- **States:** hover lifts `2px`; disabled state uses wait cursor and `0.55` opacity.

### Cards / Containers

- **Cabinet:** opaque `#0e120e`, `5px` green structural border, asymmetric rounded top and bottom corners, heavy bottom slab.
- **Action deck:** opaque dark surface, `5px` green border, `9px` top corners, inset seam.
- **Mode row:** horizontal image/title/description/radio layout, `7px` radius and `2px` border. Classical selects in leaf, Arcade in gold, IO in acid lime.

### Inputs / Fields

- **Style:** full width, at least `54px` high, `2px` warm-cream translucent stroke, `7px` radius, dark opaque background.
- **Focus:** leaf border and a four-pixel low-opacity leaf ring. Keyboard-only controls elsewhere use the gold outline.
- **Special fields:** the lobby code is large display type with wide tracking; password controls preserve space for lock and reveal icons.

### Navigation and Live Status

- The wordmark is a large illustrated icon plus uppercase display type.
- Server totals sit in a clipped dark plate with tabular numerals, dividers, and a leaf live beacon.
- Panel navigation is an understated uppercase Back control; switching panels keeps interaction inside the cabinet and moves focus into the destination panel.

### Arena and Sprite Language

- The landing arena is a processed project-generated crop from the supplied reference board.
- Classical/Arcade snake pieces are modular, orthogonal sprites. IO uses a rotated head and tail plus circular body nodes sampled along a curved trail.
- Runtime food and hazard derivatives come from the supplied 256×256 transparent export kit. Rendering can scale them, but collision geometry remains simpler than the painted silhouette.

## Do's and Don'ts

### Do

- **Do** preserve the green/gold/red action semantics across landing, join, and creation flows.
- **Do** use opaque surfaces, clipped plates, shallow radii, and physical offset bases.
- **Do** keep all page and gameplay overlays within the viewport at `320px` width and low-height landscape sizes.
- **Do** keep IO visually and mechanically distinct with smooth artwork, continuous rotation, dense colorful food, and readable angular hazards.
- **Do** preserve accessible focus outlines and the reduced-motion path.

### Don't

- **Don't** crop mode art or snake heads in ways that hide their direction, identity, or complete silhouette.
- **Don't** let display copy, button labels, lobby codes, player names, or chat text escape their containers.
- **Don't** use large rounded cards, pill-shaped general controls, glassmorphism, decorative grid fields outside the actual arena, or bouncy easing.
- **Don't** place print texture over form controls or small text; texture belongs to artwork.
- **Don't** reuse the parchment pixel treatment for IO; IO is the smooth, dark, 360-degree mode.
