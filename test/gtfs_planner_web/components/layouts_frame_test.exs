defmodule GtfsPlannerWeb.Components.LayoutsFrameTest do
  # EV-25: the wide workspace frame (CL-25, AC-31). The standard frame must stay
  # byte-identical to the pre-frame markup, and only the Blocks page opts into
  # the wide frame. The routes page is the control that keeps the 1280 px cap.
  #
  # The focused gate command is deferred to branch review:
  # `mix test test/gtfs_planner_web/components/layouts_frame_test.exs`.
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlannerWeb.Layouts

  @wide_class "max-w-[1920px]"
  @standard_class "max-w-7xl"

  defp editor_scope(_context) do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    %{user: user, organization: organization, version: gtfs_version_fixture(organization.id)}
  end

  defp render_app(frame) do
    user = %GtfsPlanner.Accounts.User{
      id: Ecto.UUID.generate(),
      email: "frame-test@gtfs-planner.test",
      confirmed_at: nil
    }

    organization = %GtfsPlanner.Organizations.Organization{
      id: Ecto.UUID.generate(),
      name: "Frame Test Org",
      product: :planner
    }

    assigns = %{
      flash: %{},
      current_user: user,
      current_organization: organization,
      user_roles: ["pathways_studio_editor"],
      current_path: "/gtfs/some/blocks",
      current_gtfs_version: nil,
      available_versions: [],
      frame: frame
    }

    rendered_to_string(~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_organization={@current_organization}
      user_roles={@user_roles}
      current_path={@current_path}
      current_gtfs_version={@current_gtfs_version}
      available_versions={@available_versions}
      frame={@frame}
    >
      <:sub_header>
        <p>Sub-header</p>
      </:sub_header>

      <p>Page content</p>
    </Layouts.app>
    """)
  end

  defp classes(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("class")
    |> List.first()
  end

  describe "Layouts.app/1 frame attribute" do
    test "the default frame renders the header, sub-header and main containers exactly as before" do
      html = render_app(:standard)

      # These are the pre-frame class lists, byte for byte. The frame work changed
      # how the class is produced, not what a standard page renders.
      assert classes(html, "#app-brand") =~ "no-underline"

      header_row = classes(html, "#app-header > div > div")
      assert header_row == "mx-auto flex max-w-7xl flex-wrap items-center gap-x-8"

      assert classes(html, "#sub-header-wrapper > div > div") == "mx-auto w-full max-w-7xl"

      assert classes(html, "#main-content > div") == "mx-auto max-w-7xl space-y-4"

      refute html =~ @wide_class
    end

    test "the wide frame replaces the 1280 px cap in all three containers" do
      html = render_app(:wide)

      assert classes(html, "#app-header > div > div") ==
               "mx-auto flex max-w-[1920px] flex-wrap items-center gap-x-8"

      assert classes(html, "#sub-header-wrapper > div > div") == "mx-auto w-full max-w-[1920px]"
      assert classes(html, "#main-content > div") == "mx-auto max-w-[1920px] space-y-4"

      refute html =~ @standard_class
    end

    test "an omitted frame renders the standard frame" do
      user = %GtfsPlanner.Accounts.User{
        id: Ecto.UUID.generate(),
        email: "frame-default@gtfs-planner.test",
        confirmed_at: nil
      }

      organization = %GtfsPlanner.Organizations.Organization{
        id: Ecto.UUID.generate(),
        name: "Frame Default Org",
        product: :planner
      }

      assigns = %{
        flash: %{},
        current_user: user,
        current_organization: organization,
        user_roles: [],
        current_path: "/",
        current_gtfs_version: nil,
        available_versions: []
      }

      html =
        rendered_to_string(~H"""
        <Layouts.app
          flash={@flash}
          current_user={@current_user}
          current_organization={@current_organization}
          user_roles={@user_roles}
          current_path={@current_path}
          current_gtfs_version={@current_gtfs_version}
          available_versions={@available_versions}
        >
          <p>Page content</p>
        </Layouts.app>
        """)

      assert classes(html, "#main-content > div") == "mx-auto max-w-7xl space-y-4"
      refute html =~ @wide_class
    end
  end

  describe "the wide frame on the real routes" do
    setup :editor_scope

    test "Blocks renders its page content in the wide frame", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/blocks")

      doc = LazyHTML.from_fragment(render(view))

      main = doc |> LazyHTML.query("#main-content > div") |> LazyHTML.attribute("class")

      assert main == ["mx-auto max-w-[1920px] space-y-4"]

      # The Blocks page no longer caps its own inner wrapper; the frame owns the
      # width so the header, sub-header and content share one edge.
      assert doc
             |> LazyHTML.query("#blocks-page section > div")
             |> LazyHTML.attribute("class") == ["w-full space-y-4"]

      assert doc
             |> LazyHTML.query("#sub-header-wrapper > div > div")
             |> LazyHTML.attribute("class") == ["mx-auto w-full max-w-[1920px]"]
    end

    test "another Operations page keeps the 1280 px frame", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      doc = LazyHTML.from_fragment(render(view))

      assert doc
             |> LazyHTML.query("#main-content > div")
             |> LazyHTML.attribute("class") == ["mx-auto max-w-7xl space-y-4"]

      refute render(view) =~ @wide_class
    end
  end
end
