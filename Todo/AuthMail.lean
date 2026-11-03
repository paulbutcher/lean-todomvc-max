/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Authentication
public import Html
public import Todo.Palette
import Std.Time

public section

open Html
open Authentication
open Css
open Todo.Palette

namespace Todo.AuthMail

/-! Mail is laid out in nested tables with every rule inline, which is what survives the clients
people actually read it in: a stylesheet is stripped before the message is shown, and a `div`
with a width is not honoured by any Outlook that renders through Word. The metrics are
`Todo.Styles.auth`'s own, so the mail and the page it leads to look like one application. -/

/-- For `bgcolor`, which Outlook paints where it ignores `background-color`. -/
private def hex (c : Color) : String := Value.render (toValue c)

private def hairlineBorder : Border := { width := px 1, style := .solid, color := hairline }

private def presentation : List (String × String) :=
  [("role", "presentation"), ("cellpadding", "0"), ("cellspacing", "0"), ("border", "0")]

private def spanning : List (String × String) := presentation ++ [("width", "100%")]

private def rows (style : List Declaration) (children : List (Node .tableRow))
    (raw : List (String × String) := spanning) : Node .flow :=
  table (children : TableBody) { style := inlineStyle style } raw

private def band (style : List Declaration) (children : List (Node .flow))
    (raw : List (String × String) := []) : Node .tableRow :=
  tr [td children { style := inlineStyle style } raw]

private def heading (text : String) : Node .flow :=
  h2 [text]
    { style := inlineStyle
        [margin (.three 0 0 (px 14)), fontFamily sans, fontSize (px 22), fontWeight 300, color ink] }

private def line (text : String) : Node .flow :=
  p [text]
    { style := inlineStyle
        [margin (.three 0 0 (px 20)), fontFamily sans, fontSize (px 16), lineHeight 1.5, color ink] }

private def aside (children : List (Node .phrasing)) : Node .flow :=
  p children
    { style := inlineStyle
        [margin (.three 0 0 (px 8)), fontFamily sans, fontSize (px 13), lineHeight 1.6, color quiet] }

/-- A cell with a background rather than a styled anchor: Outlook paints a `td` and ignores an
inline-block, so this is the shape that has a button in it everywhere. -/
private def action (href label : String) : Node .flow :=
  rows [margin (.three 0 0 (px 20))]
    [ band [borderRadius (px 2), backgroundColor accent]
        [ a { href,
              style := inlineStyle
                [ display .inlineBlock, padding (.two (px 14) (px 30)), fontFamily sans,
                  fontSize (px 16), lineHeight 1, color paper, textDecoration .none ] }
            [label] ]
        [("bgcolor", hex accent)] ]
    presentation

/-- The destination in full, because a client that drops the button, and a reader who prints the
message, otherwise have nothing left to follow. -/
private def fallback (link : String) : Node .flow :=
  aside
    [ "If the button does not work, open this instead: ",
      a { href := link, style := inlineStyle [color accent, wordBreak .breakAll] } [link] ]

private def emailedCodeSection : Option String → List (Node .flow)
  | none => []
  | some value =>
    [ line "Or type this code instead:",
      rows [margin (.three 0 0 (px 20))]
        [ band
            [ padding (px 16), textAlign .center, backgroundColor page, border hairlineBorder,
              borderRadius (px 2) ]
            [ Html.code [value]
                { style := inlineStyle
                    [fontFamily sans, fontSize (px 26), letterSpacing (em 0.12), color ink] } ]
            [("bgcolor", hex page)] ] ]

private def note (lines : List (Node .flow)) : Node .flow :=
  div lines
    { style := inlineStyle [marginTop (px 24), paddingTop (px 16), borderTop hairlineBorder] }

private def card (children : List (Node .flow)) : Node .tableRow :=
  band
    [ padding (.two (px 32) (px 28)), backgroundColor paper, border hairlineBorder,
      borderRadius (px 2) ]
    children [("bgcolor", hex paper)]

private def footer (text : String) : Node .tableRow :=
  band [padding (.three (px 20) (px 8) 0), textAlign .center]
    [ p [text]
        { style := inlineStyle
            [margin 0, fontFamily sans, fontSize (px 12), lineHeight 1.5, color faint] } ]

