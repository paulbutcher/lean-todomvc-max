/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Todo.Auth
public import Todo.Store
public import Todo.ChatTurn

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
    setCompleted := fun account id completed => do
      modifyItem account id ({ · with completed })
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

/-! ## The assistant -/

/-- A `ChatStore` with no database behind it, keeping each account's messages apart the way the
real one does so that a test can check that they stay apart. -/
def memoryChatStore : IO ChatStore := do
  let messages ← IO.mkRef (#[] : Array (String × LLMClient.Msg))
  pure {
    history := fun account => do
      pure ((← messages.get).filterMap fun (holder, msg) =>
        if holder == account.value then some msg else none)
    append := fun account added =>
      messages.modify (· ++ added.map (account.value, ·))
    clear := fun account =>
      messages.modify (·.filter fun (holder, _) => holder != account.value)
  }

/-- A provider that answers from a script instead of a model, one reply per request, and refuses
once the script runs out rather than repeating its last line.

`gate` is awaited before each reply, which is what lets a test look at the panel while a turn is
still running: resolving it is the only thing that lets the turn finish, so "before" and "after"
are positions a test can actually stand in rather than durations it has to guess at. -/
def scriptedProvider (replies : Array LLMClient.Reply) (gate : Option (IO.Promise Unit) := none) :
    IO LLMClient.Provider := do
  let remaining ← IO.mkRef replies
  pure {
    name := "scripted"
    sendRequest := fun _ _ => do
      -- Branching on the result is what forces it: binding it and discarding it would leave the
      -- task unevaluated and the gate would hold nothing up.
      if let some gate := gate then
        if gate.result?.get |>.isNone then
          return .error "the gate was dropped before it opened"
      match ← remaining.modifyGet (fun rs => (rs[0]?, rs.extract 1 rs.size)) with
      | some reply => pure (.ok reply)
      | none => pure (.error "the script ran out of replies")
  }

def scriptedAssistant (replies : Array LLMClient.Reply)
    (gate : Option (IO.Promise Unit) := none) : IO Assistant := do
  pure
    { provider := scriptedProvider replies gate
      chat := ← memoryChatStore
      turns := ← Turns.new }

/-- Waits for whatever turn is in flight to stop being in flight, or gives up.

Turns run on a thread of their own, so a test that looked once would be reading a race. The bound
is what keeps a turn that never finishes from hanging the suite instead of failing it. -/
def awaitTurn (turns : Turns) (account : Account) (label : String)
    (attempts : Nat := 200) : IO Unit := do
  for _ in [0:attempts] do
    match ← turns.get account with
    | some state => if state.phase.isRunning then IO.sleep 10 else return ()
    | none => return ()
  throw (IO.userError s!"{label}: the turn was still running after {attempts} attempts")

end TodoTests
