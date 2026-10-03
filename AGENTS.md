This is a web application written using the Phoenix web framework.

## Project guidelines

- For executable changes, run `mix precommit` once at branch completion and resolve relevant failures. Implementation steps use focused checks below; do not run the full alias after every step. Documentation-only changes require diff, command/path, and instruction-consistency checks, not application suites.
- Use the already included and available `:req` (`Req`) library for HTTP requests, **avoid** `:httpoison`, `:tesla`, and `:httpc`. Req is included by default and is the preferred HTTP client for Phoenix apps

### Test selection and execution

Keep integration coverage growing where it proves wiring, persistence, transactions,
authorization, or user interactions. During implementation, default to affected unit tests
for calculations, parsing, and rule permutations. Run focused database, LiveView, or API tests
when the changed boundary is ready; browser tests belong to affected browser behavior.
Do not repeat the same permutation matrix at every layer. Extend existing fixtures and tests,
keep setup minimal, and make new cases independently selectable.

| Need | Existing command or location |
|---|---|
| Focused tests for the current diff (advisory) | `bin/test-affected` (add `--run` to run them) |
| Routing unit feedback | `mix test test/gtfs_planner/routing/route_test.exs` |
| Calendar rule feedback | `mix test test/gtfs_planner/gtfs/calendars/service_dates_test.exs` |
| Calendar persistence boundary | `mix test test/gtfs_planner/gtfs/calendars/combination_apply_test.exs` |
| One ExUnit case or describe block | `mix test path/to/file_test.exs:LINE` (use an actual test/describe line) |
| Previously failed ExUnit cases | `mix test --failed` (this checkout's last recorded failures; after a partitioned run, those of every partition) |
| Map geometry unit feedback | `npm --prefix assets test -- js/__tests__/stop_map_geometry_test.js` |
| Calendar browser journey | `bin/test-browser e2e/calendars.spec.js` |
| Final Elixir regression and static checks | `mix precommit` (static checks, then `bin/test-all` partitions on throwaway `pg_tmp` servers) |

Find nearby context tests under `test/gtfs_planner/`, LiveView tests under
`test/gtfs_planner_web/live/`, API tests under `test/gtfs_planner_web/api/`, JavaScript tests
under `assets/js/__tests__/`, and browser journeys under `assets/e2e/`. Trace affected callers
as well as matching filenames. These examples are selectors, not a required checklist.
`mix precommit` does not run JavaScript or browser checks; select those separately when relevant.

`bin/test-affected [--base <ref>] [--run]` prints focused ExUnit, JavaScript and browser commands
for the diff against the merge base with `origin/main`, including uncommitted and untracked files.
It matches module names and imports, so it misses dynamic references and files read at runtime.
It recommends `bin/test-all` instead of a file list when a change touches `test/support/`,
`config/`, `mix.exs` or migrations, or selects over a quarter of the test files. `--run` runs the
printed ExUnit and JavaScript commands, never browser tests. The selection is advisory;
`mix precommit` stays the completion gate.

`mix test` always runs the database-create/migrate alias first, even for pure tests. Tags and
name filters may still load broad collections; prefer explicit files. `--stale` is supplementary
selection with an initial full run, not a replacement for boundary reasoning. `--slowest` and
`--slowest-modules` enable tracing and serialize execution by default; distinguish diagnostic
timings from ordinary suite runtime. Read `mix help test` before changing invocation options.

`mix precommit` ends with `bin/test-all`, which runs the ExUnit suite as `TEST_PARTITIONS`
partitions. Each partition is its own `mix test --partitions` process with its own throwaway
`pg_tmp` server, `TMPDIR` and failures manifest. It never connects to the local
`gtfs_planner_exunit*` databases and ignores the caller's `MIX_TEST_PARTITION`. `pg_tmp` comes
from ephemeralpg (`brew install ephemeralpg`), so `mix precommit` requires it. Arguments reach
every partition (`mix precommit --max-cases 4`), and a caller's `--max-cases` replaces the
runner's default. The run exits 0 only when every partition exits 0 and prints an ExUnit summary;
a killed or silent partition fails it. `TEST_PARTITIONS=1 bin/test-all <args>` is the
single-process fallback: it runs `mix test <args>` on the local test database with the caller's
`MIX_TEST_PARTITION` suffix.

A partitioned run prints each partition's tests, failures, seed, setup seconds and test seconds,
then the failure output. To reproduce one partition, run its printed
`TEST_PARTITIONS=n TEST_PARTITION_ONLY=i bin/test-all --seed <seed> --max-cases <m>` command. To
rerun only the failures, run the printed `mix test <file:line ...>` command or `mix test --failed`
(one process, local test database). The runner writes every partition's failures to this
checkout's manifest under `_build`, so `--failed` covers all partitions.

`pg_tmp` starts its server with `LC_ALL=C` unless the caller sets `LC_ALL`, while the local test
database keeps the locale it was created with. A test that depends on collation or sort order can
pass in one mode and fail in the other; reproduce it in both before changing the test.

One owner runs final regression checks. Reuse valid step/CI results, preserving their original
revision and explaining why later changes leave them applicable. Rerun affected checks after
fixes; broaden for changed shared foundations or a concrete integration risk. A new reviewer,
workflow stage, or unrelated commit alone is not a reason for another full run. Keep scale and
real external-service tests opt-in unless the feature or project gate requires them.

Across local worktrees, allow one broad or resource-heavy suite at a time by default. A
partitioned `bin/test-all` run, with all its partitions, counts as one. Check existing runs
before launching another; never terminate someone else's process. Independent runs need isolated
databases, ports, and temporary roots. For focused `mix test` runs, `MIX_TEST_PARTITION` stays the
database suffix: it separates default database names but does not isolate the fixed
upload/artifact defaults in `config/test.exs`. Partitioned runs ignore it and isolate each
partition instead.
Use the established disposable harnesses and [database setup](docs/db-setup.md). Do not increase
ExUnit concurrency or browser workers without checking global state, fixture isolation, and
connection capacity; the browser suite intentionally shares state with one worker.

A test module may use `async: true` only when none of these apply; otherwise keep `async: false`:

- It changes process-global state: `Application.put_env/3`, `System.put_env/2`,
  `Logger.configure/1`, `File.cd/1`, `:persistent_term`, named ETS tables, Mox global mode, or an
  application-wide named process.
- It uses shared sandbox mode or `Sandbox.unboxed_run/2`, or commits deliberate interleavings or
  global advisory locks.
- It writes a fixed path under `System.tmp_dir!/0`.
- It inserts a literal value into a globally unique column or index, such as `users.email` or
  `organizations.alias`. Where the test does not assert the value, use `unique_user_email/0` or
  `System.unique_integer/1` instead.

A converted module that fails intermittently returns to `async: false` with a comment naming the
observed failure. Do not add retries or sleeps to keep it asynchronous.

Use finite command deadlines (120 seconds for focused checks unless measured setup/runtime
justifies longer). Record selection, elapsed time, outcome, and why a rerun is needed. Diagnose
timeouts and narrow the reproduction instead of repeatedly extending a broad run. A timeout
or unavailable check is not a pass. Passing required checks end verification unless a relevant
change or new finding invalidates them.

### Delivery priorities

Read the current delivery posture in the primary checkout's `.specs/project-context.md`.
This is an early, low-customer project: prioritize short feedback cycles and useful completed
features. Record unrelated cleanup, minor polish, and speculative hardening in a concrete local
follow-up brief or existing backlog for batched fix-up PRs. Do not expand each feature to absorb
that work. Current acceptance failures, tenant isolation, security, retained-data protection,
and relevant failing checks remain obligations; small customer numbers do not authorize resets.

### Scoped writes and LiveView verification

- Derive actor, organization and version identity from trusted server context; scope entity lookups before applying client attributes.
- In retrying write commands, check current membership inside each transaction attempt before entity locks and revision checks. `Repo.in_transaction?/0` establishes transaction presence, not authorization.
- Seed edit forms from persisted values, retain drafts after refused writes, and keep `phx-value-*` identity keys consistent with handler parameters.
- For asynchronous LiveView work, cover both successful results and exits after query replacement, drawer close and reopen. Check the current task and UI lifecycle before changing assigns.
- Follow [the project safety procedures](docs/engineering-standards.md#scoped-writes-and-verification) for SQL Sandbox failure cases, genuine database interleavings, forged LiveView events, deterministic async fixtures and verification limits.

### Phoenix v1.8 guidelines

- **Always** begin your LiveView templates with `<Layouts.app flash={@flash} ...>` which wraps all inner content
- The `MyAppWeb.Layouts` module is aliased in the `my_app_web.ex` file, so you can use it without needing to alias it again
- Anytime you run into errors with no `current_scope` assign:
  - You failed to follow the Authenticated Routes guidelines, or you failed to pass `current_scope` to `<Layouts.app>`
  - **Always** fix the `current_scope` error by moving your routes to the proper `live_session` and ensure you pass `current_scope` as needed
- Phoenix v1.8 moved the `<.flash_group>` component to the `Layouts` module. You are **forbidden** from calling `<.flash_group>` outside of the `layouts.ex` module
- Out of the box, `core_components.ex` imports an `<.icon name="hero-x-mark" class="w-5 h-5"/>` component for for hero icons. **Always** use the `<.icon>` component for icons, **never** use `Heroicons` modules or similar
- **Always** use the imported `<.input>` component for form inputs from `core_components.ex` when available. `<.input>` is imported and using it will save steps and prevent errors
- If you override the default input classes (`<.input class="myclass px-2 py-1 rounded-lg">)`) class with your own values, no default classes are inherited, so your
custom classes must fully style the input

### JS and CSS guidelines

- **Use Tailwind CSS classes and custom CSS rules** to create polished, responsive, and visually stunning interfaces.
- Tailwindcss v4 **no longer needs a tailwind.config.js** and uses a new import syntax in `app.css`:

      @import "tailwindcss" source(none);
      @source "../css";
      @source "../js";
      @source "../../lib/my_app_web";

- **Always use and maintain this import syntax** in the app.css file for projects generated with `phx.new`
- **Never** use `@apply` when writing raw css
- **Use** daisyUI components alongside Tailwind CSS to build polished, responsive, and visually appealing interfaces. Custom Tailwind components are also encouraged where needed for a unique design.
- Out of the box **only the app.js and app.css bundles are supported**
  - You cannot reference an external vendor'd script `src` or link `href` in the layouts
  - You must import the vendor deps into app.js and app.css to use them
  - **Never write inline <script>custom js</script> tags within templates**

### UI/UX & design guidelines

- **Produce world-class UI designs** with a focus on usability, aesthetics, and modern design principles
- Implement **subtle micro-interactions** (e.g., button hover effects, and smooth transitions)
- Ensure **clean typography, spacing, and layout balance** for a refined, premium look
- Focus on **delightful details** like hover effects, loading states, and smooth page transitions


<!-- usage-rules-start -->

<!-- phoenix:elixir-start -->
## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason

## Test guidelines

- **Always use `start_supervised!/1`** to start processes in tests as it guarantees cleanup between tests
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests
  - Instead of sleeping to wait for a process to finish, **always** use `Process.monitor/1` and assert on the DOWN message:

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

   - Instead of sleeping to synchronize before the next call, **always** use `_ = :sys.get_state/1` to ensure the process has handled prior messages
<!-- phoenix:elixir-end -->

<!-- phoenix:phoenix-start -->
## Phoenix guidelines

- Remember Phoenix router `scope` blocks include an optional alias which is prefixed for all routes within the scope. **Always** be mindful of this when creating routes within a scope to avoid duplicate module prefixes.

- You **never** need to create your own `alias` for route definitions! The `scope` provides the alias, ie:

      scope "/admin", AppWeb.Admin do
        pipe_through :browser

        live "/users", UserLive, :index
      end

  the UserLive route would point to the `AppWeb.Admin.UserLive` module

- `Phoenix.View` no longer is needed or included with Phoenix, don't use it
<!-- phoenix:phoenix-end -->

<!-- phoenix:ecto-start -->
## Ecto Guidelines

- **Always** preload Ecto associations in queries when they'll be accessed in templates, ie a message that needs to reference the `message.user.email`
- Remember `import Ecto.Query` and other supporting modules when you write `seeds.exs`
- `Ecto.Schema` fields always use the `:string` type, even for `:text`, columns, ie: `field :name, :string`
- `Ecto.Changeset.validate_number/2` **DOES NOT SUPPORT the `:allow_nil` option**. By default, Ecto validations only run if a change for the given field exists and the change value is not nil, so such as option is never needed
- You **must** use `Ecto.Changeset.get_field(changeset, :field)` to access changeset fields
- Fields which are set programatically, such as `user_id`, must not be listed in `cast` calls or similar for security purposes. Instead they must be explicitly set when creating the struct
- **Always** invoke `mix ecto.gen.migration migration_name_using_underscores` when generating migration files, so the correct timestamp and conventions are applied
<!-- phoenix:ecto-end -->

<!-- phoenix:html-start -->
## Phoenix HTML guidelines

- Phoenix templates **always** use `~H` or .html.heex files (known as HEEx), **never** use `~E`
- **Always** use the imported `Phoenix.Component.form/1` and `Phoenix.Component.inputs_for/1` function to build forms. **Never** use `Phoenix.HTML.form_for` or `Phoenix.HTML.inputs_for` as they are outdated
- When building forms **always** use the already imported `Phoenix.Component.to_form/2` (`assign(socket, form: to_form(...))` and `<.form for={@form} id="msg-form">`), then access those forms in the template via `@form[:field]`
- **Always** add unique DOM IDs to key elements (like forms, buttons, etc) when writing templates, these IDs can later be used in tests (`<.form for={@form} id="product-form">`)
- For "app wide" template imports, you can import/alias into the `my_app_web.ex`'s `html_helpers` block, so they will be available to all LiveViews, LiveComponent's, and all modules that do `use MyAppWeb, :html` (replace "my_app" by the actual app name)

- Elixir supports `if/else` but **does NOT support `if/else if` or `if/elsif`**. **Never use `else if` or `elseif` in Elixir**, **always** use `cond` or `case` for multiple conditionals.

  **Never do this (invalid)**:

      <%= if condition do %>
        ...
      <% else if other_condition %>
        ...
      <% end %>

  Instead **always** do this:

      <%= cond do %>
        <% condition -> %>
          ...
        <% condition2 -> %>
          ...
        <% true -> %>
          ...
      <% end %>

- HEEx require special tag annotation if you want to insert literal curly's like `{` or `}`. If you want to show a textual code snippet on the page in a `<pre>` or `<code>` block you *must* annotate the parent tag with `phx-no-curly-interpolation`:

      <code phx-no-curly-interpolation>
        let obj = {key: "val"}
      </code>

  Within `phx-no-curly-interpolation` annotated tags, you can use `{` and `}` without escaping them, and dynamic Elixir expressions can still be used with `<%= ... %>` syntax

- HEEx class attrs support lists, but you must **always** use list `[...]` syntax. You can use the class list syntax to conditionally add classes, **always do this for multiple class values**:

      <a class={[
        "px-2 text-white",
        @some_flag && "py-5",
        if(@other_condition, do: "border-red-500", else: "border-blue-100"),
        ...
      ]}>Text</a>

  and **always** wrap `if`'s inside `{...}` expressions with parens, like done above (`if(@other_condition, do: "...", else: "...")`)

  and **never** do this, since it's invalid (note the missing `[` and `]`):

      <a class={
        "px-2 text-white",
        @some_flag && "py-5"
      }> ...
      => Raises compile syntax error on invalid HEEx attr syntax

- **Never** use `<% Enum.each %>` or non-for comprehensions for generating template content, instead **always** use `<%= for item <- @collection do %>`
- HEEx HTML comments use `<%!-- comment --%>`. **Always** use the HEEx HTML comment syntax for template comments (`<%!-- comment --%>`)
- HEEx allows interpolation via `{...}` and `<%= ... %>`, but the `<%= %>` **only** works within tag bodies. **Always** use the `{...}` syntax for interpolation within tag attributes, and for interpolation of values within tag bodies. **Always** interpolate block constructs (if, cond, case, for) within tag bodies using `<%= ... %>`.

  **Always** do this:

      <div id={@id}>
        {@my_assign}
        <%= if @some_block_condition do %>
          {@another_assign}
        <% end %>
      </div>

  and **Never** do this – the program will terminate with a syntax error:

      <%!-- THIS IS INVALID NEVER EVER DO THIS --%>
      <div id="<%= @invalid_interpolation %>">
        {if @invalid_block_construct do}
        {end}
      </div>
<!-- phoenix:html-end -->

<!-- phoenix:liveview-start -->
## Phoenix LiveView guidelines

- **Never** use the deprecated `live_redirect` and `live_patch` functions, instead **always** use the `<.link navigate={href}>` and  `<.link patch={href}>` in templates, and `push_navigate` and `push_patch` functions LiveViews
- **Avoid LiveComponent's** unless you have a strong, specific need for them
- LiveViews should be named like `AppWeb.WeatherLive`, with a `Live` suffix. When you go to add LiveView routes to the router, the default `:browser` scope is **already aliased** with the `AppWeb` module, so you can just do `live "/weather", WeatherLive`

### LiveView streams

- **Always** use LiveView streams for collections for assigning regular lists to avoid memory ballooning and runtime termination with the following operations:
  - basic append of N items - `stream(socket, :messages, [new_msg])`
  - resetting stream with new items - `stream(socket, :messages, [new_msg], reset: true)` (e.g. for filtering items)
  - prepend to stream - `stream(socket, :messages, [new_msg], at: -1)`
  - deleting items - `stream_delete(socket, :messages, msg)`

- When using the `stream/3` interfaces in the LiveView, the LiveView template must 1) always set `phx-update="stream"` on the parent element, with a DOM id on the parent element like `id="messages"` and 2) consume the `@streams.stream_name` collection and use the id as the DOM id for each child. For a call like `stream(socket, :messages, [new_msg])` in the LiveView, the template would be:

      <div id="messages" phx-update="stream">
        <div :for={{id, msg} <- @streams.messages} id={id}>
          {msg.text}
        </div>
      </div>