private def wordmark : Node .tableRow :=
  band [padding (.three 0 0 (px 20)), textAlign .center]
    [ h1 ["todos"]
        { style := inlineStyle
            [margin 0, fontFamily sans, fontSize (px 44), fontWeight 200, color accent] } ]

/-- `preview` is what an inbox shows beside the subject and the message itself never shows, so
it says what the subject leaves out rather than repeating it. -/
private def wrap (subject preview : String) (content : List (Node .tableRow)) : String :=
  document
    (head (title subject)
      [ meta_ [("charset", "utf-8")],
        meta_ [("name", "viewport"), ("content", "width=device-width, initial-scale=1")] ])
    (body
      [ div [preview]
          { style := inlineStyle
              [ display .none, maxHeight 0, overflow .hidden, opacity 0, color .transparent,
                fontSize (px 1), lineHeight (px 1) ] },
        rows [backgroundColor page]
          [ band [padding (.two (px 32) (px 16))]
              [ rows [width (pct 100), maxWidth (px 600)] (wordmark :: content)
                  (presentation ++ [("width", "600"), ("align", "center")]) ]
              [("align", "center")] ] ]
      { style := inlineStyle [margin 0, padding 0, backgroundColor page] })
    (lang := "en")

private def monthNames : Array String :=
  #["January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December"]

private def monthName (month : Nat) : String := monthNames.getD (month - 1) (toString month)

private def twoDigits (n : Nat) : String := if n < 10 then s!"0{n}" else toString n

/-- Epoch seconds are what an attempt records and are no use to whoever reads the mail, who has
to recognise the moment as one they were there for. UTC because nothing here knows where they
are, and stated so that a reader an hour out knows which way to count. -/
def inWords (moment : Timestamp) : String :=
  let stamp :=
    Std.Time.Timestamp.ofSecondsSinceUnixEpoch (Std.Time.Second.Offset.ofInt moment.epochSeconds)
  let time := Std.Time.PlainDateTime.ofWallTime
    (Std.Time.Timestamp.toWallTime stamp Std.Time.TimeZone.UTC.offset)
  s!"{time.date.day.val} {monthName time.date.month.val.toNat} {time.date.year.toInt} at " ++
  s!"{twoDigits time.time.hour.val.toNat}:{twoDigits time.time.minute.val.toNat} UTC"

private def requesterLine (requester : RequestContext) : String :=
  match requester.ip, requester.approximateLocation with
  | some ip, some place => s!"from {ip}, near {place}"
  | some ip, none => s!"from {ip}"
  | none, some place => s!"from near {place}"
  | none, none => "from an unrecorded address"

private def signIn (details : SignInDetails) : RenderedEmail :=
  let recipient := details.recipient.render
  let asked := s!"Requested {inWords details.requestedAt}, {requesterLine details.requester}."
  let ignore :=
    "If this was not you, you can ignore this message. Nobody can sign in without opening the \
     link above."
  let typed :=
    match details.emailedCode with
    | some value => s!"\n\nOr type this code instead: {value}"
    | none => ""
  { subject := s!"Sign in to {details.tenantName}"
    textBody :=
      s!"Someone asked to sign in to {details.tenantName} as {recipient}.\n\n" ++
      s!"To continue, open:\n{details.magicLink}{typed}\n\n" ++
      s!"{asked}\n\n" ++ ignore
    htmlBody := some <|
      wrap s!"Sign in to {details.tenantName}"
        s!"The link signs you in as {recipient}, once." <|
        [ card
            ([ heading s!"Sign in to {details.tenantName}",
               line s!"Someone asked to sign in as {recipient}. Opening the link below is all \
                 that is left to do, and it works once.",
               action details.magicLink "Sign in",
               fallback details.magicLink ]
              ++ emailedCodeSection details.emailedCode
              ++ [note [aside [asked], aside [ignore]]]),
          footer s!"Sent to {recipient} by {details.tenantName}." ] }

/-- What the library sends instead of its own sign-in bodies, which state the time as epoch
seconds and carry no styling at all.

The invitation is left with the library. Nothing here can create one: signing up is unrestricted,
so an invitation would grant nothing that asking for a link does not, and no route in this
application or in the library calls `Service.createInvitation`. A renderer is still required, and
one written for a mail that is never sent would go stale unread. -/
def templates : EmailTemplates where
  signIn := signIn
  invitation := EmailTemplates.standard.invitation

end Todo.AuthMail
