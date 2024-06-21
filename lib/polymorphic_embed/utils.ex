defmodule PolymorphicEmbed.Utils do
  @moduledoc "Temporary utility function location"

  alias PolymorphicEmbed.Type

  def json_library, do: Application.get_env(:polymorphic_embed, :json_library, Jason)

  @doc """
  Returns the PolymorphicEmbed struct for `field` on `schema`.

  If `schema` is not an Ecto.Schema or there are other errors, exceptions may
  be thrown.
  """
  def get_field_params(schema, field) do
    if !function_exported?(schema, :__schema__, 2) do
      raise ArgumentError, "#{inspect(schema)} is not an Ecto schema"
    end

    case schema.__schema__(:type, field) do
      {:parameterized, Type, %Type{cardinality: :many}} ->
        raise ArgumentError,
              "#{schema.__struct__}.#{field} has multiple cardinality but was declared as polymorphic_embeds_one"

      {:parameterized, Type, %Type{cardinality: :one} = params} ->
        params

      {:array, {:parameterized, Type, %Type{cardinality: :one}}} ->
        raise ArgumentError,
              "#{schema.__struct__}.#{field} has single cardinality but was declared as polymorphic_embeds_many"

      {:array, {:parameterized, Type, %Type{cardinality: :many} = params}} ->
        params

      {_, {:parameterized, Type, %Type{cardinality: :many}}} ->
        raise ArgumentError,
              "#{schema.__struct__}.#{field} has multiple cardinality but was declared as polymorphic_embeds_one"

      {_, {:parameterized, Type, %Type{cardinality: :one} = params}} ->
        params

      _ ->
        raise ArgumentError, "#{schema.__struct__}.#{field} is not a polymorphic embed"
    end
  end

  @doc """
  Returns the polymorphic type identifier for the module from the provided
  types metadata.
  """
  def get_polymorphic_type(%module{}, types_metadata),
    do: get_polymorphic_type(module, types_metadata)

  def get_polymorphic_type(module, types_metadata) do
    types_metadata
    |> Enum.find(%{}, &(module == &1.module))
    |> Map.fetch!(:type)
  end

  @doc """
  Returns the polymorphic type identifier for the `module` from the `schema`
  and `field`.
  """
  def get_polymorphic_type(schema, field, module_or_struct) do
    get_polymorphic_type(module_or_struct, get_field_params(schema, field).types_metadata)
  end

  @doc """
  Returns the polymorphic type based on the attributes in `attrs`, either the
  `type_field` if present, or the fields based on the setting
  `identify_by_fields` in the `types_metadata`.
  """
  def infer_type_from_data(attrs, type_field, types_metadata) when is_atom(type_field),
    do: infer_type_from_data(attrs, Atom.to_string(type_field), types_metadata)

  def infer_type_from_data(%{} = attrs, type_field, types_metadata) do
    attrs = for {key, val} <- attrs, into: %{}, do: {to_string(key), val}

    if type = Map.get(attrs, type_field) do
      resolve_type_by_name(type, types_metadata)
    else
      keys = Map.keys(attrs)

      # Find a type in `types_metadata` which has a list in
      # `identify_by_fields` covered by `keys` (`identify_by_fields -- keys`).
      match =
        Enum.find(types_metadata, fn
          %{identify_by_fields: [_ | _] = fields} -> [] == fields -- keys
          _ -> false
        end)

      case match do
        %{module: module} -> module
        _ -> nil
      end
    end
  end

  def cannot_infer_type_from_data!(data) do
    raise "could not infer polymorphic embed type from data #{inspect(data)}"
  end

  def resolve_type_by_name(type, types_metadata) do
    case get_metadata_for_type(to_string(type), types_metadata) do
      nil -> nil
      type_metadata -> Map.fetch!(type_metadata, :module)
    end
  end

  @doc ~S"""
  Given a `schema`, `field`, and either a type identifier or data shape, returns the
  schema module matching the polymorphic type.
  """
  def get_polymorphic_module(schema, field, type_or_data) do
    params = get_field_params(schema, field)

    case type_or_data do
      map when is_map(map) ->
        infer_type_from_data(map, Atom.to_string(params.type_field), params.types_metadata)

      type when is_atom(type) or is_binary(type) ->
        resolve_type_by_name(type, params.types_metadata)
    end
  end

  @doc """
  Returns the list of possible types for a given `schema` and `field`.

  ### Example

      iex> PolymorphicEmbed.types(PolymorphicEmbed.Reminder, :contexts)
      [:location, :age, :device]
  """
  def types(schema, field) do
    schema
    |> get_field_params(field)
    |> Map.fetch!(:types_metadata)
    |> Enum.map(& &1.type)
  end

  defp get_metadata_for_type(type, types_metadata) when is_binary(type),
    do: Enum.find(types_metadata, &(type == to_string(&1.type)))
end