- LiveView streams are *not* enumerable, so you cannot use `Enum.filter/2` or `Enum.reject/2` on them. Instead, if you want to filter, prune, or refresh a list of items on the UI, you **must refetch the data and re-stream the entire stream collection, passing reset: true**:

      def handle_event("filter", %{"filter" => filter}, socket) do
        # re-fetch the messages based on the filter
        messages = list_messages(filter)

        {:noreply,
         socket
         |> assign(:messages_empty?, messages == [])
         # reset the stream with the new messages
         |> stream(:messages, messages, reset: true)}
      end

- LiveView streams *do not support counting or empty states*. If you need to display a count, you must track it using a separate assign. For empty states, you can use Tailwind classes:

      <div id="tasks" phx-update="stream">
        <div class="hidden only:block">No tasks yet</div>
        <div :for={{id, task} <- @stream.tasks} id={id}>
          {task.name}
        </div>
      </div>

  The above only works if the empty state is the only HTML block alongside the stream for-comprehension.

- When updating an assign that should change content inside any streamed item(s), you MUST re-stream the items
  along with the updated assign:

      def handle_event("edit_message", %{"message_id" => message_id}, socket) do
        message = Chat.get_message!(message_id)
        edit_form = to_form(Chat.change_message(message, %{content: message.content}))

        # re-insert message so @editing_message_id toggle logic takes effect for that stream item
        {:noreply,
         socket
         |> stream_insert(:messages, message)
         |> assign(:editing_message_id, String.to_integer(message_id))
         |> assign(:edit_form, edit_form)}
      end

  And in the template:

      <div id="messages" phx-update="stream">
        <div :for={{id, message} <- @streams.messages} id={id} class="flex group">
          {message.username}
          <%= if @editing_message_id == message.id do %>
            <%!-- Edit mode --%>
            <.form for={@edit_form} id="edit-form-#{message.id}" phx-submit="save_edit">
              ...
            </.form>
          <% end %>
        </div>
      </div>

