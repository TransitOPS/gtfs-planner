# Pathways Studio

## High-Level Architecture Document

**Elixir/Phoenix 1.8+ Implementation**  
**GTFS Planner Repository**  
**Version 2.0**

---

## Executive Summary

Pathways Studio is a specialized GTFS management tool focused on creating and managing transit station pathways, levels, and accessibility information. This document outlines the architecture for building Pathways Studio as an Elixir/Phoenix 1.8+ application within the GTFS Planner repository, following current best practices and idioms.

Key architectural decisions include leveraging Phoenix 1.8 Scopes for secure multi-tenant data access, Ecto's `prepare_query` callback for enforced query scoping, composite foreign keys for data integrity, and LiveView Streams for optimized real-time interfaces.

---

## Project Overview

### Goals and Objectives

- Rebuild Pathways Studio as a modern Elixir/Phoenix 1.8+ application
- Migrate authentication and core functionality from Warbler (see [Warbler Authentication Implementation](warbler-authentication-implementation.md) for detailed implementation specification)
- Implement enforced multi-tenant architecture using Phoenix Scopes
- Create an intuitive, desktop-first interface using LiveView
- Support GTFS import/export with versioning capabilities
- Share codebase with GTFS Planner while maintaining separate access controls

### Scope Definition

The project resides in the GTFS Planner repository with access controls determining user experience:

- **Pathways Studio Only:** Users see specialized pathway/level management tools
- **GTFS Planner Only:** Users see broader GTFS management capabilities
- **Both:** Users have access to the full feature set

---

## System Architecture

### Technology Stack

| Component          | Technology                                   |
| ------------------ | -------------------------------------------- |
| Language           | Elixir 1.15+ / Erlang/OTP 25+                |
| Framework          | Phoenix 1.8+ with LiveView 1.0+              |
| Database           | PostgreSQL 15+ with Ecto 3.11+               |
| UI Framework       | Phoenix LiveView with Daisy UI               |
| Interactive Canvas | React (TBD) via LiveView hooks for floorplan |
| CSS                | Tailwind CSS (Phoenix 1.8 default)           |
| Real-time          | Phoenix PubSub with scoped topics            |

### Application Structure

The application follows Phoenix 1.8 conventions with the Context pattern and Scopes:

```
gtfs_planner/
├── lib/
│   ├── gtfs_planner/
│   │   ├── accounts/
│   │   │   ├── scope.ex            # Phoenix 1.8 Scope struct
│   │   │   ├── user.ex
│   │   │   └── organization.ex
│   │   ├── gtfs/                   # GTFS Context
│   │   │   ├── stop.ex
│   │   │   ├── level.ex
│   │   │   └── pathway.ex
│   │   ├── versions/               # Versions Context
│   │   │   └── gtfs_version.ex
│   │   ├── versions.ex             # Versions Context module
│   │   ├── import/                 # Import Context
│   │   ├── export/                 # Export Context
│   │   ├── validation/             # Validation Context
│   │   └── repo.ex                 # With prepare_query/3
│   └── gtfs_planner_web/
│       ├── live/
│       │   ├── stop_live/
│       │   │   ├── index.ex
│       │   │   ├── show.ex
│       │   │   └── form_component.ex
│       │   └── floorplan_live/
│       ├── components/
│       │   ├── core_components.ex
│       │   └── slide_panel.ex
│       └── router.ex
├── test/
│   ├── support/
│   │   ├── fixtures/
│   │   └── conn_case.ex
│   └── gtfs_planner/
└── config/
```

---

## Phoenix 1.8 Scopes

Phoenix 1.8 introduces Scopes as a first-class pattern for secure data access. OWASP lists "Broken access control" as the #1 security risk. Scopes ensure all database operations are properly scoped to the current organization and GTFS version.

### Scope Definition

The application defines a custom scope that includes organization and active GTFS version:

