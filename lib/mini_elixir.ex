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
  - Compile-only mode (`compile/1`) that checks module shape and loads a module without running it

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
      with {:ok, ast} <- Code.string_to_quoted(code),
           :ok <- validate_module_name(ast, module),
           :ok <- validate_module_structure(ast),
           {:ok, {fun_body, arg_names}} <- unwrap_function(ast, function, length(args)),
           :ok <- Validator.check(fun_body, arg_names) do
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
        {:error, line, reason} -> {:error, "Line #{line}: #{reason}"}
      end
    end
  end

  @doc """
  Checks the shape of a string of Elixir code and compiles it without executing
  any of it.

  The source must contain exactly one top-level `defmodule`. The module's shape
  is checked (one top-level `defmodule`; only `def`, `defp`, module attributes
  and allowlisted `alias` inside; nested modules, `import`, `require`, `use`
  and bare expressions are rejected); function bodies are not validated. Callers that need
  the `eval/5` sandbox on a compiled module can run `MiniElixir.Validator.check/2`
  over the clauses they care about. The module is then compiled and loaded under
  the name the source gives it. Nothing is applied; the caller runs the compiled
  functions later with `apply/3`.

  ## Returns

  - `{:ok, module}` where `module` is the name defined in the source
  - `{:error, reason}` where `reason` is a string

  ## Examples

      iex> code = \"\"\"
      ...> defmodule TransformDoc do
      ...>   def request(record, _metadata) do
      ...>     Map.put(record, "seen", true)
      ...>   end
      ...> end
      ...> \"\"\"
      iex> MiniElixir.compile(code)
      {:ok, TransformDoc}
      iex> TransformDoc.request(%{}, nil)
      %{"seen" => true}
  """
  def compile(code) when is_binary(code) do
    with {:ok, ast} <- parse(code),
         {:ok, module} <- single_module(ast),
         :ok <- validate_module_structure(ast) do
      try do
        Code.compiler_options(ignore_module_conflict: true)
        Code.compile_quoted(ast)
        {:ok, module}
      rescue
        e -> {:error, Exception.message(e)}
      after
        Code.compiler_options(ignore_module_conflict: false)
      end
    end
  end

  defp parse(code) do
    case Code.string_to_quoted(code) do
      {:ok, ast} ->
        {:ok, ast}

      {:error, {meta, message, token}} ->
        line = if is_list(meta), do: Keyword.get(meta, :line), else: meta

        text =
          case message do
            {prefix, suffix} -> prefix <> to_string(token) <> suffix
            message -> to_string(message) <> to_string(token)
          end

        {:error, "Line #{line}: #{text}"}
    end
  end

  defp single_module({:defmodule, _, [{:__aliases__, _, parts}, _]}),
    do: {:ok, Module.concat(parts)}

  defp single_module({:__block__, _, _}), do: {:error, "Expected exactly one module definition"}
  defp single_module(_), do: {:error, "Expected a module definition"}

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

  defp validate_statement(expr) do
    case expr do
      {:@, _, _} -> :ok
      _ -> {:error, "Immediate code execution in modules is not allowed"}
    end
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

  defp unwrap_function(
         {:defmodule, _, [_, [do: {:__block__, _, defs}]]},
         expected_name,
         expected_arity
       ) do
    # handle multiple function definitions
    Enum.find_value(defs, {:error, "Function #{expected_name}/#{expected_arity} not found"}, fn
      {:def, _, [{name, _, args}, [do: body]]} when is_list(args) ->
        if name == expected_name and length(args) == expected_arity do
          arg_names = for {name, _, _} <- args, do: name
          {:ok, {body, arg_names}}
        end

      _ ->
        nil
    end)
  end

  defp unwrap_function(
         {:defmodule, _, [_, [do: {:def, _, [{name, _, args}, [do: body]]}]]},
         expected_name,
         expected_arity
       )
       when is_list(args) do
    cond do
      name != expected_name ->
        {:error, "Expected function name to be #{inspect(expected_name)}, got: #{inspect(name)}"}

      length(args) != expected_arity ->
        {:error, "Expected function arity to be #{expected_arity}, got: #{length(args)}"}

      true ->
        arg_names = for {name, _, _} <- args, do: name
        {:ok, {body, arg_names}}
    end
  end

  defp unwrap_function(_, _, _), do: {:error, "Expected a module with function definition"}

  defp module_loaded?(module) when is_atom(module) do
    case :code.is_loaded(module) do
      {:file, _} -> true
      _ -> false
    end
  end
end