- **Never** use the deprecated `phx-update="append"` or `phx-update="prepend"` for collections

### LiveView JavaScript interop

- Remember anytime you use `phx-hook="MyHook"` and that JS hook manages its own DOM, you **must** also set the `phx-update="ignore"` attribute
- **Always** provide an unique DOM id alongside `phx-hook` otherwise a compiler error will be raised

LiveView hooks come in two flavors, 1) colocated js hooks for "inline" scripts defined inside HEEx,
and 2) external `phx-hook` annotations where JavaScript object literals are defined and passed to the `LiveSocket` constructor.

#### Inline colocated js hooks

**Never** write raw embedded `<script>` tags in heex as they are incompatible with LiveView.
Instead, **always use a colocated js hook script tag (`:type={Phoenix.LiveView.ColocatedHook}`)
when writing scripts inside the template**:

    <input type="text" name="user[phone_number]" id="user-phone-number" phx-hook=".PhoneNumber" />
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PhoneNumber">
      export default {
        mounted() {
          this.el.addEventListener("input", e => {
            let match = this.el.value.replace(/\D/g, "").match(/^(\d{3})(\d{3})(\d{4})$/)
            if(match) {
              this.el.value = `${match[1]}-${match[2]}-${match[3]}`
            }
          })
        }
      }
    </script>

