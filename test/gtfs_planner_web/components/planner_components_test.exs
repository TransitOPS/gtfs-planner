defmodule GtfsPlannerWeb.Components.PlannerComponentsTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  import GtfsPlannerWeb.PlannerComponents

  @options [
    %{value: "editor", label: "Editor", description: "Edits routes."},
    %{value: "admin", label: "Admin", description: "Manages users."}
  ]

  defp doc(html), do: LazyHTML.from_fragment(html)

  describe "back_link/1" do
    test "names the parent page and links to it" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.back_link id="back-to-parent" navigate="/parent">Parent</.back_link>
        """)

      link = doc(html) |> LazyHTML.query("#back-to-parent")

      assert LazyHTML.attribute(link, "href") == ["/parent"]
      assert LazyHTML.text(link) |> String.trim() == "Parent"
      assert Enum.count(LazyHTML.query(link, ".hero-chevron-left")) == 1
    end
  end

  describe "scope_line/1" do
    test "puts the scope in words next to an icon that names its kind" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.scope_line id="page-scope" icon="hero-calendar">Applies to one version only.</.scope_line>
        """)

      line = doc(html) |> LazyHTML.query("#page-scope")

      assert LazyHTML.text(line) |> String.trim() == "Applies to one version only."
      assert Enum.count(LazyHTML.query(line, ".hero-calendar")) == 1
    end
  end

  describe "drawer_scroll/1" do
    test "holds a drawer step's content in a scrolling region" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.drawer_scroll>
          <p id="step-body">Fields</p>
        </.drawer_scroll>
        """)

      assert Enum.count(doc(html) |> LazyHTML.query("div.overflow-y-auto #step-body")) == 1
    end
  end

  describe "message/1" do
    test "announces an error as an alert with its title and second line" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.message id="outcome" kind="error" title="Nothing was saved.">Try again.</.message>
        """)

      message = doc(html) |> LazyHTML.query("#outcome")

      assert LazyHTML.attribute(message, "role") == ["alert"]
      assert LazyHTML.text(message) =~ "Nothing was saved."
      assert LazyHTML.text(message) =~ "Try again."
    end

    test "reports success as a polite status, not an alert" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.message id="outcome" kind="success" title="Saved." />
        """)

      assert doc(html) |> LazyHTML.query("#outcome") |> LazyHTML.attribute("role") == ["status"]
    end

    test "lets a warning that reports a state be a polite status instead of an alert" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.message id="stale" kind="warning" role="status" title="May be out of date." />
        <.message id="failed" kind="warning" title="Could not load." />
        """)

      assert doc(html) |> LazyHTML.query("#stale") |> LazyHTML.attribute("role") == ["status"]
      assert doc(html) |> LazyHTML.query("#failed") |> LazyHTML.attribute("role") == ["alert"]
    end

    test "reports info as a polite status with an information mark" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.message id="outcome" kind="info" title="Latest details loaded.">Save again.</.message>
        """)

      message = doc(html) |> LazyHTML.query("#outcome")

      assert LazyHTML.attribute(message, "role") == ["status"]
      assert Enum.count(LazyHTML.query(message, ".hero-information-circle")) == 1
    end

    test "renders a warning as an alert" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.message id="outcome" kind="warning" title="Added, but the email did not send." />
        """)

      assert doc(html) |> LazyHTML.query("#outcome") |> LazyHTML.attribute("role") == ["alert"]
    end

    test "renders no second line when none is given" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.message id="outcome" kind="success" title="Saved." />
        """)

      assert doc(html) |> LazyHTML.query("#outcome p + div") |> Enum.empty?()
    end

    test "puts the action beside the text, in the message that names the problem" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.message id="outcome" kind="warning" title="Agencies use different timezones">
          Choose one timezone.
          <:action><button id="resolve" type="button">Resolve timezones</button></:action>
        </.message>
        """)

      message = doc(html) |> LazyHTML.query("#outcome")

      assert Enum.count(LazyHTML.query(message, "#resolve")) == 1
      assert LazyHTML.text(message) =~ "Agencies use different timezones"
      assert LazyHTML.text(message) =~ "Choose one timezone."
    end

    test "renders no action wrapper when none is given" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.message id="outcome" kind="info" title="Saved.">Save again.</.message>
        """)

      assert doc(html) |> LazyHTML.query("#outcome button") |> Enum.empty?()
    end
  end

  describe "form_section/1" do
    test "names its fields with a legend and divides every section after the first" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <div id="sections">
          <.form_section title="Publisher" first?><input id="one" /></.form_section>
          <.form_section title="Data contact"><input id="two" /></.form_section>
        </div>
        """)

      sections = doc(html) |> LazyHTML.query("#sections > div")
      legends = doc(html) |> LazyHTML.query("legend") |> Enum.map(&String.trim(LazyHTML.text(&1)))

      assert legends == ["Publisher", "Data contact"]

      assert LazyHTML.attribute(sections, "class") |> Enum.map(&(&1 =~ "border-t")) == [
               false,
               true
             ]
    end
  end

  describe "unsaved_badge/1" do
    test "says in words that the draft differs from what is saved" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.unsaved_badge id="draft-mark" />
        """)

      assert doc(html) |> LazyHTML.query("#draft-mark") |> LazyHTML.text() |> String.trim() ==
               "Unsaved changes"
    end
  end

  describe "aside_link/1" do
    test "links on from the aside with its label and an arrow" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.aside_link id="go-on" navigate="/next">Go on</.aside_link>
        """)

      link = doc(html) |> LazyHTML.query("#go-on")

      assert LazyHTML.attribute(link, "href") == ["/next"]
      assert LazyHTML.text(link) |> String.trim() == "Go on"
      assert Enum.count(LazyHTML.query(link, ".hero-arrow-right")) == 1
    end
  end

  describe "constraint_chip/1" do
    test "names the removal by the value alone when no kind is given" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.constraint_chip id="chip-mode" key="route_type" label="Bus" />
        """)

      chip = doc(html) |> LazyHTML.query("#chip-mode")

      assert LazyHTML.attribute(chip, "aria-label") == ["Remove filter Bus"]
      assert LazyHTML.attribute(chip, "phx-value-key") == ["route_type"]
    end

    test "puts the kind ahead of the value and disables the chip on request" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.constraint_chip id="chip-route" key="route_id" kind="Route" label="Blue" disabled />
        """)

      chip = doc(html) |> LazyHTML.query("#chip-route")

      assert LazyHTML.attribute(chip, "aria-label") == ["Remove filter Route Blue"]
      assert Enum.count(LazyHTML.query(doc(html), "#chip-route[disabled]")) == 1
    end
  end

  describe "sort_header/1" do
    test "marks the sorted column with its direction" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <table>
          <tr>
            <.sort_header label="Name" sort_key="name" sort_by={:name} sort_dir={:desc} />
          </tr>
        </table>
        """)

      header = doc(html) |> LazyHTML.query("th")

      assert LazyHTML.attribute(header, "aria-sort") == ["descending"]
      assert LazyHTML.text(header) |> String.replace(~r/\s+/, "") == "Name▼"
    end

    test "leaves another column unsorted" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <table>
          <tr>
            <.sort_header label="Stop ID" sort_key="name" sort_by={:id} sort_dir={:asc} />
          </tr>
        </table>
        """)

      header = doc(html) |> LazyHTML.query("th")

      assert LazyHTML.attribute(header, "aria-sort") == ["none"]
      assert LazyHTML.text(header) |> String.replace(~r/\s+/, "") == "StopID↕"
    end
  end

  describe "safe_href/2" do
    test "opens a plain web address or email and nothing else" do
      assert safe_href(:web, "https://agency.example/fares") == "https://agency.example/fares"
      assert safe_href(:web, "HTTP://agency.example") == "HTTP://agency.example"
      assert safe_href(:email, "riders@agency.example") == "mailto:riders@agency.example"
    end

    test "refuses imported text a browser could act on unexpectedly" do
      assert safe_href(:web, "javascript:alert(1)") == nil
      assert safe_href(:web, "https://agency.example is our site") == nil
      assert safe_href(:web, "agency.example") == nil
      assert safe_href(:email, "call the office") == nil
      assert safe_href(:email, "riders@") == nil
      assert safe_href(:text, "https://agency.example") == nil
      assert safe_href(:web, nil) == nil
    end
  end

  describe "drawer_footer/1" do
    test "holds a drawer form's actions in one footer" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.drawer_footer>
          <button type="button">Cancel</button>
          <button type="submit">Save changes</button>
        </.drawer_footer>
        """)

      footer = doc(html) |> LazyHTML.query("footer")

      assert Enum.count(footer) == 1
      assert Enum.count(LazyHTML.query(footer, "button")) == 2
    end
  end

  describe "form_error_summary/1" do
    test "renders nothing when there are no failures" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.form_error_summary id="summary" title="Not saved." failures={[]} />
        """)

      assert String.trim(html) == ""
    end

    test "links each failure to its field inside a focusable alert" do
      assigns = %{failures: [%{href: "#email", msg: "Enter an email address."}]}

      html =
        rendered_to_string(~H"""
        <.form_error_summary id="summary" title="Not saved." failures={@failures} />
        """)

      summary = doc(html) |> LazyHTML.query("#summary")

      assert LazyHTML.attribute(summary, "role") == ["alert"]
      assert LazyHTML.attribute(summary, "tabindex") == ["-1"]
      assert LazyHTML.attribute(LazyHTML.query(summary, "a"), "href") == ["#email"]
      assert LazyHTML.text(LazyHTML.query(summary, "a")) == "Enter an email address."
    end
  end

  describe "first_use/1" do
    test "says what belongs here and offers the one next step" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.first_use id="empty" title="No members yet" icon="hero-users">
          Invite someone to give them access.
          <:action><a href="/invite">Invite member</a></:action>
        </.first_use>
        """)

      panel = doc(html) |> LazyHTML.query("#empty")

      assert LazyHTML.text(LazyHTML.query(panel, "h2")) =~ "No members yet"
      assert LazyHTML.text(panel) =~ "Invite someone to give them access."
      assert LazyHTML.attribute(LazyHTML.query(panel, "a"), "href") == ["/invite"]
      assert Enum.count(LazyHTML.query(panel, ".hero-users")) == 1
    end

    test "leaves out the icon and the action when none is given" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.first_use id="empty" title="Nothing here">Explained.</.first_use>
        """)

      panel = doc(html) |> LazyHTML.query("#empty")

      assert Enum.empty?(LazyHTML.query(panel, "[class*='hero-']"))
      assert Enum.empty?(LazyHTML.query(panel, "a, button"))
    end
  end

  describe "choice_cards/1" do
    test "renders radios for a single choice, checking only the selected value" do
      assigns = %{options: @options}

      html =
        rendered_to_string(~H"""
        <.choice_cards
          id="product"
          type="radio"
          name="organization[product]"
          label="Product"
          options={@options}
          selected={["admin"]}
        />
        """)

      document = doc(html)

      assert LazyHTML.attribute(LazyHTML.query(document, "input[type=radio]"), "name") == [
               "organization[product]",
               "organization[product]"
             ]

      assert Enum.empty?(LazyHTML.query(document, "input[type=checkbox]"))
      assert LazyHTML.attribute(LazyHTML.query(document, "input#product-editor"), "checked") == []

      assert LazyHTML.attribute(LazyHTML.query(document, "input#product-admin"), "checked") == [
               ""
             ]
    end

    test "renders one checkbox per option with a description, checked when selected" do
      assigns = %{options: @options}

      html =
        rendered_to_string(~H"""
        <.choice_cards
          id="roles"
          name="invite[roles][]"
          label="Access level"
          options={@options}
          selected={["admin"]}
        />
        """)

      document = doc(html)

      assert LazyHTML.attribute(LazyHTML.query(document, "input#roles-editor"), "checked") == []
      assert LazyHTML.attribute(LazyHTML.query(document, "input#roles-admin"), "checked") == [""]

      assert LazyHTML.attribute(LazyHTML.query(document, "input[type=checkbox]"), "name") == [
               "invite[roles][]",
               "invite[roles][]"
             ]

      assert LazyHTML.text(document) =~ "Manages users."
    end

    test "marks the group invalid and points its description at the error" do
      assigns = %{options: @options}

      html =
        rendered_to_string(~H"""
        <.choice_cards
          id="roles"
          name="invite[roles][]"
          label="Access level"
          help="Choose at least one."
          options={@options}
          error="Choose at least one access level."
        />
        """)

      group = doc(html) |> LazyHTML.query("fieldset#roles")

      assert LazyHTML.attribute(group, "aria-invalid") == ["true"]
      assert LazyHTML.attribute(group, "aria-describedby") == ["roles-help roles-error"]

      assert LazyHTML.text(LazyHTML.query(doc(html), "#roles-error")) =~
               "Choose at least one access level."
    end

    test "renders a valid group with no error and no dangling description" do
      assigns = %{options: @options}

      html =
        rendered_to_string(~H"""
        <.choice_cards id="roles" name="invite[roles][]" label="Access level" options={@options} />
        """)

      document = doc(html)
      group = LazyHTML.query(document, "fieldset#roles")

      assert LazyHTML.attribute(group, "aria-invalid") == ["false"]
      assert LazyHTML.attribute(group, "aria-describedby") == []
      assert Enum.empty?(LazyHTML.query(document, "#roles-error"))
    end
  end
end
