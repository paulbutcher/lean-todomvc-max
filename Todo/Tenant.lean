/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Authentication.Tenant

@[expose] public section

namespace Todo

/-- A todo list has no organisations in it, so there is one tenant. It still has to be named:
every identifier the library hands back is indexed by the tenant it belongs to, and that index
is what stops one account's list being reached with another's identifier. -/
def tenant : Authentication.TenantId := ⟨"todomvc"⟩

abbrev Account := Authentication.AccountId tenant

end Todo
