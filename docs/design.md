# Design

Meridian's interface is called **Instrument**. It should read like a well-made instrument panel: neutral, dense where density helps, precise about versions and hosts, and quiet everywhere else. One accent colour, no shadows, no decoration that carries no information.

Browse every component, in every state, at [`/lookbook`](http://localhost:3000/lookbook) while `bin/dev` is running.

## Principles

- **Sentences first, tables second.** Every page opens with what most people came for. The board starts with **Needs attention** in plain sentences ("web isn't running on web-2, but Git says it should"), and the grid comes after.
- **Technical values are monospace.** Versions, SHAs, hostnames, labels and file paths use `font-mono`, so they line up and are easy to copy.
- **State is never colour alone.** Every drift state is a symbol and a word as well as a tint (`✓ In sync`, `≠ Drifted`, `✕ Missing`, `? Stray`, `… Stale`, `– Unknown`).
- **One primary action per view.** Primary buttons are teal; everything else is secondary, ghost or danger.
- **No shadows.** Surfaces are separated by 1px lines and a slightly different background, never by elevation.
- **No keyboard shortcuts for now.** Every place is one click from the sidebar, or a few letters in its search box.

## Layout

- **Sidebar** (`SidebarComponent`): the logo, a search box that finds any app, server or project as you type (Enter opens the first match), the main places (Board, Map, Apps, Servers, Activity, Previews), a quieter **Manage** group (Projects, Agents, Secrets, and Settings and Jobs for admins), and the person with a sign-out button at the bottom.
- **Phones:** the same sidebar is a native `popover` drawer behind a **Menu** button, so it needs no JavaScript.
- **Main column:** a `PageHeaderComponent`, then the page. Pages are `max-w-6xl`; the Board and Map opt into full width with `content_for :wide`.
- **Sign-in and first run** use a centred card (`layouts/auth.html.erb`).

## Tokens

Tailwind 4 reads its theme from CSS. `app/assets/tailwind/application.css` defines **semantic** colour tokens in `@theme` and redefines their values under `prefers-color-scheme: dark`, so views write `bg-surface text-ink border-line` and never need a `dark:` variant.

| Token | Use |
| --- | --- |
| `canvas`, `surface`, `raised` | Page background, quiet panels and table heads, hover and pressed states |
| `ink`, `ink-muted`, `ink-faint` | Text, secondary text, placeholders and the least important details |
| `line`, `line-strong` | Borders and dividers |
| `accent`, `accent-strong`, `accent-soft`, `accent-ink` | Teal: primary buttons, focus rings, current navigation, links |
| `ok`, `warn`, `bad`, `info`, `mute`, each with `-soft` | Drift states, health, alerts and badges |

Neutrals are zinc. Type is the system sans stack at 14px, with `ui-monospace` for technical values. Corners are 4px (`rounded-sm`), 6px (`rounded-md`, the default) and 8px (`rounded-lg`, for cards and tables). Numbers use tabular figures.

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
| `Ui::StatComponent` | A number and its meaning; on the board, a filter link |
| `Ui::SegmentedControlComponent`, `Ui::TabsComponent` | Views of the same thing, and sub-pages |
| `Ui::DisclosureComponent` | Something folded away until asked for |
| `Ui::EmptyStateComponent` | What a page says when it is empty, and what to do next |
| `Ui::AvatarComponent` | Initials, or a drift symbol for an attention item |
| `Ui::AlertComponent` | Flashes, form errors and one-time secrets |
| `Ui::CodeBlockComponent` | Snippets with a copy button |
| `Ui::StepsComponent` | The getting-started checklist |
| `Ui::PaginationComponent` | Previous and next pages |

Meridian-specific components sit directly in `app/components/`: `SidebarComponent`, `BoardGridComponent`, `AttentionItemComponent`, `AppStatusComponent`, `DeployProgressComponent` and `WorldMapComponent`.

Forms need no per-form markup. `MeridianFormBuilder` is the default form builder: it styles every input, select, check box and submit button, and `form.field :name, hint: "…"` renders the label, input, hint and errors together. Pass `compact: true` for dense filter forms.

## Accessibility

- Visible focus on everything: a 2px teal outline.
- Every input has a label, visible or `sr-only`. Icon-only buttons have an `aria-label`.
- Current navigation is marked with `aria-current`; sections are labelled by their headings.
- Alerts use `role="alert"` for errors and `role="status"` for everything else.
- Animations respect `prefers-reduced-motion`.

## From basic to advanced

1. **Basic.** Open Meridian and read the sentences under Needs attention. Each links to the app or server it's about. If nothing needs attention, Meridian says so.
2. **Regular.** Move between places with the sidebar or its search. Open an app to deploy or roll back. The summary numbers filter the grid by state.
3. **Advanced.** Open the filters (label, project, state, grouping), switch between apps × servers and servers × apps, and read the map for where things run and what is moving between them.

Nothing is hidden from the basic path. It is only ordered, so the first thing on each page is the thing most people came for.
