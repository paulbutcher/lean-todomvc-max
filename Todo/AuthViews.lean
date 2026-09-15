/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Html
public import AuthenticationHttp
public import Middleware
public import Todo.Authorization
public import Todo.Federation
public import Todo.Tenant
public import Todo.Views

public section

open Html
open Authentication (SignInMessage SignInRefusal)
open Authentication.Http (PageContext)

namespace Todo

/-- Where the library answers, which is also where somebody with nothing left to try has to go
back to. -/
def signInPath : String := Authentication.BaseUrl.tenantPath Todo.tenant ++ "/signin"

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
  | .addressNotVerified => "That provider has not verified that address."

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

Asking for "the code it showed you" would read, to somebody who has only looked in their mail, as
a code that should already exist: they go looking for one that was never sent and conclude the
mail is broken. What is true is that opening the link somewhere else is what produces a code, so
this is a way out of a situation rather than a step on the way, and the fold says as much before
the wording does. -/
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

/-- Where a federated sign-in begins, which is the library's route rather than one of this
application's. `returnTo` rides as a query parameter because starting one is a `GET`. -/
def federatedStart (id : Authentication.ProviderId) (returnTo : Option String := none) : String :=
  let path := Authentication.BaseUrl.tenantPath Todo.tenant ++ "/federated/" ++ id.value
  match returnTo with
  | none => path
  | some target =>
    path ++ "?" ++ (Std.Http.URI.Query.empty.insert "returnTo" target).toRawString

/-- The providers on offer, below the form rather than above it: every account here has an
address, and a provider is the shortcut rather than the way in. Nothing renders where a
deployment configured none. -/
private def providerChoices (providers : List Authentication.ProviderConfig)
    (returnTo : Option String) : List (Node .flow) :=
  if providers.isEmpty then [] else
    (p ["or"] { class_ := "divider" } : Node .flow) ::
      providers.map fun provider =>
        (p [a { href := federatedStart provider.id returnTo, class_ := "provider" }
            [s!"Continue with {Todo.Federation.label provider.id}"]] : Node .flow)

/-- What the federated routes answer for a tenant or a provider this deployment does not have.

Separate from the magic link's `unknown`, which describes a link rather than an address: getting
here means the URL named something that was never on offer, and there is no new one to ask for. -/
def notFoundPage (assets : Assets) : String :=
  cardPage assets "Not found"
    [ h2 ["Not found"],
      p ["There is nothing at that address."],
      p [a { href := signInPath } ["Sign in"]] ]

/-- Every way a federated sign-in can fail, under one heading.

