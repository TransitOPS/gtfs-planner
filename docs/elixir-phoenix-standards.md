# Elixir Phoenix Engineering Standards

> Reflecting the philosophies of José Valim, Chris McCord, and Wojtek Mach

---

## Core Principles

### Philosophy

- **Let it crash**: Embrace OTP supervision. Don't write defensive code—let processes fail and restart cleanly. Invalid state? Crash. Unexpected message? Crash. The supervisor will handle it.
- **Explicit over implicit**: Elixir's pipe operator and pattern matching make data flow visible. Keep it that way. No hidden state, no magic.
- **Functional core, imperative shell**: Pure functions at the center, side effects at the boundaries. Phoenix contexts embody this.
- **Simple > Clever**: A straightforward `Enum.map` beats a clever macro. Boring code wins.
- **Build for today**: Design for current requirements. Elixir and OTP already give you the tools for tomorrow.
- **Data > Objects**: Think in terms of data transformations, not object hierarchies. Your app is a series of functions transforming data.

### Quality Bar

- Readable by someone new to the codebase in 6 months
- Obvious what each function does from its name and typespec
- Obvious when it breaks (pattern match failures, not silent defaults)
- Simple enough to trace data flow from request to response

---

## Elixir Fundamentals

### Pattern Matching First

Pattern matching is your primary control flow tool. Use it aggressively.

```elixir
# ✅ Good: Pattern match to handle cases
def process(%User{status: :active} = user), do: activate(user)
def process(%User{status: :pending} = user), do: send_reminder(user)
def process(%User{}), do: {:error, :invalid_status}

# ❌ Bad: Conditionals when pattern matching works
def process(user) do
  cond do
    user.status == :active -> activate(user)
    user.status == :pending -> send_reminder(user)
    true -> {:error, :invalid_status}
  end
end
```

### Pipes for Data Transformation

Use pipes when you're transforming data through multiple steps. Don't use pipes for a single operation or when it hurts readability.

```elixir
# ✅ Good: Clear data transformation
user
|> User.changeset(params)
|> Repo.update()
|> broadcast_change()

# ❌ Bad: Pipe for single operation
params |> Map.get(:name)

# ✅ Good: Just call it
Map.get(params, :name)
```

### With Clauses

Use `with` for sequential operations that can fail. Keep the happy path clear.

```elixir
# ✅ Good: Clear sequential operations
def create_order(user, items) do
  with {:ok, inventory} <- check_inventory(items),
       {:ok, payment} <- process_payment(user, items),
       {:ok, order} <- Orders.create(user, items, payment) do
    {:ok, order}
  end
end

# ❌ Bad: Nested case statements
def create_order(user, items) do
  case check_inventory(items) do
    {:ok, inventory} ->
      case process_payment(user, items) do
        {:ok, payment} ->
          # ... more nesting
```

### Error Handling

Return tagged tuples. Let callers decide what to do with errors.

```elixir
# ✅ Good: Tagged tuples
def fetch_user(id) do
  case Repo.get(User, id) do
    nil -> {:error, :not_found}
    user -> {:ok, user}
  end
end

# ✅ Good: Bang functions for expected success
def fetch_user!(id) do
  Repo.get!(User, id)
end

# ❌ Bad: Returning nil and hoping caller checks
def fetch_user(id) do
  Repo.get(User, id)
end
```

### Structs and Data

Define clear data structures. Use `@enforce_keys` for required fields.

```elixir
defmodule MyApp.Order do
  @enforce_keys [:user_id, :items]
  defstruct [:id, :user_id, :items, :status, inserted_at: nil]

  @type t :: %__MODULE__{
    id: integer() | nil,
    user_id: integer(),
    items: [Item.t()],
    status: :pending | :confirmed | :shipped,
    inserted_at: DateTime.t() | nil
  }
end
```

### What NOT to Do in Elixir

- ❌ Don't use `if nil` checks—pattern match instead
- ❌ Don't rescue broadly—let it crash or handle specific errors
- ❌ Don't create deeply nested data access—restructure your data
- ❌ Don't use agents/GenServers when a simple function works
- ❌ Don't write macros unless you have a compelling reason
- ❌ Don't ignore compiler warnings

---

## Phoenix Application Structure

### Contexts: Functional Boundaries

Contexts are your API boundaries. They encapsulate related functionality and hide implementation details.

