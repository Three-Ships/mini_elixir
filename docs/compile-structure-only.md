# Spec: `compile/1` stops validating function clauses

Branch: `no-function-validation` (cut from `main` at 383339b9a, the merge of PR #2).
Target: PR against `jowi-dev/mini_elixir` `main`.

## Why

PR #2 added `compile/1` and made it run the sandbox validator over every `def`
and `defp` clause in the module. `eval/5` never did that: it validated only the
body of the one function it was about to call, and private helpers compiled
unchecked. Pointing the validator at helpers for the first time rejects code
that runs in production today.

Measured on 2026-11-12 against a copy of Axiom's production `transforms` table
(466 rows): 152 modules fail `compile/1`, 148 of them only in a `defp` helper.
The validator cannot tell a variable bound inside a function body (`case`,
`with`, `fn`, `=`) from a module name, so `r.propensity_score` becomes
"Forbidden function: r.propensity_score" (110 modules share that helper). The
rest are `Atom.to_string`, `Jason.decode`, `:io_lib.format`,
`Calendar.strftime`, and `def ... rescue` clauses, which the clause walker
rejects outright as "Unsupported function definition".

The sandbox is not the concern it was when PR #2 was written: transform edits
now go through a review pipeline before they are applied. `compile/1` should
be what its name says: parse, check the module shape, compile. Nothing more.

## Change

In `lib/mini_elixir.ex`:

1. Remove `validate_all_functions(ast)` from the `with` in `compile/1`
   (currently line 147). The chain becomes `parse` → `single_module` →
   `validate_module_structure` → `Code.compile_quoted`.
2. Delete the now-unreferenced private functions: `validate_all_functions/1`,
   `validate_function/1`, `unwrap_head/1`, `strip_defaults/1` (lines 318–376).
   `unwrap_function/3` stays; `eval/5` uses it.
3. `validate_module_structure/1` stays as is. It still rejects nested
   `defmodule`, top-level code after the module, and non-definition statements.
   It does not look inside function bodies.
4. Do not touch `eval/5` or `MiniElixir.Validator`. `eval/5` keeps validating
   the function it calls exactly as before.

Docs:

5. `@doc` on `compile/1` (line ~115): replace the sentence "Every `def` and
   `defp` clause in it is validated with the same rules `eval/5` applies to the
   function it runs" with: "The module's shape is checked (one top-level
   `defmodule`, only `def`/`defp`/`alias`/`import`/`require`/`use` inside);
   function bodies are not validated. Callers that need the `eval/5` sandbox
   on a compiled module can run `MiniElixir.Validator.check/2` over the
   clauses they care about."
6. `README.md` `### MiniElixir.compile/1` section (lines 133–170): change the
   first paragraph from "Validates and compiles" to "Checks the module shape
   and compiles". In `#### Behaviour`, replace the first bullet with: "Function
   bodies are not validated; `def` clauses may use `rescue`, `catch` and
   `after`. Only the module shape is checked." Keep the other two bullets.
   In `#### Returns`, drop "validator or" from the error description.

Tests in `test/mini_elixir_test.exs`, `describe "compile/1"` (line 251):

7. Delete these tests; they assert the removed behaviour:
   - "rejects a forbidden call in a defp before compiling"
   - "rejects a forbidden call in a second def"
   - "rejects a forbidden call in a guarded clause"
   - "rejects a forbidden call in a guard expression"
   - "rejects a forbidden call in a default-argument expression"
   - "rejects a forbidden call in a bodiless default head"
   - "rejects function clauses with rescue blocks"
8. Add these tests:
   - "compiles a defp that calls a module outside the allowlist": the
     `Transform300` source from the deleted defp test now returns
     `{:ok, Transform300}` and the module is loaded.
   - "compiles a def with a rescue clause": the `Transform307` source from the
     deleted rescue test returns `{:ok, Transform307}`; calling the function
     with input that raises returns the rescue value.
   - "compiles dot access on a variable bound in the body":
     ```elixir
     defmodule Transform309 do
       def request(resp, _m), do: model_output(resp)
       defp model_output(resp) do
         case resp do
           %{"model" => r} -> r.propensity_score
           _ -> nil
         end
       end
     end
     ```
     returns `{:ok, Transform309}` and
     `Transform309.request(%{"model" => %{propensity_score: 0.4}}, nil) == 0.4`.
9. Keep unchanged: "compiles a valid module and loads it without running it",
   "returns the module name exactly as written in the source", "accepts safe
   multi-clause, guarded and default-argument definitions", the stray-`end`
   parse test, and the top-level-code structure test. They must still pass.
10. Confirm the `eval/5` tests are untouched and green.

## Done when

- `mix test` green.
- `mix compile --warnings-as-errors` clean (the deleted private functions must
  leave no unused-function warnings behind).
- `grep -n validate_all_functions lib test` returns nothing.
- `MiniElixir.compile/1` on the three sources in step 8 returns `{:ok, _}`.
- One commit, message along the lines of "Stop validating function clauses in
  compile/1; check module shape only". Then push to `fork` and open the PR
  against `jowi-dev/mini_elixir` `main` with the "Why" section above as the
  body.

## Out of scope

- Teaching the validator about body-bound variables or widening the module
  allowlist. Not needed once `compile/1` stops calling it.
- Any change to `eval/5`.
- Axiom's side: once this merges, bump the `mini_elixir` lock in axiom's
  `AX-840-transform-compiler` branch to the new merge SHA and rerun the
  transform compile survey (`/tmp/ax840-compile-survey.exs` in that worktree)
  until the only failures are genuine compile errors.