The library answers them all alike on purpose: which refusal it was describes the person rather
than this application, so distinguishing them here would answer a question nobody signed in is
entitled to ask. What is left to say is what to do instead, and both ways out are offered because
which one applies depends on whether they have an account already. -/
def federationRefusedPage (assets : Assets) : String :=
  cardPage assets "That sign-in could not be completed"
    [ h2 ["That sign-in could not be completed"],
      p ["Signing in with that provider did not work. It may have been cancelled, or it may have
          told us nothing we could sign you in with."] { class_ := "warn" },
      p ["Signing in with your email address works whether or not you have used a provider
          before."],
      p [a { href := signInPath } ["Sign in with your email address"]] ]

/-- The providers are a parameter rather than something read from `context`, because
`PageContext` carries no provider information: which ones a tenant offers is the tenant config's,
and the library leaves rendering them entirely here. -/
def pages (assets : Assets) (providers : List Authentication.ProviderConfig := []) :
    Authentication.Http.Pages where
  signIn context :=
    cardPage assets s!"Sign in to {context.tenantName}"
      ([ h2 ["Sign in"],
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
        ++ providerChoices providers context.returnTo)
  -- Two shapes, chosen by the message rather than by the outcome, which is what keeps this from
  -- being an oracle of its own: `Todo.Auth.messageFor` has already decided what may be
  -- distinguished, and everything it holds back arrives here as `checkYourMail` and gets the
  -- page that says a link is coming.
  --
  -- The other shape exists because the first one lies otherwise: telling somebody who has been
  -- refused to go and open a link, under a heading saying their mail is on its way, describes
  -- something that did not happen. There is no code entry on it either: a refusal mints a decoy
  -- attempt cookie, so whatever code an earlier link produced can no longer be spent.
  sent context message :=
    match message with
    | .checkYourMail =>
      cardPage assets "Check your mail"
        ([ h2 ["Check your mail"],
           p [messageText message],
           p ["Open the link on this device and you are signed in. There is nothing to type."],
           p ["Asking again replaces the link, so only the newest one works, and there is a \
               limit on how often you can ask."] { class_ := "note" } ]
          ++ codeAside context)
    | refusal =>
      cardPage assets "No link sent"
        [ h2 ["No link sent"],
          p [messageText refusal] { class_ := "warn" },
          p [a { href := signInPath } ["Try again"]] ]
  confirm context :=
    cardPage assets s!"Sign in to {context.tenantName}"
      [ h2 ["One more tap"],
        p ["You opened this link in the browser you asked from, so this is the last step."],
        form
          (hidden "token" context.token ++ hidden "returnTo" context.returnTo
            ++ [(button ["Sign in"] : Node .flow)])
          { method := "post", action := context.action } ]
  code context shown :=
    cardPage assets "Your verification code"
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
      cardPage assets "Ask for a new link"
        [ h2 ["This link is finished"],
          p ["Either its attempts ran out or it expired. A new one takes a moment."]
            { class_ := "warn" },
          p [a { href := signInPath } ["Ask for a new link"]] ]
    else
      cardPage assets "That code was not right"
        ([ h2 ["That code was not right"],
           p [if remaining == 1 then
                "One more attempt before this link stops working."
              else
                s!"{remaining} attempts left before this link stops working."]
             { class_ := "warn" } ]
          ++ codeAside context (expanded := true))
  refused context reason :=
    cardPage assets s!"Sign in to {context.tenantName}"
      [ h2 ["Not signed in"], p [refusalText reason] ]
  unknown :=
    cardPage assets "Not found"
      [ h2 ["Not found"],
        p ["That link has been used, has expired, or was never ours. Asking for a new one is \
            the way out of all three."] ]

/-! ## Letting an agent in

The authorisation server settles what may be asked for; what somebody sees before answering is
this application's, and the specification is specific about parts of it. -/

/-- The name a client gave itself, which is a string it chose and nobody checked. Shown as such,
never as a heading, and always beside a host that did not choose it. -/
private def claimedName (name : String) : String :=
  if name.trimAscii.isEmpty then "An application" else name

/-- What is shown when the client, or the address it asked to be sent back to, could not be
established.

Nothing is sent to the client, because nothing about it has been established, so the person is
told instead. The description comes from the authorisation server and describes the request
rather than the person, so it is safe to show and is the only thing here that says what went
wrong. -/
def refusedClientPage (assets : Assets) (description : String) : String :=
  cardPage assets "That request was refused"
    [ h2 ["That request was refused"],
      p ["Something asked to use your todo list, and this server could not establish what it \
          was. Nothing has been sent to it."] { class_ := "warn" },
      p [if description.trimAscii.isEmpty then "No further detail was given." else description],
      p [a { href := Routes.links.index } ["Back to your todos"]] ]

/-- What the person is being asked, and the only page in this application where saying yes gives
something other than a browser access to the list.

Everything the MCP authorization specification requires be displayed is displayed: the host the
answer will be sent to, and the host of the identifier the client is known by, which is `none`
for a client that registered dynamically and so has no domain vouching for its name. That a
client's redirect URIs are all loopback carries a warning of its own, because no document can
establish who is listening on a port of this person's own machine.

The scopes are checkboxes rather than one yes: granting an agent the run of the list when it
only ever needed to read it is the mistake worth making easy to avoid. `conclude` narrows
whatever comes back to what was asked for, so nothing here can widen a grant. -/
def consentPage (assets : Assets) (context : Authentication.OAuth.Http.ConsentContext) : String :=
  let name := claimedName context.clientName
  let vouching : List (Node .flow) :=
    match context.clientHost with
    | some host => [p [s!"It identifies itself at {host}."]]
    | none => [p ["It registered itself with this server, so nothing vouches for that name."]]
  let loopback : List (Node .flow) :=
    if context.loopbackOnly then
      [p ["It is running on this device. Nothing can establish what it is, beyond that you \
           started it."] { class_ := "warn" }]
    else []
  cardPage assets s!"Allow {name}?"
    ([ h2 [s!"Allow {name}?"],
       p [s!"{name} is asking to use your todo list."] ]
      ++ vouching
      ++ [p [s!"If you allow it, your answer is sent to {context.redirectHost}."]]
      ++ loopback
      ++ [ form
             ([ (Html.label ["It is asking to:"] : Node .flow),
                (ul (context.requestedScopes.map fun scope =>
                  li [ input
                         { type := "checkbox", name := scope.approvalField, value := "on",
                           checked := true, id := scope.approvalField },
                       Html.label [Todo.Authorization.describe scope]
                         { for_ := scope.approvalField } ]) { class_ := "scopes" } : Node .flow) ]
               -- The field name is the routes' rather than this page's, because it has to match
               -- whatever `antiForgery` those routes were mounted inside was configured with.
               ++ hidden context.antiForgeryField (some context.antiForgeryToken)
               ++ [ (button ["Allow"]
                      { name := Authorization.answerField, value := Authorization.approveValue }
                      : Node .flow),
                    (button ["Deny"] { name := Authorization.answerField, value := "deny" }
                      : Node .flow) ])
             { method := "post", action := context.action } ])

def oauthPages (assets : Assets) : Authentication.OAuth.Http.OAuthPages where
  consent := consentPage assets
  refusedClient := refusedClientPage assets

end Todo
