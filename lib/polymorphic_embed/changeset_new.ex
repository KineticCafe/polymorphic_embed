defmodule PolymorphicEmbed.ChangesetNew do
  alias Ecto.Changeset

  alias PolymorphicEmbed.Type
  alias PolymorphicEmbed.Utils

  def apply_changes(changeset) do
    result = Changeset.apply_changes(changeset)

    Enum.reduce(changeset.changes, result, fn
      {key, %Changeset{} = inner_changeset}, acc ->
        Map.put(acc, key, apply_changes(inner_changeset))

      {key, list}, acc when is_list(list) ->
        new_list =
          Enum.map(list, fn
            %Changeset{} = changeset_entry ->
              apply_changes(changeset_entry)

            value ->
              value
          end)

        Map.put(acc, key, new_list)

      _, acc ->
        acc
    end)
  end

  def cast_polymorphic_embed(changeset, key, opts \\ [])

  def cast_polymorphic_embed(%Changeset{data: data, types: types}, _key, _opts)
      when data == nil or types == nil do
    raise ArgumentError,
          "cast_polymorphic_embed/3 expects the changeset to be cast. " <>
            "Please call cast/4 before calling cast_polymorphic_embed/3"
  end

  def cast_polymorphic_embed(%Changeset{}, key, _opts) when not is_atom(key) do
    raise ArgumentError,
          "cast_polymorphic_embed/3 expects an atom key, got key: `#{inspect(key)}`"
  end

  def cast_polymorphic_embed(%Changeset{} = changeset, key, opts) do
    param_key = Atom.to_string(key)
    %{data: data, types: types, params: params, changes: changes} = changeset
    embed = polymorphic_embed!(:cast, key, Map.get(types, key))
    params = params || %{}

    {changeset, required?} =
      if opts[:required] do
        {update_in(changeset.required, &[key | &1]), true}
      else
        {changeset, false}
      end

    on_cast = &polymorphic_on_cast(&1, &2, Keyword.get(opts, :with), embed)
    sort = opts_key_from_params(:sort_param, opts, params)
    drop = opts_key_from_params(:drop_param, opts, params)

    if is_map_key(params, param_key) or is_list(sort) or is_list(drop) do
      current = Map.get(data, key)
      create_sort_default = fn -> sort_create(Enum.into(opts, %{}), embed) end
      value = cast_params(embed, Map.get(params, param_key), sort, drop, create_sort_default)

      case embed_cast(embed, value, current, on_cast, opts) do
        {:ok, change, embed_valid?} when change != current ->
          changeset = %{
            force_update(changeset, opts)
            | changes: Map.put(changes, key, change),
              valid?: changeset.valid? and embed_valid?
          }

          missing_polymorphic_embed(changeset, key, current, required?, embed, opts)

        {:error, {message, meta}} ->
          meta = [validation: :cast_polymorphic_embed] ++ meta
          error = {key, {invalid_message(opts, message), meta}}
          %{changeset | errors: [error | changeset.errors], valid?: false}

        # ignore or ok with change == current
        _ ->
          missing_polymorphic_embed(changeset, key, current, required?, embed, opts)
      end
    else
      missing_polymorphic_embed(
        changeset,
        key,
        Map.get(data, key),
        required?,
        embed,
        opts
      )
    end
  end

  def cast_polymorphic_embed(_, _, _) do
    raise ArgumentError, "cast_polymorphic_embed/3 only accepts a changeset as first argument"
  end

  defp polymorphic_embed!(_op, _name, {:parameterized, Type, %Type{cardinality: :one} = params}),
    do: params

  defp polymorphic_embed!(
         _op,
         _name,
         {:array, {:parameterized, Type, %Type{cardinality: :many} = params}}
       ),
       do: params

  defp polymorphic_embed!(
         _op,
         _name,
         {_, {:parameterized, Type, %Type{cardinality: :one} = params}}
       ),
       do: params

  defp polymorphic_embed!(op, key, pattern) do
    message =
      case pattern do
        nil ->
          "not found. Make sure it exists and is spelled correctly"

        {:parameterized, Type, %Type{cardinality: :many}} ->
          "was declared as polymorphic_embeds_one but has multiple cardinality"

        {:array, {:parameterized, Type, %Type{cardinality: :one}}} ->
          "was declared as polymorphic_embeds_many but has single cardinality"

        {_, {:parameterized, Type, %Type{cardinality: :many}}} ->
          "was declared as polymorphic_embeds_one but has multiple cardinality"
      end

    raise ArgumentError, "cannot #{op} `#{key}`, field `#{key}` " <> message
  end

  defp polymorphic_on_cast(struct, params, on_cast, %Type{types_metadata: types_metadata})
       when is_list(on_cast) do
    type = Utils.get_polymorphic_type(struct, types_metadata)

    case Keyword.get(on_cast, type) do
      {module, function_name, args} ->
        apply(module, function_name, [struct, params | args])

      nil ->
        polymorphic_on_cast(struct, params, nil, nil)

      fun when is_function(fun, 2) ->
        fun.(struct, params)
    end
  end

  defp polymorphic_on_cast(%mod{} = struct, params, nil, _) do
    if !function_exported?(mod, :changeset, 2) do
      raise ArgumentError, """
      the mod #{inspect(mod)} does not define a changeset/2 function,
      which is used by cast_polymorphic_embed/3. You need to either:

        1. implement the #{mod}.changeset/2 function
        2. pass the :with option to cast_polymorphic_embed/3 with a list
           entry for the type and an anonymous function of arity 2 (or
           possibly arity 3, if using polymorphic_embeds_many)

      When using an inline embed, the :with option must be given
      """
    end

    mod.changeset(struct, params)
  end

  defp opts_key_from_params(opt, opts, params) do
    if key = opts[opt] do
      Map.get(params, Atom.to_string(key), nil)
    end
  end

  defp missing_polymorphic_embed(changeset, key, current, required?, embed, opts) do
    %{changes: changes, errors: errors} = changeset
    current_changes = Map.get(changes, key, current)

    cond do
      required? and embed_empty?(embed, current_changes) ->
        %{
          changeset
          | valid?: false,
            errors: [{key, {required_message(opts), [validation: :required]}} | errors]
        }

      is_nil(current) ->
        changeset

      changes == %{} and is_list(current) ->
        %{changeset | data: Map.put(changeset.data, key, Enum.map(current, &autogenerate_id/1))}

      changes == %{} and not is_nil(current) ->
        %{changeset | data: Map.put(changeset.data, key, autogenerate_id(current))}

      true ->
        changeset
    end
  end

  defp required_message(opts), do: Keyword.get(opts, :required_message, "can't be blank")

  defp invalid_message(opts, default \\ nil),
    do: Keyword.get(opts, :invalid_message, default || "is invalid type")

  defp embed_empty?(%{cardinality: :many}, []), do: true
  defp embed_empty?(%{cardinality: :many}, changes), do: embed_filter_empty(changes) == []
  defp embed_empty?(%{cardinality: :one}, nil), do: true
  defp embed_empty?(%{}, _), do: false

  defp embed_filter_empty(changes) do
    Enum.filter(changes, fn
      %Changeset{action: action} when action in [:replace, :delete] -> false
      _ -> true
    end)
  end

  defp cast_params(%{cardinality: :many} = embed, nil, sort, drop, create_sort_default)
       when is_list(sort) or is_list(drop),
       do: cast_params(embed, %{}, sort, drop, create_sort_default)

  defp cast_params(%{cardinality: :many}, value, sort, drop, create_sort_default)
       when is_map(value) do
    drop = if is_list(drop), do: drop, else: []

    {sorted, pending} =
      if is_list(sort) do
        Enum.map_reduce(sort -- drop, value, &Map.pop_lazy(&2, &1, create_sort_default))
      else
        {[], value}
      end

    pending =
      pending
      |> Map.drop(drop)
      |> Enum.map(&key_as_int/1)
      |> Enum.sort()
      |> Enum.map(&elem(&1, 1))

    sorted ++ pending
  end

  defp cast_params(%{cardinality: :one}, value, sort, drop, _create_sort_drop) do
    if sort do
      raise ArgumentError, ":sort_param not supported for polymorphic_embeds_one"
    end

    if drop do
      raise ArgumentError, ":drop_param not supported for polymorphic_embeds_one"
    end

    value
  end

  defp cast_params(_relation, value, _sort, _drop, _create_sort_drop) do
    value
  end

  defp key_as_int({key, val}) when is_binary(key) and byte_size(key) < 32 do
    case Integer.parse(key) do
      {key, ""} -> {key, val}
      _ -> {key, val}
    end
  end

  defp key_as_int(key_val), do: key_val

  defp force_update(changeset, opts) do
    if Keyword.get(opts, :force_update_on_change, true) do
      put_in(changeset.repo_opts[:force], true)
    else
      changeset
    end
  end

  # polymorphic_embeds_one field set to `nil`
  defp embed_cast(%{cardinality: :one}, nil, _current, _on_cast, _opts),
    do: {:ok, nil, true}

  defp embed_cast(%{cardinality: :one} = embed, value, current, on_cast, opts)
       when is_list(value) do
    if Keyword.keyword?(value) do
      embed_cast(embed, Map.new(value), current, on_cast, opts)
    else
      {:error, {invalid_message(opts), [type: :map]}}
    end
  end

  defp embed_cast(%{cardinality: :one} = embed, value, current, on_cast, opts) do
    on_type_not_found = embed.on_type_not_found
    type_param = Atom.to_string(embed.type_field)

    # We support partial update of the embed. If the type cannot be inferred
    # from the parameters, or if the found type hasn't changed, pass the data
    # to the changeset.
    case action_and_struct(value, type_param, embed.types_metadata, current) do
      :type_not_found when on_type_not_found == :raise ->
        Utils.cannot_infer_type_from_data!(value)

      :type_not_found when on_type_not_found == :changeset_error ->
        {:error, {invalid_message(opts), [type: :map]}}

      :type_not_found when on_type_not_found == :nilify ->
        {:ok, nil, true}

      _ when not (is_nil(value) or is_list(value) or is_map(value)) ->
        {:error, {invalid_message(opts), type: :map}}

      {action, %mod{} = struct} ->
        changeset = %{on_cast.(struct, value) | action: action}
        changeset = autogenerate_id(changeset, mod)

        {:ok, changeset, changeset.valid?}
    end
  end

  defp embed_cast(%{cardinality: :many} = embed, value_list, current_list, on_cast, opts)
       when is_nil(value_list) or is_nil(current_list) do
    embed_cast(embed, value_list || [], current_list || [], on_cast, opts)
  end

  defp embed_cast(%{cardinality: :many} = embed, value_list, current_list, on_cast, opts)
       when is_list(value_list) and is_list(current_list) do
    new_embeds =
      Enum.map(
        value_list,
        &embed_cast_list_item(&1, embed, Atom.to_string(embed.type_field), current_list, on_cast)
      )

    if Enum.any?(new_embeds, &(&1 == :error)) do
      {:error, {invalid_message(opts)}}
    else
      {
        :ok,
        Enum.filter(new_embeds, &(&1 != :ignore)),
        Enum.all?(new_embeds, &match?(%{valid?: true}, &1))
      }
    end
  end

  defp embed_cast_list_item(value, embed, type_param, current_list, on_cast) do
    on_type_not_found = embed.on_type_not_found

    case Utils.infer_type_from_data(value, type_param, embed.types_metadata) do
      nil when on_type_not_found == :raise ->
        Utils.cannot_infer_type_from_data!(value)

      nil when on_type_not_found == :changeset_error ->
        :error

      nil when on_type_not_found == :ignore ->
        :ignore

      mod ->
        pks = mod.__schema__(:primary_key)

        value_pks =
          pks
          |> Enum.map(fn pk_name ->
            original =
              Map.get(value, Atom.to_string(pk_name)) ||
                Map.get(value, pk_name)

            case Ecto.Type.cast(mod.__schema__(:type, pk_name), original) do
              {:ok, value} -> value
              _ -> original
            end
          end)

        current =
          Enum.find(current_list, fn
            %^mod{} = entry -> value_pks == Enum.map(pks, &Map.get(entry, &1))
            _ -> false
          end)

        embed_changeset =
          if current do
            %{on_cast.(current, value) | action: :update}
          else
            %{on_cast.(struct(mod), value) | action: :insert}
          end

        autogenerate_id(embed_changeset, mod)
    end
  end

  defp action_and_struct(value, type_param, types_metadata, current) do
    case Utils.infer_type_from_data(value, type_param, types_metadata) do
      nil when is_nil(current) -> :type_not_found
      nil -> {:update, current}
      mod when is_nil(current) -> {:insert, struct(mod)}
      mod when is_struct(current, mod) -> {:update, current}
      mod -> {:insert, struct(mod)}
    end
  end

  defp autogenerate_id(%Changeset{valid?: true, action: action} = changeset, mod)
       when action in [nil, :insert] do
    case mod.__schema__(:autogenerate_id) do
      {key, _source, :binary_id} ->
        if is_nil(Changeset.get_field(changeset, key)) do
          Changeset.put_change(changeset, key, Ecto.UUID.generate())
        else
          changeset
        end

      {_key, :id} ->
        raise "embedded schemas cannot autogenerate `:id` primary keys"

      nil ->
        changeset
    end
  end

  defp autogenerate_id(%Changeset{} = changeset, _mod), do: changeset

  defp autogenerate_id(%mod{} = data) do
    case mod.__schema__(:autogenerate_id) do
      {key, _source, :binary_id} ->
        if is_nil(Map.get(data, key)) do
          Map.put(data, key, Ecto.UUID.generate())
        else
          data
        end

      {_key, :id} ->
        raise "embedded schemas cannot autogenerate `:id` primary keys"

      nil ->
        data
    end
  end

  defp sort_create(_, %{cardinality: :one}), do: nil

  defp sort_create(%{sort_param: _} = opts, embed) do
    type =
      case Map.get(opts, :default_type_on_sort_create) do
        # If type is not provided, use the first type from types_metadata
        nil ->
          [%{type: type} | _] = embed.types_metadata
          type

        default_type ->
          type =
            if is_function(default_type, 0) do
              default_type.()
            else
              default_type
            end

          # If a type is provided, it must be in types_metadata
          if !Enum.find(embed.types_metadata, &match?(%{type: ^type}, &1)) do
            raise "option default_type_on_sort_create must be a valid embedded type, got #{inspect(type)}"
          end

          type
      end

    %{Atom.to_string(embed.type_field) => type}
  end

  defp sort_create(_, _), do: nil
end
