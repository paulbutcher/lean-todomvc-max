/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Html
public import Middleware
public import Todo.AuthViews
public import Todo.Federation
public import Todo.Views

public section

open Html
open Routes

namespace Todo

/-- What the page says happened, where something did.

There is no `connected`: a link ends in a redirect the library issues, which carries nothing, and
the row saying `Connected` is the confirmation anyway. -/
inductive AccountNotice where
  | disconnected (name : String)
  /-- The library refused because it would have left no way into the account. -/
  | lastWayIn
  | alreadyGone
  deriving DecidableEq, _root_.Repr

/-- The identity the account holds for this provider, if it holds one. Matched on the issuer
because that is what a credential records: the provider's own name for itself, which is what an
ID token is checked against and so cannot drift from the configuration. -/
private def linkedTo (linked : List (Authentication.Credential Todo.tenant))
    (provider : Authentication.ProviderConfig) :
    Option (Authentication.CredentialId Todo.tenant) :=
  (linked.find? fun credential =>
    match credential.descriptor with
    | .federatedIdentity identity => identity.issuer == provider.issuer
    | .emailAddress _ => false).map (·.id)

private def noticeText : AccountNotice → String
  | .disconnected name => s!"{name} is disconnected. Signing in with it would start a new account."
  | .lastWayIn =>
    "That is the only way into this account at the moment, so it has been kept. Connect \
     another first, or make sure mail reaches your address."
  | .alreadyGone => "That one was already disconnected."

/-- A `POST` rather than a link, and this is the whole of why the account page exists.

Starting a sign-in is a `GET` anywhere a provider is offered as a way in. Connecting one to the
account already signed in is a different operation on the same route, and the library takes the
account from the session rather than from anything in the request, so there has to be a request
with a body for the intent to be stated in.

No anti-forgery token, and none would be checked: this posts to the library's route, which is
served beside the application and outside `antiForgery`. What defends it is that the session
cookie is `SameSite=Lax`, so a cross-site `POST` arrives without one and is refused. -/
private def connectForm (provider : Authentication.ProviderConfig) :
    Node .flow :=
  form
    (hidden "returnTo" (some links.account)
      ++ [(button [s!"Connect {Todo.Federation.label provider.id}"] { class_ := "quiet" }
            : Node .flow)])
    { method := "post", action := Todo.federatedStart provider.id }

private def disconnectForm (provider : Authentication.ProviderConfig)
    (credential : Authentication.CredentialId Todo.tenant) (token : Option String) : Node .flow :=
  form
    (hidden ({} : Middleware.AntiForgeryOptions).paramName token ++ hidden "credential" (some credential.value)
      ++ [(button [s!"Disconnect {Todo.Federation.label provider.id}"] { class_ := "quiet" }
            : Node .flow)])
    { method := "post", action := links.accountUnlink }

private def providerRow (linked : List (Authentication.Credential Todo.tenant))
    (token : Option String) (provider : Authentication.ProviderConfig) : Node .listItem :=
  match linkedTo linked provider with
  | some credential =>
    li [ span [s!"{Todo.Federation.label provider.id}"] { class_ := "provider-name" },
         span ["Connected"] { class_ := "note" },
         disconnectForm provider credential token ]
  | none =>
    li [ span [s!"{Todo.Federation.label provider.id}"] { class_ := "provider-name" },
         connectForm provider ]

/-- Where somebody sees what can get them into this account, and changes it.

The address is always one of them and is not listed among the providers: every account here was
created by a link to it and none can be without one, so showing it as something to connect or
disconnect would offer a choice that does not exist. -/
def accountPage (address : Option String) (providers : List Authentication.ProviderConfig)
    (linked : List (Authentication.Credential Todo.tenant)) (token : Option String)
    (notice : Option AccountNotice := none) : String :=
  cardPage "Your account"
    ([ h2 ["Your account"] ]
      ++ (match notice with
          | none => []
          | some notice => [(p [noticeText notice] { class_ := "note" } : Node .flow)])
      ++ (match address with
          | none => []
          | some address => [(p [s!"Signed in as {address}"] : Node .flow)])
      ++ (if providers.isEmpty then
            [(p ["Signing in is by emailed link only."] : Node .flow)]
          else
            [ (p ["As well as the link we mail you, you can sign in with any of these. \
                   Connecting one here is the only way to use a provider that hides your \
                   address, because there is then no address for us to match on."] : Node .flow),
              (ul (providers.map (providerRow linked token)) { class_ := "providers" }
                : Node .flow) ])
      ++ [(p [a { href := links.index } ["Back to your todos"]] : Node .flow)])

end Todo
