defmodule GtfsPlannerWeb.Gtfs.RosterOperatorsComponents do
  @moduledoc """
  The operators drawer: the organization's list of operators, and the form that
  adds one or edits one.

  Operators are the one roster input the organization owns across every version,
  so this drawer is not version-scoped: its lede says so, and the Line column is
  the *this version's* line only, because a line is a fact of one version's week
  while an operator is a fact of the organization.

  ## The order is the organization's, not this page's

  `Operations.list_operators/1` already answers the one order AC-4 asks for —
  seniority ascending with blanks last, then employee ID, then unnumbered
  operators by name. `RostersLive` reads that list once when the drawer opens and
  hands the rows here in that order, so the table and the pick select cannot
  disagree about who is most senior (domain rule 11).

  ## The form validates on blur, and the blur is what the page believes

  Each field carries `phx-blur` and `phx-debounce="blur"`, and the page keeps the
  set of fields the editor has left at least once. An error is drawn for a field
  only after that field has been blurred, or after a submit, so a reader who is
  halfway through an employee ID is not told the employee ID is wrong while
  typing it. The rules themselves are `GtfsPlanner.Operations.Operator`'s
  changeset, run with the `:validate` action: this module draws the result and
  invents none of it.

  ## Only these three values are stored

  The form says so in its own words, because the alternative is a reader
  wondering what else the app keeps about their staff (domain rules 11 and 12,
  and the "Operator data stays minimal" criterion). An employee ID another
  operator already holds is refused by the writer with the holder's name, and the
  refusal is the writer's own sentence under the field — the page never computes
  a second answer to the same question (domain rule 13).
  """

  use GtfsPlannerWeb, :html

  import GtfsPlannerWeb.PlannerComponents,
    only: [drawer_footer: 1, drawer_scroll: 1, form_error_summary: 1]

  @doc """
  The operators drawer: the organization's operators in seniority order.

  `lines` maps an operator id to the line number that operator holds *in this
  version*, because the table's Line column is about this version's week and an
  operator belongs to no version at all. An operator nobody here holds reads
  "No line" rather than an empty cell, so the column says the same thing in
  every row.

  With no operators at all the empty state is drawn instead of the table: a table
  with a header and nothing under it is a table with nothing to say, and the
  sentence below says what belongs here instead.

  The footer's one primary is "Add operator". Editing is reached by selecting a
  name in the table, which is the row's own identifier — the same choice the
  prototype and the pick row make.
  """
  attr :open, :boolean, default: true
  attr :operators, :list, required: true
  attr :lines, :map, required: true, doc: "operator id to the line number held in this version"
  attr :on_close, :string, default: "close_operators"

  def operators_drawer(assigns) do
    assigns = assign(assigns, :held_count, map_size(assigns.lines))

    ~H"""
    <.drawer
      id="rosters-operators-drawer"
      chrome="planner"
      open={@open}
      on_close={@on_close}
      title="Operators"
      class="max-w-[720px]"
    >
      <:lede>
        <span id="rosters-operators-lede">
          {length(@operators)} {if length(@operators) == 1, do: "operator", else: "operators"} · {@held_count} hold a line in this version
        </span>
      </:lede>

      <.drawer_scroll>
        <p id="rosters-operators-order" class="text-[13px] text-muted">
          Most senior first; operators without a seniority number follow by name. Select a name to edit it.
        </p>

        <p :if={@operators == []} id="rosters-operators-empty" class="py-10 text-center">
          <span class="block font-display text-[20px] font-semibold text-strong">
            No operators yet
          </span>
          <span class="mx-auto mt-2 block max-w-[400px] text-sm text-muted">
            Add operators one at a time. Each operator needs an employee ID and a display name.
          </span>
        </p>

        <div
          :if={@operators != []}
          class="mt-3 overflow-x-auto rounded-control border border-subtle"
        >
          <table id="rosters-operators-table" class="w-full border-separate border-spacing-0 text-sm">
            <caption class="sr-only">Operators</caption>
            <thead>
              <tr class="border-b border-subtle bg-canvas text-[13px] text-muted">
                <th
                  scope="col"
                  title="1 is most senior"
                  class="px-3 py-2 text-right font-semibold text-strong"
                >
                  Seniority
                </th>
                <th scope="col" class="px-3 py-2 font-semibold text-strong">Employee ID</th>
                <th scope="col" class="px-3 py-2 font-semibold text-strong">Name</th>
                <th scope="col" class="px-3 py-2 font-semibold text-strong">Line</th>
              </tr>
            </thead>
            <tbody id="rosters-operators-rows">
              <tr
                :for={operator <- @operators}
                id={"rosters-operator-#{operator.id}"}
                class="border-b border-subtle last:border-b-0 hover:bg-canvas"
              >
                <td class="tabular px-3 py-1 text-right align-middle">
                  <span :if={operator.seniority_number}>{operator.seniority_number}</span>
                  <span :if={is_nil(operator.seniority_number)} class="text-muted">—</span>
                </td>
                <td class="px-3 py-1 align-middle font-mono text-[13px]">{operator.employee_id}</td>
                <td class="px-3 py-1 align-middle">
                  <button
                    type="button"
                    id={"rosters-edit-operator-#{operator.id}"}
                    phx-click="edit_operator"
                    phx-value-id={operator.id}
                    aria-label={"Edit #{operator.display_name}"}
                    class="-ml-1 inline-flex min-h-11 items-center rounded-control px-1 text-sm font-[650] text-action underline underline-offset-4 hover:text-action-hover focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
                  >
                    {operator.display_name}
                  </button>
                </td>
                <td class="px-3 py-1 align-middle">
                  <span :if={Map.get(@lines, operator.id)}>
                    Line {Map.get(@lines, operator.id)}
                  </span>
                  <span :if={is_nil(Map.get(@lines, operator.id))} class="text-muted">No line</span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </.drawer_scroll>

      <.drawer_footer>
        <.button
          id="rosters-drawer-add-operator"
          type="button"
          class="min-h-11"
          phx-click="new_operator"
        >
          Add operator
        </.button>
      </.drawer_footer>
    </.drawer>
    """
  end

  @doc """
  The add/edit form for one operator, in the same drawer.

  The three fields are the three stored values and nothing else; the sentence
  under them says so, because a form that shows three fields already answers the
  question and saying it in words costs one line.

  Errors are drawn under the field they name, and the summary at the top of the
  scrolling body appears only after a submit was refused — live validation is not
  a rejection and must not produce a panel that scolds a reader who is still
  typing (see `PlannerComponents.form_error_summary/1`).

  An operator who holds a line in this version is told so, and where the pick
  lives: the pick is a fact about the bid recorded in the grid, and this form is
  not where it changes.

  The footer's one primary is the save, and its label is what will have happened:
  "Add operator" for a new one, "Save operator" for an edit.
  """
  attr :open, :boolean, default: true
  attr :form, :any, required: true
  attr :editing, :boolean, default: false
  attr :name, :string, default: nil, doc: "the operator being edited; nil when adding"
  attr :line_number, :integer, default: nil
  attr :failures, :list, default: []
  attr :on_close, :string, default: "cancel_operator"

  def operator_form(assigns) do
    ~H"""
    <.drawer
      id="rosters-operators-drawer"
      chrome="planner"
      open={@open}
      on_close={@on_close}
      title={if @editing, do: "Edit #{@name}", else: "Add operator"}
      class="max-w-[640px]"
    >
      <:lede>
        <span id="rosters-operator-form-lede">Operators · shared by every version</span>
      </:lede>

      <%!-- The scoped `FormErrorFocus` hook the save pushes to lives inside this
      drawer, not on the page: the hook only focuses a target it already owns, and
      a form in a drawer is not inside the page region. --%>
      <div
        id="rosters-operator-form-content"
        phx-hook="FormErrorFocus"
        class="flex min-h-0 flex-1 flex-col"
      >
        <.form
          for={@form}
          id="rosters-operator-form"
          novalidate
          phx-change="validate_operator"
          phx-submit="save_operator"
          class="flex min-h-0 flex-1 flex-col"
        >
          <.drawer_scroll>
            <.form_error_summary
              id="rosters-operator-form-errors"
              title="Fix these to save the operator"
              failures={@failures}
              class=""
            />

            <.input
              field={@form[:employee_id]}
              type="text"
              label="Employee ID"
              help="The ID your payroll or scheduling system uses. The export writes it as employee_id."
              autocomplete="off"
              class="input input-lg w-56 font-mono"
              phx-debounce="blur"
              phx-blur="validate_operator"
            />

            <.input
              field={@form[:display_name]}
              type="text"
              label="Display name"
              autocomplete="off"
              class="input input-lg"
              phx-debounce="blur"
              phx-blur="validate_operator"
            />

            <.input
              field={@form[:seniority_number]}
              type="text"
              label="Seniority number (optional)"
              help="1 is most senior. Used only to order this list and the pick."
              autocomplete="off"
              inputmode="numeric"
              class="input input-lg w-28"
              phx-debounce="blur"
              phx-blur="validate_operator"
            />

            <p class="text-[13px] text-muted">
              Only these three values are stored. No contact details, pay or status.
            </p>

            <p :if={@line_number} id="rosters-operator-holds-line" class="text-sm text-default">
              {@name} holds <strong class="font-semibold text-strong">line {@line_number}</strong>.
              Change the pick in the roster grid.
            </p>
          </.drawer_scroll>

          <.drawer_footer>
            <.button
              id="rosters-operator-cancel"
              type="button"
              variant="secondary"
              class="min-h-11"
              phx-click={@on_close}
            >
              Cancel
            </.button>
            <.button
              id="rosters-operator-save"
              type="submit"
              class="min-h-11"
              phx-disable-with="Saving…"
            >
              {if @editing, do: "Save operator", else: "Add operator"}
            </.button>
          </.drawer_footer>
        </.form>
      </div>
    </.drawer>
    """
  end
end
