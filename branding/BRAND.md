# Finch brand

**Finch: an open OS for Apple Silicon.**
*Built in the open, for a more open tomorrow.*

![Brand sheet](brand-sheet.png)

## Name

- In prose it's **Finch**, and the wordmark is lowercase **finch**. The OS is "Finch" or
  "Finch OS", never "FinchOS".
- The tagline is **An open OS for Apple Silicon**.
- "Apple Silicon", "Mac" and "macOS" describe compatibility only. Never put Apple's logos
  or artwork next to the Finch mark, and never imply endorsement.

## Colours

| Name | Hex | Use |
|---|---|---|
| Charcoal | `#1E2328` | Wordmark, dark backgrounds, bird outline |
| Finch Green | `#486B52` | Wing, tagline, accents, focus/selection |
| Cloud | `#F5F5F2` | Light backgrounds, bird body, text on dark |
| Slate | `#9AA0A6` | Secondary text, borders, disabled states |

The brand sheet's printed Cloud value (`#55F5F2`) is a typo. The intended off-white is
`#F5F5F2`.

Terminal (24-bit) equivalents, used by finch-init's boot banner:
Finch Green `\e[38;2;72;107;82m`, Slate `\e[38;2;154;160;166m`.

## Assets

| File | What |
|---|---|
| `logo.png` | Primary logo, for light backgrounds (transparent PNG, 1254²) |
| `logo-dark.png` | Primary logo, for dark backgrounds |
| `symbol.png` | The bird alone (transparent, square) |
| `icons/icon-<n>.png`, `icons/icon-dark-<n>.png` | App icons, 16–1024 px, Cloud / Charcoal tiles |
| `icons/Finch.icns` | macOS icon bundle |
| `icons/favicon.ico` | Favicon (16–64 px) |
| `mascot.png` | The mascot (1024²) |
| `social-preview.png` | 1280×640 GitHub / social card |
| `brand-sheet.png` | The full brand sheet (reference) |

The derived assets are generated from `logo.png` by `tools/mkbrand.py`.

## Inside the OS

- finch-init prints the Finch banner at boot.
- Finch **does not** change `SystemVersion.plist`'s `ProductName` (`macOS`). Mac apps read
  it for compatibility checks. Finch identifies itself in the kernel banner
  (`finch:finch-<version>/…`) and in its own components instead.

## Mascot

<img src="mascot.png" alt="The Finch mascot: a finch in a red devil hood holding a trident" width="280">

The mascot is a finch wearing a red devil hood and holding a trident. It's a nod to the
BSD daemon, since Darwin's userland grew out of BSD. Use it for informal places: the
README, talks, stickers, release notes, error pages and "fun" moments. The logo stays
the formal mark, so don't use the mascot in place of the logo or the app icon.

- The mascot's red (`#E8262E`, approx.) belongs to the mascot only. It isn't a UI or
  brand colour.
- Don't recolour the bird, crop off the trident, or add Apple imagery.
- It was drawn after the BSD daemon, but it is its own character. Never use the BSD
  daemon artwork itself.
