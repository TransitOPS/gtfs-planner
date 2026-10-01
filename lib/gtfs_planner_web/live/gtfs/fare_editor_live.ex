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
      fare_cards: 1,
      fare_delete_dialog: 1,
      fare_drawer: 1,
      fare_note: 1,
      fare_table: 1,
      fares_conflict: 1,
      header_primary: 1,
      load_error: 1,
      loading: 1,
      media_delete_dialog: 1,
      media_drawer: 1,
      price_change_dialog: 1,
      price_save_bar: 1,
      rider_delete_dialog: 1,
      rider_drawer: 1
    ]

  import GtfsPlannerWeb.PlannerComponents, only: [back_link: 1]

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.Fares.Interpreter
  alias GtfsPlanner.Gtfs.Fares.Money
  alias GtfsPlanner.Gtfs.Fares.Pricing
  alias GtfsPlanner.Gtfs.Fares.Projection
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
     |> assign(:checks, nil)
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
      {:noreply, load_workspace(socket)}
    else
      # The static render ships the skeleton; the connected mount owns the load.
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("reload", _params, socket), do: {:noreply, load_workspace(socket)}

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
             |> assign(:price_note, %{text: "That rider type couldn’t be deleted (#{reason})."})}
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
               text: "That payment method couldn’t be deleted (#{reason})."
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
        assign(socket, :price_change, %{change | error: "Prices couldn't be changed (#{reason})."})
    end
  end

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
    socket = assign(socket, :drawer_pending?, true)
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
         |> assign(:price_note, %{text: "#{name} couldn’t be saved (#{reason})."})}
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
           delete_fare_calls(fare, replacement),
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
  defp delete_fare_calls(fare, replacement) do
    for product_id <- fare.product_ids do
      cells = Enum.filter(fare.cells, &(&1.fare_product_id == product_id))

      {product_id, replacement_product(fare, replacement, product_id),
       %{
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
      nil -> new_rider_draft(socket)
      rider -> edit_rider_draft(rider)
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
    socket = assign(socket, :drawer_pending?, true)
    name = draft.name
    version_name = socket.assigns.current_gtfs_version.name

    params = %{
      name: name,
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
         |> assign(:price_note, %{text: "#{name} couldn’t be saved (#{reason})."})}
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
    socket = assign(socket, :drawer_pending?, true)
    name = draft.name
    version_name = socket.assigns.current_gtfs_version.name

    params = %{
      name: name,
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
         |> assign(:price_note, %{text: "#{name} couldn’t be saved (#{reason})."})}
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
    Enum.reduce_while(calls, {:ok, []}, fn args, {:ok, undos} ->
      case apply(writer, [scope | Tuple.to_list(args)]) do
        {:ok, %{operation_id: operation_id, inverse: inverse}} ->
          {:cont, {:ok, undos ++ [{operation_id, inverse}]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
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
      <div id="fare-editor-page" class="ds-page">
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
              transfers?={@workspace != nil and @workspace.transfers != []}
              dirty?={@price_edits != %{} and @load_state == :ready}
            />
          </:actions>
        </.header>

        <.fares_tabs
          gtfs_version_id={@current_gtfs_version.id}
          active_tab={@live_action}
          checks_count={if @load_state == :ready, do: checks_count(@checks), else: nil}
          checks_tone={if @load_state == :ready, do: checks_tone(@checks), else: nil}
        />

        <div class="mt-4 grid grid-cols-1 gap-4">
          <.loading :if={@load_state == :loading} />
          <.load_error :if={@load_state == :unavailable} />
          <%!-- The tab's own body arrives with the tab that owns it; the shell
          owns the frame above and the load states beside it. --%>
          <div :if={@load_state == :ready} id="fare-editor-panel">
            <div :if={@live_action == :prices} id="fare-prices-panel" class="grid gap-4">
              <.fare_note note={@price_note} />
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
        socket
        |> assign(:workspace, workspace)
        |> assign(:checks, Fares.Checks.run(organization_id, gtfs_version_id))
        |> assign(:load_state, :ready)

      {:error, :unavailable} ->
        assign(socket, :load_state, :unavailable)
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
        {:noreply, assign(socket, :price_note, %{text: "Prices couldn’t be saved (#{reason})."})}
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
