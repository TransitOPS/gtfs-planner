defmodule GtfsPlannerWeb.FirstAdminLiveTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.FirstAdminForm
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion
  alias GtfsPlannerWeb.FirstAdminLive

  @base_message "Setup could not be completed. Please try again."
  @summary_selector "#first-admin-error-summary"
  @summary_title "There is a problem with this form"

  @field_control_ids [
    "first-admin-email",
    "first-admin-password",
    "first-admin-password-confirmation",
    "first-admin-organization-name",
    "first-admin-organization-alias"
  ]

  @all_invalid_params %{
    "email" => "not-an-email",
    "password" => "secret-pw-1",
    "password_confirmation" => "secret-pw-2-different",
    "organization_name" => "",
    "organization_alias" => ""
  }

  describe "initial availability" do
    test "renders the stable form contract with no summary for a zero-user install", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/first")

      assert has_element?(
               view,
               ~s(#first-admin-page[phx-hook="GtfsPlannerWeb.FirstAdminLive.FirstAdminErrorFocus"])
             )

      refute has_element?(view, "#first-admin-page[phx-update]")

      assert has_element?(view, ~s(#first_admin_form[phx-change="validate"][phx-submit="setup"]))
      assert has_element?(view, ~s(#first-admin-email[name="admin[email]"]))
      assert has_element?(view, ~s(#first-admin-password[name="admin[password]"]))

      assert has_element?(
               view,
               ~s(#first-admin-password-confirmation[name="admin[password_confirmation]"])
             )

      assert has_element?(
               view,
               ~s(#first-admin-organization-name[name="admin[organization_name]"])
             )

      assert has_element?(
               view,
               ~s(#first-admin-organization-alias[name="admin[organization_alias]"])
             )

      assert has_element?(view, "#first-admin-submit")
      refute has_element?(view, @summary_selector)

      for control_id <- @field_control_ids do
        assert has_element?(
                 view,
                 ~s(##{control_id}[phx-blur="validate"][phx-debounce="blur"])
               )
      end
    end
  end

  describe "task copy and pending contract" do
    test "renders the exact title, H1, help copy, and pending contract", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/first")

      assert page_title(view) == "Create administrator account · Pathways Studio"
      assert has_element?(view, "h1", "Create administrator account")

      h1s =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("h1")
        |> LazyHTML.to_tree()

      assert length(h1s) == 1

      assert has_element?(view, "#first-admin-password-help", "Use 12–72 characters.")

      assert has_element?(
               view,
               ~s(#first-admin-password[aria-describedby="first-admin-password-help"])
             )

      assert has_element?(
               view,
               "#first-admin-password-confirmation-help",
               "Must match the password above."
             )

      refute has_element?(
               view,
               "#first-admin-password-confirmation-help",
               "Use 12–72 characters."
             )

      assert has_element?(
               view,
               "#first-admin-organization-alias-help",
               "Leave blank to generate it from the organization name."
             )

      alias_help_html = view |> element("#first-admin-organization-alias-help") |> render()
      refute alias_help_html =~ "/gtfs/"

      assert has_element?(view, "#first-admin-submit", "Create administrator account")

      assert has_element?(
               view,
               ~s(#first-admin-submit[phx-disable-with="Creating account…"])
             )

      assert has_element?(view, ~s(#first_admin_form[class~="phx-submit-loading:opacity-60"]))
      refute has_element?(view, ~s(#first-admin-submit[class~="phx-submit-loading:opacity-60"]))
    end
  end

  describe "blur validation" do
    test "untouched controls stay clean while the blurred control validates", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/first")

      for control_id <- @field_control_ids do
        assert has_element?(view, ~s(##{control_id}[aria-invalid="false"]))
        refute has_element?(view, "##{control_id}-error")
      end

      view
      |> element("#first-admin-email")
      |> render_blur(%{
        "admin" => %{
          "email" => "not-an-email",
          "_unused_password" => "",
          "_unused_password_confirmation" => "",
          "_unused_organization_name" => "",
          "_unused_organization_alias" => ""
        }
      })

      assert has_element?(view, ~s(#first-admin-email[aria-invalid="true"]))
      assert has_element?(view, "#first-admin-email-error")

      for control_id <- @field_control_ids -- ["first-admin-email"] do
        assert has_element?(view, ~s(##{control_id}[aria-invalid="false"]))
        refute has_element?(view, "##{control_id}-error")
      end

      refute has_element?(view, @summary_selector)
      refute_push_event(view, "focus_first_admin_error", %{})
    end

    test "a metadata-only blur event is a safe no-op", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/first")

      view |> element("#first-admin-email") |> render_blur()

      for control_id <- @field_control_ids do
        assert has_element?(view, ~s(##{control_id}[aria-invalid="false"]))
        refute has_element?(view, "##{control_id}-error")
      end

      assert has_element?(view, ~s(#first_admin_form[phx-submit="setup"]))
      refute has_element?(view, @summary_selector)
      refute_push_event(view, "focus_first_admin_error", %{})
    end

    test "a used but blank optional alias stays truthful on blur", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/first")

      view
      |> element("#first-admin-organization-alias")
      |> render_blur(%{
        "admin" => %{
          "organization_alias" => "",
          "organization_name" => "My Transit Agency",
          "_unused_email" => "",
          "_unused_password" => "",
          "_unused_password_confirmation" => ""
        }
      })

      assert has_element?(view, ~s(#first-admin-organization-alias[aria-invalid="false"]))
      refute has_element?(view, "#first-admin-organization-alias-error")
      refute has_element?(view, @summary_selector)
    end
  end

  describe "change validation" do
    test "shows errors only for used inputs and pushes no focus event", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/first")

      view
      |> element("#first_admin_form")
      |> render_change(%{
        "admin" => %{
          "_unused_email" => "",
          "email" => "",
          "password" => "secret-pw-1",
          "_unused_password_confirmation" => "",
          "password_confirmation" => "",
          "_unused_organization_name" => "",
          "organization_name" => "",
          "_unused_organization_alias" => "",
          "organization_alias" => ""
        }
      })

      assert has_element?(view, ~s(#first-admin-password[aria-invalid="true"]))
      assert has_element?(view, "#first-admin-password-error")

      assert has_element?(view, ~s(#first-admin-email[aria-invalid="false"]))
      refute has_element?(view, "#first-admin-email-error")
      refute has_element?(view, "#first-admin-password-confirmation-error")
      refute has_element?(view, "#first-admin-organization-name-error")
      refute has_element?(view, "#first-admin-organization-alias-error")

      refute has_element?(view, @summary_selector)
      refute_push_event(view, "focus_first_admin_error", %{})
    end

    test "clears the failed-submit summary and stale secret errors on the next change", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/first")

      view |> element("#first_admin_form") |> render_submit(%{"admin" => @all_invalid_params})

      assert has_element?(view, @summary_selector)

      assert has_element?(
               view,
               "#first-admin-password-error",
               "should be at least 12 character(s)"
             )

      assert_push_event(view, "focus_first_admin_error", %{})

      view
      |> element("#first_admin_form")
      |> render_change(%{"admin" => %{"email" => "admin@example.com"}})

      refute has_element?(view, @summary_selector)

      refute has_element?(
               view,
               "#first-admin-password-error",
               "should be at least 12 character(s)"
             )

      refute_push_event(view, "focus_first_admin_error", %{})
    end
  end

  describe "failed submit recovery" do
    test "renders one fixed-order summary linked to the invalid controls", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/first")

      view |> element("#first_admin_form") |> render_submit(%{"admin" => @all_invalid_params})

      assert has_element?(
               view,
               ~s(#{@summary_selector}[tabindex="-1"][aria-labelledby="first-admin-error-summary-title"])
             )

      assert has_element?(view, "#first-admin-error-summary-title", @summary_title)

      summary_html = view |> element(@summary_selector) |> render()
      refute summary_html =~ "role="
      refute summary_html =~ "aria-live"

      hrefs =
        summary_html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("a")
        |> LazyHTML.attribute("href")

      assert hrefs == Enum.map(@field_control_ids, &("#" <> &1))

      for control_id <- @field_control_ids do
        assert has_element?(view, ~s(##{control_id}[aria-invalid="true"]))
      end
    end

    test "associates non-live inline errors with their controls", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/first")

      view |> element("#first_admin_form") |> render_submit(%{"admin" => @all_invalid_params})

      assert has_element?(
               view,
               ~s(#first-admin-email[aria-describedby="first-admin-email-error"])
             )

      assert has_element?(
               view,
               ~s(#first-admin-organization-alias[aria-describedby="first-admin-organization-alias-help first-admin-organization-alias-error"])
             )

      assert has_element?(
               view,
               "#first-admin-password-confirmation-error",
               "does not match password"
             )

      for control_id <- @field_control_ids do
        error_html = view |> element("##{control_id}-error") |> render()
        refute error_html =~ "role="
        refute error_html =~ "aria-live"
      end
    end

    test "preserves non-secret values and clears both secrets", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/first")

      view
      |> element("#first_admin_form")
      |> render_submit(%{
        "admin" => %{
          "email" => "admin@example.com",
          "password" => "secret-pw-1",
          "password_confirmation" => "secret-pw-1",
          "organization_name" => "My Transit Agency",
          "organization_alias" => "my-transit-agency"
        }
      })

      assert has_element?(view, ~s(#first-admin-email[value="admin@example.com"]))
      assert has_element?(view, ~s(#first-admin-organization-name[value="My Transit Agency"]))

      assert has_element?(
               view,
               ~s(#first-admin-organization-alias[value="my-transit-agency"])
             )

      assert has_element?(view, ~s(#first-admin-password[aria-invalid="true"]))

      password_html = view |> element("#first-admin-password") |> render()
      confirmation_html = view |> element("#first-admin-password-confirmation") |> render()
      refute password_html =~ "value="
      refute confirmation_html =~ "value="
      refute render(view) =~ "secret-pw-1"

      assert has_element?(view, "#first-admin-submit")
    end

    test "pushes exactly one focus event per failed submit", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/first")

      view |> element("#first_admin_form") |> render_submit(%{"admin" => @all_invalid_params})

      assert_push_event(view, "focus_first_admin_error", %{})
      refute_push_event(view, "focus_first_admin_error", %{})
    end
  end

  describe "base-only summary fallback" do
    test "render/1 exposes the focusable summary without invalid controls or field links" do
      changeset =
        %{
          "email" => "admin@example.com",
          "password" => "valid password 123",
          "password_confirmation" => "valid password 123",
          "organization_name" => "Demo Org",
          "organization_alias" => "demo-org"
        }
        |> Accounts.change_first_admin()
        |> Ecto.Changeset.add_error(:base, @base_message)
        |> Map.put(:action, :insert)
        |> FirstAdminForm.sanitize_secrets()

      assigns = %{
        flash: %{},
        form: Phoenix.Component.to_form(changeset, as: :admin),
        summary_entries: [%{target: nil, message: @base_message}],
        password_errors: [],
        password_confirmation_errors: []
      }

      html = rendered_to_string(FirstAdminLive.render(assigns))
      document = LazyHTML.from_fragment(html)

      summary =
        LazyHTML.query(
          document,
          ~s(#{@summary_selector}[tabindex="-1"][aria-labelledby="first-admin-error-summary-title"])
        )

      assert LazyHTML.attribute(summary, "id") == ["first-admin-error-summary"]

      summary_links = summary |> LazyHTML.query("a") |> LazyHTML.to_tree()
      assert summary_links == []

      invalid_controls =
        document
        |> LazyHTML.query(~s([aria-invalid="true"]))
        |> LazyHTML.to_tree()

      assert invalid_controls == []

      summary_text =
        summary
        |> LazyHTML.text()
        |> String.replace(~r/\s+/, " ")

      assert summary_text =~ @summary_title
      assert summary_text =~ @base_message
    end
  end

  describe "retry integration" do
    test "redirects to / when a user already exists without rendering the setup form", %{
      conn: conn
    } do
      user_fixture()

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/first")
    end

    test "redirects a valid first submit to login with the administrator-created message",
         %{conn: conn} do
      admin_params = valid_admin_params()
      {:ok, view, _html} = live(conn, ~p"/first")

      result =
        view
        |> element("#first_admin_form")
        |> render_submit(%{"admin" => admin_params})

      assert {:error, {:redirect, %{to: "/users/log_in"}}} = result

      {:ok, conn} = follow_redirect(result, conn)
      assert html_response(conn, 200) =~ "Administrator account created. Log in to continue."
    end

    test "generated-alias collision keeps the optional alias visibly blank and retries",
         %{conn: conn} do
      organization_fixture(%{name: "Existing Org", alias: "my-transit-agency"})
      email = unique_user_email()

      {:ok, view, _html} = live(conn, ~p"/first")

      user_count = Repo.aggregate(User, :count, :id)
      org_count = Repo.aggregate(Organization, :count, :id)

      view
      |> element("#first_admin_form")
      |> render_submit(%{
        "admin" => %{
          "email" => email,
          "password" => "valid setup password 123",
          "password_confirmation" => "valid setup password 123",
          "organization_name" => "My Transit Agency",
          "organization_alias" => ""
        }
      })

      assert has_element?(view, @summary_selector)
      assert has_element?(view, ~s(#{@summary_selector} a[href="#first-admin-organization-alias"]))

      assert has_element?(
               view,
               ~s(#first-admin-organization-alias[aria-invalid="true"])
             )

      assert has_element?(view, "#first-admin-organization-alias-error")

      alias_values =
        view
        |> element("#first-admin-organization-alias")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#first-admin-organization-alias")
        |> LazyHTML.attribute("value")

      assert alias_values == [""]

      assert has_element?(view, ~s(#first-admin-email[value="#{email}"]))

      assert has_element?(
               view,
               ~s(#first-admin-organization-name[value="My Transit Agency"])
             )

      assert Repo.aggregate(User, :count, :id) == user_count
      assert Repo.aggregate(Organization, :count, :id) == org_count

      assert_push_event(view, "focus_first_admin_error", %{})

      assert {:error, {:redirect, %{to: "/users/log_in"}}} =
               view
               |> element("#first_admin_form")
               |> render_submit(%{
                 "admin" => %{
                   "email" => email,
                   "password" => "valid setup password 123",
                   "password_confirmation" => "valid setup password 123",
                   "organization_name" => "My Transit Agency",
                   "organization_alias" => unique_organization_alias()
                 }
               })

      assert Repo.aggregate(User, :count, :id) == user_count + 1
      assert Repo.aggregate(Organization, :count, :id) == org_count + 1
    end

    test "persists exactly one record set when an invalid submit is corrected in the same view",
         %{conn: conn} do
      admin_params = valid_admin_params()
      {:ok, view, _html} = live(conn, ~p"/first")

      user_count = Repo.aggregate(User, :count, :id)
      org_count = Repo.aggregate(Organization, :count, :id)
      version_count = Repo.aggregate(GtfsVersion, :count, :id)
      membership_count = Repo.aggregate(UserOrgMembership, :count, :id)

      invalid_response =
        view |> element("#first_admin_form") |> render_submit(%{"admin" => @all_invalid_params})

      assert is_binary(invalid_response)
      assert has_element?(view, @summary_selector)
      assert has_element?(view, ~s(#first_admin_form[phx-submit="setup"]))

      assert {:error, {:redirect, %{to: "/users/log_in"}}} =
               view
               |> element("#first_admin_form")
               |> render_submit(%{"admin" => admin_params})

      assert Repo.aggregate(User, :count, :id) == user_count + 1
      assert Repo.aggregate(Organization, :count, :id) == org_count + 1
      assert Repo.aggregate(GtfsVersion, :count, :id) == version_count + 1
      assert Repo.aggregate(UserOrgMembership, :count, :id) == membership_count + 1
    end

    test "rolls back a failed transaction submit and persists only the corrected retry", %{
      conn: conn
    } do
      admin_params = valid_admin_params()
      taken_alias = "taken-#{System.unique_integer([:positive])}"
      organization_fixture(%{name: "Existing Org", alias: taken_alias})

      {:ok, view, _html} = live(conn, ~p"/first")

      user_count = Repo.aggregate(User, :count, :id)
      org_count = Repo.aggregate(Organization, :count, :id)
      version_count = Repo.aggregate(GtfsVersion, :count, :id)
      membership_count = Repo.aggregate(UserOrgMembership, :count, :id)

      rollback_response =
        view
        |> element("#first_admin_form")
        |> render_submit(%{
          "admin" => %{admin_params | "organization_alias" => taken_alias}
        })

      assert is_binary(rollback_response)
      assert has_element?(view, @summary_selector)
      assert has_element?(view, ~s(#first-admin-organization-alias[aria-invalid="true"]))

      assert {:error, {:redirect, %{to: "/users/log_in"}}} =
               view
               |> element("#first_admin_form")
               |> render_submit(%{"admin" => admin_params})

      assert Repo.aggregate(User, :count, :id) == user_count + 1
      assert Repo.aggregate(Organization, :count, :id) == org_count + 1
      assert Repo.aggregate(GtfsVersion, :count, :id) == version_count + 1
      assert Repo.aggregate(UserOrgMembership, :count, :id) == membership_count + 1
    end
  end

  defp valid_admin_params do
    %{
      "email" => unique_user_email(),
      "password" => "valid setup password 123",
      "password_confirmation" => "valid setup password 123",
      "organization_name" => "My Transit Agency",
      "organization_alias" => unique_organization_alias()
    }
  end
end
