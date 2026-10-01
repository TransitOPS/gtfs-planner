defmodule GtfsPlanner.Gtfs.Fares do
  @moduledoc """
  The facade over the fare tables a version's fares are edited in.

  A version is *managed* when a `fare_version_settings` row exists for it with
  `managed_at` set. `managed?/2` and `settings/2` are its read side: the export
  and the fare editors ask this module rather than querying the table, so the
  unscoped `get_*!` helpers in `GtfsPlanner.Gtfs` are never used for fare rows.
  Both functions filter by `organization_id` and `gtfs_version_id` together, so
  a version of another organization that carries a settings row is never managed
  (INV-5), and an unmanaged version exports its imported files unchanged.

  `load_workspace/2` is the fare editor's read side: the price grid, riders,
  payment methods, route groups, zone matrices, time periods, transfers, joins,
  the latest `fare_version` history and — for a version that is not managed — the
  stored-row summary, in one scoped snapshot, so no tab queries a fare table
  itself and no two tabs can disagree about what the version holds.

  `save_time_period/2` and `delete_time_period/3` are the time periods card's
  pair (AC-22, R10). A time period is a `fare_time_periods` row carrying the
  operator facts GTFS has no file for — the name, the weekday bitmask and the
  fare-only `service_id` its calendar row is written under — beside the
  `timeframes` rows that hold its ranges, and this writer replaces both halves
  together so the group a rule names always exists.

  `Fares.Conversion` is the first of this package's writers: it builds a
  version's first managed fare set from the four answers of the first-use setup,
  and converts imported fares in later steps. `save_prices/2` is the writer the
  price grid calls, and `Fares.Transfers` follows.

  `preview_price_change/3` and `apply_price_change/3` are the Change prices
  dialog's pair (AC-15). The preview raises no prices and shows the rows a
  chosen scope, amount or percentage, rounding and half-fare rule would change;
  the apply writes exactly those rows through the same fenced path
  `save_prices/2` uses, with each row's `now` as the amount it reviewed.

  `save_fare/2` and `delete_fare/4` are the fare drawer's pair (AC-16). A fare is
  one `fare_product_id` whose rows are one per rider type and payment method,
  which is what this module's own read model already treats as a grid row, so
  creating, renaming, pricing, re-selling and removing a fare is one write here
  rather than a sequence of price cells.

  `save_route_group/2` and `delete_route_group/3` are the route group drawer's
  pair (AC-19). A route group is a GTFS `networks` row and the
  `route_networks` rows naming the routes in it, and this writer is what keeps
  a route in at most one group: adding a route to one group deletes the row it
  had in another and answers which route came from which group, so the drawer
  can state what it moved rather than leave the operator to notice.

  `set_zone_fare/7`, `save_rule/3`, `delete_rule/3` and `set_pass_acceptance/5` are
  the Where fares apply tab's pair of writers (AC-20, AC-21). A zone matrix cell
  and a fare rule are the same thing at different breadths — the rules of one
  fare over one set of conditions — so `set_zone_fare/7` is the cell form of
  `save_rule/3` and both write through one helper. `save_rule/3` answers
  `{:error, {:overlap, rule}}` when the conditions already pay a different
  fare, so the rule drawer can offer Replace or Keep both rather than leaving an
  operator to find out from a failed save, and `set_pass_acceptance/5` is the
  checkbox in the passes table.

  ## How a write is fenced

  Every writer in this module runs through the private `write/4` helper, so
  they all share one shape (R15, INV-1):

  - `Fares.VersionLock.transact/3` holds the organization's published version
    row `FOR UPDATE`, so writers of one version's fares serialize and a pair
    that is not a published version of that organization answers
    `{:error, :not_found}` with nothing written;
  - the version must be managed — there is a `fare_version_settings` row — and
    answers `{:error, :unmanaged}` otherwise, because the editor edits fares
    through the managed form and an unmanaged version still exports its
    imported files;
  - the writer's own function re-checks the values the editor reviewed and
    answers `{:error, {:stale, cells}}` when any differ, writing nothing;
  - `Fares.Normalize.run!/2` runs before the transaction commits;
  - one `fare_version` change-log entry is recorded, carrying the shared
    operation id, the summary the editor's history shows and the rows before
    and after;
  - `{:ok, %{operation_id, inverse}}` is returned, and `undo/3` applies that
    inverse while every row still holds what the write left.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs.Area
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.FareAttribute
  alias GtfsPlanner.Gtfs.FareLegJoinRule
  alias GtfsPlanner.Gtfs.FareLegRule
  alias GtfsPlanner.Gtfs.FareMedia
  alias GtfsPlanner.Gtfs.FareProduct
  alias GtfsPlanner.Gtfs.FareProductDetail
  alias GtfsPlanner.Gtfs.FareRule
  alias GtfsPlanner.Gtfs.Fares.Conversion
  alias GtfsPlanner.Gtfs.Fares.Interpreter
  alias GtfsPlanner.Gtfs.Fares.Money
  alias GtfsPlanner.Gtfs.Fares.Normalize
  alias GtfsPlanner.Gtfs.Fares.VersionLock
  alias GtfsPlanner.Gtfs.Fares.Workspace
  alias GtfsPlanner.Gtfs.FareTimePeriod
  alias GtfsPlanner.Gtfs.FareTransferRule
  alias GtfsPlanner.Gtfs.FareVersionSetting
  alias GtfsPlanner.Gtfs.FareZones
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.Network
  alias GtfsPlanner.Gtfs.RiderCategory
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RouteNetwork
  alias GtfsPlanner.Gtfs.Timeframe
  alias GtfsPlanner.Repo

  # The Recent changes list, and the Prices tab's history card, show the latest
  # three fare changes of a managed version.
  @history_limit 3

  @default_currency "USD"

  # The key a price write's inverse is named under, which is what `undo/3`
  # matches on to tell a price change from a setup or a conversion.
  @price_inverse :prices

  @undo_price_summary "Restored the prices a price change replaced"

  # The key a fare save's or fare delete's inverse is named under, which is what
  # `undo/3` matches on to tell a fare change from a price change, a setup or a
  # conversion.
  @fare_inverse :fare

  @undo_fare_summary "Restored the fare a fare change replaced"

  # The key a rider type or payment method change's inverse is named under, which
  # is what `undo/3` matches on to tell one from a fare or price change. Both
  # writers share it: each reverses the same two things, the row of the rider
  # type or payment method and the `fare_products` rows that named it.
  @definition_inverse :definition

  @undo_definition_summary "Restored the rider type or payment method a change replaced"

  # The key a route group change's inverse is named under, which is what `undo/3`
  # matches on to tell it from a fare, a price, a definition or a conversion. It
  # is its own key because a route group changes `networks` and `route_networks`
  # rather than a `fare_products` row.
  @group_inverse :route_group

  @undo_route_group_summary "Restored the route group a change replaced"

  # The key a zone fare or fare rule change's inverse is named under, which is
  # what `undo/3` matches on to tell it from a fare, a price, a definition, a
  # route group or a conversion. It is its own key because these writers change
  # `fare_leg_rules` rather than a `fare_products` row.
  @rule_inverse :rule

  @undo_rule_summary "Restored the fare rule a change replaced"

  # The key a pass acceptance change's inverse is named under. It is its own key
  # because it changes one `fare_product_details` row's accepted networks rather
  # than a rule, even though the pass rows it moves are Normalize's (R4).
  @pass_inverse :pass_acceptance

  @undo_pass_summary "Restored the pass acceptance a change replaced"

  # `fare_product_details.kind` for a fare sold rather than applied to one ride.
  # Its leg rules are mirrored by `Fares.Normalize` (R4), so it is the one kind
  # a rule or a cell write refuses.
  @pass_kind "pass"

  # The key a time period change's inverse is named under, which is what
  # `undo/3` matches on to tell it from a rule, a pass acceptance, a route
  # group, a fare, a price, a definition or a conversion. It is its own key
  # because it changes a `fare_time_periods` row and the `timeframes` rows of
  # its group rather than a fare or a rule.
  @time_period_inverse :time_period

  @undo_time_period_summary "Restored the time period a change replaced"

  # The end of a service day, which "Until end of service day" writes as a
  # `timeframes` `end_time` (R10). GTFS carries it as hour 24 rather than as
  # `00:00:00` of the next day, so it is formatted here rather than reduced.
  @end_of_day_seconds 86_400
  @end_of_day_time "24:00:00"

  # The `fare_` prefix a time period's service id is built from, and how far
  # the numeric suffix on collision is searched before the write is refused
  # rather than silently given an id that collides with a later period.
  @fare_service_prefix "fare_"
  @service_suffix_limit 999

  @typedoc """
  The arguments every writer of this package takes: the organization and version
  whose fare rows the write touches, and the audit identity its change-log entry
  is recorded for (R15).
  """
  @type scope :: %{
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          audit: AuditContext.t()
        }

  @typedoc """
  What a write answers: the shared operation id naming its change-log entry, and
  the inverse `undo/3` applies. A refusal answers `{:error, reason}` and has
  written nothing.
  """
  @type write_result ::
          {:ok, %{operation_id: Ecto.UUID.t(), inverse: term()}}
          | {:error, {:stale, [map()]} | Ecto.Changeset.t() | atom()}

  # The stored-row counts an unmanaged version's read-only view and its
  # conversion review both state, in the order the review lists them.
  @unmanaged_tables [
    {:fare_attributes, FareAttribute},
    {:fare_rules, FareRule},
    {:fare_products, FareProduct},
    {:fare_leg_rules, FareLegRule},
    {:fare_transfer_rules, FareTransferRule},
    {:fare_leg_join_rules, FareLegJoinRule},
    {:fare_media, FareMedia},
    {:rider_categories, RiderCategory},
    {:networks, Network},
    {:fare_time_periods, FareTimePeriod}
  ]

  @doc """
  Applies the inverse of a write while the rows it created are still the
  version's own (R15).

  A `setup/2` inverse is applied by `Fares.Conversion.undo_setup/3`, which deletes
  the rows that setup wrote while the version's settings row still names this
  operation. A `Conversion.apply/3` inverse is applied the same way by
  `Fares.Conversion.undo_conversion/3`, so undoing a conversion returns the
  version to unmanaged with its imported `fare_attributes` and `fare_rules` rows
  untouched. A `save_prices/2` inverse is applied by `undo_prices/3`, which
  restores each row only while it still holds the amount that write left.
  An inverse no writer of this package produces yet is refused with
  `{:error, :unknown_inverse}` rather than guessed at.
  """
  @spec undo(scope(), Ecto.UUID.t(), term()) :: write_result()
  def undo(scope, operation_id, %{setup: _inverse} = inverse) do
    Conversion.undo_setup(scope, operation_id, inverse)
  end

  def undo(scope, operation_id, %{conversion: _inverse} = inverse) do
    Conversion.undo_conversion(scope, operation_id, inverse)
  end

  def undo(
        %{organization_id: organization_id, gtfs_version_id: gtfs_version_id} = scope,
        operation_id,
        %{
          prices: _inverse
        } = inverse
      ) do
    write(scope, @undo_price_summary, @price_inverse, fn setting ->
      undo_prices(organization_id, gtfs_version_id, operation_id, setting, inverse)
    end)
  end

  def undo(
        %{organization_id: organization_id, gtfs_version_id: gtfs_version_id} = scope,
        operation_id,
        %{fare: _inverse} = inverse
      ) do
    write(scope, @undo_fare_summary, @fare_inverse, fn _setting ->
      undo_fare(organization_id, gtfs_version_id, operation_id, inverse.fare)
    end)
  end

  def undo(
        %{organization_id: organization_id, gtfs_version_id: gtfs_version_id} = scope,
        operation_id,
        %{definition: _inverse} = inverse
      ) do
    write(scope, @undo_definition_summary, @definition_inverse, fn _setting ->
      undo_definition(organization_id, gtfs_version_id, operation_id, inverse.definition)
    end)
  end

  def undo(
        %{organization_id: organization_id, gtfs_version_id: gtfs_version_id} = scope,
        operation_id,
        %{
          route_group: _inverse
        } = inverse
      ) do
    write(scope, @undo_route_group_summary, @group_inverse, fn _setting ->
      undo_route_group(organization_id, gtfs_version_id, operation_id, inverse.route_group)
    end)
  end

  def undo(
        %{organization_id: organization_id, gtfs_version_id: gtfs_version_id} = scope,
        operation_id,
        %{
          rule: _inverse
        } = inverse
      ) do
    write(scope, @undo_rule_summary, @rule_inverse, fn _setting ->
      undo_rule(organization_id, gtfs_version_id, operation_id, inverse.rule)
    end)
  end

  def undo(
        %{organization_id: organization_id, gtfs_version_id: gtfs_version_id} = scope,
        operation_id,
        %{
          pass_acceptance: _inverse
        } = inverse
      ) do
    write(scope, @undo_pass_summary, @pass_inverse, fn _setting ->
      undo_pass_acceptance(
        organization_id,
        gtfs_version_id,
        operation_id,
        inverse.pass_acceptance
      )
    end)
  end

  def undo(
        %{organization_id: organization_id, gtfs_version_id: gtfs_version_id} = scope,
        operation_id,
        %{
          time_period: _inverse
        } = inverse
      ) do
    write(scope, @undo_time_period_summary, @time_period_inverse, fn _setting ->
      undo_time_period(organization_id, gtfs_version_id, operation_id, inverse.time_period)
    end)
  end

  def undo(_scope, _operation_id, _inverse), do: {:error, :unknown_inverse}

  @doc """
  Stores the prices an editor reviewed and changed, and returns the inverse
  `undo/3` applies (AC-14, R9, R15).

  `cells` are the price grid's changed cells, one map each:

      %{fare_product_id: String.t(),
        rider_category_id: String.t(),
        fare_media_id: String.t() | nil,
        reviewed: Decimal.t() | nil,
        amount: Decimal.t() | String.t() | nil}

  A cell names one `fare_products` row by the three values that key it, beside
  the amount the editor reviewed and the amount they typed. An `amount` of
  `nil`, or of a string `Money.parse/1` reads as blank, deletes the row: blank
  means not sold, which is a missing row rather than a zero (R9). A `nil`
  `fare_media_id` is the row that names no method, which GTFS reads as one
  price payable any way — the grid submits a method, so this is what an imported
  row carries.

  A cell with no stored row and an amount creates it, naming the fare and
  currency of the product's other rows. A cell whose `fare_product_id` names no
  product of this version answers `{:error, :not_found}`, so another
  organization's or version's product is never written through this writer.

  Amounts are rounded to the version's currency minor units (R9). A negative
  amount and an unreadable one answer `{:error, :invalid_price}`: only the
  transfer-fee writer may store a negative price, and a mistyped cell must never
  be read as a deletion.

  `reviewed` is the fence. When a stored row holds an amount other than the one
  the editor reviewed — or a row the editor saw is gone — nothing is written and
  the answer is `{:error, {:stale, cells}}` naming each offending cell with the
  amount stored now. A version that is not managed answers
  `{:error, :unmanaged}`, and a pair that is not a published version of that
  organization answers `{:error, :not_found}`.
  """
  @spec save_prices(scope(), [map()]) :: write_result()
  def save_prices(
        %{organization_id: organization_id, gtfs_version_id: gtfs_version_id} = scope,
        cells
      )
      when is_list(cells) do
    write(scope, "Changed #{pluralize(length(cells), "price", "prices")}", @price_inverse, fn
      _setting -> apply_prices(organization_id, gtfs_version_id, cells)
    end)
  end

  @doc """
  The price changes a Change prices dialog is showing, computed and not written
  (AC-15).

  `options` is the dialog's own state:

      %{scope: :single | :pass | :all,
        riders: [String.t()],
        how: :amount | :percent,
        value: Decimal.t() | String.t() | number,
        round: Decimal.t() | String.t() | number,
        half_reduced?: boolean}

  `scope` names the fares: `:single` and `:pass` are the products the editor
  recorded as one ride or as a bundle, and `:all` is every fare a rider reads.
  A transfer fee is none of those — R6 reads its amount out of the transfer
  rules, and R9 reserves a negative amount for the transfer-fee writer — so no
  scope changes one. `riders` are the rider categories to change, `how` moves
  each price by `value` (an amount of dollars, which may be negative to lower
  prices, or a percentage) and `round` is the step the new price is rounded to.

  Each row is one `fare_products` row that would change:

      %{fare_product_id: String.t(),
        rider_category_id: String.t(),
        fare_media_id: String.t() | nil,
        now: Decimal.t(),
        new: Decimal.t()}

  A price that is absent, free or already equal to the new one is not in the
  answer: a fare a rider is not sold on, a child who rides free, and a price the
  chosen rule would not move are all left alone. With `half_reduced?` the
  `reduced` rider's new price is half the new adult price of the same fare and
  payment method, rounded the same way — a fare whose adult price the dialog
  cannot see (no adult row at all) falls back to the ordinary rule for that row.

  Everything here is read through the version pair (INV-5), so no row of
  another organization or another version can be previewed. An amount that
  would fall below zero is raised to zero rather than refused, because a lower
  price is a thing an operator asks for.
  """
  @spec preview_price_change(Ecto.UUID.t(), Ecto.UUID.t(), map()) :: [map()]
  def preview_price_change(organization_id, gtfs_version_id, options)
      when is_binary(organization_id) and is_binary(gtfs_version_id) and is_map(options) do
    products = version_products(organization_id, gtfs_version_id)
    change = price_change(products, organization_id, gtfs_version_id, options)

    products
    |> price_change_products(change)
    |> Enum.flat_map(&price_change_row(&1, products, change))
    |> Enum.sort_by(&{&1.fare_product_id, &1.rider_category_id, &1.fare_media_id || ""})
  end

  @doc """
  Writes exactly the rows a `preview_price_change/3` showed, through the same
  fenced path `save_prices/2` takes (AC-15).

  `rows` are the preview's own rows, and each row's `now` is the amount this
  write reviewed: a row somebody else has changed since the preview refuses the
  whole change with `{:error, {:stale, cells}}` and writes nothing, exactly as
  `save_prices/2` does. One change-log entry is recorded with the summary
  `"Changed N prices with Change prices"`, so the history says where the change
  came from, and the inverse is the price inverse `undo/3` already applies.

  The options are the dialog's state the rows were previewed from, kept so the
  dialog can hold them in one form; the rows are what is written, so a caller
  that hands over rows of its own has written what it named.
  """
  @spec apply_price_change(scope(), map(), [map()]) :: write_result()
  def apply_price_change(
        %{organization_id: organization_id, gtfs_version_id: gtfs_version_id} = scope,
        _options,
        rows
      )
      when is_list(rows) do
    summary =
      "Changed #{pluralize(length(rows), "price", "prices")} with Change prices"

    write(scope, summary, @price_inverse, fn _setting ->
      apply_prices(organization_id, gtfs_version_id, Enum.map(rows, &price_change_cell/1))
    end)
  end

  @doc """
  Whether the version's fares are managed here.

  True exactly when a `fare_version_settings` row exists for this organization
  and version with `managed_at` set. A settings row of another organization or
  another version never answers for this pair.
  """
  @spec managed?(Ecto.UUID.t(), Ecto.UUID.t()) :: boolean()
  def managed?(organization_id, gtfs_version_id) do
    query =
      from(setting in FareVersionSetting,
        where:
          setting.organization_id == ^organization_id and
            setting.gtfs_version_id == ^gtfs_version_id and
            not is_nil(setting.managed_at)
      )

    Repo.exists?(query)
  end

  @doc """
  The version's settings row, or `nil` when the version is unmanaged.

  The row carries `older_format` — `"derived"` or `"imported"` — and the
  `conversion_operation_id` a conversion recorded, so undo can find it again.
  """
  @spec settings(Ecto.UUID.t(), Ecto.UUID.t()) :: FareVersionSetting.t() | nil
  def settings(organization_id, gtfs_version_id) do
    FareVersionSetting
    |> where(
      [setting],
      setting.organization_id == ^organization_id and
        setting.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.one()
  end

  @doc """
  The fare editor's whole read model for one version.

  One snapshot of the version's fare rows, so the Prices, Where fares apply,
  Transfers and Checks tabs, the route-detail card and the journey check all
  describe the version the same way. Every read here is filtered by
  `organization_id` and `gtfs_version_id` together (INV-5), so another version's
  or another organization's rows are absent from the workspace rather than
  filtered out by the views.

  The fare rows themselves are read through `Fares.Interpreter.load_rows/2` —
  the one scoped fare-row loader this package has, so the editor reads exactly
  the rows a journey price reads — beside the `fare_time_periods`,
  `fare_leg_join_rules` and `fare_version` change-log rows that load does not
  carry. Nothing here writes and no writer is called.

  A lost database connection is the adapter's to report as
  `{:error, :unavailable}`; this function answers `{:ok, workspace}` for any
  scope it was given, and a malformed id or any other defect raises rather than
  being presented as downtime.
  """
  @spec load_workspace(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, Workspace.t()}
  def load_workspace(organization_id, gtfs_version_id)
      when is_binary(organization_id) and is_binary(gtfs_version_id) do
    {:ok, build_workspace(organization_id, gtfs_version_id)}
  end

  defp build_workspace(organization_id, gtfs_version_id) do
    rows = Interpreter.load_rows(organization_id, gtfs_version_id)
    setting = settings(organization_id, gtfs_version_id)
    details = detail_index(organization_id, gtfs_version_id)
    periods = time_period_rows(organization_id, gtfs_version_id)
    joins = join_rows(organization_id, gtfs_version_id)

    riders = build_riders(rows.rider_categories)
    media = build_media(rows.fare_media)
    groups = build_groups(rows)
    pass_ids = pass_product_ids(details)
    names = zone_names(organization_id, gtfs_version_id, rows)

    %Workspace{
      managed?: rows.managed?,
      older_format: setting && setting.older_format,
      currency: currency(rows.fare_products),
      fares: build_fares(rows.fare_products, details, media, riders),
      riders: riders,
      media: media,
      groups: groups,
      matrices: build_matrices(rows, groups, pass_ids, names),
      transfers: build_transfers(rows.fare_transfer_rules),
      time_periods: build_time_periods(periods, rows.timeframes),
      joins: joins,
      history: history_rows(organization_id, gtfs_version_id),
      unmanaged: unmanaged_summary(organization_id, gtfs_version_id, rows)
    }
  end

  # The version's own rider categories, the default first so the grid's "Shown
  # first" column leads, then the rest by id.
  defp build_riders(rider_categories) do
    rider_categories
    |> Enum.sort_by(&{if(&1.is_default_fare_category == 1, do: 0, else: 1), &1.rider_category_id})
    |> Enum.map(fn rider ->
      %{
        rider_category_id: rider.rider_category_id,
        name: rider.rider_category_name,
        default?: rider.is_default_fare_category == 1,
        min_age: rider.min_age,
        max_age: rider.max_age,
        eligibility_url: rider.eligibility_url
      }
    end)
  end

  # Payment methods in the order a rider reads them: the GTFS
  # `fare_media_type` first, so cash or no ticket (0) precedes an app (4).
  defp build_media(fare_media) do
    fare_media
    |> Enum.sort_by(&{&1.fare_media_type || 0, &1.fare_media_id})
    |> Enum.map(fn medium ->
      %{
        fare_media_id: medium.fare_media_id,
        name: medium.fare_media_name,
        fare_media_type: medium.fare_media_type
      }
    end)
  end

  # The currency is the version's own product currency, else USD: the spec
  # removed a currency of its own, and one grid is shown in one currency.
  defp currency(fare_products) do
    case fare_products do
      [%FareProduct{currency: currency} | _] when is_binary(currency) and currency != "" ->
        currency

      _other ->
        @default_currency
    end
  end

  # A fare is the group of `fare_products` rows that share a `fare_product_name`
  # — the identity the editor's writers use, since one fare is one name sold to
  # several riders and payment methods. `prices` are the amounts at the fare's
  # first payment method, and `media_prices` the per-medium amounts that differ
  # from it, which is exactly the sub-row the grid draws. A rider the fare is not
  # sold to holds `nil`, which reads as "not sold" rather than free.
  defp build_fares(fare_products, details, media, riders) do
    fare_products
    |> Enum.group_by(&fare_name/1)
    |> Enum.map(fn {name, products} -> build_fare(name, products, details, media, riders) end)
    |> Enum.sort_by(&{fare_order(&1.kind), &1.position, &1.name})
  end

  defp fare_name(%FareProduct{fare_product_name: name}) when is_binary(name) and name != "",
    do: name

  defp fare_name(%FareProduct{fare_product_id: id}), do: id

  defp build_fare(name, products, details, media, riders) do
    detail = products |> Enum.map(&Map.get(details, &1.fare_product_id)) |> Enum.find(& &1)
    sold = sold_media(products)
    base = base_medium(sold, media)
    by_medium = prices_by_medium(products, riders, base)
    prices = Map.get(by_medium, base, blank_prices(riders))

    %{
      name: name,
      kind: kind(detail, products),
      position: (detail && detail.position) || 0,
      product_ids: products |> Enum.map(& &1.fare_product_id) |> Enum.uniq() |> Enum.sort(),
      media: if(sold == [], do: List.wrap(base), else: sold),
      prices: prices,
      media_prices:
        by_medium
        |> Enum.reject(fn {medium, amounts} -> medium == base or amounts == prices end)
        |> Map.new(),
      accepted_network_ids: (detail && detail.accepted_network_ids) || []
    }
  end

  defp sold_media(products) do
    products
    |> Enum.map(& &1.fare_media_id)
    |> Enum.reject(&is_nil(&1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp base_medium([], media), do: first_media_id(media)

  defp base_medium(sold, media) do
    # The fare's first method in the version's own media order is the one whose
    # amounts the grid shows on the fare's own row.
    Enum.find(Enum.map(media, & &1.fare_media_id), &(&1 in sold)) || hd(sold)
  end

  defp first_media_id([%{fare_media_id: id} | _rest]), do: id
  defp first_media_id([]), do: nil

  defp blank_prices(riders) do
    Map.new(riders, &{&1.rider_category_id, nil})
  end

  # Each rider's amount per payment method, every rider present in every method
  # so a grid column never disappears because one method stopped selling it. A
  # row with no `fare_media_id` is the fare's base method, which is how GTFS
  # states "one price, any payment method".
  defp prices_by_medium(products, riders, base) do
    products
    |> Enum.reduce(%{}, fn product, acc ->
      medium = product.fare_media_id || base
      rider_id = product.rider_category_id

      if is_nil(medium) or is_nil(rider_id) do
        acc
      else
        amounts = Map.get(acc, medium, %{})
        Map.put(acc, medium, Map.put(amounts, rider_id, product.amount))
      end
    end)
    |> Map.new(fn {medium, amounts} ->
      {medium, Map.merge(blank_prices(riders), amounts)}
    end)
  end

  # A product the editor recorded is what it recorded. A product with no detail
  # row counts as a single ride (the step 11 reading), unless its own rows carry
  # a bundle amount or a duration, which is how an imported feed marks a pass.
  defp kind(nil, products), do: inferred_kind(products)

  defp kind(%FareProductDetail{kind: kind}, _products) when is_binary(kind) and kind != "",
    do: kind

  defp kind(%FareProductDetail{}, products), do: inferred_kind(products)

  defp inferred_kind(products) do
    bundled? =
      Enum.any?(
        products,
        &(not is_nil(&1.bundle_amount) or not is_nil(&1.duration_amount))
      )

    if bundled?, do: "pass", else: "single"
  end

  defp fare_order("single"), do: 0
  defp fare_order("transfer_fee"), do: 2
  defp fare_order(_other), do: 1

  # The products the editor recorded as passes. Their mirrored leg rules never
  # fill a matrix cell.
  defp pass_product_ids(details) do
    details
    |> Map.values()
    |> Enum.filter(&(&1.kind == "pass"))
    |> Enum.map(& &1.fare_product_id)
    |> MapSet.new()
  end

  defp detail_index(organization_id, gtfs_version_id) do
    FareProductDetail
    |> scoped(organization_id, gtfs_version_id)
    |> Repo.all()
    |> Map.new(&{&1.fare_product_id, &1})
  end

  defp scoped(queryable, organization_id, gtfs_version_id) do
    where(
      queryable,
      [row],
      row.organization_id == ^organization_id and row.gtfs_version_id == ^gtfs_version_id
    )
  end

  # The version's route groups with their routes, and whether a group is priced
  # by zone — which is what gives it a matrix. `route_networks` is the loader's
  # route-to-group map, so it is inverted here. A group is zone-priced when any of
  # its own rules names both a departure and an arrival area.
  defp build_groups(%{networks: networks, route_networks: route_networks} = rows) do
    routes_by_network =
      route_networks
      |> Enum.group_by(fn {_route_id, network_id} -> network_id end, fn {route_id, _} ->
        route_id
      end)

    networks
    |> Enum.map(fn network ->
      %{
        network_id: network.network_id,
        name: network.network_name,
        route_ids: routes_by_network |> Map.get(network.network_id, []) |> Enum.sort(),
        zone_priced?: zone_priced?(rows, network.network_id)
      }
    end)
    |> Enum.sort_by(& &1.network_id)
  end

  defp zone_priced?(rows, network_id) do
    Enum.any?(rows.fare_leg_rules, fn rule ->
      rule.network_id == network_id and not is_nil(rule.from_area_id) and
        not is_nil(rule.to_area_id)
    end)
  end

  # One matrix per zone-priced group, over the zones that group's own rules
  # price. Every ordered pair of zones is a cell, so a pair nobody priced is
  # present and flagged as a gap — that is what the Where tab's "No fare" cell
  # writes through. A pass rule never fills a cell: a pass is sold, not applied
  # to a single ride, so its mirrored leg rules are left out of every matrix.
  defp build_matrices(rows, groups, pass_ids, names) do
    for group <- Enum.filter(groups, & &1.zone_priced?),
        zones = group_zones(rows, group.network_id, pass_ids, names),
        zones != [] do
      cells =
        for zone_from <- zones, zone_to <- zones, into: %{} do
          {{zone_from.area_id, zone_to.area_id},
           %{
             products:
               cell_products(rows, group.network_id, zone_from.area_id, zone_to.area_id, pass_ids),
             gap?: false
           }}
        end

      %{
        network_id: group.network_id,
        zones: zones,
        cells:
          Map.new(cells, fn {{from_id, to_id}, cell} ->
            {{from_id, to_id}, Map.put(cell, :gap?, cell.products == [])}
          end)
      }
    end
  end

  defp group_zones(rows, network_id, pass_ids, names) do
    rows.fare_leg_rules
    |> Enum.filter(fn rule ->
      rule.network_id == network_id and not is_nil(rule.from_area_id) and
        not is_nil(rule.to_area_id) and rule.fare_product_id not in pass_ids
    end)
    |> Enum.flat_map(&[&1.from_area_id, &1.to_area_id])
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&%{area_id: &1, name: Map.get(names, &1, &1)})
  end

  defp cell_products(rows, network_id, from_area_id, to_area_id, pass_ids) do
    rows.fare_leg_rules
    |> Enum.filter(fn rule ->
      rule.network_id == network_id and rule.from_area_id == from_area_id and
        rule.to_area_id == to_area_id and rule.fare_product_id not in pass_ids
    end)
    |> Enum.map(& &1.fare_product_id)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # A managed version's areas are its fare zones, so a zone's name is its
  # `fare_zones` record; an undeclared zone is named by its exact id.
  defp zone_names(organization_id, gtfs_version_id, rows) do
    rows.fare_leg_rules
    |> Enum.flat_map(&[&1.from_area_id, &1.to_area_id])
    |> Enum.reject(&is_nil(&1))
    |> Enum.uniq()
    |> then(&FareZones.zone_names(organization_id, gtfs_version_id, &1))
  end

  # The from × to matrix of the version's leg groups: the groups its transfer
  # rules name and the version's networks, so a rule written against a group that
  # is no longer stored still has its cell. `pay` is the editor's own word for
  # `fare_transfer_type`: 0 is a free transfer, 1 charges the named product and
  # 2 pays the difference.
  defp build_transfers(fare_transfer_rules) do
    leg_groups =
      fare_transfer_rules
      |> Enum.flat_map(&[&1.from_leg_group_id, &1.to_leg_group_id])
      |> Enum.reject(&is_nil(&1))
      |> Enum.uniq()
      |> Enum.sort()

    for from <- leg_groups, to <- leg_groups do
      %{
        from_leg_group_id: from,
        to_leg_group_id: to,
        policy: transfer_policy(fare_transfer_rules, from, to)
      }
    end
  end

  # The rule that prices a group pair: a rule with no `transfer_count` covers
  # every change, so it is the fallback and a counted rule is preferred.
  defp transfer_policy(rules, from, to) do
    rules
    |> Enum.filter(&(&1.from_leg_group_id == from and &1.to_leg_group_id == to))
    |> Enum.sort_by(
      &{if(is_nil(&1.transfer_count), do: 1, else: 0), &1.transfer_count || 0, &1.id}
    )
    |> List.first()
    |> case do
      nil ->
        nil

      rule ->
        %{
          pay: pay(rule.fare_transfer_type),
          minutes: minutes(rule),
          count: rule.transfer_count,
          fee: fee(rule),
          fare_transfer_type: rule.fare_transfer_type,
          transfer_count: rule.transfer_count,
          duration_limit: rule.duration_limit,
          duration_limit_type: rule.duration_limit_type
        }
    end
  end

  defp pay(0), do: :free
  defp pay(1), do: :fee
  defp pay(2), do: :difference

  # `duration_limit_type` 1 measures from the first departure; the other types
  # measure from arrival or elsewhere, which this read model does not reduce to
  # minutes.
  defp minutes(%{duration_limit: nil}), do: nil
  defp minutes(%{duration_limit_type: 1, duration_limit: limit}), do: div(limit, 60)
  defp minutes(_rule), do: nil

  defp fee(%{fare_transfer_type: 1, fare_product_id: product_id}), do: product_id
  defp fee(_rule), do: nil

  # A fare time period with the `timeframes` ranges of its group, so the editor
  # draws one card per period carrying its ranges.
  defp build_time_periods(periods, timeframes) do
    periods
    |> Enum.map(fn period ->
      %{
        timeframe_group_id: period.timeframe_group_id,
        name: period.name,
        weekdays: period.weekdays,
        until_end_of_day: period.until_end_of_day,
        service_id: period.service_id,
        ranges:
          timeframes
          |> Enum.filter(&(&1.timeframe_group_id == period.timeframe_group_id))
          |> Enum.sort_by(&{&1.start_time || "", &1.end_time || ""})
          |> Enum.map(&%{start_time: &1.start_time, end_time: &1.end_time})
      }
    end)
    |> Enum.sort_by(&{&1.timeframe_group_id || ""})
  end

  defp time_period_rows(organization_id, gtfs_version_id) do
    FareTimePeriod
    |> scoped(organization_id, gtfs_version_id)
    |> Repo.all()
  end

  # Leg join rules are read-only here: this package never writes them, so the
  # Transfers tab lists them and offers no edit.
  defp join_rows(organization_id, gtfs_version_id) do
    FareLegJoinRule
    |> scoped(organization_id, gtfs_version_id)
    |> Repo.all()
    |> Enum.map(fn join ->
      %{
        from_network_id: join.from_network_id,
        to_network_id: join.to_network_id,
        from_stop_id: join.from_stop_id,
        to_stop_id: join.to_stop_id
      }
    end)
    |> Enum.sort_by(
      &{&1.from_network_id || "", &1.to_network_id || "", &1.from_stop_id || "",
       &1.to_stop_id || ""}
    )
  end

  # The latest `fare_version` entries, which the Recent changes destination and
  # the Prices tab's history card both read.
  defp history_rows(organization_id, gtfs_version_id) do
    ChangeLog
    |> where(
      [log],
      log.organization_id == ^organization_id and log.gtfs_version_id == ^gtfs_version_id and
        log.entity_type == "fare_version"
    )
    |> order_by([log], desc: log.inserted_at, desc: log.id)
    |> limit(@history_limit)
    |> Repo.all()
    |> Enum.map(fn log ->
      %{
        id: log.id,
        action: log.action,
        summary: log.changed_fields && log.changed_fields["summary"],
        actor_email: log.actor_email,
        inserted_at: log.inserted_at
      }
    end)
  end

  # An unmanaged version's stored rows, which the read-only Prices view and the
  # conversion review both state. A version with no fare rows at all is the
  # first-use setup rather than an unmanaged conversion, and carries no summary.
  defp unmanaged_summary(_organization_id, _gtfs_version_id, %{managed?: true}), do: nil

  defp unmanaged_summary(organization_id, gtfs_version_id, rows) do
    if rows.fare_attributes == [] and rows.fare_products == [] do
      nil
    else
      %{
        format: unmanaged_format(rows),
        counts:
          Map.new(@unmanaged_tables, fn {key, schema} ->
            {key, count(schema, organization_id, gtfs_version_id)}
          end),
        attributes:
          Enum.map(rows.fare_attributes, fn attribute ->
            %{
              fare_id: attribute.fare_id,
              price: attribute.price,
              currency: attribute.currency_type,
              transfers: attribute.transfers,
              transfer_duration: attribute.transfer_duration
            }
          end)
      }
    end
  end

  defp unmanaged_format(rows) do
    cond do
      rows.fare_products != [] -> :v2
      rows.fare_attributes != [] -> :v1
      true -> :none
    end
  end

  defp count(schema, organization_id, gtfs_version_id) do
    schema
    |> scoped(organization_id, gtfs_version_id)
    |> select([row], count())
    |> Repo.one()
  end

  # -- Writers -------------------------------------------------------------------

  # The one write path every writer in this module takes (R15, INV-1).
  #
  # The version lock opens the transaction and validates the scope pair, so a
  # pair that is not a published version of that organization never reaches
  # `fun` and answers `{:error, :not_found}`. The version must be managed, which
  # is checked before `fun` runs rather than by the caller, so no writer of this
  # module can forget it. `fun` answers `{:ok, result}` with
  #
  #     %{before: rows, after: rows, inverse: term(),
  #       operation_id: uuid, entry_id: uuid, action: String.t(),
  #       rolled_back_to_log_id: uuid, reported: map()}
  #
  # where all five trailing fields are optional. `reported` is for a fact the
  # caller needs beyond the operation id and the inverse — which routes a route
  # group save took out of another group (AC-19) — and its keys are merged into
  # the answer. A write reports the id of the entry it records, which is the id
  # `undo/3` finds that entry by, so the two name each other by construction. An
  # undo reports the operation it reverses and gives its own entry an id of its
  # own, since a reversal is a second entry pointing at the first through
  # `rolled_back_to_log_id`.
  #
  # `Normalize.run!/2` runs inside this transaction before it commits, so a
  # version is never left with rules this package has not normalized (INV-1),
  # and the one `fare_version` change-log entry is written here rather than by
  # each writer, so every operation is recorded the same way (AC-26).
  defp write(
         %{organization_id: organization_id, gtfs_version_id: gtfs_version_id} = scope,
         summary,
         inverse_key,
         fun
       ) do
    VersionLock.transact(organization_id, gtfs_version_id, fn ->
      with {:ok, setting} <- managed_setting(organization_id, gtfs_version_id),
           {:ok, result} <- fun.(setting) do
        :ok = Normalize.run!(organization_id, gtfs_version_id)
        entry_id = Map.get(result, :entry_id) || Ecto.UUID.generate()
        operation_id = Map.get(result, :operation_id) || entry_id
        record_entry(scope, setting, summary, result, entry_id, operation_id)

        %{operation_id: operation_id, inverse: wrap_inverse(inverse_key, result.inverse)}
        |> Map.merge(Map.get(result, :reported, %{}))
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # The one `fare_version` change-log entry of an operation (R15). The entry
  # addresses the version's Fares section rather than a GTFS natural key: an
  # external id of `"fares"`, no snapshot, and the rows the write read and wrote
  # beside the shared operation id and the summary the editor's history shows.
  defp record_entry(scope, setting, summary, result, entry_id, operation_id) do
    attrs = %{
      entity_type: "fare_version",
      entity_id: setting.id,
      entity_external_id: "fares",
      actor_id: scope.audit.actor_id,
      actor_email: scope.audit.actor_email,
      action: Map.get(result, :action, "updated"),
      rolled_back_to_log_id: Map.get(result, :rolled_back_to_log_id),
      changed_fields: %{
        "operation_id" => operation_id,
        "summary" => summary,
        "before" => result.before,
        "after" => result.after
      },
      organization_id: setting.organization_id,
      gtfs_version_id: setting.gtfs_version_id
    }

    %ChangeLog{id: entry_id}
    |> ChangeLog.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, %ChangeLog{}} -> :ok
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  # The row that makes the version managed, or `:unmanaged`. A fare edit goes
  # through the managed form; an unmanaged version still exports the files its
  # import wrote, so its prices are edited by importing again or by converting
  # it (R12).
  defp managed_setting(organization_id, gtfs_version_id) do
    case settings(organization_id, gtfs_version_id) do
      %FareVersionSetting{} = setting -> {:ok, setting}
      nil -> {:error, :unmanaged}
    end
  end

  # An undo has no inverse of its own to apply a second time, so it reports the
  # nil inverse a caller cannot act on rather than a key holding nothing.
  defp wrap_inverse(_inverse_key, nil), do: nil
  defp wrap_inverse(inverse_key, inverse), do: %{inverse_key => inverse}

  # -- Changing many prices at once ----------------------------------------------

  # The rider the half-fare rule follows. R10's setup, the prototype's dialog and
  # R9's grid all name the reduced rider by this id, so a bulk change is not the
  # only place that knows it.
  @reduced_rider_id "reduced"

  # The fare kinds a bulk price change may touch. A transfer fee is excluded: R6
  # reads its amount out of the transfer rules, and R9 reserves a negative amount
  # for the transfer-fee writer, so raising it here would price a rule rather
  # than a ride.
  @changeable_kinds ["single", "pass"]

  # The step a dialog that names no rounding rounds to: a cent, which leaves the
  # price in the currency's own minor units and is what "Don't round" means (R9).
  @no_rounding Decimal.new("0.01")

  # The dialog's state, read once so every row is priced by the same rule: the
  # rider types it changes, whether it moves by an amount or a percentage, that
  # amount, the step it rounds to, whether the reduced rider stays at half, and
  # the currency the new amounts are stored in (R9).
  defp price_change(products, organization_id, gtfs_version_id, options) do
    %{
      scope: options[:scope] || :all,
      riders: MapSet.new(List.wrap(options[:riders])),
      percent?: options[:how] == :percent,
      value: change_number(options[:value], Decimal.new(0)),
      step: change_number(options[:round], @no_rounding),
      half_reduced?: options[:half_reduced?] == true,
      adult: default_rider_id(organization_id, gtfs_version_id),
      currency: currency(products),
      details: detail_index(organization_id, gtfs_version_id)
    }
  end

  # The version's one default rider type, which is whose price a fare's other
  # rider types are read against (R8). A version with no default has no adult
  # row to move, so no row is treated as one.
  defp default_rider_id(organization_id, gtfs_version_id) do
    RiderCategory
    |> scoped(organization_id, gtfs_version_id)
    |> where([rider], rider.is_default_fare_category == 1)
    |> select([rider], rider.rider_category_id)
    |> Repo.one()
  end

  # The dialog types a number the way an operator reads it, so `$`, a comma and a
  # leading or trailing space are stripped and a minus sign is kept — lowering a
  # price is a thing the dialog offers. Anything that is not a number at all
  # moves nothing, so a half-typed field previews no change rather than raising
  # while the operator is still typing.
  defp change_number(value, default)
  defp change_number(%Decimal{} = value, _default), do: value
  defp change_number(value, _default) when is_integer(value), do: Decimal.new(value)

  defp change_number(value, _default) when is_float(value) do
    value |> Float.round(6) |> Decimal.from_float()
  end

  defp change_number(value, default) when is_binary(value) do
    value
    |> String.replace(~r/[$,\s]/, "")
    |> Decimal.parse()
    |> case do
      {number, ""} -> number
      _other -> default
    end
  end

  defp change_number(_value, default), do: default

  # The rows the scope and the chosen rider types leave in play: a stored price
  # of a fare in scope, sold to a rider type the dialog changes. A fare is a kind
  # the editor recorded, so the scope reads `fare_product_details` the same way
  # the grid's own read model does.
  defp price_change_products(products, change) do
    details = change.details

    products
    |> Enum.group_by(& &1.fare_product_id)
    |> Enum.flat_map(fn {product_id, rows} ->
      product_kind = kind(Map.get(details, product_id), rows)

      if changeable_kind?(product_kind, change.scope) do
        Enum.filter(rows, &changeable_row?(&1, change))
      else
        []
      end
    end)
  end

  defp changeable_kind?(product_kind, :all), do: product_kind in @changeable_kinds
  defp changeable_kind?("single", :single), do: true
  defp changeable_kind?("pass", :pass), do: true
  defp changeable_kind?(_product_kind, _scope), do: false

  # A rider a fare is not sold on holds no row at all, and a free price stays
  # free (R9), so neither is in the answer.
  defp changeable_row?(product, change) do
    MapSet.member?(change.riders, product.rider_category_id) and
      not is_nil(product.amount) and
      not Decimal.equal?(product.amount, 0)
  end

  # One row of the preview, or none when the chosen rule leaves the price where
  # it is: a dialog that lists a row nobody's price changes is showing work that
  # is not there.
  defp price_change_row(product, products, change) do
    new = changed_amount(product, products, change)

    if Decimal.equal?(new, product.amount) do
      []
    else
      [
        %{
          fare_product_id: product.fare_product_id,
          rider_category_id: product.rider_category_id,
          fare_media_id: product.fare_media_id,
          now: product.amount,
          new: new
        }
      ]
    end
  end

  # The default rider's price moves by the chosen rule, the reduced rider's moves
  # with it when the dialog was asked to keep it at half, and every other rider
  # moves by the rule on its own stored price — which is what the dialog says
  # about app prices: the same rule, whatever the method.
  defp changed_amount(product, products, change) do
    cond do
      product.rider_category_id == change.adult ->
        moved_amount(product.amount, change)

      change.half_reduced? and product.rider_category_id == @reduced_rider_id ->
        case adult_new_amount(product, products, change) do
          nil -> moved_amount(product.amount, change)
          adult_new -> rounded(half(adult_new), change)
        end

      true ->
        moved_amount(product.amount, change)
    end
  end

  # The new price of the adult row this reduced row follows: the same fare sold
  # to the default rider on the same payment method, falling back to the fare's
  # method-less row, which GTFS reads as one price payable any way. A fare with
  # no adult price at all has nothing to be half of, and answers `nil` so the
  # caller moves this row by the ordinary rule instead.
  defp adult_new_amount(product, products, change) do
    adult_rows =
      Enum.filter(products, fn row ->
        row.fare_product_id == product.fare_product_id and
          row.rider_category_id == change.adult and not is_nil(row.amount)
      end)

    Enum.find_value(adult_rows, fn row ->
      if row.fare_media_id == product.fare_media_id or is_nil(row.fare_media_id) do
        moved_amount(row.amount, change)
      end
    end)
  end

  # A percentage moves the price by that share of itself, an amount by that many
  # dollars. Either way the result is rounded to the step the dialog chose and
  # stored in the currency's minor units (R9).
  defp moved_amount(amount, change) do
    moved =
      if change.percent? do
        Decimal.mult(amount, Decimal.add(1, Decimal.div(change.value, 100)))
      else
        Decimal.add(amount, change.value)
      end

    rounded(moved, change)
  end

  defp rounded(amount, change) do
    amount
    |> rounded_to_step(change)
    |> then(&Decimal.max(&1, Decimal.new(0)))
    |> Decimal.round(Money.minor_units(change.currency))
  end

  defp rounded_to_step(amount, %{step: step}) do
    amount
    |> Decimal.div(step)
    |> Decimal.round(0)
    |> Decimal.mult(step)
  end

  defp half(amount), do: Decimal.div(amount, Decimal.new(2))

  # The cell `apply_prices/3` writes, carrying the previewed `now` as the amount
  # this write reviewed — which is what makes a row somebody else has changed
  # since the preview refuse the whole change.
  defp price_change_cell(row) do
    %{
      fare_product_id: row[:fare_product_id],
      rider_category_id: row[:rider_category_id],
      fare_media_id: row[:fare_media_id],
      reviewed: row[:now],
      amount: row[:new]
    }
  end

  # -- Creating, editing and deleting fares ---------------------------------------

  # The kinds `save_fare/2` writes. A transfer fee is `Fares.Transfers`' own row
  # (R5) and only that writer may store a negative amount (R9), so a fare
  # written here is a single ride or a pass and nothing else.
  @fare_kinds ["single", "pass"]

  # R4's name for the leg rules whose `network_id` is nil. It is also the one
  # value a pass may accept that is not a network of the version, because R4
  # reads an empty list as "accepted nowhere" and this string as "accepted where
  # the rules name no network".
  @all_routes_accepted "all_routes"

  @doc """
  Creates or updates one fare: its name, its kind, the payment methods it is
  sold on, its prices for each rider type, and — for a pass — the route groups
  that accept it (AC-16).

  `params` is the fare drawer's own form:

      %{name: String.t(),
        fare_product_id: String.t() | nil,
        kind: "single" | "pass",
        media_ids: [String.t()],
        prices: %{rider_category_id => Decimal.t() | String.t() | nil},
        media_prices: %{fare_media_id => %{rider_category_id => Decimal.t() | String.t() | nil}},
        accepted_network_ids: [String.t()],
        position: integer() | nil,
        reviewed: [map()] | nil}

  A form with no `fare_product_id` creates a fare, whose GTFS id is its name as
  an id — `Summer beach shuttle` is `summer_beach_shuttle` — and a name whose id
  this version already holds answers `{:error, :duplicate_fare}`, because an
  operator creating a second fare is not editing the first. A form naming a
  `fare_product_id` updates that fare and answers `{:error, :not_found}` when
  this version holds no such fare, which is what another organization's or
  version's fare id is here (AC-26, INV-5).

  The form is the whole fare: one `fare_products` row per rider type and payment
  method it names, and a row of this fare that it does not name is deleted,
  because blank means not sold and not sold is a missing row rather than a zero
  (R9). `prices` is the fare's price for each rider type, `media_prices` the
  price for one method where it differs, and an amount is read by the same
  `Fares.Money.parse/1` every other price on this page is read by, so a
  mistyped price refuses the whole save rather than storing something else.

  A payment method or a rider type that this version does not hold answers
  `{:error, :not_found}`, so nothing of another version can be written through
  this writer. A blank or unreadable price answers `{:error, :invalid_price}`.

  The fare's operator facts — its kind, its place in the editor's order, and for
  a pass the route groups that accept it — go to `fare_product_details`, which
  is where the Fares v2 files have no place for them. `Fares.Normalize.run!/2`
  then rebuilds the rows that kind implies, so a pass saved with
  `accepted_network_ids` leaves one leg rule per condition set of the single
  rides it stands in for (R4, INV-4); a pass accepts a network of this version or
  `"all_routes"`, and anything else answers `{:error, :not_found}`.

  A blank name answers `{:error, changeset}` with an error on `:name`, because a
  fare with no name is not one an operator can find again, even though the
  stored column itself may hold nothing for an imported row (AC-1).

  `reviewed` is the fence, and is the same cell shape `save_prices/2` takes. It
  is the fare's price list as the editor saw it: a cell whose stored amount has
  moved answers `{:error, {:stale, cells}}` naming it, and writes nothing
  (R15, AC-26).
  """
  @spec save_fare(scope(), map()) :: write_result()
  def save_fare(
        %{organization_id: organization_id, gtfs_version_id: gtfs_version_id} = scope,
        params
      )
      when is_map(params) do
    case trimmed_name(params) do
      {:ok, name} ->
        write(scope, fare_save_summary(params, name), @fare_inverse, fn _setting ->
          apply_fare(organization_id, gtfs_version_id, name, params)
        end)

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Deletes one fare and settles the rules that named it (AC-16).

  `replacement` is what those rules are pointed at instead:

  - a `fare_product_id` of this version moves them there, which answers
    `{:error, :not_found}` when this version holds no such fare and
    `{:error, :conflicting_rule}` when a rule of the replacement already states
    the same conditions — GTFS has one rule per set of conditions and fare;
  - `:remove_rules` deletes them, leaving the cells they priced with no fare,
    which the Where tab reports as a gap;
  - `nil` answers `{:error, :replacement_required}` whenever the fare is named by
    any rule, because deleting a priced fare is not something an operator can
    mean by accident.

  A fare named by no rule at all is deleted with any of the three. The rules in
  question are the version's `fare_leg_rules` rows naming the fare and its
  `fare_transfer_rules` rows naming it, so a deleted fare leaves nothing
  pointing at it (FH-17). The fare's own rows are deleted whole, with the ids
  they had, so `undo/3` puts them back as they were.

  `expected` is the fence, and carries the facts the editor reviewed: `:name`,
  `:kind` and `:prices` (the cell shape `save_prices/2` takes). Anything that has
  moved answers `{:error, {:stale, details}}` and deletes nothing.

  A fare of another organization or another version answers
  `{:error, :not_found}`, a version that is not published answers the same, and
  an unmanaged version answers `{:error, :unmanaged}` — its fares are edited by
  converting it (R12).
  """
  @spec delete_fare(scope(), String.t(), String.t() | :remove_rules | nil, map()) ::
          write_result()
  def delete_fare(
        %{organization_id: organization_id, gtfs_version_id: gtfs_version_id} = scope,
        fare_product_id,
        replacement,
        expected
      )
      when is_binary(fare_product_id) and is_map(expected) do
    name = fare_display_name(organization_id, gtfs_version_id, fare_product_id)
    summary = "Deleted the fare \"#{name || fare_product_id}\""

    write(scope, summary, @fare_inverse, fn _setting ->
      remove_fare(organization_id, gtfs_version_id, fare_product_id, replacement, expected)
    end)
  end

  @doc """
  Creates or updates one rider type: its name, the page that says who qualifies
  for it, and whether it is the default one (AC-17).

  `params` is the rider type drawer's own form:

      %{name: String.t(),
        rider_category_id: String.t() | nil,
        eligibility_url: String.t() | nil,
        default?: boolean(),
        starting: :half | :same | :free | :blank}

  A form with no `rider_category_id` creates a rider type, whose GTFS id is its
  name as an id — `Students (18-25)` is `students_18_25` — and a name whose id
  this version already holds answers `{:error, :duplicate_rider_type}`.
  A form naming a `rider_category_id` updates that rider type and answers
  `{:error, :not_found}` when this version holds no such rider type, which is
  what another organization's or version's id is here (INV-5).

  `starting` is the create's starting prices, applied to every fare the version
  holds, and is what the drawer's preview states (AC-17, R9):

  - `:half` — half the fare's price for the default rider type, rounded to the
    nearest five cents, which is the rounding R9's setup uses;
  - `:same` — the fare's own price for the default rider type, for the fares
    where that price exists;
  - `:free` — a zero amount for every fare;
  - `:blank` — no row at all, because blank means not sold (R9).

  A fare the default rider type has no row for gets no row either, since there
  is no price to start from; `:free` is the choice that sells a fare to a rider
  type for nothing. An update ignores `starting` entirely: the prices are the
  grid's to write, through `save_prices/2` or `save_fare/2`.

  `default?` moves the default. R8 allows exactly one rider type to be the
  default, so setting it clears the flag on whichever rider type held it in the
  same transaction — the two writes commit together or neither does — and
  `Normalize.run!/2` raises if the version is ever left with two (INV-1). A
  version with no rider types at all cannot be managed, so a create never has to
  worry about leaving none.

  The rider type's own row is the only thing an update writes besides the
  default flag: the name, the eligibility URL and the flag go through
  `RiderCategory.changeset/2`, so the URL and the `0`/`1` flag pass the same
  checks every other write of that row passes.
  """
  @spec save_rider_type(scope(), map()) :: write_result()
  def save_rider_type(
        %{organization_id: organization_id, gtfs_version_id: gtfs_version_id} = scope,
        params
      )
      when is_map(params) do
    case trimmed_name(params) do
      {:ok, name} ->
        write(scope, rider_save_summary(params, name), @definition_inverse, fn _setting ->
          apply_rider_type(organization_id, gtfs_version_id, name, params)
        end)

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Deletes one rider type and the prices that named it (AC-17).

  The default rider type answers `{:error, :default_rider_type}`: R8 does not
  allow a managed version with no default, so deleting it would leave the
  version in a state its own normalizer refuses. A rider type another
  organization or another version holds answers `{:error, :not_found}`, and an
  unmanaged version answers `{:error, :unmanaged}`.

  Every `fare_products` row of the rider type is deleted with it, so no price
  names a rider type that is gone, and the rows go into the inverse whole — with
  the ids they had — so `undo/3` puts them back as they were.

  `expected` is the fence, and carries the `:name` the editor reviewed: a rider
  type renamed since the drawer opened answers `{:error, {:stale, details}}` and
  deletes nothing (R15).
  """
  @spec delete_rider_type(scope(), String.t(), map()) :: write_result()
  def delete_rider_type(
        %{organization_id: organization_id, gtfs_version_id: gtfs_version_id} = scope,
        rider_category_id,
        expected
      )
      when is_binary(rider_category_id) and is_map(expected) do
    summary =
      "Deleted the rider type \"#{rider_type_name(organization_id, gtfs_version_id, rider_category_id) || rider_category_id}\""

    write(scope, summary, @definition_inverse, fn _setting ->
      remove_rider_type(organization_id, gtfs_version_id, rider_category_id, expected)
    end)
  end

  @doc """
  Creates or updates one payment method: its name, its GTFS `fare_media_type`
  and the fares that accept it (AC-18).

  `params` is the payment method drawer's own form:

      %{name: String.t(),
        fare_media_id: String.t() | nil,
        fare_media_type: 0..4,
        fare_product_ids: [String.t()]}

  A form with no `fare_media_id` creates a payment method whose GTFS id is its
  name as an id, and a name whose id this version already holds answers
  `{:error, :duplicate_payment_method}`. A `fare_media_type` outside 0–4 answers
  `{:error, :invalid_media_type}` rather than a changeset, because the five
  kinds are a choice the drawer offers rather than free text.

  `fare_product_ids` is the whole set of fares that accept this method, and the
  writer makes the stored rows say so: a fare that accepts it gets one
  `fare_products` row per rider type it is sold to, at that rider's own price on
  the fare's cash medium (type 0) — the price a rider pays with the method, which
  is the price they pay on board until the fare itself is edited to differ by
  payment method (AC-18). A fare that no longer accepts it has those rows
  deleted, because a method a fare does not accept is a missing row rather than a
  zero (R9). A fare with no cash-medium price of its own gets no row: there is
  no price to copy, and the fare is priced by opening it (AC-18).

  A `fare_product_id` this version does not hold answers `{:error, :not_found}`,
  so nothing of another version can be written through this writer (INV-5).

  The medium's own row carries the name and the type, and nothing else is
  implied by it — a payment method appears only in the newer format, because the
  older one records only whether a rider pays on board (R11).
  """
  @spec save_payment_method(scope(), map()) :: write_result()
  def save_payment_method(
        %{organization_id: organization_id, gtfs_version_id: gtfs_version_id} = scope,
        params
      )
      when is_map(params) do
    case trimmed_name(params) do
      {:ok, name} ->
        write(scope, media_save_summary(params, name), @definition_inverse, fn _setting ->
          apply_payment_method(organization_id, gtfs_version_id, name, params)
        end)

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Deletes one payment method and the prices that named it (AC-18).

  Every `fare_products` row of the medium is deleted with it, so no price names
  a payment method that is gone, and the rows go into the inverse whole — with
  the ids they had — so `undo/3` puts them back as they were.

  A payment method of another organization or another version answers
  `{:error, :not_found}`, and an unmanaged version answers `{:error, :unmanaged}`.
  A method this version does not hold is the same answer, because a delete of
  something that is not there has nothing to record.

  `expected` is the fence, and carries the `:name` the editor reviewed (R15).
  """
  @spec delete_payment_method(scope(), String.t(), map()) :: write_result()
  def delete_payment_method(
        %{organization_id: organization_id, gtfs_version_id: gtfs_version_id} = scope,
        fare_media_id,
        expected
      )
      when is_binary(fare_media_id) and is_map(expected) do
    summary =
      "Deleted the payment method \"#{media_name(organization_id, gtfs_version_id, fare_media_id) || fare_media_id}\""

    write(scope, summary, @definition_inverse, fn _setting ->
      remove_payment_method(organization_id, gtfs_version_id, fare_media_id, expected)
    end)
  end

  # -- Writing one rider type -------------------------------------------------------

  # The starting prices a rider type can be created with (AC-17). `:blank` writes
  # no rows at all, which R9 reads as "not sold until you enter prices" — a
  # missing row rather than a zero.
  @starting_prices [:half, :same, :free, :blank]

  # The step R9's setup rounds a reduced price to, and the step `:half` rounds to:
  # the nearest nickel, so a half price never lands on a fraction of a cent a
  # fare machine cannot take.
  @nickel Decimal.new("0.05")

  defp apply_rider_type(organization_id, gtfs_version_id, name, params) do
    categories = version_rider_categories(organization_id, gtfs_version_id)

    with {:ok, rider_id} <- rider_category_id(categories, name, params),
         {:ok, category} <-
           write_rider_category(organization_id, gtfs_version_id, rider_id, name, params),
         {:ok, cleared} <-
           clear_previous_default(organization_id, gtfs_version_id, category, params),
         {:ok, prices} <-
           rider_starting_prices(organization_id, gtfs_version_id, rider_id, params, category) do
      {:ok,
       %{
         before: category_log_row(category, cleared),
         after: rider_log_row(category, prices.rows_written),
         action: category.action,
         inverse: %{
           operation: :save,
           schema: RiderCategory,
           rider_category_id: rider_id,
           row: category,
           fare_products: prices.states,
           cleared_default: cleared
         }
       }}
    end
  end

  # The GTFS id of the rider type the form names: its name as an id when the form
  # creates one, refused when this version already holds it, and the id the form
  # named when it edits one. An id of another version is `:not_found` (INV-5).
  defp rider_category_id(categories, name, params) do
    case fare_param(params, :rider_category_id) do
      nil ->
        id = fare_slug(name)

        cond do
          id == "" -> {:error, name_changeset(name, "must have a letter or a number")}
          Enum.any?(categories, &(&1.rider_category_id == id)) -> {:error, :duplicate_rider_type}
          true -> {:ok, id}
        end

      "" ->
        {:error, :not_found}

      id when is_binary(id) ->
        if Enum.any?(categories, &(&1.rider_category_id == id)) do
          {:ok, id}
        else
          {:error, :not_found}
        end

      _other ->
        {:error, :not_found}
    end
  end

  defp version_rider_categories(organization_id, gtfs_version_id) do
    RiderCategory
    |> scoped(organization_id, gtfs_version_id)
    |> order_by([category], category.rider_category_id)
    |> Repo.all()
  end

  # The one `rider_categories` row, written through its own changeset so the
  # eligibility URL and the `0`/`1` default flag pass the same checks every other
  # write of that row passes. A rider type the version did not hold is a create,
  # and its entry says so the way every other entity type's does.
  defp write_rider_category(organization_id, gtfs_version_id, rider_id, name, params) do
    attrs = %{
      rider_category_id: rider_id,
      rider_category_name: name,
      eligibility_url: blank_to_nil(fare_param(params, :eligibility_url)),
      is_default_fare_category: default_flag(params)
    }

    case rider_category_row(organization_id, gtfs_version_id, rider_id) do
      nil ->
        changeset =
          %RiderCategory{}
          |> RiderCategory.changeset(
            Map.merge(attrs, %{
              organization_id: organization_id,
              gtfs_version_id: gtfs_version_id
            })
          )

        case Repo.insert(changeset) do
          {:ok, row} ->
            {:ok,
             %{id: row.id, created?: true, action: "created", before: nil, after: attrs, row: row}}

          {:error, changeset} ->
            Repo.rollback(changeset)
        end

      row ->
        # An update leaves the flag alone unless the form asked to move the
        # default: a drawer that omits `:default?` is not un-defaulting a rider
        # type, and R8 would refuse the version if it were.
        attrs =
          if Map.has_key?(params, :default?) or Map.has_key?(params, "default?") do
            attrs
          else
            Map.delete(attrs, :is_default_fare_category)
          end

        case row |> RiderCategory.changeset(attrs) |> Repo.update() do
          {:ok, updated} ->
            {:ok,
             %{
               id: updated.id,
               created?: false,
               action: "updated",
               before: rider_attrs(row),
               after: rider_attrs(updated),
               row: updated
             }}

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
    end
  end

  defp rider_category_row(organization_id, gtfs_version_id, rider_id) do
    RiderCategory
    |> scoped(organization_id, gtfs_version_id)
    |> where([category], category.rider_category_id == ^rider_id)
    |> Repo.one()
  end

  # R8: exactly one rider type may be the default, so setting one clears the flag
  # on whichever held it — in this transaction, so a rollback takes both back.
  # The cleared row is the inverse, so undo puts the flag where it was. A create
  # moves the default too: the form's box is the same one either way.
  defp clear_previous_default(organization_id, gtfs_version_id, category, _params) do
    if category.after[:is_default_fare_category] == 1 do
      rider_id = category.after[:rider_category_id]

      previous =
        RiderCategory
        |> scoped(organization_id, gtfs_version_id)
        |> where(
          [row],
          row.is_default_fare_category == 1 and row.rider_category_id != ^rider_id
        )
        |> Repo.one()

      if previous do
        previous
        |> Ecto.Changeset.change(%{is_default_fare_category: 0})
        |> Repo.update!()

        {:ok, previous.rider_category_id}
      else
        {:ok, nil}
      end
    else
      {:ok, nil}
    end
  end

  # R8 stores the flag as 0 or 1 and `Normalize` counts the 1s, so a rider type
  # created without the drawer asking for the default stores 0 rather than nil:
  # the column is what the export writes and an empty cell there reads as
  # "unset" rather than "not the default". An update that says nothing about it
  # leaves it alone instead.
  defp default_flag(params) do
    case params do
      %{default?: true} -> 1
      %{"default?" => true} -> 1
      _other -> 0
    end
  end

  defp rider_attrs(row) do
    %{
      rider_category_id: row.rider_category_id,
      rider_category_name: row.rider_category_name,
      eligibility_url: row.eligibility_url,
      is_default_fare_category: row.is_default_fare_category
    }
  end

  defp rider_log_row(category, rows_written) do
    Map.merge(rider_attrs(category.row), %{"prices" => rows_written})
  end

  defp category_log_row(category, cleared) do
    rider_attrs(category.row)
    |> Map.put("default_moved_from", cleared)
  end

  defp rider_save_summary(params, name) do
    if fare_param(params, :rider_category_id) do
      "Updated the rider type \"#{name}\""
    else
      "Created the rider type \"#{name}\""
    end
  end

  defp rider_type_name(organization_id, gtfs_version_id, rider_id) do
    case rider_category_row(organization_id, gtfs_version_id, rider_id) do
      nil -> nil
      row -> row.rider_category_name
    end
  end

  # The starting prices a create writes (AC-17). Only a create has them: an
  # update's prices are the grid's to write, and a form that named one anyway
  # does not get to move every fare in the version.
  defp rider_starting_prices(organization_id, gtfs_version_id, rider_id, params, category) do
    if category.created? do
      case starting_choice(params) do
        {:ok, :blank} ->
          {:ok, %{states: [], rows_written: 0}}

        {:ok, choice} ->
          products = version_products(organization_id, gtfs_version_id)
          media = version_media(organization_id, gtfs_version_id)
          default_id = default_rider_id(organization_id, gtfs_version_id)

          changes =
            starting_price_changes(products, media, default_id, rider_id, choice)

          write_starting_prices(organization_id, gtfs_version_id, changes, products)

        {:error, reason} ->
          Repo.rollback(reason)
      end
    else
      {:ok, %{states: [], rows_written: 0}}
    end
  end

  defp starting_choice(params) do
    case fare_param(params, :starting) do
      nil -> {:ok, :blank}
      choice when choice in @starting_prices -> {:ok, choice}
      _other -> {:error, :invalid_starting_prices}
    end
  end

  # The starting rows go through the grid's own price writer, the way
  # `save_fare/2` writes its own rows, rather than through `apply_prices/3`: a
  # create has nothing to review and every cell it writes is one it has just
  # read, so there is no fence to check and no entry of its own to record (R15).
  # A refusal from that writer rolls the whole save back.
  defp write_starting_prices(_organization_id, _gtfs_version_id, [], _products) do
    {:ok, %{states: [], rows_written: 0}}
  end

  defp write_starting_prices(organization_id, gtfs_version_id, changes, products) do
    {:ok, written} = write_prices(organization_id, gtfs_version_id, changes, products)

    {:ok, %{states: written.inverse.fare_products, rows_written: length(changes)}}
  end

  # One cell per fare the version holds that the default rider type has a price
  # for, at the amount the chosen starting prices give (AC-17, R9). `:same` and
  # `:half` are the default's own amount and half of it to the nearest nickel;
  # `:free` is zero; a fare with no default-rider price gets no cell, because
  # there is nothing to start from.
  defp starting_price_changes(products, media, default_id, rider_id, choice) do
    products
    |> Enum.group_by(&fare_name/1)
    |> Enum.flat_map(fn {_name, rows} ->
      starting_cell(rows, media, default_id, rider_id, choice)
    end)
    |> Enum.sort_by(fn change -> change.key end)
  end

  # The new rider type's one row for one fare, taken from that fare's own row for
  # the default rider type. Which of the default's rows is the fare's own price is
  # R11's rule, the same one the older-format projection uses: the fare's
  # cash-medium (type 0) row, else the row naming no method, else its
  # lowest-ordered method. A fare the default rider type has no row for gets no
  # cell, because there is no price to start from.
  defp starting_cell(rows, media, default_id, rider_id, choice) do
    adult = rows |> Enum.filter(&(&1.rider_category_id == default_id)) |> base_row(media)

    case adult && starting_amount(adult.amount, choice) do
      nil ->
        []

      amount ->
        [
          %{
            key: {adult.fare_product_id, rider_id, adult.fare_media_id},
            reviewed: nil,
            amount: amount,
            name: adult.fare_product_name,
            currency: adult.currency || @default_currency
          }
        ]
    end
  end

  defp base_row([], _media), do: nil

  defp base_row(rows, media) do
    order = Map.new(media, &{&1.fare_media_id, &1.fare_media_type || 0})

    Enum.find(rows, &(Map.get(order, &1.fare_media_id, 99) == 0)) ||
      Enum.find(rows, &is_nil(&1.fare_media_id)) ||
      Enum.min_by(rows, &{Map.get(order, &1.fare_media_id, 99), &1.fare_media_id || ""})
  end

  # The version's own payment methods, in the order `build_media/1` reads them:
  # the GTFS type first, so cash (0) precedes an app (4).
  defp version_media(organization_id, gtfs_version_id) do
    FareMedia
    |> scoped(organization_id, gtfs_version_id)
    |> order_by([medium], asc: medium.fare_media_type, asc: medium.fare_media_id)
    |> Repo.all()
  end

  # What a new rider type's first row is for one fare: `:same` copies the fare's
  # own price for the default rider type, `:half` is half of it to the nearest
  # nickel, and `:free` is zero. A fare with no default-rider price has nothing
  # to start from, which is what answers `nil` and drops the row.
  defp starting_amount(nil, _choice), do: nil

  defp starting_amount(_amount, :free), do: Decimal.new(0)

  defp starting_amount(%Decimal{} = amount, :same), do: amount

  defp starting_amount(%Decimal{} = amount, :half) do
    amount
    |> Decimal.div(Decimal.new(2))
    |> Decimal.div(@nickel)
    |> Decimal.round(0)
    |> Decimal.mult(@nickel)
  end

  # Deleting a rider type takes its prices with it, so nothing names a rider type
  # that is gone. The rows go into the inverse whole, with the ids they had.
  defp remove_rider_type(organization_id, gtfs_version_id, rider_id, expected) do
    products = version_products(organization_id, gtfs_version_id)
    rows = Enum.filter(products, &(&1.rider_category_id == rider_id))

    case rider_category_row(organization_id, gtfs_version_id, rider_id) do
      nil ->
        {:error, :not_found}

      category ->
        if category.is_default_fare_category == 1 do
          {:error, :default_rider_type}
        else
          delete_rider_rows(organization_id, gtfs_version_id, rider_id, category, rows, expected)
        end
    end
  end

  defp delete_rider_rows(
         organization_id,
         gtfs_version_id,
         rider_id,
         category,
         rows,
         expected
       ) do
    case name_stale(expected, category.rider_category_name) do
      [] ->
        Repo.delete_all(
          from(row in FareProduct,
            where:
              row.organization_id == ^organization_id and
                row.gtfs_version_id == ^gtfs_version_id and
                row.rider_category_id == ^rider_id
          )
        )

        Repo.delete_all(
          from(row in RiderCategory,
            where:
              row.organization_id == ^organization_id and
                row.gtfs_version_id == ^gtfs_version_id and
                row.rider_category_id == ^rider_id
          )
        )

        {:ok,
         %{
           before: [
             rider_attrs(category) | Enum.map(rows, &log_row(product_key(&1), &1.amount))
           ],
           after: [],
           action: "deleted",
           inverse: %{
             operation: :delete,
             schema: RiderCategory,
             rider_category_id: rider_id,
             row: category,
             fare_products: Enum.map(rows, &row_snapshot/1)
           }
         }}

      stale ->
        {:error, {:stale, stale}}
    end
  end

  # -- Writing one payment method --------------------------------------------------

  defp apply_payment_method(organization_id, gtfs_version_id, name, params) do
    with {:ok, media_id} <- fare_media_id(organization_id, gtfs_version_id, name, params),
         {:ok, media_type} <- media_type(params),
         {:ok, medium} <-
           write_fare_media(organization_id, gtfs_version_id, media_id, name, media_type),
         {:ok, accepted} <-
           accepted_fare_product_ids(organization_id, gtfs_version_id, params),
         {:ok, prices} <-
           media_accepted_rows(organization_id, gtfs_version_id, media_id, medium, accepted) do
      {:ok,
       %{
         before: media_log_row(medium, prices.removed),
         after: media_log_row(medium, prices.added),
         action: medium.action,
         inverse: %{
           operation: :save,
           schema: FareMedia,
           fare_media_id: media_id,
           row: medium,
           fare_products: prices.states
         }
       }}
    end
  end

  defp fare_media_id(organization_id, gtfs_version_id, name, params) do
    case fare_param(params, :fare_media_id) do
      nil ->
        id = fare_slug(name)
        known = version_media_ids(organization_id, gtfs_version_id)

        cond do
          id == "" -> {:error, name_changeset(name, "must have a letter or a number")}
          MapSet.member?(known, id) -> {:error, :duplicate_payment_method}
          true -> {:ok, id}
        end

      "" ->
        {:error, :not_found}

      id when is_binary(id) ->
        if MapSet.member?(version_media_ids(organization_id, gtfs_version_id), id) do
          {:ok, id}
        else
          {:error, :not_found}
        end

      _other ->
        {:error, :not_found}
    end
  end

  # The five kinds GTFS gives a payment method. The drawer offers them as choice
  # cards, so a type outside them is a refusal rather than a changeset (AC-18).
  defp media_type(params) do
    case fare_param(params, :fare_media_type) do
      type when is_integer(type) and type in 0..4 -> {:ok, type}
      _other -> {:error, :invalid_media_type}
    end
  end

  defp write_fare_media(organization_id, gtfs_version_id, media_id, name, media_type) do
    attrs = %{fare_media_id: media_id, fare_media_name: name, fare_media_type: media_type}

    case media_row(organization_id, gtfs_version_id, media_id) do
      nil ->
        changeset =
          %FareMedia{}
          |> FareMedia.changeset(
            Map.merge(attrs, %{
              organization_id: organization_id,
              gtfs_version_id: gtfs_version_id
            })
          )

        case Repo.insert(changeset) do
          {:ok, row} ->
            {:ok,
             %{
               id: row.id,
               created?: true,
               action: "created",
               before: nil,
               after: media_attrs(row),
               row: row
             }}

          {:error, changeset} ->
            Repo.rollback(changeset)
        end

      row ->
        case row |> FareMedia.changeset(attrs) |> Repo.update() do
          {:ok, updated} ->
            {:ok,
             %{
               id: updated.id,
               created?: false,
               action: "updated",
               before: media_attrs(row),
               after: media_attrs(updated),
               row: updated
             }}

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
    end
  end

  defp media_row(organization_id, gtfs_version_id, media_id) do
    FareMedia
    |> scoped(organization_id, gtfs_version_id)
    |> where([medium], medium.fare_media_id == ^media_id)
    |> Repo.one()
  end

  defp media_attrs(row) do
    %{
      fare_media_id: row.fare_media_id,
      fare_media_name: row.fare_media_name,
      fare_media_type: row.fare_media_type
    }
  end

  defp media_log_row(medium, rows) do
    Map.merge(media_attrs(medium.row), %{"prices" => rows})
  end

  defp media_save_summary(params, name) do
    if fare_param(params, :fare_media_id) do
      "Updated the payment method \"#{name}\""
    else
      "Created the payment method \"#{name}\""
    end
  end

  defp media_name(organization_id, gtfs_version_id, media_id) do
    case media_row(organization_id, gtfs_version_id, media_id) do
      nil -> nil
      row -> row.fare_media_name
    end
  end

  # The fares the form says accept this method, each of which must be a fare
  # this version holds (INV-5). A fare is the group of `fare_products` rows
  # sharing a `fare_product_name` (the identity `load_workspace/2` and every
  # other writer here uses), so naming one of its product ids names the fare: the
  # drawer's checkbox is one per fare, and unticking it must stop the fare being
  # sold on this method rather than one of its four rider types.
  defp accepted_fare_product_ids(organization_id, gtfs_version_id, params) do
    named =
      params
      |> fare_param(:fare_product_ids)
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.uniq()

    products = version_products(organization_id, gtfs_version_id)

    known = products |> Enum.map(& &1.fare_product_id) |> MapSet.new()

    if Enum.all?(named, &MapSet.member?(known, &1)) do
      {:ok, fare_product_ids_for(products, MapSet.new(named))}
    else
      {:error, :not_found}
    end
  end

  # Every `fare_product_id` of the fares the drawer ticked, which is every row of
  # every product id that shares a ticked one's `fare_product_name`.
  defp fare_product_ids_for(products, named) do
    names =
      products
      |> Enum.filter(&MapSet.member?(named, &1.fare_product_id))
      |> Enum.map(&fare_name/1)
      |> MapSet.new()

    products
    |> Enum.filter(&MapSet.member?(names, fare_name(&1)))
    |> Enum.map(& &1.fare_product_id)
    |> MapSet.new()
  end

  # AC-18: a fare that accepts a payment method is sold on it, at the price that
  # method's rider would pay on board. Every rider type the fare has a cash-medium
  # price for gets a row on this medium at that amount; a fare that stops
  # accepting it has those rows deleted, because a method a fare does not accept
  # is a missing row rather than a zero (R9). A fare with no cash-medium price has
  # nothing to copy and is priced by opening the fare, which is what the drawer
  # says next to the checkbox.
  defp media_accepted_rows(organization_id, gtfs_version_id, media_id, _medium, accepted) do
    products = version_products(organization_id, gtfs_version_id)
    cash_ids = cash_media_ids(version_media(organization_id, gtfs_version_id))

    changes =
      for row <- products,
          row.fare_media_id in cash_ids,
          change =
            media_change(products, row, media_id, MapSet.member?(accepted, row.fare_product_id)),
          change != nil,
          do: change

    write_media_prices(organization_id, gtfs_version_id, media_id, changes, products)
  end

  defp write_media_prices(_organization_id, _gtfs_version_id, _media_id, [], _products) do
    {:ok, %{states: [], added: 0, removed: 0}}
  end

  defp write_media_prices(organization_id, gtfs_version_id, _media_id, changes, products) do
    {:ok, written} = write_prices(organization_id, gtfs_version_id, changes, products)

    {:ok,
     %{
       states: written.inverse.fare_products,
       added: length(changes),
       removed: Enum.count(written.inverse.fare_products, &match?(%{after: nil}, &1))
     }}
  end

  # The cash-medium (type 0) methods of this version, which is the price a rider
  # pays on board and therefore the price another method starts at (AC-18).
  defp cash_media_ids(media) do
    for row <- media, row.fare_media_type == 0, do: row.fare_media_id
  end

  # A fare that accepts the method gets a row at its own cash-medium price; a fare
  # that does not has its rows on that medium deleted, because a method a fare
  # does not accept is a missing row rather than a zero (R9).
  #
  # A fare that already has a row on this medium is left alone whichever way its
  # checkbox stands: the amount there is the fare's own per-medium price, which
  # is what the fare drawer wrote and what AC-18 keeps, and a method the version
  # already sells on a fare is not something this writer re-prices. Only the rows
  # this writer created — the ones that simply copy the cash price — are the
  # cells it may add or remove.
  defp media_change(products, cash_row, media_id, accepted) do
    existing =
      Enum.find(products, fn row ->
        row.fare_product_id == cash_row.fare_product_id and
          row.rider_category_id == cash_row.rider_category_id and
          row.fare_media_id == media_id
      end)

    case {accepted, existing} do
      {true, nil} -> media_cell(cash_row, media_id, cash_row.amount)
      {false, nil} -> nil
      {true, _row} -> nil
      {false, _row} -> media_cell(cash_row, media_id, nil)
    end
  end

  defp media_cell(row, media_id, amount) do
    %{
      key: {row.fare_product_id, row.rider_category_id, media_id},
      reviewed: nil,
      amount: amount,
      name: row.fare_product_name,
      currency: row.currency || @default_currency
    }
  end

  # Deleting a payment method takes its prices with it, so nothing names a method
  # that is gone. The rows go into the inverse whole, with the ids they had.
  defp remove_payment_method(organization_id, gtfs_version_id, media_id, expected) do
    products = version_products(organization_id, gtfs_version_id)
    rows = Enum.filter(products, &(&1.fare_media_id == media_id))

    case media_row(organization_id, gtfs_version_id, media_id) do
      nil ->
        {:error, :not_found}

      medium ->
        case name_stale(expected, medium.fare_media_name) do
          [] ->
            Repo.delete_all(
              from(row in FareProduct,
                where:
                  row.organization_id == ^organization_id and
                    row.gtfs_version_id == ^gtfs_version_id and
                    row.fare_media_id == ^media_id
              )
            )

            Repo.delete_all(
              from(row in FareMedia,
                where:
                  row.organization_id == ^organization_id and
                    row.gtfs_version_id == ^gtfs_version_id and
                    row.fare_media_id == ^media_id
              )
            )

            {:ok,
             %{
               before: [
                 media_attrs(medium) | Enum.map(rows, &log_row(product_key(&1), &1.amount))
               ],
               after: [],
               action: "deleted",
               inverse: %{
                 operation: :delete,
                 schema: FareMedia,
                 fare_media_id: media_id,
                 row: medium,
                 fare_products: Enum.map(rows, &row_snapshot/1)
               }
             }}

          stale ->
            {:error, {:stale, stale}}
        end
    end
  end

  # -- Writing one route group ----------------------------------------------------

  @doc """
  Creates or updates one route group: its name and the routes in it (AC-19).

  `params` is the route group drawer's own form:

      %{name: String.t(),
        network_id: String.t() | nil,
        route_ids: [String.t()]}

  A form with no `network_id` creates a route group, whose GTFS id is its name
  as an id — `Coast routes` is `coast_routes` — and a name whose id this version
  already holds answers `{:error, :duplicate_route_group}`. A form naming a
  `network_id` updates that group and answers `{:error, :not_found}` when this
  version holds no such group, which is what another organization's or
  version's id is here (INV-5).

  A blank name answers `{:error, changeset}` with an error on `:name`, because a
  route group the drawer cannot name is not one an operator can find again —
  the same refusal a fare, a rider type and a payment method give.

  `route_ids` is the whole set of routes in the group, and a route the form does
  not name is removed from it, because a group is the routes it holds rather
  than a list an editor adds to. A `route_id` this version does not hold answers
  `{:error, :not_found}`: the drawer offers this version's routes, and a route of
  another version is never written into this one's `route_networks` (INV-5).

  A route is in at most one group (AC-19), so a route this group takes is
  deleted from whatever group held it, and the answer carries
  `moved: [%{route_id, from_network_id}]` naming each one, which is what the
  drawer's "moving routes" warning states. The stored `routes.network_id` column
  of an imported version is not touched (INV-3): a managed version exports
  `route_networks.txt` and drops that column, so this writer is where a managed
  version's route-to-group map lives.

  Rules are not this writer's to change. A leg rule, a transfer rule and a
  pass's `accepted_network_ids` name a group by its id, and a group's id does not
  move when the group is renamed — only `networks.network_name` is written here.
  """
  @spec save_route_group(scope(), map()) :: write_result()
  def save_route_group(
        %{organization_id: organization_id, gtfs_version_id: gtfs_version_id} = scope,
        params
      )
      when is_map(params) do
    case trimmed_name(params) do
      {:ok, name} ->
        write(scope, route_group_save_summary(params, name), @group_inverse, fn _setting ->
          apply_route_group(organization_id, gtfs_version_id, name, params)
        end)

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Deletes one route group with the rules and passes that named it (AC-19).

  A group its own `fare_leg_rules` or `fare_transfer_rules` reference answers
  `{:error, :rules_reference_group}`, and a group a pass accepts through its
  `accepted_network_ids` answers `{:error, :group_accepted_by_pass}`: deleting
  either would leave rows naming a group that is gone, which is not a state the
  rest of this package can read. Both are settled by `expected[:remove_rules]`:

  - `true` deletes the leg rules of that group and the transfer rules naming it
    in either direction, which leaves the cells they priced with no fare — the
    Where tab's gap, the same shape `delete_fare/4`'s `:remove_rules` leaves;
  - the group's id is dropped from the `accepted_network_ids` of every pass that
    accepted it, so no pass is left accepting a group that is not there.

  A group named by nothing is deleted with either. The group's own
  `route_networks` rows and its `networks` row are deleted with it and go into
  the inverse whole — with the ids they had, beside the rules and the pass
  acceptances the write settled — so `undo/3` puts all of it back as it was.

  `expected` is the fence, and carries the `:name` the editor reviewed beside
  the `:remove_rules` choice: a group renamed since the drawer opened answers
  `{:error, {:stale, details}}` and deletes nothing (R15).

  A group of another organization or another version answers
  `{:error, :not_found}`, a version that is not published answers the same, and
  an unmanaged version answers `{:error, :unmanaged}` (R12).
  """
  @spec delete_route_group(scope(), String.t(), map()) :: write_result()
  def delete_route_group(
        %{organization_id: organization_id, gtfs_version_id: gtfs_version_id} = scope,
        network_id,
        expected
      )
      when is_binary(network_id) and is_map(expected) do
    summary =
      "Deleted the route group \"#{route_group_name(organization_id, gtfs_version_id, network_id) || network_id}\""

    write(scope, summary, @group_inverse, fn _setting ->
      remove_route_group(organization_id, gtfs_version_id, network_id, expected)
    end)
  end

  defp apply_route_group(organization_id, gtfs_version_id, name, params) do
    networks = version_networks(organization_id, gtfs_version_id)

    with {:ok, network_id} <- route_group_id(networks, name, params),
         {:ok, network} <- write_network(organization_id, gtfs_version_id, network_id, name),
         {:ok, routes} <- route_group_routes(organization_id, gtfs_version_id, params),
         {:ok, membership} <-
           write_route_membership(organization_id, gtfs_version_id, network_id, routes) do
      {:ok,
       %{
         before:
           route_group_log_row(
             network.before,
             Enum.map(membership.removed, & &1.route_id),
             Enum.map(membership.moved, &moved_log_row/1)
           ),
         after:
           route_group_log_row(
             network.after,
             membership.route_ids,
             Enum.map(membership.moved, &moved_log_row/1)
           ),
         action: network.action,
         reported: %{moved: Enum.map(membership.moved, &moved_report(&1))},
         inverse: %{
           operation: :save,
           network: network,
           route_networks: %{
             added: membership.added,
             removed: membership.removed,
             moved: membership.moved
           }
         }
       }}
    end
  end

  # The GTFS id of the route group the form names: its name as an id when the form
  # creates one, refused when this version already holds it, and the id the form
  # named when it edits one. An id of another version is `:not_found` (INV-5),
  # the same answer a fare, a rider type and a payment method give.
  defp route_group_id(networks, name, params) do
    case fare_param(params, :network_id) do
      nil ->
        id = fare_slug(name)

        cond do
          id == "" -> {:error, name_changeset(name, "must have a letter or a number")}
          Enum.any?(networks, &(&1.network_id == id)) -> {:error, :duplicate_route_group}
          true -> {:ok, id}
        end

      "" ->
        {:error, :not_found}

      id when is_binary(id) ->
        if Enum.any?(networks, &(&1.network_id == id)) do
          {:ok, id}
        else
          {:error, :not_found}
        end

      _other ->
        {:error, :not_found}
    end
  end

  defp version_networks(organization_id, gtfs_version_id) do
    Network
    |> scoped(organization_id, gtfs_version_id)
    |> order_by([network], network.network_id)
    |> Repo.all()
  end

  defp network_row(organization_id, gtfs_version_id, network_id) do
    Network
    |> scoped(organization_id, gtfs_version_id)
    |> where([network], network.network_id == ^network_id)
    |> Repo.one()
  end

  defp route_group_name(organization_id, gtfs_version_id, network_id) do
    case network_row(organization_id, gtfs_version_id, network_id) do
      nil -> nil
      network -> network.network_name
    end
  end

  # The one `networks` row, written through its own changeset. Only the name is an
  # operator's to edit here: the id is what every leg rule, transfer rule and
  # accepted pass names, and renaming a group leaves those naming the same group.
  defp write_network(organization_id, gtfs_version_id, network_id, name) do
    attrs = %{network_id: network_id, network_name: name}

    case network_row(organization_id, gtfs_version_id, network_id) do
      nil ->
        changeset =
          %Network{}
          |> Network.changeset(
            Map.merge(attrs, %{
              organization_id: organization_id,
              gtfs_version_id: gtfs_version_id
            })
          )

        case Repo.insert(changeset) do
          {:ok, row} ->
            {:ok, %{id: row.id, action: "created", before: nil, after: attrs, row: row}}

          {:error, changeset} ->
            Repo.rollback(changeset)
        end

      row ->
        case row |> Network.changeset(%{network_name: name}) |> Repo.update() do
          {:ok, updated} ->
            {:ok,
             %{
               id: updated.id,
               action: "updated",
               before: network_attrs(row),
               after: network_attrs(updated),
               row: updated
             }}

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
    end
  end

  defp network_attrs(row) do
    %{network_id: row.network_id, network_name: row.network_name}
  end

  # The routes the drawer put in the group, checked against the version's own
  # routes. A `route_id` this version does not hold is `:not_found`, which is
  # what another version's route is here (INV-5).
  defp route_group_routes(organization_id, gtfs_version_id, params) do
    named =
      case fare_param(params, :route_ids) do
        ids when is_list(ids) -> ids
        _other -> []
      end

    routes =
      named
      |> Enum.filter(&is_binary/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.sort()

    known = version_route_ids(organization_id, gtfs_version_id)

    if Enum.all?(routes, &MapSet.member?(known, &1)) do
      {:ok, routes}
    else
      {:error, :not_found}
    end
  end

  defp version_route_ids(organization_id, gtfs_version_id) do
    Route
    |> scoped(organization_id, gtfs_version_id)
    |> select([route], route.route_id)
    |> Repo.all()
    |> MapSet.new()
  end

  # The `route_networks` rows this group holds, and the routes it takes out of
  # another group. AC-19: a route is in at most one group, so a route this group
  # takes has the row it had elsewhere deleted in the same transaction, and the
  # answer says which route came from which group.
  defp write_route_membership(organization_id, gtfs_version_id, network_id, routes) do
    rows = version_route_networks(organization_id, gtfs_version_id)
    mine = Enum.filter(rows, &(&1.network_id == network_id))
    elsewhere = Enum.filter(rows, &(&1.network_id != network_id))
    wanted = MapSet.new(routes)

    removed = Enum.reject(mine, &MapSet.member?(wanted, &1.route_id))
    added = Enum.reject(routes, &Enum.any?(mine, fn row -> row.route_id == &1 end))
    moved = Enum.filter(elsewhere, &MapSet.member?(wanted, &1.route_id))

    delete_rows(RouteNetwork, organization_id, gtfs_version_id, removed ++ moved)
    added = insert_route_networks(organization_id, gtfs_version_id, network_id, added)

    {:ok,
     %{
       added: added,
       removed: removed,
       moved: moved,
       route_ids: routes
     }}
  end

  defp version_route_networks(organization_id, gtfs_version_id) do
    RouteNetwork
    |> scoped(organization_id, gtfs_version_id)
    |> order_by([row], row.route_id)
    |> Repo.all()
  end

  # `insert_all/3` answers `{count, rows}`; the rows themselves are what the
  # inverse restores, with the ids they were given.
  defp insert_route_networks(_organization_id, _gtfs_version_id, _network_id, []), do: []

  defp insert_route_networks(organization_id, gtfs_version_id, network_id, route_ids) do
    now = DateTime.utc_now()

    rows =
      Enum.map(route_ids, fn route_id ->
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id,
          network_id: network_id,
          route_id: route_id,
          inserted_at: now,
          updated_at: now
        }
      end)

    {_count, inserted} = Repo.insert_all(RouteNetwork, rows, returning: true)
    inserted
  end

  # Deleting by the rows' own ids, re-asserting the version pair, so a row that
  # moved between versions is never deleted through this path (INV-5).
  defp delete_rows(schema, organization_id, gtfs_version_id, rows) do
    case Enum.map(rows, & &1.id) do
      [] ->
        :ok

      ids ->
        Repo.delete_all(
          from(row in schema,
            where:
              row.organization_id == ^organization_id and
                row.gtfs_version_id == ^gtfs_version_id and row.id in ^ids
          )
        )
    end
  end

  defp moved_report(row), do: %{route_id: row.route_id, from_network_id: row.network_id}

  defp moved_log_row(row) do
    %{"route_id" => row.route_id, "from_network_id" => row.network_id}
  end

  # The change-log rows of one route group write: the group's own id and name
  # beside the routes it holds now and the routes it moved. A group the version
  # did not hold has no before, because there was nothing to state.
  defp route_group_log_row(nil, _route_ids, _moved), do: nil

  defp route_group_log_row(attrs, route_ids, moved) do
    %{
      "network_id" => attrs.network_id,
      "network_name" => attrs.network_name,
      "routes" => route_ids,
      "moved" => moved
    }
  end

  defp route_group_save_summary(params, name) do
    if fare_param(params, :network_id) do
      "Updated the route group \"#{name}\""
    else
      "Created the route group \"#{name}\""
    end
  end

  # -- Deleting one route group ----------------------------------------------------

  # The `fare_product_details.kind` of a pass, which is what a route group a pass
  # still accepts is read out of.
  @pass_kind "pass"

  defp remove_route_group(organization_id, gtfs_version_id, network_id, expected) do
    case network_row(organization_id, gtfs_version_id, network_id) do
      nil ->
        {:error, :not_found}

      network ->
        case name_stale(expected, network.network_name) do
          [] -> settle_route_group_references(organization_id, gtfs_version_id, network, expected)
          stale -> {:error, {:stale, stale}}
        end
    end
  end

  # What named this group, and what the operator asked to do about it. A group a
  # rule or a pass names is refused unless the drawer asked for the references to
  # be settled, because deleting a group out from under them leaves rows naming
  # something that is gone.
  defp settle_route_group_references(organization_id, gtfs_version_id, network, expected) do
    rules = group_rules(organization_id, gtfs_version_id, network.network_id)
    passes = accepting_passes(organization_id, gtfs_version_id, network.network_id)

    cond do
      rules != [] and not remove_rules?(expected) -> {:error, :rules_reference_group}
      passes != [] and not remove_rules?(expected) -> {:error, :group_accepted_by_pass}
      true -> delete_group_rows(organization_id, gtfs_version_id, network, rules, passes)
    end
  end

  defp remove_rules?(expected) do
    fare_param(expected, :remove_rules) == true
  end

  # The rules of a delete, split by the table they live in: a `fare_leg_rules`
  # row and a `fare_transfer_rules` row are different rows that happen to name
  # the same group, and each is deleted from its own table.
  defp leg_rule_rows(rules), do: Enum.filter(rules, &match?(%FareLegRule{}, &1))

  defp transfer_rule_rows(rules), do: Enum.filter(rules, &match?(%FareTransferRule{}, &1))

  # The version's own rules naming this group: a leg rule through the network the
  # operator chose, and a transfer rule through either leg group. `leg_group_id`
  # is not read here because it is Normalize's column (INV-4) and says the same
  # thing about a leg rule.
  defp group_rules(organization_id, gtfs_version_id, network_id) do
    leg_rules =
      FareLegRule
      |> scoped(organization_id, gtfs_version_id)
      |> where([rule], rule.network_id == ^network_id)
      |> Repo.all()

    transfer_rules =
      FareTransferRule
      |> scoped(organization_id, gtfs_version_id)
      |> where(
        [rule],
        rule.from_leg_group_id == ^network_id or rule.to_leg_group_id == ^network_id
      )
      |> Repo.all()

    leg_rules ++ transfer_rules
  end

  defp accepting_passes(organization_id, gtfs_version_id, network_id) do
    FareProductDetail
    |> scoped(organization_id, gtfs_version_id)
    |> where([detail], detail.kind == ^@pass_kind)
    |> Repo.all()
    |> Enum.filter(fn detail ->
      network_id in (detail.accepted_network_ids || [])
    end)
  end

  defp delete_group_rows(organization_id, gtfs_version_id, network, rules, passes) do
    membership =
      Enum.filter(
        version_route_networks(organization_id, gtfs_version_id),
        &(&1.network_id == network.network_id)
      )

    delete_rows(FareLegRule, organization_id, gtfs_version_id, leg_rule_rows(rules))
    delete_rows(FareTransferRule, organization_id, gtfs_version_id, transfer_rule_rows(rules))
    delete_rows(RouteNetwork, organization_id, gtfs_version_id, membership)
    delete_rows(Network, organization_id, gtfs_version_id, [network])
    states = unaccept_route_group(organization_id, gtfs_version_id, passes, network.network_id)

    {:ok,
     %{
       before:
         route_group_log_row(
           network_attrs(network),
           Enum.map(membership, & &1.route_id),
           []
         )
         |> Map.merge(%{
           "rules_removed" => Enum.map(rules, & &1.id),
           "passes_updated" => Enum.map(states, & &1.fare_product_id)
         }),
       after: [],
       action: "deleted",
       inverse: %{
         operation: :delete,
         network: network,
         route_networks: membership,
         rules: rules,
         passes: states
       }
     }}
  end

  # A pass no longer accepts a group that is gone. R4's mirror is rebuilt by the
  # `Normalize.run!/2` this transaction runs, so dropping the id is enough: no
  # pass row of a group that no longer exists is written back.
  defp unaccept_route_group(organization_id, gtfs_version_id, passes, network_id) do
    now = DateTime.utc_now()

    Enum.map(passes, fn pass ->
      accepted = pass.accepted_network_ids -- [network_id]

      from(detail in FareProductDetail,
        where:
          detail.id == ^pass.id and detail.organization_id == ^organization_id and
            detail.gtfs_version_id == ^gtfs_version_id
      )
      |> Repo.update_all(set: [accepted_network_ids: accepted, updated_at: now])

      %{
        id: pass.id,
        fare_product_id: pass.fare_product_id,
        before: pass.accepted_network_ids,
        after: accepted
      }
    end)
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  # -- Setting one zone fare -------------------------------------------------------

  @doc """
  Sets or clears one cell of a route group's zone fare matrix (AC-20).

  A cell is one `(network_id, from_area_id, to_area_id)` pair, and it names a
  *fare* rather than a product: the matrix shows a fare's adult price and says
  the other rider types follow the Prices tab, which is true of the stored rows
  because one fare is one `fare_products` row per rider type and payment method
  and one `fare_leg_rules` row per rider. So `fare_product_id` may be any
  product of the fare, or the fare's id as `save_fare/2` derives it from its name
  (`Valley-coast ride` is `valley_coast_ride`), and every one of the fare's
  products is written to the cell.

  `both?` writes the reverse cell as well, which the cell dialog offers only for
  a pair of different zones. A pass answers `{:error, :pass_fare}`: a pass is
  sold, not applied to a single ride, and its leg rules are mirrored by
  `Fares.Normalize` from the networks it accepts (R4, INV-4).

  A `fare_product_id` of `nil` clears the cell: its rules go, and so do the pass
  rows that mirrored them, because `Normalize.run!/2` rebuilds every pass row
  from the single-ride rules that are left. A cell already holding no fare
  answers `{:ok, ...}` with nothing written, so a dialog opened on a gap and
  saved unchanged is not an error.

  `reviewed` is the cell's product list as the matrix showed it, and a cell
  whose rules have changed since answers `{:error, {:stale, details}}` and writes
  nothing (R15). `nil` is no fence, which is what a create is.

  A `network_id` or a zone this version does not hold answers
  `{:error, :not_found}`, so another organization's or version's ids are never
  written into this one's rules (INV-5). An unmanaged version answers
  `{:error, :unmanaged}` and a pair that is not a published version of that
  organization answers the same.
  """
  @spec set_zone_fare(
          scope(),
          String.t(),
          String.t(),
          String.t(),
          String.t() | nil,
          boolean(),
          [String.t()] | nil
        ) :: write_result()
  def set_zone_fare(
        %{organization_id: organization_id, gtfs_version_id: gtfs_version_id} = scope,
        network_id,
        from,
        to,
        fare_product_id,
        both?,
        reviewed
      )
      when is_binary(network_id) and is_binary(from) and is_binary(to) and is_boolean(both?) do
    summary =
      zone_fare_summary(
        organization_id,
        gtfs_version_id,
        network_id,
        from,
        to,
        fare_product_id,
        both?
      )

    write(scope, summary, @rule_inverse, fn _setting ->
      apply_zone_fare(
        organization_id,
        gtfs_version_id,
        network_id,
        from,
        to,
        fare_product_id,
        both?,
        reviewed
      )
    end)
  end

  # A cell is one `network_id`/`from_area_id`/`to_area_id` triple, and its rules
  # are every non-pass row of that triple whatever its timeframe: the matrix
  # draws one cell per pair, and a write that left a timed rule behind would
  # disagree with the cell the read model shows.
  defp apply_zone_fare(
         organization_id,
         gtfs_version_id,
         network_id,
         from,
         to,
         fare_product_id,
         both?,
         reviewed
       ) do
    with {:ok, cells} <- zone_cells(organization_id, gtfs_version_id, network_id, from, to, both?),
         {:ok, product_ids} <-
           zone_fare_products(organization_id, gtfs_version_id, fare_product_id),
         :ok <- require_cell_unchanged(organization_id, gtfs_version_id, cells, reviewed),
         {:ok, written} <- write_cells(organization_id, gtfs_version_id, cells, product_ids) do
      {:ok,
       %{
         before: rule_log_rows(written.removed),
         after: rule_log_rows(written.added),
         action: "updated",
         inverse: %{operation: :save, rules: written}
       }}
    end
  end

  # The cells one write touches: the one the dialog was opened on, and the
  # reverse one when `both?` is set for a pair of different zones. A network and
  # a zone this version does not hold are `:not_found` (INV-5), and a zone is
  # checked against the version's own `areas` rows and the areas its rules name,
  # which is the inventory AC-24 measures leg rules against.
  defp zone_cells(organization_id, gtfs_version_id, network_id, from, to, both?) do
    with :ok <- require_network(organization_id, gtfs_version_id, network_id),
         :ok <- require_zones(organization_id, gtfs_version_id, [from, to]) do
      cell = %{network_id: network_id, from_area_id: from, to_area_id: to}

      reverse =
        if both? and from != to do
          [%{network_id: network_id, from_area_id: to, to_area_id: from}]
        else
          []
        end

      {:ok, [cell | reverse]}
    end
  end

  defp require_network(organization_id, gtfs_version_id, network_id) do
    case network_row(organization_id, gtfs_version_id, network_id) do
      nil -> {:error, :not_found}
      _network -> :ok
    end
  end

  defp require_zones(organization_id, gtfs_version_id, zones) do
    known = version_area_ids(organization_id, gtfs_version_id)
    if Enum.all?(zones, &MapSet.member?(known, &1)), do: :ok, else: {:error, :not_found}
  end

  defp version_area_ids(organization_id, gtfs_version_id) do
    Area
    |> scoped(organization_id, gtfs_version_id)
    |> select([area], area.area_id)
    |> Repo.all()
    |> Kernel.++(scoped_leg_rules(organization_id, gtfs_version_id) |> Enum.flat_map(&area_ids/1))
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> MapSet.new()
  end

  defp area_ids(rule) do
    [rule.from_area_id, rule.to_area_id]
  end

  # The products a cell write writes, which is the whole fare: `nil` clears the
  # cell and writes none, and a pass is refused because its rows are Normalize's
  # (R4, INV-4).
  defp zone_fare_products(_organization_id, _gtfs_version_id, nil), do: {:ok, []}

  defp zone_fare_products(organization_id, gtfs_version_id, fare_product_id)
       when is_binary(fare_product_id) do
    products = version_products(organization_id, gtfs_version_id)

    case fare_name_for(products, fare_product_id) do
      nil ->
        {:error, :not_found}

      name ->
        if MapSet.member?(version_pass_ids(organization_id, gtfs_version_id), fare_product_id) do
          {:error, :pass_fare}
        else
          {:ok, fare_product_ids(products, name)}
        end
    end
  end

  defp zone_fare_products(_organization_id, _gtfs_version_id, _other), do: {:error, :not_found}

  defp zone_fare_summary(_organization_id, _gtfs_version_id, network_id, from, to, nil, _both?) do
    "Removed the fare for rides from #{from} to #{to} in #{network_id}"
  end

  defp zone_fare_summary(
         organization_id,
         gtfs_version_id,
         network_id,
         from,
         to,
         fare_product_id,
         both?
       ) do
    products = version_products(organization_id, gtfs_version_id)
    name = fare_name_for(products, fare_product_id)

    direction = if both? and from != to, do: " and back", else: ""

    "Set the fare for rides from #{from} to #{to}#{direction} in #{network_id} to #{name}"
  end

  # The fence: every cell's stored rules must still be the products the matrix
  # showed. `nil` is a create and has nothing to be stale against.
  defp require_cell_unchanged(_organization_id, _gtfs_version_id, _cells, nil), do: :ok

  defp require_cell_unchanged(organization_id, gtfs_version_id, cells, reviewed)
       when is_list(reviewed) do
    stale =
      Enum.flat_map(cells, fn cell ->
        stored = cell_products(organization_id, gtfs_version_id, cell)

        if stored == Enum.sort(Enum.uniq(reviewed)) do
          []
        else
          [%{field: :products, reviewed: Enum.sort(Enum.uniq(reviewed)), stored: stored}]
        end
      end)

    case stale do
      [] -> :ok
      stale -> {:error, {:stale, stale}}
    end
  end

  defp require_cell_unchanged(_organization_id, _gtfs_version_id, _cells, _other),
    do: {:error, :not_found}

  # The cells' own rules go and the fare's products are written in their place.
  # The rows are read before the delete, so the inverse carries each removed row
  # whole and each added row's id, which is what `undo/3` needs to put the cell
  # back as it was.
  defp write_cells(organization_id, gtfs_version_id, cells, product_ids) do
    rules = scoped_leg_rules(organization_id, gtfs_version_id)
    pass_ids = version_pass_ids(organization_id, gtfs_version_id)

    Enum.reduce(cells, %{removed: [], added: []}, fn cell, written ->
      current = cell_rule_rows(rules, cell, pass_ids)

      kept = Enum.filter(current, &(&1.fare_product_id in product_ids))
      removed_rows = current -- kept
      wanted = Enum.uniq(product_ids -- Enum.map(kept, & &1.fare_product_id))

      inserted = insert_leg_rules(organization_id, gtfs_version_id, cell, wanted)
      delete_rows(FareLegRule, organization_id, gtfs_version_id, removed_rows)

      %{
        removed: written.removed ++ Enum.map(removed_rows, &row_snapshot/1),
        added: written.added ++ inserted
      }
    end)
    |> then(&{:ok, &1})
  end

  # The non-pass rules of one cell. A cell is a triple, not a set of conditions
  # with a timeframe, so a timed rule at the same pair is part of the cell: the
  # read model draws one cell per pair and a write that left a timed rule behind
  # would disagree with it.
  defp cell_rule_rows(rules, cell, pass_ids) do
    Enum.filter(rules, fn rule ->
      not MapSet.member?(pass_ids, rule.fare_product_id) and
        rule.network_id == cell.network_id and rule.from_area_id == cell.from_area_id and
        rule.to_area_id == cell.to_area_id
    end)
  end

  defp cell_products(organization_id, gtfs_version_id, cell) do
    rules = scoped_leg_rules(organization_id, gtfs_version_id)
    pass_ids = version_pass_ids(organization_id, gtfs_version_id)

    rules
    |> cell_rule_rows(cell, pass_ids)
    |> Enum.map(& &1.fare_product_id)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # One `fare_leg_rules` row per product of the fare, written with the conditions
  # the operator's own columns state. `rule_priority`, `leg_group_id` and
  # `to_timeframe_group_id` are left for `Fares.Normalize.run!/2`, which is their
  # only writer (R3, INV-4) and which runs inside this same transaction
  # (INV-1).
  defp insert_leg_rules(_organization_id, _gtfs_version_id, _cell, []), do: []

  defp insert_leg_rules(organization_id, gtfs_version_id, cell, product_ids) do
    now = DateTime.utc_now()

    rows =
      Enum.map(product_ids, fn product_id ->
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id,
          network_id: cell.network_id,
          from_area_id: cell.from_area_id,
          to_area_id: cell.to_area_id,
          from_timeframe_group_id: cell[:from_timeframe_group_id],
          to_timeframe_group_id: nil,
          fare_product_id: product_id,
          inserted_at: now,
          updated_at: now
        }
      end)

    {_count, inserted} = Repo.insert_all(FareLegRule, rows, returning: true)
    inserted
  end

  # -- Writing, deleting and undoing fare rules -----------------------------------

  @doc """
  Creates or updates the fare rule of one set of conditions (AC-20).

  `params` is the rule drawer's own form:

      %{rule_id: String.t() | nil,
        network_id: String.t() | nil,
        from_area_id: String.t() | nil,
        to_area_id: String.t() | nil,
        from_timeframe_group_id: String.t() | nil,
        fare_product_id: String.t(),
        both?: boolean(),
        reviewed: [String.t()] | nil}

  Unlike a matrix cell, a rule may name any condition or none: a `network_id`,
  a departure area, an arrival area and a time period are each `nil` for "any",
  which is what an operator writing a group-wide or all-day rule means. A blank
  string is that `nil`. A time period this version does not hold answers
  `{:error, :not_found}`.

  `fare_product_id` names a fare the same way `set_zone_fare/7`'s does, and a
  pass answers `{:error, :pass_fare}` (R4, INV-4).

  A conditions set that already names a *different* fare is an overlap, because
  a rider can only be charged one single-ride fare for one ride. `overlap` of
  `nil` answers `{:error, {:overlap, rule}}`, naming the rule that would
  collide, so the drawer can offer the choice; `:replace` writes the new fare
  over that rule and `:keep_both` leaves it and adds the new one beside it.
  Another rider type or payment method of the *same* fare is not an overlap: it
  is the same fare, and the four rules an imported cell carries are one fare
  rather than four.

  `reviewed` is the product list the rule list showed for these conditions, and
  conditions that have changed since answer `{:error, {:stale, details}}` and
  write nothing (R15). `rule_id` names the rule being edited — any one of its
  rows — and its rules go before the new ones are written, so an edit replaces
  rather than adds.
  """
  @spec save_rule(scope(), map(), :replace | :keep_both | nil) ::
          write_result() | {:error, {:overlap, FareLegRule.t()}}
  def save_rule(
        %{organization_id: organization_id, gtfs_version_id: gtfs_version_id} = scope,
        params,
        overlap \\ nil
      )
      when is_map(params) and overlap in [:replace, :keep_both, nil] do
    summary = rule_save_summary(organization_id, gtfs_version_id, params)

    write(scope, summary, @rule_inverse, fn _setting ->
      apply_rule(organization_id, gtfs_version_id, params, overlap)
    end)
  end

  @doc """
  Deletes one fare rule (AC-20).

  `rule_id` names any one of the rules' rows and the whole rule goes, because a
  rule is one fare over one set of conditions and half of it would leave a cell
  priced for one rider type and not another. A row whose fare is a pass answers
  `{:error, :pass_rule}`: `Fares.Normalize` writes every pass row from the
  networks its fare accepts (R4, INV-4), so deleting one would be undone by the
  next write of any kind.

  `expected` is the fence and carries the `:fare_product_id` the rule list
  showed; a rule whose product has moved since answers
  `{:error, {:stale, details}}` and deletes nothing (R15). A rule of another
  organization or another version answers `{:error, :not_found}`.
  """
  @spec delete_rule(scope(), String.t(), map()) :: write_result()
  def delete_rule(
        %{organization_id: organization_id, gtfs_version_id: gtfs_version_id} = scope,
        rule_id,
        expected
      )
      when is_binary(rule_id) and is_map(expected) do
    summary = rule_delete_summary(organization_id, gtfs_version_id, rule_id)

    write(scope, summary, @rule_inverse, fn _setting ->
      remove_rule(organization_id, gtfs_version_id, rule_id, expected)
    end)
  end

  defp apply_rule(organization_id, gtfs_version_id, params, overlap) do
    with {:ok, conditions} <- rule_conditions(organization_id, gtfs_version_id, params),
         {:ok, product_ids} <-
           zone_fare_products(organization_id, gtfs_version_id, rule_fare(params)),
         :ok <- require_conditions_unchanged(organization_id, gtfs_version_id, conditions, params),
         {:ok, edited} <- edited_rule(organization_id, gtfs_version_id, params),
         {:ok, targets} <- rule_targets(organization_id, gtfs_version_id, conditions, params),
         {:ok, clashes} <- rule_clashes(organization_id, gtfs_version_id, targets, product_ids) do
      settle_rule(
        organization_id,
        gtfs_version_id,
        targets,
        product_ids,
        edited,
        clashes,
        overlap
      )
    end
  end

  defp rule_fare(params), do: fare_param(params, :fare_product_id)

  # The conditions one rule states, with every blank read as "any". A network, a
  # zone and a time period are each checked against this version's own rows, so
  # another version's id is never written into this one's rules (INV-5).
  defp rule_conditions(organization_id, gtfs_version_id, params) do
    conditions = %{
      network_id: blank_to_nil(fare_param(params, :network_id)),
      from_area_id: blank_to_nil(fare_param(params, :from_area_id)),
      to_area_id: blank_to_nil(fare_param(params, :to_area_id)),
      from_timeframe_group_id: blank_to_nil(fare_param(params, :from_timeframe_group_id))
    }

    zones = Enum.reject([conditions.from_area_id, conditions.to_area_id], &is_nil/1)

    with :ok <- optional_network(organization_id, gtfs_version_id, conditions.network_id),
         :ok <- optional_zones(organization_id, gtfs_version_id, zones),
         :ok <- optional_time_period(organization_id, gtfs_version_id, conditions) do
      {:ok, conditions}
    end
  end

  defp optional_network(_organization_id, _gtfs_version_id, nil), do: :ok

  defp optional_network(organization_id, gtfs_version_id, network_id),
    do: require_network(organization_id, gtfs_version_id, network_id)

  defp optional_zones(_organization_id, _gtfs_version_id, []), do: :ok

  defp optional_zones(organization_id, gtfs_version_id, zones),
    do: require_zones(organization_id, gtfs_version_id, zones)

  defp optional_time_period(_organization_id, _gtfs_version_id, %{from_timeframe_group_id: nil}),
    do: :ok

  defp optional_time_period(
         organization_id,
         gtfs_version_id,
         %{from_timeframe_group_id: timeframe_group_id}
       ) do
    known =
      FareTimePeriod
      |> scoped(organization_id, gtfs_version_id)
      |> select([period], period.timeframe_group_id)
      |> Repo.all()
      |> MapSet.new()

    if MapSet.member?(known, timeframe_group_id), do: :ok, else: {:error, :not_found}
  end

  # The conditions sets one save writes: the one the drawer states, and the
  # reverse when `both?` is set for two different named areas. The same overlap
  # choice settles both, so "Also for rides from Y to X" cannot leave one
  # direction replaced and the other kept.
  defp rule_targets(_organization_id, _gtfs_version_id, conditions, params) do
    target = conditions
    both? = fare_param(params, :both?) == true

    reverse =
      if both? and not is_nil(conditions.from_area_id) and not is_nil(conditions.to_area_id) and
           conditions.from_area_id != conditions.to_area_id do
        [
          Map.merge(target, %{
            from_area_id: conditions.to_area_id,
            to_area_id: conditions.from_area_id
          })
        ]
      else
        []
      end

    {:ok, [target | reverse]}
  end

  # The rules an edit replaces: the ones the named `rule_id` belongs to. A rule
  # is one fare over one set of conditions, so editing it replaces the whole of
  # it rather than adding a second set beside the first.
  defp edited_rule(organization_id, gtfs_version_id, params) do
    case fare_param(params, :rule_id) do
      rule_id when is_binary(rule_id) ->
        edited_rule_by_id(organization_id, gtfs_version_id, rule_id)

      _nil_or_other ->
        {:ok, []}
    end
  end

  # A `rule_id` this version does not hold, or one whose fare is a pass, names
  # no rule to edit; a pass's rows are `Normalize`'s (R4, INV-4).
  defp edited_rule_by_id(organization_id, gtfs_version_id, rule_id) do
    case fetch_leg_rule(organization_id, gtfs_version_id, rule_id) do
      nil ->
        {:error, :not_found}

      rule ->
        if MapSet.member?(
             version_pass_ids(organization_id, gtfs_version_id),
             rule.fare_product_id
           ) do
          {:error, :pass_rule}
        else
          {:ok, rules_of_fare(organization_id, gtfs_version_id, rule)}
        end
    end
  end

  # Every non-pass rule with the same conditions as the given rule: the whole
  # rule, whichever of its rows the caller happened to name.
  defp rules_of_fare(organization_id, gtfs_version_id, rule) do
    rules = scoped_leg_rules(organization_id, gtfs_version_id)
    pass_ids = version_pass_ids(organization_id, gtfs_version_id)
    fare_ids = fare_product_ids(organization_id, gtfs_version_id, rule.fare_product_id)

    Enum.filter(rules, fn candidate ->
      not MapSet.member?(pass_ids, candidate.fare_product_id) and
        candidate.fare_product_id in fare_ids and
        same_rule_conditions?(candidate, rule)
    end)
  end

  # The products of the fare a stored rule names, resolved the same way
  # `zone_fare_products/3` resolves the caller's argument, so a rule and the
  # fare the drawer chose are one fare's products either way.
  defp fare_product_ids(organization_id, gtfs_version_id, fare_product_id) do
    products = version_products(organization_id, gtfs_version_id)

    case fare_name_for(products, fare_product_id) do
      nil -> []
      name -> fare_product_ids(products, name)
    end
  end

  # The fence: the product list the rule list showed for these conditions must
  # still be what is stored, so a save cannot land on top of an edit made since
  # the drawer opened (R15). `nil` is a create and has nothing to be stale
  # against. The rules the save itself replaces — the ones named by `rule_id`,
  # and the clashing ones under `:replace` — are already accounted for by the
  # write, so only the rules the drawer did not choose are compared.
  defp require_conditions_unchanged(organization_id, gtfs_version_id, conditions, params) do
    case fare_param(params, :reviewed) do
      reviewed when is_list(reviewed) ->
        stored = stored_conditions_products(organization_id, gtfs_version_id, conditions, params)
        reviewed = Enum.sort(Enum.uniq(reviewed))

        if stored == reviewed do
          :ok
        else
          {:error, {:stale, [%{field: :products, reviewed: reviewed, stored: stored}]}}
        end

      _other ->
        :ok
    end
  end

  defp stored_conditions_products(organization_id, gtfs_version_id, conditions, params) do
    rules = scoped_leg_rules(organization_id, gtfs_version_id)
    pass_ids = version_pass_ids(organization_id, gtfs_version_id)
    edited_ids = edited_rule_ids(params, organization_id, gtfs_version_id)

    rules
    |> Enum.filter(fn rule ->
      not MapSet.member?(pass_ids, rule.fare_product_id) and
        not MapSet.member?(edited_ids, rule.id) and
        rule.network_id == conditions.network_id and
        rule.from_area_id == conditions.from_area_id and
        rule.to_area_id == conditions.to_area_id and
        rule.from_timeframe_group_id == conditions.from_timeframe_group_id
    end)
    |> Enum.map(& &1.fare_product_id)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp edited_rule_ids(params, organization_id, version_id) do
    case fare_param(params, :rule_id) do
      rule_id when is_binary(rule_id) ->
        case fetch_leg_rule(organization_id, version_id, rule_id) do
          nil -> MapSet.new()
          rule -> rules_of_fare(organization_id, version_id, rule) |> MapSet.new(& &1.id)
        end

      _other ->
        MapSet.new()
    end
  end

  defp same_rule_conditions?(left, right) do
    left.network_id == right.network_id and left.from_area_id == right.from_area_id and
      left.to_area_id == right.to_area_id and
      left.from_timeframe_group_id == right.from_timeframe_group_id
  end

  # The rules at these conditions that name a *different* fare. A rider can only
  # be charged one single-ride fare for one ride, so this is the overlap the
  # drawer offers to replace or to keep; another rider type or payment method of
  # the same fare is the same fare and is not one — which is why the check is on
  # the fare's product list rather than on the product id.
  defp rule_clashes(organization_id, gtfs_version_id, targets, product_ids) do
    rules = scoped_leg_rules(organization_id, gtfs_version_id)
    pass_ids = version_pass_ids(organization_id, gtfs_version_id)

    clashes =
      targets
      |> Enum.flat_map(fn target ->
        Enum.filter(rules, fn rule ->
          not MapSet.member?(pass_ids, rule.fare_product_id) and
            target_rule?(rule, target) and rule.fare_product_id not in product_ids
        end)
      end)
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(& &1.id)

    {:ok, clashes}
  end

  defp target_rule?(rule, target) do
    rule.network_id == target.network_id and rule.from_area_id == target.from_area_id and
      rule.to_area_id == target.to_area_id and
      rule.from_timeframe_group_id == target[:from_timeframe_group_id]
  end

  # `:replace` writes the new fare over the clashing rules, `:keep_both` leaves
  # them, and no choice at all is the refusal that makes the drawer offer one.
  # Either way the rules an edit replaces go first, so an edit never leaves two
  # sets of rules for one set of conditions.
  defp settle_rule(organization_id, gtfs_version_id, targets, product_ids, edited, clashes, nil) do
    case clashes do
      [] -> write_rules(organization_id, gtfs_version_id, targets, product_ids, edited, [], [])
      [clash | _rest] -> {:error, {:overlap, clash}}
    end
  end

  defp settle_rule(
         organization_id,
         gtfs_version_id,
         targets,
         product_ids,
         edited,
         clashes,
         :keep_both
       ) do
    write_rules(
      organization_id,
      gtfs_version_id,
      targets,
      product_ids,
      edited,
      [],
      Enum.map(clashes, & &1.id)
    )
  end

  defp settle_rule(
         organization_id,
         gtfs_version_id,
         targets,
         product_ids,
         edited,
         clashes,
         :replace
       ) do
    write_rules(organization_id, gtfs_version_id, targets, product_ids, edited, clashes, [])
  end

  # `replaced` is the set of rules the choice took out (an edit's own rules, and
  # the clashing ones under `:replace`); `preserved` is the set it left in place
  # (the clashing ones under `:keep_both`).
  defp write_rules(
         organization_id,
         gtfs_version_id,
         targets,
         product_ids,
         edited,
         replaced,
         preserved
       ) do
    rules = scoped_leg_rules(organization_id, gtfs_version_id)
    pass_ids = version_pass_ids(organization_id, gtfs_version_id)

    removed_ids = MapSet.new(Enum.map(edited ++ replaced, & &1.id))
    preserved_ids = MapSet.new(preserved)

    {removed, added} =
      Enum.reduce(targets, {[], []}, fn target, {removed, added} ->
        # At this target, a rule goes when the write chose to replace it (an edit
        # or an overlap the operator settled) or when it names a fare the write
        # did not choose; a rule naming the chosen fare, or one the choice kept,
        # is already what should be there and is left alone, so a repeated save
        # is a no-op.
        at_target =
          Enum.filter(rules, fn rule ->
            not MapSet.member?(pass_ids, rule.fare_product_id) and
              not MapSet.member?(preserved_ids, rule.id) and
              target_rule?(rule, target)
          end)

        current =
          Enum.filter(at_target, fn rule ->
            MapSet.member?(removed_ids, rule.id) or rule.fare_product_id not in product_ids
          end)

        # A product already named by a rule that is staying is not written again,
        # so saving the same conditions and fare twice is a no-op rather than a
        # second set of rows for one fare. The unique index cannot catch that on
        # its own: it treats the rules whose timeframes are null as distinct.
        staying = at_target -- current

        named = Enum.map(staying ++ current, & &1.fare_product_id)
        keep = product_ids |> Enum.uniq() |> Enum.reject(&(&1 in named))

        inserted = insert_leg_rules(organization_id, gtfs_version_id, target, keep)
        delete_rows(FareLegRule, organization_id, gtfs_version_id, current)

        {removed ++ Enum.map(current, &row_snapshot/1), added ++ inserted}
      end)

    {:ok,
     %{
       before: rule_log_rows(removed),
       after: rule_log_rows(added),
       action: if(edited == [], do: "created", else: "updated"),
       inverse: %{operation: :save, rules: %{removed: removed, added: added}}
     }}
  end

  # The whole rule the named row belongs to goes, because a rule is one fare
  # over one set of conditions and half of it would leave a cell priced for one
  # rider type and not another. A pass row is refused rather than deleted
  # because `Fares.Normalize` writes it back from the accepted networks on the
  # next write of any kind (R4, INV-4).
  defp remove_rule(organization_id, gtfs_version_id, rule_id, expected) do
    with {:ok, rule} <- removable_rule(organization_id, gtfs_version_id, rule_id),
         :ok <- require_rule_fence(organization_id, gtfs_version_id, rule, expected) do
      removed = rules_of_fare(organization_id, gtfs_version_id, rule)
      delete_rows(FareLegRule, organization_id, gtfs_version_id, removed)

      {:ok,
       %{
         before: rule_log_rows(removed),
         after: [],
         action: "deleted",
         inverse: %{operation: :delete, rules: Enum.map(removed, &row_snapshot/1)}
       }}
    end
  end

  defp removable_rule(organization_id, gtfs_version_id, rule_id) do
    case fetch_leg_rule(organization_id, gtfs_version_id, rule_id) do
      nil ->
        {:error, :not_found}

      rule ->
        if MapSet.member?(
             version_pass_ids(organization_id, gtfs_version_id),
             rule.fare_product_id
           ) do
          {:error, :pass_rule}
        else
          {:ok, rule}
        end
    end
  end

  # The fence: the product the rule list showed must still be one of the rule's
  # own products, so a rule somebody else has changed since the drawer opened
  # deletes nothing (R15).
  defp require_rule_fence(organization_id, gtfs_version_id, rule, expected) do
    case Map.fetch(expected, :fare_product_id) do
      :error ->
        :ok

      {:ok, reviewed} when is_binary(reviewed) ->
        stored =
          organization_id
          |> rules_of_fare(gtfs_version_id, rule)
          |> Enum.map(& &1.fare_product_id)
          |> Enum.uniq()
          |> Enum.sort()

        if reviewed in stored do
          :ok
        else
          {:error, {:stale, [%{field: :fare_product_id, reviewed: reviewed, stored: stored}]}}
        end

      {:ok, _other} ->
        {:error, :not_found}
    end
  end

  defp rule_save_summary(organization_id, gtfs_version_id, params) do
    fare = fare_param(params, :fare_product_id)
    name = fare_name_for(version_products(organization_id, gtfs_version_id), fare)
    action = if is_nil(fare_param(params, :rule_id)), do: "Added", else: "Updated"

    "#{action} the fare rule for #{rule_sentence(params)} paying #{name}"
  end

  defp rule_delete_summary(organization_id, gtfs_version_id, rule_id) do
    case fetch_leg_rule(organization_id, gtfs_version_id, rule_id) do
      nil ->
        "Deleted a fare rule"

      rule ->
        name =
          fare_name_for(version_products(organization_id, gtfs_version_id), rule.fare_product_id)

        "Deleted the fare rule for #{rule_sentence(rule)} paying #{name}"
    end
  end

  # The conditions in the words the rule list and the drawer's "what this rule
  # does" card use, with "any" for each one the rule leaves open. It reads a
  # stored rule and the drawer's form alike, because both name the same four
  # conditions under the same keys.
  defp rule_sentence(rule) when is_map(rule) do
    read = fn
      key, label ->
        case blank_to_nil(Map.get(rule, key)) do
          nil -> "any #{label}"
          value -> value
        end
    end

    "rides in #{read.(:network_id, "route group")} from #{read.(:from_area_id, "zone")} to " <>
      "#{read.(:to_area_id, "zone")} at #{read.(:from_timeframe_group_id, "time")}"
  end

  @doc """
  Adds or removes one route group from a pass's accepted networks (AC-21).

  A pass's `accepted_network_ids` are the leg groups it stands in for, and
  `Fares.Normalize` rebuilds the pass's leg rules from them (R4). Writing the
  list is therefore the whole of this writer: the mirrored rows are
  Normalize's, not this module's (INV-4), and they are rebuilt inside the same
  transaction before it commits (INV-1).

  A product this version does not hold, a product whose kind is not `"pass"`, a
  network this version does not hold and a `network_id` other than
  `"all_routes"` all answer `{:error, :not_found}`; an existing detail row
  holding a different `kind` answers `{:error, :not_a_pass}`, which is the one
  case a caller can tell apart.

  `reviewed` is the accepted list the passes table showed, and a pass whose
  list has changed since answers `{:error, {:stale, details}}` and writes
  nothing (R15). A checkbox already in the state the operator asked for is
  `{:ok, ...}` with nothing written, so pressing save twice records one entry.
  """
  @spec set_pass_acceptance(
          scope(),
          String.t(),
          String.t(),
          boolean(),
          [String.t()] | nil
        ) :: write_result()
  def set_pass_acceptance(
        %{organization_id: organization_id, gtfs_version_id: gtfs_version_id} = scope,
        fare_product_id,
        network_id,
        accepted?,
        reviewed
      )
      when is_binary(fare_product_id) and is_binary(network_id) and is_boolean(accepted?) do
    summary =
      pass_acceptance_summary(
        organization_id,
        gtfs_version_id,
        fare_product_id,
        network_id,
        accepted?
      )

    write(scope, summary, @pass_inverse, fn _setting ->
      apply_pass_acceptance(
        organization_id,
        gtfs_version_id,
        fare_product_id,
        network_id,
        accepted?,
        reviewed
      )
    end)
  end

  defp apply_pass_acceptance(
         organization_id,
         gtfs_version_id,
         fare_product_id,
         network_id,
         accepted?,
         reviewed
       ) do
    with {:ok, pass} <-
           pass_detail(organization_id, gtfs_version_id, fare_product_id, network_id),
         :ok <- require_acceptance_unchanged(pass, reviewed) do
      accepted = accepted_network_ids(pass, network_id, accepted?)
      write_pass_acceptance(organization_id, gtfs_version_id, pass, accepted)
    end
  end

  # The pass's own detail row, which is where the accepted networks live, and
  # `:not_found` for a product or a network this version does not hold (INV-5).
  # A product with no detail row is read as a single ride everywhere else in
  # this module, so accepting a network for it is a caller's mistake rather than
  # a state the stored rows can hold.
  defp pass_detail(organization_id, gtfs_version_id, fare_product_id, network_id) do
    with {:ok, network_id} <- accepted_network_id(organization_id, gtfs_version_id, network_id),
         {:ok, detail} <- pass_detail_row(organization_id, gtfs_version_id, fare_product_id) do
      {:ok,
       %{id: detail.id, fare_product_id: fare_product_id, network_id: network_id, row: detail}}
    end
  end

  defp pass_detail_row(organization_id, gtfs_version_id, fare_product_id) do
    case detail_row(organization_id, gtfs_version_id, fare_product_id) do
      nil ->
        {:error, :not_found}

      %FareProductDetail{kind: "pass"} = detail ->
        {:ok, detail}

      %FareProductDetail{} ->
        {:error, :not_a_pass}
    end
  end

  defp accepted_network_id(_organization_id, _gtfs_version_id, @all_routes_accepted),
    do: {:ok, @all_routes_accepted}

  defp accepted_network_id(organization_id, gtfs_version_id, network_id) do
    case network_row(organization_id, gtfs_version_id, network_id) do
      nil -> {:error, :not_found}
      _network -> {:ok, network_id}
    end
  end

  defp require_acceptance_unchanged(_pass, nil), do: :ok

  defp require_acceptance_unchanged(pass, reviewed) when is_list(reviewed) do
    stored = pass.row.accepted_network_ids

    if stored == Enum.sort(Enum.uniq(reviewed)) do
      :ok
    else
      {:error, {:stale, [%{field: :accepted_network_ids, reviewed: reviewed, stored: stored}]}}
    end
  end

  defp require_acceptance_unchanged(_pass, _other), do: {:error, :not_found}

  # The list with this network added or dropped, sorted and deduplicated, which
  # is the shape `Fares.Normalize` reads and the shape the table renders. A
  # list that already says what the operator asked for is written as it stands,
  # so one save is one change-log entry whether or not it moved.
  defp accepted_network_ids(pass, network_id, true) do
    Enum.sort(Enum.uniq([network_id | pass.row.accepted_network_ids]))
  end

  defp accepted_network_ids(pass, network_id, false) do
    Enum.reject(pass.row.accepted_network_ids, &(&1 == network_id))
  end

  defp write_pass_acceptance(organization_id, gtfs_version_id, pass, accepted) do
    now = DateTime.utc_now()

    from(detail in FareProductDetail,
      where:
        detail.id == ^pass.id and detail.organization_id == ^organization_id and
          detail.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.update_all(set: [accepted_network_ids: accepted, updated_at: now])

    name = fare_display_name(organization_id, gtfs_version_id, pass.fare_product_id)
    log = fare_name_log_row(pass.fare_product_id, name)

    {:ok,
     %{
       before: [log],
       after: [Map.put(log, "accepted_network_ids", accepted)],
       action: "updated",
       inverse: %{
         operation: :save,
         id: pass.id,
         fare_product_id: pass.fare_product_id,
         before: pass.row.accepted_network_ids,
         after: accepted
       }
     }}
  end

  defp pass_acceptance_summary(
         organization_id,
         gtfs_version_id,
         fare_product_id,
         network_id,
         true
       ) do
    "Accepted #{network_id} for the pass #{fare_display_name(organization_id, gtfs_version_id, fare_product_id)}"
  end

  defp pass_acceptance_summary(
         organization_id,
         gtfs_version_id,
         fare_product_id,
         network_id,
         false
       ) do
    "Removed #{network_id} from the pass #{fare_display_name(organization_id, gtfs_version_id, fare_product_id)}"
  end

  # -- Editing time periods --------------------------------------------------------

  @doc """
  Creates or edits one fare time period and its `timeframes` rows (AC-22, R10).

  `params` is the time periods drawer's form:

      %{timeframe_group_id: String.t() | nil,
        name: String.t(),
        weekdays: integer() | nil,
        ranges: [%{start_seconds: integer(), end_seconds: integer()}],
        until_end_of_day?: boolean()}

  A period with no `timeframe_group_id` is a new one, and its GTFS group id is
  `fare_slug(name)` — refused with `{:error, :duplicate_time_period}` when this
  version already holds it, which is the same slug rule `save_route_group/2`
  follows. A named `timeframe_group_id` this version does not hold answers
  `{:error, :not_found}`, so another version's period is never written through
  this path (INV-5).

  `weekdays` is the R10 bitmask (Monday `1` … Sunday `64`), and a blank one is
  valid and means the ranges apply every day; a mask of `0` or one over `127` is
  refused by the period's own changeset, which is also where the database's own
  check would refuse it.

  `ranges` must be non-empty, each range must start before it ends, and the
  ranges must not overlap; each failure answers a changeset carrying an error on
  `:ranges` rather than writing half a period. Overlap is decided after sorting
  by start, so two ranges in any order are compared the same way.

  The period's own row and the `timeframes` rows of its group are written
  together in one transaction: a save replaces the group's ranges whole, so the
  group a leg rule names always exists and never holds a range the save did not
  write. Times are formatted `HH:MM:SS`, and `until_end_of_day?: true` writes the
  last range's end as `"24:00:00"` (R10) rather than as `00:00:00` of the next
  day.

  `service_id` is `fare_<slug>`, checked against every `calendar` and
  `calendar_dates` `service_id` of this version and against every other period's,
  with `_2`, `_3` … added until it is free (R10). The export re-checks the id
  and re-suffixes it if a calendar row was imported after this write (AC-22).

  A version that is not managed answers `{:error, :unmanaged}`, and a pair that
  is not a published version of that organization answers `{:error, :not_found}`
  with nothing written (R12, R15).
  """
  @spec save_time_period(scope(), map()) :: write_result()
  def save_time_period(
        %{organization_id: organization_id, gtfs_version_id: gtfs_version_id} = scope,
        params
      )
      when is_map(params) do
    case trimmed_name(params) do
      {:ok, name} ->
        write(scope, time_period_save_summary(params, name), @time_period_inverse, fn _setting ->
          apply_time_period(organization_id, gtfs_version_id, name, params)
        end)

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Deletes one fare time period, its `timeframes` rows and the rules that named it
  (AC-22).

  A period its own `fare_leg_rules` reference answers
  `{:error, :rules_reference_time_period}`: deleting it would leave rules naming
  a group that is gone, which is not a state the rest of this package can read.
  `expected[:remove_rules]` settles it — `true` deletes those rules, leaving the
  cells they priced with no fare, the same shape `delete_fare/4`'s
  `:remove_rules` and `delete_route_group/3`'s leave.

  A period's own `service_id` and its group's rows go with it. The rules are
  deleted rather than their timeframe columns blanked, because a leg rule with a
  blank timeframe prices every time of day, which is a different fare.

  `expected` is the fence and carries the `:name` the editor reviewed beside the
  `:remove_rules` choice: a period renamed since the drawer opened answers
  `{:error, {:stale, details}}` and deletes nothing (R15). A period of another
  organization or another version answers `{:error, :not_found}`.
  """
  @spec delete_time_period(scope(), String.t(), map()) :: write_result()
  def delete_time_period(
        %{organization_id: organization_id, gtfs_version_id: gtfs_version_id} = scope,
        timeframe_group_id,
        expected
      )
      when is_binary(timeframe_group_id) and is_map(expected) do
    summary =
      "Deleted the time period \"#{time_period_name(organization_id, gtfs_version_id, timeframe_group_id) || timeframe_group_id}\""

    write(scope, summary, @time_period_inverse, fn _setting ->
      remove_time_period(organization_id, gtfs_version_id, timeframe_group_id, expected)
    end)
  end

  defp apply_time_period(organization_id, gtfs_version_id, name, params) do
    with {:ok, ranges} <- time_period_ranges(params),
         {:ok, group_id} <-
           time_period_group_id(organization_id, gtfs_version_id, name, params),
         {:ok, service_id} <-
           time_period_service_id(organization_id, gtfs_version_id, group_id, name),
         {:ok, period} <-
           write_time_period(organization_id, gtfs_version_id, group_id, name, service_id, params),
         {:ok, timeframes} <-
           write_timeframes(
             organization_id,
             gtfs_version_id,
             group_id,
             service_id,
             ranges,
             params
           ) do
      {:ok,
       %{
         before: time_period_log_row(period.before, timeframes.previous),
         after: time_period_log_row(period.after, timeframes.written),
         action: period.action,
         inverse: %{
           operation: :save,
           period: period,
           timeframes: %{added: timeframes.added, removed: timeframes.removed}
         }
       }}
    end
  end

  # The drawer's ranges, sorted and checked. Every failure is a changeset error
  # on `:ranges` rather than a refusal the drawer would have to read as a
  # different kind of answer, because all three are the operator's own input.
  defp time_period_ranges(params) do
    ranges =
      case fare_param(params, :ranges) do
        ranges when is_list(ranges) -> ranges
        _other -> []
      end

    case normalized_ranges(ranges) do
      [] ->
        {:error, ranges_changeset("can't be blank")}

      ranges ->
        with :ok <- check_range_order(ranges),
             :ok <- check_range_overlap(ranges) do
          {:ok, ranges}
        end
    end
  end

  defp normalized_ranges(ranges) do
    ranges
    |> Enum.map(&range_bounds/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
  end

  # One range as `{start, end}` seconds, or `nil` when the drawer sent something
  # that is not a pair of seconds within one day. A range that ends before it
  # starts is kept here rather than dropped, so `check_range_order/1` can name
  # the operator's own mistake rather than reporting an empty list of ranges.
  # A range of text the drawer already formatted is read through
  # `GtfsTime.parse/1`, the same reader the importer uses.
  defp range_bounds(%{start_seconds: start, end_seconds: finish}) do
    range_bounds({start, finish})
  end

  defp range_bounds({start, finish}) do
    with {:ok, start} <- time_seconds(start),
         {:ok, finish} <- time_seconds(finish) do
      {start, finish}
    else
      _other -> nil
    end
  end

  defp range_bounds(_other), do: nil

  defp time_seconds(seconds) when is_integer(seconds) do
    if seconds >= 0 and seconds <= @end_of_day_seconds,
      do: {:ok, seconds},
      else: {:error, :out_of_range}
  end

  defp time_seconds(value) when is_binary(value), do: GtfsTime.parse(value)
  defp time_seconds(_other), do: {:error, :invalid_time}

  # A range that ends before the next one starts is a valid split; a range that
  # ends at or after it is not, which is what an operator means by two ranges
  # that overlap.
  defp check_range_order(ranges) do
    if Enum.all?(ranges, fn {start, finish} -> start < finish end) do
      :ok
    else
      {:error, ranges_changeset("must start before it ends")}
    end
  end

  defp check_range_overlap(ranges) do
    overlaps? =
      ranges
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.any?(fn [{_start, finish}, {next_start, _next_finish}] ->
        next_start < finish
      end)

    if overlaps? do
      {:error, ranges_changeset("can't overlap")}
    else
      :ok
    end
  end

  defp ranges_changeset(message) do
    %FareTimePeriod{}
    |> Ecto.Changeset.change(%{name: nil})
    |> Map.put(:action, :insert)
    |> Ecto.Changeset.add_error(:ranges, message)
  end

  # The GTFS group id the form names: the name's slug when the form creates a
  # period, refused when this version already holds it, and the id the form named
  # when it edits one (INV-5).
  defp time_period_group_id(organization_id, gtfs_version_id, name, params) do
    periods = version_time_periods(organization_id, gtfs_version_id)

    case fare_param(params, :timeframe_group_id) do
      nil ->
        id = fare_slug(name)

        cond do
          id == "" -> {:error, name_changeset(name, "must have a letter or a number")}
          Enum.any?(periods, &(&1.timeframe_group_id == id)) -> {:error, :duplicate_time_period}
          true -> {:ok, id}
        end

      "" ->
        {:error, :not_found}

      id when is_binary(id) ->
        if Enum.any?(periods, &(&1.timeframe_group_id == id)) do
          {:ok, id}
        else
          {:error, :not_found}
        end

      _other ->
        {:error, :not_found}
    end
  end

  # R10's `fare_<slug>`, unique among the version's calendar service ids, its
  # calendar-date service ids and every other period's. A period's own current
  # service id is not a collision with itself, so saving a period twice asks for
  # the same id twice rather than the second save suffixing away from the first.
  defp time_period_service_id(organization_id, gtfs_version_id, group_id, name) do
    own =
      case time_period_row(organization_id, gtfs_version_id, group_id) do
        nil -> []
        period -> [period.service_id]
      end

    taken = reserved_service_ids(organization_id, gtfs_version_id) -- own
    base = @fare_service_prefix <> fare_slug(name)

    if base in taken do
      case unique_service_id(base, taken, 2) do
        {:ok, service_id} -> {:ok, service_id}
        {:error, changeset} -> {:error, changeset}
      end
    else
      {:ok, base}
    end
  end

  defp reserved_service_ids(organization_id, gtfs_version_id) do
    calendar_ids =
      Calendar
      |> scoped(organization_id, gtfs_version_id)
      |> select([calendar], calendar.service_id)
      |> Repo.all()

    exception_ids =
      CalendarDate
      |> scoped(organization_id, gtfs_version_id)
      |> select([exception], exception.service_id)
      |> Repo.all()

    period_ids =
      FareTimePeriod
      |> scoped(organization_id, gtfs_version_id)
      |> select([period], period.service_id)
      |> Repo.all()

    Enum.uniq(calendar_ids ++ exception_ids ++ period_ids)
  end

  defp unique_service_id(base, taken, suffix) when suffix <= @service_suffix_limit do
    candidate = "#{base}_#{suffix}"

    if candidate in taken do
      unique_service_id(base, taken, suffix + 1)
    else
      {:ok, candidate}
    end
  end

  defp unique_service_id(_base, _taken, _suffix) do
    # The suffix search is bounded, and running out of ids is refused rather
    # than answered with an id that collides with a calendar or a period.
    {:error, name_changeset("", "has no free service id")}
  end

  defp version_time_periods(organization_id, gtfs_version_id) do
    FareTimePeriod
    |> scoped(organization_id, gtfs_version_id)
    |> order_by([period], period.timeframe_group_id)
    |> Repo.all()
  end

  defp time_period_row(organization_id, gtfs_version_id, timeframe_group_id) do
    FareTimePeriod
    |> scoped(organization_id, gtfs_version_id)
    |> where([period], period.timeframe_group_id == ^timeframe_group_id)
    |> Repo.one()
  end

  defp time_period_name(organization_id, gtfs_version_id, timeframe_group_id) do
    case time_period_row(organization_id, gtfs_version_id, timeframe_group_id) do
      nil -> nil
      period -> period.name
    end
  end

  # The one `fare_time_periods` row, written through its own changeset. The
  # group id is what every leg rule naming this period states and never moves;
  # the name, the weekday mask, the end-of-day flag and the service id are the
  # drawer edit.
  defp write_time_period(
         organization_id,
         gtfs_version_id,
         group_id,
         name,
         service_id,
         params
       ) do
    attrs = %{
      timeframe_group_id: group_id,
      name: name,
      weekdays: fare_param(params, :weekdays),
      until_end_of_day: fare_param(params, :until_end_of_day?) == true,
      service_id: service_id
    }

    case time_period_row(organization_id, gtfs_version_id, group_id) do
      nil ->
        changeset =
          %FareTimePeriod{}
          |> struct(%{
            organization_id: organization_id,
            gtfs_version_id: gtfs_version_id
          })
          |> FareTimePeriod.changeset(attrs)

        case Repo.insert(changeset) do
          {:ok, row} ->
            {:ok, %{id: row.id, action: "created", before: nil, after: attrs, row: row}}

          {:error, changeset} ->
            Repo.rollback(changeset)
        end

      row ->
        case row |> FareTimePeriod.changeset(attrs) |> Repo.update() do
          {:ok, updated} ->
            {:ok,
             %{
               id: updated.id,
               action: "updated",
               before: time_period_attrs(row),
               after: time_period_attrs(updated),
               row: updated
             }}

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
    end
  end

  defp time_period_attrs(row) do
    %{
      timeframe_group_id: row.timeframe_group_id,
      name: row.name,
      weekdays: row.weekdays,
      until_end_of_day: row.until_end_of_day,
      service_id: row.service_id
    }
  end

  # The group's `timeframes` rows, replaced whole. A range this save did not
  # write has its row deleted and a range it did write has its row inserted, in
  # the same transaction as the period itself, so the group never holds a stale
  # range (persistence-integrity).
  defp write_timeframes(
         organization_id,
         gtfs_version_id,
         group_id,
         service_id,
         ranges,
         params
       ) do
    rows = version_timeframes(organization_id, gtfs_version_id)
    mine = Enum.filter(rows, &(&1.timeframe_group_id == group_id))
    wanted = timeframe_rows(ranges, params, group_id, service_id)

    # A row is kept only when it names this period's service id as well as the
    # range: a rename re-derives the service id (R10), and a range left carrying
    # the old one would name a service no calendar row exists.
    wanted_keys = MapSet.new(Enum.map(wanted, &range_key/1))
    kept = Enum.filter(mine, &MapSet.member?(wanted_keys, range_key(&1)))
    removed = mine -- kept
    named = MapSet.new(Enum.map(kept, &range_key/1))
    added = Enum.reject(wanted, &MapSet.member?(named, range_key(&1)))

    delete_rows(Timeframe, organization_id, gtfs_version_id, removed)
    added = insert_timeframes(organization_id, gtfs_version_id, added)

    {:ok, %{added: added, removed: removed, written: wanted, previous: mine}}
  end

  # The ranges as `timeframes` rows would read them, with the last range's end
  # written as `"24:00:00"` when the drawer asked to run to the end of the
  # service day (R10).
  defp timeframe_rows(ranges, params, group_id, service_id) do
    until_end_of_day? = fare_param(params, :until_end_of_day?) == true
    count = length(ranges)

    ranges
    |> Enum.with_index()
    |> Enum.map(fn {{start, finish}, index} ->
      %{
        timeframe_group_id: group_id,
        start_time: GtfsTime.format(start),
        end_time:
          if(until_end_of_day? and index == count - 1,
            do: @end_of_day_time,
            else: GtfsTime.format(finish)
          ),
        service_id: service_id
      }
    end)
  end

  # What makes one `timeframes` row the row a save would write again: its range
  # and the service id it is written under.
  defp range_key(row), do: {row.start_time, row.end_time, row.service_id}

  defp version_timeframes(organization_id, gtfs_version_id) do
    Timeframe
    |> scoped(organization_id, gtfs_version_id)
    |> order_by([row], row.start_time)
    |> Repo.all()
  end

  defp insert_timeframes(_organization_id, _gtfs_version_id, []), do: []

  defp insert_timeframes(organization_id, gtfs_version_id, attrs) do
    now = DateTime.utc_now()

    rows =
      Enum.map(attrs, fn attr ->
        Map.merge(attr, %{
          id: Ecto.UUID.generate(),
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id,
          inserted_at: now,
          updated_at: now
        })
      end)

    {_count, inserted} = Repo.insert_all(Timeframe, rows, returning: true)
    inserted
  end

  defp time_period_save_summary(params, name) do
    if fare_param(params, :timeframe_group_id) do
      "Updated the time period \"#{name}\""
    else
      "Created the time period \"#{name}\""
    end
  end

  # The change-log row of one time period write: the period's own facts beside
  # the ranges it now holds, as `HH:MM:SS` text, which is what the editor's
  # history shows.
  defp time_period_log_row(nil, _ranges), do: nil

  defp time_period_log_row(attrs, ranges) do
    Map.merge(attrs, %{
      "ranges" =>
        Enum.map(ranges || [], &%{"start_time" => &1.start_time, "end_time" => &1.end_time})
    })
  end

  defp remove_time_period(organization_id, gtfs_version_id, timeframe_group_id, expected) do
    case time_period_row(organization_id, gtfs_version_id, timeframe_group_id) do
      nil ->
        {:error, :not_found}

      period ->
        case name_stale(expected, period.name) do
          [] -> settle_time_period_references(organization_id, gtfs_version_id, period, expected)
          stale -> {:error, {:stale, stale}}
        end
    end
  end

  # What named this period, and what the operator asked to do about it. The rules
  # are refused rather than left naming a group that is gone, unless the drawer
  # asked for them to go with it.
  defp settle_time_period_references(organization_id, gtfs_version_id, period, expected) do
    rules = period_rules(organization_id, gtfs_version_id, period.timeframe_group_id)

    if rules != [] and not remove_rules?(expected) do
      {:error, :rules_reference_time_period}
    else
      delete_time_period_rows(organization_id, gtfs_version_id, period, rules)
    end
  end

  defp period_rules(organization_id, gtfs_version_id, timeframe_group_id) do
    FareLegRule
    |> scoped(organization_id, gtfs_version_id)
    |> where([rule], rule.from_timeframe_group_id == ^timeframe_group_id)
    |> order_by([rule], rule.fare_product_id)
    |> Repo.all()
  end

  defp delete_time_period_rows(organization_id, gtfs_version_id, period, rules) do
    timeframes =
      Timeframe
      |> scoped(organization_id, gtfs_version_id)
      |> where([row], row.timeframe_group_id == ^period.timeframe_group_id)
      |> Repo.all()

    delete_rows(FareLegRule, organization_id, gtfs_version_id, rules)
    delete_rows(Timeframe, organization_id, gtfs_version_id, timeframes)
    delete_rows(FareTimePeriod, organization_id, gtfs_version_id, [period])

    {:ok,
     %{
       before: time_period_log_row(time_period_attrs(period), timeframes),
       after: [],
       action: "deleted",
       inverse: %{
         operation: :delete,
         period: period,
         timeframes: timeframes,
         rules: Enum.map(rules, &row_snapshot/1)
       }
     }}
  end

  # Applies a `save_time_period/2` or `delete_time_period/3` inverse.
  #
  # A saved period's row must still be there and still hold the values that write
  # left, the `timeframes` rows it added must still be there and the rows it
  # deleted must still be gone. A deleted period's row, its ranges and the rules
  # its delete settled must all still be gone. Anything else answers
  # `{:error, :stale}` and changes nothing, so a reversal can never revert a
  # later edit (R15, AC-26).
  defp undo_time_period(organization_id, gtfs_version_id, operation_id, inverse) do
    with :ok <- require_entry(operation_id, organization_id, gtfs_version_id),
         :ok <- require_period_unchanged(organization_id, gtfs_version_id, inverse) do
      restore_time_period(organization_id, gtfs_version_id, inverse)

      {:ok,
       %{
         before: [],
         after: [],
         inverse: nil,
         operation_id: operation_id,
         action: "rolled_back",
         rolled_back_to_log_id: operation_id
       }}
    end
  end

  defp require_period_unchanged(organization_id, gtfs_version_id, inverse) do
    stale? =
      case inverse do
        %{operation: :save} = inverse ->
          not definition_untouched?(
            FareTimePeriod,
            organization_id,
            gtfs_version_id,
            inverse.period
          ) or
            not Enum.all?(
              inverse.timeframes.added,
              &timeframe_untouched?(&1, organization_id, gtfs_version_id)
            ) or
            Enum.any?(
              inverse.timeframes.removed,
              &definition_present?(Timeframe, organization_id, gtfs_version_id, &1.id)
            )

        %{operation: :delete} = inverse ->
          definition_present?(
            FareTimePeriod,
            organization_id,
            gtfs_version_id,
            inverse.period.id
          ) or
            Enum.any?(
              inverse.timeframes,
              &definition_present?(Timeframe, organization_id, gtfs_version_id, &1.id)
            ) or
            Enum.any?(inverse.rules, &rule_present?(&1, organization_id, gtfs_version_id))

        _other ->
          true
      end

    if stale?, do: {:error, :stale}, else: :ok
  end

  # A range the save added must still name its group and the times it was
  # written with, so a period edited since is a later edit the reversal must not
  # revert on top of.
  defp timeframe_untouched?(row, organization_id, gtfs_version_id) do
    current =
      from(t in Timeframe,
        where:
          t.id == ^row.id and t.organization_id == ^organization_id and
            t.gtfs_version_id == ^gtfs_version_id
      )
      |> Repo.one()

    current != nil and
      current.timeframe_group_id == row.timeframe_group_id and
      current.start_time == row.start_time and current.end_time == row.end_time and
      current.service_id == row.service_id
  end

  defp restore_time_period(organization_id, gtfs_version_id, %{operation: :save} = inverse) do
    rows = inverse.timeframes

    Enum.each(rows.removed, &Repo.insert!(Ecto.Changeset.change(&1)))
    delete_rows(Timeframe, organization_id, gtfs_version_id, rows.added)
    restore_saved_row(organization_id, gtfs_version_id, FareTimePeriod, inverse.period)

    :ok
  end

  defp restore_time_period(_organization_id, _gtfs_version_id, %{operation: :delete} = inverse) do
    Repo.insert!(Ecto.Changeset.change(inverse.period))
    Enum.each(inverse.timeframes, &Repo.insert!(Ecto.Changeset.change(&1)))
    Enum.each(inverse.rules, &Repo.insert!(Ecto.Changeset.change(&1)))

    :ok
  end

  @doc false
  # The name a product id belongs to, matched against the ids `save_fare/2`
  # derives from names as well as against the products themselves, so a caller
  # that holds a fare's name-slug reaches the same fare the grid shows.
  @spec fare_name_for([GtfsPlanner.Gtfs.FareProduct.t()], String.t() | nil) :: String.t() | nil
  defp fare_name_for(products, fare_product_id) do
    case Enum.find(products, &(&1.fare_product_id == fare_product_id)) do
      nil ->
        case Enum.find(products, &(fare_slug(fare_name(&1)) == fare_product_id)) do
          nil -> nil
          product -> fare_name(product)
        end

      product ->
        fare_name(product)
    end
  end

  defp fare_product_ids(products, name) do
    products
    |> Enum.filter(&(fare_name(&1) == name))
    |> Enum.map(& &1.fare_product_id)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # The change-log row of one leg rule, whichever direction it moved: the rule's
  # own id and the conditions and product it states, which is what the rule list
  # shows and what a reader of Recent changes can act on.
  defp leg_rule_log_row(rule) do
    %{
      "rule_id" => rule.id,
      "network_id" => rule.network_id,
      "from_area_id" => rule.from_area_id,
      "to_area_id" => rule.to_area_id,
      "from_timeframe_group_id" => rule.from_timeframe_group_id,
      "fare_product_id" => rule.fare_product_id
    }
  end

  # The change-log rows of one rule write: the rules it removed before, the rules
  # it added after. A save that changed nothing records one entry with both
  # empty, which is the same shape every other writer of this module records.
  defp rule_log_rows(rows), do: Enum.map(rows, &leg_rule_log_row/1)

  # -- Undoing a rule or pass acceptance change -----------------------------------

  # A saved rule's added rows must all still be there, and its removed rows all
  # still gone. A delete's rows must all still be gone. Anything else answers
  # `{:error, :stale}` and changes nothing, so a reversal can never revert a
  # later edit (R15, AC-26).
  defp require_rule_unchanged(organization_id, gtfs_version_id, inverse) do
    stale? =
      case inverse do
        %{operation: :save, rules: %{removed: removed, added: added}} ->
          Enum.any?(removed, &rule_present?(&1, organization_id, gtfs_version_id)) or
            not Enum.all?(added, &(not rule_present?(&1, organization_id, gtfs_version_id)))

        %{operation: :delete, rules: removed} ->
          Enum.any?(removed, &rule_present?(&1, organization_id, gtfs_version_id))

        _other ->
          true
      end

    if stale?, do: {:error, :stale}, else: :ok
  end

  defp restore_rule(organization_id, gtfs_version_id, %{operation: :save, rules: rules}) do
    delete_rows(FareLegRule, organization_id, gtfs_version_id, rules.added)
    Enum.each(rules.removed, &Repo.insert!(Ecto.Changeset.change(&1)))

    :ok
  end

  defp restore_rule(_organization_id, _gtfs_version_id, %{operation: :delete, rules: rules}) do
    Enum.each(rules, &Repo.insert!(Ecto.Changeset.change(&1)))

    :ok
  end

  # The pass must still hold exactly the accepted list the write left, which is
  # the same fence `delete_route_group/3`'s reversal uses for a pass it stopped
  # accepting.
  defp require_acceptance_unchanged(inverse, organization_id, gtfs_version_id) do
    current =
      from(detail in FareProductDetail,
        where:
          detail.id == ^inverse.id and detail.organization_id == ^organization_id and
            detail.gtfs_version_id == ^gtfs_version_id,
        select: detail.accepted_network_ids
      )
      |> Repo.one()

    if current == inverse.after, do: :ok, else: {:error, :stale}
  end

  defp restore_pass_acceptance(organization_id, gtfs_version_id, inverse) do
    from(detail in FareProductDetail,
      where:
        detail.id == ^inverse.id and detail.organization_id == ^organization_id and
          detail.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.update_all(
      set: [accepted_network_ids: inverse.before, updated_at: DateTime.utc_now()]
    )

    :ok
  end

  # The version's leg rules in id order, which is the order the inverse reads and
  # writes them in. Every read here is scoped to the organization and version
  # together (INV-5).
  defp scoped_leg_rules(organization_id, gtfs_version_id) do
    FareLegRule
    |> scoped(organization_id, gtfs_version_id)
    |> order_by([rule], rule.id)
    |> Repo.all()
  end

  # The products this version's editor recorded as passes, whose leg rules
  # `Fares.Normalize` owns (R4, INV-4).
  defp version_pass_ids(organization_id, gtfs_version_id) do
    FareProductDetail
    |> scoped(organization_id, gtfs_version_id)
    |> where([detail], detail.kind == ^@pass_kind)
    |> select([detail], detail.fare_product_id)
    |> Repo.all()
    |> MapSet.new()
  end

  defp undo_rule(organization_id, gtfs_version_id, operation_id, inverse) do
    with :ok <- require_entry(operation_id, organization_id, gtfs_version_id),
         :ok <- require_rule_unchanged(organization_id, gtfs_version_id, inverse) do
      restore_rule(organization_id, gtfs_version_id, inverse)

      {:ok,
       %{
         before: [],
         after: [],
         inverse: nil,
         operation_id: operation_id,
         action: "rolled_back",
         rolled_back_to_log_id: operation_id
       }}
    end
  end

  defp undo_pass_acceptance(organization_id, gtfs_version_id, operation_id, inverse) do
    with :ok <- require_entry(operation_id, organization_id, gtfs_version_id),
         :ok <- require_acceptance_unchanged(inverse, organization_id, gtfs_version_id) do
      restore_pass_acceptance(organization_id, gtfs_version_id, inverse)

      {:ok,
       %{
         before: [],
         after: [],
         inverse: nil,
         operation_id: operation_id,
         action: "rolled_back",
         rolled_back_to_log_id: operation_id
       }}
    end
  end

  # -- Writing one fare ------------------------------------------------------------

  defp apply_fare(organization_id, gtfs_version_id, name, params) do
    products = version_products(organization_id, gtfs_version_id)

    with {:ok, product_id} <- fare_product_id(products, name, params),
         {:ok, media_ids} <- fare_media_ids(organization_id, gtfs_version_id, params),
         {:ok, riders} <-
           fare_rider_ids(organization_id, gtfs_version_id, products, product_id, params),
         {:ok, kind} <- fare_kind(params),
         {:ok, accepted} <-
           fare_accepted_networks(organization_id, gtfs_version_id, kind, params),
         {:ok, changes} <-
           fare_changes(product_id, media_ids, riders, params, name, currency(products)) do
      # A fare the version did not hold before this write is a create, and its
      # entry says so the way every other entity type's does.
      write_fare_rows(
        organization_id,
        gtfs_version_id,
        %{
          product_id: product_id,
          name: name,
          kind: kind,
          accepted: accepted,
          params: params,
          changes: changes,
          # A fare the version did not hold before this write is a create, and
          # its entry says so the way every other entity type's does.
          action: if(known_fare?(products, product_id), do: "updated", else: "created")
        },
        products
      )
    end
  end

  # The fence runs before anything is written, so a reviewed price that has moved
  # refuses the whole save rather than half of it (R15). Everything below it shares
  # `write_prices/4` with the grid's own writer, so R9's parsing, rounding, blank
  # and inverse rules are this writer's rules rather than a second set of them.
  defp write_fare_rows(organization_id, gtfs_version_id, fare, products) do
    case fare_stale(fare.product_id, fare.params, products) do
      [] ->
        write_fare_prices(organization_id, gtfs_version_id, fare, products)

      stale ->
        {:error, {:stale, stale}}
    end
  end

  defp write_fare_prices(organization_id, gtfs_version_id, fare, products) do
    %{product_id: product_id, name: name, changes: changes} = fare

    with {:ok, written} <- write_prices(organization_id, gtfs_version_id, changes, products),
         {:ok, renamed} <-
           rename_fare(organization_id, gtfs_version_id, product_id, products, name),
         {:ok, detail} <- write_fare_detail(organization_id, gtfs_version_id, fare) do
      {:ok,
       %{
         before: written.before,
         after: written.after,
         action: fare.action,
         inverse: %{
           operation: :save,
           fare_product_id: product_id,
           fare_products: written.inverse.fare_products,
           name: renamed,
           detail: detail
         }
       }}
    end
  end

  # Whether this version already held a fare under this id, which is what tells
  # a fare save's create from its update.
  defp known_fare?(products, product_id) do
    Enum.any?(products, &(&1.fare_product_id == product_id))
  end

  # The price cells the form names, one per rider type and payment method, in
  # the order the grid reads them. A cell the form leaves blank carries a `nil`
  # amount, which is the row this fare no longer has for that rider type and
  # method: blank means not sold (R9). A blank cell is kept in the list rather
  # than dropped, because that is what deletes the row it stands for.
  defp fare_changes(product_id, media_ids, riders, params, name, code) do
    prices = fare_param(params, :prices) || %{}
    media_prices = fare_param(params, :media_prices) || %{}

    parsed =
      for rider <- riders, medium <- media_ids do
        cell = %{
          key: {product_id, rider, medium},
          reviewed: nil,
          amount: fare_cell_amount(prices, media_prices, medium, rider),
          name: name,
          currency: code
        }

        case parse_amount(cell, code) do
          {:ok, amount} -> {:ok, %{cell | amount: amount}}
          {:error, reason} -> {:error, reason}
        end
      end

    case Enum.find(parsed, &match?({:error, _reason}, &1)) do
      nil -> {:ok, Enum.map(parsed, &elem(&1, 1))}
      {:error, reason} -> {:error, reason}
    end
  end

  # The reviewed cells of a fare, checked against what is stored before anything
  # is written. `reviewed` is optional: a form that did not review the fare's
  # prices has no fence to trip, which is the case a create always is.
  defp fare_stale(_product_id, params, products) do
    case fare_param(params, :reviewed) do
      reviewed when is_list(reviewed) ->
        changes =
          Enum.map(reviewed, fn cell ->
            %{
              key: cell_key(cell),
              reviewed: cell[:reviewed] || cell[:amount],
              amount: cell[:amount]
            }
          end)

        stale_cells(changes, products)

      _other ->
        []
    end
  end

  # A method's own price where the form gave one, the fare's price for that
  # rider type otherwise. A blank is `nil`, which is the row this fare no longer
  # has for that rider type and method (R9).
  defp fare_cell_amount(prices, media_prices, medium, rider) do
    case Map.fetch(Map.get(media_prices, medium) || %{}, rider) do
      {:ok, amount} -> amount
      :error -> Map.get(prices, rider)
    end
  end

  # The rider types the form prices: every rider type it names a price for, on
  # the fare or on one of its methods, beside every rider type this fare already
  # has a row for, so a rider type the editor blanked is deleted rather than
  # kept. A rider type this version does not hold answers `:not_found` (INV-5).
  defp fare_rider_ids(organization_id, gtfs_version_id, products, product_id, params) do
    prices = fare_param(params, :prices) || %{}
    media_prices = fare_param(params, :media_prices) || %{}

    named =
      Map.keys(prices) ++
        Enum.flat_map(Map.values(media_prices), &Map.keys/1) ++
        for(row <- products, row.fare_product_id == product_id, do: row.rider_category_id)

    known = version_rider_ids(organization_id, gtfs_version_id)
    riders = named |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()

    if Enum.all?(riders, &MapSet.member?(known, &1)) do
      {:ok, riders}
    else
      {:error, :not_found}
    end
  end

  defp version_rider_ids(organization_id, gtfs_version_id) do
    RiderCategory
    |> scoped(organization_id, gtfs_version_id)
    |> select([rider], rider.rider_category_id)
    |> Repo.all()
    |> MapSet.new()
  end

  # The payment methods the form names, each of which must be a method this
  # version holds. A fare sold no way at all cannot be priced, so a form naming
  # none answers `:no_payment_methods` rather than writing nothing.
  defp fare_media_ids(organization_id, gtfs_version_id, params) do
    case params |> fare_param(:media_ids) |> List.wrap() |> Enum.map(&to_string/1) do
      [] ->
        {:error, :no_payment_methods}

      media_ids ->
        known = version_media_ids(organization_id, gtfs_version_id)

        if media_ids |> Enum.uniq() |> Enum.all?(&MapSet.member?(known, &1)) do
          {:ok, media_ids}
        else
          {:error, :not_found}
        end
    end
  end

  defp version_media_ids(organization_id, gtfs_version_id) do
    FareMedia
    |> scoped(organization_id, gtfs_version_id)
    |> select([medium], medium.fare_media_id)
    |> Repo.all()
    |> MapSet.new()
  end

  defp fare_kind(params) do
    case fare_param(params, :kind) || "single" do
      kind when kind in @fare_kinds -> {:ok, kind}
      _other -> {:error, :invalid_kind}
    end
  end

  # R4: a pass's accepted networks are the leg groups it stands in for, and an
  # empty list means it is accepted nowhere. Anything else has to be a network of
  # this version or R4's name for the rules that name none.
  defp fare_accepted_networks(_organization_id, _gtfs_version_id, kind, _params)
       when kind != "pass",
       do: {:ok, []}

  defp fare_accepted_networks(organization_id, gtfs_version_id, "pass", params) do
    accepted =
      params
      |> fare_param(:accepted_network_ids)
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.uniq()
      |> Enum.sort()

    known =
      Network
      |> scoped(organization_id, gtfs_version_id)
      |> select([network], network.network_id)
      |> Repo.all()

    allowed = MapSet.new([@all_routes_accepted | known])

    if Enum.all?(accepted, &MapSet.member?(allowed, &1)) do
      {:ok, accepted}
    else
      {:error, :not_found}
    end
  end

  defp fare_product_id(products, name, params) do
    case fare_param(params, :fare_product_id) do
      nil ->
        id = fare_slug(name)

        cond do
          id == "" -> {:error, name_changeset(name, "must have a letter or a number")}
          Enum.any?(products, &(&1.fare_product_id == id)) -> {:error, :duplicate_fare}
          true -> {:ok, id}
        end

      "" ->
        {:error, :not_found}

      id when is_binary(id) ->
        if Enum.any?(products, &(&1.fare_product_id == id)) do
          {:ok, id}
        else
          {:error, :not_found}
        end

      _other ->
        {:error, :not_found}
    end
  end

  # A fare's GTFS id is its name the way `Fares.Conversion` writes a route
  # group's: lower case, with every run of other characters one underscore.
  defp fare_slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  # Every row of one fare carries its name, so a rename writes all of them and
  # the inverse carries the name they held.
  defp rename_fare(organization_id, gtfs_version_id, product_id, products, name) do
    stored =
      products
      |> Enum.filter(&(&1.fare_product_id == product_id))
      |> Enum.map(& &1.fare_product_name)
      |> Enum.uniq()

    previous = List.first(stored)

    cond do
      stored == [] ->
        {:ok, %{before: nil, after: name}}

      stored == [name] ->
        {:ok, %{before: name, after: name}}

      true ->
        now = DateTime.utc_now()

        Repo.update_all(
          from(row in FareProduct,
            where:
              row.organization_id == ^organization_id and
                row.gtfs_version_id == ^gtfs_version_id and
                row.fare_product_id == ^product_id
          ),
          set: [fare_product_name: name, updated_at: now]
        )

        {:ok, %{before: previous, after: name}}
    end
  end

  # The one `fare_product_details` row of a fare, written through its own
  # changeset so `kind` passes the same check every other writer of that column
  # passes. A fare with no row yet gets one, and a new fare's place in the
  # editor's order is after the fares already there unless the form names one.
  defp write_fare_detail(organization_id, gtfs_version_id, fare) do
    %{
      product_id: product_id,
      kind: kind,
      accepted: accepted,
      params: params
    } = fare

    case detail_row(organization_id, gtfs_version_id, product_id) do
      nil ->
        attrs = %{
          fare_product_id: product_id,
          kind: kind,
          position: fare_position(organization_id, gtfs_version_id, params, nil),
          accepted_network_ids: accepted
        }

        row = fare_detail_changeset(%FareProductDetail{}, organization_id, gtfs_version_id, attrs)

        case Repo.insert(row) do
          {:ok, detail} -> {:ok, %{id: detail.id, before: nil, after: detail_attrs(detail)}}
          {:error, changeset} -> Repo.rollback(changeset)
        end

      detail ->
        attrs = %{
          kind: kind,
          position: fare_position(organization_id, gtfs_version_id, params, detail),
          accepted_network_ids: accepted
        }

        case detail |> FareProductDetail.changeset(attrs) |> Repo.update() do
          {:ok, updated} ->
            {:ok, %{id: detail.id, before: detail_attrs(detail), after: detail_attrs(updated)}}

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
    end
  end

  defp fare_detail_changeset(
         %FareProductDetail{} = detail,
         organization_id,
         gtfs_version_id,
         attrs
       ) do
    FareProductDetail.changeset(
      Map.merge(detail, %{organization_id: organization_id, gtfs_version_id: gtfs_version_id}),
      attrs
    )
  end

  defp fare_position(organization_id, gtfs_version_id, params, nil) do
    case fare_param(params, :position) do
      position when is_integer(position) -> position
      _other -> detail_count(organization_id, gtfs_version_id)
    end
  end

  defp fare_position(_organization_id, _gtfs_version_id, params, detail) do
    case fare_param(params, :position) do
      position when is_integer(position) -> position
      _other -> detail.position
    end
  end

  # A new fare's place in the editor's own order is after the fares this version
  # already has, which is scoped to the version rather than counted across every
  # organization (INV-5).
  defp detail_count(organization_id, gtfs_version_id) do
    FareProductDetail
    |> scoped(organization_id, gtfs_version_id)
    |> select([detail], count())
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp detail_row(organization_id, gtfs_version_id, product_id) do
    FareProductDetail
    |> scoped(organization_id, gtfs_version_id)
    |> where([detail], detail.fare_product_id == ^product_id)
    |> Repo.one()
  end

  defp detail_attrs(detail) do
    %{
      kind: detail.kind,
      position: detail.position,
      accepted_network_ids: detail.accepted_network_ids
    }
  end

  # The fare's own name, for the summary a delete records. A fare this version
  # does not hold answers `nil`, which the caller turns into the id it named —
  # the write refuses a fare it cannot find, so nothing else depends on it.
  defp fare_display_name(organization_id, gtfs_version_id, product_id) do
    organization_id
    |> version_products(gtfs_version_id)
    |> Enum.filter(&(&1.fare_product_id == product_id))
    |> fare_rows_name()
  end

  defp trimmed_name(params) do
    case fare_param(params, :name) do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> {:error, name_changeset(name, "can't be blank")}
          trimmed -> {:ok, trimmed}
        end

      _other ->
        {:error, name_changeset(nil, "can't be blank")}
    end
  end

  # A blank or unreadable name answers a changeset with an error on `:name`, so
  # the drawer renders the same summary and the same inline message it renders
  # for every other invalid field. This is the one place a name is refused: a
  # stored `fare_product_name` may still hold nothing for an imported row
  # (AC-1), because that row is not one an operator is looking at.
  defp name_changeset(name, message) do
    %FareProduct{}
    |> Ecto.Changeset.change(%{fare_product_name: name})
    |> Map.put(:action, :insert)
    |> Ecto.Changeset.add_error(:name, message)
  end

  defp fare_save_summary(params, name) do
    if fare_param(params, :fare_product_id) do
      "Updated the fare \"#{name}\""
    else
      "Created the fare \"#{name}\""
    end
  end

  # A drawer hands over atom keys, and a form that did not send an optional field
  # leaves it out rather than sending `nil`, so every reader of the form's own
  # keys goes through here.
  defp fare_param(params, key) do
    case params do
      %{^key => value} -> value
      _other -> Map.get(params, Atom.to_string(key))
    end
  end

  # -- Deleting one fare -----------------------------------------------------------

  defp remove_fare(organization_id, gtfs_version_id, product_id, replacement, expected) do
    products = version_products(organization_id, gtfs_version_id)
    rows = Enum.filter(products, &(&1.fare_product_id == product_id))
    detail = detail_row(organization_id, gtfs_version_id, product_id)

    case delete_stale(rows, detail, expected, products) do
      [] when rows != [] or not is_nil(detail) ->
        settle_fare_rules(organization_id, gtfs_version_id, product_id, replacement, rows, detail)

      [] ->
        {:error, :not_found}

      stale ->
        {:error, {:stale, stale}}
    end
  end

  # The facts the editor reviewed before confirming the delete. `:name` is the
  # fare's own name, `:kind` and `:accepted_network_ids` its detail row's, and
  # `:prices` the cell list `save_prices/2` takes, so a fare whose prices have
  # moved since the drawer opened refuses here exactly as a grid save does.
  defp delete_stale(rows, detail, expected, products) do
    name_stale(expected, fare_rows_name(rows)) ++
      detail_stale(detail, expected) ++
      case Map.get(expected, :prices) do
        nil -> []
        _reviewed -> fare_stale(nil, %{reviewed: expected.prices}, products)
      end
  end

  # The name the editor reviewed before confirming the delete, which is the one
  # fact a rider type or payment method drawer shows besides its type. A form
  # that reviewed no name has no fence to trip.
  defp name_stale(expected, stored) do
    case Map.fetch(expected, :name) do
      :error ->
        []

      {:ok, name} ->
        if stored == name do
          []
        else
          [%{field: :name, reviewed: name, stored: stored}]
        end
    end
  end

  defp detail_stale(detail, expected) do
    Enum.flat_map([:kind, :accepted_network_ids], fn field ->
      expected |> Map.fetch(field) |> stale_detail_cell(detail, field)
    end)
  end

  defp stale_detail_cell(:error, _detail, _field), do: []

  defp stale_detail_cell({:ok, reviewed}, detail, field) do
    stored = detail && Map.get(detail, field)

    if stored == reviewed, do: [], else: [%{field: field, reviewed: reviewed, stored: stored}]
  end

  defp fare_rows_name(rows) do
    case Enum.find(rows, &is_binary(&1.fare_product_name)) do
      nil -> nil
      row -> row.fare_product_name
    end
  end

  # R5's own rows and the leg rules both point at a product, so a deleted fare
  # must leave neither naming it (FH-17). A replacement points them somewhere
  # else, `:remove_rules` deletes them, and no replacement at all is refused
  # while any of them exists: an operator confirming a delete did not mean to
  # leave the version's cells unpriced.
  defp settle_fare_rules(organization_id, gtfs_version_id, product_id, replacement, rows, detail) do
    rules = fare_rules(organization_id, gtfs_version_id, product_id)

    case replacement do
      nil ->
        if rules == [] do
          drop_fare(organization_id, gtfs_version_id, product_id, rows, detail, [])
        else
          {:error, :replacement_required}
        end

      :remove_rules ->
        removed = remove_fare_rules(organization_id, gtfs_version_id, rules)
        drop_fare(organization_id, gtfs_version_id, product_id, rows, detail, removed)

      replacement when is_binary(replacement) ->
        products = version_products(organization_id, gtfs_version_id)

        cond do
          replacement == product_id ->
            {:error, :conflicting_rule}

          not Enum.any?(products, &(&1.fare_product_id == replacement)) ->
            {:error, :not_found}

          conflicting = conflicting_rule(organization_id, gtfs_version_id, rules, replacement) ->
            {:error, {:conflicting_rule, conflicting}}

          true ->
            moved = move_fare_rules(organization_id, gtfs_version_id, product_id, replacement)
            drop_fare(organization_id, gtfs_version_id, product_id, rows, detail, moved)
        end
    end
  end

  # The rules that name the fare: its leg rules and any transfer rule naming it
  # as the difference or fee product. Every read is scoped to this version
  # (INV-5), so another version's rule can never be moved by this write.
  defp fare_rules(organization_id, gtfs_version_id, product_id) do
    leg =
      from(rule in FareLegRule,
        where:
          rule.organization_id == ^organization_id and
            rule.gtfs_version_id == ^gtfs_version_id and
            rule.fare_product_id == ^product_id,
        order_by: rule.id,
        select: {:leg_rule, rule.id}
      )
      |> Repo.all()

    transfer =
      from(rule in FareTransferRule,
        where:
          rule.organization_id == ^organization_id and
            rule.gtfs_version_id == ^gtfs_version_id and
            rule.fare_product_id == ^product_id,
        order_by: rule.id,
        select: {:transfer_rule, rule.id}
      )
      |> Repo.all()

    Enum.sort(leg ++ transfer)
  end

  # GTFS states one rule per set of conditions and fare, so pointing a rule at a
  # replacement that already states the same conditions would write two rows the
  # unique index refuses. The rule that would collide is named, so the drawer can
  # offer its overlap choice (AC-20) rather than the operator seeing a failed
  # save with nothing to act on.
  defp conflicting_rule(organization_id, gtfs_version_id, rules, replacement) do
    moving = moving_leg_rules(organization_id, gtfs_version_id, rules)

    existing =
      from(rule in FareLegRule,
        where:
          rule.organization_id == ^organization_id and
            rule.gtfs_version_id == ^gtfs_version_id and
            rule.fare_product_id == ^replacement,
        select: rule
      )
      |> Repo.all()

    Enum.find_value(existing, fn rule ->
      if Enum.any?(moving, &same_conditions?(&1, rule)), do: rule
    end)
  end

  defp moving_leg_rules(organization_id, gtfs_version_id, rules) do
    ids = for {:leg_rule, id} <- rules, do: id

    if ids == [] do
      []
    else
      from(rule in FareLegRule,
        where:
          rule.organization_id == ^organization_id and
            rule.gtfs_version_id == ^gtfs_version_id and
            rule.id in ^ids,
        select: rule
      )
      |> Repo.all()
    end
  end

  defp same_conditions?(left, right) do
    left.network_id == right.network_id and left.from_area_id == right.from_area_id and
      left.to_area_id == right.to_area_id and
      left.from_timeframe_group_id == right.from_timeframe_group_id and
      left.to_timeframe_group_id == right.to_timeframe_group_id
  end

  # The rules are read before the move, so the inverse records what each named
  # and the id it had: undo restores the same row rather than a new one carrying
  # the same conditions.
  defp move_fare_rules(organization_id, gtfs_version_id, product_id, replacement) do
    before = fare_rules(organization_id, gtfs_version_id, product_id)
    now = DateTime.utc_now()

    from(rule in FareLegRule,
      where:
        rule.organization_id == ^organization_id and
          rule.gtfs_version_id == ^gtfs_version_id and
          rule.fare_product_id == ^product_id
    )
    |> Repo.update_all(set: [fare_product_id: replacement, updated_at: now])

    from(rule in FareTransferRule,
      where:
        rule.organization_id == ^organization_id and
          rule.gtfs_version_id == ^gtfs_version_id and
          rule.fare_product_id == ^product_id
    )
    |> Repo.update_all(set: [fare_product_id: replacement, updated_at: now])

    Enum.map(before, fn
      {:leg_rule, id} ->
        %{kind: :leg_rule, id: id, before: product_id, after: replacement}

      {:transfer_rule, id} ->
        %{kind: :transfer_rule, id: id, before: product_id, after: replacement}
    end)
  end

  # `:remove_rules` deletes the rules themselves, and the inverse carries each
  # deleted row whole so undo puts back the rule with the id it had.
  defp remove_fare_rules(organization_id, gtfs_version_id, rules) do
    Enum.map(rules, fn
      {:leg_rule, id} ->
        row = fetch_leg_rule(organization_id, gtfs_version_id, id)
        if row, do: Repo.delete_all(from(rule in FareLegRule, where: rule.id == ^id))
        %{kind: :leg_rule, id: id, row: row && row_snapshot(row)}

      {:transfer_rule, id} ->
        row = fetch_transfer_rule(organization_id, gtfs_version_id, id)
        if row, do: Repo.delete_all(from(rule in FareTransferRule, where: rule.id == ^id))
        %{kind: :transfer_rule, id: id, row: row && row_snapshot(row)}
    end)
  end

  defp fetch_leg_rule(organization_id, gtfs_version_id, id) do
    FareLegRule
    |> where(
      [rule],
      rule.id == ^id and rule.organization_id == ^organization_id and
        rule.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.one()
  end

  defp fetch_transfer_rule(organization_id, gtfs_version_id, id) do
    FareTransferRule
    |> where(
      [rule],
      rule.id == ^id and rule.organization_id == ^organization_id and
        rule.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.one()
  end

  # The fare's own rows and its detail row go, and the inverse carries them whole
  # with the ids they had, so `undo/3` puts back the rows a rule pointed at.
  defp drop_fare(organization_id, gtfs_version_id, product_id, rows, detail, rules) do
    Repo.delete_all(
      from(row in FareProduct,
        where:
          row.organization_id == ^organization_id and
            row.gtfs_version_id == ^gtfs_version_id and
            row.fare_product_id == ^product_id
      )
    )

    if detail, do: Repo.delete_all(from(row in FareProductDetail, where: row.id == ^detail.id))

    {:ok,
     %{
       before:
         [fare_name_log_row(product_id, fare_rows_name(rows))] ++
           Enum.map(rules, &fare_rule_log_row/1),
       after: [],
       action: "deleted",
       inverse: %{
         operation: :delete,
         fare_product_id: product_id,
         name: fare_rows_name(rows),
         fare_products: Enum.map(rows, &row_snapshot/1),
         detail: detail && row_snapshot(detail),
         rules: rules
       }
     }}
  end

  # A whole row, kept in an inverse so undo restores it with the id it had rather
  # than building a replacement from the values that survived. The struct itself
  # is kept rather than a plain map, because `Ecto.Changeset.change/2` needs the
  # schema to insert it back — the same shape `save_prices/2`'s inverse carries.
  defp row_snapshot(row), do: row

  defp fare_name_log_row(product_id, name) do
    %{"fare_product_id" => product_id, "fare_product_name" => name}
  end

  defp fare_rule_log_row(%{kind: kind, id: id, row: row}) do
    %{
      "rule" => Atom.to_string(kind),
      "rule_id" => id,
      "fare_product_id" => row && row.fare_product_id
    }
  end

  defp fare_rule_log_row(%{kind: kind, id: id, after: product_id}) do
    %{"rule" => Atom.to_string(kind), "rule_id" => id, "fare_product_id" => product_id}
  end

  # Every cell is checked before anything is written, so one stale cell refuses
  # the whole save rather than half of it. A cell with no amount at all is a
  # save of nothing, which is refused rather than recorded as an operation.
  defp apply_prices(_organization_id, _gtfs_version_id, []) do
    {:error, :no_prices}
  end

  defp apply_prices(organization_id, gtfs_version_id, cells) do
    products = version_products(organization_id, gtfs_version_id)
    code = currency(products)

    with {:ok, changes} <- price_changes(cells, products, code) do
      case stale_cells(changes, products) do
        [] -> write_prices(organization_id, gtfs_version_id, changes, products)
        stale -> {:error, {:stale, stale}}
      end
    end
  end

  defp version_products(organization_id, gtfs_version_id) do
    FareProduct
    |> scoped(organization_id, gtfs_version_id)
    |> Repo.all()
  end

  # Each cell becomes a `%{key, reviewed, amount}` change, or the whole save is
  # refused. `amount` is the parsed, rounded price, or `nil` for a blank cell.
  defp price_changes(cells, products, code) do
    Enum.reduce_while(cells, {:ok, []}, fn cell, {:ok, changes} ->
      case price_change(cell, products, code) do
        {:ok, change} -> {:cont, {:ok, [change | changes]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, changes} -> {:ok, Enum.reverse(changes)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp price_change(cell, products, code) do
    key = cell_key(cell)

    with {:ok, product} <- fetch_product(products, key),
         {:ok, amount} <- parse_amount(cell, code) do
      {:ok,
       %{
         key: key,
         reviewed: cell[:reviewed],
         amount: amount,
         name: product.fare_product_name,
         currency: product.currency || code
       }}
    end
  end

  # The product the cell names, which is any row of this version carrying that
  # `fare_product_id`. A cell naming no product of this version answers
  # `{:error, :not_found}` — that is what another organization's or version's
  # product id is here (AC-26, INV-5).
  defp fetch_product(products, {product_id, _rider_id, _media_id}) do
    case Enum.find(products, &(&1.fare_product_id == product_id)) do
      nil -> {:error, :not_found}
      product -> {:ok, product}
    end
  end

  defp cell_key(cell) do
    {cell[:fare_product_id], cell[:rider_category_id], cell[:fare_media_id]}
  end

  # A price arrives as the `Decimal` a preview computed or as the string an
  # operator typed, and `Fares.Money.parse/1` is the one place either is read
  # (R9). A blank cell parses to `nil`, which deletes the row rather than
  # storing a zero, and an unreadable cell is refused rather than treated as
  # blank — a mistyped cell must never delete a price. A negative amount is
  # refused too: a `fare_products` row may hold one, but only the transfer-fee
  # writer stores one (R9).
  defp parse_amount(cell, code) do
    cell[:amount]
    |> money_amount()
    |> case do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, amount} ->
        if Decimal.negative?(amount) do
          {:error, :invalid_price}
        else
          {:ok, Decimal.round(amount, Money.minor_units(code))}
        end

      {:error, :invalid} ->
        {:error, :invalid_price}
    end
  end

  # A price reaches this writer either as the string an operator typed, which
  # `Fares.Money.parse/1` reads, or as the `Decimal` a preview computed for this
  # package's own writers — `preview_price_change/3` hands its rows straight to
  # `apply_price_change/3` — which is already a price and needs only the
  # currency's minor units below. A `Decimal` is never read from a person, so
  # `Money.parse/1` is not asked to parse one.
  defp money_amount(%Decimal{} = amount), do: {:ok, amount}
  defp money_amount(amount), do: Money.parse(amount)

  # The fence: every cell's stored row must still hold the amount the editor
  # reviewed, and a cell that reviewed no row must still have none. The answer
  # names each offending cell and the amount stored now, which is what the grid
  # reloads from.
  defp stale_cells(changes, products) do
    Enum.flat_map(changes, fn change -> stale_cell(change, products) end)
  end

  defp stale_cell(change, products) do
    case stored_amount(products, change.key) do
      {:ok, stored} ->
        if same_amount?(stored, change.reviewed), do: [], else: [named_stale_cell(change, stored)]

      :missing ->
        if is_nil(change.reviewed), do: [], else: [named_stale_cell(change, nil)]
    end
  end

  defp stored_amount(products, key) do
    case Enum.find(products, &(product_key(&1) == key)) do
      nil -> :missing
      product -> {:ok, product.amount}
    end
  end

  # `numeric` columns keep no scale, so a stored zero reads back as `0` and not
  # as `0.00`; `Decimal.equal?/2` compares the amount rather than the scale
  # Postgres happened to keep.
  defp same_amount?(nil, nil), do: true
  defp same_amount?(_stored, nil), do: false
  defp same_amount?(nil, _reviewed), do: false
  defp same_amount?(stored, %Decimal{} = reviewed), do: Decimal.equal?(stored, reviewed)

  defp named_stale_cell(change, stored) do
    {product_id, rider_id, media_id} = change.key

    %{
      fare_product_id: product_id,
      rider_category_id: rider_id,
      fare_media_id: media_id,
      reviewed: change.reviewed,
      stored: stored
    }
  end

  # Writes the cells and returns the change-log rows beside the inverse
  # `undo/3` applies. A cell whose stored amount already equals the new one is
  # left alone and names nothing in either set, so an editor who saved without
  # changing anything records one entry with empty before and after.
  defp write_prices(organization_id, gtfs_version_id, changes, products) do
    {inverse, before_rows, after_rows} =
      Enum.reduce(changes, {[], [], []}, fn change, {inverse, before_rows, after_rows} ->
        case write_price(organization_id, gtfs_version_id, change, products) do
          :unchanged ->
            {inverse, before_rows, after_rows}

          {state, before_row, after_row} ->
            {[state | inverse], [before_row | before_rows], [after_row | after_rows]}
        end
      end)

    {:ok,
     %{
       before: Enum.reverse(before_rows),
       after: Enum.reverse(after_rows),
       inverse: %{fare_products: Enum.reverse(inverse)}
     }}
  end

  defp write_price(organization_id, gtfs_version_id, change, products) do
    case Enum.find(products, &(product_key(&1) == change.key)) do
      nil -> insert_price(organization_id, gtfs_version_id, change)
      product -> update_price(organization_id, gtfs_version_id, product, change)
    end
  end

  # A blank cell for a row the fare was never sold on: there is nothing to
  # delete, so nothing is written and the inverse names nothing.
  defp insert_price(_organization_id, _gtfs_version_id, %{amount: nil}), do: :unchanged

  # A new price for a rider type or a payment method the fare is not sold on.
  # The row names the product it extends, so one fare keeps one name and one
  # currency across every rider and method.
  defp insert_price(organization_id, gtfs_version_id, change) do
    {product_id, rider_id, media_id} = change.key

    %FareProduct{}
    |> Map.merge(%{organization_id: organization_id, gtfs_version_id: gtfs_version_id})
    |> FareProduct.changeset(%{
      fare_product_id: product_id,
      fare_product_name: change.name,
      fare_media_id: media_id,
      rider_category_id: rider_id,
      amount: change.amount,
      currency: change.currency
    })
    |> Repo.insert()
    |> case do
      {:ok, product} ->
        {%{key: change.key, id: product.id, before: nil, after: change.amount},
         log_row(change.key, nil), log_row(change.key, change.amount)}

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp update_price(_organization_id, _gtfs_version_id, %FareProduct{amount: nil}, %{amount: nil}) do
    :unchanged
  end

  # A blank cell deletes the row: blank means not sold, which is a missing row
  # rather than a zero (R9). The whole row goes into the inverse, so undo puts
  # back the row the import or an earlier write created rather than one rebuilt
  # from the cell alone.
  defp update_price(organization_id, gtfs_version_id, product, %{amount: nil}) do
    delete_price(organization_id, gtfs_version_id, product)

    key = product_key(product)

    {%{key: key, id: product.id, before: product.amount, after: nil, row: product},
     log_row(key, product.amount), log_row(key, nil)}
  end

  defp update_price(_organization_id, _gtfs_version_id, product, change) do
    if same_amount?(product.amount, change.amount) do
      :unchanged
    else
      change_price(product, change.amount)
      key = product_key(product)

      {%{key: key, id: product.id, before: product.amount, after: change.amount},
       log_row(key, product.amount), log_row(key, change.amount)}
    end
  end

  defp delete_price(organization_id, gtfs_version_id, product) do
    Repo.delete_all(
      from(row in FareProduct,
        where:
          row.id == ^product.id and row.organization_id == ^organization_id and
            row.gtfs_version_id == ^gtfs_version_id
      )
    )
  end

  # The row is changed through its own changeset rather than with `update_all`,
  # so the amount passes the same `validate_required/1` every other write of
  # this table does. The row was read through the scoped query inside the version
  # lock, so it is this version's own row (INV-5).
  defp change_price(product, amount) do
    product
    |> Ecto.Changeset.change(%{amount: amount})
    |> Repo.update!()
  end

  # The rows a change-log entry records, with the amounts as strings: a
  # `Decimal` is not a JSON value, and an amount in the history is a thing to
  # read rather than to compute with. A cell with no amount names a deleted row.
  defp log_row({product_id, rider_id, media_id}, amount) do
    %{
      "fare_product_id" => product_id,
      "rider_category_id" => rider_id,
      "fare_media_id" => media_id,
      "amount" => amount_text(amount)
    }
  end

  defp amount_text(nil), do: nil
  defp amount_text(amount), do: Decimal.to_string(amount)

  defp product_key(product) do
    {product.fare_product_id, product.rider_category_id, product.fare_media_id}
  end

  # -- Undoing a price change -----------------------------------------------------

  # -- Undoing a fare change ------------------------------------------------------

  # Applies a `save_rider_type/2`, `delete_rider_type/3`,
  # `save_payment_method/2` or `delete_payment_method/3` inverse.
  #
  # These four writers share one inverse key, because each changes two things:
  # the `rider_categories` or `fare_media` row, and the `fare_products` rows that
  # named it. A save's price rows are checked through the same fence
  # `save_prices/2`'s inverse uses; a delete's rows must still be gone, and the
  # definition row a save wrote must still hold what that save left. Anything else
  # answers `{:error, :stale}` and changes nothing (R15, AC-26).
  defp undo_definition(organization_id, gtfs_version_id, operation_id, inverse) do
    with :ok <- require_entry(operation_id, organization_id, gtfs_version_id),
         :ok <- require_definition_unchanged(organization_id, gtfs_version_id, inverse) do
      restore_definition(organization_id, gtfs_version_id, inverse)

      {:ok,
       %{
         before: [],
         after: [],
         inverse: nil,
         operation_id: operation_id,
         action: "rolled_back",
         rolled_back_to_log_id: operation_id
       }}
    end
  end

  # A saved definition's prices must still hold what the write left, and the
  # definition row itself must still be there; a deleted one's rows and its own
  # row must still be gone.
  defp require_definition_unchanged(organization_id, gtfs_version_id, inverse) do
    stale? =
      case inverse do
        %{operation: :save, fare_products: states, row: row, schema: schema} ->
          require_unchanged(organization_id, gtfs_version_id, states) == {:error, :stale} or
            not definition_present?(schema, organization_id, gtfs_version_id, row.id) or
            not definition_untouched?(schema, organization_id, gtfs_version_id, row)

        %{operation: :delete, fare_products: rows, row: row, schema: schema} ->
          Enum.any?(rows, &fetch_price(organization_id, gtfs_version_id, &1.id)) or
            definition_present?(schema, organization_id, gtfs_version_id, row.id)

        _other ->
          true
      end

    if stale?, do: {:error, :stale}, else: :ok
  end

  # R15's fence for a saved definition: the row must still hold the values this
  # write left, not merely still be there. A rider type renamed since the write,
  # or a method whose name or kind moved, is a later edit the reversal must not
  # revert on top of.
  defp definition_untouched?(schema, organization_id, gtfs_version_id, row) do
    current =
      from(r in schema,
        where:
          r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id and
            r.id == ^row.id
      )
      |> Repo.one()

    current != nil and
      Enum.all?(row.after, fn {field, value} ->
        Map.fetch!(current, field) == value
      end)
  end

  defp definition_present?(schema, organization_id, gtfs_version_id, id) do
    Repo.exists?(
      from(row in schema,
        where:
          row.organization_id == ^organization_id and
            row.gtfs_version_id == ^gtfs_version_id and
            row.id == ^id
      )
    )
  end

  defp restore_definition(organization_id, gtfs_version_id, inverse) do
    case inverse do
      %{operation: :save} = inverse ->
        restore_prices(organization_id, gtfs_version_id, inverse.fare_products)
        restore_saved_row(organization_id, gtfs_version_id, inverse.schema, inverse.row)
        restore_default(organization_id, gtfs_version_id, inverse)

      %{operation: :delete} = inverse ->
        Enum.each(inverse.fare_products, &Repo.insert!(Ecto.Changeset.change(&1)))
        Repo.insert!(Ecto.Changeset.change(inverse.row))

        :ok
    end
  end

  # A definition row this write created is deleted again, and a row it changed
  # goes back to the values it held. Both statements re-assert the version pair,
  # so a row that moved between versions is never written through this path
  # (INV-5). The same two statements restore a saved route group row, which is
  # why this reads a row rather than one entity type.
  defp restore_saved_row(
         organization_id,
         gtfs_version_id,
         schema,
         %{before: nil, id: id}
       ) do
    Repo.delete_all(
      from(row in schema,
        where:
          row.organization_id == ^organization_id and
            row.gtfs_version_id == ^gtfs_version_id and
            row.id == ^id
      )
    )
  end

  defp restore_saved_row(
         organization_id,
         gtfs_version_id,
         schema,
         %{before: before, id: id}
       ) do
    Repo.update_all(
      from(row in schema,
        where:
          row.organization_id == ^organization_id and
            row.gtfs_version_id == ^gtfs_version_id and
            row.id == ^id
      ),
      set: Keyword.new(Map.merge(before, %{updated_at: DateTime.utc_now()}))
    )
  end

  # The rider type whose default flag this write cleared goes back to being the
  # default, since R8 needs exactly one and this write is what took it away.
  # A payment method change moves no flag, and answers `:ok` for this.
  defp restore_default(organization_id, gtfs_version_id, inverse) do
    case Map.get(inverse, :cleared_default) do
      nil ->
        :ok

      rider_id ->
        Repo.update_all(
          from(row in RiderCategory,
            where:
              row.organization_id == ^organization_id and
                row.gtfs_version_id == ^gtfs_version_id and
                row.rider_category_id == ^rider_id
          ),
          set: [is_default_fare_category: 1, updated_at: DateTime.utc_now()]
        )

        :ok
    end
  end

  # -- Undoing a route group change -----------------------------------------------

  # Applies a `save_route_group/2` or `delete_route_group/3` inverse.
  #
  # A saved group's row must still be there and still hold the name and routes
  # that write left, the rows it added must still be in it and the rows it
  # deleted — its own and those it took from another group — must still be gone.
  # A deleted group's own rows and the rules its delete settled must still be
  # gone, and each pass it stopped accepting must still hold the acceptance list
  # the delete left. Anything else answers `{:error, :stale}` and changes
  # nothing, so a reversal can never revert a later edit (R15, AC-26).
  defp undo_route_group(organization_id, gtfs_version_id, operation_id, inverse) do
    with :ok <- require_entry(operation_id, organization_id, gtfs_version_id),
         :ok <- require_group_unchanged(organization_id, gtfs_version_id, inverse) do
      restore_route_group(organization_id, gtfs_version_id, inverse)

      {:ok,
       %{
         before: [],
         after: [],
         inverse: nil,
         operation_id: operation_id,
         action: "rolled_back",
         rolled_back_to_log_id: operation_id
       }}
    end
  end

  defp require_group_unchanged(organization_id, gtfs_version_id, inverse) do
    stale? =
      case inverse do
        %{operation: :save} = inverse ->
          saved_group_stale?(organization_id, gtfs_version_id, inverse)

        %{operation: :delete} = inverse ->
          deleted_group_stale?(organization_id, gtfs_version_id, inverse)

        _other ->
          true
      end

    if stale?, do: {:error, :stale}, else: :ok
  end

  defp saved_group_stale?(organization_id, gtfs_version_id, inverse) do
    network = inverse.network
    rows = inverse.route_networks

    not definition_untouched?(Network, organization_id, gtfs_version_id, network) or
      Enum.any?(
        rows.removed ++ rows.moved,
        &definition_present?(RouteNetwork, organization_id, gtfs_version_id, &1.id)
      ) or
      not Enum.all?(
        rows.added,
        &route_network_untouched?(&1, organization_id, gtfs_version_id)
      )
  end

  defp deleted_group_stale?(organization_id, gtfs_version_id, inverse) do
    definition_present?(Network, organization_id, gtfs_version_id, inverse.network.id) or
      Enum.any?(
        inverse.route_networks,
        &definition_present?(RouteNetwork, organization_id, gtfs_version_id, &1.id)
      ) or
      Enum.any?(inverse.rules, &rule_present?(&1, organization_id, gtfs_version_id)) or
      not Enum.all?(
        inverse.passes,
        &pass_acceptance_untouched?(&1, organization_id, gtfs_version_id)
      )
  end

  # The membership row the save added must still name the group and the route it
  # added for, and no other row may hold that route: a route that has since been
  # moved to another group is a later edit this reversal must not revert.
  defp route_network_untouched?(row, organization_id, gtfs_version_id) do
    current =
      from(m in RouteNetwork,
        where:
          m.id == ^row.id and m.organization_id == ^organization_id and
            m.gtfs_version_id == ^gtfs_version_id
      )
      |> Repo.one()

    current != nil and current.network_id == row.network_id and current.route_id == row.route_id
  end

  defp rule_present?(%FareLegRule{} = rule, organization_id, gtfs_version_id) do
    Repo.exists?(
      from(r in FareLegRule,
        where:
          r.id == ^rule.id and r.organization_id == ^organization_id and
            r.gtfs_version_id == ^gtfs_version_id
      )
    )
  end

  defp rule_present?(%FareTransferRule{} = rule, organization_id, gtfs_version_id) do
    Repo.exists?(
      from(r in FareTransferRule,
        where:
          r.id == ^rule.id and r.organization_id == ^organization_id and
            r.gtfs_version_id == ^gtfs_version_id
      )
    )
  end

  # The pass must still accept exactly the groups the delete left it accepting.
  defp pass_acceptance_untouched?(state, organization_id, gtfs_version_id) do
    current =
      from(detail in FareProductDetail,
        where:
          detail.id == ^state.id and detail.organization_id == ^organization_id and
            detail.gtfs_version_id == ^gtfs_version_id,
        select: detail.accepted_network_ids
      )
      |> Repo.one()

    current == state.after
  end

  defp restore_route_group(organization_id, gtfs_version_id, %{operation: :save} = inverse) do
    rows = inverse.route_networks

    Enum.each(rows.removed ++ rows.moved, &Repo.insert!(Ecto.Changeset.change(&1)))
    delete_rows(RouteNetwork, organization_id, gtfs_version_id, rows.added)
    restore_saved_row(organization_id, gtfs_version_id, Network, inverse.network)

    :ok
  end

  defp restore_route_group(organization_id, gtfs_version_id, %{operation: :delete} = inverse) do
    Repo.insert!(Ecto.Changeset.change(inverse.network))
    Enum.each(inverse.route_networks, &Repo.insert!(Ecto.Changeset.change(&1)))
    Enum.each(inverse.rules, &Repo.insert!(Ecto.Changeset.change(&1)))

    now = DateTime.utc_now()

    Enum.each(inverse.passes, fn pass ->
      from(detail in FareProductDetail,
        where:
          detail.id == ^pass.id and detail.organization_id == ^organization_id and
            detail.gtfs_version_id == ^gtfs_version_id
      )
      |> Repo.update_all(set: [accepted_network_ids: pass.before, updated_at: now])
    end)

    :ok
  end

  # Applies a `save_fare/2` or `delete_fare/4` inverse.
  #
  # The entry this reversal names has to exist in this version, and every row the
  # write touched must still hold what that write left: a fare's price rows must
  # hold the amounts it left, a deleted fare's rows must still be gone, and a
  # rule it moved or deleted must still be where it left it. Anything else
  # answers `{:error, :stale}` and changes nothing, so undo can never revert a
  # later edit (R15, AC-26).
  defp undo_fare(organization_id, gtfs_version_id, operation_id, %{operation: _} = inverse) do
    with :ok <- require_entry(operation_id, organization_id, gtfs_version_id),
         :ok <- require_fare_unchanged(organization_id, gtfs_version_id, inverse) do
      restore_fare(organization_id, gtfs_version_id, inverse)

      {:ok,
       %{
         before: [],
         after: [],
         inverse: nil,
         operation_id: operation_id,
         action: "rolled_back",
         rolled_back_to_log_id: operation_id
       }}
    end
  end

  # The fence for a fare reversal. A saved fare's rows are checked through the
  # price inverse they share with `save_prices/2`, which compares each row's
  # amount and presence; a deleted fare's rows must be gone, and the rules its
  # delete settled must still be settled the same way.
  defp require_fare_unchanged(organization_id, gtfs_version_id, inverse) do
    stale? =
      case inverse do
        %{operation: :save, fare_products: states} ->
          require_unchanged(organization_id, gtfs_version_id, states) == {:error, :stale}

        %{operation: :delete, fare_product_id: product_id, rules: rules} ->
          fare_rows_present(organization_id, gtfs_version_id, product_id) or
            not Enum.all?(
              rules,
              &rule_untouched?(&1, organization_id, gtfs_version_id)
            )

        _other ->
          true
      end

    if stale?, do: {:error, :stale}, else: :ok
  end

  defp fare_rows_present(organization_id, gtfs_version_id, product_id) do
    Repo.exists?(
      from(row in FareProduct,
        where:
          row.organization_id == ^organization_id and
            row.gtfs_version_id == ^gtfs_version_id and
            row.fare_product_id == ^product_id
      )
    )
  end

  # A rule the delete moved must still name the replacement, and a rule it
  # deleted must still be gone. Either answer that a rule has been touched since
  # makes the whole reversal stale.
  defp rule_untouched?(%{kind: kind, id: id} = rule, organization_id, gtfs_version_id) do
    schema = if kind == :leg_rule, do: FareLegRule, else: FareTransferRule

    current =
      from(r in schema,
        where:
          r.id == ^id and r.organization_id == ^organization_id and
            r.gtfs_version_id == ^gtfs_version_id,
        select: r.fare_product_id
      )
      |> Repo.one()

    case rule do
      # A rule the delete removed: still absent is still what the delete left.
      %{row: _row} -> is_nil(current)
      # A rule it moved: still naming the replacement is still what it left.
      %{after: product_id} -> current == product_id
    end
  end

  defp restore_fare(organization_id, gtfs_version_id, %{operation: :save} = inverse) do
    restore_prices(organization_id, gtfs_version_id, inverse.fare_products)
    restore_fare_name(organization_id, gtfs_version_id, inverse)
    restore_fare_detail(organization_id, gtfs_version_id, inverse.detail)
    :ok
  end

  defp restore_fare(organization_id, gtfs_version_id, %{operation: :delete} = inverse) do
    Enum.each(inverse.fare_products, &Repo.insert!(Ecto.Changeset.change(&1)))

    if inverse.detail do
      Repo.insert!(Ecto.Changeset.change(inverse.detail))
    end

    Enum.each(inverse.rules, &restore_fare_rule(&1, organization_id, gtfs_version_id))

    :ok
  end

  # A detail row the write created is deleted again, and a row it changed goes
  # back to the values it held.
  defp restore_fare_detail(organization_id, gtfs_version_id, %{before: nil, id: id}) do
    Repo.delete_all(
      from(row in FareProductDetail,
        where:
          row.id == ^id and row.organization_id == ^organization_id and
            row.gtfs_version_id == ^gtfs_version_id
      )
    )
  end

  defp restore_fare_detail(organization_id, gtfs_version_id, %{before: before, id: id}) do
    Repo.update_all(
      from(row in FareProductDetail,
        where:
          row.id == ^id and row.organization_id == ^organization_id and
            row.gtfs_version_id == ^gtfs_version_id
      ),
      set: Keyword.new(Map.merge(before, %{updated_at: DateTime.utc_now()}))
    )
  end

  # A rule the delete moved goes back to naming the fare it named, and a rule it
  # deleted is put back whole with the id it had.
  defp restore_fare_rule(%{row: nil}, _organization_id, _gtfs_version_id), do: :ok

  defp restore_fare_rule(%{row: row}, _organization_id, _gtfs_version_id) do
    Repo.insert!(Ecto.Changeset.change(row))
  end

  defp restore_fare_rule(
         %{kind: kind, id: id, before: product_id},
         organization_id,
         gtfs_version_id
       ) do
    schema = if kind == :leg_rule, do: FareLegRule, else: FareTransferRule

    from(r in schema,
      where:
        r.id == ^id and r.organization_id == ^organization_id and
          r.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.update_all(set: [fare_product_id: product_id, updated_at: DateTime.utc_now()])
  end

  # A rename is restored on every row of the fare, because that is where the
  # name lives. A fare that did not exist before has no name to restore.
  defp restore_fare_name(
         organization_id,
         gtfs_version_id,
         %{fare_product_id: product_id, name: %{before: before}}
       )
       when not is_nil(before) do
    Repo.update_all(
      from(row in FareProduct,
        where:
          row.organization_id == ^organization_id and
            row.gtfs_version_id == ^gtfs_version_id and
            row.fare_product_id == ^product_id
      ),
      set: [fare_product_name: before, updated_at: DateTime.utc_now()]
    )
  end

  defp restore_fare_name(_organization_id, _gtfs_version_id, _inverse), do: :ok

  # Applies a `save_prices/2` inverse, restoring every row it named.
  #
  # The entry this reversal names has to exist in this version, and every row
  # the write touched must still hold the value that write left: a row it
  # created must still be there, a row it changed must still hold the new
  # amount, and a row it deleted must still be gone. Anything else answers
  # `{:error, :stale}` and changes nothing, so undo can never revert a later
  # edit (R15, AC-26).
  defp undo_prices(organization_id, gtfs_version_id, operation_id, _setting, %{
         prices: %{fare_products: states}
       })
       when is_list(states) do
    with :ok <- require_entry(operation_id, organization_id, gtfs_version_id),
         :ok <- require_unchanged(organization_id, gtfs_version_id, states) do
      restore_prices(organization_id, gtfs_version_id, states)

      {:ok,
       %{
         before: Enum.map(states, &log_row(&1.key, &1.after)),
         after: Enum.map(states, &log_row(&1.key, &1.before)),
         inverse: nil,
         operation_id: operation_id,
         action: "rolled_back",
         rolled_back_to_log_id: operation_id
       }}
    end
  end

  # An inverse held in the editor's socket that names no rows is not one this
  # writer produced, so it is stale rather than a reversal of nothing.
  defp undo_prices(_organization_id, _gtfs_version_id, _operation_id, _setting, _inverse) do
    {:error, :stale}
  end

  # The entry this reversal names is the undo target, so an operation id this
  # version never recorded — a random UUID, or another organization's entry — is
  # stale rather than a reversal of something.
  defp require_entry(operation_id, organization_id, gtfs_version_id) do
    found =
      ChangeLog
      |> where(
        [log],
        log.id == ^operation_id and log.organization_id == ^organization_id and
          log.gtfs_version_id == ^gtfs_version_id and log.entity_type == "fare_version"
      )
      |> Repo.exists?()

    if found, do: :ok, else: {:error, :stale}
  end

  defp require_unchanged(organization_id, gtfs_version_id, states) do
    stale? =
      Enum.any?(states, fn state ->
        row = fetch_price(organization_id, gtfs_version_id, state.id)

        case {state.after, row} do
          {nil, nil} -> false
          {nil, _row} -> true
          {_amount, nil} -> true
          {amount, row} -> not same_amount?(row.amount, amount)
        end
      end)

    if stale?, do: {:error, :stale}, else: :ok
  end

  # A row the write created is deleted, a row it changed goes back to the amount
  # it held, and a row it deleted is put back whole — with the id it had, so a
  # `fare_leg_rules` row naming its `fare_product_id` finds the same row it
  # named before the price save.
  defp restore_prices(organization_id, gtfs_version_id, states) do
    Enum.each(states, fn state ->
      case state do
        # A row the write deleted goes back whole, with the id it had, so a
        # `fare_leg_rules` row naming its `fare_product_id` finds the same row it
        # named before the price save.
        %{row: row} when not is_nil(row) ->
          Repo.insert!(Ecto.Changeset.change(row))

        # A row the write created goes away again.
        %{before: nil} ->
          delete_price_by_id(organization_id, gtfs_version_id, state.id)

        # A row the write changed goes back to the amount it held.
        state ->
          restore_price(organization_id, gtfs_version_id, state)
      end
    end)
  end

  defp restore_price(organization_id, gtfs_version_id, state) do
    case fetch_price(organization_id, gtfs_version_id, state.id) do
      nil ->
        :ok

      row ->
        row
        |> Ecto.Changeset.change(%{amount: state.before})
        |> Repo.update!()

        :ok
    end
  end

  defp delete_price_by_id(organization_id, gtfs_version_id, id) do
    Repo.delete_all(
      from(row in FareProduct,
        where:
          row.id == ^id and row.organization_id == ^organization_id and
            row.gtfs_version_id == ^gtfs_version_id
      )
    )
  end

  defp fetch_price(organization_id, gtfs_version_id, id) do
    FareProduct
    |> where(
      [row],
      row.id == ^id and row.organization_id == ^organization_id and
        row.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.one()
  end

  defp pluralize(1, singular, _plural), do: "1 #{singular}"
  defp pluralize(number, _singular, plural), do: "#{number} #{plural}"
end
