# Design

Meridian's interface is called **Inspector**: a dense grid of what runs where, and a side panel for the thing you picked. It should read like a well-made instrument panel: neutral, precise about versions and hosts, and quiet everywhere else. One accent colour, no shadows, no decoration that carries no information.

It is built the way 37signals builds Rails apps: plain CSS, ERB partials and helpers, Stimulus for the little behaviour there is, and no build step. The direction, the map and the sidebar were each picked from mockups drawn side by side first.

## Principles

- **Sentences first, tables second.** Every page opens with what most people came for. The board starts with **Needs attention** in plain sentences ("web isn't running on web-2, but Git says it should"); the grid comes after.
- **Technical values are monospace.** Versions, SHAs, hostnames, labels and file paths use `.mono`, so they line up and are easy to copy.
- **State is never colour alone.** Every drift state is a symbol and a word as well as a tint (`✓ In sync`, `≠ Drifted`, `✕ Missing`, `? Stray`, `… Stale`, `– Unknown`).
- **One primary action per view.** `.btn--primary` is indigo; everything else is a plain, danger or quiet button.
- **No shadows on the page.** Surfaces are separated by 1px lines and a slightly different background, never by elevation. Only what floats over the page (the account menu, search results) gets one soft shadow, `--shadow-float`, so it reads as above the content.
- **Icons are Lucide's.** `icon(:name)` inlines one from `vendor/lucide`, mapped from a meaning (`:servers`, `:sign_out`) to a Lucide name in `IconsHelper::ICONS`. Add one with `bin/icons <lucide-name>` and a line in that map; a test checks every name has its file. The logo is Meridian's own.
- **No keyboard shortcuts for now.** Every place is one click from the sidebar, or a few letters in the search box.

## CSS

`app/assets/stylesheets/`, served as is by Propshaft (`stylesheet_link_tag :app`). Files load alphabetically, so the cascade order is set once with layers in `application.css`: `reset, base, layout, components, modules, utilities`.

| File | Holds |
| --- | --- |
| `colors.css` | The palette as custom properties, light and dark together via `light-dark()` |
| `base.css` | Elements: type, links, inputs, selects, tables, focus, `details` |
| `layout.css` | The shell (sidebar, rail, top bar), page header, sections, the main + side panel split, the sign-in card |
| `buttons.css` | `.btn` and its variants |
| `badges.css` | `.badge`, `.chip`, `.cell`, `.avatar` |
| `blocks.css` | Cards, tables, rows, facts, tabs, segmented controls, empty states, alerts, code blocks, steps, fields, menus, search results |
| `board.css`, `map.css` | The board's matrix, and the world map |
| `utilities.css` | A short list of single-purpose classes (`flex`, `gap`, `txt-muted`, `mono`, `sr-only`…) |

Class names follow a light BEM: a block (`.sidebar`), its parts (`.sidebar__link`) and variants (`.btn--primary`). State lives in attributes the markup needs anyway: `aria-current`, `aria-selected`, `data-state`, `data-collapsed`, `[open]`. Modern CSS does the rest: nesting, `:has()`, `color-mix()`, logical properties. Inputs, selects and tables are styled by element, so forms need no classes.

Inline `style` attributes are never used: the CSP blocks them, and a test fails if one appears in a view.

## Colour and themes

`colors.css` defines each colour once, for both themes:

```css
--color-ink: light-dark(#18181b, #f4f4f5);
```

`light-dark()` follows the page's `color-scheme`: the system's by default, or the person's choice from **Theme: System / Light / Dark** in the account menu. `theme_controller.js` sets `html[data-theme]` and a `theme` cookie, so the server renders the same theme on the next page with no flash; System clears both. Nothing else in the CSS knows about themes.

| Token | Use |
| --- | --- |
| `canvas`, `surface`, `raised` | Page background, quiet panels and table heads, hover |
| `ink`, `ink-muted`, `ink-faint` | Text, secondary text, placeholders |
| `line`, `line-strong` | Borders and dividers |
| `accent`, `accent-strong`, `accent-soft`, `accent-ink` | Indigo: primary buttons, focus, current navigation, the selected row, links |
| `ok`, `warn`, `bad`, `info`, `mute`, with `-soft` and `-line` | Drift states, health, alerts and badges |

Neutrals are zinc. Type is the system sans stack at 13px, with `ui-monospace` for technical values. Corners are 4, 6 and 8px.

## Layout

- **Sidebar** (`layouts/_sidebar`): the main places, then Manage (Projects, Agents, Secrets), then Settings and Jobs for admins. The Board carries the number of things that need attention. One toggle collapses it to an icon rail and back; the choice is a cookie, so the server renders the right width on every page. `sidebar_controller.js` only flips `data-collapsed` on `.shell` and the toggle's label.
- **Top bar** (`layouts/_topbar`): search that finds any app, server or project as you type (Enter opens the first match), and the account menu.
- **Phones:** the sidebar is a native `popover` drawer behind a **Menu** button, so it needs no JavaScript.
- **Error pages** in `public/` are static and self-contained, generated by `script/error_pages.rb`.
- **Main column and side panel** (`.split`): the Board, the Map, an app and a server put their content on the left and what you act on in `.panel` on the right. The Board's panel inspects the app you click (`boards/_inspector`, in a Turbo Frame, remembered in the URL); the Map's shows the place you click (`maps/_place`); an app's ships versions; a server's holds its facts. On narrow screens the panel drops below.

## Helpers and partials

Small, repeated pieces are helpers in `ApplicationHelper`: `page_header`, `titled_section`, `badge`, `state_badge`, `chip`, `version_cell`, `avatar`, `tabs`, `segmented`, `disclosure`, `alert_box`, `empty_state`, `pagination`, `field_errors`. A `<details>` keeps the open or closed state the person gave it when a live page morphs (`application.js`). Bigger pieces are partials next to the views that use them: `boards/_matrix`, `boards/_inspector`, `boards/_attention_item`, `apps/_deploy_progress`, `maps/_world`, `maps/_place`, `shared/_code_block`. Board and map wording lives in `BoardsHelper` and `MapsHelper`.

**The version cell** is the unit of the whole interface: one app on one server, showing the version actually running, tinted by its drift state (green: what Git says; amber with ≠: another version; red ✕: missing; dotted: stray; dashed: quiet agent or unknown). The state is also a word for screen readers and a different border.

**The map** marks each place with its worst state (purple while a deploy goes out) and the number of servers there. It names only Meridian, places that need you and the one you picked; the rest are named on hover and in the table.

## Accessibility

- Visible focus on everything: a 2px indigo outline.
- Every input has a label, visible or `.sr-only`. Icon-only buttons have an `aria-label`.
- Current navigation uses `aria-current`; sections are labelled by their headings; the selected board row uses `aria-selected`.
- Alerts use `role="alert"` for errors and `role="status"` for everything else.
- Animations respect `prefers-reduced-motion`.

## From basic to advanced

1. **Basic.** Open Meridian and read the sentences under Needs attention. Each links to the app or server it's about. If nothing needs attention, Meridian says so.
2. **Regular.** Move between places with the sidebar or the search box. Click an app in the grid to inspect it, deploy it or roll it back without leaving the board. The state chips filter the grid.
3. **Advanced.** Open the filters (label, project, state, grouping), switch between apps × servers and servers × apps, and read the map for where things run and what is moving between them.
