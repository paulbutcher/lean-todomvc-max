/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Todo.Classes
public import Todo.Palette

@[expose] public section

open Css Todo.Palette

namespace Todo.Styles

def cls (c : Cls) : Subclass := class_ c

def line (color : Color := hairline) : Border := { width := px 1, style := .solid, color }

def none_ : Border := { style := .none }

def keyword (k : String) : Value := [.ident k]

def fieldFocus : List Declaration :=
  [outline none_, borderColor accent, boxShadow [{ x := 0, y := 0, blur := px 2, spread := px 2, color := focusRing }]]

/-! ## Sign-in, account and connect pages

What these need beyond todomvc-app-css, which styles a list and not a form. -/

def inAuth (s : Complex) : Complex := descendant (cls .auth) s

def auth : Stylesheet := [
  rule [cls .auth] [padding (.three (px 24) (px 20) (px 28))],
  rule [inAuth (tag "h2")] [
    margin (.three 0 0 (px 14)), fontSize (px 22), fontWeight 300, color ink],
  rule [inAuth (tag "p")] [margin (.three 0 0 (px 16)), lineHeight 1.5],
  rule [inAuth (tag "label")] [
    display .block, marginBottom (px 8), fontSize (px 12), letterSpacing (em 0.08),
    textTransform .uppercase, color faint],
  rule [inAuth (tag "input" ++ attr "type" (.equals "email")),
      inAuth (tag "input" ++ attr "type" (.equals "text"))] [
    width (pct 100), boxSizing .borderBox, padding (.two (px 14) (px 16)), fontFamily.inherit,
    fontSize (px 20), color.inherit, backgroundColor paper, border (line fieldBorder),
    borderRadius (px 2),
    boxShadow [{ x := 0, y := px (-1), blur := px 5, color := .rgb 0 0 0 0.06, inset := true }]],
  rule [inAuth (tag "input" ++ pseudo .focus)] fieldFocus,
  rule [inAuth (tag "button")] [
    marginTop (px 18), padding (.two (px 12) (px 22)), fontFamily.inherit, fontSize (px 16),
    color paper, backgroundColor accent, border none_, borderRadius (px 2), cursor .pointer],
  rule [inAuth (tag "button" ++ pseudo .hover)] [backgroundColor accentPressed],
  -- One block per assistant, separated rather than boxed: what distinguishes the rows is which
  -- assistant each is about, and a border around each would say they are cells of something.
  rule [inAuth (tag "ul" ++ cls .connections)] [margin 0, padding 0, listStyleType .none],
  rule [inAuth (nextSibling (child (tag "ul" ++ cls .connections) (tag "li")) (tag "li"))] [
    marginTop (px 20), paddingTop (px 20), borderTop (line)],
  rule [inAuth (descendant (tag "ul" ++ cls .connections) (tag "p"))] [
    margin (.three 0 0 (px 8))],
  -- Quieter than the red buttons. Those are the ones that act on the list itself; these sit
  -- beside what they are about, and a page whose loudest control is a convenience reads wrong.
  rule [inAuth (tag "button" ++ cls .quiet)] [
    marginTop 0, padding (.two (px 8) (px 16)), fontSize (px 14), color ink,
    backgroundColor paper, border (line controlBorder)],
  rule [inAuth (tag "button" ++ cls .quiet ++ pseudo .hover)] [backgroundColor page],
  -- The cross-device code entry. Collapsed because it applies to one way of arriving here and
  -- not the usual one, and an open field asks to be filled in.
  rule [inAuth (cls .aside)] [marginTop (px 28), paddingTop (px 20), borderTop (line)],
  rule [inAuth (descendant (cls .aside) (tag "summary"))] [
    color accent, fontSize (px 14), cursor .pointer],
  rule [inAuth (descendant (cls .aside) (tag "p"))] [
    marginTop (px 14), fontSize (px 14), color quiet],
  -- The code the other device displays, which somebody is reading off one screen and typing
  -- into another.
  rule [inAuth (cls .code)] [
    display .block, margin (.two (px 24) 0), fontSize (px 38), letterSpacing (em 0.12),
    textAlign .center, color ink],
  rule [inAuth (cls .warn)] [color accent],
  -- Said on every "check your mail", whatever happened, so it can carry no information about
  -- which outcome this was.
  rule [inAuth (cls .note)] [fontSize (px 14), color quiet],
  -- The prompt somebody hands to their own assistant. A `readonly` textarea rather than a block
  -- of prose, because what has to happen next is a select-all and a copy, and a textarea is what
  -- a browser will select the whole of on its own. `connect.js` reads and selects it as a form
  -- control, so prose styled to look like this would leave the copy button with nothing to take.
  rule [inAuth (tag "textarea" ++ cls .prompt)] [
    width (pct 100), boxSizing .borderBox, padding (.two (px 14) (px 16)), fontFamily mono,
    fontSize (px 13), lineHeight 1.6, color.inherit, backgroundColor paper,
    border (line fieldBorder), borderRadius (px 2), resize .vertical],
  rule [inAuth (tag "textarea" ++ cls .prompt ++ pseudo .focus)] fieldFocus,
  rule [inAuth (tag "ul")] [margin (.three 0 0 (px 16)), paddingLeft (px 20), lineHeight 1.6],
  rule [inAuth (descendant (cls .endpoint) (tag "code"))] [
    fontFamily mono, fontSize (px 13), wordBreak .breakAll],
  -- The one thing on the connect page that takes something away, set apart from the rest of it
  -- so that it is not read as part of the setting-up.
  rule [inAuth (cls .withdraw)] [marginTop (px 28), paddingTop (px 20), borderTop (line)],
  -- Each scope is a choice, not an item in a list, so the marker goes and the label sits beside
  -- its box rather than taking the block form the field captions above use.
  rule [inAuth (cls .scopes)] [listStyleType .none, margin (.three 0 0 (px 16)), paddingLeft 0],
  rule [inAuth (descendant (cls .scopes) (tag "li"))] [
    display .flex, alignItems .baseline, gap (px 10), marginBottom (px 10)],
  rule [inAuth (descendant (cls .scopes) (tag "input" ++ attr "type" (.equals "checkbox")))] [
    flexGrow 0, flexShrink 0, flexBasis .auto, width (px 16), height (px 16),
    declare "accent-color" accent],
  rule [inAuth (descendant (cls .scopes) (tag "label"))] [
    display .inline, margin 0, fontSize.inherit, declare "letter-spacing" (keyword "normal"),
    textTransform .none, color.inherit, cursor .pointer],
  -- Two answers side by side, which without this meet as one block of colour.
  rule [inAuth (nextSibling (tag "button") (tag "button"))] [marginLeft (px 10)],
  -- What separates the emailed link from the providers. A word rather than a rule, because the
  -- two are alternatives and a rule alone reads as the end of the page.
  rule [inAuth (cls .divider)] [
    margin (.three (px 24) 0 (px 16)), fontSize (px 14), color quiet, textAlign .center],
  -- Styled as the buttons are, because that is what they do here: each one starts a sign-in.
  -- The `a` stays an `a` because starting one is a `GET`, and a form per provider would say
  -- otherwise. The passkey button is a `button` and looks like the rest, being one more way in.
  rule [inAuth (tag "a" ++ cls .provider), inAuth (tag "button" ++ cls .provider)] [
    display .block, boxSizing .borderBox, width (pct 100), marginTop 0, fontFamily.inherit,
    padding (px 12), fontSize (px 16), color ink, textAlign .center, textDecoration .none,
    backgroundColor paper, border (line controlBorder), borderRadius (px 2)],
  rule [inAuth (tag "a" ++ cls .provider ++ pseudo .hover),
      inAuth (tag "button" ++ cls .provider ++ pseudo .hover)] [backgroundColor page],
  rule [inAuth (child (nextSibling (tag "p") (tag "p")) (tag "a" ++ cls .provider))] [marginTop 0],
  -- One row per provider, the name on the left and whatever can be done about it on the right.
  -- Laid out rather than listed because each row is a thing and a control over it, not prose.
  rule [inAuth (tag "ul" ++ cls .providers)] [
    margin (.three (px 16) 0 0), padding 0, listStyleType .none],
  rule [inAuth (child (tag "ul" ++ cls .providers) (tag "li"))] [
    display .flex, gap (px 12), alignItems .center, padding (.two (px 12) 0), borderTop (line)],
  rule [inAuth (descendant (tag "ul" ++ cls .providers) (cls .providerName))] [
    flexGrow 1, flexShrink 1, flexBasis 0, color ink],
  rule [inAuth (descendant (tag "ul" ++ cls .providers) (tag "form"))] [margin 0],
  -- A passkey's name is shown in the field that changes it, so the field takes the room the name
  -- would have taken.
  rule [inAuth (descendant (tag "ul" ++ cls .passkeys) (tag "form" ++ cls .rename))] [
    flexGrow 1, flexShrink 1, flexBasis 0, display .flex, gap (px 8), minWidth 0],
  rule [inAuth (descendant (tag "ul" ++ cls .passkeys)
      (descendant (tag "form" ++ cls .rename) (tag "input" ++ attr "type" (.equals "text"))))] [
    flexGrow 1, flexShrink 1, flexBasis 0, width .auto, minWidth 0, padding (.two (px 8) (px 10)),
    fontSize (px 16)],
]

