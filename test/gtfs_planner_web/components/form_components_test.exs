defmodule GtfsPlannerWeb.FormComponentsTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component
  import GtfsPlannerWeb.CoreComponents

  describe "input/1 shared contract" do
    test "renders deterministic help and error IDs with combined aria-describedby" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.input
          id="email"
          name="email"
          label="Email"
          help="Enter your work email"
          errors={["can't be blank"]}
        />
        """)

      assert html =~ "id=\"email-help\""
      assert html =~ "id=\"email-error\""
      assert html =~ ~r/aria-describedby="email-help email-error"/
      assert html =~ ~r/aria-invalid="true"/
      assert html =~ "can&#39;t be blank"
    end

    test "sets aria-invalid=false and omits error ID when no errors" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.input id="name" name="name" label="Name" help="Your name" />
        """)

      assert html =~ ~r/aria-invalid="false"/
      assert html =~ ~r/aria-describedby="name-help"/
      refute html =~ "name-error"
    end

    test "renders no role=alert or aria-live on error containers" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.input id="name" name="name" label="Name" errors={["is invalid"]} />
        """)

      assert html =~ "id=\"name-error\""
      refute html =~ "role=\"alert\""
      refute html =~ "aria-live"
    end

    test "renders visible actionable error text" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.input id="age" name="age" label="Age" errors={["must be a number", "must be positive"]} />
        """)

      assert html =~ "must be a number"
      assert html =~ "must be positive"
      assert html =~ "id=\"age-error\""
    end

    test "select clause follows the same contract" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.input
          id="role"
          name="role"
          type="select"
          label="Role"
          options={[{"Admin", "admin"}]}
          help="Pick a role"
          errors={["is invalid"]}
        />
        """)

      assert html =~ "id=\"role-help\""
      assert html =~ "id=\"role-error\""
      assert html =~ ~r/aria-describedby="role-help role-error"/
      assert html =~ ~r/aria-invalid="true"/
      refute html =~ "role=\"alert\""
      refute html =~ "aria-live"
    end

    test "textarea clause follows the same contract" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.input
          id="notes"
          name="notes"
          type="textarea"
          label="Notes"
          errors={["is too long"]}
        />
        """)

      assert html =~ "id=\"notes-error\""
      assert html =~ ~r/aria-describedby="notes-error"/
      assert html =~ ~r/aria-invalid="true"/
      refute html =~ "role=\"alert\""
      refute html =~ "aria-live"
    end

    test "checkbox clause follows the same contract" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.input
          id="active"
          name="active"
          type="checkbox"
          label="Active"
          errors={["must be accepted"]}
        />
        """)

      assert html =~ "id=\"active-error\""
      assert html =~ ~r/aria-describedby="active-error"/
      assert html =~ ~r/aria-invalid="true"/
      refute html =~ "role=\"alert\""
      refute html =~ "aria-live"
    end
  end

  describe "simple_form/1" do
    test "requires and renders the caller ID" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.simple_form for={%{}} id="my-form" phx-submit="save">
          <p>Fields</p>
        </.simple_form>
        """)

      assert html =~ "id=\"my-form\""
    end

    test "applies the bounded one-column layout" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.simple_form for={%{}} id="bounded-form">
          <p>Content</p>
        </.simple_form>
        """)

      assert html =~ "max-w-2xl"
      assert html =~ "w-full"
    end

    test "preserves caller-defined action order" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.simple_form for={%{}} id="action-form">
          <p>Fields</p>
          <:actions>
            <button type="button" id="cancel-btn">Cancel</button>
            <button type="submit" id="save-btn">Save</button>
          </:actions>
        </.simple_form>
        """)

      assert html =~ "id=\"cancel-btn\""
      assert html =~ "id=\"save-btn\""
      cancel_pos = :binary.match(html, "cancel-btn") |> elem(0)
      save_pos = :binary.match(html, "save-btn") |> elem(0)
      assert cancel_pos < save_pos
    end

    test "does not use :let binding" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.simple_form for={%{}} id="no-let-form">
          <p>Content</p>
        </.simple_form>
        """)

      assert html =~ "id=\"no-let-form\""
    end
  end

  describe "checkbox_group/1" do
    test "renders one fieldset with a legend" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.checkbox_group
          id="roles-group"
          name="roles[]"
          label="Roles"
          options={[{"Admin", "admin"}, {"Editor", "editor"}]}
        />
        """)

      assert html =~ "<fieldset"
      assert html =~ "<legend"
      assert html =~ "Roles"
    end

    test "derives deterministic unique option IDs from the group id" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.checkbox_group
          id="roles-group"
          name="roles[]"
          label="Roles"
          options={[{"Admin", "admin"}, {"Editor", "editor"}]}
        />
        """)

      assert html =~ "id=\"roles-group-admin\""
      assert html =~ "id=\"roles-group-editor\""
    end

    test "associates help and error IDs" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.checkbox_group
          id="roles-group"
          name="roles[]"
          label="Roles"
          options={[{"Admin", "admin"}]}
          help="Select at least one"
          error="Required"
        />
        """)

      assert html =~ "id=\"roles-group-help\""
      assert html =~ "id=\"roles-group-error\""
      assert html =~ ~r/aria-describedby="roles-group-help roles-group-error"/
    end

    test "renders visible required copy" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.checkbox_group
          id="roles-group"
          name="roles[]"
          label="Roles"
          options={[{"Admin", "admin"}]}
          required
        />
        """)

      assert html =~ "required"
    end

    test "renders visible optional copy when not required" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.checkbox_group
          id="roles-group"
          name="roles[]"
          label="Roles"
          options={[{"Admin", "admin"}]}
        />
        """)

      assert html =~ "optional"
    end

    test "applies invalid group styling when error is present" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.checkbox_group
          id="roles-group"
          name="roles[]"
          label="Roles"
          options={[{"Admin", "admin"}]}
          error="At least one role is required"
        />
        """)

      assert html =~ "text-error"
      assert html =~ "At least one role is required"
    end

    test "preserves selected values" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.checkbox_group
          id="roles-group"
          name="roles[]"
          label="Roles"
          options={[{"Admin", "admin"}, {"Editor", "editor"}]}
          selected={["admin"]}
        />
        """)

      assert html =~ ~r/id="roles-group-admin"[^>]*checked/
      refute html =~ ~r/id="roles-group-editor"[^>]*checked/
    end

    test "renders no role=alert or aria-live on error" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.checkbox_group
          id="roles-group"
          name="roles[]"
          label="Roles"
          options={[{"Admin", "admin"}]}
          error="Required"
        />
        """)

      refute html =~ "role=\"alert\""
      refute html =~ "aria-live"
    end
  end
end