```elixir
# lib/gtfs_planner/accounts/scope.ex
defmodule GtfsPlanner.Accounts.Scope do
  defstruct [:user, :organization, :gtfs_version]

  def new(user, organization, gtfs_version) do
    %__MODULE__{
      user: user,
      organization: organization,
      gtfs_version: gtfs_version
    }
  end

  def org_id(%__MODULE__{organization: org}), do: org.id
  def version_id(%__MODULE__{gtfs_version: v}), do: v.id
end
```

### Scope Configuration

Configure scopes in `config.exs` for generator integration:

```elixir
# config/config.exs
config :gtfs_planner, :scopes,
  organization: [
    default: true,
    module: GtfsPlanner.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:organization, :id],
    schema_key: :org_id,
    schema_type: :binary_id,
    route_prefix: "/org/:org_id",
    test_data_fixture: GtfsPlanner.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]
```

### Scope in LiveView Lifecycle

Use `on_mount` hooks to establish scope before any LiveView renders:

```elixir
# lib/gtfs_planner_web/live/auth_hooks.ex
defmodule GtfsPlannerWeb.AuthHooks do
  import Phoenix.LiveView
  import Phoenix.Component

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.Scope

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = assign_current_scope(socket, session)

    if socket.assigns.current_scope do
      {:cont, socket}
    else
      {:halt, redirect(socket, to: "/login")}
    end
  end

  defp assign_current_scope(socket, session) do
    case Accounts.get_user_by_session_token(session["user_token"]) do
      nil -> assign(socket, :current_scope, nil)
      user ->
        org = Accounts.get_user_organization(user)
        [version | _] = GtfsPlanner.Versions.list_gtfs_versions(org.id)
        scope = Scope.new(user, org, version)
        assign(socket, :current_scope, scope)
    end
  end
end
```

---

## Database Design

### Enforced Multi-Tenant Repository

Following Ecto best practices, the repository uses `prepare_query/3` to enforce `org_id` scoping on all read operations. This prevents accidental data leakage by requiring explicit scoping or opt-out:

```elixir
# lib/gtfs_planner/repo.ex
defmodule GtfsPlanner.Repo do
  use Ecto.Repo, otp_app: :gtfs_planner
  require Ecto.Query

  @impl true
  def prepare_query(_operation, query, opts) do
    cond do
      opts[:skip_org_id] || opts[:schema_migration] ->
        {query, opts}

      scope = opts[:scope] ->
        org_id = scope.organization.id
        version_id = scope.gtfs_version.id
        query = Ecto.Query.where(query,
          org_id: ^org_id,
          gtfs_version_id: ^version_id
        )
        {query, opts}

      org_id = opts[:org_id] ->
        {Ecto.Query.where(query, org_id: ^org_id), opts}

      true ->
        raise "expected :scope, :org_id, or :skip_org_id option"
    end
  end
end
```

**Usage:** All repository operations now require explicit scoping:

```elixir
# In context functions - pass scope from LiveView
Repo.all(Stop, scope: scope)
Repo.get!(Stop, id, scope: scope)

# For admin/system operations - explicit opt-out
Repo.all(Stop, skip_org_id: true)
```

### Composite Foreign Keys

Use composite foreign keys to ensure referential integrity at the database level. This guarantees that child records always reference parents within the same organization:

```elixir
# priv/repo/migrations/xxx_create_stops.exs
defmodule GtfsPlanner.Repo.Migrations.CreateStops do
  use Ecto.Migration

  def change do
    create table(:stops, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :org_id, references(:organizations, type: :binary_id),
          null: false
      add :gtfs_version_id, :binary_id, null: false
      add :stop_id, :string, null: false
      add :stop_name, :string
      add :location_type, :integer, default: 0
      # ... other fields
      timestamps()
    end

    # Unique constraint for GTFS stop_id within org+version
    create unique_index(:stops, [:org_id, :gtfs_version_id, :stop_id])

    # Composite foreign key for gtfs_version
    create index(:gtfs_versions, [:org_id, :id], unique: true)

    alter table(:stops) do
      modify :gtfs_version_id,
        references(:gtfs_versions,
          column: :id,
          with: [org_id: :org_id],
          match: :full
        )
    end
  end
end
```

