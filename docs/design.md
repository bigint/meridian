# Design

Meridian borrows its calm from HEY: one quiet bar at the top, one menu that takes you anywhere, content on a centred sheet with a big plain title, and sentences instead of jargon wherever a newcomer would otherwise have to decode a table.

It borrows the feel, not the brand. HEY's logo, icons, illustrations and names stay HEY's. Meridian draws its own icons, uses only the system font, and has its own palette.

## What we took

| HEY pattern | In Meridian |
| --- | --- |
| A minimal navbar: search on the left, the product menu in the centre, the person on the right | The same three places. The centre button opens the jump menu; the avatar holds settings and sign out |
| A menu you can open from anywhere ("Press H"), with a type-to-go field, numbered tiles for the main places and a quiet list for the rest | Press <kbd>M</kbd> or <kbd>⌘K</kbd>. Type an app, server or project name to jump to it. <kbd>1</kbd>–<kbd>6</kbd> open the tiles |
| A centred sheet with rounded top corners, a big bold centred title and a thin rule beneath it | Every page. The board's sheet is wider, because the grid needs the room |
| One primary pill button at the sheet's top-right ("+ Write") | "+ New app", "Sync now" and similar |
| "New for you" first, everything else under a small uppercase label ("PREVIOUSLY SEEN") | The board opens on **Needs attention**: plain sentences such as "web isn't running on web-2, but Git says it should". **Everything** (the grid) comes after |
| Friendly empty states ("✨ Nothing new for you.") | "✨ Everything matches Git.", plus a short getting-started checklist on a new install |
| List rows: initials avatar, a strong first line, a subtle second line, a time on the right | Activity, releases, attention items |
| The calendar's day headings, its gold "now" marker and orange "Today" pill | Activity reads like a calendar: days as headings, a Today pill, times down the side |
| Pastel colours with a soft tint ("glint") behind them | Drift states: tinted pills, always with a symbol and a word as well, never colour alone |
| Palette as RGB triples, with semantic colours mixed from them per scheme | `--rgb-*` tokens; `--ink`, `--sheet`, `--line` and friends derive from them for light and dark |

## From basic to advanced

1. **Basic.** Open Meridian and read the sentences under Needs attention. Each one links to the app or server it's about. If nothing needs attention, Meridian says so.
2. **Regular.** Use the menu to move between places. Click an app to deploy or roll back. The summary pills filter the grid by state.
3. **Advanced.** Open the filters (label, project, state, grouping), switch between apps × servers and servers × apps, and keep your hands on the keyboard: <kbd>M</kbd> or <kbd>⌘K</kbd> to jump, <kbd>g</kbd> then a letter for a section, <kbd>/</kbd> to filter, <kbd>?</kbd> for the rest.

Nothing is hidden from the basic path. It is only ordered, so the first thing on each page is the thing most people came for.

## Tokens

The palette lives in `app/assets/stylesheets/application.css`, as `--rgb-*` triples for light and dark. Components use only the semantic tokens derived from it: `--page`, `--sheet`, `--ink`, `--ink-subtle`, `--line`, `--accent`, `--action` and the `--state-*` pairs. Type is the system stack, with a 17px base and a 2.75rem bold title.
