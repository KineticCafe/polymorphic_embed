defmodule PolymorphicEmbed do
  @moduledoc """
  """

  alias Ecto.Changeset

  require Logger

  @typedoc ~S"""
  Options to describe a single embedded polymorphic schema type.

  Types may be identified by a type field (`"__type__"`) that contains the name of the
  polymorphic type, or by the presence of specific fields.

  A bare `t:module/0` as an option is treated the same as an option list `[module:
  modname]`.

  ### Type Option List

  - `:module` - The module containing the polymorphic schema type.
  - `:identify_by_fields` - Used to specify type resolution by the presence of specific
    fields in cast data. If omitted or empty, types are identified by the type field. If
    a type field value is present in the incoming data, it will be used in preference to
    field identification.

  ### Example

      polymorphic_embeds_one :field, types: [
        name1: module1,
        name2: [module: module2],
        name3: [module: module3, identify_by_fields: [:field1, :field2]]
      ]

  The `embedded_type` values are the values *after* `name1`, `name2`, and `name3` and show
  the various options.

  - `name1` and `name2` are detected in incoming data by looking up data in the type
    field, such as `{"__type__":"name1"}` or `{"__type__":"name2"}`.

  - `name3` will be detected by `{"field1":"anything","field2":"anything"}` or
    `{"__type__":"name3"}`.
  """
  @type embedded_type :: module() | [{:module, module()} | {:identify_by_fields, [atom()]}]

  @typedoc ~S"""
  Options to configure a polymorphic embed.

  ### Required Parameter

  - `:types` - The types supported by this polymorphic embed. This most be or produce
    a keyword list mapping type identifiers to embedded schema modules (see
    `t:embedded_type/0`). If not provided as a literal keyword list, it may be provided as
    one of:

    - `Module.function()` - a qualified function call,
    - `{Module, :function}` - a tuple identifying the same module and function, or
    - `{Module, :function, argslist}` - a `t:mfa/0` tuple.

  ### Optional Parameters

  - `:type_field` – Specifies a custom type field for comparison of names for type
    matching. Defaults to `:__type__`.

  - `:on_type_not_found` – Specifies the behaviour when the embedded type cannot be
    inferred from `:types`. Possible values are:

    - `:changeset_error` - adds a changeset error (default `"is invalid type"`).
    - `:ignore` - ignores unknown types, removing it from the resulting list. Cannot be
      used with `polymorphic_embeds_one/2`.
    - `:nilify` - replaces unknown data with `nil`. Cannot be used with
      `polymorphic_embeds_many/2`.
    - `:raise` - raises an exception when the type is unknown

  - `:default` - sets the default value for the embedded value. This defaults to `nil` for
    `polymorphic_embeds_one/2` and `[]` for `polymorphic_embeds_many/2`. Values other than
    `nil` or `[]` are discouraged.
  """
  @type embed_params ::
          {:types, [{atom(), embedded_type}] | mfa() | {module(), atom()}}
          | {:type_field, atom()}
          | {:on_type_not_found, :changeset_error | :ignore | :nilify | :raise}
          | {:default, term()}

  # defdelegate cast_polymorphic_embed(changeset, field, cast_opts \\ []),
  #   to: PolymorphicEmbed.Changeset

  defdelegate cast_polymorphic_embed(changeset, field, cast_opts \\ []),
    to: PolymorphicEmbed.ChangesetNew

  defdelegate apply_changes(changeset), to: PolymorphicEmbed.ChangesetNew

  @doc ~S"""
  Indicates an embedded polymorphic schema for a field.

  The current schema has zero or one records of the other schema types embedded inside of
  it. It uses a field similar to the `:map` type for storage, but allows embeds to have
  all the things regular schema can.

  You must declare your `polymorphic_embeds_one/2` field with type `:map` at the database
  level.

  See `t:embed_params/0` for available options.
  """
  defmacro polymorphic_embeds_one(field_name, opts) do
    opts =
      opts
      |> Keyword.put(:cardinality, :one)
      |> Keyword.update!(:types, &resolve_types(&1, __CALLER__))
      |> check_options!("polymorphic_embeds_one/2")

    quote do
      Ecto.Schema.__field__(__MODULE__, unquote(field_name), PolymorphicEmbed.Type, unquote(opts))
    end
  end

  @doc ~S"""
  Indicates an embedded list of polymorphic schema for a field.

  The current schema has zero or more records of the other schema types embedded inside of
  it. It uses a field similar to the `:map` type for storage, but allows embeds to have
  all the things regular schema can.

  You must declare your `polymorphic_embeds_one/2` field with type `:map` at the database
  level.

  See `t:embed_params/0` for available options.
  """
  defmacro polymorphic_embeds_many(field_name, opts) do
    opts =
      opts
      |> Keyword.put(:cardinality, :many)
      |> Keyword.put_new(:default, [])
      |> Keyword.update!(:types, &resolve_types(&1, __CALLER__))
      |> check_options!("polymorphic_embeds_many/2")

    quote do
      Ecto.Schema.__field__(
        __MODULE__,
        unquote(field_name),
        {:array, PolymorphicEmbed.Type},
        unquote(opts)
      )
    end
  end

  @valid_options [
    :cardinality,
    :default,
    :nilify_unlisted_types_on_load,
    :on_type_not_found,
    :retain_unlisted_types_on_load,
    :type_field,
    :types
  ]

  @doc ~S"""
  Traverses changeset errors for changesets including polymorphic embeds.

  `Ecto.Changeset.traverse_errors/2` does not correctly include errors found in
  polymorphic embeds.
  """
  def traverse_errors(%Changeset{changes: changes, types: types} = changeset, msg_func)
      when is_function(msg_func, 1) or is_function(msg_func, 3) do
    changeset
    |> Changeset.traverse_errors(msg_func)
    |> merge_polymorphic_keys(changes, types, msg_func)
  end

  # We need to match the case where an invalid changeset has
  # a PolymorphicEmbed.Type field which is valid, then that
  # PolymorphicEmbed.Type field is already converted to a struct and no longer
  # a changeset. Since the said field is converted to a struct there's no
  # errors to check for.
  def traverse_errors(%_{}, msg_func)
      when is_function(msg_func, 1) or is_function(msg_func, 3) do
    %{}
  end

  defp merge_polymorphic_keys(map, changes, types, msg_func) do
    Enum.reduce(types, map, &polymorphic_key_reducer(&1, &2, changes, msg_func))
  end

  defp polymorphic_key_reducer(
         {field, {rel, %{cardinality: :one}}},
         acc,
         changes,
         msg_func
       )
       when rel in [:assoc, :embed] do
    if changeset = Map.get(changes, field) do
      case traverse_errors(changeset, msg_func) do
        errors when errors == %{} -> acc
        errors -> Map.put(acc, field, errors)
      end
    else
      acc
    end
  end

  defp polymorphic_key_reducer(
         {field, {:parameterized, PolymorphicEmbed.Type, _opts}},
         acc,
         changes,
         msg_func
       ) do
    if changeset = Map.get(changes, field) do
      case traverse_errors(changeset, msg_func) do
        errors when errors == %{} -> acc
        errors -> Map.put(acc, field, errors)
      end
    else
      acc
    end
  end

  defp polymorphic_key_reducer(
         {field, {rel, %{cardinality: :many}}},
         acc,
         changes,
         msg_func
       )
       when rel in [:assoc, :embed] do
    if changesets = Map.get(changes, field) do
      {errors, all_empty?} =
        Enum.map_reduce(changesets, true, fn changeset, all_empty? ->
          errors = traverse_errors(changeset, msg_func)
          {errors, all_empty? and errors == %{}}
        end)

      case all_empty? do
        true -> acc
        false -> Map.put(acc, field, errors)
      end
    else
      acc
    end
  end

  defp polymorphic_key_reducer(
         {field, {:array, {:parameterized, PolymorphicEmbed.Type, _opts}}},
         acc,
         changes,
         msg_func
       ) do
    if changesets = Map.get(changes, field) do
      {errors, all_empty?} =
        Enum.map_reduce(changesets, true, fn changeset, all_empty? ->
          errors = traverse_errors(changeset, msg_func)
          {errors, all_empty? and errors == %{}}
        end)

      case all_empty? do
        true -> acc
        false -> Map.put(acc, field, errors)
      end
    else
      acc
    end
  end

  defp polymorphic_key_reducer({_, _}, acc, _, _), do: acc

  defp check_options!(opts, fun_arity) do
    case Enum.find(opts, fn {k, _} -> k not in @valid_options end) do
      {k, _} ->
        raise ArgumentError, "invalid option #{inspect(k)} for #{fun_arity}"

      nil ->
        case {Keyword.get(opts, :cardinality), Keyword.get(opts, :on_type_not_found)} do
          {:one, :ignore} ->
            raise ArgumentError,
                  "invalid option :on_type_not_found value :ignore for #{fun_arity}"

          {:many, :nilify} ->
            raise ArgumentError,
                  "invalid option :on_type_not_found value :nilify for #{fun_arity}"

          _ ->
            opts
        end
    end
  end

  defp resolve_types(types, env) do
    case types do
      types when is_list(types) ->
        expand_alias(types, env)

      # Module.function(args...)
      {{:., _, context}, _, args} when is_list(context) and is_list(args) ->
        {types, _binding} = Module.eval_quoted(env, types)
        expand_alias(types, env)

      # {Module, function, args}
      {:{}, _, [{_, _, _}, f, a]} when is_atom(f) and is_list(a) ->
        {{m, f, a}, _binding} = Module.eval_quoted(env, types)

        m
        |> apply(f, a)
        |> expand_alias(env)

      # {Module, function}
      {{_, _, _}, f} when is_atom(f) ->
        {m, f} = Macro.expand_literals(types, env)

        m
        |> apply(f, [])
        |> expand_alias(env)
    end
  end

  # Expand module aliases to avoid creating compile-time dependencies between the
  # parent schema that uses `polymorphic_embeds_one` or `polymorphic_embeds_many`
  # and the embedded schemas.
  defp expand_alias(types, env) when is_list(types) do
    Enum.map(types, fn
      {type_name, type_opts} when is_list(type_opts) ->
        {type_name, Keyword.update!(type_opts, :module, &do_expand_alias(&1, env))}

      {type_name, module} ->
        {type_name, do_expand_alias(module, env)}
    end)
  end

  # FIGURE OUT HOW TO RESOLVE THIS PROPERLY
  # If it's not a list or a map, it means it's being defined by a reference of some kind,
  # possibly via module attribute like:
  # @types [twilio: PolymorphicEmbed.Channel.TwilioSMSProvider]
  # # ...
  #   polymorphic_embeds_one(:fallback_provider, types: @types)
  # which means we can't expand aliases
  defp expand_alias(types, env) do
    Logger.warning("""
    Aliases could not be expanded for the given types in #{inspect(env.module)}.

    This likely means the types are defined using a module attribute or another reference
    that cannot be expanded at compile time. As a result, this may lead to unnecessary
    compile-time dependencies, causing longer compilation times and unnecessary
    re-compilation of modules (the parent defining the embedded types).

    Ensure that the types are specified directly within the macro call to avoid these issues,
    or refactor your code to eliminate references that cannot be expanded.
    """)

    types
  end

  defp do_expand_alias({:__aliases__, _, _} = ast, env) do
    # Macro.expand(ast, %{env | lexical_tracker: nil})
    Macro.expand(ast, %{env | function: {:__schema__, 2}})
  end

  defp do_expand_alias(ast, _env) do
    ast
  end
end
