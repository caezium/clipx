# Native UI conventions

Clipx follows Stint's charcoal surfaces, off-white actions, and restrained use of color. [ClipxTheme.swift](../Sources/ClipxApp/ClipxTheme.swift) owns the palette and shared control treatments for the native app.

## Color roles

| Role | Token | Color |
| --- | --- | --- |
| Canvas | `bg` | `#09090B` |
| Navigation | `bgRaised` | `#111113` |
| Cards | `surface` | `#18181B` |
| Inputs | `field` | `#19191C` |
| Inspector | `panel` | `#212124` |
| Primary text and actions | `textPrimary`, `accent` | `#FAFAFA` |
| Secondary text | `textSecondary` | `#A1A1AA` |
| Timeline ranges | `timeline` | `#8BA8D6` |
| Successful outcomes | `success` | `#8BBC9C` |
| Warnings | `warning` | `#D6B47B` |
| Errors | `danger` | `#E28C8C` |

Navigation, tags, purposes, ratings, and project headers use neutral selection states. A saved clip is ordinary library content, so its range does not need a success-colored badge. Blue identifies source-time ranges in the player. User-assigned color labels use `Theme.labelColor(_:)` and show the selected label's name; the choices remain available in a menu.

## Controls and hierarchy

- Use `PillButtonStyle` for actions and `.menuStyle(.button)` when a menu needs that same treatment. The AppKit borderless menu style does not preserve a custom SwiftUI label's surfaces reliably.
- Use `clipxInputField()` for text fields and menu pickers, and `clipxChip(selected:)` for metadata choices. Selection must remain visible through text, checkmarks, or outlines as well as color.
- Project titles use 19-point type, inspector titles 17, body text 13, section labels and controls 12, and secondary metadata 11. Keep section labels in sentence case; use monospaced digits for time and numeric metadata.
- Workspace and library gutters use 16 points. Cards use 12-point corners, inputs 8, metadata lozenges 6, and the task panel 24. Round action buttons retain Stint's pill shape.
- Clip cards keep their imagery clear: duration sits over the thumbnail; the clip name, source, range, and compact rating sit below it. Source cards share the same surface and title treatment.
- On macOS 26, `clipxToolbarChrome()` removes the additional shared glass capsule around toolbar items. Earlier systems use their standard toolbar presentation. Native navigation, search, menus, shortcuts, and selection bindings stay in their existing owners.

## Check changes in the actual app

Run the isolated [native verification](../.agents/skills/verify-clipx/features/native.md) and the [screenshot runner](screenshots/README.md). Its `--review` option adds Notes, Export, and narrow workspace captures. Inspect those alongside the library and Details view before updating the two README images. In-process checks and owned-window captures do not establish system click automation coverage.
