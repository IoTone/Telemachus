# The console

The console is the web page TMach serves at `/`. It is the whole product as a
person sees it: every screen described in this directory is reachable from the
tab bar at the top, and nothing here needs a terminal.

These pages describe **what is on screen and what it does**. The design
documents under `docs/design/` say why each subsystem is shaped as it is, and
`docs/reference/` is generated from the source and lists every route, tool,
permission and workflow. If you are reading an answer from **Docs** (the button
in the header) and it cited a design document for a question about a button,
that is the gap these pages exist to close.

## The screens

| Screen | What it is for |
|---|---|
| [Chat](chat.md) | Talk to the configured model. The answer streams. |
| [Agent](agent.md) | Ask the model to *act* — it calls the platform's own tools. |
| [Translate](translate.md) | Translate a passage, with the team's glossary applied. |
| [Search](search.md) | One box over notes, documents, files and translations. |
| [Notes](notes.md) | Short text, Markdown or Org, tagged, linked and drawn as a graph. |
| [Documents](documents.md) | Text documents you write here, filed under a path. |
| [Repository](repository.md) | Any file, any format, versioned, shared, and run through workflows. |
| [Workflows](workflows.md) | The published specs, their runs, and the triggers that start them. |
| [Review](review.md) | Work a workflow parked on a person. |
| [Knowledge](knowledge.md) | Entities and relations extracted from the team's documents. |
| [Jobs](jobs.md) | The scheduler queue — what is queued, running, held or finished. |
| [Team](team.md) | Members, roles, API tokens, the audit log, and your own password. |
| [Usage](usage.md) | What this team has spent and what its limits are. |
| [Health](health.md) | What an operator needs when told "it's slow". |
| [Localize](localize.md) | Translate the product itself. |
| [Admin](admin.md) | Branding, language, session security, email, the fleet. |
| [Beta](beta.md) | The public onboarding funnel and the people who applied. |

Three screens are composed of parts described once:

- [The editor](editor.md) — shared by Notes and Documents.
- [Workers and the queue](workers.md) — the `Workers` card (the worker fleet)
  and the `Queue` card, both of which are on the Health tab and the Admin tab.
  There is no tab of either name.

Also: [signing in](signing-in.md), the [keyboard routes](keyboard.md), and
[asking the documentation](asking-the-documentation.md).

## Which tabs you see

The bar is not the same for everybody, and a tab you cannot see is not a tab
that is broken.

- **Five tabs can be switched off by an operator** — Chat, Agent, Translate,
  Search and Workflows. When one is off for the instance, the company or the
  team, its tab is simply absent. [Team](team.md) shows which layer decided.
- **Five appear only with a permission**: Review needs `reviews:read`, Localize
  needs `localization:read`, Health needs `instance:read`, Beta needs a
  settings-manage permission, and Admin appears only for an operator.
- The rest are always there.

A tab's *contents* narrow the same way. Every listing on every screen is
filtered row by row against what you may read, so two people on one team can
look at the same screen and see different rows. That is the platform working,
not a stale page.

## The header and the footer

The header carries, left to right: the instance's own brand lockup (set in
[Admin](admin.md)), the language switcher, two keyboard affordances — the
command palette and **Docs** — your user id with an `operator` badge if you
have one, and **Sign out**.

The footer names the build: the product name, the version, and the commit it
was built from (`unreleased build` when it was built from a working tree with
no revision). Hover the commit for the full hash and when the process started.
Two instances of this platform a day apart look identical on screen; this line
is how you tell them apart. It is only shown to someone who has signed in.

## Conventions

- **A muted figure with a symbol beside it has a tooltip.** The console does
  not explain a number twice; where a column is `✓ 12 ✗ 0 ⧖ 3`, each figure
  carries its own hover text, and the legend is under the table.
- **A badge is a status**, and green means good only where good is a state the
  platform can tell you about: `active`, `confirmed`, `delivered`. A plain badge
  is neutral and a red one is a problem.
- **Nothing on screen polls itself, with three deliberate exceptions**: a
  workflow run while you are watching it, the Jobs list while there is live
  work, and the queue card while the queue is moving. Each of them stops when
  the work settles. This is not an oversight — a screen that refreshes itself
  holds your session open indefinitely, which would switch off the inactivity
  timeout described in [signing in](signing-in.md). Where a figure can go
  stale, there is a **Refresh** button.
- **Leaving a tab abandons what you were doing on it.** An unsaved note, a
  half-written document, an open detail panel and a run you were watching are
  all dropped when you switch tabs. Save first.
- **A link you paste reproduces the view, not the data.** The address bar
  mirrors which tab you are on, which run or document you have open, and which
  page and filter you set — so a link is shareable, and the person who opens it
  sees their own permitted view of it. No token, and no unsaved text, ever goes
  into the URL.
