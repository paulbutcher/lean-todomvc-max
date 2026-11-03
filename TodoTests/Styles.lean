/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Todo.Styles

public section

open Css Todo Todo.Styles

namespace TodoTests.Styles

def allClasses : List Cls :=
  [ .appDivider, .appPane, .appShell, .aside, .auth, .chatAside, .chatBubble, .chatConversation,
    .chatEmpty, .chatError, .chatForm, .chatHeader, .chatMessage, .chatPanel, .chatPrompt,
    .chatReset, .chatSend, .chatThinking, .chatTool, .chatToolName, .chatTools, .clearCompleted,
    .code, .completed, .connections, .destroy, .divider, .dragging, .edit, .editing, .endpoint,
    .filters, .footer, .fromAssistant, .fromUser, .header, .info, .main, .newTodo, .note,
    .passkeys, .prompt, .provider, .providerName, .providers, .quiet, .rename, .resizing,
    .running, .scopes, .selected, .signOut, .todoapp, .todoCount, .todoList, .toggle, .toggleAll,
    .view, .warn, .withdraw ]

/-- The classes todomvc-app-css styles and our stylesheets don't. Nothing here can read that
stylesheet, so this list is the claim, not a check of it. -/
def todomvcOnly : List Cls :=
  [ .clearCompleted, .completed, .destroy, .edit, .editing, .filters, .footer, .header, .main,
    .newTodo, .selected, .todoCount, .todoList, .toggle, .toggleAll, .view ]

def ours : List String := auth.classNames ++ chat.classNames

/-- `allClasses` lists every class there is, so the two theorems below, which quantify over it,
quantify over the whole of `Cls`.

For any `c : Cls`, `c ∈ allClasses` holds. Adding a constructor without adding it to the list
fails here rather than silently escaping the checks below. -/
theorem allClasses_complete (c : Cls) : c ∈ allClasses := by
  cases c <;> decide

/-- Every class a stylesheet selects on is one the views can name, so no rule waits on a class
that no page can ever carry.

For every string `n` in `ours`, the class names `Stylesheet.classNames` reads off the selectors of
`auth` and `chat` at any depth, `n` is `Cls.name` of some member of `allClasses`, which by
`allClasses_complete` is any `Cls`. The views reach the `class` attribute only through
`Todo.classes`, which renders `Cls.name`; that they never write a string of their own instead
rests on review, not on anything proved. -/
theorem stylesheets_select_only_known_classes : ∀ n ∈ ours, n ∈ allClasses.map Cls.name := by
  decide

/-- Every class the views can name is styled by something, so none is a name with no effect,
which is what a misspelling would otherwise be.

For every `c` in `allClasses`, which is every `Cls`, either `Cls.name c` is among the classes
`auth` and `chat` select on, or `c` is in `todomvcOnly`. The second disjunct rests on that list
being true of todomvc-app-css, which nothing here checks. -/
theorem every_class_is_styled : ∀ c ∈ allClasses, c.name ∈ ours ∨ c ∈ todomvcOnly := by
  decide

/-- The stylesheets as served are well formed: every block they open is closed, and they contain
no `<`, so what a browser parses is the rules written here and nothing else.

`WellFormed (s.render pretty)` is lean-css's statement of that, for each stylesheet as rendered
compactly, which is how `Todo.Assets` serves them. `render_wellFormed` proves it of any
stylesheet with no `unsafeRaw`, and `decide` establishes that hypothesis for these two. -/
theorem stylesheets_wellFormed : WellFormed auth.render ∧ WellFormed chat.render :=
  ⟨Stylesheet.render_wellFormed auth false (by decide),
    Stylesheet.render_wellFormed chat false (by decide)⟩

end TodoTests.Styles
