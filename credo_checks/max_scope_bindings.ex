defmodule CredoChecks.MaxScopeBindings do
  @moduledoc """
  Flags function bodies that introduce more than `:max_bindings` distinct
  local bindings (parameters plus variables bound in the body).

  This enforces a working-memory rule: a scope with too many live
  variables is hard to reason about, for a human and for an LLM alike.
  When you hit the limit, the fix is to extract a small named helper, not
  to add a seventh variable.

  The module is deliberately NOT namespaced under an app: it is loaded by
  credo's `requires` from `credo_checks/` at the project root and never
  compiled into the application, so the same file can be dropped into any
  project unchanged.

  ## Configuration

      {CredoChecks.MaxScopeBindings, max_bindings: 6}

  ## What counts

  Parameters and variables introduced via `=` (and `<-` inside `with`)
  are counted. `_`-prefixed variables are ignored, as are things that
  parse as variables but bind nothing: binary-segment types and modifiers
  (`<<n::little-32, rest::binary>>` binds `n` and `rest`, not `little` or
  `binary`) and default-argument values (`arg \\\\ @default` binds `arg`,
  not `default`). The count is a *sum over the function clause*, not a
  point-in-time live set, so it is a deliberately conservative proxy: it
  over-counts rebinding but is cheap and stable. Treat a flag as "look at
  this function", not a hard error.

  This is intentionally approximate. It is a nudge, not a type checker.
  """

  # `explanations` and `params` shape follows the Credo.Check behaviour.
  use Credo.Check,
    base_priority: :low,
    category: :refactor,
    param_defaults: [max_bindings: 6],
    explanations: [
      check: """
      Functions with many local bindings are harder to hold in working
      memory. Prefer extracting a named helper over adding another variable.
      """,
      params: [
        max_bindings: "The maximum number of distinct bindings allowed per function clause."
      ]
    ]

  @doc false
  @spec run(Credo.SourceFile.t(), keyword) :: [Credo.Issue.t()]
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    max_bindings = Params.get(params, :max_bindings, __MODULE__)

    Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta, max_bindings), [])
  end

  # Match public and private function definitions with a body.
  defp traverse({op, _meta, [_head, _body]} = ast, issues, issue_meta, max_bindings)
       when op in [:def, :defp] do
    {ast, check_clause(ast, issues, issue_meta, max_bindings)}
  end

  defp traverse(ast, issues, _issue_meta, _max), do: {ast, issues}

  defp check_clause({_op, meta, [head, body]}, issues, issue_meta, max_bindings) do
    case count_bindings(head, body) do
      count when count > max_bindings ->
        [issue_for(issue_meta, meta[:line], name_of(head), count, max_bindings) | issues]

      _ ->
        issues
    end
  end

  # Count parameter names in the head, plus variables bound by `=` / `<-`
  # anywhere in the body. Dedupe by name; ignore underscore-prefixed vars.
  defp count_bindings(head, body) do
    param_vars = collect_param_vars(head)
    body_vars = collect_bound_vars(body)

    (param_vars ++ body_vars)
    |> Enum.reject(&underscored?/1)
    |> Enum.uniq()
    |> length()
  end

  # A guarded head (`def f(...) when ...`) wraps the real head in `:when`;
  # unwrap it so guard variables (uses, not bindings) are not counted.
  defp collect_param_vars({:when, _meta, [head | _guard]}), do: collect_param_vars(head)

  defp collect_param_vars({_name, _meta, args}) when is_list(args) do
    Enum.flat_map(args, &vars_in_pattern/1)
  end

  defp collect_param_vars(_), do: []

  # Walk any AST fragment collecting variable names bound in patterns,
  # i.e. the left side of `=` and the left side of `<-` in `with`/`for`.
  defp collect_bound_vars(ast) do
    {_ast, vars} =
      Macro.prewalk(ast, [], fn
        {:=, _meta, [lhs, _rhs]} = node, acc -> {node, vars_in_pattern(lhs) ++ acc}
        {:<-, _meta, [lhs, _rhs]} = node, acc -> {node, vars_in_pattern(lhs) ++ acc}
        node, acc -> {node, acc}
      end)

    vars
  end

  # Extract bound variable names from a pattern (handles tuples, lists,
  # maps, and plain vars). Pin (`^`) and calls are not bindings.
  defp vars_in_pattern(pattern) do
    {_ast, vars} =
      Macro.prewalk(pattern, [], fn
        {:^, _meta, _}, acc ->
          {nil, acc}

        # Binary segment: `value::type-modifiers`. Only the left side binds.
        # The right side names types and modifiers (`binary`, `little`,
        # `signed`, `size(n)`, ...) which parse as var nodes but bind
        # nothing — counting them made every binary-parsing function look
        # 1-2 bindings heavier than it is, with no refactor able to remove
        # them.
        {:"::", _meta, [lhs, _type]}, acc ->
          {nil, vars_in_pattern(lhs) ++ acc}

        # Default argument: `arg \\ @default`. Only `arg` binds; the
        # default value is an expression (often a module attribute, which
        # also parses as a var node).
        {:\\, _meta, [lhs, _default]}, acc ->
          {nil, vars_in_pattern(lhs) ++ acc}

        {name, _meta, context} = node, acc when is_atom(name) and is_atom(context) ->
          {node, [name | acc]}

        node, acc ->
          {node, acc}
      end)

    vars
  end

  defp underscored?(name) do
    name |> Atom.to_string() |> String.starts_with?("_")
  end

  defp name_of({:when, _meta, [head | _guard]}), do: name_of(head)
  defp name_of({name, _meta, _args}) when is_atom(name), do: name
  defp name_of(_), do: :unknown

  defp issue_for(issue_meta, line, fun_name, count, max) do
    format_issue(
      issue_meta,
      message:
        "Function #{fun_name}/? binds #{count} variables (limit #{max}). " <>
          "Consider extracting a helper.",
      line_no: line,
      trigger: to_string(fun_name)
    )
  end
end
