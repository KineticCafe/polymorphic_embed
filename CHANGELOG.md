# Changelog

## 4.1.0-kinetic.2

Rebased against upstream 4.0.x.

## 4.0.0-kinetic.1

- Removed Phoenix form support. This is not required for Kinetic and causes
  dependency issues. If we do need this, we would add it as a second package.

- Removed some parity with Ecto `embeds_one/3` and `embeds_many/3` by removing
  the `:on_replace` option. The previous version required `on_replace: :update`
  for `polymorphic_embeds_one/3` and `on_replace: :delete` for
  `polymorphic_embeds_many/3`, so if the values are required, they can be
  inferred by cardinality.

- Removed `with: [{atom(), mfa()}]` support in `cast_polymorphic_embed/3`.

- Modified the resolution of `types` to support qualified function calls, MFA,
  and `{module, function}` tuples instead of only literal type keyword lists.

## 4.0.x

- Support `sort_param` and `drop_param` for list of embeds
- Add `PolymorphicEmbed.HTML.Component.polymorphic_embed_inputs_for/1` (similar
  to `Phoenix.Component.inputs_for/1`)
- Support updating list of embeds while retaining ids
- Add `:retain_unlisted_types_on_load` and `:nilify_unlisted_types_on_load`
  options
- Fix form input rendering for list of embeds
- Fix `traverse_errors` for nested embeds
- MongoDB fix

**Breaking Change**: The form helper `get_polymorphic_type/3` has been updated
to `get_polymorphic_type/2`. The module name parameter (previously the second
parameter) has been removed.

## 3.0.x

- Default value for polymorphic list of embeds is `[]` instead of `nil`
  (following `embeds_many/3`)

### Migration from 2.x to 3.x

- Use `polymorphic_embeds_one/2` and `polymorphic_embeds_many/2` macros instead
  of `field/3`

## 2.0.x

- Support IDs

### Migration from 1.x to 2.x

- Make sure that every existing polymorphic `embedded_schema` contains the
  setting `@primary_key false`

## 1.10.x

- Add `polymorphic_embed_inputs_for/2` for displaying forms in LiveView
- Add `polymorphic_embed_inputs_for/3` for displaying forms in Phoenix templates
  without needing to specify the type

## 1.9.x

- Add `PolymorphicEmbed.types/2` function returning the possible types for a
  polymorphic field

## 1.8.x

- Add `:nilify` and `:ignore` for `:on_type_not_found` option

## 1.7.x

- Support the SQLite3 Ecto adapter `ecto_sqlite3`

## 1.6.x

- Fix errors in form for `embeds_one` nested into `polymorphic_embed`
- Refactor `PolymorphicEmbed.HTML.Form`

## 1.5.x

- Add `traverse_errors/2`

## 1.4.x

- Support custom changeset functions through `:with` option

## 1.3.x

- Add `:required` option

## 1.2.x

- Support custom type field

## 1.1.x

- Support list of polymorphic embeds
- Force `:on_replace` option to be explicitly set
