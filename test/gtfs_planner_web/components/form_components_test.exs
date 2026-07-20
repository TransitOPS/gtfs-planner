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
    test "requires a form binding in its public contract" do
      simple_form = GtfsPlannerWeb.CoreComponents.__components__()[:simple_form]
      for_attr = Enum.find(simple_form.attrs, &(&1.name == :for))

      assert for_attr.required
      refute Keyword.has_key?(for_attr.opts, :default)
    end

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
    test "treats an empty error as no error" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.checkbox_group
          id="roles-group"
          name="roles[]"
          label="Roles"
          options={[{"Admin", "admin"}]}
          error=""
        />
        """)

      doc = LazyHTML.from_fragment(html)
      fieldset = LazyHTML.query(doc, "#roles-group")
      classes = LazyHTML.attribute(fieldset, "class") |> List.first()

      assert LazyHTML.attribute(fieldset, "aria-invalid") == ["false"]
      refute classes =~ "text-error"
      refute html =~ "roles-group-error"
      refute html =~ "hero-exclamation-circle"
    end

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

  describe "upload_field/1 experimental contract" do
    test "renders labeled native file input with help text" do
      assigns = %{
        upload: %Phoenix.LiveView.UploadConfig{
          ref: "test-ref",
          entries: [],
          errors: [],
          max_entries: 1,
          max_file_size: 52_428_800,
          accept: [".zip"]
        }
      }

      html =
        rendered_to_string(~H"""
        <.upload_field
          id="feed-upload"
          upload={@upload}
          label="GTFS feed"
          help="ZIP file, max 50MB"
          cancel_event="cancel_upload"
        />
        """)

      assert html =~ "GTFS feed"
      assert html =~ "ZIP file, max 50MB"
      doc = LazyHTML.from_fragment(html)
      assert LazyHTML.query(doc, "#feed-upload-label") != []

      assert LazyHTML.query(
               doc,
               "#feed-upload input[type='file'][aria-labelledby='feed-upload-label']"
             ) != []
    end

    test "renders entry with progress bar and cancel button" do
      entry = %Phoenix.LiveView.UploadEntry{
        ref: "entry-ref",
        client_name: "test.zip",
        progress: 50,
        valid?: true
      }

      assigns = %{
        upload: %Phoenix.LiveView.UploadConfig{
          ref: "test-ref",
          entries: [entry],
          errors: [],
          max_entries: 1,
          max_file_size: 52_428_800,
          accept: [".zip"]
        }
      }

      html =
        rendered_to_string(~H"""
        <.upload_field
          id="feed-upload"
          upload={@upload}
          label="GTFS feed"
          help="ZIP file"
          cancel_event="cancel_upload"
        />
        """)

      assert html =~ "test.zip"
      assert html =~ "50%"
      assert html =~ ~r/id="feed-upload-entry-entry-ref"/
      assert html =~ ~r/phx-click="cancel_upload"/
      assert html =~ ~r/phx-value-ref="entry-ref"/
    end

    test "renders rejected entry errors" do
      entry = %Phoenix.LiveView.UploadEntry{
        ref: "bad-ref",
        client_name: "bad.exe",
        progress: 0,
        valid?: false
      }

      assigns = %{
        upload: %Phoenix.LiveView.UploadConfig{
          ref: "test-ref",
          entries: [entry],
          errors: [{"test-ref", :too_many_files}],
          max_entries: 1,
          max_file_size: 52_428_800,
          accept: [".zip"]
        }
      }

      html =
        rendered_to_string(~H"""
        <.upload_field
          id="feed-upload"
          upload={@upload}
          label="GTFS feed"
          help="ZIP file"
          cancel_event="cancel_upload"
        />
        """)

      assert html =~ "bad.exe"
      assert html =~ "Too many files"
    end

    test "renders view-level failure slot" do
      assigns = %{
        upload: %Phoenix.LiveView.UploadConfig{
          ref: "test-ref",
          entries: [],
          errors: [],
          max_entries: 1,
          max_file_size: 52_428_800,
          accept: [".zip"]
        }
      }

      html =
        rendered_to_string(~H"""
        <.upload_field
          id="feed-upload"
          upload={@upload}
          label="GTFS feed"
          help="ZIP file"
          cancel_event="cancel_upload"
        >
          <:failure>Upload failed: server error</:failure>
        </.upload_field>
        """)

      assert html =~ "Upload failed: server error"
      assert html =~ ~r/id="feed-upload-failure"/
    end

    test "renders error attribute" do
      assigns = %{
        upload: %Phoenix.LiveView.UploadConfig{
          ref: "test-ref",
          entries: [],
          errors: [],
          max_entries: 1,
          max_file_size: 52_428_800,
          accept: [".zip"]
        }
      }

      html =
        rendered_to_string(~H"""
        <.upload_field
          id="feed-upload"
          upload={@upload}
          label="GTFS feed"
          help="ZIP file"
          cancel_event="cancel_upload"
          error="File type not allowed"
        />
        """)

      assert html =~ "File type not allowed"
      assert html =~ ~r/id="feed-upload-error"/
      refute html =~ ~r/role="alert"/
    end

    test "exposes pending, failure, and accessibility associations for an upload entry" do
      entry = %Phoenix.LiveView.UploadEntry{
        ref: "entry-ref",
        client_name: "station-plan.png",
        progress: 64,
        valid?: false
      }

      assigns = %{
        upload: %Phoenix.LiveView.UploadConfig{
          ref: "test-ref",
          entries: [entry],
          errors: [{"entry-ref", :not_accepted}],
          max_entries: 1,
          max_file_size: 52_428_800,
          accept: [".png"]
        }
      }

      html =
        rendered_to_string(~H"""
        <.upload_field
          id="diagram-upload"
          upload={@upload}
          label="Diagram"
          help="PNG or JPEG, max 50MB"
          state={:validating}
          pending_label="Checking diagram…"
          error="The diagram could not be checked"
          disabled={true}
          disabled_reason="Choose a level before uploading"
        >
          <:failure>Try selecting the diagram again.</:failure>
        </.upload_field>
        """)

      doc = LazyHTML.from_fragment(html)

      input = LazyHTML.query(doc, "#diagram-upload input[type='file']")

      assert LazyHTML.attribute(input, "aria-describedby") == [
               "diagram-upload-help diagram-upload-error diagram-upload-failure diagram-upload-disabled-reason"
             ]

      assert LazyHTML.attribute(input, "disabled") == [""]

      assert LazyHTML.query(doc, "#diagram-upload[data-upload-state='validating']") != []
      assert LazyHTML.query(doc, "#diagram-upload-pending") != []
      assert LazyHTML.query(doc, "#diagram-upload-failure") != []
      assert LazyHTML.query(doc, "#diagram-upload-disabled-reason") != []

      progress = LazyHTML.query(doc, "#diagram-upload-entry-entry-ref progress")
      assert LazyHTML.attribute(progress, "value") == ["64"]
      assert LazyHTML.attribute(progress, "max") == ["100"]

      cancel =
        LazyHTML.query(doc, "#diagram-upload-entry-entry-ref button[phx-click='cancel_upload']")

      classes = LazyHTML.attribute(cancel, "class") |> List.first()
      assert classes =~ "min-h-11"
      assert classes =~ "min-w-11"

      assert LazyHTML.query(doc, "#diagram-upload-entry-entry-ref-error") != []
    end
  end
end