- colocated hooks are automatically integrated into the app.js bundle
- colocated hooks names **MUST ALWAYS** start with a `.` prefix, i.e. `.PhoneNumber`

#### External phx-hook

External JS hooks (`<div id="myhook" phx-hook="MyHook">`) must be placed in `assets/js/` and passed to the
LiveSocket constructor:

    const MyHook = {
      mounted() { ... }
    }
    let liveSocket = new LiveSocket("/live", Socket, {
      hooks: { MyHook }
    });

#### Pushing events between client and server

Use LiveView's `push_event/3` when you need to push events/data to the client for a phx-hook to handle.
**Always** return or rebind the socket on `push_event/3` when pushing events:

    # re-bind socket so we maintain event state to be pushed
    socket = push_event(socket, "my_event", %{...})

    # or return the modified socket directly:
    def handle_event("some_event", _, socket) do
      {:noreply, push_event(socket, "my_event", %{...})}
    end

Pushed events can then be picked up in a JS hook with `this.handleEvent`:

    mounted() {
      this.handleEvent("my_event", data => console.log("from server:", data));
    }

Clients can also push an event to the server and receive a reply with `this.pushEvent`:

    mounted() {
      this.el.addEventListener("click", e => {
        this.pushEvent("my_event", { one: 1 }, reply => console.log("got reply from server:", reply));
      })
    }