### Core Schema Definitions

Schemas use Ecto best practices with typed structs and comprehensive changesets:

#### Stop Schema

```elixir
# lib/gtfs_planner/gtfs/stop.ex
defmodule GtfsPlanner.Gtfs.Stop do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "stops" do
    field :stop_id, :string
    field :stop_name, :string
    field :stop_lat, :decimal
    field :stop_lon, :decimal
    field :location_type, :integer, default: 0
    field :wheelchair_boarding, :integer

    belongs_to :organization, GtfsPlanner.Accounts.Organization,
      foreign_key: :org_id
    belongs_to :gtfs_version, GtfsPlanner.Versions.GtfsVersion
    belongs_to :parent_station, __MODULE__,
      foreign_key: :parent_station_id
    belongs_to :level, GtfsPlanner.Gtfs.Level

    has_many :child_stops, __MODULE__,
      foreign_key: :parent_station_id

    timestamps()
  end

  @required ~w(stop_id stop_name org_id gtfs_version_id)a
  @optional ~w(stop_lat stop_lon location_type wheelchair_boarding
               parent_station_id level_id)a

  def changeset(stop, attrs) do
    stop
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:location_type, 0..4)
    |> validate_inclusion(:wheelchair_boarding, 0..2)
    |> unique_constraint([:org_id, :gtfs_version_id, :stop_id])
    |> foreign_key_constraint(:org_id)
    |> foreign_key_constraint(:gtfs_version_id)
  end
end
```

#### Pathway Schema

```elixir
# lib/gtfs_planner/gtfs/pathway.ex
defmodule GtfsPlanner.Gtfs.Pathway do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @pathway_modes %{
    walkway: 1,
    stairs: 2,
    moving_sidewalk: 3,
    escalator: 4,
    elevator: 5,
    fare_gate: 6,
    exit_gate: 7
  }

  schema "pathways" do
    field :pathway_id, :string
    field :pathway_mode, :integer
    field :is_bidirectional, :boolean, default: true
    field :traversal_time, :integer
    field :length, :decimal
    field :stair_count, :integer

    belongs_to :organization, GtfsPlanner.Accounts.Organization,
      foreign_key: :org_id
    belongs_to :gtfs_version, GtfsPlanner.Versions.GtfsVersion
    belongs_to :from_stop, GtfsPlanner.Gtfs.Stop
    belongs_to :to_stop, GtfsPlanner.Gtfs.Stop

    timestamps()
  end

  def pathway_modes, do: @pathway_modes
end
```

---

## LiveView Architecture

### LiveView Best Practices

The application follows modern LiveView patterns for optimal performance and maintainability:

1. **Use `handle_params/3` over `mount/3`** for URL-driven state
2. **Leverage Streams** for large collections (stops list)
3. **Use `on_mount` hooks** for authentication and scope setup
4. **Compose with function components** for reusable UI
5. **Keep LiveViews thin** - delegate to contexts

### Stops LiveView Example

```elixir
# lib/gtfs_planner_web/live/stop_live/index.ex
defmodule GtfsPlannerWeb.StopLive.Index do
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Gtfs

  @impl true
  def mount(_params, _session, socket) do
    # Minimal mount - just return socket
    # Scope is set by on_mount hook
    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> apply_action(socket.assigns.live_action, params)
     |> load_stops()}
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, :page_title, "Stops")
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    scope = socket.assigns.current_scope
    stop = Gtfs.get_stop!(scope, id)
    assign(socket, page_title: "Edit Stop", stop: stop)
  end

  defp load_stops(socket) do
    scope = socket.assigns.current_scope
    # Use streams for efficient list rendering
    stream(socket, :stops, Gtfs.list_parent_stations(scope))
  end

  @impl true
  def handle_info({:stop_updated, stop}, socket) do
    {:noreply, stream_insert(socket, :stops, stop)}
  end

  def handle_info({:stop_deleted, stop}, socket) do
    {:noreply, stream_delete(socket, :stops, stop)}
  end
end
```

### Router Configuration

