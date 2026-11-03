/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Css

@[expose] public section

namespace Todo

/-- Every class the pages and the stylesheets name, whichever stylesheet styles it: the views and
`Todo.Styles` both reach a class only through this type, so neither can name one the other has
never heard of. `dragging` and `resizing` are set by `chat.js` instead. -/
inductive Cls where
  | appDivider | appPane | appShell | aside | auth | chatAside | chatBubble | chatConversation
  | chatEmpty | chatError | chatForm | chatHeader | chatMessage | chatPanel | chatPrompt
  | chatReset | chatSend | chatThinking | chatTool | chatToolName | chatTools | clearCompleted
  | code | completed | connections | destroy | divider | dragging | edit | editing | endpoint
  | filters | footer | fromAssistant | fromUser | header | info | main | newTodo | note
  | passkeys | prompt | provider | providerName | providers | quiet | rename | resizing
  | running | scopes | selected | signOut | todoapp | todoCount | todoList | toggle | toggleAll
  | view | warn | withdraw
  deriving DecidableEq, Repr

namespace Cls

def name : Cls → String
  | appDivider => "app-divider"
  | appPane => "app-pane"
  | appShell => "app-shell"
  | aside => "aside"
  | auth => "auth"
  | chatAside => "chat-aside"
  | chatBubble => "chat-bubble"
  | chatConversation => "chat-conversation"
  | chatEmpty => "chat-empty"
  | chatError => "chat-error"
  | chatForm => "chat-form"
  | chatHeader => "chat-header"
  | chatMessage => "chat-message"
  | chatPanel => "chat-panel"
  | chatPrompt => "chat-prompt"
  | chatReset => "chat-reset"
  | chatSend => "chat-send"
  | chatThinking => "chat-thinking"
  | chatTool => "chat-tool"
  | chatToolName => "chat-tool-name"
  | chatTools => "chat-tools"
  | clearCompleted => "clear-completed"
  | code => "code"
  | completed => "completed"
  | connections => "connections"
  | destroy => "destroy"
  | divider => "divider"
  | dragging => "dragging"
  | edit => "edit"
  | editing => "editing"
  | endpoint => "endpoint"
  | filters => "filters"
  | footer => "footer"
  | fromAssistant => "from-assistant"
  | fromUser => "from-user"
  | header => "header"
  | info => "info"
  | main => "main"
  | newTodo => "new-todo"
  | note => "note"
  | passkeys => "passkeys"
  | prompt => "prompt"
  | provider => "provider"
  | providerName => "provider-name"
  | providers => "providers"
  | quiet => "quiet"
  | rename => "rename"
  | resizing => "resizing"
  | running => "running"
  | scopes => "scopes"
  | selected => "selected"
  | signOut => "sign-out"
  | todoapp => "todoapp"
  | todoCount => "todo-count"
  | todoList => "todo-list"
  | toggle => "toggle"
  | toggleAll => "toggle-all"
  | view => "view"
  | warn => "warn"
  | withdraw => "withdraw"

instance : Css.ClassName Cls := ⟨name⟩

end Cls

/-- A `class` attribute's value, or none for no classes at all. -/
def classes : List Cls → Option String
  | [] => none
  | cs => some (" ".intercalate (cs.map Cls.name))

end Todo
