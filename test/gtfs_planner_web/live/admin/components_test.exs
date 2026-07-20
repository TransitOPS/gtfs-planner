defmodule GtfsPlannerWeb.Admin.ComponentsTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import GtfsPlannerWeb.Admin.Components

  alias GtfsPlanner.Accounts.User
  alias GtfsPlannerWeb.Admin.Components
  alias Phoenix.LiveView.LiveStream

  @active_id "11111111-1111-1111-1111-111111111111"
  @pending_id "22222222-2222-2222-2222-222222222222"
  @deactivated_id "33333333-3333-3333-3333-333333333333"

  defp active_member do
    %{
      user: %User{
        id: @active_id,
        email: "active@example.com",
        hashed_password: "hashed"
      },
      roles: ["pathways_studio_admin"],
      deactivated_at: nil
    }
  end

  defp pending_member do
    %{
      user: %User{id: @pending_id, email: "pending@example.com", hashed_password: nil},
      roles: ["pathways_studio_editor"],
      deactivated_at: nil
    }
  end

  defp deactivated_member do
    %{
      user: %User{
        id: @deactivated_id,
        email: "deactivated@example.com",
        hashed_password: "hashed"
      },
      roles: ["pathways_studio_admin", "pathways_studio_editor"],
      deactivated_at: ~U[2026-02-01 00:00:00Z]
    }
  end

  defp render_view(members, overrides \\ %{}) do
    assigns =
      Map.merge(
        %{
          id: "members",
          members: members,
          empty?: members == [],
          invite_path: "/admin/users/invite",
          resend_event: "resend_invite",
          activate_event: "activate_user",
          deactivate_event: "request_deactivation"
        },
        overrides
      )

    rendered_to_string(~H"""
    <.member_data_view
      id={@id}
      members={@members}
      empty?={@empty?}
      invite_path={@invite_path}
      resend_event={@resend_event}
      activate_event={@activate_event}
      deactivate_event={@deactivate_event}
    />
    """)
  end

  defp doc(html), do: LazyHTML.from_fragment(html)

  describe "member_data_view/1 — one shared table representation" do
    test "renders one stacked semantic table with one tbody and one row per member" do
      html = render_view([active_member(), deactivated_member()])

      document = doc(html)

      assert Enum.count(LazyHTML.query(document, "table")) == 1
      assert Enum.count(LazyHTML.query(document, "tbody")) == 1
      assert Enum.count(LazyHTML.query(document, "tbody#members > tr")) == 2

      assert LazyHTML.attribute(LazyHTML.query(document, "table"), "class") |> List.first() =~
               "ds-stack-table"
    end

    test "derives stable member-<user-id> row IDs from the user ID alone" do
      html = render_view([active_member(), deactivated_member()])

      document = doc(html)

      assert Enum.count(LazyHTML.query(document, "tr#member-#{@active_id}")) == 1
      assert Enum.count(LazyHTML.query(document, "tr#member-#{@deactivated_id}")) == 1
    end

    test "uses the same row ID contract for a LiveStream as for a static list" do
      # The real struct `stream/3` puts in `@streams.members`, built directly
      # because `stream/3` needs a mounted socket a component test cannot produce.
      stream =
        LiveStream.new(
          :members,
          0,
          [active_member(), pending_member()],
          dom_id: &member_dom_id/1
        )

      html = render_view(stream, %{empty?: false})

      document = doc(html)

      assert LazyHTML.attribute(LazyHTML.query(document, "tbody#members"), "phx-update") == [
               "stream"
             ]

      assert Enum.count(LazyHTML.query(document, "tr#member-#{@active_id}")) == 1
      assert Enum.count(LazyHTML.query(document, "tr#member-#{@pending_id}")) == 1
    end

    test "exports the row ID contract so parents stream under the same IDs" do
      assert member_dom_id(active_member()) == "member-#{@active_id}"
    end

    test "shows the member email as the row identifier" do
      html = render_view([active_member()])

      assert html =~ "active@example.com"
    end

    test "renders at most two actions per row" do
      html = render_view([active_member(), pending_member(), deactivated_member()])

      document = doc(html)

      for row_id <- [@active_id, @pending_id, @deactivated_id] do
        assert Enum.count(LazyHTML.query(document, "tr#member-#{row_id} button")) <= 2
      end
    end
  end

  describe "member_data_view/1 — status precedence and role neutrality" do
    test "renders Active for a confirmed member who is not deactivated" do
      html = render_view([active_member()])

      assert row_status(html, @active_id) == "Active"
    end

    test "renders Invitation pending for a member who has not accepted the invitation" do
      html = render_view([pending_member()])

      assert row_status(html, @pending_id) == "Invitation pending"
    end

    test "prefers Deactivated over Invitation pending for a deactivated unaccepted member" do
      member = %{
        deactivated_member()
        | user: %User{deactivated_member().user | hashed_password: nil}
      }

      html = render_view([member])

      assert row_status(html, @deactivated_id) == "Deactivated"
    end

    test "renders status through the shared badge, as colour plus text" do
      html = render_view([deactivated_member()])

      document = doc(html)
      badge = LazyHTML.query(document, "tr#member-#{@deactivated_id} [data-role=member-status]")

      assert Enum.count(LazyHTML.query(badge, "span[aria-hidden=true]")) == 1
      assert LazyHTML.text(badge) =~ "Deactivated"
      refute LazyHTML.attribute(badge, "class") |> List.first() =~ "badge-error"
    end

    test "renders canonical role labels as neutral chips, never as status badges" do
      html = render_view([deactivated_member()])

      document = doc(html)
      roles = LazyHTML.query(document, "tr#member-#{@deactivated_id} [data-role=member-role]")

      assert Enum.count(roles) == 2
      assert LazyHTML.text(roles) =~ "Pathways Studio Admin"
      assert LazyHTML.text(roles) =~ "Pathways Studio Editor"

      for class <- LazyHTML.attribute(roles, "class") do
        refute class =~ "text-success"
        refute class =~ "text-error"
        refute class =~ "text-warning"
      end
    end

    test "falls back to the raw value for an unknown role rather than crashing" do
      member = %{active_member() | roles: ["not_a_role"]}

      html = render_view([member])

      assert doc(html)
             |> LazyHTML.query("tr#member-#{@active_id} [data-role=member-role]")
             |> LazyHTML.text() =~ "not_a_role"
    end
  end

  describe "member_data_view/1 — row actions" do
    test "offers Resend invite and Deactivate user for an invitation-pending member" do
      html = render_view([pending_member()])

      document = doc(html)

      assert Enum.count(LazyHTML.query(document, "#resend-invite-#{@pending_id}")) == 1
      assert Enum.count(LazyHTML.query(document, "#deactivate-user-#{@pending_id}")) == 1
      assert Enum.empty?(LazyHTML.query(document, "#activate-user-#{@pending_id}"))
    end

    test "offers only Deactivate user for an active member" do
      html = render_view([active_member()])

      document = doc(html)

      assert Enum.count(LazyHTML.query(document, "#deactivate-user-#{@active_id}")) == 1
      assert Enum.empty?(LazyHTML.query(document, "#resend-invite-#{@active_id}"))
      assert Enum.empty?(LazyHTML.query(document, "#activate-user-#{@active_id}"))
    end

    test "offers only Activate user for a deactivated member" do
      html = render_view([deactivated_member()])

      document = doc(html)

      assert Enum.count(LazyHTML.query(document, "#activate-user-#{@deactivated_id}")) == 1
      assert Enum.empty?(LazyHTML.query(document, "#deactivate-user-#{@deactivated_id}"))
      assert Enum.empty?(LazyHTML.query(document, "#resend-invite-#{@deactivated_id}"))
    end

    test "emits the parent event names and the user ID as the only event value" do
      html =
        render_view([pending_member()], %{
          resend_event: "parent_resend",
          activate_event: "parent_activate",
          deactivate_event: "parent_deactivate"
        })

      document = doc(html)
      resend = LazyHTML.query(document, "#resend-invite-#{@pending_id}")
      deactivate = LazyHTML.query(document, "#deactivate-user-#{@pending_id}")

      assert LazyHTML.attribute(resend, "phx-click") == ["parent_resend"]
      assert LazyHTML.attribute(resend, "phx-value-user-id") == [@pending_id]
      assert LazyHTML.attribute(deactivate, "phx-click") == ["parent_deactivate"]
      assert LazyHTML.attribute(deactivate, "phx-value-user-id") == [@pending_id]
      refute html =~ "parent_activate"
      assert LazyHTML.attribute(resend, "phx-value-email") == []
      assert LazyHTML.attribute(deactivate, "phx-value-email") == []
    end

    test "gives every action an operation-specific pending label that blocks repeat clicks" do
      html = render_view([pending_member()])

      document = doc(html)

      assert LazyHTML.attribute(
               LazyHTML.query(document, "#resend-invite-#{@pending_id}"),
               "phx-disable-with"
             ) == ["Resending invite…"]

      assert LazyHTML.attribute(
               LazyHTML.query(document, "#deactivate-user-#{@pending_id}"),
               "phx-disable-with"
             ) == ["Deactivating user…"]
    end

    test "names each action after its own row for assistive technology" do
      html = render_view([deactivated_member()])

      document = doc(html)
      activate = LazyHTML.query(document, "#activate-user-#{@deactivated_id}")

      assert LazyHTML.attribute(activate, "aria-label") == [
               "Activate deactivated@example.com"
             ]

      assert LazyHTML.text(activate) =~ "Activate user"
    end

    test "renders actions through the shared quiet small button at a 44 px target" do
      html = render_view([active_member()])

      class =
        doc(html)
        |> LazyHTML.query("#deactivate-user-#{@active_id}")
        |> LazyHTML.attribute("class")
        |> List.first()

      assert class =~ "btn"
      assert class =~ "btn-sm"
      assert class =~ "btn-ghost"
      assert class =~ "min-h-11"
    end
  end

  describe "member_data_view/1 — empty state" do
    test "renders one explanatory empty state with the context invite CTA instead of a table" do
      html = render_view([], %{invite_path: "/admin/organizations/abc/invite"})

      document = doc(html)

      assert Enum.empty?(LazyHTML.query(document, "table"))
      assert Enum.count(LazyHTML.query(document, "#members-empty")) == 1
      assert LazyHTML.text(LazyHTML.query(document, "#members-empty")) =~ "No members yet"
      assert Enum.count(LazyHTML.query(document, "#members-empty a")) == 1

      assert LazyHTML.attribute(LazyHTML.query(document, "#members-empty a"), "href") == [
               "/admin/organizations/abc/invite"
             ]
    end

    test "omits the CTA when the parent supplies no invite path" do
      html = render_view([], %{invite_path: nil})

      document = doc(html)

      assert Enum.count(LazyHTML.query(document, "#members-empty")) == 1
      assert Enum.empty?(LazyHTML.query(document, "#members-empty a"))
    end

    test "renders the table and no empty state when members exist" do
      html = render_view([active_member()])

      document = doc(html)

      assert Enum.empty?(LazyHTML.query(document, "#members-empty"))
      assert Enum.count(LazyHTML.query(document, "table")) == 1
    end
  end

  describe "member_data_view/1 — stateless contract" do
    test "is a function component with no LiveComponent lifecycle or event ownership" do
      exports = Components.__info__(:functions)

      assert {:member_data_view, 1} in exports
      refute {:mount, 1} in exports
      refute {:update, 2} in exports
      refute {:handle_event, 3} in exports
    end

    test "renders identical markup for the same input, holding no state between calls" do
      first = render_view([active_member(), pending_member()])
      second = render_view([active_member(), pending_member()])

      assert first == second
    end
  end

  defp row_status(html, user_id) do
    html
    |> doc()
    |> LazyHTML.query("tr#member-#{user_id} [data-role=member-status]")
    |> LazyHTML.text()
    |> String.trim()
  end
end