```elixir
# lib/gtfs_planner_web/router.ex
defmodule GtfsPlannerWeb.Router do
  use GtfsPlannerWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {GtfsPlannerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_user
  end

  # Authenticated routes with scope
  live_session :authenticated,
    on_mount: [
      {GtfsPlannerWeb.AuthHooks, :require_authenticated},
      {GtfsPlannerWeb.AuthHooks, :ensure_gtfs_version}
    ] do

    scope "/", GtfsPlannerWeb do
      pipe_through [:browser, :require_authenticated_user]

      live "/stops", StopLive.Index, :index
      live "/stops/new", StopLive.Index, :new
      live "/stops/:id", StopLive.Show, :show
      live "/stops/:id/edit", StopLive.Show, :edit
      live "/stops/:id/levels/:level_id", FloorplanLive.Show, :show

      live "/import", ImportLive.Index, :index
      live "/export", ExportLive.Index, :index
      live "/validation", ValidationLive.Index, :index
    end
  end
end
```

---

## PubSub Architecture

Phoenix PubSub enables real-time updates across connected clients. Topics are scoped to organization and version to ensure data isolation:

### Scoped Topic Helpers

```elixir
# lib/gtfs_planner/gtfs.ex (in context module)
defmodule GtfsPlanner.Gtfs do
  @pubsub GtfsPlanner.PubSub

  # Topic scoped to org + version
  defp topic(%Scope{} = scope) do
    "gtfs:#{scope.organization.id}:#{scope.gtfs_version.id}"
  end

  def subscribe(%Scope{} = scope) do
    Phoenix.PubSub.subscribe(@pubsub, topic(scope))
  end

  def broadcast(%Scope{} = scope, event, payload) do
    Phoenix.PubSub.broadcast(@pubsub, topic(scope), {event, payload})
  end

  # Context function with broadcast
  def create_stop(%Scope{} = scope, attrs) do
    attrs = Map.merge(attrs, %{
      org_id: scope.organization.id,
      gtfs_version_id: scope.gtfs_version.id
    })

    case %Stop{} |> Stop.changeset(attrs) |> Repo.insert() do
      {:ok, stop} ->
        broadcast(scope, :stop_created, stop)
        {:ok, stop}

      {:error, changeset} ->
        {:error, changeset}
    end
  end
end
```

### LiveView Subscription

```elixir
# In LiveView mount or handle_params
def mount(_params, _session, socket) do
  if connected?(socket) do
    Gtfs.subscribe(socket.assigns.current_scope)
  end

  {:ok, socket}
end

# Handle broadcasts
@impl true
def handle_info({:stop_created, stop}, socket) do
  {:noreply, stream_insert(socket, :stops, stop, at: 0)}
end

def handle_info({:stop_updated, stop}, socket) do
  {:noreply, stream_insert(socket, :stops, stop)}
end

def handle_info({:stop_deleted, stop}, socket) do
  {:noreply, stream_delete(socket, :stops, stop)}
end
```

---

## Phoenix Contexts

Contexts encapsulate business logic with scope as the first parameter for all data operations:

### GTFS Context

```elixir
# lib/gtfs_planner/gtfs.ex
defmodule GtfsPlanner.Gtfs do
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Accounts.Scope
  alias GtfsPlanner.Gtfs.{Stop, Level, Pathway}

  # All functions take scope as first argument

  def list_parent_stations(%Scope{} = scope) do
    Stop
    |> where([s], s.location_type == 1)
    |> order_by([s], s.stop_name)
    |> Repo.all(scope: scope)
  end

  def get_stop!(%Scope{} = scope, id) do
    Repo.get!(Stop, id, scope: scope)
  end

  def create_stop(%Scope{} = scope, attrs) do
    %Stop{}
    |> Stop.changeset(scope_attrs(scope, attrs))
    |> Repo.insert()
    |> broadcast_change(scope, :stop_created)
  end

  def update_stop(%Scope{} = scope, %Stop{} = stop, attrs) do
    stop
    |> Stop.changeset(attrs)
    |> Repo.update()
    |> broadcast_change(scope, :stop_updated)
  end

  def delete_stop(%Scope{} = scope, %Stop{} = stop) do
    Repo.delete(stop)
    |> broadcast_change(scope, :stop_deleted)
  end

  # Helper to inject scope IDs into attrs
  defp scope_attrs(%Scope{} = scope, attrs) do
    Map.merge(attrs, %{
      org_id: Scope.org_id(scope),
      gtfs_version_id: Scope.version_id(scope)
    })
  end

  defp broadcast_change({:ok, record} = result, scope, event) do
    broadcast(scope, event, record)
    result
  end
  defp broadcast_change(error, _scope, _event), do: error
end
```

