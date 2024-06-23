defmodule PolymorphicEmbed.Changeset do
  @moduledoc ""

  alias Ecto.Changeset

  alias PolymorphicEmbed.Utils

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
    embed = Utils.get_field_params(changeset.data.__struct__, field)
    array? = embed.cardinality == :many

    required = Keyword.get(cast_opts, :required, false)
    on_cast = Keyword.get(cast_opts, :with, nil)

    changeset_fun = &changeset_fun(&1, &2, on_cast, embed.types_metadata)

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
        create_sort_default = fn -> sort_create(Enum.into(cast_opts, %{}), embed) end
        params_for_field = apply_sort_drop(%{}, sort, drop, create_sort_default)

        cast_polymorphic_embeds_many(
          changeset,
          field,
          changeset_fun,
          params_for_field,
          embed,
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
        create_sort_default = fn -> sort_create(Enum.into(cast_opts, %{}), embed) end
        params_for_field = apply_sort_drop(params_for_field, sort, drop, create_sort_default)

        cast_polymorphic_embeds_many(
          changeset,
          field,
          changeset_fun,
          params_for_field,
          embed,
          invalid_message
        )

      {:ok, params_for_field} when is_map(params_for_field) and not array? ->
        cast_polymorphic_embeds_one(
          changeset,
          field,
          changeset_fun,
          params_for_field,
          embed,
          invalid_message
        )
    end
  end

  def cast_polymorphic_embed(_, _, _) do
    raise ArgumentError, "cast_polymorphic_embed/3 only accepts a changeset as first argument"
  end

  defp cast_polymorphic_embeds_one(
         changeset,
         field,
         changeset_fun,
         params,
         embed,
         invalid_message
       ) do
    %{
      on_type_not_found: on_type_not_found
    } = embed

    type_param = Atom.to_string(embed.type_field)

    data_for_field = Map.fetch!(changeset.data, field)

    # We support partial update of the embed. If the type cannot be inferred
    # from the parameters, or if the found type hasn't changed, pass the data
    # to the changeset.

    case action_and_struct(params, type_param, embed.types_metadata, data_for_field) do
      :type_not_found when on_type_not_found == :raise ->
        Utils.cannot_infer_type_from_data!(params)

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

  defp cast_polymorphic_embeds_many(
         changeset,
         field,
         changeset_fun,
         value_list,
         embed,
         invalid_message
       ) do
    %{on_type_not_found: on_type_not_found} = embed
    type_param = Atom.to_string(embed.type_field)
    current_list = Map.fetch!(changeset.data, field)

    embeds =
      Enum.map(value_list, fn params ->
        case Utils.infer_type_from_data(params, type_param, embed.types_metadata) do
          nil when on_type_not_found == :raise ->
            Utils.cannot_infer_type_from_data!(params)

          nil when on_type_not_found == :changeset_error ->
            :error

          nil when on_type_not_found == :ignore ->
            :ignore

          module ->
            data_for_field =
              Enum.find(current_list, fn
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

  defp changeset_fun(struct, params, on_cast, types_metadata) when is_list(on_cast) do
    type = Utils.get_polymorphic_type(struct, types_metadata)

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

  defp maybe_apply_changes(%{valid?: true} = embed_changeset) do
    embed_changeset
    |> Changeset.apply_changes()
    |> autogenerate_id(embed_changeset.action)
  end

  defp maybe_apply_changes(%Changeset{valid?: false} = changeset), do: changeset

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

  defp param_value_for_cast_opt(opt, opts, params) do
    if key = opts[opt] do
      Map.get(params, Atom.to_string(key), nil)
    end
  end

  defp sort_create(%{sort_param: _} = cast_opts, embed) do
    default_type = Map.get(cast_opts, :default_type_on_sort_create)

    case default_type do
      nil ->
        # If type is not provided, use the first type from types_metadata
        [first_type_metadata | _] = embed.types_metadata
        first_type = first_type_metadata.type
        %{Atom.to_string(embed.type_field) => first_type}

      _ ->
        default_type =
          case default_type do
            fun when is_function(fun, 0) -> fun.()
            _ -> default_type
          end

        # If type is provided, ensure it exists in types_metadata
        unless Enum.find(embed.types_metadata, &(&1.type === default_type)) do
          raise "Incorrect type atom #{inspect(default_type)}"
        end

        %{Atom.to_string(embed.type_field) => default_type}
    end
  end

  defp sort_create(_cast_opts, _field_params), do: nil

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

  defp action_and_struct(params, type_param, types_metadata, data_for_field) do
    case Utils.infer_type_from_data(params, type_param, types_metadata) do
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
end
