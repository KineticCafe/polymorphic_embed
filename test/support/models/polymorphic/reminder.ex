defmodule PolymorphicEmbed.ReminderTypes do
  alias PolymorphicEmbed.Reminder.Context

  def context_types do
    [location: Context.Location, age: Context.Age, device: Context.Device]
  end
end

defmodule PolymorphicEmbed.Reminder do
  use Ecto.Schema
  use QueryBuilder
  import Ecto.Changeset
  import PolymorphicEmbed
  alias PolymorphicEmbed.{Todo, Event, Reminder.Context}, warn: false
  alias PolymorphicEmbed.Channel.{SMS, Email}, warn: false

  schema "reminders" do
    field(:date, :utc_datetime)
    field(:text, :string)
    has_one(:todo, Todo)
    belongs_to(:event, Event)

    polymorphic_embeds_one :channel,
      types: [
        sms: SMS,
        email: [
          module: Email,
          identify_by_fields: [:address, :confirmed]
        ]
      ],
      type_field: :my_type_field

    polymorphic_embeds_one :channel2,
      types: [
        sms: PolymorphicEmbed.Channel.SMS,
        email: PolymorphicEmbed.Channel.Email
      ]

    polymorphic_embeds_one :channel3,
      types: [
        sms: PolymorphicEmbed.Channel.SMS,
        email: PolymorphicEmbed.Channel.Email
      ],
      type_field: :my_type_field

    # polymorphic_embeds_many :contexts, types: PolymorphicEmbed.ReminderTypes.context_types()
    # polymorphic_embeds_many :contexts, types: {PolymorphicEmbed.ReminderTypes, :context_types}
    polymorphic_embeds_many :contexts, types: {PolymorphicEmbed.ReminderTypes, :context_types, []}

    polymorphic_embeds_many :contexts2,
      types: [
        location: PolymorphicEmbed.Reminder.Context.Location,
        age: PolymorphicEmbed.Reminder.Context.Age,
        device: PolymorphicEmbed.Reminder.Context.Device
      ],
      on_type_not_found: :ignore

    timestamps()
  end

  def changeset(struct, values) do
    struct
    |> cast(values, [:date, :text])
    |> validate_required(:date)
    |> cast_polymorphic_embed(:channel)
    |> cast_polymorphic_embed(:contexts,
      sort_param: :contexts_sort,
      sort_create: %{__type__: :location},
      drop_param: :contexts_drop
    )
    |> cast_polymorphic_embed(:contexts2,
      sort_param: :contexts2_sort,
      sort_create: fn -> %{__type__: :location} end,
      drop_param: :contexts2_drop
    )
  end

  def custom_changeset(struct, values) do
    struct
    |> cast(values, [:date, :text])
    |> cast_polymorphic_embed(:channel,
      with: [
        sms: &PolymorphicEmbed.Channel.SMS.custom_changeset/2
      ]
    )
    |> validate_required(:date)
  end
end