Where the server handled it via:

    def handle_event("my_event", %{"one" => 1}, socket) do
      {:reply, %{two: 2}, socket}
    end

### LiveView tests

- `Phoenix.LiveViewTest` module and `LazyHTML` (included) for making your assertions
- Form tests are driven by `Phoenix.LiveViewTest`'s `render_submit/2` and `render_change/2` functions
- Come up with a step-by-step test plan that splits major test cases into small, isolated files. You may start with simpler tests that verify content exists, gradually add interaction tests
- **Always reference the key element IDs you added in the LiveView templates in your tests** for `Phoenix.LiveViewTest` functions like `element/2`, `has_element/2`, selectors, etc
- **Never** tests again raw HTML, **always** use `element/2`, `has_element/2`, and similar: `assert has_element?(view, "#my-form")`
- Instead of relying on testing text content, which can change, favor testing for the presence of key elements
- Focus on testing outcomes rather than implementation details
- Be aware that `Phoenix.Component` functions like `<.form>` might produce different HTML than expected. Test against the output HTML structure, not your mental model of what you expect it to be
- When facing test failures with element selectors, add debug statements to print the actual HTML, but use `LazyHTML` selectors to limit the output, ie:

      html = render(view)
      document = LazyHTML.from_fragment(html)
      matches = LazyHTML.filter(document, "your-complex-selector")
      IO.inspect(matches, label: "Matches")