```elixir
# ✅ Good: Context as public API
defmodule MyApp.Accounts do
  def get_user!(id), do: Repo.get!(User, id)
  def authenticate(email, password), do: # ...
  def register(params), do: # ...
end

# Controllers call contexts, never Repo directly
defmodule MyAppWeb.UserController do
  def show(conn, %{"id" => id}) do
    user = Accounts.get_user!(id)
    render(conn, :show, user: user)
  end
end
```

### Context Design Principles

- **One context per domain concept**: `Accounts`, `Orders`, `Inventory`—not `UserHelpers`
- **Contexts own their schemas**: `Accounts.User`, not `MyApp.User`
- **Cross-context communication through public functions**: Never reach into another context's internals
- **Keep contexts focused**: If a context grows beyond 300-400 lines, consider splitting

```elixir
# ✅ Good: Context structure
lib/my_app/
  accounts/           # Context directory
    accounts.ex       # Public API
    user.ex           # Schema
    user_token.ex     # Schema
    user_notifier.ex  # Internal module
  orders/
    orders.ex
    order.ex
    line_item.ex
```

### What Contexts Should NOT Do

- ❌ Don't put web-specific logic in contexts (no `conn`, no `socket`)
- ❌ Don't create contexts for utilities—use plain modules
- ❌ Don't have contexts call each other's private functions
- ❌ Don't create a context for every schema

---

## Phoenix LiveView

### LiveView Philosophy

LiveView replaces JavaScript complexity with server-rendered real-time UI. Embrace this model fully.

- **Server is the source of truth**: All state lives in the socket assigns
- **Events, not callbacks**: User actions trigger events, events update state
- **Minimal JavaScript**: Use hooks only when necessary (browser APIs, third-party libs)

### LiveView Structure

Keep LiveViews focused and delegate to components.

```elixir
defmodule MyAppWeb.OrderLive.Index do
  use MyAppWeb, :live_view

  # Mount: Initial state setup
  def mount(_params, _session, socket) do
    {:ok, assign(socket, orders: [], loading: true)}
  end

  # Params: URL-driven state
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  # Events: User interactions
  def handle_event("delete", %{"id" => id}, socket) do
    order = Orders.get_order!(id)
    {:ok, _} = Orders.delete_order(order)
    {:noreply, stream_delete(socket, :orders, order)}
  end

  # Info: PubSub and internal messages
  def handle_info({:order_created, order}, socket) do
    {:noreply, stream_insert(socket, :orders, order, at: 0)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Orders")
    |> stream(:orders, Orders.list_orders())
  end
end
```

### Assigns Best Practices

```elixir
# ✅ Good: Minimal, focused assigns
def mount(_params, _session, socket) do
  {:ok,
   socket
   |> assign(:page_title, "Dashboard")
   |> assign(:current_tab, :overview)
   |> stream(:notifications, [])}
end

# ❌ Bad: Derived data in assigns
def mount(_params, _session, socket) do
  orders = Orders.list_orders()
  {:ok,
   socket
   |> assign(:orders, orders)
   |> assign(:order_count, length(orders))        # Derived—compute in template
   |> assign(:has_orders, orders != [])}          # Derived—compute in template
end
```

### Streams for Collections

Use streams for lists that change. They're memory-efficient and handle DOM updates correctly.

```elixir
# ✅ Good: Streams for dynamic lists
def mount(_params, _session, socket) do
  {:ok, stream(socket, :messages, Messages.list_recent())}
end

def handle_info({:new_message, message}, socket) do
  {:noreply, stream_insert(socket, :messages, message, at: 0)}
end

# Template
<div id="messages" phx-update="stream">
  <div :for={{dom_id, message} <- @streams.messages} id={dom_id}>
    <%= message.content %>
  </div>
</div>
```

### LiveView Components

Use function components for reusable UI. Use LiveComponents only when you need isolated state or event handling.

```elixir
# ✅ Good: Function component for stateless UI
attr :user, :map, required: true
attr :class, :string, default: nil

def user_avatar(assigns) do
  ~H"""
  <img
    src={@user.avatar_url}
    alt={@user.name}
    class={["rounded-full h-10 w-10", @class]}
  />
  """
end

# ✅ Good: LiveComponent for isolated state
defmodule MyAppWeb.ChatBoxComponent do
  use MyAppWeb, :live_component

  def mount(socket) do
    {:ok, assign(socket, message: "", messages: [])}
  end

  def handle_event("send", %{"message" => msg}, socket) do
    # Component handles its own events
    {:noreply, socket}
  end
end
```

### LiveView Anti-Patterns

