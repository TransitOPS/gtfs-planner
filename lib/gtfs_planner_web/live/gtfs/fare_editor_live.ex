defmodule GtfsPlannerWeb.Gtfs.FareEditorLive do
  @moduledoc """
  The fare editor shell for Settings › This version › Fares: the page frame
  every fare tab draws into.

  The Fares section is two LiveViews. This one owns Prices, Where fares apply,
  Transfers and Checks — the four tabs that read and write the version's fare
  model — and `GtfsPlannerWeb.Gtfs.FaresLive` keeps the Zones tab, whose map,
  selection and assignment review spec 21 built. The shared `fares_tabs/1`
  strip navigates between them, so each tab is its own path and a tab change is
  a real navigation rather than a patch of one LiveView's query state.

  The shell carries the Settings back link, the "Fares" heading and its lede,
  the five tabs, and one primary action per tab, so each tab body arrives inside
  a finished page rather than rewriting the frame around it.

  The Prices tab is the fare grid and the bar under it. A price edit is held in
  `@price_edits`, keyed by the `fare_products` row it writes, and nothing is
  written until Save: the edit is read by `Fares.Money.parse/1` — which is also
  what decides the cell is invalid — the save bar names what is unsaved and which
  saved journeys the draft would move, and `Fares.save_prices/2` writes the cells
  with the amount the operator reviewed beside each one.

  That reviewed amount is the fence. When another operator has changed a cell
  since it was reviewed, nothing is written and `@price_conflict` holds the cells
  both of them touched; the operator chooses which price to keep for each of
  those, and only then can Save proceed. A cell only one of them changed is kept
  as it stands.

  `@price_note` is what happened last and whether it can still be undone through
  `Fares.undo/3`, which is the same inverse the write returned.

  The version's whole fare read model arrives in one operational read through
  `Gtfs.load_fare_editor/3`, so the tabs cannot disagree about what the version
  holds and a lost database connection resolves to one load-error state with a
  single recovery action instead of a blank page, a partial workspace, or a
  crash reported as downtime. The disconnected render ships the skeleton; the
  connected load resolves to `:ready` or `:unavailable`, and `reload` re-runs the
  same load.

  `/settings/fares/rules` is the retired Fare rules path. Fare rules are edited
  on Where fares apply now, so that action navigates there instead of rendering
  a tab of its own, and a link from outside the page keeps working.

  Access is authorized at mount through `EnsureRole`, following the other GTFS
  pages: there is no view-only GTFS role.
  """

  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Gtfs.FareEditorComponents,
    only: [
      cell_dialog: 1,
      conversion_review: 1,
      fare_cards: 1,
      fare_delete_dialog: 1,
      fare_drawer: 1,
      fare_free_summary: 1,
      fare_note: 1,
      fare_setup: 1,
      fare_table: 1,
      fares_conflict: 1,
      fares_mismatch_banner: 1,
      fares_checks_tab: 1,
      journey_check: 1,
      saved_journeys: 1,
      formats_section: 1,
      group_drawer: 1,
      header_primary: 1,
      load_error: 1,
      loading: 1,
      media_delete_dialog: 1,
      media_drawer: 1,
      passes_card: 1,
      price_change_dialog: 1,
      price_save_bar: 1,
      rider_delete_dialog: 1,
      rider_drawer: 1,
      route_groups_card: 1,
      rule_drawer: 1,
      rule_list_card: 1,
      time_period_drawer: 1,
      time_periods_card: 1,
      transfer_drawer: 1,
      transfers_tab: 1,
      unmanaged_fares: 1,
      zone_matrix: 1
    ]

  import GtfsPlannerWeb.PlannerComponents, only: [back_link: 1]

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.Fares.Conversion
  alias GtfsPlanner.Gtfs.Fares.Interpreter
  alias GtfsPlanner.Gtfs.Fares.Money
  alias GtfsPlanner.Gtfs.Fares.Pricing
  alias GtfsPlanner.Gtfs.Fares.Projection
  alias GtfsPlanner.Gtfs.Fares.Transfers
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Layouts

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Fares")
     |> assign(:user_roles, socket.assigns[:user_roles] || [])
     |> assign(:load_state, :loading)
     |> assign(:workspace, nil)
     |> assign(:older_allowances, [])
     |> assign(:has_transfer_rules?, false)
     |> assign(:checks, nil)
     |> assign(:journey_routes, [])
     |> assign(:journey_stops, [])
     |> assign(:journey_params, %{})
     |> assign(:journey_form, to_form(%{}, as: :journey))
     |> assign(:journey_result, nil)
     |> assign(:journey_note, nil)
     |> assign(:saved_journeys, [])
     |> assign(:format_counts, %{})
     |> assign(:price_edits, %{})
     |> assign(:price_conflict, nil)
     |> assign(:price_note, nil)
     |> assign(:price_impacts, [])
     |> assign(:price_form, to_form(%{}, as: :price))
     |> assign(:carried, nil)
     |> assign(:lens?, false)
     |> assign(:fare_draft, nil)
     |> assign(:fare_focus, nil)
     |> assign(:fare_delete, nil)
     |> assign(:rider_draft, nil)
     |> assign(:rider_focus, nil)
     |> assign(:rider_delete, nil)
     |> assign(:media_draft, nil)
     |> assign(:media_focus, nil)
     |> assign(:media_delete, nil)
     |> assign(:price_change, nil)
     |> assign(:price_change_focus, nil)
     |> assign(:setup, nil)
     |> assign(:setup_form, to_form(%{}, as: :setup))
     |> assign(:conversion, nil)
     |> assign(:conversion_focus, nil)
     |> assign(:prices_mode, :grid)
     |> assign(:older_mismatches, [])
     |> assign(:group_draft, nil)
     |> assign(:group_form, to_form(%{}, as: :group))
     |> assign(:group_focus, nil)
     |> assign(:cell, nil)
     |> assign(:cell_form, to_form(%{}, as: :cell))
     |> assign(:cell_focus, nil)
     |> assign(:time_period_draft, nil)
     |> assign(:time_period_focus, nil)
     |> assign(:transfer_draft, nil)
     |> assign(:transfer_focus, nil)
     |> assign(:rule_draft, nil)
     |> assign(:rule_form, to_form(%{}, as: :rule))
     |> assign(:rule_focus, nil)
     |> assign(:show_rule_ids?, false)
     |> assign(:drawer_pending?, false)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    socket =
      if socket.assigns.live_action == :rules do
        push_navigate(socket, to: fares_path(socket.assigns.current_gtfs_version.id, :where))
      else
        socket
      end

    if connected?(socket) do
      # Finish the channel join before the operational read. A database timeout
      # can outlast the client's join timeout; the joined view must receive the
      # unavailable state rather than repeatedly attempting the same mount.
      send(self(), {:load_workspace, version_id(socket)})
      {:noreply, socket}
    else
      # The static render ships the skeleton; the connected mount owns the load.
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:load_workspace, gtfs_version_id}, socket) do
    if gtfs_version_id == version_id(socket) do
      {:noreply, load_workspace(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("reload", _params, socket), do: {:noreply, load_workspace(socket)}

  def handle_event("price_journey", %{"journey" => params}, socket) when is_map(params) do
    {:noreply, put_journey(socket, params)}
  end

  def handle_event("price_journey", _params, socket), do: {:noreply, socket}

  def handle_event("add_journey_leg", _params, socket) do
    legs = Map.get(socket.assigns.journey_params, "legs", [])

    if length(legs) < 3 do
      next =
        default_journey_leg(socket.assigns.journey_routes, socket.assigns.journey_stops, legs)

      {:noreply,
       put_journey(socket, Map.put(socket.assigns.journey_params, "legs", legs ++ [next]))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove_journey_leg", %{"index" => index}, socket) do
    legs = Map.get(socket.assigns.journey_params, "legs", [])

    case Integer.parse(index) do
      {index, ""} when index > 0 and index < length(legs) ->
        {:noreply,
         put_journey(
           socket,
           Map.put(socket.assigns.journey_params, "legs", List.delete_at(legs, index))
         )}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("save_test_journey", _params, socket) do
    with %{total: %Decimal{} = total} <- socket.assigns.journey_result,
         journey when is_map(journey) <- socket.assigns[:priced_journey],
         name when is_binary(name) <- journey_name(journey, socket.assigns.journey_stops),
         {:ok, %{journey: _saved}} <-
           Fares.save_journey(fare_scope(socket), Map.put(journey, :name, name)) do
      {:noreply,
       socket
       |> load_workspace()
       |> assign(
         :journey_note,
         "Journey saved with an expected price of #{Money.format(total, socket.assigns.workspace.currency)}."
       )}
    else
      {:error, :unmanaged} ->
        {:noreply, assign(socket, :journey_note, "Edit fares before saving a test journey.")}

      {:error, :no_price} ->
        {:noreply,
         assign(socket, :journey_note, "This journey has no known price, so it was not saved.")}

      _ ->
        {:noreply,
         assign(socket, :journey_note, "This journey could not be saved. Nothing changed.")}
    end
  end

  def handle_event("accept_journey_price", %{"journey_id" => journey_id}, socket) do
    organization_id = organization_id(socket)
    gtfs_version_id = version_id(socket)
    rows = Interpreter.load_rows(organization_id, gtfs_version_id)

    result =
      case Enum.find(
             Fares.saved_journeys(organization_id, gtfs_version_id),
             &(&1.id == journey_id)
           ) do
        nil ->
          {:error, :not_found}

        journey ->
          case Pricing.price_journey(rows, journey).total do
            %Decimal{} = amount ->
              Fares.accept_journey_price(fare_scope(socket), journey.id, amount)

            _ ->
              {:error, :no_price}
          end
      end

    case result do
      {:ok, %{journey: journey}} ->
        {:noreply,
         socket
         |> load_workspace()
         |> assign(
           :journey_note,
           "#{journey.name} now expects #{Money.format(journey.expected_amount, socket.assigns.workspace.currency)}."
         )}

      {:error, :no_price} ->
        {:noreply, assign(socket, :journey_note, "The current fare is unknown. Nothing changed.")}

      {:error, :not_found} ->
        {:noreply,
         assign(
           socket,
           :journey_note,
           "That saved journey is no longer available. Nothing changed."
         )}

      _ ->
        {:noreply,
         assign(
           socket,
           :journey_note,
           "That saved journey is no longer available. Nothing changed."
         )}
    end
  end

  def handle_event("accept_journey_price", _params, socket), do: {:noreply, socket}

  def handle_event("open_saved_journey", %{"journey_id" => journey_id}, socket) do
    journey =
      Enum.find(
        Fares.saved_journeys(organization_id(socket), version_id(socket)),
        &(&1.id == journey_id)
      )

    if journey do
      params = %{
        "rider_category_id" => journey.rider_category_id,
        "fare_media_id" => journey.fare_media_id || "",
        "service_date" => Date.to_iso8601(journey.service_date),
        "legs" => Enum.map(journey.legs, &saved_leg_params/1)
      }

      {:noreply, put_journey(socket, params)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("open_saved_journey", _params, socket), do: {:noreply, socket}

  def handle_event("open_transfer_create", _params, socket) do
    case socket.assigns.workspace.groups do
      [group | _] ->
        {:noreply,
         put_transfer(
           socket,
           new_transfer_draft(group.network_id, group.network_id, nil),
           "add-first-transfer-rule"
         )}

      [] ->
        {:noreply, socket}
    end
  end

  def handle_event("open_transfer_edit", %{"from" => from, "to" => to}, socket) do
    case Enum.find(
           socket.assigns.workspace.transfers,
           &(&1.from_leg_group_id == from and &1.to_leg_group_id == to)
         ) do
      nil -> {:noreply, put_transfer(socket, new_transfer_draft(from, to, nil))}
      transfer -> {:noreply, put_transfer(socket, new_transfer_draft(from, to, transfer.policy))}
    end
  end

  def handle_event("change_transfer", %{"transfer" => params}, socket) do
    draft = update_transfer_draft(socket.assigns.transfer_draft, params)
    {:noreply, put_transfer(socket, draft)}
  end

  def handle_event("change_transfer", _params, socket), do: {:noreply, socket}

  def handle_event("close_transfer_drawer", _params, socket) do
    {:noreply, socket |> assign(:transfer_draft, nil) |> assign(:transfer_focus, nil)}
  end

  def handle_event("save_transfer", %{"transfer" => params}, socket) do
    draft = update_transfer_draft(socket.assigns.transfer_draft, params)
    pay = transfer_pay(draft.pay)
    count = if draft.from == draft.to, do: transfer_count(draft.count), else: nil

    writer_params = %{
      pay: pay,
      minutes: draft.minutes,
      basis: transfer_basis(draft.basis),
      count: count,
      fee: draft.fee
    }

    reviewed = draft.reviewed

    case Transfers.save(fare_scope(socket), draft.from, draft.to, writer_params, reviewed) do
      {:ok, %{operation_id: operation_id, inverse: inverse}} ->
        {:noreply,
         socket
         |> load_workspace()
         |> assign(:transfer_draft, nil)
         |> assign(:transfer_focus, nil)
         |> assign(:price_note, %{text: "Transfer rule saved.", undo: [{operation_id, inverse}]})}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_transfer(%{
           draft
           | failures: ["Transfer rule could not be saved: #{inspect(reason)}"]
         })}
    end
  end

  def handle_event("save_transfer", _params, socket), do: {:noreply, socket}

  # A price edit is one cell. The raw text is kept exactly as it was typed
  # beside what `Fares.Money.parse/1` made of it, so an unreadable cell shows the
  # typo rather than a formatted value that hides it, and Save is blocked while
  # any cell is unreadable.
  #
  # The grid is one form, so a change event carries every cell rather than the
  # one that was typed in. A cell the operator did not change is therefore
  # dropped: the unsaved set is what differs from what is stored, and a cell
  # typed back to its stored price stops being unsaved. An unreadable cell is
  # kept whatever it holds, because its text is the only record of the typo.
  @impl true
  def handle_event("edit_price", %{"price" => cells}, socket) when is_map(cells) do
    edits = Enum.reduce(cells, socket.assigns.price_edits, &price_edit(socket, &1, &2))

    {:noreply,
     socket
     |> assign(:price_edits, edits)
     |> assign(:price_note, nil)
     |> assign(:price_impacts, journey_impacts(socket, edits))}
  end

  def handle_event("edit_price", _params, socket), do: {:noreply, socket}

  # The older-format lens is a view of the same prices rather than a second set
  # of them, but which fares the older format carries is the projection's answer,
  # so it is read from `Fares.Projection` — lazily, the first time the lens is
  # turned on, and held for as long as the tab is open.
  @impl true
  def handle_event("toggle_lens", _params, socket) do
    if socket.assigns.lens? do
      {:noreply, assign(socket, :lens?, false)}
    else
      {:noreply,
       socket
       |> assign(
         :carried,
         Projection.carried_fare_ids(organization_id(socket), version_id(socket))
       )
       |> assign(:lens?, true)}
    end
  end

  @impl true
  def handle_event("discard_prices", _params, socket) do
    {:noreply,
     socket
     |> assign(:price_edits, %{})
     |> assign(:price_conflict, nil)
     |> assign(:price_note, nil)
     |> assign(:affected_journeys, [])}
  end

  # The save is the production call the tab exists for: the edited cells go to
  # `Fares.save_prices/2` with the amount each one was reviewed at, and the
  # answer decides all three outcomes — written, stale, or refused.
  @impl true
  def handle_event("save_prices", _params, socket) do
    if blocked?(socket.assigns) do
      {:noreply, socket}
    else
      save_prices(socket)
    end
  end

  @impl true
  def handle_event("choose_conflict", %{"key" => key, "choice" => choice}, socket) do
    choice = if choice == "theirs", do: :theirs, else: :mine

    conflict =
      case socket.assigns.price_conflict do
        nil ->
          nil

        conflict ->
          %{conflict | cells: Enum.map(conflict.cells, &put_choice(&1, key, choice))}
      end

    {:noreply, assign(socket, :price_conflict, conflict)}
  end

  @impl true
  def handle_event("choose_conflict", _params, socket), do: {:noreply, socket}

  # The undo covers one write or a fan-out of them. A drawer save is a fan-out
  # whenever the fare holds more than one `fare_products` row, so it reverses its
  # writes newest first, which is the only order that can put each row back under
  # the name and the product the next one still expects.
  @impl true
  def handle_event("undo_prices", _params, socket) do
    case socket.assigns.price_note do
      %{undo: undo} when undo != [] ->
        case undo_writes(fare_scope(socket), undo) do
          {:ok, _undone} ->
            {:noreply,
             socket
             |> load_workspace()
             |> assign(:price_note, %{text: "Change undone.", tone: :neutral})}

          {:error, _reason} ->
            {:noreply,
             assign(socket, :price_note, %{text: "That change can’t be undone.", tone: :neutral})}
        end

      _other ->
        {:noreply, socket}
    end
  end

  # Version switching follows the other GTFS pages: a selection of another
  # published version of this organization navigates, keeping the tab the
  # operator was reading. The switcher's own hook returns before it sends the
  # event for the version already shown, so both events ignore that case.
  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_organization = socket.assigns.current_organization

    if version_id && version_id != to_string(socket.assigns.current_gtfs_version.id) &&
         Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      {:noreply, push_navigate(socket, to: fares_path(version_id, socket.assigns.live_action))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    current_organization = socket.assigns.current_organization

    if Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})
      {:noreply, push_navigate(socket, to: fares_path(version_id, socket.assigns.live_action))}
    else
      {:noreply, socket}
    end
  end

  # -- Setup, the fare-free summary and the conversion ------------------------

  # Every answer is one form, so a change carries the whole question set rather
  # than the control that was touched. The draft is rebuilt from it and nothing
  # is written: the writer waits for the submit.
  @impl true
  def handle_event("validate_setup", %{"setup" => params}, socket) when is_map(params) do
    case socket.assigns.setup do
      nil -> {:noreply, socket}
      setup -> {:noreply, put_setup(socket, setup_draft(setup, params))}
    end
  end

  def handle_event("validate_setup", _params, socket), do: {:noreply, socket}

  # The route groups are a list, so adding one is the one answer that is not a
  # field. The draft is rebuilt from its own full param reading plus the new
  # empty row, which is the same reading a change event produces.
  @impl true
  def handle_event("add_route_group", _params, socket) do
    case socket.assigns.setup do
      nil ->
        {:noreply, socket}

      setup ->
        groups = setup["groups"] ++ [%{"name" => "", "price" => ""}]

        {:noreply, put_setup(socket, setup_draft(setup, %{"groups" => groups}))}
    end
  end

  # The one write this step owns that starts a version: `Conversion.setup/2`
  # builds the whole fare set from the four answers in one version-locked
  # transaction, so the grid the operator lands on is the one the writer wrote.
  @impl true
  def handle_event("create_fares", %{"setup" => params}, socket) when is_map(params) do
    case socket.assigns.setup do
      nil ->
        {:noreply, socket}

      setup ->
        setup = setup_draft(setup, params)

        case Conversion.setup(fare_scope(socket), setup_answers(setup)) do
          {:ok, %{operation_id: operation_id, inverse: inverse}} ->
            {:noreply,
             socket
             |> load_workspace()
             |> assign(:price_note, %{
               text:
                 "Fares created for #{socket.assigns.current_gtfs_version.name} service. Check the prices, then set up transfers and zones if you use them.",
               undo: [{operation_id, inverse}]
             })}

          {:error, reason} ->
            {:noreply, socket |> put_setup(setup) |> refuse_setup(reason)}
        end
    end
  end

  def handle_event("create_fares", _params, socket), do: {:noreply, socket}

  # The review is a read: `Conversion.preview/2` prices every combination this
  # version can be asked for, on the stored rows and on the rows a conversion
  # would leave behind, and answers either what it would write or why it must
  # not. Both answers open the same dialog, so opening it writes nothing.
  @impl true
  def handle_event("open_conversion_review", _params, socket) do
    review =
      case Conversion.preview(organization_id(socket), version_id(socket)) do
        {:ok, plan} -> %{state: :ok, plan: plan, reasons: [], error: nil}
        {:refused, reasons} -> %{state: :refused, plan: nil, reasons: reasons, error: nil}
      end

    {:noreply,
     socket
     |> assign(:conversion, review)
     |> assign(:conversion_focus, "edit-fares")}
  end

  @impl true
  def handle_event("close_conversion_review", _params, socket) do
    {:noreply, assign(socket, :conversion, nil)}
  end

  # The apply is exactly the review the operator read: the fingerprint travels
  # with it, so a fare row that changed after the review refuses the whole
  # conversion rather than writing over somebody else's edit (AC-13).
  @impl true
  def handle_event("convert_fares", _params, socket) do
    case socket.assigns.conversion do
      %{state: :ok, plan: plan} ->
        {:noreply, convert_fares(socket, plan)}

      _other ->
        {:noreply, socket}
    end
  end

  # R14: the stored `fare_attributes` rows and the ones the export derives are
  # two descriptions of the same prices, and the operator chooses which the
  # export streams. This is the mismatch banner's writer.
  @impl true
  def handle_event("keep_older_format", _params, socket) do
    case Fares.set_older_format(fare_scope(socket), :imported) do
      {:ok, %{operation_id: operation_id, inverse: inverse}} ->
        {:noreply,
         socket
         |> load_workspace()
         |> assign(:price_note, %{
           text:
             "Exports keep the older format exactly as imported. Fare edits here won’t change it.",
           undo: [{operation_id, inverse}]
         })}

      {:error, reason} ->
        {:noreply,
         assign(socket, :price_note, %{
           text: "The imported format couldn’t be kept (#{write_reason(reason)})."
         })}
    end
  end

  # -- Drawers -----------------------------------------------------------------

  # One drawer at a time: opening any of them closes the others, so the page
  # never carries two forms that both answer to a submit.
  @impl true
  def handle_event("open_fare_drawer", params, socket) do
    {:noreply,
     socket
     |> close_rider_and_media()
     |> assign(:fare_draft, open_fare_draft(socket, params))
     |> assign(:fare_focus, params["opener_id"])
     |> assign(:fare_delete, nil)
     |> assign(:price_note, nil)}
  end

  @impl true
  def handle_event("close_fare_drawer", _params, socket) do
    {:noreply,
     socket
     |> assign(:fare_draft, nil)
     |> assign(:fare_delete, nil)
     |> assign(:fare_focus, nil)}
  end

  # A change clears what the last submit found: the operator has moved past the
  # problems, and a stale error summary would name fields they just fixed. A
  # change that arrives after its own drawer has closed is ignored rather than
  # applied to nothing: a debounced keystroke and a submit can cross, and the
  # submit has already answered the operator.
  @impl true
  def handle_event("validate_fare", %{"fare" => params}, socket) do
    case socket.assigns.fare_draft do
      nil -> {:noreply, socket}
      draft -> {:noreply, assign(socket, :fare_draft, fare_draft(draft, socket, params))}
    end
  end

  def handle_event("validate_fare", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("save_fare", %{"fare" => params}, socket) do
    {draft, failures} =
      socket.assigns.fare_draft |> fare_draft(socket, params) |> fare_failures(socket)

    if failures == [] do
      save_fare(socket, draft)
    else
      {:noreply, socket |> assign(:fare_draft, draft) |> focus_error_summary()}
    end
  end

  def handle_event("save_fare", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("open_delete_fare", _params, socket) do
    case fare_of_product(socket, socket.assigns.fare_draft.key) do
      nil ->
        {:noreply, socket}

      fare ->
        {:noreply,
         assign(socket, :fare_delete, %{
           reviewed_snapshot: socket.assigns.workspace.reviewed_snapshot,
           fare: fare,
           rules: fare.rules,
           replacement: nil,
           error: nil
         })}
    end
  end

  @impl true
  def handle_event("change_fare_replacement", %{"replacement" => slug}, socket) do
    case socket.assigns.fare_delete do
      nil ->
        {:noreply, socket}

      state ->
        replacement = blank_to_nil(slug)
        {:noreply, assign(socket, :fare_delete, %{state | replacement: replacement, error: nil})}
    end
  end

  @impl true
  def handle_event("cancel_delete_fare", _params, socket) do
    {:noreply, assign(socket, :fare_delete, nil)}
  end

  @impl true
  def handle_event("delete_fare", _params, socket) do
    case socket.assigns.fare_delete do
      nil -> {:noreply, socket}
      state -> delete_fare(socket, state)
    end
  end

  @impl true
  def handle_event("go_fares_where", _params, socket) do
    {:noreply,
     socket
     |> assign(:fare_draft, nil)
     |> assign(:fare_delete, nil)
     |> push_patch(to: fares_path(version_id(socket), :where))}
  end

  @impl true
  def handle_event("open_rider_drawer", params, socket) do
    {:noreply,
     socket
     |> close_fare_and_media()
     |> assign(:rider_draft, open_rider_draft(socket, params))
     |> assign(:rider_focus, params["opener_id"])
     |> assign(:rider_delete, nil)
     |> assign(:price_note, nil)}
  end

  @impl true
  def handle_event("close_rider_drawer", _params, socket) do
    {:noreply,
     socket
     |> assign(:rider_draft, nil)
     |> assign(:rider_delete, nil)
     |> assign(:rider_focus, nil)}
  end

  @impl true
  def handle_event("validate_rider", %{"rider" => params}, socket) do
    case socket.assigns.rider_draft do
      nil ->
        {:noreply, socket}

      draft ->
        {:noreply, assign(socket, :rider_draft, rider_draft(draft, socket, params))}
    end
  end

  def handle_event("validate_rider", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("save_rider_type", %{"rider" => params}, socket) do
    {draft, failures} =
      socket.assigns.rider_draft |> rider_draft(socket, params) |> rider_failures()

    if failures == [] do
      save_rider_type(socket, draft)
    else
      {:noreply, socket |> assign(:rider_draft, draft) |> focus_error_summary()}
    end
  end

  def handle_event("save_rider_type", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("open_delete_rider", _params, socket) do
    rider = socket.assigns.rider_draft
    workspace = socket.assigns.workspace

    state = %{
      name: rider.name,
      rider_category_id: rider.key,
      price_count: rider_price_count(workspace, rider.key)
    }

    {:noreply, assign(socket, :rider_delete, state)}
  end

  @impl true
  def handle_event("cancel_delete_rider", _params, socket) do
    {:noreply, assign(socket, :rider_delete, nil)}
  end

  @impl true
  def handle_event("delete_rider_type", _params, socket) do
    case socket.assigns.rider_delete do
      nil ->
        {:noreply, socket}

      state ->
        scope = fare_scope(socket)

        case Fares.delete_rider_type(scope, state.rider_category_id, %{name: state.name}) do
          {:ok, %{operation_id: operation_id, inverse: inverse}} ->
            {:noreply,
             socket
             |> load_workspace()
             |> assign(:rider_draft, nil)
             |> assign(:rider_delete, nil)
             |> assign(:rider_focus, nil)
             |> assign(:price_note, %{
               text:
                 "#{state.name} deleted from #{socket.assigns.current_gtfs_version.name} service.",
               undo: [{operation_id, inverse}]
             })}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:rider_delete, nil)
             |> assign(:price_note, %{
               text: "That rider type couldn’t be deleted (#{write_reason(reason)})."
             })}
        end
    end
  end

  @impl true
  def handle_event("open_media_drawer", params, socket) do
    {:noreply,
     socket
     |> close_fare_and_rider()
     |> assign(:media_draft, open_media_draft(socket, params))
     |> assign(:media_focus, params["opener_id"])
     |> assign(:media_delete, nil)
     |> assign(:price_note, nil)}
  end

  @impl true
  def handle_event("close_media_drawer", _params, socket) do
    {:noreply,
     socket
     |> assign(:media_draft, nil)
     |> assign(:media_delete, nil)
     |> assign(:media_focus, nil)}
  end

  @impl true
  def handle_event("validate_media", %{"media" => params}, socket) do
    case socket.assigns.media_draft do
      nil ->
        {:noreply, socket}

      draft ->
        {:noreply, assign(socket, :media_draft, media_draft(draft, socket, params))}
    end
  end

  def handle_event("validate_media", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("save_payment_method", %{"media" => params}, socket) do
    {draft, failures} =
      socket.assigns.media_draft |> media_draft(socket, params) |> media_failures()

    if failures == [] do
      save_payment_method(socket, draft)
    else
      {:noreply, socket |> assign(:media_draft, draft) |> focus_error_summary()}
    end
  end

  def handle_event("save_payment_method", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("open_delete_media", _params, socket) do
    media = socket.assigns.media_draft
    workspace = socket.assigns.workspace

    state = %{
      name: media.name,
      fare_media_id: media.key,
      fare_count: media_fare_count(workspace, media.key)
    }

    {:noreply, assign(socket, :media_delete, state)}
  end

  @impl true
  def handle_event("cancel_delete_media", _params, socket) do
    {:noreply, assign(socket, :media_delete, nil)}
  end

  @impl true
  def handle_event("delete_payment_method", _params, socket) do
    case socket.assigns.media_delete do
      nil ->
        {:noreply, socket}

      state ->
        scope = fare_scope(socket)

        case Fares.delete_payment_method(scope, state.fare_media_id, %{name: state.name}) do
          {:ok, %{operation_id: operation_id, inverse: inverse}} ->
            {:noreply,
             socket
             |> load_workspace()
             |> assign(:media_draft, nil)
             |> assign(:media_delete, nil)
             |> assign(:media_focus, nil)
             |> assign(:price_note, %{
               text:
                 "#{state.name} deleted from #{socket.assigns.current_gtfs_version.name} service.",
               undo: [{operation_id, inverse}]
             })}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:media_delete, nil)
             |> assign(:price_note, %{
               text: "That payment method couldn’t be deleted (#{write_reason(reason)})."
             })}
        end
    end
  end

  # -- Change prices ------------------------------------------------------------

  # The dialog opens with the choices the prototype opens it on: single rides,
  # every rider type a fare is sold to, +$0.25 to the nearest nickel and the
  # reduced rider kept at half. Nothing is written here — the dialog's whole
  # first answer is `Fares.preview_price_change/3`, which is computed against
  # the version's own stored rows (INV-5).
  #
  # It closes the drawers because a dialog and a drawer are both overlays over
  # the same prices, and Escape must return focus to one control rather than
  # two.
  #
  # It does not open over unsaved prices. The grid's edits are held against the
  # amounts they were typed at, and a change across the whole version would move
  # those amounts under them; saving afterwards would then write what the
  # operator reviewed against a price nobody reviewed. The note says so and the
  # grid's own save bar stays the next action.
  @impl true
  def handle_event("open_change_prices", _params, socket) do
    if socket.assigns.price_edits == %{} do
      {:noreply,
       socket
       |> close_fare_and_media()
       |> close_rider_and_media()
       |> assign(:price_change, price_change(socket))
       |> assign(:price_change_focus, "change-prices")
       |> assign(:price_note, nil)}
    else
      {:noreply,
       assign(socket, :price_note, %{
         text: "Save or discard your unsaved prices before changing prices across the version."
       })}
    end
  end

  # Every control in the dialog is one form, so a change carries the whole set of
  # choices rather than the one that was touched. The preview is recomputed on
  # every change and nothing is written, so what the tiles count and what the
  # table lists are always the rows Update would hand the writer.
  @impl true
  def handle_event("change_price_options", %{"change" => params}, socket)
      when is_map(params) do
    case socket.assigns.price_change do
      nil ->
        {:noreply, socket}

      change ->
        {:noreply, assign(socket, :price_change, preview_price_change(change, params, socket))}
    end
  end

  def handle_event("change_price_options", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("cancel_change_prices", _params, socket) do
    {:noreply, assign(socket, :price_change, nil)}
  end

  # The write is exactly the preview the operator reviewed: the rows
  # `Fares.preview_price_change/3` returned, each carrying the amount it was
  # reviewed at, so a price another operator has changed since refuses the whole
  # change rather than overwriting it (AC-14's fence, INV-1).
  @impl true
  def handle_event("apply_price_change", _params, socket) do
    case socket.assigns.price_change do
      nil ->
        {:noreply, socket}

      %{rows: []} = change ->
        {:noreply,
         assign(socket, :price_change, %{change | error: "There is nothing to update."})}

      change ->
        {:noreply, apply_price_change(socket, change)}
    end
  end

  # -- Where fares apply: route groups, the zone matrix and passes ------------

  # The group drawer is one of the two overlays the Where tab owns, so opening
  # either closes the other: a drawer and a dialog are both an overlay over the
  # same page, and Escape must return focus to one control rather than two.
  @impl true
  def handle_event("open_group_drawer", params, socket) do
    draft = open_group_draft(socket, params)

    {:noreply,
     socket
     |> assign(:cell, nil)
     |> assign(:cell_focus, nil)
     |> assign(:group_draft, draft)
     |> assign(:group_form, to_form(%{"name" => draft.name}, as: :group))
     |> assign(:group_focus, params["opener_id"])
     |> assign(:price_note, nil)}
  end

  @impl true
  def handle_event("close_group_drawer", _params, socket) do
    {:noreply,
     socket
     |> assign(:group_draft, nil)
     |> assign(:group_focus, nil)}
  end

  # A change carries the whole form — the name and every route box — so the
  # draft is rebuilt from it rather than merged into: an unticked box is simply
  # absent from the payload, and a merge would keep the route the operator just
  # removed. Nothing is written until the submit.
  @impl true
  def handle_event("validate_group", %{"group" => params}, socket) when is_map(params) do
    case socket.assigns.group_draft do
      nil -> {:noreply, socket}
      draft -> {:noreply, put_group(socket, group_draft(draft, socket, params))}
    end
  end

  def handle_event("validate_group", _params, socket), do: {:noreply, socket}

  # The write is exactly what `Fares.save_route_group/2` is for: the group's
  # name and the whole set of routes it holds, which is what makes a route in at
  # most one group true (AC-19) rather than a convention the UI keeps. The
  # answer's `moved` list is the drawer's own warning, so the operator is told
  # what moved after the write as well as before it.
  @impl true
  def handle_event("save_route_group", %{"group" => params}, socket) when is_map(params) do
    case socket.assigns.group_draft do
      nil ->
        {:noreply, socket}

      draft ->
        draft = group_draft(draft, socket, params)
        socket = put_group(socket, draft)

        if draft.failures == [] do
          save_route_group(socket, draft)
        else
          {:noreply, focus_error_summary(socket)}
        end
    end
  end

  def handle_event("save_route_group", _params, socket), do: {:noreply, socket}

  # The cell dialog opens on one cell of one group's matrix, with the fare that
  # cell holds and the reverse cell's fare beside it: the "also for the return
  # ride" choice is only offered when it is free to offer, which is the case
  # when the reverse cell holds nothing or holds the same fare.
  @impl true
  def handle_event("open_cell", params, socket) do
    {:noreply,
     socket
     |> assign(:group_draft, nil)
     |> assign(:group_focus, nil)
     |> assign(:cell, open_cell(socket, params))
     |> assign(:cell_focus, "cell-#{params["network_id"]}-#{params["from"]}-#{params["to"]}")}
  end

  @impl true
  def handle_event("close_cell", _params, socket) do
    {:noreply, assign(socket, :cell, nil)}
  end

  @impl true
  def handle_event("change_cell", %{"cell" => params}, socket) when is_map(params) do
    case socket.assigns.cell do
      nil -> {:noreply, socket}
      cell -> {:noreply, assign(socket, :cell, cell_draft(cell, params))}
    end
  end

  def handle_event("change_cell", _params, socket), do: {:noreply, socket}

  # The write is `Fares.set_zone_fare/7` and nothing else: the cell's own
  # products are the fence the writer checks, so a cell another operator has
  # changed since the dialog opened refuses the whole write rather than
  # overwriting it (AC-20, R15).
  @impl true
  def handle_event("set_zone_fare", %{"cell" => params}, socket) when is_map(params) do
    case socket.assigns.cell do
      nil ->
        {:noreply, socket}

      cell ->
        cell = cell_draft(cell, params)

        if cell.error do
          {:noreply, assign(socket, :cell, cell)}
        else
          set_zone_fare(socket, cell)
        end
    end
  end

  def handle_event("set_zone_fare", _params, socket), do: {:noreply, socket}

  # The passes table writes each box as it is ticked or unticked, so a pass's
  # accepted groups are never a draft the operator has to remember to save.
  # `set_pass_acceptance/5` names the one group that changed, and the pass's
  # own accepted list is the fence it checks.
  @impl true
  def handle_event("set_pass_acceptance", %{"pass" => params}, socket) when is_map(params) do
    with product_id when is_binary(product_id) <- params["fare_product_id"],
         network_id when is_binary(network_id) <- params["network_id"] do
      case pass_of_product(socket, product_id) do
        nil ->
          {:noreply, socket}

        fare ->
          set_pass_acceptance(socket, fare, network_id, params["accepted"] == "true")
      end
    else
      _other -> {:noreply, socket}
    end
  end

  def handle_event("set_pass_acceptance", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_rule_feed_ids", _params, socket) do
    {:noreply, assign(socket, :show_rule_ids?, not socket.assigns.show_rule_ids?)}
  end

  @impl true
  def handle_event("open_time_period_drawer", _params, socket) do
    {:noreply, put_time_period(socket, new_time_period_draft(), "create-time-period")}
  end

  @impl true
  def handle_event("close_time_period_drawer", _params, socket) do
    {:noreply,
     socket
     |> assign(:time_period_draft, nil)
     |> assign(:time_period_focus, nil)
     |> assign(:drawer_pending?, false)}
  end

  @impl true
  def handle_event("change_time_period", %{"time_period" => params}, socket)
      when is_map(params) do
    case socket.assigns.time_period_draft do
      nil -> {:noreply, socket}
      draft -> {:noreply, put_time_period(socket, update_time_period_draft(draft, params))}
    end
  end

  def handle_event("change_time_period", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("add_time_period_range", _params, socket) do
    case socket.assigns.time_period_draft do
      nil ->
        {:noreply, socket}

      draft ->
        range = %{start_time: "", end_time: ""}

        {:noreply,
         put_time_period(socket, %{draft | ranges: draft.ranges ++ [range], failures: []})}
    end
  end

  @impl true
  def handle_event("remove_time_period_range", %{"index" => index}, socket) do
    with %{ranges: ranges} = draft when length(ranges) > 1 <- socket.assigns.time_period_draft,
         {index, ""} <- Integer.parse(index),
         true <- index >= 0 and index < length(ranges) do
      next = List.delete_at(ranges, index)
      {:noreply, put_time_period(socket, %{draft | ranges: next, failures: []})}
    else
      _other -> {:noreply, socket}
    end
  end

  def handle_event("remove_time_period_range", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("save_time_period", %{"time_period" => params}, socket) when is_map(params) do
    case socket.assigns.time_period_draft do
      nil -> {:noreply, socket}
      draft -> save_time_period(socket, update_time_period_draft(draft, params))
    end
  end

  def handle_event("save_time_period", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("open_rule_drawer", %{"rule_id" => rule_id}, socket) do
    case find_editor_rule(socket.assigns.workspace, rule_id) do
      nil ->
        {:noreply, socket}

      rule ->
        {:noreply, put_rule(socket, rule_draft_from_rule(rule), "edit-fare-rule-#{rule_id}")}
    end
  end

  def handle_event("open_rule_drawer", _params, socket) do
    {:noreply, put_rule(socket, new_rule_draft(socket.assigns.workspace), "add-fare-rule")}
  end

  @impl true
  def handle_event("close_rule_drawer", _params, socket) do
    {:noreply,
     socket
     |> assign(:rule_draft, nil)
     |> assign(:rule_focus, nil)
     |> assign(:drawer_pending?, false)}
  end

  @impl true
  def handle_event("change_rule", %{"rule" => params}, socket) when is_map(params) do
    case socket.assigns.rule_draft do
      nil ->
        {:noreply, socket}

      draft ->
        {:noreply, put_rule(socket, update_rule_draft(draft, params), socket.assigns.rule_focus)}
    end
  end

  def handle_event("change_rule", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("save_rule", %{"rule" => params}, socket) when is_map(params) do
    case socket.assigns.rule_draft do
      nil -> {:noreply, socket}
      draft -> save_rule(socket, update_rule_draft(draft, params))
    end
  end

  def handle_event("save_rule", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("delete_rule", %{"rule_id" => rule_id}, socket) do
    case find_editor_rule(socket.assigns.workspace, rule_id) do
      nil -> {:noreply, socket}
      rule -> delete_fare_rule(socket, rule)
    end
  end

  def handle_event("delete_rule", _params, socket), do: {:noreply, socket}

  defp new_transfer_draft(from, to, nil) do
    %{
      from: from,
      to: to,
      pay: "full",
      minutes: 90,
      basis: 1,
      count: "-1",
      fee: nil,
      reviewed: nil,
      failures: []
    }
  end

  defp new_transfer_draft(from, to, policy) do
    %{
      from: from,
      to: to,
      pay: Atom.to_string(policy.pay),
      minutes: policy.minutes || 90,
      basis: policy.duration_limit_type || 1,
      count: to_string(policy.count || -1),
      fee: policy.fee_amount,
      reviewed: %{
        pay: policy.pay,
        minutes: policy.minutes,
        basis: policy.duration_limit_type || 1,
        count: policy.count,
        fee: policy.fee_amount
      },
      failures: []
    }
  end

  defp put_transfer(socket, draft, focus_id \\ nil) do
    socket
    |> assign(:transfer_draft, draft)
    |> assign(:transfer_focus, focus_id || socket.assigns.transfer_focus)
    |> assign(:transfer_scope, fare_scope(socket))
  end

  defp update_transfer_draft(draft, params) do
    %{
      draft
      | pay: Map.get(params, "pay", draft.pay),
        minutes: Map.get(params, "minutes", draft.minutes),
        basis: Map.get(params, "basis", draft.basis),
        count: Map.get(params, "count", draft.count),
        fee: Map.get(params, "fee", draft.fee)
    }
  end

  defp transfer_pay(value) do
    case value do
      "free" -> :free
      "fee" -> :fee
      "difference" -> :difference
      "full" -> :full
      _ -> :full
    end
  end

  defp transfer_count("-1"), do: -1
  defp transfer_count("1"), do: 1
  defp transfer_count("2"), do: 2
  defp transfer_count(_), do: nil

  defp transfer_basis("0"), do: 0
  defp transfer_basis("1"), do: 1
  defp transfer_basis("2"), do: 2
  defp transfer_basis("3"), do: 3
  defp transfer_basis(basis) when is_integer(basis) and basis in 0..3, do: basis
  defp transfer_basis(_), do: 1

  defp put_time_period(socket, draft, focus_id \\ nil) do
    socket
    |> assign(:time_period_draft, draft)
    |> assign(:time_period_focus, focus_id || socket.assigns.time_period_focus)
    |> assign(:time_period_form, to_form(%{"name" => draft.name}, as: :time_period))
  end

  defp new_time_period_draft do
    %{
      name: "",
      days: [],
      weekdays: nil,
      ranges: [%{start_time: "", end_time: ""}],
      until_end_of_day?: false,
      failures: []
    }
  end

  defp update_time_period_draft(draft, params) do
    days =
      params
      |> Map.get("weekdays", [])
      |> List.wrap()
      |> Enum.map(&parse_weekday/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    ranges = period_draft_ranges(params["ranges"], draft.ranges)

    %{
      draft
      | name: Map.get(params, "name", draft.name),
        days: days,
        ranges: ranges,
        until_end_of_day?: params["until_end_of_day"] == "true",
        failures: []
    }
  end

  defp period_draft_ranges(values, _previous) when is_map(values) do
    values
    |> Enum.sort_by(fn {index, _range} ->
      case Integer.parse(index) do
        {n, ""} -> n
        _ -> 0
      end
    end)
    |> Enum.map(fn {_index, range} ->
      %{start_time: range["start_time"] || "", end_time: range["end_time"] || ""}
    end)
  end

  defp period_draft_ranges(_values, previous), do: previous

  defp parse_weekday(day) when day in 0..6, do: day

  defp parse_weekday(day) when is_binary(day) do
    case Integer.parse(day) do
      {n, ""} when n in 0..6 -> n
      _ -> nil
    end
  end

  defp parse_weekday(_day), do: nil

  defp time_period_writer_params(draft) do
    weekdays =
      Enum.reduce(draft.days, 0, fn day, mask ->
        Bitwise.bor(mask, weekday_bit(day))
      end)

    ranges =
      Enum.map(draft.ranges, fn range ->
        %{
          start_seconds: time_input_seconds(range.start_time),
          end_seconds:
            if(draft.until_end_of_day? and range == List.last(draft.ranges),
              do: 86_400,
              else: time_input_seconds(range.end_time)
            )
        }
      end)

    %{
      name: draft.name,
      weekdays: if(weekdays == 0, do: nil, else: weekdays),
      ranges: ranges,
      until_end_of_day?: draft.until_end_of_day?
    }
  end

  defp time_input_seconds(""), do: nil

  defp time_input_seconds(value) when is_binary(value) do
    case Time.from_iso8601(value <> if(String.length(value) == 5, do: ":00", else: "")) do
      {:ok, time} -> time.hour * 3600 + time.minute * 60 + time.second
      _ -> nil
    end
  end

  defp time_input_seconds(_value), do: nil

  defp weekday_bit(0), do: 64
  defp weekday_bit(day) when day in 1..6, do: :erlang.bsl(1, day - 1)

  defp save_time_period(socket, draft) do
    socket = assign(socket, :drawer_pending?, true)

    case Fares.save_time_period(fare_scope(socket), time_period_writer_params(draft)) do
      {:ok, %{operation_id: operation_id, inverse: inverse}} ->
        {:noreply,
         socket
         |> load_workspace()
         |> assign(:time_period_draft, nil)
         |> assign(:time_period_focus, nil)
         |> assign(:drawer_pending?, false)
         |> assign(:price_note, %{
           text: "Time period saved to #{socket.assigns.current_gtfs_version.name} service.",
           undo: [{operation_id, inverse}]
         })}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:drawer_pending?, false)
         |> put_time_period(%{draft | failures: [time_period_failure(reason)]})}
    end
  end

  defp time_period_failure(%Ecto.Changeset{} = changeset) do
    message =
      changeset.errors
      |> Enum.map(fn {_field, {message, _opts}} -> message end)
      |> Enum.uniq()
      |> Enum.join(" ")

    %{
      href: "#time-period-name",
      msg:
        "Time period: #{if(message == "", do: "Check the name and time ranges.", else: message)}"
    }
  end

  defp time_period_failure(:duplicate_time_period),
    do: %{
      href: "#time-period-name",
      msg: "Name: This version already has a time period with that name."
    }

  defp time_period_failure(:not_found),
    do: %{
      href: "#time-period-name",
      msg: "Time period: This version no longer holds that period."
    }

  defp time_period_failure(:unmanaged),
    do: %{
      href: "#time-period-name",
      msg: "Time period: Convert this version's fares before editing them."
    }

  defp time_period_failure(_reason),
    do: %{href: "#time-period-name", msg: "Time period: It could not be saved. Nothing changed."}

  defp put_rule(socket, draft, focus_id \\ nil) do
    socket
    |> assign(:rule_draft, draft)
    |> assign(:rule_focus, focus_id || socket.assigns.rule_focus)
    |> assign(:rule_form, to_form(%{}, as: :rule))
  end

  defp new_rule_draft(workspace) do
    fare = Enum.find(workspace.fares, &(&1.kind == "single"))

    %{
      rule_id: nil,
      network_id: nil,
      from_area_id: nil,
      to_area_id: nil,
      from_timeframe_group_id: nil,
      fare_product_id: fare && List.first(fare.product_ids),
      both?: false,
      overlap: nil,
      failures: []
    }
  end

  defp rule_draft_from_rule(rule) do
    %{
      rule_id: rule.id,
      network_id: rule.network_id,
      from_area_id: rule.from_area_id,
      to_area_id: rule.to_area_id,
      from_timeframe_group_id: rule.from_timeframe_group_id,
      fare_product_id: rule.fare_product_id,
      both?: false,
      overlap: nil,
      failures: []
    }
  end

  defp update_rule_draft(draft, params) do
    overlap =
      case params["overlap"] do
        "replace" -> :replace
        "keep_both" -> :keep_both
        _ -> draft.overlap
      end

    %{
      draft
      | network_id: blank_to_nil(params["network_id"]),
        from_area_id: blank_to_nil(params["from_area_id"]),
        to_area_id: blank_to_nil(params["to_area_id"]),
        from_timeframe_group_id: blank_to_nil(params["from_timeframe_group_id"]),
        fare_product_id: blank_to_nil(params["fare_product_id"]),
        both?: params["both"] == "true" and is_nil(draft.rule_id),
        overlap: overlap,
        failures: []
    }
  end

  defp editor_rules(workspace) do
    workspace.fares
    |> Enum.flat_map(fn fare ->
      Enum.map(fare.rules, &Map.put(&1, :editable?, fare.kind == "single"))
    end)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(&{&1.network_id || "", &1.from_area_id || "", &1.to_area_id || "", &1.id})
  end

  defp editable_rules(workspace), do: Enum.filter(editor_rules(workspace), & &1.editable?)

  defp rule_overlaps(workspace, draft) do
    conditions =
      [{draft.from_area_id, draft.to_area_id}] ++
        if(draft.both? and draft.from_area_id != draft.to_area_id,
          do: [{draft.to_area_id, draft.from_area_id}],
          else: []
        )

    editable_rules(workspace)
    |> Enum.filter(fn rule ->
      rule.network_id == draft.network_id and
        {rule.from_area_id, rule.to_area_id} in conditions and
        rule.from_timeframe_group_id == draft.from_timeframe_group_id and
        rule.fare_product_id not in fare_product_ids_for(workspace, draft.fare_product_id) and
        rule.id != draft.rule_id
    end)
    |> Enum.uniq_by(& &1.fare_product_id)
  end

  defp fare_product_ids_for(_workspace, nil), do: []

  defp fare_product_ids_for(workspace, product_id) do
    case Enum.find(workspace.fares, &(product_id in &1.product_ids)) do
      nil -> [product_id]
      fare -> fare.product_ids
    end
  end

  defp rule_reviewed(workspace, draft) do
    editable_rules(workspace)
    |> Enum.filter(fn rule ->
      rule.network_id == draft.network_id and rule.from_area_id == draft.from_area_id and
        rule.to_area_id == draft.to_area_id and
        rule.from_timeframe_group_id == draft.from_timeframe_group_id and
        rule.id != draft.rule_id
    end)
    |> Enum.flat_map(&Map.get(&1, :product_ids, [&1.fare_product_id]))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp save_rule(socket, draft) do
    overlaps = rule_overlaps(socket.assigns.workspace, draft)

    failures =
      cond do
        is_nil(draft.fare_product_id) ->
          [%{href: "#rule-fares", msg: "Fare: Choose a single-ride fare."}]

        overlaps != [] and is_nil(draft.overlap) ->
          [
            %{
              href: "#rule-overlap",
              msg: "Overlap: Choose whether to replace the existing fare or keep both."
            }
          ]

        true ->
          []
      end

    case failures do
      [] -> persist_rule(socket, draft, overlaps)
      _ -> {:noreply, put_rule(socket, %{draft | failures: failures}, socket.assigns.rule_focus)}
    end
  end

  defp persist_rule(socket, draft, overlaps) do
    socket = assign(socket, :drawer_pending?, true)

    write_params = %{
      rule_id: draft.rule_id,
      network_id: draft.network_id,
      from_area_id: draft.from_area_id,
      to_area_id: draft.to_area_id,
      from_timeframe_group_id: draft.from_timeframe_group_id,
      fare_product_id: draft.fare_product_id,
      both?: draft.both?,
      reviewed: rule_reviewed(socket.assigns.workspace, draft)
    }

    case Fares.save_rule(
           fare_scope(socket),
           write_params,
           if(overlaps == [], do: nil, else: draft.overlap)
         ) do
      {:ok, %{operation_id: operation_id, inverse: inverse}} ->
        {:noreply,
         socket
         |> load_workspace()
         |> assign(:rule_draft, nil)
         |> assign(:rule_focus, nil)
         |> assign(:drawer_pending?, false)
         |> assign(:price_note, %{
           text: "Fare rule saved to #{socket.assigns.current_gtfs_version.name} service.",
           undo: [{operation_id, inverse}]
         })}

      {:error, {:overlap, _rule}} ->
        {:noreply,
         put_rule(
           assign(socket, :drawer_pending?, false),
           %{
             draft
             | failures: [
                 %{
                   href: "#rule-overlap",
                   msg:
                     "Overlap: These rides now have another fare. Review the choice and save again."
                 }
               ]
           },
           socket.assigns.rule_focus
         )}

      {:error, reason} ->
        {:noreply,
         put_rule(
           assign(socket, :drawer_pending?, false),
           %{
             draft
             | failures: [%{href: "#rule-fares", msg: "Fare rule: #{rule_error(reason)}"}]
           },
           socket.assigns.rule_focus
         )}
    end
  end

  defp rule_error(:not_found),
    do: "A selected route group, zone, time period, or fare is no longer in this version."

  defp rule_error(:pass_fare), do: "Passes are managed in the Passes table."
  defp rule_error(:unmanaged), do: "Convert this version's fares before editing them."

  defp rule_error({:stale, _details}),
    do: "These rules changed since you opened the editor. Review them again and save."

  defp rule_error(_reason), do: "It could not be saved. Nothing changed."

  defp find_editor_rule(workspace, rule_id),
    do: Enum.find(editable_rules(workspace), &(to_string(&1.id) == rule_id))

  defp delete_fare_rule(socket, rule) do
    socket = assign(socket, :drawer_pending?, true)

    case Fares.delete_rule(fare_scope(socket), rule.id, %{fare_product_id: rule.fare_product_id}) do
      {:ok, %{operation_id: operation_id, inverse: inverse}} ->
        {:noreply,
         socket
         |> load_workspace()
         |> assign(:rule_draft, nil)
         |> assign(:rule_focus, nil)
         |> assign(:drawer_pending?, false)
         |> assign(:price_note, %{
           text: "Fare rule deleted. Journeys using it are now unpriced.",
           undo: [{operation_id, inverse}]
         })}

      {:error, reason} ->
        {:noreply,
         put_rule(assign(socket, :drawer_pending?, false), %{
           socket.assigns.rule_draft
           | failures: [%{href: "#rule-fares", msg: "Fare rule: #{rule_error(reason)}"}]
         })}
    end
  end

  # The dialog's own state, opened with the prototype's defaults: single rides,
  # every rider type the version charges, $0.25, the nearest nickel, and the
  # reduced rider kept at half its fare's new adult price.
  defp price_change(socket) do
    preview_price_change(
      %{
        scope: :single,
        how: :amount,
        amount: "0.25",
        percent: "10",
        round: "0.05",
        half_reduced?: true,
        riders: priced_riders(socket.assigns.workspace),
        error: nil,
        value_invalid?: false
      },
      %{},
      socket
    )
  end

  # The chosen rider types default to the ones a fare in this scope is sold to.
  # A rider type with no priced row cannot change and is disabled in the dialog.
  defp priced_riders(workspace) do
    Enum.filter(workspace.riders, &rider_priced?(&1, workspace))
    |> Enum.map(& &1.rider_category_id)
  end

  defp rider_priced?(rider, workspace) do
    Enum.any?(workspace.fares, fn fare ->
      case Map.get(fare.prices, rider.rider_category_id) do
        nil -> false
        amount -> not Decimal.equal?(amount, 0)
      end
    end)
  end

  # One preview of the choices as they stand. The amount is read through
  # `Fares.Money.parse/1` (CR-3) and an unreadable one previews nothing rather
  # than raising while the operator is still typing: the dialog shows the reason
  # and Update stays disabled.
  defp preview_price_change(change, params, socket) do
    change =
      change
      |> put_scope(params["scope"])
      |> put_how(params["how"])
      |> put_value(params)
      |> put_round(params["round"])
      |> put_riders(params["riders"])
      |> put_half(params["half_reduced?"])

    amount = change_value(change)

    rows =
      if amount == nil do
        []
      else
        Fares.preview_price_change(organization_id(socket), version_id(socket), %{
          scope: change.scope,
          riders: change.riders,
          how: change.how,
          value: amount,
          round: change.round,
          half_reduced?: change.half_reduced?
        })
      end

    change
    |> Map.put(:rows, rows)
    |> Map.put(:value_invalid?, is_nil(amount))
    |> Map.put(:error, preview_error(change, amount))
  end

  defp preview_error(_change, nil),
    do: "Type a number, such as 0.25 or -0.10, to see the prices this changes."

  defp preview_error(%{error: error}, _amount) when is_binary(error), do: error
  defp preview_error(_change, _amount), do: nil

  defp put_scope(change, scope) when scope in ~w(single pass all),
    do: %{change | scope: String.to_existing_atom(scope)}

  defp put_scope(change, _scope), do: change

  defp put_how(change, how) when how in ~w(amount percent),
    do: %{change | how: String.to_existing_atom(how)}

  defp put_how(change, _how), do: change

  defp put_value(change, params) do
    case change.how do
      :percent -> %{change | percent: to_string(Map.get(params, "percent", change.percent))}
      :amount -> %{change | amount: to_string(Map.get(params, "amount", change.amount))}
    end
  end

  defp put_round(change, round) when round in ~w(0.01 0.05 0.25), do: %{change | round: round}
  defp put_round(change, _round), do: change

  # A form's unticked boxes are absent from its payload rather than sent as
  # false. The dialog's hidden marker field means a payload that carries the
  # list at all says how many rider types are ticked — including none — while a
  # payload without the marker is not a rider choice at all and keeps the ones
  # already chosen.
  defp put_riders(change, riders) when is_list(riders) do
    case Enum.reject(riders, &(&1 == "")) do
      [] -> %{change | riders: []}
      chosen -> %{change | riders: chosen}
    end
  end

  defp put_riders(change, riders) when is_binary(riders), do: put_riders(change, [riders])
  defp put_riders(change, _riders), do: change

  # The hidden marker field sends `false` when the box is unticked, so `nil` here
  # is a payload that never carried the choice and keeps it as it stands.
  defp put_half(change, half) when is_binary(half), do: %{change | half_reduced?: half == "true"}
  defp put_half(change, _half), do: change

  # The amount or percentage the choices name, read through the one money parser
  # (CR-3), or nil while it is blank or unreadable.
  defp change_value(%{how: :amount, amount: amount}), do: parsed_amount(amount)
  defp change_value(%{how: :percent, percent: percent}), do: parsed_amount(percent)

  defp parsed_amount(text) do
    case Money.parse(text) do
      {:ok, nil} -> nil
      {:ok, amount} -> amount
      {:error, :invalid} -> nil
    end
  end

  # The write. One call, with the preview's own rows, so what was reviewed is
  # what is stored; the answer decides the three outcomes the tab already knows
  # how to show — written with Undo, refused as stale, or refused outright.
  defp apply_price_change(socket, change) do
    case Fares.apply_price_change(fare_scope(socket), change, change.rows) do
      {:ok, %{operation_id: operation_id, inverse: inverse}} ->
        socket
        |> load_workspace()
        |> assign(:price_change, nil)
        |> assign(:price_change_focus, nil)
        |> assign(:price_note, %{
          text:
            "#{price_count_text(length(change.rows))} changed to #{socket.assigns.current_gtfs_version.name} service.",
          undo: [{operation_id, inverse}]
        })

      {:error, {:stale, cells}} ->
        # Somebody changed a price this preview reviewed. Nothing was written,
        # and the dialog stays open with the reason rather than closing over a
        # change that did not happen.
        assign(socket, :price_change, %{
          change
          | error:
              "#{price_count_text(length(cells))} changed since this preview. Nothing was saved — preview again and update."
        })

      {:error, reason} ->
        assign(socket, :price_change, %{
          change
          | error: "Prices couldn't be changed (#{write_reason(reason)})."
        })
    end
  end

  defp convert_fares(socket, plan) do
    case Conversion.apply(fare_scope(socket), plan.fingerprint, []) do
      {:ok, %{operation_id: operation_id, inverse: inverse}} ->
        socket
        |> load_workspace()
        |> assign(:conversion, nil)
        |> assign(:conversion_focus, nil)
        |> assign(:price_note, %{
          text:
            "Fares converted to the newer format in #{socket.assigns.current_gtfs_version.name} service.",
          undo: [{operation_id, inverse}]
        })

      {:refused, reasons} ->
        assign(socket, :conversion, %{
          state: :refused,
          plan: nil,
          reasons: reasons,
          error: "The stored fares changed since the review, so nothing was written."
        })

      {:error, reason} ->
        assign(socket, :conversion, refusal(state: :ok, plan: plan, reason: reason))
    end
  end

  defp refusal(state: state, plan: plan, reason: reason) do
    %{
      state: state,
      plan: plan,
      reasons: [],
      error: "These fares couldn’t be converted (#{write_reason(reason)})."
    }
  end

  defp open_group_draft(socket, params) do
    case group_of(socket, params["network_id"]) do
      nil ->
        group_draft_new(socket)

      group ->
        group_draft_edit(group)
        |> Map.put(:reviewed_snapshot, socket.assigns.workspace.reviewed_snapshot)
    end
  end

  defp group_draft_new(_socket) do
    %{key: nil, name: "", route_ids: [], name_error: nil, failures: []}
  end

  defp group_draft_edit(group) do
    %{
      key: group.network_id,
      name: group.name || "",
      route_ids: group.route_ids,
      name_error: nil,
      failures: []
    }
  end

  defp group_of(_socket, nil), do: nil

  defp group_of(socket, network_id) when is_binary(network_id) do
    Enum.find(socket.assigns.workspace.groups, &(&1.network_id == network_id))
  end

  # The draft as the payload a change event carries: the name is text, and the
  # route boxes are a list whose unticked entries are simply absent.
  defp group_draft(draft, _socket, params) do
    route_ids =
      case params["route_ids"] do
        # The marker field means an empty list is the operator's own answer:
        # every box unticked.
        ids when is_list(ids) -> Enum.reject(ids, &(&1 == ""))
        ids when is_binary(ids) -> if ids == "", do: draft.route_ids, else: [ids]
        # No marker and no list: the payload did not carry the route answer, so
        # the routes the draft holds are kept.
        nil -> draft.route_ids
      end

    draft
    |> Map.put(:name, to_string(params["name"] || ""))
    |> Map.put(:route_ids, route_ids)
    |> Map.put(:name_error, nil)
    |> Map.put(:failures, [])
  end

  defp put_group(socket, draft) do
    socket
    |> assign(:group_draft, draft)
    |> assign(:group_form, to_form(%{"name" => draft.name}, as: :group))
  end

  defp save_route_group(socket, draft) do
    socket = assign(socket, :drawer_pending?, true)
    name = blank_name(draft.name)
    version_name = socket.assigns.current_gtfs_version.name

    params =
      %{
        name: name,
        route_ids: draft.route_ids,
        reviewed_snapshot: Map.get(draft, :reviewed_snapshot)
      }
      |> then(fn params ->
        if draft.key, do: Map.put(params, :network_id, draft.key), else: params
      end)

    case Fares.save_route_group(fare_scope(socket), params) do
      {:ok, %{operation_id: operation_id, inverse: inverse} = result} ->
        {:noreply,
         socket
         |> load_workspace()
         |> assign(:group_draft, nil)
         |> assign(:group_focus, nil)
         |> assign(:drawer_pending?, false)
         |> assign(:price_note, %{
           text: "#{name} saved to #{version_name} service.#{moved_text(result)}",
           undo: [{operation_id, inverse}]
         })}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:drawer_pending?, false)
         |> put_group(refuse_group(socket.assigns.group_draft, reason))}
    end
  end

  # The routes the writer moved, named after the write rather than before it:
  # what the drawer warned about is what the answer reports.
  defp moved_text(%{moved: []}), do: ""

  defp moved_text(%{moved: moved}) do
    " " <> Enum.map_join(moved, ", ", &"Route #{&1.route_id} moved to this group.")
  end

  # A refused save names the field the writer would not read, and the summary is
  # the list of them rather than the first one the draft holds.
  defp refuse_group(draft, reason) do
    message = group_reason_message(reason)
    field = group_failure_field(reason)
    failure = %{href: field, msg: "#{group_failure_label(field)}: #{message}"}

    Map.merge(draft, %{name_error: message, failures: [failure]})
  end

  defp group_failure_field(:duplicate_route_group), do: "#group-name"
  defp group_failure_field(:not_found), do: "#group-routes"
  defp group_failure_field(_reason), do: "#group-name"

  defp group_failure_label("#group-routes"), do: "Routes"
  defp group_failure_label(_href), do: "Name"

  defp write_reason(:stale),
    do: "Fares changed since this dialog opened. Review them and try again"

  defp write_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp write_reason(_reason), do: "Nothing changed. Review the form and try again"

  defp group_reason_message(:duplicate_route_group),
    do: "This version already holds a group with that name."

  defp group_reason_message(:not_found), do: "This version holds no such group or route."
  defp group_reason_message(:unmanaged), do: "This version’s fares are not edited here yet."

  defp group_reason_message(%Ecto.Changeset{} = changeset) do
    # A blank name is the writer's own refusal and carries its message; the UI
    # states what the writer said rather than a second wording of it.
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Map.values()
    |> List.flatten()
    |> Enum.join(" ")
  end

  defp group_reason_message(_reason), do: "That group could not be saved."

  defp open_cell(socket, params) do
    network_id = params["network_id"]
    from = params["from"]
    to = params["to"]
    workspace = socket.assigns.workspace

    matrix = Enum.find(workspace.matrices, &(&1.network_id == network_id))
    cell = matrix && Map.get(matrix.cells, {from, to})
    reverse = matrix && Map.get(matrix.cells, {to, from})
    products = (cell && cell.products) || []
    reverse_products = (reverse && reverse.products) || []

    %{
      network_id: network_id,
      from: from,
      to: to,
      from_name: zone_name(matrix, from),
      to_name: zone_name(matrix, to),
      group_name: group_name(workspace, network_id),
      fare_product_id: cell_fare_key(products, workspace),
      both?: from != to and reverse_products in [[], products],
      reviewed: products,
      error: nil
    }
  end

  defp cell_draft(cell, params) do
    fare = blank_to_nil(params["fare_product_id"])

    cell
    |> Map.put(:fare_product_id, fare)
    |> Map.put(:both?, params["both"] == "true" and cell.from != cell.to)
    |> Map.put(:error, nil)
  end

  defp zone_name(nil, _area_id), do: nil

  defp zone_name(matrix, area_id) do
    case Enum.find(matrix.zones, &(&1.area_id == area_id)) do
      %{name: name} -> name
      nil -> area_id
    end
  end

  defp group_name(workspace, network_id) do
    case Enum.find(workspace.groups, &(&1.network_id == network_id)) do
      %{name: name} -> name || network_id
      nil -> network_id
    end
  end

  # The product a cell's fare is written by: the first `fare_product_id` the
  # workspace's own fares hold for it, because `set_zone_fare/7` reads any
  # product of a fare as that fare.
  defp cell_fare_key([], _workspace), do: nil

  defp cell_fare_key(products, workspace) do
    fare = Enum.find(workspace.fares, &(List.first(&1.product_ids) in products))
    fare && List.first(fare.product_ids)
  end

  defp set_zone_fare(socket, cell) do
    socket = assign(socket, :drawer_pending?, true)
    version_name = socket.assigns.current_gtfs_version.name

    case Fares.set_zone_fare(
           fare_scope(socket),
           cell.network_id,
           cell.from,
           cell.to,
           cell.fare_product_id,
           cell.both?,
           cell.reviewed
         ) do
      {:ok, %{operation_id: operation_id, inverse: inverse}} ->
        {:noreply,
         socket
         |> load_workspace()
         |> assign(:cell, nil)
         |> assign(:cell_focus, nil)
         |> assign(:drawer_pending?, false)
         |> assign(:price_note, %{
           text: zone_fare_note(cell, socket.assigns.workspace, version_name),
           undo: [{operation_id, inverse}]
         })}

      {:error, {:stale, _details}} ->
        {:noreply,
         assign(socket, :drawer_pending?, false)
         |> assign(:cell, %{
           cell
           | error: "That cell changed since this dialog opened. Nothing was saved."
         })}

      {:error, :pass_fare} ->
        {:noreply,
         assign(socket, :drawer_pending?, false)
         |> assign(:cell, %{cell | error: "A pass is sold, not applied to a single ride."})}

      {:error, reason} ->
        {:noreply,
         assign(socket, :drawer_pending?, false)
         |> assign(:cell, %{
           cell
           | error: "That fare could not be saved (#{write_reason(reason)})."
         })}
    end
  end

  # What the write did, in the prototype's own words. The fare is named from
  # the reloaded workspace rather than from the draft, so the note says what is
  # stored rather than what was chosen.
  defp zone_fare_note(%{fare_product_id: nil} = cell, _workspace, version_name) do
    "Removed the fare from #{cell.from_name} to #{cell.to_name} in #{version_name} service."
  end

  defp zone_fare_note(cell, workspace, version_name) do
    fare = fare_name_of(cell.fare_product_id, workspace)

    "Rides from #{cell.from_name} to #{cell.to_name}#{reverse_phrase(cell)} now pay #{fare} in #{version_name} service."
  end

  defp reverse_phrase(%{both?: true}), do: " and back"
  defp reverse_phrase(_cell), do: ""

  defp fare_name_of(nil, _workspace), do: "no fare"

  defp fare_name_of(product_id, workspace) do
    case Enum.find(workspace.fares, &(product_id in &1.product_ids)) do
      nil -> product_id
      fare -> fare.name
    end
  end

  defp pass_of_product(socket, product_id) do
    Enum.find(socket.assigns.workspace.fares, &(product_id in &1.product_ids))
  end

  defp set_pass_acceptance(socket, fare, network_id, accepted?) do
    case Fares.set_pass_acceptance(
           fare_scope(socket),
           List.first(fare.product_ids),
           network_id,
           accepted?,
           fare.accepted_network_ids
         ) do
      {:ok, %{operation_id: operation_id, inverse: inverse}} ->
        {:noreply,
         socket
         |> load_workspace()
         |> assign(:price_note, %{
           text:
             "#{fare.name} #{if accepted?, do: "is now accepted", else: "is no longer accepted"} on #{group_name(socket.assigns.workspace, network_id)}.",
           undo: [{operation_id, inverse}]
         })}

      {:error, {:stale, _details}} ->
        {:noreply,
         assign(socket, :price_note, %{
           text:
             "That pass changed since this table was read. Nothing was saved — reopen the tab to see the current acceptances."
         })}

      {:error, reason} ->
        {:noreply,
         assign(socket, :price_note, %{
           text: "That acceptance could not be saved (#{write_reason(reason)})."
         })}
    end
  end

  defp blank_name(name) when is_binary(name), do: String.trim(name)
  defp blank_name(_name), do: ""

  # -- The setup draft ---------------------------------------------------------

  # The prototype's own defaults: one price for every ride at $1.50, a reduced
  # fare and free young children, and free transfers within 90 minutes.
  defp setup_defaults do
    %{
      "kind" => "flat",
      "adult" => "1.50",
      "groups" => [
        %{"name" => "Local routes", "price" => "1.50"},
        %{"name" => "Intercity", "price" => "6.00"}
      ],
      "reduced" => true,
      "youth" => false,
      "child" => true,
      "transfer" => true,
      "minutes" => "90"
    }
  end

  # A change carries the whole question set, so the draft is rebuilt from it
  # rather than merged into: an unticked box is simply absent from the payload,
  # and a merge would keep the answer the operator just removed.
  #
  # The one answer that is not a field — the list of route groups — arrives with
  # no other answer at all, so the draft is always read through its own full
  # payload first. Every question is either in this payload or in that one, and
  # a check box is true exactly when its payload carries "true".
  defp setup_draft(setup, params) do
    previous = setup |> then(&Map.merge(setup_defaults(), &1 || %{})) |> setup_params()
    answered = Map.merge(previous, params)

    %{
      "kind" => setup_kind(answered["kind"]),
      "adult" => draft_text(answered["adult"]),
      "groups" => setup_groups(answered["groups"]),
      "reduced" => answered["reduced"] == "true",
      "youth" => answered["youth"] == "true",
      "child" => answered["child"] == "true",
      "transfer" => answered["transfer"] == "true",
      "minutes" => draft_text(answered["minutes"]),
      "adult_error" => nil,
      "minutes_error" => nil,
      "failures" => []
    }
  end

  defp draft_text(value), do: to_string(value)

  # The structure is a fixed set the writer names, so anything else arriving is
  # not read as one of them.
  defp setup_kind(kind) when kind in ~w(free flat route zone), do: kind
  defp setup_kind(_kind), do: "flat"

  defp setup_groups(groups) when is_list(groups) do
    Enum.map(groups, fn
      %{"name" => name, "price" => price} -> %{"name" => name, "price" => price}
      _other -> %{"name" => "", "price" => ""}
    end)
  end

  defp setup_groups(groups) when is_map(groups) do
    groups |> Map.values() |> Enum.sort_by(& &1) |> setup_groups()
  end

  defp setup_groups(_groups) do
    setup_defaults()["groups"]
  end

  # The draft as the payload a change event would carry, which is what the
  # add-a-group answer starts from.
  defp setup_params(setup) do
    %{
      "kind" => setup["kind"],
      "adult" => setup["adult"],
      "groups" => setup["groups"],
      "reduced" => setup["reduced"] && "true",
      "youth" => setup["youth"] && "true",
      "child" => setup["child"] && "true",
      "transfer" => setup["transfer"] && "true",
      "minutes" => setup["minutes"]
    }
  end

  # What `Conversion.setup/2` is handed. The structure is one of the writer's own
  # four, the prices arrive as the text an operator typed because
  # `Fares.Money.parse/1` is what reads a price (CR-3), and the minutes are the
  # whole number of minutes the transfer question names.
  defp setup_answers(setup) do
    %{
      kind: String.to_existing_atom(setup["kind"]),
      adult: setup["adult"],
      groups: Enum.map(setup["groups"], &{&1["name"], &1["price"]}),
      reduced: setup["reduced"],
      youth: setup["youth"],
      child: setup["child"],
      transfer_minutes: transfer_minutes(setup)
    }
  end

  defp transfer_minutes(%{"transfer" => true, "minutes" => text}) do
    case Integer.parse(String.trim(to_string(text))) do
      {minutes, ""} when minutes > 0 -> minutes
      _other -> text
    end
  end

  defp transfer_minutes(_setup), do: nil

  defp put_setup(socket, setup) do
    socket
    |> assign(:setup, setup)
    |> assign(:setup_form, to_form(setup, as: :setup))
  end

  # A refused setup names the field whose answer the writer would not read, and
  # the summary is the list of them rather than the first one the draft holds.
  defp refuse_setup(socket, reason) do
    message = setup_reason_message(reason)
    setup = socket.assigns.setup
    groups? = setup["kind"] == "route"

    {adult_error, minutes_error, failure_href} =
      case reason do
        :invalid_price when groups? ->
          {nil, nil, "#setup-group-0-price"}

        :invalid_price ->
          {message, nil, "#setup-adult"}

        :invalid_transfer_minutes ->
          {nil, message, "#setup-minutes"}

        reason when reason in [:no_groups, :invalid_group, :duplicate_group] ->
          {nil, nil, "#setup-groups"}

        _other ->
          {nil, nil, "#setup-kind"}
      end

    failure = %{href: failure_href, msg: "#{setup_failure_label(failure_href)}: #{message}"}

    put_setup(socket, %{
      setup
      | "adult_error" => adult_error,
        "minutes_error" => minutes_error,
        "failures" => [failure]
    })
  end

  defp setup_failure_label("#setup-adult"), do: "Adult price"
  defp setup_failure_label("#setup-minutes"), do: "Transfer time limit"
  defp setup_failure_label("#setup-groups"), do: "Route groups"
  defp setup_failure_label(_href), do: "Pricing structure"

  defp setup_reason_message(:invalid_price),
    do: "Enter a price in dollars and cents, such as 1.50, or Free."

  defp setup_reason_message(:invalid_transfer_minutes),
    do: "Enter the free transfer window as a whole number of minutes, such as 90."

  defp setup_reason_message(:no_groups), do: "Name at least one group of routes."
  defp setup_reason_message(:invalid_group), do: "Name each group of routes and price it."
  defp setup_reason_message(:duplicate_group), do: "Give each group of routes its own name."
  defp setup_reason_message(:unknown_structure), do: "Choose how riders pay for a ride."
  defp setup_reason_message(:has_fares), do: "This version already holds fares."
  defp setup_reason_message(_reason), do: "Those answers could not be saved."

  defp close_fare_and_media(socket) do
    socket
    |> assign(:fare_draft, nil)
    |> assign(:fare_delete, nil)
    |> assign(:media_draft, nil)
    |> assign(:media_delete, nil)
  end

  defp close_rider_and_media(socket) do
    socket
    |> assign(:rider_draft, nil)
    |> assign(:rider_delete, nil)
    |> assign(:media_draft, nil)
    |> assign(:media_delete, nil)
  end

  defp close_fare_and_rider(socket) do
    socket
    |> assign(:fare_draft, nil)
    |> assign(:fare_delete, nil)
    |> assign(:rider_draft, nil)
    |> assign(:rider_delete, nil)
  end

  defp focus_error_summary(socket) do
    push_event(socket, "focus_scoped_target", %{id: "error-summary"})
  end

  # -- The fare drawer ---------------------------------------------------------

  defp open_fare_draft(socket, %{"fare_product_id" => product_id}) do
    case fare_of_product(socket, product_id) do
      nil -> new_fare_draft(socket)
      fare -> edit_fare_draft(socket, fare)
    end
  end

  defp open_fare_draft(socket, _params), do: new_fare_draft(socket)

  defp new_fare_draft(socket) do
    workspace = socket.assigns.workspace
    base = default_media_id(workspace)

    %{
      key: nil,
      name: "",
      kind: "single",
      prices: blank_prices(workspace),
      app_prices: blank_prices(workspace),
      amounts: %{},
      app_amounts: %{},
      invalid_riders: [],
      differ?: false,
      media_ids: if(base, do: [base], else: []),
      group_ids: [],
      base_medium: base,
      app_medium: other_media_id(workspace, base),
      rules: [],
      name_error: nil,
      price_error: nil,
      media_error: nil,
      failures: []
    }
  end

  # The drawer opens on what the grid was showing: the fare's own row price for
  # each rider type, and, for the payment method that prices differently, the
  # sub-row's amount beside it.
  defp edit_fare_draft(socket, fare) do
    workspace = socket.assigns.workspace
    base = fare.base_media_id || default_media_id(workspace)
    app = app_media_id(fare, workspace, base)

    %{
      reviewed_snapshot: workspace.reviewed_snapshot,
      key: List.first(fare.product_ids),
      name: fare.name,
      kind: fare.kind,
      prices: prices_text(fare, workspace),
      app_prices: app_prices_text(fare, workspace, app),
      amounts: %{},
      app_amounts: %{},
      invalid_riders: [],
      differ?: Map.has_key?(fare.media_prices, app),
      media_ids: fare.media,
      group_ids: fare.accepted_network_ids,
      base_medium: base,
      app_medium: app,
      rules: fare.rules,
      name_error: nil,
      price_error: nil,
      media_error: nil,
      failures: []
    }
    |> parse_fare_prices()
  end

  defp blank_prices(workspace) do
    Map.new(workspace.riders, &{&1.rider_category_id, ""})
  end

  defp prices_text(fare, workspace) do
    Map.new(workspace.riders, fn rider ->
      amount = Map.get(fare.prices, rider.rider_category_id)

      {rider.rider_category_id, Money.format(amount, workspace.currency) || ""}
    end)
  end

  defp app_prices_text(_fare, workspace, nil), do: blank_prices(workspace)

  defp app_prices_text(fare, workspace, app) do
    Map.new(workspace.riders, fn rider ->
      amount = get_in(fare.media_prices, [app, rider.rider_category_id])

      {rider.rider_category_id, Money.format(amount, workspace.currency) || ""}
    end)
  end

  # The payment method a fare's own row prices: the one paid on board where the
  # version has one, because that is what the older format carries.
  defp default_media_id(workspace) do
    Enum.find_value(workspace.media, fn medium ->
      case medium do
        %{fare_media_type: 0} -> medium.fare_media_id
        _other -> nil
      end
    end) || first_media_id(workspace)
  end

  defp first_media_id(workspace) do
    case List.first(workspace.media) do
      nil -> nil
      medium -> medium.fare_media_id
    end
  end

  # The payment method the "price differs" column names: the first one that is
  # not the fare's own.
  defp other_media_id(workspace, base) do
    workspace.media
    |> Enum.map(& &1.fare_media_id)
    |> Enum.reject(&(&1 == base))
    |> List.first()
  end

  defp app_media_id(fare, workspace, base) do
    fare.media_prices |> Map.keys() |> Enum.reject(&(&1 == base)) |> List.first() ||
      other_media_id(workspace, base)
  end

  # The change event carries the whole form, so every field is rebuilt from it.
  # A checkbox that is not ticked is simply absent, which is how unticking one
  # reads.
  defp fare_draft(draft, socket, params) do
    socket
    |> merge_fare_params(draft, params)
    |> parse_fare_prices()
  end

  defp merge_fare_params(_socket, draft, params) do
    %{
      draft
      | name: params["name"] || "",
        kind: params["kind"] || draft.kind,
        differ?: params["differ"] == "true",
        media_ids: checkbox_ids(params["media_ids"]),
        group_ids: checkbox_ids(params["group_ids"]),
        prices: Map.merge(draft.prices, text_map(params["prices"])),
        app_prices:
          Map.merge(draft.app_prices, text_map(params["media_prices"][draft.app_medium]))
    }
  end

  # LiveView names every input a form's data does not account for
  # `_unused_<name>` and sends it alongside the real ones. They are the browser's
  # bookkeeping, not rider types, so they are dropped before a price is read.
  defp text_map(nil), do: %{}

  defp text_map(params) when is_map(params),
    do: Map.reject(params, fn {key, _text} -> String.starts_with?(key, "_unused_") end)

  defp checkbox_ids(nil), do: []

  defp checkbox_ids(params) when is_list(params),
    do: Enum.reject(params, &String.starts_with?(to_string(&1), "_unused_"))

  defp checkbox_ids(params) when is_binary(params), do: [params]

  # Prices are read exactly as the grid reads a cell: `Fares.Money.parse/1` is
  # what decides a price, a blank is not sold, and an unreadable one keeps the
  # rider type it belongs to so the drawer can name it and refuse the save.
  defp parse_fare_prices(draft) do
    {amounts, invalid} = read_amounts(draft.prices)
    {app_amounts, app_invalid} = read_amounts(draft.app_prices)

    %{
      draft
      | amounts: amounts,
        app_amounts: app_amounts,
        invalid_riders: Enum.uniq(invalid ++ app_invalid)
    }
  end

  defp read_amounts(texts) do
    Enum.reduce(texts, {%{}, []}, fn {rider_id, text}, {amounts, invalid} ->
      case Money.parse(text) do
        {:ok, amount} -> {Map.put(amounts, rider_id, amount), invalid}
        {:error, :invalid} -> {amounts, [rider_id | invalid]}
      end
    end)
  end

  # What a refused save found, each as a link to the field it names so the
  # summary is the list of things to fix rather than the first field that
  # happens to be at the top of the drawer.
  defp fare_failures(draft, socket) do
    {name_failure, name_error} = fare_name_failure(draft)
    {price_failure, price_error, invalid} = fare_price_failure(draft, socket)
    {media_failure, media_error} = fare_media_failure(draft)

    failures = Enum.reject([name_failure, price_failure, media_failure], &is_nil/1)

    draft = %{
      draft
      | name_error: name_error,
        price_error: price_error,
        media_error: media_error,
        invalid_riders: invalid,
        failures: failures
    }

    {draft, failures}
  end

  defp fare_name_failure(%{name: name}) do
    if blank?(name) do
      message = "Enter a name riders will see, such as Local ride."
      {%{href: "#fare-name", msg: "Name: #{message}"}, message}
    else
      {nil, nil}
    end
  end

  defp fare_price_failure(draft, socket) do
    workspace = socket.assigns.workspace

    cond do
      draft.invalid_riders != [] ->
        names = Enum.map_join(draft.invalid_riders, ", ", &rider_name(workspace, &1))

        message = "Enter a price in dollars and cents, such as 1.50, or Free."

        {%{
           href: "#fare-price-#{List.first(draft.invalid_riders)}",
           msg: "Prices: #{names}: #{message}"
         }, message, draft.invalid_riders}

      Enum.all?(draft.amounts, fn {_rider_id, amount} -> is_nil(amount) end) ->
        message = "Enter a price for at least one rider type."

        {%{href: "#fare-prices", msg: "Prices: #{message}"}, message, []}

      true ->
        {nil, nil, []}
    end
  end

  defp fare_media_failure(%{media_ids: []}) do
    message = "Choose at least one."

    {%{href: "#fare-media", msg: "Riders can pay with: #{message}"}, message}
  end

  defp fare_media_failure(%{media_ids: [_ | _]}), do: {nil, nil}

  defp rider_name(workspace, rider_id) do
    case Enum.find(workspace.riders, &(&1.rider_category_id == rider_id)) do
      %{name: name} -> name || rider_id
      nil -> rider_id
    end
  end

  # -- Writing a fare ----------------------------------------------------------

  defp save_fare(socket, draft) do
    socket = socket |> assign(:fare_draft, draft) |> assign(:drawer_pending?, true)
    name = draft.name
    version_name = socket.assigns.current_gtfs_version.name

    case write_each(
           fare_scope(socket),
           Enum.map(fare_calls(socket, draft), &{&1}),
           &Fares.save_fare/2
         ) do
      {:ok, undos} ->
        {:noreply,
         socket
         |> load_workspace()
         |> assign(:fare_draft, nil)
         |> assign(:fare_focus, nil)
         |> assign(:drawer_pending?, false)
         |> assign(:price_note, %{text: "#{name} saved to #{version_name} service.", undo: undos})}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:drawer_pending?, false)
         |> assign(:price_note, %{text: "#{name} couldn’t be saved (#{write_reason(reason)})."})}
    end
  end

  # One `Fares.save_fare/2` call per `fare_products` row the fare owns.
  #
  # The writers address one product at a time, and an imported fare holds one row
  # per rider type and payment method — "Local ride" is eight rows, not one. So
  # the draft's grid is grouped by the row each cell already writes: a cell keeps
  # the id it had, because the leg rules name that id, and a cell with no row yet
  # joins the fare's first row, which is the same convention the price grid's
  # `cell_product_id/3` uses. Each call is then scoped to its own row's rider type
  # and payment method, so no call invents a row that was not there.
  #
  # A fare being created has no rows to inherit, so it takes a single call under
  # the id its name produces — which is the shape `Conversion` writes.
  defp fare_calls(socket, draft) do
    fare = current_fare(socket, draft)

    draft
    |> fare_cells(fare)
    |> Map.new(fn {rider_id, medium_id} ->
      {{rider_id, medium_id}, fare_cell_product(fare, rider_id, medium_id, draft)}
    end)
    |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
    |> Enum.map(fn {product_id, cells} -> fare_call(draft, fare, product_id, cells) end)
  end

  defp fare_call(draft, fare, product_id, cells) do
    media_ids = cells |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    %{
      name: draft.name,
      fare_product_id: product_id,
      kind: draft.kind,
      media_ids: media_ids,
      prices: cell_prices(draft, cells),
      media_prices: %{},
      accepted_network_ids: draft.group_ids,
      reviewed_snapshot: Map.get(draft, :reviewed_snapshot),
      position: fare && fare.position
    }
  end

  # One row's prices: every cell that row owns, at what the draft says for that
  # rider type on that payment method. The text is sent rather than the parsed
  # amount, because `Fares.Money.parse/1` is what decides a price at the writer
  # too — a blank is "not sold" there as it is here.
  defp cell_prices(draft, cells) do
    Map.new(cells, fn cell -> {elem(cell, 0), fare_cell_text(draft, cell)} end)
  end

  defp fare_cell_text(draft, {rider_id, medium_id}) do
    if medium_id == draft.app_medium and draft.differ? do
      Map.get(draft.app_prices, rider_id, "")
    else
      Map.get(draft.prices, rider_id, "")
    end
  end

  # Every cell the draft draws: one per rider type, on each payment method the
  # fare is sold on.
  defp fare_cells(draft, _fare) do
    for rider_id <- Map.keys(draft.prices),
        medium_id <- draft.media_ids,
        do: {rider_id, medium_id}
  end

  # A fare being created has no row to inherit, and `Fares.save_fare/2` names the
  # new id from the fare's own name, so the whole draft is one create under no id.
  defp fare_cell_product(nil, _rider_id, _medium_id, _draft), do: nil

  defp fare_cell_product(fare, rider_id, medium_id, _draft) do
    fare.cells
    |> Enum.find_value(List.first(fare.product_ids), fn cell ->
      if cell.rider_category_id == rider_id and cell_medium_id(cell, fare) == medium_id do
        cell.fare_product_id
      end
    end)
  end

  # A stored row naming no payment method is the fare's own base method, so it
  # answers to the id the grid drew it under.
  defp cell_medium_id(cell, fare), do: cell.fare_media_id || fare.base_media_id

  defp current_fare(%{assigns: %{fare_draft: %{key: nil}}}, _draft), do: nil

  defp current_fare(socket, draft), do: fare_of_product(socket, draft.key)

  # -- Deleting a fare ---------------------------------------------------------

  defp delete_fare(socket, state) do
    fare = state.fare
    version_name = socket.assigns.current_gtfs_version.name

    # "Nothing chosen" and "no fare" are different answers, and neither is an
    # answer a fare no rule charges needs: nothing points at it, so it goes.
    # A priced fare is not deleted while the operator has not said what its rides
    # should charge instead.
    case replacement_choice(socket, state.replacement) do
      :unchosen when state.rules == [] ->
        write_fare_delete(socket, state, fare, nil, version_name)

      :unchosen ->
        {:noreply, socket |> put_replacement_error(state) |> focus_replacement()}

      replacement ->
        write_fare_delete(socket, state, fare, replacement, version_name)
    end
  end

  defp put_replacement_error(socket, state) do
    assign(socket, :fare_delete, %{state | error: "Choose what these rides charge instead."})
  end

  defp focus_replacement(socket) do
    push_event(socket, "focus_scoped_target", %{id: "fare-delete-replacement"})
  end

  defp write_fare_delete(socket, state, fare, replacement, version_name) do
    socket = assign(socket, :drawer_pending?, true)

    case write_each(
           fare_scope(socket),
           delete_fare_calls(fare, replacement, Map.get(state, :reviewed_snapshot)),
           &Fares.delete_fare/4
         ) do
      {:ok, undos} ->
        {:noreply,
         socket
         |> load_workspace()
         |> assign(:fare_draft, nil)
         |> assign(:fare_delete, nil)
         |> assign(:fare_focus, nil)
         |> assign(:drawer_pending?, false)
         |> assign(:price_note, %{
           text: "#{fare.name} deleted from #{version_name} service.",
           undo: undos
         })}

      {:error, :replacement_required} ->
        {:noreply,
         socket
         |> assign(:drawer_pending?, false)
         |> put_replacement_error(state)
         |> focus_replacement()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:drawer_pending?, false)
         |> assign(:price_note, %{
           text: "#{fare.name} couldn’t be deleted (#{inspect(reason)})."
         })}
    end
  end

  # One `Fares.delete_fare/4` call per row the fare owns, each fenced against
  # only that row's own prices: the fence is checked against what is stored at
  # the time of the call, and an earlier call in the fan-out has already removed
  # the rows that came before it.
  #
  # The replacement is chosen by fare, and each row is pointed at the
  # replacement's row for the same rider type and payment method — a rule about a
  # reduced rider's cash price belongs on the reduced rider's cash price. A row
  # the replacement does not mirror falls back to the replacement's own first
  # row, and choosing "no fare" removes the rules instead.
  defp delete_fare_calls(fare, replacement, snapshot) do
    for product_id <- fare.product_ids do
      cells = Enum.filter(fare.cells, &(&1.fare_product_id == product_id))

      {product_id, replacement_product(fare, replacement, product_id),
       %{
         reviewed_snapshot: snapshot,
         name: fare.name,
         kind: fare.kind,
         prices:
           Enum.map(cells, fn cell ->
             %{
               fare_product_id: cell.fare_product_id,
               rider_category_id: cell.rider_category_id,
               fare_media_id: cell.fare_media_id,
               reviewed: stored_row_amount(fare, cell.rider_category_id, cell.fare_media_id)
             }
           end)
       }}
    end
  end

  # What the chosen replacement resolves to: `:unchosen` while the operator has
  # not answered, `:remove_rules` for the explicit "no fare", and otherwise the
  # fare whose rows the rules move to.
  defp replacement_choice(_socket, nil), do: :unchosen
  defp replacement_choice(_socket, ""), do: :unchosen
  defp replacement_choice(_socket, "none"), do: :remove_rules
  defp replacement_choice(socket, product_id), do: fare_of_product(socket, product_id)

  # The row one of the deleted fare's own rows is replaced by: the replacement
  # fare's row for the same rider type and payment method. The deleted row is
  # looked up on the fare being deleted, which is the only one that knows it.
  defp replacement_product(_fare, :remove_rules, _product_id), do: :remove_rules

  defp replacement_product(_fare, nil, _product_id), do: nil

  defp replacement_product(fare, replacement, product_id) do
    cell = Enum.find(fare.cells, &(&1.fare_product_id == product_id))

    mirrored =
      cell &&
        Enum.find(replacement.cells, fn other ->
          other.rider_category_id == cell.rider_category_id and
            other.fare_media_id == cell.fare_media_id
        end)

    (mirrored && mirrored.fare_product_id) || List.first(replacement.product_ids)
  end

  # -- The rider type drawer ---------------------------------------------------

  defp open_rider_draft(socket, %{"rider_category_id" => rider_id}) do
    case Enum.find(socket.assigns.workspace.riders, &(&1.rider_category_id == rider_id)) do
      nil ->
        new_rider_draft(socket)

      rider ->
        edit_rider_draft(rider)
        |> Map.put(:reviewed_snapshot, socket.assigns.workspace.reviewed_snapshot)
    end
  end

  defp open_rider_draft(socket, _params), do: new_rider_draft(socket)

  defp new_rider_draft(_socket) do
    %{
      key: nil,
      name: "",
      eligibility_url: "",
      default?: false,
      default_locked?: false,
      starting: "half",
      name_error: nil,
      failures: []
    }
  end

  defp edit_rider_draft(rider) do
    %{
      key: rider.rider_category_id,
      name: rider.name || "",
      eligibility_url: rider.eligibility_url || "",
      default?: rider.default?,
      # The one rider type shown first cannot give that up here: another editor
      # has to claim it first, so the control is stated rather than offered.
      default_locked?: rider.default?,
      starting: "same",
      name_error: nil,
      failures: []
    }
  end

  defp rider_draft(draft, _socket, params) do
    %{
      draft
      | name: params["name"] || "",
        eligibility_url: params["eligibility_url"] || "",
        default?: params["default?"] == "true" or draft.default_locked?,
        starting: params["starting"] || draft.starting
    }
  end

  defp rider_failures(draft) do
    if blank?(draft.name) do
      message = "Enter a name riders will see, such as Reduced fare."
      failures = [%{href: "#rider-name", msg: "Name: #{message}"}]

      {%{draft | name_error: message, failures: failures}, failures}
    else
      {%{draft | name_error: nil}, []}
    end
  end

  defp save_rider_type(socket, draft) do
    scope = fare_scope(socket)
    socket = socket |> assign(:rider_draft, draft) |> assign(:drawer_pending?, true)
    name = draft.name
    version_name = socket.assigns.current_gtfs_version.name

    params = %{
      name: name,
      reviewed_snapshot: Map.get(draft, :reviewed_snapshot),
      rider_category_id: draft.key,
      eligibility_url: blank_to_nil(draft.eligibility_url),
      default?: draft.default?
    }

    params =
      if draft.key,
        do: params,
        else: Map.put(params, :starting, starting_choice(draft.starting))

    case Fares.save_rider_type(scope, params) do
      {:ok, %{operation_id: operation_id, inverse: inverse}} ->
        {:noreply,
         socket
         |> load_workspace()
         |> assign(:rider_draft, nil)
         |> assign(:rider_focus, nil)
         |> assign(:drawer_pending?, false)
         |> assign(:price_note, %{
           text: "#{name} saved to #{version_name} service.",
           undo: [{operation_id, inverse}]
         })}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:drawer_pending?, false)
         |> assign(:price_note, %{text: "#{name} couldn’t be saved (#{write_reason(reason)})."})}
    end
  end

  # The starting choice is a fixed set named by the drawer's own choice cards, so
  # it is read from that set rather than turned into an atom from what arrived.
  defp starting_choice("half"), do: :half
  defp starting_choice("same"), do: :same
  defp starting_choice("free"), do: :free
  defp starting_choice("blank"), do: :blank

  defp rider_price_count(workspace, rider_id) do
    Enum.count(workspace.fares, fn fare ->
      Map.has_key?(fare.prices, rider_id) or
        Enum.any?(Map.values(fare.media_prices), &Map.has_key?(&1, rider_id))
    end)
  end

  # -- The payment method drawer -----------------------------------------------

  defp open_media_draft(socket, %{"fare_media_id" => medium_id}) do
    case Enum.find(socket.assigns.workspace.media, &(&1.fare_media_id == medium_id)) do
      nil -> new_media_draft(socket)
      medium -> edit_media_draft(socket, medium)
    end
  end

  defp open_media_draft(socket, _params), do: new_media_draft(socket)

  defp new_media_draft(_socket) do
    %{
      key: nil,
      name: "",
      fare_media_type: 0,
      accepted_products: [],
      name_error: nil,
      failures: []
    }
  end

  defp edit_media_draft(socket, medium) do
    %{
      reviewed_snapshot: socket.assigns.workspace.reviewed_snapshot,
      key: medium.fare_media_id,
      name: medium.name || "",
      fare_media_type: medium.fare_media_type || 0,
      accepted_products: accepted_products(socket, medium.fare_media_id),
      name_error: nil,
      failures: []
    }
  end

  # The fares a payment method is accepted for, as the `fare_products` row that
  # `Fares.save_payment_method/4` names. One row per fare is enough, because the
  # writer expands it to every row of the same fare name.
  defp accepted_products(socket, medium_id) do
    for fare <- socket.assigns.workspace.fares,
        medium_id in fare.media,
        product_id = List.first(fare.product_ids),
        do: product_id
  end

  defp media_draft(draft, _socket, params) do
    %{
      draft
      | name: params["name"] || "",
        fare_media_type: media_type_param(params["fare_media_type"], draft.fare_media_type),
        accepted_products: checkbox_ids(params["accepted_products"])
    }
  end

  # The kind is one of the five the drawer's choice cards offer, so anything else
  # arriving is not read as a kind at all.
  defp media_type_param(nil, current), do: current
  defp media_type_param(text, _current) when text in ~w(0 1 2 3 4), do: String.to_integer(text)
  defp media_type_param(_text, current), do: current

  defp media_failures(draft) do
    if blank?(draft.name) do
      message = "Enter a name riders will see, such as NCT Ride app."
      failures = [%{href: "#media-name", msg: "Name: #{message}"}]

      {%{draft | name_error: message, failures: failures}, failures}
    else
      {%{draft | name_error: nil}, []}
    end
  end

  defp save_payment_method(socket, draft) do
    scope = fare_scope(socket)
    socket = socket |> assign(:media_draft, draft) |> assign(:drawer_pending?, true)
    name = draft.name
    version_name = socket.assigns.current_gtfs_version.name

    params = %{
      name: name,
      reviewed_snapshot: Map.get(draft, :reviewed_snapshot),
      fare_media_id: draft.key,
      fare_media_type: draft.fare_media_type,
      fare_product_ids: draft.accepted_products
    }

    case Fares.save_payment_method(scope, params) do
      {:ok, %{operation_id: operation_id, inverse: inverse}} ->
        {:noreply,
         socket
         |> load_workspace()
         |> assign(:media_draft, nil)
         |> assign(:media_focus, nil)
         |> assign(:drawer_pending?, false)
         |> assign(:price_note, %{
           text: "#{name} saved to #{version_name} service.",
           undo: [{operation_id, inverse}]
         })}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:drawer_pending?, false)
         |> assign(:price_note, %{text: "#{name} couldn’t be saved (#{write_reason(reason)})."})}
    end
  end

  defp media_fare_count(workspace, medium_id) do
    Enum.count(workspace.fares, &(medium_id in &1.media))
  end

  # -- Writing -----------------------------------------------------------------

  # A fan-out of writes, newest failure first: the writes stop at the first one
  # that is refused and the caller reports that reason, rather than pressing on
  # with a half-written fare. The undos come back in the order they were written,
  # which is the order they have to be reversed in.
  defp write_each(scope, calls, writer) do
    result =
      if writer == (&Fares.save_fare/2) do
        params = Enum.map(calls, &elem(&1, 0))

        if length(params) == 1 and is_nil(hd(params).fare_product_id),
          do: Fares.save_fare(scope, hd(params)),
          else: Fares.save_fares(scope, params)
      else
        Fares.delete_fares(scope, calls)
      end

    case result do
      {:ok, %{operation_id: id, inverse: inverse}} -> {:ok, [{id, inverse}]}
      error -> error
    end
  end

  defp undo_writes(scope, undos) do
    Enum.reduce_while(Enum.reverse(undos), {:ok, []}, fn undo, {:ok, done} ->
      case Fares.undo(scope, elem(undo, 0), elem(undo, 1)) do
        {:ok, _result} -> {:cont, {:ok, done}}
        {:error, _reason} -> {:halt, {:error, :refused}}
      end
    end)
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp price_edit(socket, {key, text}, edits) do
    edit = price_edit(text)

    if edit.invalid? or edited?(socket, key, edit) do
      Map.put(edits, key, edit)
    else
      Map.delete(edits, key)
    end
  end

  # Whether a cell's text is an edit at all: a different amount, or a rider type
  # the fare was not sold to and now is (which stores the amount for the first
  # time) or is not (which removes the row).
  defp edited?(socket, key, edit) do
    case stored_amount(socket, key) do
      :none -> not is_nil(edit.amount)
      amount -> not same_amount?(amount, edit.amount)
    end
  end

  defp same_amount?(nil, nil), do: true
  defp same_amount?(a, b), do: Decimal.equal?(a, b)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_organization={@current_organization}
      user_roles={@user_roles}
      current_path={@current_path}
      current_gtfs_version={assigns[:current_gtfs_version]}
      available_versions={assigns[:available_versions] || []}
    >
      <div id="fare-editor-page" class="ds-page min-w-0">
        <.back_link id="settings-back" navigate={settings_path(@current_gtfs_version.id)}>
          Settings
        </.back_link>

        <.header>
          Fares
          <:subtitle>
            What riders pay and which fare each ride charges. Exports include both GTFS fare
            formats.
          </:subtitle>
          <:actions>
            <.header_primary
              active_tab={@live_action}
              ready?={@load_state == :ready}
              transfers?={@has_transfer_rules?}
              dirty?={@price_edits != %{} and @load_state == :ready}
              prices_ready?={@load_state == :ready and @prices_mode == :grid}
            />
          </:actions>
        </.header>

        <.fares_tabs
          gtfs_version_id={@current_gtfs_version.id}
          active_tab={@live_action}
          checks_count={if @load_state == :ready, do: checks_count(@checks), else: nil}
          checks_tone={if @load_state == :ready, do: checks_tone(@checks), else: nil}
        />

        <div class="mt-4 grid min-w-0 grid-cols-1 gap-4">
          <.loading :if={@load_state == :loading} />
          <.load_error :if={@load_state == :unavailable} />
          <%!-- The tab's own body arrives with the tab that owns it; the shell
          owns the frame above and the load states beside it. --%>
          <div :if={@load_state == :ready} id="fare-editor-panel" class="min-w-0">
            <div
              :if={@live_action == :where}
              id="fare-where-panel"
              class="grid min-w-0 grid-cols-1 gap-4"
            >
              <.fare_note note={@price_note} />
              <p id="where-lede" class="max-w-[80ch] text-sm text-default">
                A ride’s fare depends on its <b class="font-semibold text-strong">route group</b>
                and, where you price by zone,
                the <b class="font-semibold text-strong">zones</b>
                where it starts and ends. What a
                rider pays when they change buses is on the Transfers tab.
              </p>
              <.route_groups_card workspace={@workspace} />
              <.zone_matrix
                :for={matrix <- @workspace.matrices}
                matrix={matrix}
                workspace={@workspace}
              />
              <.passes_card
                workspace={@workspace}
                version_name={@current_gtfs_version.name}
                published?={published?(@current_gtfs_version)}
              />
              <.time_periods_card workspace={@workspace} />
              <.rule_list_card
                rules={editor_rules(@workspace)}
                workspace={@workspace}
                show_ids?={@show_rule_ids?}
              />
            </div>

            <div :if={@live_action == :transfers} id="fare-transfers-panel">
              <.fare_note note={@price_note} />
              <.transfers_tab
                workspace={@workspace}
                older_allowances={@older_allowances}
                has_rules?={@has_transfer_rules?}
              />
            </div>

            <div :if={@live_action == :checks} id="fare-checks-panel" class="grid min-w-0 gap-4">
              <.fares_checks_tab checks={@checks} version_id={@current_gtfs_version.id} />
              <.journey_check
                workspace={@workspace}
                form={@journey_form}
                routes={@journey_routes}
                stops={@journey_stops}
                result={@journey_result}
                note={@journey_note}
              />
              <.saved_journeys journeys={@saved_journeys} currency={@workspace.currency} />
              <.formats_section counts={@format_counts} />
            </div>

            <div :if={@live_action == :prices} id="fare-prices-panel" class="grid gap-4">
              <.fare_note note={@price_note} />
              <.fare_setup
                :if={@prices_mode == :setup and @setup != nil}
                setup={@setup}
                form={@setup_form}
                version_name={@current_gtfs_version.name}
              />
              <.fare_free_summary
                :if={@prices_mode == :free}
                workspace={@workspace}
                version_name={@current_gtfs_version.name}
              />
              <.unmanaged_fares
                :if={@prices_mode == :unmanaged}
                workspace={@workspace}
                unmanaged={@workspace.unmanaged}
              />
              <%= if @prices_mode == :grid do %>
                <.fares_mismatch_banner
                  :if={@older_mismatches != []}
                  differences={@older_mismatches}
                  currency={@workspace.currency}
                />
                <.fares_conflict
                  :if={@price_conflict}
                  conflict={@price_conflict}
                  workspace={@workspace}
                />
                <.form
                  for={@price_form}
                  id="fare-table-form"
                  phx-change="edit_price"
                  class="min-w-0"
                >
                  <.fare_table
                    workspace={@workspace}
                    edits={@price_edits}
                    lens?={@lens?}
                    carried={@carried}
                  />
                </.form>
                <.price_save_bar
                  :if={@price_edits != %{}}
                  workspace={@workspace}
                  edits={@price_edits}
                  journeys={@price_impacts}
                  blocked?={blocked?(assigns)}
                  blocking_reason={blocking_reason(assigns)}
                  version_name={@current_gtfs_version.name}
                  published?={published?(@current_gtfs_version)}
                />
                <.fare_cards workspace={@workspace} history={@workspace.history} />
              <% end %>
            </div>
          </div>
        </div>

        <%!-- The drawers are siblings of the grid, not cells inside it: a drawer
          is fixed to the edge of the viewport, and a grid container would place it
          by its own column. They also sit outside the grid's own form, because a
          drawer is a separate form with its own submit and two nested forms submit
          the wrong one. --%>

        <.fare_drawer
          :if={@fare_draft}
          draft={@fare_draft}
          form={to_form(%{"name" => @fare_draft.name}, as: :fare)}
          workspace={@workspace}
          version_name={@current_gtfs_version.name}
          published?={published?(@current_gtfs_version)}
          return_focus_id={@fare_focus}
          pending?={@drawer_pending?}
        />
        <.fare_delete_dialog
          :if={@fare_delete}
          fare_delete={@fare_delete}
          workspace={@workspace}
          return_focus_id={@fare_focus}
        />
        <.rider_drawer
          :if={@rider_draft}
          draft={@rider_draft}
          form={
            to_form(
              %{"name" => @rider_draft.name, "eligibility_url" => @rider_draft.eligibility_url},
              as: :rider
            )
          }
          workspace={@workspace}
          version_name={@current_gtfs_version.name}
          return_focus_id={@rider_focus}
          pending?={@drawer_pending?}
        />
        <.rider_delete_dialog
          :if={@rider_delete}
          rider_delete={@rider_delete}
          workspace={@workspace}
          return_focus_id={@rider_focus}
        />
        <.media_drawer
          :if={@media_draft}
          draft={@media_draft}
          form={to_form(%{"name" => @media_draft.name}, as: :media)}
          workspace={@workspace}
          return_focus_id={@media_focus}
          pending?={@drawer_pending?}
        />
        <.media_delete_dialog
          :if={@media_delete}
          media_delete={@media_delete}
          return_focus_id={@media_focus}
        />
        <.price_change_dialog
          :if={@price_change}
          change={@price_change}
          workspace={@workspace}
          version_name={@current_gtfs_version.name}
          published?={published?(@current_gtfs_version)}
          return_focus_id={@price_change_focus}
        />

        <%!-- The conversion review is a dialog rather than a page: it is opened
          from one button on a read-only table and answers the same way whether
          it accepts or refuses. --%>
        <.conversion_review
          :if={@conversion}
          conversion={@conversion}
          return_focus_id={@conversion_focus}
        />

        <%!-- The Where tab's two overlays, siblings of the grid like every other
          drawer here: a drawer is fixed to the edge of the viewport, and a grid
          container would place it by its own column. --%>
        <.group_drawer
          :if={@group_draft}
          draft={@group_draft}
          form={@group_form}
          workspace={@workspace}
          version_name={@current_gtfs_version.name}
          published?={published?(@current_gtfs_version)}
          return_focus_id={@group_focus}
          pending?={@drawer_pending?}
        />
        <.cell_dialog
          :if={@cell}
          cell={@cell}
          form={@cell_form}
          workspace={@workspace}
          version_name={@current_gtfs_version.name}
          published?={published?(@current_gtfs_version)}
          return_focus_id={@cell_focus}
          pending?={@drawer_pending?}
        />
        <.time_period_drawer
          :if={@time_period_draft}
          draft={@time_period_draft}
          form={to_form(%{"name" => @time_period_draft.name}, as: :time_period)}
          version_name={@current_gtfs_version.name}
          published?={published?(@current_gtfs_version)}
          return_focus_id={@time_period_focus}
          pending?={@drawer_pending?}
        />
        <.rule_drawer
          :if={@rule_draft}
          draft={@rule_draft}
          form={@rule_form}
          workspace={@workspace}
          rules={editor_rules(@workspace)}
          overlaps={rule_overlaps(@workspace, @rule_draft)}
          version_name={@current_gtfs_version.name}
          published?={published?(@current_gtfs_version)}
          return_focus_id={@rule_focus}
          pending?={@drawer_pending?}
        />
        <.transfer_drawer
          :if={@transfer_draft}
          draft={@transfer_draft}
          form={
            to_form(
              %{
                "minutes" => @transfer_draft.minutes,
                "basis" => to_string(@transfer_draft.basis),
                "count" => @transfer_draft.count,
                "fee" => @transfer_draft.fee
              },
              as: :transfer
            )
          }
          scope={@transfer_scope}
          workspace={@workspace}
          version_name={@current_gtfs_version.name}
          published?={published?(@current_gtfs_version)}
          return_focus_id={@transfer_focus}
          pending?={@drawer_pending?}
        />
      </div>
    </Layouts.app>
    """
  end

  # One scoped read of the version's whole fare model. A lost connection is
  # reported once so the page can offer its reload action; a previous workspace
  # stays in assigns, so a failed refresh never erases values a later step can
  # still render — the load state decides what is shown.
  defp load_workspace(socket) do
    organization_id = organization_id(socket)
    gtfs_version_id = version_id(socket)

    case Gtfs.load_fare_editor(organization_id, gtfs_version_id, []) do
      {:ok, workspace} ->
        workspace =
          Map.put(
            workspace,
            :reviewed_snapshot,
            Map.get(workspace, :reviewed_snapshot) ||
              Fares.reviewed_snapshot(organization_id, gtfs_version_id)
          )

        socket = assign(socket, :workspace, workspace)

        routes = Gtfs.list_routes(organization_id, gtfs_version_id, page: 1, per_page: 1_000)
        stops = Gtfs.list_stops(organization_id, gtfs_version_id)
        rows = Interpreter.load_rows(organization_id, gtfs_version_id)

        journey_params =
          initial_journey_params(socket.assigns.journey_params, workspace, routes, stops, rows)

        saved_journeys =
          saved_journey_rows(Fares.saved_journeys(organization_id, gtfs_version_id), rows)

        format_counts = format_counts(organization_id, gtfs_version_id, rows)

        socket
        |> assign(:checks, Fares.Checks.run(organization_id, gtfs_version_id))
        |> assign(:journey_routes, routes)
        |> assign(:journey_stops, stops)
        |> assign(:journey_params, journey_params)
        |> assign(:journey_form, to_form(journey_params, as: :journey))
        |> assign(:priced_journey, journey_data(journey_params, routes, stops, workspace))
        |> assign(
          :journey_result,
          journey_result(journey_params, routes, stops, workspace, rows)
        )
        |> assign(:saved_journeys, saved_journeys)
        |> assign(:format_counts, format_counts)
        |> assign(:prices_mode, prices_mode(workspace))
        |> assign(
          :older_mismatches,
          older_mismatches(workspace, organization_id, gtfs_version_id)
        )
        |> assign(:load_state, :ready)
        |> assign(:older_allowances, older_allowances(organization_id, gtfs_version_id))
        |> assign(:has_transfer_rules?, Enum.any?(workspace.transfers, & &1.policy))
        |> refresh_setup()

      {:error, :unavailable} ->
        assign(socket, :load_state, :unavailable)
    end
  end

  defp older_allowances(organization_id, version_id) do
    Projection.v1_rows(organization_id, version_id)
    |> Map.fetch!("fare_attributes.txt")
  end

  # A journey is assembled only from the current authenticated version's route,
  # stop and rider catalogs. The form carries GTFS ids, never organization or
  # version identity; unavailable ids are rejected before pricing or writing.
  defp initial_journey_params(current, workspace, routes, stops, rows) do
    defaults = %{
      "rider_category_id" =>
        workspace.riders |> Enum.find(& &1.default?) |> then(&(&1 && &1.rider_category_id)) ||
          (Enum.at(workspace.riders, 0) && Enum.at(workspace.riders, 0).rider_category_id) || "",
      "fare_media_id" => preferred_media_id(workspace.media),
      "service_date" => Date.to_iso8601(Date.utc_today()),
      "legs" => [default_journey_leg(routes, stops, [])]
    }

    cond do
      valid_journey_params?(current, workspace, routes, stops) -> current
      priced = priced_default_journey(defaults, workspace, routes, stops, rows) -> priced
      true -> defaults
    end
  end

  defp priced_default_journey(defaults, workspace, routes, stops, rows) do
    pairs =
      stops
      |> Stream.flat_map(fn from -> Stream.map(stops, &{from, &1}) end)
      |> Stream.filter(&shared_journey_area?(&1, rows))

    routes
    |> Stream.flat_map(fn route -> Stream.map(pairs, &{route, &1}) end)
    |> Stream.flat_map(fn {route, {from, to}} ->
      Stream.map(workspace.riders, &{route, from, to, &1})
    end)
    |> Enum.find_value(&priced_journey_choice(&1, defaults, workspace, routes, stops, rows))
  end

  defp shared_journey_area?({from, to}, rows) do
    from.stop_id != to.stop_id and
      Enum.any?(Map.get(rows.stop_areas, from.stop_id, []), fn area ->
        area in Map.get(rows.stop_areas, to.stop_id, [])
      end)
  end

  defp priced_journey_choice({route, from, to, rider}, defaults, workspace, routes, stops, rows) do
    params =
      defaults
      |> Map.put("rider_category_id", rider.rider_category_id)
      |> Map.put("legs", [
        %{
          "route_id" => route.route_id,
          "from_stop_id" => from.stop_id,
          "to_stop_id" => to.stop_id,
          "departs" => "07:40"
        }
      ])

    case journey_result(params, routes, stops, workspace, rows) do
      %{total: %Decimal{}} -> params
      _ -> nil
    end
  end

  defp valid_journey_params?(params, workspace, routes, stops) when is_map(params) do
    route_ids = MapSet.new(routes, & &1.route_id)
    stop_ids = MapSet.new(stops, & &1.stop_id)
    rider_ids = MapSet.new(workspace.riders, & &1.rider_category_id)

    MapSet.member?(rider_ids, params["rider_category_id"]) and
      is_list(params["legs"]) and params["legs"] != [] and
      Enum.all?(params["legs"], fn leg ->
        MapSet.member?(route_ids, leg["route_id"]) and
          MapSet.member?(stop_ids, leg["from_stop_id"]) and
          MapSet.member?(stop_ids, leg["to_stop_id"])
      end)
  end

  defp valid_journey_params?(_, _, _, _), do: false

  defp preferred_media_id(media) do
    case Enum.find(media, &(String.downcase(&1.name) == "cash")) || List.first(media) do
      nil -> ""
      medium -> medium.fare_media_id
    end
  end

  defp default_journey_leg(routes, stops, existing) do
    first = List.first(existing)

    %{
      "route_id" => journey_initial_id(first, "route_id", List.first(routes)),
      "from_stop_id" => journey_initial_id(first, "from_stop_id", List.first(stops)),
      "to_stop_id" =>
        journey_initial_id(first, "to_stop_id", Enum.at(stops, 1) || List.first(stops)),
      "departs" => "07:40"
    }
  end

  defp journey_initial_id(existing, key, row) do
    map_value(existing, key) ||
      if(row, do: Map.get(row, if(key == "route_id", do: :route_id, else: :stop_id)), else: "")
  end

  defp map_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, String.to_existing_atom(key))

  defp map_value(_, _), do: nil

  defp put_journey(socket, params) do
    params = normalize_journey_params(params, socket.assigns.journey_params)
    organization_id = organization_id(socket)
    gtfs_version_id = version_id(socket)
    routes = socket.assigns.journey_routes
    stops = socket.assigns.journey_stops
    journey = journey_data(params, routes, stops, socket.assigns.workspace)
    rows = Interpreter.load_rows(organization_id, gtfs_version_id)
    result = if journey, do: Pricing.price_journey(rows, journey), else: nil

    socket
    |> assign(:journey_params, params)
    |> assign(:journey_form, to_form(params, as: :journey))
    |> assign(:priced_journey, journey)
    |> assign(:journey_result, result)
    |> assign(:journey_note, nil)
  end

  defp normalize_journey_params(params, existing) do
    params = Map.take(params, ["rider_category_id", "fare_media_id", "service_date", "legs"])
    legs = normalize_legs(Map.get(params, "legs"), existing["legs"] || [])
    Map.merge(existing, params) |> Map.put("legs", legs)
  end

  defp normalize_legs(legs, _existing) when is_list(legs), do: legs

  defp normalize_legs(legs, _existing) when is_map(legs) do
    legs
    |> Enum.sort_by(fn {index, _leg} ->
      case Integer.parse(to_string(index)) do
        {n, ""} -> n
        _ -> 0
      end
    end)
    |> Enum.map(&elem(&1, 1))
  end

  defp normalize_legs(_, existing), do: existing

  defp journey_data(params, routes, stops, workspace) when is_map(params) do
    route_ids = MapSet.new(routes, & &1.route_id)
    stop_ids = MapSet.new(stops, & &1.stop_id)
    {:ok, service_date} = Date.from_iso8601(params["service_date"] || "")
    rider_ids = MapSet.new(workspace.riders, & &1.rider_category_id)
    media_ids = MapSet.new(workspace.media, & &1.fare_media_id)

    legs =
      Enum.map(params["legs"] || [], fn leg ->
        with true <- MapSet.member?(route_ids, leg["route_id"]),
             true <- MapSet.member?(stop_ids, leg["from_stop_id"]),
             true <- MapSet.member?(stop_ids, leg["to_stop_id"]),
             {:ok, departs} <- parse_board_time(leg["departs"]) do
          %{
            route_id: leg["route_id"],
            from_stop_id: leg["from_stop_id"],
            to_stop_id: leg["to_stop_id"],
            departs: departs,
            arrives: departs
          }
        else
          _ -> nil
        end
      end)

    if length(legs) == length(params["legs"] || []) and legs != [] and
         MapSet.member?(rider_ids, params["rider_category_id"]) and
         (empty_to_nil(params["fare_media_id"]) == nil or
            MapSet.member?(media_ids, params["fare_media_id"])) do
      %{
        rider_category_id: params["rider_category_id"],
        fare_media_id: empty_to_nil(params["fare_media_id"]),
        service_date: service_date,
        legs: legs
      }
    end
  rescue
    _ -> nil
  end

  defp journey_data(_, _, _, _), do: nil

  defp journey_result(params, routes, stops, workspace, rows) do
    case journey_data(params, routes, stops, workspace) do
      nil -> nil
      journey -> Pricing.price_journey(rows, journey)
    end
  end

  defp parse_board_time(value) when is_binary(value) do
    case Regex.run(~r/^(\d{2}):(\d{2})$/, value) do
      [_, hours, minutes] ->
        with {hour, ""} <- Integer.parse(hours),
             {minute, ""} <- Integer.parse(minutes),
             true <- hour < 24 and minute < 60 do
          {:ok, hour * 3600 + minute * 60}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_board_time(_), do: :error

  defp saved_leg_params(leg) do
    %{
      "route_id" => leg["route_id"] || leg[:route_id],
      "from_stop_id" => leg["from_stop_id"] || leg[:from_stop_id],
      "to_stop_id" => leg["to_stop_id"] || leg[:to_stop_id],
      "departs" => seconds_to_time(leg["departs"] || leg[:departs])
    }
  end

  defp seconds_to_time(seconds) when is_integer(seconds),
    do: Calendar.strftime(Time.new!(div(seconds, 3600), div(rem(seconds, 3600), 60), 0), "%H:%M")

  defp seconds_to_time(_), do: "07:40"

  defp journey_name(%{legs: legs}, stops) do
    first = Enum.find(stops, &(&1.stop_id == hd(legs).from_stop_id))
    last_leg = List.last(legs)
    last = Enum.find(stops, &(&1.stop_id == last_leg.to_stop_id))
    from = first && (first.stop_name || first.stop_id)
    to = last && (last.stop_name || last.stop_id)
    if from && to, do: "#{from} to #{to}", else: nil
  end

  defp journey_name(_, _), do: nil

  defp saved_journey_rows(journeys, rows) do
    Enum.map(journeys, fn journey ->
      current = Pricing.price_journey(rows, journey).total

      Map.merge(Map.from_struct(journey), %{
        current_amount: current,
        changed?: is_nil(current) or not Decimal.equal?(current, journey.expected_amount)
      })
    end)
  end

  defp format_counts(organization_id, version_id, rows) do
    projection = Projection.export_rows(organization_id, version_id)
    older = Map.get(projection.replaced, "fare_attributes.txt", rows.fare_attributes)
    zones = Map.get(projection.replaced, "areas.txt", [])

    [
      {"Older-format fares", length(older)},
      {"Fare products", length(rows.fare_products)},
      {"Leg rules", length(rows.fare_leg_rules)},
      {"Transfer rules", length(rows.fare_transfer_rules)},
      {"Zones",
       if(zones == [],
         do: MapSet.size(MapSet.new(Map.values(rows.stop_zones))),
         else: length(zones)
       )}
    ]
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  # Which of the Prices tab's four bodies this version is in, decided from the
  # workspace rather than from a state the tab keeps beside it:
  #
  #   * `:setup` — the version stores no fare row at all and is unmanaged, so
  #     nobody has priced it and the tab asks the first-use questions;
  #   * `:unmanaged` — the version's fares came from an import and are shown
  #     read-only until the conversion review makes them editable;
  #   * `:free` — the version's one fare charges nothing, so there is no price
  #     to type and the summary replaces the grid;
  #   * `:grid` — the fare table.
  #
  # A version with stored `fare_attributes` rows but no `fare_products` rows has
  # no workspace fares at all, which is why the stored rows decide `:setup`
  # rather than an empty fare list. The setup is also gated on the version being
  # unmanaged: `Conversion.setup/2` refuses a version that holds fare rows, and a
  # managed version has been through it.
  defp prices_mode(workspace) do
    cond do
      workspace.unmanaged != nil -> :unmanaged
      workspace.fares == [] and not workspace.managed? -> :setup
      free_only?(workspace) -> :free
      true -> :grid
    end
  end

  # The setup is open only while the version is in it, so a write that gives the
  # version its first fare closes it on the same load that redraws the tab.
  defp refresh_setup(socket) do
    cond do
      socket.assigns.prices_mode != :setup -> assign(socket, :setup, nil)
      is_nil(socket.assigns.setup) -> put_setup(socket, setup_draft(nil, %{}))
      true -> socket
    end
  end

  # The fares the older format's two descriptions disagree about: the stored
  # `fare_attributes` rows against the ones `Fares.Projection` derives from the
  # version's own fare rows. An import keeps the feed's own fare id case while
  # the projection writes its derived id in lower case, so the two sets are
  # joined by the same slug rule the projection names its rows with — otherwise
  # the two descriptions of one fare never meet.
  #
  # A version whose export already streams the stored rows has nothing to
  # disagree about and carries no banner, and an unmanaged version is never
  # projected at all.
  defp older_mismatches(%{managed?: false}, _organization_id, _version_id), do: []

  defp older_mismatches(%{older_format: "imported"}, _organization_id, _version_id), do: []

  defp older_mismatches(_workspace, organization_id, version_id) do
    stored =
      organization_id
      |> Interpreter.load_rows(version_id)
      |> Map.fetch!(:fare_attributes)
      |> Map.new(&{Stop.slugify(&1.fare_id), {&1.fare_id, &1.price}})

    derived =
      organization_id
      |> Projection.v1_rows(version_id)
      |> Map.fetch!("fare_attributes.txt")
      |> Map.new(&{Stop.slugify(&1.fare_id), &1.price})

    for {key, {fare_id, price}} <- Enum.sort(stored),
        amount = Map.get(derived, key),
        not is_nil(amount),
        not Decimal.equal?(amount, price) do
      %{fare_id: fare_id, stored: price, derived: amount}
    end
  end

  # -- Prices ------------------------------------------------------------------

  # The write scope, built from the assigns the page already authorizes rather
  # than from anything the request carried, so a write can only reach this
  # organization and this version (INV-5).
  defp fare_scope(socket) do
    organization_id = organization_id(socket)
    gtfs_version_id = version_id(socket)

    %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      audit: %AuditContext{
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id,
        station_stop_id: nil,
        actor_id: socket.assigns.current_user.id,
        actor_email: socket.assigns.current_user.email
      }
    }
  end

  # The fare-free state: one fare, sold at nothing, to every rider type the
  # version carries. There is nothing to type a price into, so the summary
  # replaces the grid.
  defp free_only?(nil), do: false

  defp free_only?(%{fares: [fare]}) do
    fare.kind == "single" and
      Enum.all?(Map.values(fare.prices), &free_amount?/1) and
      fare.media_prices
      |> Map.values()
      |> Enum.flat_map(&Map.values/1)
      |> Enum.all?(&free_amount?/1)
  end

  defp free_only?(_workspace), do: false

  defp free_amount?(nil), do: false
  defp free_amount?(amount), do: Decimal.equal?(amount, 0)

  defp organization_id(socket), do: socket.assigns.current_organization.id
  defp version_id(socket), do: socket.assigns.current_gtfs_version.id

  # One edit as the grid holds it: exactly what was typed beside what
  # `Fares.Money.parse/1` read, so an unreadable cell keeps its typo and blocks
  # the save rather than being silently read as a blank.
  defp price_edit(text) do
    case Money.parse(text) do
      {:ok, amount} -> %{text: text, amount: amount, invalid?: false}
      {:error, :invalid} -> %{text: text, amount: nil, invalid?: true}
    end
  end

  # Save is blocked while any cell is unreadable, or while a conflict the
  # operator has not resolved is open. The bar stays on screen either way, with
  # the reason on its lead line.
  defp blocked?(assigns) do
    Enum.any?(Map.values(assigns.price_edits), & &1.invalid?) or
      unresolved_conflict?(assigns.price_conflict)
  end

  defp unresolved_conflict?(nil), do: false

  defp unresolved_conflict?(conflict) do
    Enum.any?(conflict.cells, &is_nil(&1.choice))
  end

  defp blocking_reason(%{price_conflict: conflict}) when not is_nil(conflict) do
    case Enum.find(conflict.cells, &is_nil(&1.choice)) do
      nil -> nil
      cell -> "Choose which price to keep for #{cell.label}, then save."
    end
  end

  defp blocking_reason(assigns) do
    if Enum.any?(Map.values(assigns.price_edits), & &1.invalid?) do
      "Fix the highlighted price to save."
    end
  end

  defp save_prices(socket) do
    scope = fare_scope(socket)
    count = map_size(socket.assigns.price_edits)

    case Fares.save_prices(scope, price_cells(socket)) do
      {:ok, %{operation_id: operation_id, inverse: inverse}} ->
        {:noreply,
         socket
         |> load_workspace()
         |> assign(:price_edits, %{})
         |> assign(:price_conflict, nil)
         |> assign(:price_impacts, [])
         |> assign(
           :price_note,
           %{
             text:
               "#{price_count_text(count)} saved to #{socket.assigns.current_gtfs_version.name} service.",
             undo: [{operation_id, inverse}]
           }
         )}

      {:error, {:stale, cells}} ->
        {:noreply,
         socket
         |> assign(:price_conflict, conflict_from(socket, cells))
         |> assign(:price_note, nil)}

      {:error, :invalid_price} ->
        {:noreply,
         assign(socket, :price_note, %{text: "That price couldn’t be read. Nothing was saved."})}

      {:error, reason} ->
        {:noreply,
         assign(socket, :price_note, %{
           text: "Prices couldn’t be saved (#{write_reason(reason)})."
         })}
    end
  end

  # The edited cells, each carrying the amount the operator reviewed at the time
  # they typed. That reviewed amount is the fence `Fares.save_prices/2` checks,
  # and it is read from the workspace as it stood before this save — the amount
  # the grid showed, not the amount being typed.
  # What one cell holds in the workspace now: the amount, `nil` for a cell
  # stored as not sold, or `:none` for a cell the fare is not sold to at all —
  # which a price typed into it creates, and a blank one leaves absent.
  defp stored_amount(socket, key) do
    {product_id, rider_id, medium_id} = split_key(key)

    case fare_of_product(socket, product_id) do
      nil ->
        :none

      fare ->
        medium = blank_to_nil(medium_id)
        sold? = Enum.any?(fare.cells, &stored_row?(&1, product_id, rider_id, medium))

        if sold?, do: stored_row_amount(fare, rider_id, medium), else: :none
    end
  end

  defp price_cells(socket) do
    socket.assigns.price_edits
    |> Enum.flat_map(fn {key, edit} ->
      {product_id, rider_id, medium_id} = split_key(key)
      medium = blank_to_nil(medium_id)

      case kept_by(socket, key) do
        :theirs ->
          # The operator kept the other editor's price, so this cell is not
          # written at all rather than rewritten with what is already stored.
          []

        :keep ->
          [
            %{
              fare_product_id: product_id,
              rider_category_id: rider_id,
              fare_media_id: medium,
              reviewed: reviewed_amount(socket, key, product_id, rider_id, medium),
              amount: edit.amount
            }
          ]
      end
    end)
    |> Enum.sort_by(&{&1.fare_product_id, &1.rider_category_id, &1.fare_media_id || ""})
  end

  defp kept_by(%{assigns: %{price_conflict: conflict}}, key) when not is_nil(conflict) do
    case Enum.find(conflict.cells, &(&1.key == key)) do
      %{choice: :theirs} -> :theirs
      _other -> :keep
    end
  end

  defp kept_by(_socket, _key), do: :keep

  # What one cell held when the grid showed it: the fare's own row amount for the
  # base payment method, the sub-row's own amount otherwise, and nothing for a
  # rider type the fare is not sold to.
  #
  # A cell the conflict panel covers is reviewed against what is stored now
  # rather than against what the grid showed: the operator has just been told
  # somebody else changed it and has chosen which price to keep, so the fence
  # has to be the amount they chose over. Without that the second save would be
  # refused against the same amount the first was.
  defp reviewed_amount(socket, key, product_id, rider_id, medium_id) do
    case conflict_stored(socket, key) do
      {:ok, stored} ->
        stored

      :none ->
        reviewed_from_workspace(socket, product_id, rider_id, medium_id)
    end
  end

  defp conflict_stored(%{assigns: %{price_conflict: conflict}}, key) when not is_nil(conflict) do
    case Enum.find(conflict.cells, &(&1.key == key)) do
      nil -> :none
      %{choice: :mine, stored: stored} -> {:ok, stored}
      _other -> :none
    end
  end

  defp conflict_stored(_socket, _key), do: :none

  defp reviewed_from_workspace(socket, product_id, rider_id, medium_id) do
    fare = fare_of_product(socket, product_id)

    case fare do
      nil ->
        nil

      fare ->
        case Enum.find(fare.cells, &stored_row?(&1, product_id, rider_id, medium_id)) do
          nil ->
            nil

          _cell ->
            stored_row_amount(fare, rider_id, medium_id)
        end
    end
  end

  # The row the cell writes, matched on the three values that key it. A stored
  # row naming no payment method is the fare's base method, so it matches the
  # fare's own grid row the same way the grid matched it.
  defp stored_row?(cell, product_id, rider_id, medium_id) do
    cell.fare_product_id == product_id and cell.rider_category_id == rider_id and
      (cell.fare_media_id || :base) == (medium_id || :base)
  end

  defp fare_of_product(socket, product_id) do
    Enum.find(socket.assigns.workspace.fares, fn fare ->
      Enum.any?(fare.cells, &(&1.fare_product_id == product_id))
    end)
  end

  # The stored amount for one cell. The fare's base payment method prices its
  # own grid row and is carried in `prices`; a method that prices differently is
  # a sub-row and is carried in `media_prices`, which holds exactly those.
  defp stored_row_amount(fare, rider_id, medium_id) do
    case medium_id do
      nil ->
        Map.get(fare.prices, rider_id)

      medium ->
        if medium == fare.base_media_id,
          do: Map.get(fare.prices, rider_id),
          else: get_in(fare.media_prices, [medium, rider_id])
    end
  end

  defp split_key(key) do
    [product_id, rider_id, medium_id] = String.split(key, "|")
    {product_id, rider_id, medium_id}
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp price_count_text(1), do: "1 price"
  defp price_count_text(count), do: "#{count} prices"

  # The conflict the writer refused, named from the workspace and the change log:
  # who changed it and when is the newest entry another actor recorded, and each
  # cell says which price is the operator's and which is the stored one.
  defp conflict_from(socket, cells) do
    actor = other_actor(socket)

    %{
      actor: actor,
      at: other_actor_time(socket),
      cells:
        Enum.map(cells, fn cell ->
          key =
            Enum.join(
              [cell.fare_product_id, cell.rider_category_id, cell.fare_media_id || ""],
              "|"
            )

          %{
            key: key,
            label: cell_label(socket, cell),
            mine_text: edit_text(socket.assigns.price_edits[key]),
            theirs_text:
              Money.format(cell.stored, socket.assigns.workspace.currency) || "not sold",
            stored: cell.stored,
            choice: nil
          }
        end)
    }
  end

  # The newest change-log entry recorded by somebody other than the operator,
  # which is who moved a price underneath them.
  defp other_actor(socket) do
    actor_email =
      socket.assigns.workspace.history
      |> Enum.find_value(fn entry ->
        if entry.actor_email && entry.actor_email != socket.assigns.current_user.email do
          entry.actor_email
        end
      end)

    actor_email || "Another editor"
  end

  defp other_actor_time(socket) do
    socket.assigns.workspace.history
    |> Enum.find_value(fn entry ->
      if entry.actor_email && entry.actor_email != socket.assigns.current_user.email do
        entry.inserted_at
      end
    end)
  end

  defp cell_label(socket, cell) do
    fare =
      Enum.find(socket.assigns.workspace.fares, fn fare ->
        Enum.any?(fare.cells, &(&1.fare_product_id == cell.fare_product_id))
      end)

    rider =
      Enum.find(
        socket.assigns.workspace.riders,
        &(&1.rider_category_id == cell.rider_category_id)
      )

    medium =
      Enum.find(socket.assigns.workspace.media, &(&1.fare_media_id == cell.fare_media_id))

    [fare && fare.name, rider && rider.name, medium && "in the #{medium.name}"]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp edit_text(%{text: text}), do: text
  defp edit_text(_edit), do: "—"

  defp put_choice(cell, key, choice) when cell.key == key, do: %{cell | choice: choice}
  defp put_choice(cell, _key, _choice), do: cell

  # Which saved journeys the unsaved draft would move, priced on a draft of the
  # version's own rows with the operator's amounts applied. A journey whose total
  # does not change is not in the answer, and an unreadable price stops the
  # calculation entirely rather than reporting a movement that may not happen.
  defp journey_impacts(socket, edits) do
    if Enum.any?(Map.values(edits), & &1.invalid?) do
      []
    else
      organization_id = organization_id(socket)
      gtfs_version_id = version_id(socket)
      rows = Interpreter.load_rows(organization_id, gtfs_version_id)
      draft = draft_rows(rows, edits)
      journeys = Fares.saved_journeys(organization_id, gtfs_version_id)

      for journey <- journeys,
          changed = changed_total(draft, journey),
          do: changed
    end
  end

  defp changed_total(rows, journey) do
    total = Pricing.price_journey(rows, journey).total

    if is_nil(total) or Decimal.equal?(total, journey.expected_amount) do
      nil
    else
      %{name: journey.name, expected: journey.expected_amount, now: total}
    end
  end

  # The version's fare rows with the operator's amounts substituted, which is
  # what `Fares.Pricing` reads. A cell the grid holds no row for is added, so a
  # price that is being newly sold is priced as the draft would store it.
  defp draft_rows(rows, edits) do
    products =
      Enum.reduce(edits, rows.fare_products, fn {key, edit}, products ->
        {product_id, rider_id, medium_id} = split_key(key)
        put_draft_amount(products, product_id, rider_id, blank_to_nil(medium_id), edit.amount)
      end)

    %{rows | fare_products: products}
  end

  defp put_draft_amount(products, product_id, rider_id, medium_id, amount) do
    case Enum.find_index(products, &draft_row?(&1, product_id, rider_id, medium_id)) do
      nil ->
        products ++ [draft_row(product_id, rider_id, medium_id, amount)]

      index ->
        List.update_at(products, index, &%{&1 | amount: amount})
    end
  end

  defp draft_row?(product, product_id, rider_id, medium_id) do
    product.fare_product_id == product_id and product.rider_category_id == rider_id and
      product.fare_media_id == medium_id
  end

  defp draft_row(product_id, rider_id, medium_id, amount) do
    %GtfsPlanner.Gtfs.FareProduct{
      fare_product_id: product_id,
      rider_category_id: rider_id,
      fare_media_id: medium_id,
      amount: amount
    }
  end

  defp published?(version), do: version.publication_status == "published"

  # The version's fare problems, which the Checks tab's mark reports: everything
  # that needs repair or review, so a setup problem stays visible from every
  # other tab. A version whose fares have not loaded claims no count at all.
  defp checks_count(%{repair: repair, review: review}), do: length(repair) + length(review)

  defp checks_tone(%{repair: [_ | _]}), do: :error
  defp checks_tone(%{review: [_ | _]}), do: :warning
  defp checks_tone(%{}), do: :ok

  defp settings_path(version_id), do: "/gtfs/#{version_id}/settings"

  defp fares_path(gtfs_version_id, :prices), do: "/gtfs/#{gtfs_version_id}/settings/fares"

  defp fares_path(gtfs_version_id, :transfers),
    do: "/gtfs/#{gtfs_version_id}/settings/fares/transfers"

  defp fares_path(gtfs_version_id, :checks), do: "/gtfs/#{gtfs_version_id}/settings/fares/checks"
  defp fares_path(gtfs_version_id, _where), do: "/gtfs/#{gtfs_version_id}/settings/fares/where"
end
