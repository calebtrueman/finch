# Fieldwork: Finch's design language

An interface inspired by precision instruments, printed materials and the physical
desktop. The computer is a tool, not a spectacle.

Someone sitting down at a Mac running Finch should see three things straight away:

1. This isn't macOS. It has its own visual identity.
2. This is a serious operating system: cohesive, efficient, carefully engineered.
3. It feels native to the hardware. Every interaction responds at once.

Fieldwork is not a copy of Aqua or Liquid Glass. Aqua was translucent liquid and
reflections, and recent macOS is layers of glass. Fieldwork is materials, structure,
typography and spatial relationships. Think Braun industrial design, vintage
scientific instruments, good printed paper, and a refined modern desktop. It isn't
retro, skeuomorphic, or aggressively minimal.

## Materials

| Material | Appearance | Used for |
|---|---|---|
| Canvas | warm, matte, faintly textured | the desktop, app backgrounds |
| Slate | solid, slightly raised, sharply defined | windows, panels, controls |
| Ink | high contrast, crisp type and geometry | text, icons, indicators |

Depth comes from very thin edge highlights, small differences in surface luminance,
and deliberate spacing. It doesn't come from heavy borders, big shadows, or gradients.
A window has a one-pixel outline, a faint highlight along its top edge, and a small
shadow that puts it about two millimetres above the desktop.

## Colour

There are two appearances, each designed on its own rather than as an inversion of the
other. Neither uses pure black, pure white, or Apple's blue. The green nods to the
finch without making the system a green novelty. Colour is never the only sign of a
state.

| Token | Day | Night |
|---|---|---|
| Canvas (desktop, backgrounds) | chalk `#F0EFE9` | carbon `#181D1C` |
| Slate (window surfaces) | porcelain `#FAF9F5` | iron `#252C29` |
| Ink (primary text) | charcoal `#242925` | warm white `#EAEDE6` |
| Secondary text | graphite `#646C66` | silver grey `#9EA9A2` |
| Accent | botanical green `#3D7058` | fern `#8DD5A0` |
| Selection | pale sage `#D8E8DB` | evergreen `#344C3D` |

Contrast ratios (WCAG):

| Pairing | Day | Night |
|---|---|---|
| Ink on slate | 14.0 | 12.1 |
| Accent on slate | 5.5 | 8.3 |
| Ink on selection | 11.6 | 7.9 |

Day's graphite is a shade darker than the first draft (`#69716B`). That draft was 4.4:1
on chalk, just under the 4.5:1 that small text needs; the new value clears it. Slate is
only 1.09:1 against canvas in Day, which is deliberate: the outline and the top-edge
highlight carry the structure, not a tonal jump.

## Windows

- Top corners rounded 6 px, bottom corners 2 px.
- A 1 px structural outline and a faint top-edge highlight.
- A shallow shadow.
- The title bar merges with the app's toolbar.
- The key window has a thin accent-green edge mark.
- The window controls stay on the left, where Mac apps expect them: apps leave room
  for them and put their own items on the right. They are drawn as one compact
  Fieldwork cluster (close, minimise, zoom) in ink, not as coloured traffic lights.
  Their glyphs show at all times, so colour isn't needed to tell them apart.
- Behaviour is where Finch differs:
  - Windows dragged near each other show a thin magnetic alignment guide.
  - A modifier key shows layout zones.
  - Double-clicking the title bar fills the workbench.

  All of these are immediate, predictable and reversible.

Originality in design, familiarity in operation.

## The desktop: an L-shaped frame

- **The Instrument Bar** runs along the top. Its left side holds the active app's menus,
  as on macOS, so every Mac app's main menu works unchanged, including apps with no
  window open. The menus are set in Fieldwork type. Its right side holds the system:
  `FINCH`, the workbench (`01 / Development`), the clock, network and battery. Clicking
  the Finch mark opens the launcher and the system commands. Clicking the workbench
  shows a compact overview.
- **The Rail** runs down the left edge, 48 px wide, and replaces the Dock. From the
  top, it holds:
  - the Finch mark;
  - pinned apps;
  - running apps (a slim line beside the icon, segmented for several windows);
  - the workbench switcher at the bottom.

  It doesn't magnify or float; it's part of the desktop's structure. It retracts for
  full-screen apps.

