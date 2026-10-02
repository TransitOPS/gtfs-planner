defmodule GtfsPlanner.Gtfs.Fares.Workspace do
  @moduledoc """
  Everything the fare editor reads about one version, in one snapshot.

  `GtfsPlanner.Gtfs.Fares.load_workspace/2` builds this struct so the four
  fare tabs, the route-detail card and the Checks tab never read a fare table
  themselves and never disagree about what the version holds. It is a read
  model: nothing here writes, and every query it was built from was filtered by
  `organization_id` and `gtfs_version_id` together (INV-5).

  The fields follow what the editor renders:

    * `managed?` and `older_format` — whether the version's fares are edited
      here, and whether the older GTFS format is derived from the stored v2
      rows or streamed from the rows an import stored. `unmanaged` carries the
      stored-row summary of a version that is *not* managed, so the read-only
      view and the conversion review see the same counts.

    * `currency` — the version's own product currency, `USD` when it has no
      product row (spec "remove currency and upgrade": there is no currency
      column of its own).

    * `fares` — the price grid, single rides first and then passes, each in its
      `fare_product_details` position. A fare is the group of `fare_products`
      rows that share a `fare_product_name`, which is the identity the editor's
      writers use: one fare is one name, sold to several riders and payment
      methods. `prices` holds each rider's amount at the fare's first payment
      method (lowest `fare_media_type`, then id) and `media_prices` holds the
      per-medium amounts of the methods whose prices differ from it, which is
      exactly the sub-row the prototype draws. `base_media_id` is the method
      those main-row prices belong to, `cells` the `fare_products` rows
      themselves — each named by its `fare_product_id`, rider and medium, which
      is the triple `Fares.save_prices/2` writes a cell by — and `rules` the leg
      rules that charge the fare, which is what its "where" line reads.

    * `riders` and `media` — the rider categories and payment methods, the grid's
      columns and its medium columns.

    * `groups` — the version's networks with their route ids. A group is
      *zone-priced* when any of the version's leg rules names both areas for it,
      which is what gives it a matrix.

    * `routes` — the version's own routes, keyed by their `routes.txt` column
      names, which the Where tab's group table badges, its group drawer offers
      and its "In no group" row is worked from. A route no group's `route_ids`
      hold is one no group holds.

    * `matrices` — one per zone-priced group, over that group's own zones: every
      ordered pair of zones is a cell, keyed by `{from_area_id, to_area_id}`,
      holding the single-ride `fare_product_id`s that price it and a `gap?`
      flag. A pass row never fills a cell: a pass is sold, not applied to a
      ride, so its mirrored leg rules are left out of every cell.

    * `transfers` — the from × to matrix of the version's leg groups, each cell
      holding the policy of the rule that applies to it or `nil`. `pay` is the
      editor's own word for `fare_transfer_type`: `:free`, `:fee` or
      `:difference`.

    * `time_periods` — the fare-only periods an editor maintains, each with the
      `timeframes` ranges of its group.

    * `joins` — the version's leg join rules, read-only: this package does not
      write them.

    * `history` — the latest three `fare_version` change-log entries, the list
      the Recent changes destination shows for a managed version.
  """

  @type rider :: %{
          rider_category_id: String.t(),
          name: String.t() | nil,
          default?: boolean(),
          min_age: integer() | nil,
          max_age: integer() | nil,
          eligibility_url: String.t() | nil
        }

  @type medium :: %{
          fare_media_id: String.t(),
          name: String.t() | nil,
          fare_media_type: integer() | nil
        }

  @type fare_cell :: %{
          fare_product_id: String.t(),
          rider_category_id: String.t() | nil,
          fare_media_id: String.t() | nil
        }

  @type fare_rule :: %{
          id: Ecto.UUID.t(),
          fare_product_id: String.t(),
          product_ids: [String.t()],
          network_id: String.t() | nil,
          from_area_id: String.t() | nil,
          to_area_id: String.t() | nil,
          from_timeframe_group_id: String.t() | nil
        }

  @type fare :: %{
          name: String.t(),
          kind: String.t(),
          position: integer(),
          product_ids: [String.t()],
          media: [String.t()],
          base_media_id: String.t() | nil,
          prices: %{optional(String.t()) => Decimal.t() | nil},
          media_prices: %{optional(String.t()) => %{optional(String.t()) => Decimal.t() | nil}},
          cells: [fare_cell()],
          rules: [fare_rule()],
          accepted_network_ids: [String.t()]
        }

  @type group :: %{
          network_id: String.t(),
          name: String.t() | nil,
          route_ids: [String.t()],
          zone_priced?: boolean()
        }

  @type route :: %{
          route_id: String.t(),
          route_short_name: String.t() | nil,
          route_long_name: String.t() | nil,
          route_color: String.t() | nil,
          route_text_color: String.t() | nil
        }

  @type zone :: %{area_id: String.t(), name: String.t()}

  @type cell :: %{products: [String.t()], gap?: boolean()}

  @type matrix :: %{
          network_id: String.t(),
          zones: [zone()],
          cells: %{{String.t(), String.t()} => cell()}
        }

  @type transfer :: %{
          from_leg_group_id: String.t(),
          to_leg_group_id: String.t(),
          policy:
            %{
              pay: :free | :fee | :difference,
              minutes: non_neg_integer() | nil,
              count: integer() | nil,
              fee: String.t() | nil,
              fee_amount: Decimal.t() | nil,
              fare_transfer_type: integer(),
              transfer_count: integer() | nil,
              duration_limit: integer() | nil,
              duration_limit_type: integer() | nil
            }
            | nil
        }

  @type time_period :: %{
          timeframe_group_id: String.t(),
          name: String.t() | nil,
          weekdays: integer() | nil,
          until_end_of_day: boolean() | nil,
          service_id: String.t() | nil,
          ranges: [%{start_time: String.t() | nil, end_time: String.t() | nil}]
        }

  @type history_entry :: %{
          id: Ecto.UUID.t(),
          action: String.t(),
          summary: String.t() | nil,
          actor_email: String.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  @type unmanaged :: %{
          format: :none | :v1 | :v2,
          counts: %{optional(atom()) => non_neg_integer()},
          attributes: [map()]
        }

  @type t :: %__MODULE__{
          managed?: boolean(),
          older_format: String.t() | nil,
          currency: String.t(),
          fares: [fare()],
          riders: [rider()],
          media: [medium()],
          groups: [group()],
          routes: [route()],
          matrices: [matrix()],
          transfers: [transfer()],
          time_periods: [time_period()],
          joins: [map()],
          history: [history_entry()],
          unmanaged: unmanaged() | nil
        }

  defstruct managed?: false,
            older_format: nil,
            currency: "USD",
            fares: [],
            riders: [],
            media: [],
            groups: [],
            routes: [],
            matrices: [],
            transfers: [],
            time_periods: [],
            joins: [],
            history: [],
            unmanaged: nil
end
