# Keyboard routes and the command palette

Six keys. The list is also on screen: press `?` anywhere outside a text field.

| Key | What it does |
|---|---|
| `⌘K` / `Ctrl+K` | Open the command palette |
| `?` | Show the shortcut list |
| `⌘/` / `Ctrl+/` | [Ask the documentation](asking-the-documentation.md) |
| `Esc` | Close the palette, the shortcut list, the Docs panel, or focus mode |
| `Enter` | Send a prompt, or run the selected palette item |
| `Shift+Enter` | Insert a newline instead of sending |

The modifier is shown as `⌘` on a Mac and `Ctrl+` elsewhere; the console picks
which to display, and both keys work either way.

**`⌘K` and `⌘/` work everywhere, including inside a text field.** A held
modifier is unambiguous, so there is no state in which the palette is
unreachable.

**A bare `?` only fires when the focus is not in a field.** Otherwise it would
eat a question mark in a prompt, which is the one way a help shortcut leaves a
console worse than it was. The same rule covers an input method: the `Enter`
that *confirms* a Japanese conversion does not send the prompt.

**`Esc` falls through when nothing of the keyboard's is open**, because `Esc`
already leaves the editor's focus mode. It closes one thing at a time, the
innermost first.

## The command palette

`⌘K` opens one box over whatever you are looking at. Type, and it offers three
kinds of thing:

- **A tab.** Jump to any tab you can see.
- **An action.** A handful per tab — New note, New document, Upload a document,
  Workflow runs, Refresh this screen. Every entry is something that already
  exists as a control on a screen; the palette is a shortcut to it, not a second
  surface with its own behaviour.
- **A record.** Anything the [Search](search.md) box would find — notes,
  documents, files, translations. The palette runs the same search, so it can
  only ever offer a record you are allowed to read.

`↑` and `↓` move, `Enter` runs the selected item, `Esc` closes. A record opens
on the tab that owns it.

The palette is deliberately small. It is a way to reach a screen without the
mouse, not a menu of everything the platform can do — for that, every screen's
own controls are the surface, and the HTTP API is the complete one.
