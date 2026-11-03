/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Css

@[expose] public section

open Css

/-! The stylesheets and the sign-in mail draw on these, so the pages and the message that leads to
them look like one application. The colours are todomvc-app-css's own, where it has one. -/

namespace Todo.Palette

def ink : Color := .hex 0x4d4d4d
def accent : Color := .hex 0xb83f45
def accentPressed : Color := .hex 0xa03238
def focusRing : Color := .hex 0xcf7d7d
/-- The lightest grey that passes WCAG AA as text on white. -/
def quiet : Color := .hex 0x767676
def faint : Color := .hex 0x949494
def hairline : Color := .hex 0xededed
def page : Color := .hex 0xf5f5f5
def paper : Color := .hex 0xffffff
def fieldBorder : Color := .hex 0xe6e6e6
def controlBorder : Color := .hex 0xd9d9d9
def codeBackground : Color := .hex 0xebebeb
def done : Color := .hex 0x6aa84f
def errorBackground : Color := .hex 0xfdecea
def errorInk : Color := .hex 0xa4271f

/-- todomvc-app-css's body font, which the mail names because it cannot inherit it. -/
def sans : FontStack := ⟨"Helvetica Neue", ["Helvetica", "Arial", .sansSerif]⟩
def mono : FontStack := ⟨.uiMonospace, ["SFMono-Regular", "Menlo", "Consolas", .monospace]⟩
def system : FontStack := ⟨.systemUi, ["Segoe UI", "Roboto", .sansSerif]⟩

end Todo.Palette