### Versions Context

The Versions context manages GTFS versions scoped to organizations. A default version is automatically created when an organization is created.

```elixir
# lib/gtfs_planner/versions.ex
defmodule GtfsPlanner.Versions do
  @moduledoc """
  The Versions context for managing GTFS versions scoped to organizations.
  """

  import Ecto.Query, warn: false
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  @doc "Creates a GTFS version for an organization."
  def create_gtfs_version(organization_id, attrs) do
    %GtfsVersion{organization_id: organization_id}
    |> GtfsVersion.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Creates a default 'First Version' GTFS version for an organization."
  def create_default_version(organization_id) do
    create_gtfs_version(organization_id, %{name: "First Version"})
  end

  @doc "Returns the list of GTFS versions for an organization."
  def list_gtfs_versions(organization_id) do
    from(v in GtfsVersion,
      where: v.organization_id == ^organization_id,
      order_by: [asc: v.inserted_at]
    )
    |> Repo.all()
  end

  @doc "Gets a single GTFS version. Raises if not found."
  def get_gtfs_version!(id), do: Repo.get!(GtfsVersion, id)
end
```

The `GtfsVersion` schema is minimal, storing only the essential fields:

```elixir
# lib/gtfs_planner/versions/gtfs_version.ex
defmodule GtfsPlanner.Versions.GtfsVersion do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "gtfs_versions" do
    field :organization_id, Ecto.UUID
    field :name, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(gtfs_version, attrs) do
    gtfs_version
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
  end
end
```

**Note:** Version branching and status tracking are planned future enhancements. The current implementation focuses on basic version management with automatic creation during organization setup.

### Import Context

```elixir
# lib/gtfs_planner/import.ex
defmodule GtfsPlanner.Import do
  alias GtfsPlanner.Repo
  alias Ecto.Multi

  @doc "Import GTFS zip into new version"
  def import_gtfs(%Scope{} = scope, zip_path, version_name) do
    Multi.new()
    |> Multi.run(:version, fn _, _ ->
      create_import_version(scope, version_name)
    end)
    |> Multi.run(:parse, fn _, _ ->
      parse_gtfs_zip(zip_path)
    end)
    |> Multi.run(:stops, fn _, %{version: v, parse: data} ->
      import_stops(scope, v, data.stops)
    end)
    |> Multi.run(:levels, fn _, %{version: v, parse: data} ->
      import_levels(scope, v, data.levels)
    end)
    |> Multi.run(:pathways, fn _, %{version: v, parse: data} ->
      import_pathways(scope, v, data.pathways)
    end)
    |> Repo.transaction()
    |> handle_import_result()
  end

  defp handle_import_result({:ok, %{version: version}}), do:
    {:ok, version}
  defp handle_import_result({:error, step, reason, _}), do:
    {:error, {step, reason}}
end
```

---

## Error Handling Patterns

Follow Elixir conventions for error handling using tagged tuples and pattern matching:

### Context Return Values

```elixir
# Context functions return tagged tuples
def create_stop(scope, attrs) do
  case %Stop{} |> Stop.changeset(attrs) |> Repo.insert() do
    {:ok, stop} -> {:ok, stop}
    {:error, changeset} -> {:error, changeset}
  end
end

# Bang variants for when failure is unexpected
def get_stop!(scope, id) do
  Repo.get!(Stop, id, scope: scope)
end
```

