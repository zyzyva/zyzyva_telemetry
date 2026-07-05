# .credo.exs
#
# Template — copy to a repo root as .credo.exs (see practices/README.md).
# Credo configuration tuned to enforce the swarm Elixir style guide.
# Run with:  mix credo --strict   (or the `mix check` alias)
#
# Only the checks that map onto a *deterministic* guide rule are annotated below.
# Semantic rules (good naming quality, "why not what" comments, single
# responsibility) are NOT enforceable here and live in CLAUDE.md instead.

%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "src/", "test/", "config/", "credo_checks/"],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/"]
      },
      plugins: [],
      requires: [
        # Load the custom check(s) shipped with this repo. They live OUTSIDE
        # lib/ on purpose: mix must never compile them (credo is a dev/test
        # dep, and a lib/ copy would be loaded twice — once by this `requires`
        # and once by `mix compile` — tripping warnings-as-errors).
        "./credo_checks/max_scope_bindings.ex"
      ],
      strict: true,
      parse_timeout: 5000,
      color: true,
      checks: %{
        enabled: [
          #
          # ---- Custom check: ~5-6 live bindings per scope --------------------
          # Guide rule: "No scope over ~5-6 live bindings (pipe chains exempt)".
          # Not built into Credo; implemented in this repo. Warns at 7+.
          {CredoChecks.MaxScopeBindings, max_bindings: 6},

          #
          # ---- Docs & specs --------------------------------------------------
          # Guide rule: every module has @moduledoc; public functions have @spec.
          {Credo.Check.Readability.ModuleDoc, []},
          {Credo.Check.Readability.Specs, []},

          #
          # ---- Naming --------------------------------------------------------
          # Guide rule: snake_case names, predicate ?/! conventions.
          # (Enforces *format*, not "use full words" — that stays semantic.)
          {Credo.Check.Readability.VariableNames, []},
          {Credo.Check.Readability.FunctionNames, []},
          {Credo.Check.Readability.ModuleNames, []},
          {Credo.Check.Readability.PredicateFunctionNames, []},

          #
          # ---- Function size / complexity ------------------------------------
          # Guide rule: "keep functions small; fewer paths through a function".
          # Cyclomatic complexity is a better proxy than raw line count and it
          # naturally exempts long-but-linear pipe chains (low branching).
          {Credo.Check.Refactor.CyclomaticComplexity, max_complexity: 9},
          {Credo.Check.Refactor.Nesting, max_nesting: 2},
          {Credo.Check.Refactor.FunctionArity, max_arity: 6},

          #
          # ---- Control-flow idioms -------------------------------------------
          # Guide rules: no redundant `with else`, prefer case over cond on a
          # single value, no unless/else, no negated conditions, etc.
          {Credo.Check.Refactor.WithClauses, []},
          {Credo.Check.Refactor.RedundantWithClauseResult, []},
          {Credo.Check.Refactor.CondStatements, []},
          {Credo.Check.Refactor.UnlessWithElse, []},
          {Credo.Check.Refactor.NegatedConditionsInUnless, []},
          {Credo.Check.Refactor.NegatedConditionsWithElse, []},

          #
          # ---- Pipe hygiene --------------------------------------------------
          # Guide rule: pipes for linear transforms, not wrapping a single call.
          {Credo.Check.Readability.SinglePipe, []},
          {Credo.Check.Readability.PipeIntoAnonymousFunctions, []},
          {Credo.Check.Refactor.PipeChainStart, []},

          #
          # ---- General readability / correctness safety net -------------------
          {Credo.Check.Readability.MaxLineLength, max_length: 98},
          {Credo.Check.Readability.TrailingWhiteSpace, []},
          {Credo.Check.Readability.TrailingBlankLine, []},
          {Credo.Check.Readability.RedundantBlankLines, []},
          {Credo.Check.Readability.SpaceAfterCommas, []},
          {Credo.Check.Readability.LargeNumbers, []},
          {Credo.Check.Readability.ParenthesesOnZeroArityDefs, []},
          {Credo.Check.Warning.IExPry, []},
          {Credo.Check.Warning.IoInspect, []},
          {Credo.Check.Warning.Dbg, []},
          {Credo.Check.Warning.UnusedEnumOperation, []},
          {Credo.Check.Warning.UnusedKeywordOperation, []},
          {Credo.Check.Warning.UnusedListOperation, []},
          {Credo.Check.Warning.UnusedStringOperation, []},
          {Credo.Check.Warning.UnusedTupleOperation, []},
          {Credo.Check.Warning.OperationOnSameValues, []},
          {Credo.Check.Warning.OperationWithConstantResult, []},
          {Credo.Check.Warning.RaiseInsideRescue, []},
          {Credo.Check.Design.AliasUsage, [if_nested_deeper_than: 2]}
        ],
        disabled: [
          # TODO/FIXME as build failures is usually too aggressive during
          # active development. Re-enable if you want a clean-tree policy.
          {Credo.Check.Design.TagTODO, []},
          {Credo.Check.Design.TagFIXME, []}
        ]
      }
    }
  ]
}
