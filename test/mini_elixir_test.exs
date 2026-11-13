defmodule MiniElixirTest do
  use ExUnit.Case
  doctest MiniElixir

  describe "eval/4" do
    test "successfully evaluates a simple math function" do
      code = ~S"""
      defmodule Calculator do
        def add_tax(price) do
          tax = price * 0.2
          %{price: price, tax: tax, total: price + tax}
        end
      end
      """

      assert {:ok, result} = MiniElixir.eval(code, Calculator, :add_tax, [100.0])
      assert result == %{price: 100.0, tax: 20.0, total: 120.0}
    end

    test "successfully evaluates a recursive function" do
      code = ~S"""
      defmodule Math do
        def fibonacci(n) do
          case n do
            0 -> 0
            1 -> 1
            n -> fibonacci(n-1) + fibonacci(n-2)
          end
        end
      end
      """

      assert {:ok, 55} = MiniElixir.eval(code, Math, :fibonacci, [10])
    end

    test "successfully evaluates a string processing function" do
      code = ~S"""
      defmodule NameFormatter do
        def format_name(first, last) do
          String.trim("#{String.capitalize(first)} #{String.capitalize(last)}")
        end
      end
      """

      assert {:ok, "John Doe"} =
               MiniElixir.eval(code, NameFormatter, :format_name, ["john", "doe"])
    end

    test "handles complex data structures" do
      code = ~S"""
      defmodule ListProcessor do
        def process_list(items) do
          items
          |> Enum.map(&String.upcase/1)
          |> Enum.sort()
          |> Enum.with_index(1)
          |> Map.new(fn {item, idx} -> {idx, item} end)
        end
      end
      """

      assert {:ok, result} =
               MiniElixir.eval(code, ListProcessor, :process_list, [["banana", "apple", "cherry"]])

      assert result == %{1 => "APPLE", 2 => "BANANA", 3 => "CHERRY"}
    end

    test "rejects unsafe code" do
      code = ~S"""
      defmodule FileReader do
        def read_file(path) do
          File.read!(path)
        end
      end
      """

      assert {:error, _} = MiniElixir.eval(code, FileReader, :read_file, ["/etc/passwd"])
    end

    test "rejects code with wrong function name" do
      code = ~S"""
      defmodule Math do
        def add(x, y) do
          x + y
        end
      end
      """

      assert {:error, _} = MiniElixir.eval(code, Math, :sum, [1, 2])
    end

    test "rejects code with wrong arity" do
      code = ~S"""
      defmodule Greeter do
        def greet(name) do
          "Hello #{name}!"
        end
      end
      """

      assert {:error, _} = MiniElixir.eval(code, Greeter, :greet, ["John", "extra"])
    end

    test "rejects code trying to define modules" do
      code = ~S"""
      defmodule Evil do
        def evil(x) do
          defmodule Evil do
            def hack, do: System.cmd("rm", ["-rf", "/"])
          end
          x
        end
      end
      """

      assert {:error, _} = MiniElixir.eval(code, Evil, :evil, [1])
    end

    test "handles errors in user code" do
      code = ~S"""
      defmodule Math do
        def divide(a, b) do
          a / b  # This will raise an error if b is 0
        end
      end
      """

      assert {:error, message} = MiniElixir.eval(code, Math, :divide, [1, 0])
      assert is_binary(message)
    end

    test "allows using whitelisted modules" do
      code = ~S"""
      defmodule TextProcessor do
        def process_data(text) do
          %{
            "encoded" => Base.encode64(text),
            "length" => String.length(text),
            "words" => length(String.split(text)),
            "url_safe" => URI.encode(text)
          }
        end
      end
      """

      assert {:ok, result} = MiniElixir.eval(code, TextProcessor, :process_data, ["Hello World!"])
      assert is_binary(result["encoded"])
      assert result["length"] == 12
      assert result["words"] == 2
      assert is_binary(result["url_safe"])
    end

    test "prevents assigning to function arguments" do
      code = ~S"""
      defmodule Math do
        def increment(x) do
          x = x + 1  # This is not allowed
          x
        end
      end
      """

      assert {:error, _} = MiniElixir.eval(code, Math, :increment, [1])
    end

    test "prevents creating atoms from strings" do
      code = ~S"""
      defmodule Converter do
        def to_atom(str) do
          String.to_atom(str)
        end
      end
      """

      assert {:error, _} = MiniElixir.eval(code, Converter, :to_atom, ["dangerous"])
    end

    test "handles nested modules that override built-in modules" do
      code = ~S"""
      defmodule NameFormatterNested do
        defmodule String do
          def capitalize(a) do
            Code.eval_string(a, [])
          end
        end

        def format_name(first) do
          String.capitalize(first)
        end
      end
      """

      # Now this should be properly rejected due to nested module validation
      assert {:error, message} =
               MiniElixir.eval(code, NameFormatterNested, :format_name, ["john"])

      assert message =~ "Nested modules are not allowed"
    end

    test "handles module aliases" do
      code = ~S"""
      defmodule NameFormatterAlias do
        alias String, as: MyString

        def format_name(first) do
          MyString.capitalize(first)
        end
      end
      """

      # Now this should be properly rejected due to alias validation
      assert {:error, message} = MiniElixir.eval(code, NameFormatterAlias, :format_name, ["john"])
      assert message =~ "Module aliases are not allowed"
    end

    test "handles modules with immediate execution" do
      code = ~S"""
      defmodule NameFormatterIO do
        defmodule MyMod do
          IO.inspect("modules are tricky")
        end

        def format_name(first) do
          String.capitalize(first)
        end
      end
      """

      # Now this should be properly rejected due to nested module validation
      assert {:error, message} = MiniElixir.eval(code, NameFormatterIO, :format_name, ["john"])
      assert message =~ "Nested modules are not allowed"
    end

    test "prevents immediate code execution in modules" do
      code = ~S"""
      defmodule ImmediateExecution do
        IO.puts("This should not execute!")

        def safe_function(x) do
          x + 1
        end
      end
      """

      # This should be rejected due to immediate execution validation
      assert {:error, message} = MiniElixir.eval(code, ImmediateExecution, :safe_function, [1])
      assert message =~ "Immediate code execution in modules is not allowed"
    end
  end

  describe "compile/1" do
    setup do
      previous = Application.get_env(:mini_elixir, :allowed_modules)
      Application.delete_env(:mini_elixir, :allowed_modules)

      on_exit(fn ->
        if previous do
          Application.put_env(:mini_elixir, :allowed_modules, previous)
        else
          Application.delete_env(:mini_elixir, :allowed_modules)
        end
      end)

      :ok
    end

    @valid_transform ~S"""
    defmodule Transform199.Transformer do
      @moduledoc "Adds a tag"
      @doc "Request handler"
      @spec request(map(), term()) :: map()
      def request(record, metadata) do
        tag(record, metadata)
      end

      def version, do: 1

      defp tag(record, nil), do: Map.put(record, "tag", "none")
      defp tag(record, metadata) when is_binary(metadata), do: Map.put(record, "tag", metadata)
      defp tag(record, _metadata), do: record
    end
    """

    test "compiles a valid module and loads it without running it" do
      assert {:ok, Transform199.Transformer} = MiniElixir.compile(@valid_transform)
      assert Code.ensure_loaded?(Transform199.Transformer)

      functions = Transform199.Transformer.__info__(:functions)
      assert {:request, 2} in functions
      assert {:version, 0} in functions
      refute {:tag, 2} in functions

      assert apply(Transform199.Transformer, :request, [%{"a" => 1}, "x"]) ==
               %{"a" => 1, "tag" => "x"}

      assert apply(Transform199.Transformer, :request, [%{}, nil]) == %{"tag" => "none"}
    end

    test "returns the module name exactly as written in the source" do
      code = ~S"""
      defmodule Some.Deeply.Nested.Name do
        def request(record, _metadata), do: record
      end
      """

      assert {:ok, Some.Deeply.Nested.Name} = MiniElixir.compile(code)
      assert Code.ensure_loaded?(Some.Deeply.Nested.Name)
    end

    test "compiles a defp that calls a module outside the allowlist" do
      code = ~S"""
      defmodule Transform300 do
        def request(path, _metadata), do: read(path)
        defp read(path), do: File.read!(path)
      end
      """

      assert {:ok, Transform300} = MiniElixir.compile(code)
      assert Code.ensure_loaded?(Transform300)
    end

    test "compiles a def with a rescue clause" do
      code = ~S"""
      defmodule Transform307 do
        def request(record, _metadata) do
          Map.fetch!(record, "key")
        rescue
          _ -> :rescued
        end
      end
      """

      assert {:ok, Transform307} = MiniElixir.compile(code)
      assert Transform307.request(%{"key" => 1}, nil) == 1
      assert Transform307.request(%{}, nil) == :rescued
    end

    test "compiles dot access on a variable bound in the body" do
      code = ~S"""
      defmodule Transform319 do
        def request(resp, _m), do: model_output(resp)

        defp model_output(resp) do
          case resp do
            %{"model" => r} -> r.propensity_score
            _ -> nil
          end
        end
      end
      """

      assert {:ok, Transform319} = MiniElixir.compile(code)
      assert Transform319.request(%{"model" => %{propensity_score: 0.4}}, nil) == 0.4
      assert Transform319.request(%{}, nil) == nil
    end

    test "accepts safe multi-clause, guarded and default-argument definitions" do
      code = ~S"""
      defmodule Transform306 do
        def request(record, metadata \\ "default")
        def request(record, nil), do: record
        def request(record, metadata) when is_binary(metadata), do: Map.put(record, "m", metadata)
        def request(record, _metadata), do: record
      end
      """

      assert {:ok, Transform306} = MiniElixir.compile(code)
      assert Transform306.request(%{}) == %{"m" => "default"}
      assert Transform306.request(%{}, nil) == %{}
      assert Transform306.request(%{}, 7) == %{}
    end

    test "stray end followed by top-level code fails at parse and defines no module" do
      code = ~S"""
      defmodule Transform308 do
        def request(record, _metadata), do: record
      end
      end
      IO.puts("escaped")
      """

      assert {:error, message} = MiniElixir.compile(code)
      assert message =~ ~r/^Line \d+: /
      refute Code.ensure_loaded?(Transform308)
    end

    test "top-level code after the module fails the structure check" do
      code = ~S"""
      defmodule Transform309 do
        def request(record, _metadata), do: record
      end

      IO.puts("escaped")
      """

      assert {:error, "Expected exactly one module definition"} = MiniElixir.compile(code)
      refute Code.ensure_loaded?(Transform309)
    end

    test "two modules in one source are rejected" do
      code = ~S"""
      defmodule Transform310 do
        def request(record, _metadata), do: record
      end

      defmodule Transform310Other do
        def go, do: System.cmd("rm", ["-rf", "/"])
      end
      """

      assert {:error, "Expected exactly one module definition"} = MiniElixir.compile(code)
      refute Code.ensure_loaded?(Transform310)
      refute Code.ensure_loaded?(Transform310Other)
    end

    test "source without a module is rejected" do
      assert {:error, "Expected a module definition"} = MiniElixir.compile("1 + 1")
      assert {:error, "Expected a module definition"} = MiniElixir.compile(~s|IO.puts("hi")|)
    end

    test "nested modules, import, require, use and bare expressions are rejected" do
      for {snippet, expected} <- [
            {"defmodule Inner do\n end", "Nested modules are not allowed"},
            {"import Enum", "Module imports are not allowed"},
            {"require Logger", "Module requires are not allowed"},
            {"use GenServer", "Module use is not allowed"},
            {~s|IO.puts("hi")|, "Immediate code execution in modules is not allowed"}
          ] do
        code = """
        defmodule Transform311 do
          #{snippet}
          def request(record, _metadata), do: record
        end
        """

        assert {:error, ^expected} = MiniElixir.compile(code)
        refute Code.ensure_loaded?(Transform311)
      end
    end

    test "recompiling the same module name replaces it" do
      v1 = ~S"""
      defmodule Transform318 do
        def version, do: 1
      end
      """

      v2 = ~S"""
      defmodule Transform318 do
        def version, do: 2
      end
      """

      assert {:ok, Transform318} = MiniElixir.compile(v1)
      assert Transform318.version() == 1
      assert {:ok, Transform318} = MiniElixir.compile(v2)
      assert Transform318.version() == 2
    end
  end

  describe "allowed_modules configuration" do
    setup do
      # Clean up any previous config
      previous = Application.get_env(:mini_elixir, :allowed_modules)
      Application.delete_env(:mini_elixir, :allowed_modules)

      on_exit(fn ->
        if previous do
          Application.put_env(:mini_elixir, :allowed_modules, previous)
        else
          Application.delete_env(:mini_elixir, :allowed_modules)
        end
      end)

      :ok
    end

    test "multi-part module calls are rejected by default" do
      code = ~S"""
      defmodule RejectedMultiPart do
        def run(price) do
          MyApp.Helpers.format(price)
        end
      end
      """

      assert {:error, message} =
               MiniElixir.eval(code, RejectedMultiPart, :run, [100.0], persistent: false)

      assert message =~ "Forbidden function"
      assert message =~ "MyApp.Helpers"
    end

    test "configured modules are allowed" do
      defmodule AllowedHelper do
        def double(x), do: x * 2
      end

      Application.put_env(:mini_elixir, :allowed_modules, [AllowedHelper])

      code = ~S"""
      defmodule AllowedModuleTest do
        def run(price) do
          MiniElixirTest.AllowedHelper.double(price)
        end
      end
      """

      assert {:ok, 200.0} =
               MiniElixir.eval(code, AllowedModuleTest, :run, [100.0], persistent: false)
    end

    test "unconfigured multi-part modules are still rejected when others are allowed" do
      defmodule SafeHelper do
        def safe(_x), do: :ok
      end

      Application.put_env(:mini_elixir, :allowed_modules, [SafeHelper])

      code = ~S"""
      defmodule StillRejectedModule do
        def run(price) do
          SomeOther.Module.evil(price)
        end
      end
      """

      assert {:error, message} =
               MiniElixir.eval(code, StillRejectedModule, :run, [100.0], persistent: false)

      assert message =~ "Forbidden function"
    end

    test "existing single-element whitelist modules still work" do
      # String, Enum, Map etc. should still work regardless of allowed_modules config
      Application.put_env(:mini_elixir, :allowed_modules, [])

      code = ~S"""
      defmodule WhitelistStillWorks do
        def run(price) do
          String.upcase(to_string(price))
        end
      end
      """

      assert {:ok, "100.0"} =
               MiniElixir.eval(code, WhitelistStillWorks, :run, [100.0], persistent: false)
    end

    test "bare module entries do not permit aliasing" do
      defmodule BareHelper do
        def double(x), do: x * 2
      end

      Application.put_env(:mini_elixir, :allowed_modules, [BareHelper])

      code = ~S"""
      defmodule BareAliasRejected do
        alias MiniElixirTest.BareHelper, as: Helper

        def run(price) do
          Helper.double(price)
        end
      end
      """

      assert {:error, message} =
               MiniElixir.eval(code, BareAliasRejected, :run, [100.0], persistent: false)

      assert message =~ "Module aliases are not allowed"
    end

    test "configured aliases are allowed and usable" do
      defmodule AliasableHelper do
        def double(x), do: x * 2
      end

      Application.put_env(:mini_elixir, :allowed_modules, [
        {MiniElixirTest.AliasableHelper, as: Helper}
      ])

      code = ~S"""
      defmodule ConfiguredAliasTest do
        alias MiniElixirTest.AliasableHelper, as: Helper

        def run(price) do
          Helper.double(price)
        end
      end
      """

      assert {:ok, 200.0} =
               MiniElixir.eval(code, ConfiguredAliasTest, :run, [100.0], persistent: false)
    end

    test "aliasing with a different name than configured is rejected" do
      defmodule MismatchHelper do
        def double(x), do: x * 2
      end

      Application.put_env(:mini_elixir, :allowed_modules, [
        {MiniElixirTest.MismatchHelper, as: Helper}
      ])

      code = ~S"""
      defmodule MismatchAliasTest do
        alias MiniElixirTest.MismatchHelper, as: SomethingElse

        def run(price) do
          SomethingElse.double(price)
        end
      end
      """

      assert {:error, message} =
               MiniElixir.eval(code, MismatchAliasTest, :run, [100.0], persistent: false)

      assert message =~ "Module aliases are not allowed"
    end

    test "configured aliases also allow direct calls to the source module" do
      defmodule DirectCallHelper do
        def double(x), do: x * 2
      end

      Application.put_env(:mini_elixir, :allowed_modules, [
        {MiniElixirTest.DirectCallHelper, as: Helper}
      ])

      code = ~S"""
      defmodule DirectCallTest do
        def run(price) do
          MiniElixirTest.DirectCallHelper.double(price)
        end
      end
      """

      assert {:ok, 200.0} =
               MiniElixir.eval(code, DirectCallTest, :run, [100.0], persistent: false)
    end
  end
end