### LiveView Error Handling

```elixir
# Handle form submission with error feedback
@impl true
def handle_event("save", %{"stop" => params}, socket) do
  scope = socket.assigns.current_scope

  case Gtfs.create_stop(scope, params) do
    {:ok, stop} ->
      {:noreply,
       socket
       |> put_flash(:info, "Stop created successfully")
       |> push_navigate(to: ~p"/stops/#{stop}")}

    {:error, %Ecto.Changeset{} = changeset} ->
      {:noreply, assign(socket, :form, to_form(changeset))}
  end
end
```

### Ecto.Multi for Complex Operations

```elixir
# Use Ecto.Multi for operations that must succeed together
def delete_stop_with_pathways(%Scope{} = scope, stop) do
  Multi.new()
  |> Multi.delete_all(:pathways, fn _ ->
    from(p in Pathway,
      where: p.from_stop_id == ^stop.id or p.to_stop_id == ^stop.id
    )
  end)
  |> Multi.delete(:stop, stop)
  |> Repo.transaction()
  |> case do
    {:ok, %{stop: stop}} ->
      broadcast(scope, :stop_deleted, stop)
      {:ok, stop}

    {:error, _op, changeset, _changes} ->
      {:error, changeset}
  end
end
```

---

## Testing Strategy

Testing follows Elixir conventions with fixtures, factories, and comprehensive coverage:

### Test Support Setup

```elixir
# test/support/fixtures/gtfs_fixtures.ex
defmodule GtfsPlanner.GtfsFixtures do
  alias GtfsPlanner.Gtfs

  def valid_stop_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      stop_id: "stop_#{System.unique_integer()}",
      stop_name: "Test Station",
      location_type: 1,
      stop_lat: Decimal.new("42.3601"),
      stop_lon: Decimal.new("-71.0589")
    })
  end

  def stop_fixture(scope, attrs \\ %{}) do
    {:ok, stop} =
      attrs
      |> valid_stop_attrs()
      |> then(&Gtfs.create_stop(scope, &1))

    stop
  end

  def scope_fixture do
    org = GtfsPlanner.AccountsFixtures.organization_fixture()
    user = GtfsPlanner.AccountsFixtures.user_fixture(org)
    # Organization creation auto-creates a "First Version"
    [version | _] = GtfsPlanner.Versions.list_gtfs_versions(org.id)
    GtfsPlanner.Accounts.Scope.new(user, org, version)
  end
end
```

### Context Tests

```elixir
# test/gtfs_planner/gtfs_test.exs
defmodule GtfsPlanner.GtfsTest do
  use GtfsPlanner.DataCase

  alias GtfsPlanner.Gtfs
  import GtfsPlanner.GtfsFixtures

  describe "stops" do
    setup do
      %{scope: scope_fixture()}
    end

    test "list_parent_stations/1 returns only parent stations",
         %{scope: scope} do
      parent = stop_fixture(scope, %{location_type: 1})
      _child = stop_fixture(scope, %{
        location_type: 0,
        parent_station_id: parent.id
      })

      assert [returned] = Gtfs.list_parent_stations(scope)
      assert returned.id == parent.id
    end

    test "create_stop/2 enforces org_id from scope", %{scope: scope} do
      {:ok, stop} = Gtfs.create_stop(scope, valid_stop_attrs())
      assert stop.org_id == scope.organization.id
      assert stop.gtfs_version_id == scope.gtfs_version.id
    end

    test "get_stop!/2 is scoped to organization", %{scope: scope} do
      other_scope = scope_fixture()  # Different org
      stop = stop_fixture(scope)

      assert Gtfs.get_stop!(scope, stop.id).id == stop.id
      assert_raise Ecto.NoResultsError, fn ->
        Gtfs.get_stop!(other_scope, stop.id)
      end
    end
  end
end
```

### LiveView Tests