- ❌ Don't store large data structures in assigns—use streams or load on demand
- ❌ Don't make database calls in render—do it in mount/handle_params/handle_event
- ❌ Don't use LiveComponent when a function component works
- ❌ Don't put business logic in LiveViews—call context functions
- ❌ Don't forget to handle disconnected/reconnected states

---

## Ecto and PostgreSQL

### Changesets: Your Validation Layer

Changesets are for data validation and transformation. Keep them focused.

```elixir
defmodule MyApp.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :name, :string
    field :password, :string, virtual: true, redact: true
    field :password_hash, :string, redact: true

    timestamps()
  end

  # ✅ Good: Separate changesets for different operations
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :password])
    |> validate_required([:email, :password])
    |> validate_email()
    |> validate_password()
    |> hash_password()
  end

  def profile_changeset(user, attrs) do
    user
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, min: 2, max: 100)
  end

  defp validate_email(changeset) do
    changeset
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/)
    |> validate_length(:email, max: 160)
    |> unsafe_validate_unique(:email, MyApp.Repo)
    |> unique_constraint(:email)
  end
end
```

### Query Composition

Build queries incrementally. Keep them in context modules.

```elixir
defmodule MyApp.Orders do
  import Ecto.Query

  def list_orders(opts \\ []) do
    Order
    |> filter_by_status(opts[:status])
    |> filter_by_user(opts[:user_id])
    |> order_by_recent()
    |> Repo.all()
  end

  defp filter_by_status(query, nil), do: query
  defp filter_by_status(query, status) do
    where(query, [o], o.status == ^status)
  end

  defp filter_by_user(query, nil), do: query
  defp filter_by_user(query, user_id) do
    where(query, [o], o.user_id == ^user_id)
  end

  defp order_by_recent(query) do
    order_by(query, [o], desc: o.inserted_at)
  end
end
```

### Migrations

Migrations are append-only history. Never modify existing migrations in production.

```elixir
defmodule MyApp.Repo.Migrations.CreateOrders do
  use Ecto.Migration

  def change do
    create table(:orders) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "pending"
      add :total_cents, :integer, null: false

      timestamps()
    end

    create index(:orders, [:user_id])
    create index(:orders, [:status])
    create index(:orders, [:inserted_at])
  end
end
```

### Database Best Practices

- **Use database constraints**: `null: false`, foreign keys, unique constraints
- **Index thoughtfully**: Index foreign keys and columns you filter/sort by
- **Use transactions**: `Repo.transaction` for multi-step operations
- **Preload explicitly**: Never rely on lazy loading
- **Use Postgres features**: Arrays, JSONB, full-text search when appropriate

```elixir
# ✅ Good: Explicit preloading
def get_order_with_items!(id) do
  Order
  |> Repo.get!(id)
  |> Repo.preload(:line_items)
end

# ✅ Good: Query-time preloading for filtering
def get_order_with_items!(id) do
  from(o in Order,
    where: o.id == ^id,
    preload: [line_items: ^from(li in LineItem, order_by: li.position)]
  )
  |> Repo.one!()
end

# ❌ Bad: N+1 waiting to happen
def list_orders do
  Repo.all(Order)
  # Then accessing order.line_items in template
end
```

### Ecto Anti-Patterns

- ❌ Don't use `Repo` in schemas—schemas are data, not behavior
- ❌ Don't create "god changesets" that handle everything
- ❌ Don't skip database constraints because "the app validates"
- ❌ Don't use raw SQL unless Ecto can't express it
- ❌ Don't forget to handle constraint errors in changesets

---

## Tailwind CSS & DaisyUI

### Tailwind in Phoenix

Phoenix ships with Tailwind. Use it idiomatically.

```heex
<%!-- ✅ Good: Utility classes, readable formatting --%>
<div class="flex items-center gap-4 p-4 bg-white rounded-lg shadow">
  <.user_avatar user={@user} class="h-12 w-12" />
  <div>
    <h3 class="font-medium text-gray-900"><%= @user.name %></h3>
    <p class="text-sm text-gray-500"><%= @user.email %></p>
  </div>
</div>

<%!-- ❌ Bad: Arbitrary values everywhere --%>
<div class="flex items-center gap-[17px] p-[13px] bg-[#fafafa] rounded-[7px]">
```

### DaisyUI Components

DaisyUI provides pre-built components. Use semantic class names.