/-! ## The list page's split and the assistant panel

`todomvc-app-css` styles the list itself and is loaded unmodified; everything here is the frame
around it, so the list still looks like the one the spec describes. -/

/-- The panel's width, a custom property because the divider drag is the only thing that sets it,
and setting one property is the whole of what dragging has to do. `chat.js` writes it by name. -/
def chatWidth : CustomProp (OrAuto LengthPercentage) := .named "chat-width"

def chatPulse := keyframes "chat-pulse" [
  frame [.at (pct 0), .at (pct 100)] [opacity 1],
  frame [.at (pct 50)] [opacity 0.35],
]

def pulse (duration : Time) : Animation :=
  { name := chatPulse, duration, easing := .easeInOut, iterations := .infinite }

def chat : Stylesheet := [
  rule [pseudo .root] [chatWidth (rem 26)],
  rule [tag "html", tag "body"] [height (pct 100)],
  -- `todomvc-app-css` sizes the list by constraining `body` itself to 550px and centring it,
  -- which is right when the list is the whole page and wrong now that it is one pane beside
  -- another: the flex shell would be 550px wide, both panes would sit on their own `min-width`
  -- with nothing left to give, and the divider would have nowhere to move to. The constraint
  -- moves to the pane's contents below.
  rule [tag "body"] [margin 0, minWidth 0, maxWidth .none, overflow .hidden],
  rule [cls .appShell] [display .flex, height (vh 100), alignItems .stretch],
  -- The list keeps its own centred layout and scrolls within its half rather than moving the
  -- page, so the panel beside it stays put while a long list is read.
  rule [cls .appPane] [
    flexGrow 1, flexShrink 1, flexBasis .auto, minWidth (rem 20), overflowY .auto,
    overflowX .hidden],
  -- What `body` used to do for these two. Both keep the vertical margins `todomvc-app-css` gives
  -- them and gain the horizontal centring it used to get from the page being 550px wide.
  rule [descendant (cls .appPane) (cls .todoapp), descendant (cls .appPane) (cls .info)] [
    maxWidth (px 550), marginLeft .auto, marginRight .auto],
  -- A button only because signing out is a POST; it sits among the footer's links and should
  -- read as one, as `todomvc-app-css` styles `.info a`.
  rule [descendant (cls .info) (cls .signOut)] [cursor .pointer],
  rule [descendant (cls .info) (cls .signOut ++ pseudo .hover)] [textDecoration .underline],
  rule [cls .appDivider] [
    flexGrow 0, flexShrink 0, flexBasis (px 6), cursor .colResize, backgroundColor hairline,
    border none_, declare "touch-action" (keyword "none")],
  rule [cls .appDivider ++ pseudo .hover, cls .appDivider ++ cls .dragging] [
    backgroundColor accent],
  -- Border-box so the left border falls inside the width rather than being added to it: the
  -- resize handler measures the panel and writes the result back, and a border outside the width
  -- would be added again on every resize event. The font is set whole, weight included, because
  -- `todomvc-app-css` gives `body` a light weight meant for the list.
  rule [cls .chatPanel] [
    boxSizing .borderBox, flexGrow 0, flexShrink 0, flexBasis.var chatWidth, minWidth (rem 18),
    display .flex, flexDirection .column, backgroundColor paper, borderLeft (line),
    fontFamily system, fontSize (px 14), lineHeight 1.5, fontWeight 400, color ink],
  -- Dragging over an iframe-free page still loses the pointer to text selection without this;
  -- the script adds the class to `body` for the duration of a drag.
  rule [tag "body" ++ cls .resizing] [cursor .colResize, userSelect .none],
  rule [cls .chatHeader] [
    display .flex, alignItems .center, justifyContent .spaceBetween,
    padding (.two (rem 0.75) (rem 1)), borderBottom (line)],
  rule [descendant (cls .chatHeader) (tag "h2")] [margin 0, fontSize (rem 1), fontWeight 600],
  rule [cls .chatReset] [
    border (line), borderRadius (px 4), backgroundColor paper, color faint,
    padding (.two (rem 0.25) (rem 0.6)), fontSize (rem 0.8), cursor .pointer],
  rule [cls .chatReset ++ pseudo .hover] [color accent, borderColor accent],
  rule [cls .chatConversation] [
    flexGrow 1, flexShrink 1, flexBasis .auto, overflowY .auto, padding (rem 1)],
  rule [cls .chatEmpty] [color faint, textAlign .center, marginTop (rem 2)],
  rule [cls .chatMessage] [marginBottom (rem 1), display .flex, flexDirection .column],
  rule [cls .chatMessage ++ cls .fromUser] [alignItems .flexEnd],
  rule [cls .chatMessage ++ cls .fromAssistant] [alignItems .flexStart],
  rule [cls .chatBubble] [
    maxWidth (pct 85), padding (.two (rem 0.5) (rem 0.75)), borderRadius (px 10),
    overflowWrap .anywhere],
  rule [descendant (cls .fromUser) (cls .chatBubble)] [
    backgroundColor accent, color paper, whiteSpace .preWrap],
  rule [descendant (cls .fromAssistant) (cls .chatBubble)] [backgroundColor page],
  -- Markdown arrives as whole blocks, so the first and last need their margins taken off to sit
  -- in a bubble sized to them.
  rule [child (cls .chatBubble) (pseudo .firstChild)] [marginTop 0],
  rule [child (cls .chatBubble) (pseudo .lastChild)] [marginBottom 0],
  rule [descendant (cls .chatBubble) (tag "pre")] [
    overflowX .auto, backgroundColor codeBackground, padding (rem 0.5), borderRadius (px 6)],
  rule [descendant (cls .chatBubble) (tag "code")] [fontFamily mono, fontSize (em 0.85)],
  rule [descendant (cls .chatBubble) (tag "table")] [declare "border-collapse" (keyword "collapse")],
  rule [descendant (cls .chatBubble) (tag "th"), descendant (cls .chatBubble) (tag "td")] [
    border (line), padding (.two (rem 0.2) (rem 0.4))],
  -- What the model is calling, or has called. A tool the model asked for is shown whether the
  -- turn is still running or long finished, so a reply can be read against what it was drawn
  -- from.
  rule [cls .chatTools] [
    listStyleType .none, margin (.four 0 0 (rem 0.35) 0), padding 0, fontSize (rem 0.8),
    color faint],
  rule [cls .chatTool] [display .flex, alignItems .center, gap (rem 0.4)],
  rule [cls .chatTool ++ pseudoElement .before] [content "✓", color done],
  rule [cls .chatTool ++ cls .running ++ pseudoElement .before] [
    content "◍", color accent,
    animation [pulse (sec 1)]],
  rule [cls .chatToolName] [fontFamily mono],
  rule [descendant (cls .chatThinking) (tag "span" ++ pseudoElement .after)] [
    content "…",
    animation [pulse (sec 1.2)]],
  rule [cls .chatThinking] [color faint],
  rule [cls .chatError] [backgroundColor errorBackground, color errorInk],
  chatPulse,
  media [.prefersReducedMotion] [
    rule [cls .chatTool ++ cls .running ++ pseudoElement .before,
        descendant (cls .chatThinking) (tag "span" ++ pseudoElement .after)] [animation []],
  ],
  rule [cls .chatForm] [
    display .flex, gap (rem 0.5), alignItems .flexEnd, padding (.two (rem 0.75) (rem 1)),
    borderTop (line)],
  rule [cls .chatPrompt] [
    flexGrow 1, flexShrink 1, flexBasis .auto, resize .none, declare "font" Global.inherit,
    padding (rem 0.5), border (line), borderRadius (px 6)],
  rule [cls .chatPrompt ++ pseudo .focus] [outline none_, borderColor accent],
  rule [cls .chatSend] [
    border none_, borderRadius (px 6), backgroundColor accent, color paper,
    padding (.two (rem 0.55) (rem 0.9)), cursor .pointer],
  rule [cls .chatSend ++ pseudo .hover] [
    declare "filter" ([.function "brightness" [.number 1.08]] : Value)],
  -- Below this there is no room for two columns, so the panel goes under the list rather than
  -- squeezing it. The divider has nothing left to drag and is taken out of the flow.
  media [.maxWidth (rem 48)] [
    rule [tag "body"] [overflow .auto],
    rule [cls .appShell] [flexDirection .column, height .auto],
    rule [cls .appPane] [overflow .visible],
    rule [cls .appDivider] [display .none],
    rule [cls .chatPanel] [
      flexGrow 1, flexShrink 1, flexBasis .auto, height (vh 80), borderLeft none_,
      borderTop (line)],
  ],
  -- The way out of the panel, for somebody who would rather use an assistant of their own. Under
  -- the prompt because it is the alternative to what is above it, not part of it.
  rule [cls .chatAside] [
    margin 0, padding (.three 0 (px 12) (px 12)), fontSize (px 13), textAlign .center],
  rule [descendant (cls .chatAside) (tag "a")] [color quiet],
  rule [descendant (cls .chatAside) (tag "a" ++ pseudo .hover)] [color accent],
]

end Todo.Styles
