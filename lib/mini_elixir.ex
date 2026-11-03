defmodule MiniElixir do
  @moduledoc """
  MiniElixir provides a safe sandbox for evaluating Elixir code with restricted functionality.
  It allows users to write and execute Elixir code in a controlled environment where only
  whitelisted functions and operators are available.

  ## Features

  - Safe evaluation of Elixir code strings
  - Restricted access to only whitelisted functions and operators
  - Protection against dangerous operations
  - Support for any module and function name
  - Compile-only mode (`compile/2`) that validates and loads a module without running it

  ## Example

      iex> code = \"\"\"
      ...> defmodule TextProcessor do
      ...>   def sort_words(text) do
      ...>     text
      ...>     |> String.split()
      ...>     |> Enum.sort()
      ...>   end
      ...> end
      ...> \"\"\"
      iex> {:ok, result} = MiniElixir.eval(code, TextProcessor, :sort_words, ["banana apple cherry"])
      iex> result
      ["apple", "banana", "cherry"]
  """

  alias MiniElixir.Validator

  @allowed_attributes [:doc, :moduledoc, :spec, :type, :typedoc]
  @default_inner Transformer

  @doc """
  Evaluates a string of Elixir code in a safe sandbox environment.

  ## Parameters

  - `code`: String containing the Elixir code to evaluate
  - `module`: The module name to define the function in
  - `function`: The name of the function to define and call
  - `args`: List of arguments to pass to the function

  ## Returns

  - `{:ok, result}` on success
  - `{:error, reason}` on failure

  ## Examples

      iex> code = \"\"\"
      ...> defmodule Calculator do
      ...>   def add_tax(price) do
      ...>     tax = price * 0.2
      ...>     %{price: price, tax: tax, total: price + tax}
      ...>   end
      ...> end
      ...> \"\"\"
      iex> MiniElixir.eval(code, Calculator, :add_tax, [100.0])
      {:ok, %{price: 100.0, tax: 20.0, total: 120.0}}

      iex> code = \"\"\"
      ...> defmodule NameFormatter do
      ...>   def format_name(first, last) do
      ...>     first_cap = String.capitalize(first)
      ...>     last_cap = String.capitalize(last)
      ...>     String.trim(first_cap <> " " <> last_cap)
      ...>   end
      ...> end
      ...> \"\"\"
      iex> MiniElixir.eval(code, NameFormatter, :format_name, ["john", "doe"])
      {:ok, "John Doe"}
  """
  def eval(code, module, function, args, opts \\ [])
      when is_atom(module) and is_atom(function) and is_list(args) and is_list(opts) do
    persistent? = Keyword.get(opts, :persistent, true)
    arity = length(args)

    if persistent? and module_loaded?(module) and function_exported?(module, function, arity) do
      try do
        result = apply(module, function, args)
        {:ok, result}
      rescue
        e -> {:error, Exception.message(e)}
      end
    else
      with {:ok, ast} <- parse(code),
           :ok <- validate_module_name(ast, module),
           :ok <- validate_module_structure(ast),
           :ok <- validate_all_functions(ast),
           :ok <- ensure_function_defined(ast, function, arity) do
        try do
          # only compile and execute after validation
          Code.compiler_options(ignore_module_conflict: true)
          Code.eval_quoted(ast)
          result = apply(module, function, args)
          {:ok, result}
        rescue
          e ->
            {:error, Exception.message(e)}
        after
          Code.compiler_options(ignore_module_conflict: false)

          if not persistent? do
            :code.purge(module)
            :code.delete(module)
          end
        end
      else
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Validates and compiles a string of Elixir code without executing any of it.

  The source must contain exactly one top-level `defmodule`. Every `def` and
  `defp` clause in it is validated with the same rules `eval/5` applies, and
  then the module is compiled under a caller-chosen name: the source module is
  renamed to `inner:` and nested inside `as:`, so the resulting module is
  `Module.concat(as, inner)`. Nothing is applied; the caller runs the compiled
  functions later with `apply/3`.

  ## Options

  - `:as` (required): the outer module atom, e.g. `Transform199`
  - `:inner` (optional, default `Transformer`): the inner module name

  ## Returns

  - `{:ok, module}` where `module` is `Module.concat(as, inner)`
  - `{:error, reason}` with the same string shapes `eval/5` produces

  ## Examples

      iex> code = \"\"\"
      ...> defmodule Transform do
      ...>   def request(record, _metadata) do
      ...>     Map.put(record, "seen", true)
      ...>   end
      ...> end
      ...> \"\"\"
      iex> MiniElixir.compile(code, as: TransformDoc)
      {:ok, TransformDoc.Transformer}
      iex> TransformDoc.Transformer.request(%{}, nil)
      %{"seen" => true}
  """
  def compile(code, opts) when is_binary(code) and is_list(opts) do
    with {:ok, outer} <- fetch_module_opt(opts, :as, nil),
         {:ok, inner} <- fetch_module_opt(opts, :inner, @default_inner),
         {:ok, ast} <- parse(code),
         :ok <- validate_single_module(ast),
         :ok <- validate_module_structure(ast),
         :ok <- validate_all_functions(ast) do
      wrapper = build_wrapper(outer, rename_module(ast, inner))
      compile_wrapper(wrapper, Module.concat(outer, inner))
    end
  end

  defp compile_wrapper(wrapper, module) do
    try do
      Code.compiler_options(ignore_module_conflict: true)
      Code.compile_quoted(wrapper)
      {:ok, module}
    rescue
      e -> {:error, Exception.message(e)}
    after
      Code.compiler_options(ignore_module_conflict: false)
    end
  end

  # Build `defmodule outer do <inner defmodule> end` as AST. The inner AST is
  # spliced in as a quoted value, never re-parsed from a string.
  defp build_wrapper(outer, inner_ast) do
    quote do
      defmodule unquote(module_alias(outer)) do
        unquote(inner_ast)
      end
    end
  end

  # Replace the source module's name with `inner` so that, once nested in the
  # wrapper, it becomes `outer.inner`. Only the alias node changes.
  defp rename_module({:defmodule, meta, [{:__aliases__, _, _}, body]}, inner) do
    {:defmodule, meta, [module_alias(inner), body]}
  end

  # An `__aliases__` node (not a bare atom) so defmodule applies nesting.
  defp module_alias(module) do
    parts = module |> Module.split() |> Enum.map(&String.to_atom/1)
    {:__aliases__, [alias: false], parts}
  end

  defp fetch_module_opt(opts, key, default) do
    case Keyword.get(opts, key, default) do
      nil ->
        {:error, "Option #{inspect(key)} is required"}

      module when is_atom(module) ->
        if elixir_module_atom?(module) do
          {:ok, module}
        else
          {:error,
           "Option #{inspect(key)} must be an Elixir module atom, got: #{inspect(module)}"}
        end

      other ->
        {:error, "Option #{inspect(key)} must be an Elixir module atom, got: #{inspect(other)}"}
    end
  end

  defp elixir_module_atom?(module) do
    String.starts_with?(Atom.to_string(module), "Elixir.")
  end

  defp parse(code) do
    case Code.string_to_quoted(code) do
      {:ok, ast} -> {:ok, ast}
      {:error, {meta, message, token}} -> {:error, format_parse_error(meta, message, token)}
    end
  end

  defp format_parse_error(meta, message, token) do
    line = if is_list(meta), do: Keyword.get(meta, :line, meta), else: meta

    text =
      case message do
        {prefix, suffix} -> prefix <> to_string(token) <> suffix
        message -> to_string(message) <> to_string(token)
      end

    "Line #{line}: #{text}"
  end

  defp validate_module_name(
         {:defmodule, _, [{:__aliases__, _, module_parts}, _]},
         expected_module
       ) do
    actual_module = Module.concat(module_parts)

    if actual_module == expected_module do
      :ok
    else
      {:error, "Module name mismatch. Expected #{expected_module}, got #{actual_module}"}
    end
  end

  defp validate_module_name(_, _) do
    {:error, "Expected a module definition"}
  end

  defp validate_single_module({:defmodule, _, [{:__aliases__, _, _}, _]}), do: :ok

  defp validate_single_module({:__block__, _, _}) do
    {:error, "Expected exactly one module definition"}
  end

  defp validate_single_module(_), do: {:error, "Expected a module definition"}

  defp validate_module_structure({:defmodule, _, [_, [do: body]]}) do
    validate_module_body(body)
  end

  defp validate_module_structure(_) do
    {:error, "Expected a module definition"}
  end

  defp validate_module_body({:__block__, _, statements}) when is_list(statements) do
    Enum.reduce_while(statements, :ok, fn statement, :ok ->
      case validate_statement(statement) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_module_body(single_statement) do
    validate_statement(single_statement)
  end

  defp validate_statement({:def, _, _}), do: :ok
  defp validate_statement({:defp, _, _}), do: :ok

  defp validate_statement({:defmodule, _, _}) do
    {:error, "Nested modules are not allowed"}
  end

  defp validate_statement({:alias, _, args}) do
    case parse_alias(args) do
      {:ok, source, as_name} ->
        if Validator.allowed_alias?(source, as_name) do
          :ok
        else
          {:error, "Module aliases are not allowed: #{inspect(source)}"}
        end

      :error ->
        {:error, "Module aliases are not allowed"}
    end
  end

  defp validate_statement({:import, _, _}) do
    {:error, "Module imports are not allowed"}
  end

  defp validate_statement({:require, _, _}) do
    {:error, "Module requires are not allowed"}
  end

  defp validate_statement({:use, _, _}) do
    {:error, "Module use is not allowed"}
  end

  defp validate_statement({:@, _, [{name, _, args}]}) when is_atom(name) do
    validate_attribute(name, args)
  end

  defp validate_statement(_expr) do
    {:error, "Immediate code execution in modules is not allowed"}
  end

  # Attribute values are evaluated at compile time, so both the attribute name
  # and its value are restricted. Doc attributes must be literals; typespecs
  # must not contain unquote fragments (the only way to run code inside them).
  defp validate_attribute(name, [value]) when name in [:doc, :moduledoc, :typedoc] do
    if Macro.quoted_literal?(value) do
      :ok
    else
      {:error, "Module attribute @#{name} must be a literal value"}
    end
  end

  defp validate_attribute(name, [value]) when name in [:spec, :type] do
    if contains_unquote?(value) do
      {:error, "Module attribute @#{name} must not contain unquote"}
    else
      :ok
    end
  end

  defp validate_attribute(name, _args) when name in @allowed_attributes do
    {:error, "Module attribute @#{name} must be given a single value"}
  end

  defp validate_attribute(name, _args) do
    allowed = Enum.map_join(@allowed_attributes, ", ", &"@#{&1}")
    {:error, "Module attribute @#{name} is not allowed (allowed: #{allowed})"}
  end

  defp contains_unquote?(ast) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {op, _, _} = node, _ when op in [:unquote, :unquote_splicing] -> {node, true}
        node, acc -> {node, acc}
      end)

    found?
  end

  # Extract the source module and effective alias name from an `alias` AST.
  # `alias Foo.Bar` defaults the alias name to the last segment (`Bar`).
  defp parse_alias([{:__aliases__, _, parts}]) when is_list(parts) do
    {:ok, Module.concat(parts), Module.concat([List.last(parts)])}
  end

  defp parse_alias([{:__aliases__, _, parts}, opts]) when is_list(parts) and is_list(opts) do
    as_name =
      case Keyword.fetch(opts, :as) do
        {:ok, {:__aliases__, _, as_parts}} -> Module.concat(as_parts)
        _ -> Module.concat([List.last(parts)])
      end

    {:ok, Module.concat(parts), as_name}
  end

  defp parse_alias(_), do: :error

  # Run the validator over every function clause in the module: every `def`
  # and `defp`, including multi-clause heads, `when` guards, default-argument
  # expressions and bodiless heads. Must be called after
  # validate_module_structure/1 so the statement list is already known-good.
  defp validate_all_functions({:defmodule, _, [_, [do: body]]}) do
    body
    |> module_statements()
    |> Enum.filter(&match?({kind, _, _} when kind in [:def, :defp], &1))
    |> Enum.reduce_while(:ok, fn definition, :ok ->
      case validate_function(definition) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp module_statements({:__block__, _, statements}) when is_list(statements), do: statements
  defp module_statements(single), do: [single]

  # Bodiless head, e.g. `def f(a, b \\ 1)` declaring defaults.
  defp validate_function({_kind, _, [head]}) do
    with {:ok, {_name, args, guard}} <- unwrap_head(head) do
      validate_clause(args, guard, nil)
    end
  end

  defp validate_function({_kind, _, [head, [do: body]]}) do
    with {:ok, {_name, args, guard}} <- unwrap_head(head) do
      validate_clause(args, guard, body)
    end
  end

  defp validate_function({_kind, _, [head, body_parts]}) when is_list(body_parts) do
    case unwrap_head(head) do
      {:ok, {name, _, _}} ->
        keys = body_parts |> Keyword.keys() |> Enum.reject(&(&1 == :do))

        {:error,
         "Function #{name} may only have a `do` block, got: #{Enum.map_join(keys, ", ", &inspect/1)}"}

      error ->
        error
    end
  end

  defp validate_function(_), do: {:error, "Unsupported function definition"}

  defp unwrap_head({:when, _, [call, guard]}) do
    with {:ok, {name, args, nil}} <- unwrap_head(call), do: {:ok, {name, args, guard}}
  end

  defp unwrap_head({name, _, args}) when is_atom(name) and is_list(args) do
    {:ok, {name, args, nil}}
  end

  defp unwrap_head({name, _, nil}) when is_atom(name), do: {:ok, {name, [], nil}}
  defp unwrap_head(_), do: {:error, "Unsupported function definition"}

  defp validate_clause(args, guard, body) do
    arg_names = arg_names(args)
    defaults = for {:\\, _, [_pattern, default]} <- args, do: default

    with :ok <- check_each(defaults, arg_names),
         :ok <- check_optional(guard, arg_names) do
      check_optional(body, arg_names)
    end
  end

  defp check_each(asts, arg_names) do
    Enum.reduce_while(asts, :ok, fn ast, :ok ->
      case check_optional(ast, arg_names) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp check_optional(nil, _arg_names), do: :ok

  defp check_optional(ast, arg_names) do
    case Validator.check(ast, arg_names) do
      :ok -> :ok
      {:error, :validator, message} -> {:error, message}
    end
  end

  # Names of top-level variable parameters (what the validator protects from
  # re-binding). Pattern-matched parameters contribute nothing, as before.
  defp arg_names(args) do
    args
    |> Enum.map(fn
      {:\\, _, [pattern, _default]} -> pattern
      pattern -> pattern
    end)
    |> Enum.flat_map(fn
      {name, _, ctx} when is_atom(name) and is_atom(ctx) -> [name]
      _ -> []
    end)
  end

  defp ensure_function_defined({:defmodule, _, [_, [do: body]]}, function, arity) do
    defined? =
      body
      |> module_statements()
      |> Enum.any?(fn
        {:def, _, [head | _]} ->
          case unwrap_head(head) do
            {:ok, {^function, args, _}} -> length(args) == arity
            _ -> false
          end

        _ ->
          false
      end)

    if defined? do
      :ok
    else
      {:error, "Function #{function}/#{arity} not found"}
    end
  end

  defp module_loaded?(module) when is_atom(module) do
    case :code.is_loaded(module) do
      {:file, _} -> true
      _ -> false
    end
  end
end