```heex
<%!-- ✅ Good: DaisyUI semantic classes --%>
<button class="btn btn-primary">Save Changes</button>
<div class="alert alert-warning">Please review your input.</div>
<div class="card bg-base-100 shadow-xl">
  <div class="card-body">
    <h2 class="card-title"><%= @title %></h2>
    <p><%= @description %></p>
  </div>
</div>

<%!-- ✅ Good: Combining DaisyUI with Tailwind utilities --%>
<button class="btn btn-primary w-full mt-4">Submit</button>
```

### Component Styling Strategy

```elixir
# ✅ Good: Variant-based styling in components
attr :variant, :atom, default: :primary, values: [:primary, :secondary, :danger]
attr :size, :atom, default: :md, values: [:sm, :md, :lg]

def button(assigns) do
  ~H"""
  <button class={[
    "btn",
    variant_class(@variant),
    size_class(@size)
  ]}>
    <%= render_slot(@inner_block) %>
  </button>
  """
end

defp variant_class(:primary), do: "btn-primary"
defp variant_class(:secondary), do: "btn-secondary"
defp variant_class(:danger), do: "btn-error"

defp size_class(:sm), do: "btn-sm"
defp size_class(:md), do: ""
defp size_class(:lg), do: "btn-lg"
```

### CSS Anti-Patterns

- ❌ Don't create custom CSS when Tailwind utilities exist
- ❌ Don't use `@apply` excessively—defeats the purpose of utilities
- ❌ Don't mix CSS methodologies (BEM + Tailwind = confusion)
- ❌ Don't use arbitrary values (`[]`) when design tokens exist

---

## OTP and Concurrency

### When to Use Processes

Not everything needs a GenServer. Use the right tool:

| Need | Solution |
|------|----------|
| Transform data | Plain functions |
| Maintain state | GenServer |
| One-off async work | Task |
| Background jobs | Task.Supervisor, Oban |
| Pub/sub | Phoenix.PubSub |
| Cache | ETS, :persistent_term |
| Rate limiting | GenServer or external (Redis) |

### GenServer Basics

```elixir
defmodule MyApp.Counter do
  use GenServer

  # Client API
  def start_link(initial \\ 0) do
    GenServer.start_link(__MODULE__, initial, name: __MODULE__)
  end

  def increment, do: GenServer.call(__MODULE__, :increment)
  def get, do: GenServer.call(__MODULE__, :get)

  # Server callbacks
  @impl true
  def init(initial), do: {:ok, initial}

  @impl true
  def handle_call(:increment, _from, count), do: {:reply, count + 1, count + 1}
  def handle_call(:get, _from, count), do: {:reply, count, count}
end
```

### Supervision Trees

Let OTP handle failure recovery.

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      MyApp.Repo,
      {Phoenix.PubSub, name: MyApp.PubSub},
      MyAppWeb.Endpoint,
      # Your supervised processes
      {MyApp.Cache, []},
      {Task.Supervisor, name: MyApp.TaskSupervisor}
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

### PubSub for Real-Time

```elixir
# Broadcasting
Phoenix.PubSub.broadcast(MyApp.PubSub, "orders:#{user_id}", {:order_created, order})

# Subscribing in LiveView
def mount(_params, _session, socket) do
  if connected?(socket) do
    Phoenix.PubSub.subscribe(MyApp.PubSub, "orders:#{socket.assigns.current_user.id}")
  end
  {:ok, socket}
end

def handle_info({:order_created, order}, socket) do
  {:noreply, stream_insert(socket, :orders, order, at: 0)}
end
```

---

## Testing

### Test Philosophy

- Test behavior, not implementation
- Use ExUnit's built-in features fully
- Prefer integration tests for critical paths
- Unit test complex business logic

### Context Tests

```elixir
defmodule MyApp.AccountsTest do
  use MyApp.DataCase

  alias MyApp.Accounts

  describe "register_user/1" do
    test "creates user with valid params" do
      params = %{email: "test@example.com", password: "validpassword123"}

      assert {:ok, user} = Accounts.register_user(params)
      assert user.email == "test@example.com"
      assert user.password_hash
    end

    test "returns error with invalid email" do
      params = %{email: "invalid", password: "validpassword123"}

      assert {:error, changeset} = Accounts.register_user(params)
      assert "has invalid format" in errors_on(changeset).email
    end
  end
end
```

### LiveView Tests