### Form handling

#### Creating a form from params

If you want to create a form based on `handle_event` params:

    def handle_event("submitted", params, socket) do
      {:noreply, assign(socket, form: to_form(params))}
    end

When you pass a map to `to_form/1`, it assumes said map contains the form params, which are expected to have string keys.

You can also specify a name to nest the params:

    def handle_event("submitted", %{"user" => user_params}, socket) do
      {:noreply, assign(socket, form: to_form(user_params, as: :user))}
    end

#### Creating a form from changesets

When using changesets, the underlying data, form params, and errors are retrieved from it. The `:as` option is automatically computed too. E.g. if you have a user schema:

    defmodule MyApp.Users.User do
      use Ecto.Schema
      ...
    end

And then you create a changeset that you pass to `to_form`:

    %MyApp.Users.User{}
    |> Ecto.Changeset.change()
    |> to_form()

Once the form is submitted, the params will be available under `%{"user" => user_params}`.

In the template, the form form assign can be passed to the `<.form>` function component:

    <.form for={@form} id="todo-form" phx-change="validate" phx-submit="save">
      <.input field={@form[:field]} type="text" />
    </.form>

Always give the form an explicit, unique DOM ID, like `id="todo-form"`.

#### Avoiding form errors

**Always** use a form assigned via `to_form/2` in the LiveView, and the `<.input>` component in the template. In the template **always access forms this**:

    <%!-- ALWAYS do this (valid) --%>
    <.form for={@form} id="my-form">
      <.input field={@form[:field]} type="text" />
    </.form>

