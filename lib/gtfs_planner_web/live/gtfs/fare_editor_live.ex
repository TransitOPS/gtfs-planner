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
      fare_note: 1,
      fare_table: 1,
      fares_conflict: 1,
      header_primary: 1,
      load_error: 1,
      loading: 1,
      price_save_bar: 1
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
     |> assign(:lens?, false)}
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

  @impl true
  def handle_event("undo_prices", _params, socket) do
    case socket.assigns.price_note do
      %{undo: {operation_id, inverse}} ->
        scope = fare_scope(socket)

        case Fares.undo(scope, operation_id, inverse) do
          {:ok, _result} ->
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
             undo: {operation_id, inverse}
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
