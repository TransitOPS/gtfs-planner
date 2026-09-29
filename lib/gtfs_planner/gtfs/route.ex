defmodule GtfsPlanner.Gtfs.Route do
  use Ecto.Schema
  import Ecto.Changeset
  import GtfsPlanner.ChangesetHelpers

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @route_types [0, 1, 2, 3, 4, 5, 6, 7, 11, 12]

  # The messages the shared validation adds, named so the editor changeset can
  # recognize them and say what to enter instead.
  @missing_name_message "at least one of route_short_name or route_long_name must be present"
  @hex_message "must be a valid 6-character hex color code"
  @url_message "must be an http(s) URL with a nonempty host"
  @editor_fields [
    :route_short_name,
    :route_long_name,
    :route_type,
    :agency_id,
    :route_desc,
    :route_url,
    :route_color,
    :route_text_color,
    :route_sort_order,
    :continuous_pickup,
    :continuous_drop_off,
    :network_id
  ]
  @text_fields [
    :route_id,
    :route_short_name,
    :route_long_name,
    :agency_id,
    :route_desc,
    :route_url,
    :network_id
  ]

  schema "routes" do
    field :route_id, :string
    field :route_type, :integer
    field :route_short_name, :string
    field :route_long_name, :string
    field :agency_id, :string
    field :route_desc, :string
    field :route_url, :string
    field :route_color, :string, default: "FFFFFF"
    field :route_text_color, :string, default: "000000"
    field :route_sort_order, :integer
    field :continuous_pickup, :integer, default: 1
    field :continuous_drop_off, :integer, default: 1
    field :network_id, :string
    field :active, :boolean, default: true
    field :pattern_derivation_error, :string

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    belongs_to :gtfs_version, GtfsPlanner.Versions.GtfsVersion

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          route_id: String.t(),
          route_type: integer(),
          route_short_name: String.t() | nil,
          route_long_name: String.t() | nil,
          agency_id: String.t() | nil,
          route_desc: String.t() | nil,
          route_url: String.t() | nil,
          route_color: String.t(),
          route_text_color: String.t(),
          route_sort_order: integer() | nil,
          continuous_pickup: integer(),
          continuous_drop_off: integer(),
          network_id: String.t() | nil,
          active: boolean(),
          pattern_derivation_error: String.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc "Creates a changeset for a route."
  def changeset(route, attrs) do
    route
    |> cast(attrs, [
      :route_id,
      :route_type,
      :route_short_name,
      :route_long_name,
      :agency_id,
      :route_desc,
      :route_url,
      :route_color,
      :route_text_color,
      :route_sort_order,
      :continuous_pickup,
      :continuous_drop_off,
      :network_id,
      :active,
      :organization_id,
      :gtfs_version_id
    ])
    |> trim_string_fields()
    |> validate_route_fields(:import)
    |> route_constraints()
  end

  @doc """
  Creates the editor changeset for a route create or edit.

  `mode` is `:create`, which casts the natural ID, or `:edit`, where `route_id`
  stays fixed. Only the editor allowlist is cast, so forged scope, identity,
  active and derivation keys never reach the struct. Transient `text_mode`
  metadata (`"automatic"` or `"custom"`) is stripped before the persisted-field
  cast and automatic text hex is recomputed server-side. Only new/changed blank
  colors normalize to FFFFFF/000000, preserving untouched imported values.
  """
  @spec editor_changeset(t(), map(), :create | :edit) :: Ecto.Changeset.t()
  def editor_changeset(route, attrs, mode) when mode in [:create, :edit] do
    {text_mode, attrs} = pop_text_mode(attrs)
    fields = if mode == :create, do: [:route_id | @editor_fields], else: @editor_fields

    route
    |> cast(attrs, fields)
    |> trim_string_fields()
    |> normalize_changed_blank_colors()
    |> apply_text_mode(text_mode)
    |> validate_route_fields(:editor)
    |> validate_route_url()
    |> route_constraints()
    |> editor_error_copy()
  end

  @doc "Returns human-readable label for route_type."
  def route_type_label(route_type) do
    case route_type do
      0 -> "Tram/Light Rail"
      1 -> "Subway/Metro"
      2 -> "Rail"
      3 -> "Bus"
      4 -> "Ferry"
      5 -> "Cable Tram"
      6 -> "Aerial Lift"
      7 -> "Funicular"
      11 -> "Trolleybus"
      12 -> "Monorail"
      _ -> "Unknown"
    end
  end

  @doc "Returns the accepted route types as labelled options."
  @spec route_type_options() :: [{String.t(), integer()}]
  def route_type_options, do: Enum.map(@route_types, &{route_type_label(&1), &1})

  # Private validation functions

  defp validate_route_fields(changeset, name_rule) do
    # The route text columns are varchar(255), and Postgres counts code points.
    changeset
    |> then(fn changeset ->
      Enum.reduce(
        @text_fields,
        changeset,
        &validate_length(&2, &1, max: 255, count: :codepoints)
      )
    end)
    |> validate_required([:route_id, :route_type, :organization_id, :gtfs_version_id])
    |> validate_route_name(name_rule)
    |> validate_inclusion(:route_type, @route_types)
    |> validate_inclusion(:continuous_pickup, 0..3)
    |> validate_inclusion(:continuous_drop_off, 0..3)
    |> validate_number(:route_sort_order, greater_than_or_equal_to: 0)
    |> validate_hex_color(:route_color)
    |> validate_hex_color(:route_text_color)
  end

  # The editor's messages say what to enter, in words an operator can act on.
  # They replace the generic wording only on the editor changeset; the import
  # changeset keeps the messages other callers already read.
  defp editor_error_copy(changeset) do
    %{changeset | errors: Enum.map(changeset.errors, &editor_error/1)}
  end

  defp editor_error({:route_short_name, {@missing_name_message, opts}}),
    do: {:route_short_name, {"Enter a route number, a route name, or both.", opts}}

  defp editor_error({:route_type, {"can't be blank", opts}}),
    do: {:route_type, {"Choose a mode.", opts}}

  defp editor_error({:route_type, {"is invalid", opts}}),
    do: {:route_type, {"Choose a mode from the list.", opts}}

  defp editor_error({:route_id, {"can't be blank", opts}}),
    do: {:route_id, {"Enter a route ID.", opts}}

  defp editor_error({:route_color, {@hex_message, opts}}),
    do: {:route_color, {"Enter six hex digits for the route color, like 1F5FBF.", opts}}

  defp editor_error({:route_text_color, {@hex_message, opts}}),
    do: {:route_text_color, {"Enter six hex digits for the text color, like FFFFFF.", opts}}

  defp editor_error({:route_url, {@url_message, opts}}),
    do: {:route_url, {"Enter a full web address, starting with https:// or http://.", opts}}

  defp editor_error({:route_sort_order, {"is invalid", opts}}),
    do: {:route_sort_order, {"Enter a whole number, 0 or higher.", opts}}

  defp editor_error({:route_sort_order, {"must be greater than or equal to" <> _, opts}}),
    do: {:route_sort_order, {"Enter a whole number, 0 or higher.", opts}}

  defp editor_error(error), do: error

  defp route_constraints(changeset) do
    # routes_organization_id_gtfs_version_id_route_id_index binds to :route_id.
    changeset
    |> unique_constraint([:organization_id, :gtfs_version_id, :route_id],
      error_key: :route_id
    )
    |> foreign_key_constraint(:organization_id)
  end

  # Import rule, identical to the base revision: both names nil fails. A
  # trimmed-but-blank imported name still counts as present so feed rows insert.
  defp validate_route_name(changeset, :import) do
    route_short_name = get_field(changeset, :route_short_name)
    route_long_name = get_field(changeset, :route_long_name)

    if is_nil(route_short_name) && is_nil(route_long_name) do
      missing_route_name_error(changeset)
    else
      changeset
    end
  end

  # Editor rule (R1): at least one name must be non-blank.
  defp validate_route_name(changeset, :editor) do
    route_short_name = get_field(changeset, :route_short_name)
    route_long_name = get_field(changeset, :route_long_name)

    if blank_value?(route_short_name) && blank_value?(route_long_name) do
      missing_route_name_error(changeset)
    else
      changeset
    end
  end

  defp missing_route_name_error(changeset) do
    add_error(changeset, :route_short_name, @missing_name_message)
  end

  defp validate_hex_color(changeset, field) do
    case get_field(changeset, field) do
      nil ->
        changeset

      _value ->
        validate_format(changeset, field, ~r/^[0-9A-Fa-f]{6}$/, message: @hex_message)
    end
  end

  defp blank_value?(value), do: is_nil(value) or String.trim(value) == ""

  # Editor-only rule: an optional URL is blank or an HTTP(S) URL with a host.
  defp validate_route_url(changeset) do
    validate_change(changeset, :route_url, fn :route_url, url ->
      if blank_value?(url) or valid_route_url?(url) do
        []
      else
        [route_url: @url_message]
      end
    end)
  end

  defp valid_route_url?(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] ->
        is_binary(host) and host != ""

      _other ->
        false
    end
  end

  # Only new/changed blank colors normalize to the defaults; untouched colors
  # keep their raw imported values.
  defp normalize_changed_blank_colors(changeset) do
    changeset
    |> normalize_blank_change(:route_color, "FFFFFF")
    |> normalize_blank_change(:route_text_color, "000000")
  end

  defp normalize_blank_change(changeset, field, default) do
    update_change(changeset, field, fn
      blank when blank in [nil, ""] -> default
      value -> value
    end)
  end

  # text_mode is transient form transport metadata; it is stripped before the
  # cast and never persisted.
  defp pop_text_mode(attrs) do
    key = Enum.find(["text_mode", :text_mode], &Map.has_key?(attrs, &1))
    {value, attrs} = if key, do: Map.pop(attrs, key), else: {nil, attrs}

    mode =
      case value do
        v when v in [nil, ""] -> nil
        v when v in ["automatic", :automatic] -> :automatic
        v when v in ["custom", :custom] -> :custom
        _other -> :invalid
      end

    {mode, attrs}
  end

  defp apply_text_mode(changeset, nil), do: changeset
  defp apply_text_mode(changeset, :custom), do: changeset

  defp apply_text_mode(changeset, :invalid) do
    add_error(changeset, :text_mode, "must be automatic or custom")
  end

  # No-op safety (R4/AC-3): resolve automatic text only when a color field
  # changed, and store it only when the computed hex differs from the current
  # value, so an unrelated save leaves changes empty and touches neither
  # route_text_color nor updated_at.
  defp apply_text_mode(changeset, :automatic) do
    if color_change?(changeset), do: put_auto_text_color(changeset), else: changeset
  end

  defp color_change?(changeset) do
    not is_nil(get_change(changeset, :route_color)) or
      not is_nil(get_change(changeset, :route_text_color))
  end

  defp put_auto_text_color(changeset) do
    case changed_or_current_hex(changeset, :route_color) do
      {:ok, background} ->
        auto = auto_text_color(background)

        if auto == get_field(changeset, :route_text_color) do
          changeset
        else
          put_change(changeset, :route_text_color, auto)
        end

      :error ->
        changeset
    end
  end

  defp changed_or_current_hex(changeset, field) do
    value = get_change(changeset, field) || get_field(changeset, field)

    if is_binary(value) and Regex.match?(~r/^[0-9A-Fa-f]{6}$/, value) do
      {:ok, value}
    else
      :error
    end
  end

  # Same WCAG pick as RouteIdentity's fallback: black unless the background
  # luminance gives white more contrast.
  defp auto_text_color(background) do
    luminance = relative_luminance(background)
    black_contrast = (luminance + 0.05) / 0.05
    white_contrast = 1.05 / (luminance + 0.05)
    if black_contrast >= white_contrast, do: "000000", else: "FFFFFF"
  end

  defp relative_luminance(<<red::binary-size(2), green::binary-size(2), blue::binary-size(2)>>) do
    [red, green, blue]
    |> Enum.map(&linear_channel/1)
    |> then(fn [r, g, b] -> 0.2126 * r + 0.7152 * g + 0.0722 * b end)
  end

  defp linear_channel(hex) do
    channel = String.to_integer(hex, 16) / 255
    if channel <= 0.04045, do: channel / 12.92, else: :math.pow((channel + 0.055) / 1.055, 2.4)
  end
end
