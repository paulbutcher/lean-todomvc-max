/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Authentication
public import Html
import Std.Time

public section

open Html
open Authentication

namespace Todo.AuthMail

/-! Mail is laid out in nested tables with every rule inline, which is what survives the clients
people actually read it in: a stylesheet is stripped before the message is shown, and a `div`
with a width is not honoured by any Outlook that renders through Word. The palette and the
metrics are `public/auth.css`'s own, so the mail and the page it leads to look like one
application. -/

private def sans : String := "'Helvetica Neue', Helvetica, Arial, sans-serif"

private def ink : String := "#4d4d4d"
private def accent : String := "#b83f45"
private def quiet : String := "#767676"
private def faint : String := "#949494"
private def rule : String := "#ededed"
private def page : String := "#f5f5f5"
private def paper : String := "#ffffff"

private def presentation : List (String × String) :=
  [("role", "presentation"), ("cellpadding", "0"), ("cellspacing", "0"), ("border", "0")]

private def spanning : List (String × String) := presentation ++ [("width", "100%")]

private def rows (style : String) (children : List (Node .tableRow))
    (raw : List (String × String) := spanning) : Node .flow :=
  table (children.map Node.toTableSection) { style } raw

private def band (style : String) (children : List (Node .flow))
    (raw : List (String × String) := []) : Node .tableRow :=
  tr [td children { style } raw]

private def heading (text : String) : Node .flow :=
  h2 [text]
    { style := s!"margin:0 0 14px;font-family:{sans};font-size:22px;font-weight:300;color:{ink};" }

private def line (text : String) : Node .flow :=
  p [text]
    { style := s!"margin:0 0 20px;font-family:{sans};font-size:16px;line-height:1.5;color:{ink};" }

private def aside (children : List (Node .phrasing)) : Node .flow :=
  p children
    { style := s!"margin:0 0 8px;font-family:{sans};font-size:13px;line-height:1.6;color:{quiet};" }

/-- A cell with a background rather than a styled anchor: Outlook paints a `td` and ignores an
inline-block, so this is the shape that has a button in it everywhere. -/
private def action (href label : String) : Node .flow :=
  rows "margin:0 0 20px;"
    [ band s!"border-radius:2px;background-color:{accent};"
        [ a { href,
              style := s!"display:inline-block;padding:14px 30px;font-family:{sans};\
                font-size:16px;line-height:1;color:{paper};text-decoration:none;" }
            [label] ]
        [("bgcolor", accent)] ]
    presentation

/-- The destination in full, because a client that drops the button, and a reader who prints the
message, otherwise have nothing left to follow. -/
private def fallback (link : String) : Node .flow :=
  aside
    [ "If the button does not work, open this instead: ",
      a { href := link, style := s!"color:{accent};word-break:break-all;" } [link] ]

private def emailedCodeSection : Option String → List (Node .flow)
  | none => []
  | some value =>
    [ line "Or type this code instead:",
      rows "margin:0 0 20px;"
        [ band s!"padding:16px;text-align:center;background-color:{page};border:1px solid {rule};\
            border-radius:2px;"
            [ Html.code [value]
                { style := s!"font-family:{sans};font-size:26px;letter-spacing:0.12em;\
                    color:{ink};" } ]
            [("bgcolor", page)] ] ]

private def note (lines : List (Node .flow)) : Node .flow :=
  div lines { style := s!"margin-top:24px;padding-top:16px;border-top:1px solid {rule};" }

private def card (children : List (Node .flow)) : Node .tableRow :=
  band s!"padding:32px 28px;background-color:{paper};border:1px solid {rule};border-radius:2px;"
    children [("bgcolor", paper)]

private def footer (text : String) : Node .tableRow :=
  band "padding:20px 8px 0;text-align:center;"
    [ p [text]
        { style := s!"margin:0;font-family:{sans};font-size:12px;line-height:1.5;color:{faint};" } ]

private def wordmark : Node .tableRow :=
  band "padding:0 0 20px;text-align:center;"
    [ h1 ["todos"]
        { style := s!"margin:0;font-family:{sans};font-size:44px;font-weight:200;color:{accent};" } ]

/-- `preview` is what an inbox shows beside the subject and the message itself never shows, so
it says what the subject leaves out rather than repeating it. -/
private def wrap (subject preview : String) (content : List (Node .tableRow)) : String :=
  document
    [ head
        [ meta_ [("charset", "utf-8")],
          meta_ [("name", "viewport"), ("content", "width=device-width, initial-scale=1")],
          title subject ],
      body
        [ div [preview]
            { style := "display:none;max-height:0;overflow:hidden;opacity:0;color:transparent;\
                font-size:1px;line-height:1px;" },
          rows s!"background-color:{page};"
            [ band "padding:32px 16px;"
                [ rows "width:100%;max-width:600px;" (wordmark :: content)
                    (presentation ++ [("width", "600"), ("align", "center")]) ]
                [("align", "center")] ] ]
        { style := s!"margin:0;padding:0;background-color:{page};" } ]
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

private def invitation (details : InvitationDetails) : RenderedEmail :=
  let recipient := details.recipient.render
  let expiry := s!"The invitation expires {inWords details.expiresAt}."
  let ignore := "If you were not expecting it, you can ignore this message."
  { subject := s!"You have been invited to {details.tenantName}"
    textBody :=
      s!"You have been invited to {details.tenantName} as {recipient}.\n\n" ++
      s!"To accept, open:\n{details.acceptLink}\n\n" ++
      s!"{expiry} {ignore}"
    htmlBody := some <|
      wrap s!"You have been invited to {details.tenantName}"
        expiry <|
        [ card
            [ heading s!"You have been invited to {details.tenantName}",
              line s!"The invitation is for {recipient}. Accepting it makes the list yours.",
              action details.acceptLink "Accept the invitation",
              fallback details.acceptLink,
              note [aside [expiry], aside [ignore]] ],
          footer s!"Sent to {recipient} by {details.tenantName}." ] }

/-- What the library sends instead of its own bodies. The default states the time as epoch
seconds and carries no styling at all, neither of which is what somebody signing in to this
application should be shown. -/
def templates : EmailTemplates where
  signIn := signIn
  invitation := invitation

end Todo.AuthMail