```elixir
# test/gtfs_planner_web/live/stop_live_test.exs
defmodule GtfsPlannerWeb.StopLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.GtfsFixtures

  setup :register_and_log_in_user

  describe "Index" do
    test "lists all parent stations", %{conn: conn, scope: scope} do
      stop = stop_fixture(scope, %{stop_name: "Central Station"})

      {:ok, _view, html} = live(conn, ~p"/stops")

      assert html =~ "Stops"
      assert html =~ "Central Station"
    end

    test "creates new stop", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/stops/new")

      assert view
             |> form("#stop-form", stop: %{
               stop_id: "new_stop",
               stop_name: "New Station",
               location_type: 1
             })
             |> render_submit()

      assert_patch(view, ~p"/stops")
      assert render(view) =~ "Stop created successfully"
    end

    test "updates stop in realtime via PubSub", %{conn: conn, scope: scope} do
      stop = stop_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/stops")

      # Simulate update from another session
      {:ok, updated} = Gtfs.update_stop(scope, stop, %{
        stop_name: "Updated Name"
      })

      # Should update via PubSub
      assert render(view) =~ "Updated Name"
    end
  end
end
```

---

## User Interface

### Design Principles

- **Desktop-First:** Optimized for desktop browsers; mobile is secondary
- **Component Library:** Daisy UI for consistent, accessible components with Tailwind
- **LiveView-First:** Real-time updates without full page reloads
- **Progressive Enhancement:** React only where complexity demands it (floorplan)

### Navigation Structure

```
┌─────────────────────────────────────────────────────────┐
│  [Logo]  Pathways Studio    [Version: v1.2] [User ▼]   │
├─────────────────────────────────────────────────────────┤
│  ┌──────┐                                              │
│  │ NAV  │  ┌─────────────────────────────────────────┐ │
│  │      │  │                                         │ │
│  │Stops │  │           MAIN CONTENT AREA             │ │
│  │Import│  │                                         │ │
│  │Export│  │                                         │ │
│  │Valid.│  │                                         │ │
│  │      │  └─────────────────────────────────────────┘ │
│  └──────┘                                              │
└─────────────────────────────────────────────────────────┘
```

### Key Views

1. **Stops List:** Table view of all parent stations using LiveView Streams
2. **Stop Detail:** Dynamic view with level tabs and overview
3. **Floorplan Editor:** Interactive canvas for a specific level
4. **Import Wizard:** Step-by-step GTFS import flow
5. **Export Panel:** Version selection and export options
6. **Validation Report:** Issues list with navigation to problem entities

---

## Core Features

### GTFS Version Context

Users always operate within a selected GTFS version. The version is part of the Scope and maintained in the socket assigns:

- Version selector in header/navigation
- Automatic "First Version" creation for new organizations (via `GtfsPlanner.Versions.create_default_version/1` called during organization creation)
- Version stored in session for persistence across page loads
- Version branching capability planned for future enhancement

### Stops Management

#### CRUD View

A table-based interface for managing parent station stops, using LiveView Streams for efficient rendering:

- Streamed data table with sorting and filtering
- Real-time updates via scoped PubSub
- Slide panel for create/edit operations
- Click-through to dynamic stop view

#### Dynamic Stop View

An interactive view for a single stop (parent station):

- Level management with add/edit/delete
- Level switching via tabs
- Overview of child stops and pathways per level

### Floorplan View

The floorplan view is the primary workspace for pathway creation:

- **Background Image:** Uploadable floorplan image for the level
- **Child Stop Placement:** Click to add child stops with controlled location_type
- **Pathway Creation:** Select two child stops to create a pathway
- **Visual Indicators:** Lines showing pathways with mode-based styling

#### React Integration via Hooks

If React is used for the canvas, integrate via LiveView hooks:

```javascript
// assets/js/hooks/floorplan_hook.js
export const FloorplanHook = {
  mounted() {
    const container = this.el
    const data = JSON.parse(this.el.dataset.floorplan)

    // Mount React component
    this.root = createRoot(container)
    this.root.render(
      <FloorplanCanvas
        {...data}
        onStopClick={(id) => this.pushEvent('stop_clicked', {id})}
        onPathwayCreate={(from, to) =>
          this.pushEvent('create_pathway', {from, to})}
      />
    )
  },

  updated() {
    // Re-render with new data from server
    const data = JSON.parse(this.el.dataset.floorplan)
    this.root.render(<FloorplanCanvas {...data} ... />)
  },

  destroyed() {
    this.root.unmount()
  }
}
```

