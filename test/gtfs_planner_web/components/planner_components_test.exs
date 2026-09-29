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