```elixir
defmodule MyAppWeb.OrderLiveTest do
  use MyAppWeb.ConnCase

  import Phoenix.LiveViewTest

  describe "Index" do
    setup [:create_user, :log_in_user]

    test "lists orders", %{conn: conn, user: user} do
      order = order_fixture(user_id: user.id)

      {:ok, view, html} = live(conn, ~p"/orders")

      assert html =~ "Orders"
      assert html =~ order.reference
    end

    test "deletes order", %{conn: conn, user: user} do
      order = order_fixture(user_id: user.id)

      {:ok, view, _html} = live(conn, ~p"/orders")

      assert view |> element("#order-#{order.id} a", "Delete") |> render_click()
      refute has_element?(view, "#order-#{order.id}")
    end
  end
end
```

### What to Test

- ✅ Context functions (your public API)
- ✅ Complex business logic
- ✅ LiveView user flows
- ✅ Edge cases and error handling
- ❌ Don't test Phoenix/Ecto internals
- ❌ Don't test simple CRUD operations exhaustively
- ❌ Don't test private functions directly

---

## Project Structure

### Recommended Layout

```
lib/
  my_app/
    application.ex          # OTP application
    repo.ex                 # Ecto repo
    mailer.ex               # Email

    accounts/               # Context
      accounts.ex           # Public API
      user.ex               # Schema
      user_token.ex         # Schema
      user_notifier.ex      # Internal

    orders/                 # Context
      orders.ex
      order.ex
      line_item.ex

    workers/                # Background jobs
      order_processor.ex

  my_app_web/
    components/
      core_components.ex    # Shared components
      layouts.ex            # Layout components

    live/
      order_live/
        index.ex
        show.ex
        form_component.ex

    controllers/
      page_controller.ex
      page_html.ex
      page_html/
        home.html.heex

    router.ex
    endpoint.ex

test/
  my_app/                   # Context tests
    accounts_test.exs
    orders_test.exs

  my_app_web/
    live/                   # LiveView tests
      order_live_test.exs

  support/
    fixtures/
      accounts_fixtures.ex
      orders_fixtures.ex
    conn_case.ex
    data_case.ex
```

---

## Code Review Checklist

### Red Flags

- ☐ GenServer when a function would work
- ☐ LiveComponent when a function component would work
- ☐ Business logic in LiveViews or controllers
- ☐ Direct Repo calls outside contexts
- ☐ Nested case/if statements (use with/pattern matching)
- ☐ Defensive nil checks instead of pattern matching
- ☐ Missing typespecs on public functions
- ☐ Rescue blocks without specific exceptions
- ☐ Custom CSS when Tailwind utilities exist
- ☐ N+1 queries (missing preloads)

### Green Flags

- ☐ Clear context boundaries
- ☐ Pattern matching for control flow
- ☐ Tagged tuples for error handling
- ☐ Streams for dynamic LiveView lists
- ☐ Database constraints backing changeset validations
- ☐ PubSub for real-time features
- ☐ Explicit preloads
- ☐ Focused, single-purpose functions

---

## Quick Reference

### Common Patterns

```elixir
# Fetch with error tuple
def get_thing(id) do
  case Repo.get(Thing, id) do
    nil -> {:error, :not_found}
    thing -> {:ok, thing}
  end
end

# Fetch or raise
def get_thing!(id), do: Repo.get!(Thing, id)

# List with filters
def list_things(opts \\ []) do
  Thing
  |> maybe_filter(:status, opts[:status])
  |> Repo.all()
end

defp maybe_filter(query, _field, nil), do: query
defp maybe_filter(query, :status, value), do: where(query, [t], t.status == ^value)

# Transaction with multiple operations
def create_order(user, items) do
  Repo.transaction(fn ->
    with {:ok, order} <- insert_order(user),
         {:ok, _items} <- insert_items(order, items) do
      order
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end)
end
```

### LiveView Patterns

```elixir
# Assign on mount
def mount(_params, _session, socket) do
  {:ok, assign(socket, loading: true, data: nil)}
end

# Load on params
def handle_params(%{"id" => id}, _uri, socket) do
  {:noreply, assign(socket, thing: Things.get_thing!(id))}
end

# Handle user event
def handle_event("save", %{"form" => params}, socket) do
  case Things.update(socket.assigns.thing, params) do
    {:ok, thing} -> {:noreply, assign(socket, thing: thing)}
    {:error, changeset} -> {:noreply, assign(socket, changeset: changeset)}
  end
end

# Handle PubSub
def handle_info({:thing_updated, thing}, socket) do
  {:noreply, stream_insert(socket, :things, thing)}
end
```

---

*Build for the system you have today. Elixir and OTP already give you the tools for tomorrow.*