### Edit Panels

All entity editing uses sliding panels implemented as function components:

```elixir
# lib/gtfs_planner_web/components/slide_panel.ex
defmodule GtfsPlannerWeb.Components.SlidePanel do
  use Phoenix.Component

  attr :show, :boolean, default: false
  attr :title, :string, required: true
  attr :on_close, :any, required: true
  slot :inner_block, required: true

  def slide_panel(assigns) do
    ~H"""
    <div
      class={[
        "fixed inset-y-0 right-0 w-96 bg-white shadow-xl",
        "transform transition-transform duration-300",
        @show && "translate-x-0" || "translate-x-full"
      ]}
    >
      <div class="p-4 border-b flex justify-between">
        <h2 class="text-lg font-semibold"><%= @title %></h2>
        <button phx-click={@on_close} class="btn btn-ghost btn-sm">×</button>
      </div>
      <div class="p-4">
        <%= render_slot(@inner_block) %>
      </div>
    </div>
    """
  end
end
```

### GTFS Import/Export

- **Import:** Upload GTFS ZIP, parse files, create/update version via Ecto.Multi transaction
- **Export:** Generate stops.txt, levels.txt, pathways.txt as downloadable ZIP
- **Validation:** Pre-import/export validation with detailed error reporting

---

## Implementation Phases

### Phase 1: Foundation

1. Phoenix 1.8 project setup with `phx.gen.auth`
2. Configure Scope with organization + version
3. Implement `Repo.prepare_query/3` for enforced scoping
4. Database migrations with composite foreign keys
5. Migrate authentication from Warbler (implementation documented in [warbler-authentication-implementation.md](warbler-authentication-implementation.md))
6. GTFS Version management context

### Phase 2: Core Pathways Features

- Stops CRUD with LiveView Streams
- PubSub integration for real-time updates
- Dynamic Stop view with levels
- Slide panel components
- Floorplan view (basic implementation)
- Child stop and pathway management

### Phase 3: Import/Export/Validation

- GTFS import with Ecto.Multi transactions
- GTFS export functionality
- Validation engine and reporting

### Phase 4: Polish & Enhancement

- React floorplan canvas (if needed)
- UI/UX refinement with Daisy UI
- Performance optimization
- Comprehensive test coverage
- Access control for GTFS Planner integration

---

## Conclusion

This architecture leverages Phoenix 1.8's Scopes and Ecto's `prepare_query/3` to provide enforced multi-tenant data access, making security the default rather than something developers must remember. The use of composite foreign keys ensures data integrity at the database level.

LiveView Streams, PubSub integration, and function components provide a responsive, real-time user experience while keeping code maintainable. The Context pattern organizes business logic into clear boundaries with scope-first function signatures.

**Key success factors:**

- Rigorous scope enforcement in all data operations
- Comprehensive testing with fixtures
- Clean separation between LiveView UI logic and Context business logic

---

## Change Log

| Date | Version | Changes |
|------|---------|---------|
| 2026-01-19 | 2.1 | Updated to reflect implementation from GitHub Issue #50 / PR #51: Changed Versioning Context from `GtfsPlanner.Gtfs.Versioning` to `GtfsPlanner.Versions`; Updated schema location from `lib/gtfs_planner/gtfs/version.ex` to `lib/gtfs_planner/versions/gtfs_version.ex`; Changed default version name from "Initial version" to "First Version"; Removed references to `status` and `parent_version_id` fields (noted as future enhancements); Updated function references from `get_or_create_initial_version/1` to `create_default_version/1` and `list_gtfs_versions/1`; Updated all `GtfsPlanner.Gtfs.Version` references to `GtfsPlanner.Versions.GtfsVersion`. |