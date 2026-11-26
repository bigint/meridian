# Design

Meridian's interface is called **Inspector**: a dense grid of what runs where, and a side panel for the thing you picked. It should read like a well-made instrument panel: neutral, precise about versions and hosts, and quiet everywhere else. One accent colour, no shadows, no decoration that carries no information.

The direction was chosen from three mockups on a design canvas (Console, Paper, Inspector).

Browse every component, in every state, at [`/lookbook`](http://localhost:3000/lookbook) while `bin/dev` is running.

## Principles

- **Sentences first, tables second.** Every page opens with what most people came for. The board starts with **Needs attention** in plain sentences ("web isn't running on web-2, but Git says it should"), and the grid comes after.
- **Technical values are monospace.** Versions, SHAs, hostnames, labels and file paths use `font-mono`, so they line up and are easy to copy.
- **State is never colour alone.** Every drift state is a symbol and a word as well as a tint (`✓ In sync`, `≠ Drifted`, `✕ Missing`, `? Stray`, `… Stale`, `– Unknown`).
- **One primary action per view.** Primary buttons are teal; everything else is secondary, ghost or danger.
- **No shadows.** Surfaces are separated by 1px lines and a slightly different background, never by elevation.
- **No keyboard shortcuts for now.** Every place is one click from the sidebar, or a few letters in its search box.

## Layout

- **Sidebar** (`SidebarComponent`): the main places (Board, Map, Apps, Servers, Activity, Previews), then Projects, Agents and Secrets under Manage, and Settings and Jobs for admins at the bottom. The Board carries the number of things that need attention. The « button beside the logo collapses it to an icon rail (each icon named on hover and for screen readers) and » brings it back. The choice is a cookie, so the server renders the right width on every page with no flicker; the toggle itself only flips `data-collapsed` on the shell, and collapsed styles hang off that (`group-data-[collapsed]/shell:`).
- **Top bar** (`TopbarComponent`): a search box that finds any app, server or project as you type (Enter opens the first match), and the account menu with sign out.
- **Phones:** the sidebar is a native `popover` drawer behind a **Menu** button, always with names, so it needs no JavaScript.
- **Main column and side panel:** the Board, the Map, an app and a server put their content in a main column and what you act on in a panel on the right: the Map's panel shows the place you click (`PlaceInspectorComponent`): its servers with the version each app runs, the places it shares apps with, and what is wrong there; the Board's panel inspects the app you click (`AppInspectorComponent`, in a Turbo Frame, so the grid stays put and the URL remembers it); an app's panel ships versions and shows the current deploy; a server's panel holds its facts, labels and location. On narrow screens the panel drops below.
- Other pages are `max-w-6xl`; the Board, Map, apps and servers use full width with `content_for :wide`.
- **Sign-in and first run** use a centred card (`layouts/auth.html.erb`).

## Tokens

Tailwind 4 reads its theme from CSS. `app/assets/tailwind/application.css` defines **semantic** colour tokens in `@theme` and redefines their values under `prefers-color-scheme: dark`, so views write `bg-surface text-ink border-line` and never need a `dark:` variant.

| Token | Use |
| --- | --- |
| `canvas`, `surface`, `raised` | Page background, quiet panels and table heads, hover and pressed states |
| `ink`, `ink-muted`, `ink-faint` | Text, secondary text, placeholders and the least important details |
| `line`, `line-strong` | Borders and dividers |
| `accent`, `accent-strong`, `accent-soft`, `accent-ink` | Indigo: primary buttons, focus rings, current navigation, the selected row, links |
| `ok`, `warn`, `bad`, `info`, `mute`, each with `-soft` (and `-line` for borders) | Drift states, health, alerts and badges |

Neutrals are zinc. Type is the system sans stack at 13px, with `ui-monospace` for technical values. Corners are 4px (`rounded-sm`), 6px (`rounded-md`, the default) and 8px (`rounded-lg`, for cards and tables). Numbers use tabular figures.

The world map's SVG styles are the only hand-written component CSS, in an `@layer components` block in the same file, and they use the same tokens.

## Components

Generic components live in `app/components/ui/`. Each has a Lookbook preview in `test/components/previews/ui/` and tests in `test/components/ui/`.

| Component | For |
| --- | --- |
| `Ui::ButtonComponent` | Buttons, button links and `button_to` forms with a confirmation. Variants `primary`, `secondary`, `ghost`, `danger`; sizes `md`, `sm`; optional icon |
| `Ui::BadgeComponent` | Small labels: kinds, roles, server labels. Tones `neutral`, `accent`, `ok`, `warn`, `bad`, `info` |
| `Ui::StateComponent` | A drift state as symbol, word and tint |
| `Ui::PageHeaderComponent` | Title, description, actions and tabs |
| `Ui::SectionComponent` | A titled block with a count and actions, labelled for screen readers |
| `Ui::CardComponent` | A bordered surface with an optional header and footer |
| `Ui::TableComponent` | Data tables: columns declared once with alignment and monospace, and an empty message |
| `Ui::ListComponent`, `Ui::ListItemComponent` | Rows with something leading, a title and subtitle, and something trailing |
| `Ui::DescriptionListComponent` | Terms and values |
| `Ui::StatComponent` | A count as a chip; on the board, a state filter you toggle |
| `Ui::SegmentedControlComponent`, `Ui::TabsComponent` | Views of the same thing, and sub-pages |
| `Ui::DisclosureComponent` | Something folded away until asked for |
| `Ui::EmptyStateComponent` | What a page says when it is empty, and what to do next |
| `Ui::AvatarComponent` | Initials, or a drift symbol for an attention item |
| `Ui::AlertComponent` | Flashes, form errors and one-time secrets |
| `Ui::CodeBlockComponent` | Snippets with a copy button |
| `Ui::StepsComponent` | The getting-started checklist |
| `Ui::PaginationComponent` | Previous and next pages |

Meridian-specific components sit directly in `app/components/`: `SidebarComponent`, `TopbarComponent`, `BoardMatrixComponent`, `VersionCellComponent`, `AppInspectorComponent`, `AttentionItemComponent`, `AppStatusComponent`, `DeployProgressComponent` and `WorldMapComponent`.

**The version cell** is the unit of the whole interface: one app on one server, showing the version actually running, tinted by its drift state (green: what Git says; amber with ≠: another version; red ✕: missing; dotted: stray; dashed: quiet agent or unknown). The state is also a word for screen readers and a different border, never colour alone. The board matrix puts servers under their region as column groups (`aps2-az1-node-01` reads as `az1-01` under `ap-south-2`).

**The map** marks each place with its worst state (purple while a deploy goes out) and the number of servers there. It names only Meridian, places that need you and the one you picked; the rest are named on hover and in the table, which keeps crowded regions readable. The places table lists what needs attention first, with a version cell for every app on every server.

Forms need no per-form markup. `MeridianFormBuilder` is the default form builder: it styles every input, select, check box and submit button, and `form.field :name, hint: "…"` renders the label, input, hint and errors together. Pass `compact: true` for dense filter forms.

## Accessibility

- Visible focus on everything: a 2px teal outline.
- Every input has a label, visible or `sr-only`. Icon-only buttons have an `aria-label`.
- Current navigation is marked with `aria-current`; sections are labelled by their headings.
- Alerts use `role="alert"` for errors and `role="status"` for everything else.
- Animations respect `prefers-reduced-motion`.

## From basic to advanced

1. **Basic.** Open Meridian and read the sentences under Needs attention. Each links to the app or server it's about. If nothing needs attention, Meridian says so.
2. **Regular.** Move between places with the rail or the search box. Click an app in the grid to inspect it, deploy it or roll it back without leaving the board. The state chips filter the grid.
3. **Advanced.** Open the filters (label, project, state, grouping), switch between apps × servers and servers × apps, and read the map for where things run and what is moving between them.

Nothing is hidden from the basic path. It is only ordered, so the first thing on each page is the thing most people came for.