Windows sit inside this frame like sheets on a drafting table. The wallpaper is free
to be beautiful, and the frame keeps Finch recognisable on any wallpaper.

## Workbenches

Workbenches are virtual desktops treated as named, persistent environments:
`01 / Development`, `02 / Research`, `03 / Creative`.

- Each remembers its window arrangement and its preferred apps.
- The current one shows in the Instrument Bar.
- The launcher, notifications and the file manager know about workbenches.
- Definitions are plain text files that can be versioned and shared.

## Typography

There are two families:
- **Interface:** Inter, the system font already.
- **Technical:** Fragment Mono, used for workbench names, shortcuts, counts and small
  status labels.

The contrast between the two gives Fieldwork its instrument feel:

```
Files
Home / Documents / Projects
12 ITEMS                     MODIFIED TODAY
```

Weights are Regular, Medium and Semibold. The interface doesn't lean on big headings.

## Icons

Icons are illustrated again, with discipline:
- consistent perspective;
- a restrained palette;
- distinct silhouettes;
- subtle material texture;
- no mandatory rounded square.

For example:
- the file manager is an archival folder;
- the terminal is a small instrument display;
- Settings is a machined dial.

The lineage is classic Mac OS, BeOS and NeXTSTEP, drawn as modern vectors. The finch
mascot appears in onboarding, setup, empty states and About, and nowhere else.

## Motion

Movement says what happened; it doesn't celebrate that it happened:
- Windows open in 120 ms (opacity and a small scale).
- Workbenches change with a short lateral shift and a crossfade.
- Menus appear at once, with a brief fade.

There is no bouncing, no jelly, and no liquid. Durations follow the user's settings,
and Reduce Motion turns them off.

## How it reaches apps

There are two interfaces:
- **The Finch shell:** the Instrument Bar, the Rail, the launcher, workbenches, the
  file manager and Settings.
- **The app interface:** the controls AppKit draws.

Finch's AppKit is Finch's own code, so unmodified Mac apps that use standard controls
take on Fieldwork without any change to the app.

| Mode | What it does |
|---|---|
| Fieldwork | the default: system colours, controls, menus and window frames are drawn in Fieldwork |
| Classic | Aqua-compatible colours and metrics, per app (`defaults write <app> FinchTheme Classic`) or everywhere; for apps whose custom drawing assumes Aqua, and for the comparison tests against Apple's AppKit |
| Theme files | any other theme: a plist of tokens (below) |

Apps always see the appearance names they know. Fieldwork Day reports as
`NSAppearanceNameAqua` and Night as `NSAppearanceNameDarkAqua`, so apps that branch
on the appearance still choose the right assets.

### Themes: Finch UI

A theme is a property list in `AppKit.framework/Resources/Themes/<Name>.plist`, or in
`~/Library/Themes/`. It holds:
- `colors`: a system colour name mapped to `{day, night}` hex values;
- `metrics`: corner radii, outline widths, control heights;
- `fonts`: the interface and technical families;
- `motion`: durations.

Anything a theme leaves out falls back to Classic. Fieldwork is the first theme. The
theme layer is separate from the shell, so other desktops can be built on Finch
without touching the compatibility stack.

### Choosing the theme

1. The `FINCH_THEME` environment variable. `tools/host-tests.sh` sets it to Classic.
2. The app's `FinchTheme` default.
3. The global `FinchTheme` default.
4. Otherwise, Fieldwork.

## Order of work

1. Theme tokens and system colours (Day and Night), and the theme switch.
2. Controls: buttons, pop-ups, segmented controls, check boxes and radios, sliders,
   fields, scrollers, tabs, menus.
3. The window frame: corners, outline, highlight, the control cluster, the key-window
   mark.
4. The Instrument Bar (today's menu bar, rebuilt).
5. The Rail, a shell process.
6. Workbenches.
7. Icons and the mascot.

## Status

- 2026-10-09: the design language. Decided with the user: app menus stay in the
  Instrument Bar (left), and window controls stay on the left as a restyled cluster.
