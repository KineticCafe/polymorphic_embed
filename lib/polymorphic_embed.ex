defmodule PolymorphicEmbed do
  @moduledoc """
  """

  use Ecto.ParameterizedType

  alias Ecto.Changeset

  @type t() :: any()

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
      Ecto.Schema.__field__(__MODULE__, unquote(field_name), PolymorphicEmbed, unquote(opts))
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
        {:array, PolymorphicEmbed},
        unquote(opts)
      )
    end
  end

  @doc false
  @impl true
  def type(_params), do: :map

  @doc false
  @impl true
  def init(opts) do
    types_metadata = Enum.map(Keyword.fetch!(opts, :types), &normalize_types/1)
    type_field = Keyword.get(opts, :type_field, :__type__)

    %{
      cardinality: Keyword.fetch!(opts, :cardinality),
      default: Keyword.get(opts, :default, nil),
      on_type_not_found: Keyword.get(opts, :on_type_not_found, :changeset_error),
      nilify_unlisted_types_on_load: Keyword.get(opts, :nilify_unlisted_types_on_load, []),
      retain_unlisted_types_on_load: Keyword.get(opts, :retain_unlisted_types_on_load, []),
      type_field: to_string(type_field),
      type_field_atom: type_field,
      types_metadata: types_metadata
    }
  end

  @doc ~S"""
  Casts the given polymorphic embed with the changeset parameters.

  The parameters for the given embed will be retrieved from `changeset.params`. Those
  parameters are expected to be a map with attributes, similar to the ones passed to
  `cast/4`.

  The changeset must have been previously `cast` using `cast/4` before this function is
  invoked.

  Once parameters are retrieved, `cast_polymorphic_embed/3` will match those
  parameters with the embeds already in the changeset record. See `cast_assoc/3` for an
  example of working with casts and
  associations which would also apply for embeds.


  ## Options

  - `:required` - if the polymorphic embed is a required field. For polymorphic embeds
    of cardinality one, a non-`nil` value satisfies this validation. For embeds with many
    entries, a non-empty list is satisfactory.

  - `:required_message` - the message on failure, defaults to "can't be blank"

  - `:invalid_message` - the message on failure, defaults to "is invalid type"

  - `:with` - the function to build the changeset from params. Defaults to the
    `changeset/2` function of the associated module. It must be an anonymous function that
    expects two arguments: the embedded struct to be cast and its parameters. It must
    return a changeset.

  - `:drop_param` - the parameter name which keeps a list of indexes to drop from the
    relation parameters

  - `:sort_param` - the parameter name which keeps a list of indexes to sort from the
    relation parameters. Unknown indexes are considered to be new entries. Non-listed
    indexes will come before any sorted ones.
  """
  def cast_polymorphic_embed(changeset, field, cast_opts \\ [])

  def cast_polymorphic_embed(%Changeset{data: data, types: types}, _field, _cast_opts)
      when data == nil or types == nil do
    raise ArgumentError,
          "cast_polymorphic_embed/3 expects the changeset to be cast. " <>
            "Please call cast/4 before calling cast_polymorphic_embed/3"
  end

  def cast_polymorphic_embed(%Changeset{} = changeset, field, cast_opts) do
    %{array?: array?, types_metadata: types_metadata} =
      field_opts = get_field_opts(changeset.data.__struct__, field)

    required = Keyword.get(cast_opts, :required, false)
    on_cast = Keyword.get(cast_opts, :with, nil)

    changeset_fun = &changeset_fun(&1, &2, on_cast, types_metadata)

    params = changeset.params || %{}

    # used for sort_param and drop_param support for many embeds
    sort = param_value_for_cast_opt(:sort_param, cast_opts, params)
    drop = param_value_for_cast_opt(:drop_param, cast_opts, params)

    required_message = Keyword.get(cast_opts, :required_message, "can't be blank")
    invalid_message = Keyword.get(cast_opts, :invalid_message, "is invalid type")

    case Map.fetch(params, to_string(field)) do
      # consider sort and drop params even if the assoc param was not given, as in Ecto
      # https://github.com/elixir-ecto/ecto/commit/afc694ce723f047e9fe7828ad16cea2de82eb217
      :error when (array? and is_list(sort)) or is_list(drop) ->
        create_sort_default = fn -> sort_create(Enum.into(cast_opts, %{}), field_opts) end
        params_for_field = apply_sort_drop(%{}, sort, drop, create_sort_default)

        cast_polymorphic_embeds_many(
          changeset,
          field,
          changeset_fun,
          params_for_field,
          field_opts,
          invalid_message
        )

      :error when required ->
        if data_for_field = Map.fetch!(changeset.data, field) do
          data_for_field = autogenerate_id(data_for_field, changeset.action)
          Changeset.put_change(changeset, field, data_for_field)
        else
          Changeset.add_error(changeset, field, required_message, validation: :required)
        end

      :error when not required ->
        if data_for_field = Map.fetch!(changeset.data, field) do
          data_for_field = autogenerate_id(data_for_field, changeset.action)
          Changeset.put_change(changeset, field, data_for_field)
        else
          changeset
        end

      {:ok, nil} when required ->
        Changeset.add_error(changeset, field, required_message, validation: :required)

      {:ok, []} when array? and required ->
        Changeset.add_error(changeset, field, required_message, validation: :required)

      {:ok, nil} when not required ->
        Changeset.put_change(changeset, field, nil)

      {:ok, []} when not required ->
        Changeset.put_change(changeset, field, nil)

      {:ok, map} when map == %{} and not array? ->
        changeset

      {:ok, params_for_field} when array? ->
        create_sort_default = fn -> sort_create(Enum.into(cast_opts, %{}), field_opts) end
        params_for_field = apply_sort_drop(params_for_field, sort, drop, create_sort_default)

        cast_polymorphic_embeds_many(
          changeset,
          field,
          changeset_fun,
          params_for_field,
          field_opts,
          invalid_message
        )

      {:ok, params_for_field} when is_map(params_for_field) and not array? ->
        cast_polymorphic_embeds_one(
          changeset,
          field,
          changeset_fun,
          params_for_field,
          field_opts,
          invalid_message
        )
    end
  end

  def cast_polymorphic_embed(_, _, _) do
    raise ArgumentError, "cast_polymorphic_embed/3 only accepts a changeset as first argument"
  end

  @doc false
  @impl true
  def cast(_data, _params) do
    raise "#{__MODULE__} must not be cast using Ecto.Changeset.cast/4, " <>
            "use #{__MODULE__}.cast_polymorphic_embed/2 instead."
  end

  @doc false
  @impl true
  def embed_as(_format, _params), do: :dump

  @doc false
  @impl true
  def load(nil, _loader, _params), do: {:ok, nil}

  def load(data, loader, params) when is_map(data), do: do_load(data, loader, params)

  def load(data, loader, params) when is_binary(data),
    do: do_load(json_library().decode!(data), loader, params)

  @doc false
  @impl true
  def dump(%Changeset{valid?: false}, _dumper, _params) do
    raise "cannot dump invalid changeset"
  end

  def dump(%Changeset{valid?: true} = changeset, dumper, params) do
    dump(Changeset.apply_changes(changeset), dumper, params)
  end

  def dump(%module{} = struct, dumper, %{
        types_metadata: types_metadata,
        type_field_atom: type_field_atom
      }) do
    case module.__schema__(:autogenerate_id) do
      {key, _source, :binary_id} ->
        unless Map.get(struct, key) do
          raise "polymorphic_embed cannot add an autogenerated key without casting " <>
                  "through cast_polymorphic_embed/3"
        end

      _ ->
        nil
    end

    map =
      struct
      |> map_from_struct()
      # use the atom instead of string form for mongodb
      |> Map.put(type_field_atom, do_get_polymorphic_type(module, types_metadata))

    dumper.(:map, map)
  end

  def dump(nil, dumper, _params), do: dumper.(:map, nil)

  @doc ~S"""
  Given a `schema`, `field`, and either a type identifier or data shape, returns the
  schema module matching the polymorphic type.
  """
  def get_polymorphic_module(schema, field, type_or_data) do
    %{types_metadata: types_metadata, type_field: type_field} = get_field_opts(schema, field)

    case type_or_data do
      map when is_map(map) ->
        do_get_polymorphic_module_from_map(map, type_field, types_metadata)

      type when is_atom(type) or is_binary(type) ->
        do_get_polymorphic_module_for_type(type, types_metadata)
    end
  end

  @doc ~S"""
  Given a `schema`, `field`, and a module name struct instance, returns the polymorphic
  type identifier.
  """
  def get_polymorphic_type(schema, field, module_or_struct) do
    %{types_metadata: types_metadata} = get_field_opts(schema, field)
    do_get_polymorphic_type(module_or_struct, types_metadata)
  end

  @doc """
  Returns the list of possible types for a given `schema` and `field`.

  ### Example

      iex> PolymorphicEmbed.types(PolymorphicEmbed.Reminder, :contexts)
      [:location, :age, :device]
  """
  def types(schema, field) do
    %{types_metadata: types_metadata} = get_field_opts(schema, field)
    Enum.map(types_metadata, & &1.type)
  end

  @doc false
  def get_field_opts(schema, field) do
    try do
      schema.__schema__(:type, field)
    rescue
      _ in UndefinedFunctionError ->
        reraise ArgumentError, "#{inspect(schema)} is not an Ecto schema", __STACKTRACE__
    else
      {:parameterized, PolymorphicEmbed, options} -> Map.put(options, :array?, false)
      {:array, {:parameterized, PolymorphicEmbed, options}} -> Map.put(options, :array?, true)
      {_, {:parameterized, PolymorphicEmbed, options}} -> Map.put(options, :array?, false)
      nil -> raise ArgumentError, "#{field} is not a polymorphic embed"
    end
  end

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

  # We need to match the case where an invalid changeset has a PolymorphicEmbed
  # field which is valid, then that PolymorphicEmbed field is already converted
  # to a struct and no longer a changeset. Since the said field is converted to
  # a struct there's no errors to check for.
  def traverse_errors(%_{}, msg_func)
      when is_function(msg_func, 1) or is_function(msg_func, 3) do
    %{}
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

  defp sort_create(%{sort_param: _} = cast_opts, field_opts) do
    default_type = Map.get(cast_opts, :default_type_on_sort_create)
    type_field_atom = Map.fetch!(field_opts, :type_field_atom)
    types_metadata = Map.fetch!(field_opts, :types_metadata)

    case default_type do
      nil ->
        # If type is not provided, use the first type from types_metadata
        [first_type_metadata | _] = types_metadata
        first_type = first_type_metadata.type
        %{type_field_atom => first_type}

      _ ->
        default_type =
          case default_type do
            fun when is_function(fun, 0) -> fun.()
            _ -> default_type
          end

        # If type is provided, ensure it exists in types_metadata
        unless Enum.find(types_metadata, &(&1.type === default_type)) do
          raise "Incorrect type atom #{inspect(default_type)}"
        end

        %{type_field_atom => default_type}
    end
  end

  defp sort_create(_cast_opts, _field_opts), do: nil

  # from https://github.com/elixir-ecto/ecto/commit/dd5aaa11ea7a6d2bf16787ebe8270a5cd9079044#diff-edb6c9aaeb40387eb81c6b238954c0b4d813876d18805c6ae00d7ccc4d78e3f1R1196
  defp apply_sort_drop(value, sort, drop, create_sort_default) when is_map(value) do
    drop = if is_list(drop), do: drop, else: []

    popper =
      case create_sort_default do
        fun when is_function(fun, 0) -> &Map.pop_lazy/3
        _ -> &Map.pop/3
      end

    {sorted, pending} =
      if is_list(sort) do
        Enum.map_reduce(sort -- drop, value, &popper.(&2, &1, create_sort_default))
      else
        {[], value}
      end

    sorted ++
      (pending
       |> Map.drop(drop)
       |> Enum.map(&key_as_int/1)
       |> Enum.sort()
       |> Enum.map(&elem(&1, 1)))
  end

  defp apply_sort_drop(value, _sort, _drop, _default), do: value

  defp param_value_for_cast_opt(opt, opts, params) do
    if key = opts[opt] do
      Map.get(params, Atom.to_string(key), nil)
    end
  end

  defp key_as_int({key, val}) when is_binary(key) do
    case Integer.parse(key) do
      {key, ""} -> {key, val}
      _ -> {key, val}
    end
  end

  # from Ecto
  # We check for the byte size to avoid creating unnecessary large integers
  # which would never map to a database key (u64 is 20 digits only).
  defp key_as_int({key, val}) when is_binary(key) and byte_size(key) < 32 do
    case Integer.parse(key) do
      {key, ""} -> {key, val}
      _ -> {key, val}
    end
  end

  defp key_as_int(key_val), do: key_val

  defp changeset_fun(struct, params, on_cast, types_metadata) when is_list(on_cast) do
    type = do_get_polymorphic_type(struct, types_metadata)

    case Keyword.get(on_cast, type) do
      {module, function_name, args} ->
        apply(module, function_name, [struct, params | args])

      nil ->
        struct.__struct__.changeset(struct, params)

      fun ->
        apply(fun, [struct, params])
    end
  end

  defp changeset_fun(struct, params, nil, _) do
    struct.__struct__.changeset(struct, params)
  end

  defp cast_polymorphic_embeds_one(
         changeset,
         field,
         changeset_fun,
         params,
         field_opts,
         invalid_message
       ) do
    %{
      types_metadata: types_metadata,
      on_type_not_found: on_type_not_found,
      type_field: type_field
    } = field_opts

    data_for_field = Map.fetch!(changeset.data, field)

    # We support partial update of the embed. If the type cannot be inferred
    # from the parameters, or if the found type hasn't changed, pass the data
    # to the changeset.

    case action_and_struct(params, type_field, types_metadata, data_for_field) do
      :type_not_found when on_type_not_found == :raise ->
        raise_cannot_infer_type_from_data(params)

      :type_not_found when on_type_not_found == :changeset_error ->
        Changeset.add_error(changeset, field, invalid_message)

      :type_not_found when on_type_not_found == :nilify ->
        Changeset.put_change(changeset, field, nil)

      {action, struct} ->
        embed_changeset = changeset_fun.(struct, params)
        embed_changeset = %{embed_changeset | action: action}

        case embed_changeset do
          %{valid?: true} = embed_changeset ->
            embed_schema = Changeset.apply_changes(embed_changeset)
            embed_schema = autogenerate_id(embed_schema, embed_changeset.action)
            Changeset.put_change(changeset, field, embed_schema)

          %{valid?: false} = embed_changeset ->
            changeset
            |> Changeset.put_change(field, embed_changeset)
            |> Map.put(:valid?, false)
        end
    end
  end

  defp action_and_struct(params, type_field, types_metadata, data_for_field) do
    case do_get_polymorphic_module_from_map(params, type_field, types_metadata) do
      nil ->
        if data_for_field do
          {:update, data_for_field}
        else
          :type_not_found
        end

      module when is_nil(data_for_field) ->
        {:insert, struct(module)}

      module ->
        if data_for_field.__struct__ != module do
          {:insert, struct(module)}
        else
          {:update, data_for_field}
        end
    end
  end

  defp cast_polymorphic_embeds_many(
         changeset,
         field,
         changeset_fun,
         list_params,
         field_opts,
         invalid_message
       ) do
    %{
      types_metadata: types_metadata,
      on_type_not_found: on_type_not_found,
      type_field: type_field
    } = field_opts

    list_data_for_field = Map.fetch!(changeset.data, field)

    embeds =
      Enum.map(list_params, fn params ->
        case do_get_polymorphic_module_from_map(params, type_field, types_metadata) do
          nil when on_type_not_found == :raise ->
            raise_cannot_infer_type_from_data(params)

          nil when on_type_not_found == :changeset_error ->
            :error

          nil when on_type_not_found == :ignore ->
            :ignore

          module ->
            data_for_field =
              Enum.find(list_data_for_field, fn
                %{id: id} = datum when not is_nil(id) ->
                  id == params[:id] and datum.__struct__ == module

                _ ->
                  nil
              end)

            embed_changeset =
              if data_for_field do
                %{changeset_fun.(data_for_field, params) | action: :update}
              else
                %{changeset_fun.(struct(module), params) | action: :insert}
              end

            maybe_apply_changes(embed_changeset)
        end
      end)

    if Enum.any?(embeds, &(&1 == :error)) do
      Changeset.add_error(changeset, field, invalid_message)
    else
      embeds = Enum.filter(embeds, &(&1 != :ignore))

      any_invalid? =
        Enum.any?(embeds, fn
          %{valid?: false} -> true
          _ -> false
        end)

      changeset = Changeset.put_change(changeset, field, embeds)

      if any_invalid? do
        Map.put(changeset, :valid?, false)
      else
        changeset
      end
    end
  end

  defp maybe_apply_changes(%{valid?: true} = embed_changeset) do
    embed_changeset
    |> Changeset.apply_changes()
    |> autogenerate_id(embed_changeset.action)
  end

  defp maybe_apply_changes(%Changeset{valid?: false} = changeset), do: changeset

  defp do_load(data, _loader, field_opts) do
    %{
      types_metadata: types_metadata,
      type_field: type_field
    } = field_opts

    case do_get_polymorphic_module_from_map(data, type_field, types_metadata) do
      nil ->
        retain_type_list = Map.get(field_opts, :retain_unlisted_types_on_load, [])
        nilify_type_list = Map.get(field_opts, :nilify_unlisted_types_on_load, [])

        retain_type_list = Enum.map(retain_type_list, &to_string(&1))
        nilify_type_list = Enum.map(nilify_type_list, &to_string(&1))

        type = Map.get(data, type_field)

        cond do
          type in retain_type_list ->
            {:ok, data}

          type in nilify_type_list ->
            {:ok, nil}

          true ->
            raise_cannot_infer_type_from_data(data)
        end

      module when is_atom(module) ->
        {:ok, Ecto.embedded_load(module, data, :json)}
    end
  end

  defp map_from_struct(struct) do
    Ecto.embedded_dump(struct, :json)
  end

  defp do_get_polymorphic_module_from_map(%{} = attrs, type_field, types_metadata) do
    attrs = attrs |> convert_map_keys_to_string()

    type = Enum.find_value(attrs, fn {key, value} -> key == type_field && value end)

    if type do
      do_get_polymorphic_module_for_type(type, types_metadata)
    else
      # check if one list is contained in another
      # Enum.count(contained -- container) == 0
      # contained -- container == []
      types_metadata
      |> Enum.filter(&([] != &1.identify_by_fields))
      |> Enum.find(&([] == &1.identify_by_fields -- Map.keys(attrs)))
      |> (&(&1 && Map.fetch!(&1, :module))).()
    end
  end

  defp do_get_polymorphic_module_for_type(type, types_metadata) do
    case get_metadata_for_type(to_string(type), types_metadata) do
      nil -> nil
      type_metadata -> Map.fetch!(type_metadata, :module)
    end
  end

  defp do_get_polymorphic_type(%module{}, types_metadata),
    do: do_get_polymorphic_type(module, types_metadata)

  defp do_get_polymorphic_type(module, types_metadata),
    do: Map.fetch!(get_metadata_for_module(module, types_metadata), :type)

  defp get_metadata_for_module(module, types_metadata),
    do: Enum.find(types_metadata, &(module == &1.module))

  defp get_metadata_for_type(type, types_metadata) when is_binary(type),
    do: Enum.find(types_metadata, &(type == to_string(&1.type)))

  defp convert_map_keys_to_string(%{} = map),
    do: for({key, val} <- map, into: %{}, do: {to_string(key), val})

  defp raise_cannot_infer_type_from_data(data),
    do: raise("could not infer polymorphic embed from data #{inspect(data)}")

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
         {field, {:parameterized, PolymorphicEmbed, _opts}},
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
         {field, {:array, {:parameterized, PolymorphicEmbed, _opts}}},
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

  defp autogenerate_id([], _action), do: []

  defp autogenerate_id([schema | rest], action) do
    [autogenerate_id(schema, action) | autogenerate_id(rest, action)]
  end

  defp autogenerate_id(schema, :update) do
    # in case there is no primary key, Ecto.primary_key/1 returns an empty keyword list []
    for {_, nil} <- Ecto.primary_key(schema) do
      raise("no primary key found in #{inspect(schema)}")
    end

    schema
  end

  defp autogenerate_id(schema, action) when action in [nil, :insert] do
    case schema.__struct__.__schema__(:autogenerate_id) do
      {key, _source, :binary_id} ->
        if Map.get(schema, key) == nil do
          Map.put(schema, key, Ecto.UUID.generate())
        else
          schema
        end

      {_key, :id} ->
        raise("embedded schemas cannot autogenerate `:id` primary keys")

      nil ->
        schema
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

  defp normalize_types({type_name, module}) when is_atom(module),
    do: normalize_types({type_name, module: module})

  defp normalize_types({type_name, embedded_type}) do
    %{
      type: type_name,
      module: Keyword.fetch!(embedded_type, :module),
      identify_by_fields:
        Enum.map(Keyword.get(embedded_type, :identify_by_fields, []), &to_string/1)
    }
  end

  defp json_library, do: Application.get_env(:polymorphic_embed, :json_library, Jason)

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
end