And **never** do this:

    <%!-- NEVER do this (invalid) --%>
    <.form for={@changeset} id="my-form">
      <.input field={@changeset[:field]} type="text" />
    </.form>

- You are FORBIDDEN from accessing the changeset in the template as it will cause errors
- **Never** use `<.form let={f} ...>` in the template, instead **always use `<.form for={@form} ...>`**, then drive all form references from the form assign as in `@form[:field]`. The UI should **always** be driven by a `to_form/2` assigned in the LiveView module that is derived from a changeset
<!-- phoenix:liveview-end -->

<!-- usage-rules-end -->

<!-- agents-docs:start -->
## SpecOps Agent Docs Index

Manifest: [`docs/specops/targets.json`](docs/specops/targets.json)

**System:** GTFS Planner is a multi-tenant Phoenix application for managing GTFS transit datasets, including organization-scoped authentication, editable routes and stations, station diagrams, import/export workflows, validation runs, OTP graph and station materialization, companion JSON APIs, and deployment/support tooling.

**External dependencies:** Elixir/Phoenix LiveView, PostgreSQL, Geoapify geocoding API, OpenTripPlanner, OSM extracts, SMTP (Swoosh), Tailwind CSS/daisyUI, Docker, AWS/OpenTofu.

| # | Target | Agent Doc | Deep Analysis | Status |
|---|---|---|---|---|
| 1 | Companion API Controllers | [`agents/lib-gtfs-planner-web-api.md`](docs/specops/agents/lib-gtfs-planner-web-api.md) | [`analysis/lib-gtfs-planner-web-api.md`](docs/specops/analysis/lib-gtfs-planner-web-api.md) | ✅ |
| 2 | Web Components and Layouts | [`agents/lib-gtfs-planner-web-components.md`](docs/specops/agents/lib-gtfs-planner-web-components.md) | [`analysis/lib-gtfs-planner-web-components.md`](docs/specops/analysis/lib-gtfs-planner-web-components.md) | ✅ |
| 3 | HTTP Controllers | [`agents/lib-gtfs-planner-web-controllers.md`](docs/specops/agents/lib-gtfs-planner-web-controllers.md) | [`analysis/lib-gtfs-planner-web-controllers.md`](docs/specops/analysis/lib-gtfs-planner-web-controllers.md) | ✅ |
| 4 | LiveView Interfaces | [`agents/lib-gtfs-planner-web-live.md`](docs/specops/agents/lib-gtfs-planner-web-live.md) | [`analysis/lib-gtfs-planner-web-live.md`](docs/specops/analysis/lib-gtfs-planner-web-live.md) | ✅ |
| 5 | API and Upload Plugs | [`agents/lib-gtfs-planner-web-plugs.md`](docs/specops/agents/lib-gtfs-planner-web-plugs.md) | [`analysis/lib-gtfs-planner-web-plugs.md`](docs/specops/analysis/lib-gtfs-planner-web-plugs.md) | ✅ |
| 6 | Email Templates | [`agents/lib-gtfs-planner-web-templates.md`](docs/specops/agents/lib-gtfs-planner-web-templates.md) | [`analysis/lib-gtfs-planner-web-templates.md`](docs/specops/analysis/lib-gtfs-planner-web-templates.md) | ✅ |
| 7 | Accounts Context | [`agents/lib-gtfs-planner-accounts.md`](docs/specops/agents/lib-gtfs-planner-accounts.md) | [`analysis/lib-gtfs-planner-accounts.md`](docs/specops/analysis/lib-gtfs-planner-accounts.md) | ✅ |
| 8 | Authorization Roles | [`agents/lib-gtfs-planner-authorization.md`](docs/specops/agents/lib-gtfs-planner-authorization.md) | [`analysis/lib-gtfs-planner-authorization.md`](docs/specops/analysis/lib-gtfs-planner-authorization.md) | ✅ |
| 9 | Geocoding Context | [`agents/lib-gtfs-planner-geocoding.md`](docs/specops/agents/lib-gtfs-planner-geocoding.md) | [`analysis/lib-gtfs-planner-geocoding.md`](docs/specops/analysis/lib-gtfs-planner-geocoding.md) | ✅ |
| 10 | GTFS Data Context | [`agents/lib-gtfs-planner-gtfs.md`](docs/specops/agents/lib-gtfs-planner-gtfs.md) | [`analysis/lib-gtfs-planner-gtfs.md`](docs/specops/analysis/lib-gtfs-planner-gtfs.md) | ✅ |
| 11 | Organizations Context | [`agents/lib-gtfs-planner-organizations.md`](docs/specops/agents/lib-gtfs-planner-organizations.md) | [`analysis/lib-gtfs-planner-organizations.md`](docs/specops/analysis/lib-gtfs-planner-organizations.md) | ✅ |
| 13 | Validation Context | [`agents/lib-gtfs-planner-validations.md`](docs/specops/agents/lib-gtfs-planner-validations.md) | [`analysis/lib-gtfs-planner-validations.md`](docs/specops/analysis/lib-gtfs-planner-validations.md) | ✅ |
| 14 | GTFS Versions Context | [`agents/lib-gtfs-planner-versions.md`](docs/specops/agents/lib-gtfs-planner-versions.md) | [`analysis/lib-gtfs-planner-versions.md`](docs/specops/analysis/lib-gtfs-planner-versions.md) | ✅ |
| 15 | Mix Maintenance Tasks | [`agents/lib-mix.md`](docs/specops/agents/lib-mix.md) | [`analysis/lib-mix.md`](docs/specops/analysis/lib-mix.md) | ✅ |
<!-- agents-docs:end -->
