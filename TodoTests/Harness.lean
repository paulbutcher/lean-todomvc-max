/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Todo.Auth
public import Todo.Store

public section

namespace TodoTests

open Todo

def checkEq [BEq α] [Repr α] (label : String) (expected actual : α) : IO Unit :=
  unless expected == actual do
    throw <| IO.userError s!"{label}: expected {repr expected}, got {repr actual}"

def alice : Account := ⟨"alice"⟩
def bob : Account := ⟨"bob"⟩

/-- A `Store` the handler tests can drive directly. What the queries in `Todo.Db` do with the
same operations is settled against a real database in `TodoTests.runDbTests`; here the point is
only to give the handlers something to read and write.

`initial` belongs to `owner`, so a test can ask as somebody else and see what that somebody
else is allowed to see. -/
def memoryStore (owner : Account) (initial : Array Item) : IO Store := do
  let items ← IO.mkRef (initial.map (fun item => (owner.value, item)))
  let nextId ← IO.mkRef ((initial.map (·.id)).foldl max 0 + 1)
  let mine (account : Account) : IO (Array Item) := do
    pure ((← items.get).filterMap fun (holder, item) =>
      if holder == account.value then some item else none)
  let modifyItem (account : Account) (id : Int64) (f : Item → Item) : IO Unit :=
    items.modify (·.map fun (holder, item) =>
      if holder == account.value && item.id == id then (holder, f item) else (holder, item))
  let remove (account : Account) (id : Int64) : IO Unit :=
    items.modify (·.filter fun (holder, item) => !(holder == account.value && item.id == id))
  pure {
    list := fun account filter => do
      pure <| (← mine account).filter fun item =>
        match filter with
        | .all => true
        | .active => !item.completed
        | .completed => item.completed
    add := fun account raw => do
      if let some title := normalisedTitle raw then
        let id ← nextId.modifyGet fun id => (id, id + 1)
        items.modify (·.push (account.value, { id, title, completed := false }))
    toggle := fun account id => do
      modifyItem account id fun item => { item with completed := !item.completed }
    delete := fun account id => do remove account id
    setTitle := fun account id raw => do
      match normalisedTitle raw with
      | none => remove account id
      | some title => modifyItem account id ({ · with title })
    toggleAll := fun account => do
      let anyActive := (← mine account).any (!·.completed)
      items.modify (·.map fun (holder, item) =>
        if holder == account.value then (holder, { item with completed := anyActive })
        else (holder, item))
    clearCompleted := fun account =>
      items.modify (·.filter fun (holder, item) => !(holder == account.value && item.completed))
  }

/-- Answers for every request with the same account, so the handlers can be driven without a
database standing behind the sign-in flow. -/
def fixedIdentity (account : Account) (revocations : IO.Ref Nat) : Auth.Identity where
  of := fun _ => pure (some account)
  address := fun _ => pure (some s!"{account.value}@example.com")
  signOut := fun _ _ => revocations.modify (· + 1)

/-- Nobody is signed in, which is what every request arrives as before it has been. -/
def anonymousIdentity : Auth.Identity where
  of := fun _ => pure none
  address := fun _ => pure none
  signOut := fun _ _ => pure ()

end TodoTests
