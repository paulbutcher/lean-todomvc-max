/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Html
public import AuthenticationHttp
public import Todo.Tenant
public import Todo.Views

public section

open Html
open Authentication (SignInMessage SignInRefusal)
open Authentication.Http (PageContext)

namespace Todo

def authCss : LinkAttrs := { rel := "stylesheet", href := "/auth.css" }

/-- Where the library answers, which is also where somebody with nothing left to try has to go
back to. -/
def signInPath : String := Authentication.BaseUrl.tenantPath Todo.tenant ++ "/signin"

/-- The same shell the todo list uses, so signing in does not look like a different site. The
heading floats above the card on `todomvc-app-css`'s own positioning; it is here for that rather
than to say anything. -/
private def shell (heading : String) (children : List (Node .flow)) : String :=
  document
    [ head
        [ meta_ [("charset", "utf-8")],
          meta_ [("name", "viewport"), ("content", "width=device-width, initial-scale=1")],
          title heading, link todomvcCss, link authCss, link favicon ],
      body
        [ section_
            [ header [h1 ["todos"]] { class_ := "header" },
              div children { class_ := "auth" } ]
            { class_ := "todoapp" } ] ]
    (lang := "en")

private def hidden (name : String) (value : Option String) : List (Node .flow) :=
  match value with
  | none => []
  | some value => [input { type := "hidden", name, value }]

/-- Every outcome of asking for a link maps to one of these. Which outcomes are allowed to reach
a distinct one is `Todo.Auth.messageFor`'s decision rather than this function's: the wording here
is faithful to each case, and what keeps a case unreachable is the policy. -/
private def messageText : SignInMessage → String
  | .checkYourMail => "If that address can sign in, a link is on its way to it."
  | .addressNotRecognised => "That address does not have an account here."
  | .invitationRequired => "This list is invitation only."
  | .domainNotAllowed => "This list does not accept that address's domain."
  | .tryAgainLater => "Too many attempts. Try again later."
  | .addressMalformed => "That does not look like an email address."
  | .accountUnavailable => "That account is closed."

private def refusalText : SignInRefusal → String
  | .signup .notInvited => "This list is invitation only, and you were not invited."
  | .signup .domainNotAllowed => "This list does not accept that address's domain."
  | .accountDeactivated => "That account is closed."

private def codeField (context : PageContext) (action label id : String) : Node .flow :=
  form
    ([ (Html.label [Node.text label] { for_ := id } : Node .flow),
       (input { type := "text", name := "code", id, required := true }
         [("autocomplete", "one-time-code"), ("autocapitalize", "characters"),
          ("spellcheck", "false")] : Node .flow) ]
      ++ hidden "token" context.token
      ++ hidden "returnTo" context.returnTo
      ++ [(button ["Sign in"] : Node .flow)])
    { method := "post", action }

/-- Folded away, and written for somebody who has not opened the link yet.

The wording it replaces asked for "the code it showed you", in the past tense and in an open
field on the page that answers the very first step. Somebody who has only looked in their mail
reads that as a code that should already exist, goes looking for one that was never sent, and
concludes the mail is broken. What is true is that opening the link somewhere else is what
produces a code, and that this is a way out of a situation rather than a step on the way. -/
private def codeAside (context : PageContext) (expanded : Bool := false) : List (Node .flow) :=
  [ details
      ([ summary ["I opened the link on another device"],
         p ["That device shows a short code instead of signing you in there. Type it here to \
             finish signing in on this one."],
         codeField context context.action "Code from the other device" "code" ]
        ++ match context.emailedCodeAction with
           | none => []
           | some action =>
             [ p ["Or use the code in the mail itself."],
               codeField context action "Code from the mail" "emailed-code" ])
      { class_ := "aside", open_ := expanded } ]

def pages : Authentication.Http.Pages where
  signIn context :=
    shell s!"Sign in to {context.tenantName}"
      [ h2 ["Sign in"],
        p ["Enter your address and we will mail you a link. There is no password to remember."],
        form
          ([ (Html.label ["Email address"] { for_ := "email" } : Node .flow),
             (input
               { type := "email", name := "email", id := "email", required := true,
                 placeholder := "you@example.com" }
               [("autocomplete", "email"), ("autocapitalize", "off"), ("spellcheck", "false"),
                ("autofocus", "autofocus")] : Node .flow) ]
            ++ hidden "returnTo" context.returnTo
            ++ [(button ["Send me a link"] : Node .flow)])
          { method := "post", action := context.action } ]
  -- Two shapes, chosen by the message rather than by the outcome, which is what keeps this from
  -- being an oracle of its own: `Todo.Auth.messageFor` has already decided what may be
  -- distinguished, and everything it holds back arrives here as `checkYourMail` and gets the
  -- page that says a link is coming.
  --
  -- The other shape exists because the first one lies otherwise. Telling somebody who has been
  -- refused to go and open a link, under a heading saying their mail is on its way, is worse
  -- than the silence it replaced. There is no code entry on it either: a refusal mints a decoy
  -- attempt cookie, so whatever code an earlier link produced can no longer be spent.
  sent context message :=
    match message with
    | .checkYourMail =>
      shell "Check your mail"
        ([ h2 ["Check your mail"],
           p [messageText message],
           p ["Open the link on this device and you are signed in. There is nothing to type."],
           p ["Asking again replaces the link, so only the newest one works, and there is a \
               limit on how often you can ask."] { class_ := "note" } ]
          ++ codeAside context)
    | refusal =>
      shell "No link sent"
        [ h2 ["No link sent"],
          p [messageText refusal] { class_ := "warn" },
          p [a { href := signInPath } ["Try again"]] ]
  confirm context :=
    shell s!"Sign in to {context.tenantName}"
      [ h2 ["One more tap"],
        p ["You opened this link in the browser you asked from, so this is the last step."],
        form
          (hidden "token" context.token ++ hidden "returnTo" context.returnTo
            ++ [(button ["Sign in"] : Node .flow)])
          { method := "post", action := context.action } ]
  code context shown :=
    shell "Your verification code"
      [ h2 ["Your verification code"],
        p ["Type this into the browser you asked to sign in from. It will not sign you in on \
            this device."],
        p [strong [Html.code [Node.text shown]]] { class_ := "code" },
        p [s!"Asked for by {context.tenantName}."] ]
  -- Whoever is reading this has a code in front of them and got it wrong, so the field is open
  -- rather than folded away behind the question it already answers.
  --
  -- Zero remaining is not only the attempts running out: a submission the library could not
  -- evaluate at all, against an attempt that has expired or was never there, arrives here as
  -- zero as well. So that branch says what is true of all of them and does not claim a code was
  -- read and rejected, which for an expired link it was not.
  codeRejected context remaining :=
    if remaining == 0 then
      shell "Ask for a new link"
        [ h2 ["This link is finished"],
          p ["Either its attempts ran out or it expired. A new one takes a moment."]
            { class_ := "warn" },
          p [a { href := signInPath } ["Ask for a new link"]] ]
    else
      shell "That code was not right"
        ([ h2 ["That code was not right"],
           p [if remaining == 1 then
                "One more attempt before this link stops working."
              else
                s!"{remaining} attempts left before this link stops working."]
             { class_ := "warn" } ]
          ++ codeAside context (expanded := true))
  refused context reason :=
    shell s!"Sign in to {context.tenantName}"
      [ h2 ["Not signed in"], p [refusalText reason] ]
  unknown :=
    shell "Not found"
      [ h2 ["Not found"],
        p ["That link has been used, has expired, or was never ours. Asking for a new one is \
            the way out of all three."] ]

end Todo
