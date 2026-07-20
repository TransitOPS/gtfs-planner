# Creates deterministic browser-test users for Playwright E2E tests.
# This script runs after `MIX_ENV=test mix ecto.reset`, so the database
# is empty and idempotency is unneeded.
#
# User 1 (admin): browser-test@gtfs-planner.test — used by overlays.spec.js
# User 2 (editor): diagram-test@gtfs-planner.test — used by diagram_keyboard.spec.js
# User 3 (org admin): admin-contracts@gtfs-planner.test — used by
#   admin_design_contracts.spec.js, together with its own "Admin Contracts Org"
#   and its deterministic active/deactivated/pending/multi-role/long-email members.
#
# Both users belong to the same org. The editor user can access GTFS routes
# because it has the pathways_studio_editor role and a session-scoped
# organization (non-admin bypasses the admin org-skip in AssignOrganization).
#
# Also creates a seeded station with a level, floorplan, and positioned
# child stops so the diagram route renders a keyboard-accessible canvas.
#
# Credentials are test-only and must not appear in application config.

alias GtfsPlanner.Accounts
alias GtfsPlanner.Accounts.User
alias GtfsPlanner.Accounts.UserToken
alias GtfsPlanner.Gtfs
alias GtfsPlanner.Organizations
alias GtfsPlanner.Repo
alias GtfsPlanner.Versions

import Ecto.Query

# ── Admin user (existing, used by overlays.spec.js) ──
case Accounts.register_first_admin(%{
       email: "browser-test@gtfs-planner.test",
       password: "BrowserTest123!",
       password_confirmation: "BrowserTest123!",
       organization_name: "Browser Test Org",
       organization_alias: "browser-test"
     }) do
  {:ok, user} ->
    IO.puts("Browser seed: created admin #{user.email} (id=#{user.id})")

    # Fetch the org and version created by register_first_admin
    [org] = Organizations.list_organizations_for_user(user.id)
    IO.puts("Browser seed: org #{org.name} (id=#{org.id})")

    # The default version created by register_first_admin is in staging status.
    # GTFS routes only work with published versions. Create a published version
    # for the browser e2e tests.
    {:ok, diagram_version} =
      Versions.create_gtfs_version(org.id, %{name: "Browser E2E Version"})

    IO.puts("Browser seed: published version #{diagram_version.name} (id=#{diagram_version.id})")

    # ── Editor user (for GTFS diagram keyboard test) ──
    editor_attrs = %{
      email: "diagram-test@gtfs-planner.test",
      password: "DiagramTest123!"
    }

    {:ok, editor} = Accounts.register_user(editor_attrs)
    # Confirm the editor user so they can log in
    Repo.update!(User.confirm_changeset(editor))

    Accounts.create_user_org_membership(%{
      user_id: editor.id,
      organization_id: org.id,
      roles: ["pathways_studio_editor"]
    })

    IO.puts("Browser seed: created editor #{editor.email} (id=#{editor.id})")

    # ── Station diagram seed data ──
    {:ok, station} =
      Gtfs.create_stop(%{
        stop_id: "BROWSER_STATION",
        stop_name: "Browser Test Station",
        location_type: 1,
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    IO.puts("Browser seed: station #{station.stop_id}")

    {:ok, level} =
      Gtfs.create_level(%{
        level_id: "BROWSER_L1",
        level_name: "Browser Level 1",
        level_index: 0.0,
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    {:ok, stop_level} =
      Gtfs.create_stop_level(%{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        stop_id: station.id,
        level_id: level.id,
        diagram_filename: "browser_seed_diagram.png"
      })

    IO.puts("Browser seed: stop_level #{stop_level.id} with diagram")

    # Create child stops with diagram coordinates
    {:ok, _child_a} =
      Gtfs.create_stop(%{
        stop_id: "BROWSER_STOP_A",
        stop_name: "Platform A North",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: level.level_id,
        diagram_coordinate: %{"x" => 30, "y" => 40},
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    {:ok, _child_b} =
      Gtfs.create_stop(%{
        stop_id: "BROWSER_STOP_B",
        stop_name: "Platform B South",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: level.level_id,
        diagram_coordinate: %{"x" => 70, "y" => 60},
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    IO.puts("Browser seed: child stops placed on diagram")

    {:ok, _child_c} =
      Gtfs.create_stop(%{
        stop_id: "BROWSER_STOP_C",
        stop_name: "Entrance C",
        location_type: 2,
        parent_station: station.stop_id,
        level_id: level.level_id,
        diagram_coordinate: %{"x" => 50, "y" => 25},
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    IO.puts(
      "Browser seed: diagram ready — /gtfs/#{diagram_version.id}/stops/BROWSER_STATION/diagram"
    )

    # ── Long-name fixtures for responsive data-view browser tests ──
    {:ok, _long_org} =
      Organizations.create_organization(%{
        name: "Metropolitan Regional Transit Authority of the Greater Metropolitan Area",
        alias: "metro-regional-transit-authority-greater-metropolitan-area"
      })

    IO.puts("Browser seed: long-name organization for reflow tests")

    Enum.each(1..3, fn idx ->
      {:ok, _long_route} =
        Gtfs.create_route(%{
          organization_id: org.id,
          gtfs_version_id: diagram_version.id,
          route_id: "LONG_ROUTE_#{idx}",
          route_short_name:
            "Express Route #{idx} — Downtown to University District via Waterfront and Convention Center",
          route_long_name:
            "Metropolitan Express Route #{idx} connecting Downtown Transit Center to University District via Waterfront Promenade, Convention Center, and Medical Campus",
          route_type: 3,
          route_color: "FF5733"
        })
    end)

    IO.puts("Browser seed: long-name routes for reflow tests")

# ── Auth fixtures for authentication.spec.js (Package 10) ──
    #
    # Deterministic, test-only token fixtures. Each raw value is a fixed
    # 32-byte binary; only its SHA-256 digest is persisted (production-shaped
    # `%UserToken{token: <digest>}`), and the unpadded URL-safe Base64 of the
    # raw value is mirrored verbatim in assets/e2e/authentication.spec.js so
    # token URLs are reproducible without parsing mail or passing seed output
    # between processes. One user/token per destructive case; expired rows are
    # backdated beyond their context validity window (reset_password 1 day,
    # confirm/invite 7 days). The replay cases reuse the valid token URL after
    # the valid case consumes it, proving one-use semantics.
    auth_insert_token = fn user, context, encoded, backdate ->
      raw = Base.url_decode64!(encoded, padding: false)
      digest = :crypto.hash(:sha256, raw)

      token =
        Repo.insert!(%UserToken{
          token: digest,
          context: context,
          sent_to: user.email,
          user_id: user.id
        })

      if backdate do
        # update_all bypasses timestamp autogenerate so the expired row keeps
        # its deterministic past inserted_at.
        {1, _} =
          from(t in GtfsPlanner.Accounts.UserToken, where: t.id == ^token.id)
          |> Repo.update_all(set: [inserted_at: backdate])
      end

      token
    end

    auth_now = DateTime.utc_now()
    # Beyond the 1-day reset_password window.
    auth_expired_reset = DateTime.add(auth_now, -2, :day)
    # Beyond the 7-day confirm/invite window.
    auth_expired_week = DateTime.add(auth_now, -8, :day)

    # Login recovery: deactivated member (valid credentials, deactivated membership).
    {:ok, auth_deactivated} =
      Accounts.register_user(%{
        email: "auth-deactivated@gtfs-planner.test",
        password: "AuthDeactivated123!"
      })

    Repo.update!(User.confirm_changeset(auth_deactivated))

    {:ok, _auth_deactivated_membership} =
      Accounts.create_user_org_membership(%{
        user_id: auth_deactivated.id,
        organization_id: org.id,
        roles: ["pathways_studio_editor"]
      })

    {:ok, _} = Organizations.deactivate_user_in_organization(auth_deactivated.id, org.id)
    IO.puts("Browser seed: auth deactivated user #{auth_deactivated.email}")

    # Login recovery: confirmed user with no organization membership.
    {:ok, auth_noorg} =
      Accounts.register_user(%{
        email: "auth-noorg@gtfs-planner.test",
        password: "AuthNoOrg123!"
      })

    Repo.update!(User.confirm_changeset(auth_noorg))
    IO.puts("Browser seed: auth no-org user #{auth_noorg.email}")

    # Reset password: valid (consumed by the success case, replayed after).
    {:ok, auth_reset} =
      Accounts.register_user(%{
        email: "auth-reset@gtfs-planner.test",
        password: "AuthReset123!"
      })

    Repo.update!(User.confirm_changeset(auth_reset))

    auth_insert_token.(
      auth_reset,
      "reset_password",
      "YXV0aC1yZXNldC12YWxpZDAwMDAwMDAwMDAwMDAwMDA",
      nil
    )

    IO.puts("Browser seed: auth reset user #{auth_reset.email}")

    # Reset password: expired token (backdated beyond the 1-day window).
    {:ok, auth_reset_expired} =
      Accounts.register_user(%{
        email: "auth-reset-expired@gtfs-planner.test",
        password: "AuthResetExpired123!"
      })

    Repo.update!(User.confirm_changeset(auth_reset_expired))

    auth_insert_token.(
      auth_reset_expired,
      "reset_password",
      "YXV0aC1yZXNldC1leHBpcmVkMDAwMDAwMDAwMDAwMDA",
      auth_expired_reset
    )

    IO.puts("Browser seed: auth reset-expired user #{auth_reset_expired.email}")

    # Confirmation: valid (unconfirmed user; consumed by the success case, replayed after).
    {:ok, auth_confirm} =
      Accounts.register_user(%{
        email: "auth-confirm@gtfs-planner.test",
        password: "AuthConfirm123!"
      })

    auth_insert_token.(
      auth_confirm,
      "confirm",
      "YXV0aC1jb25maXJtLXZhbGlkMDAwMDAwMDAwMDAwMDA",
      nil
    )

    IO.puts("Browser seed: auth confirm user #{auth_confirm.email}")

    # Confirmation: expired token (backdated beyond the 7-day window).
    {:ok, auth_confirm_expired} =
      Accounts.register_user(%{
        email: "auth-confirm-expired@gtfs-planner.test",
        password: "AuthConfirmExpired123!"
      })

    auth_insert_token.(
      auth_confirm_expired,
      "confirm",
      "YXV0aC1jb25maXJtLWV4cGlyZWQwMDAwMDAwMDAwMDA",
      auth_expired_week
    )

    IO.puts("Browser seed: auth confirm-expired user #{auth_confirm_expired.email}")

    # Invitation: valid (invited user without a password; consumed, then replayed).
    {:ok, auth_invite} =
      %User{}
      |> User.invite_changeset(%{email: "auth-invite@gtfs-planner.test"})
      |> Repo.insert()

    auth_insert_token.(auth_invite, "invite", "YXV0aC1pbnZpdGUtdmFsaWQwMDAwMDAwMDAwMDAwMDA", nil)
    IO.puts("Browser seed: auth invite user #{auth_invite.email}")

    # Invitation: expired token (backdated beyond the 7-day window).
    {:ok, auth_invite_expired} =
      %User{}
      |> User.invite_changeset(%{email: "auth-invite-expired@gtfs-planner.test"})
      |> Repo.insert()

    auth_insert_token.(
      auth_invite_expired,
      "invite",
      "YXV0aC1pbnZpdGUtZXhwaXJlZDAwMDAwMDAwMDAwMDA",
      auth_expired_week
    )

    IO.puts("Browser seed: auth invite-expired user #{auth_invite_expired.email}")

    # ── Administration design-contract fixtures (admin_design_contracts.spec.js) ──
    #
    # A dedicated organization keeps every administration mutation away from the
    # organizations used by the other browser specs. The administrator below holds
    # only `pathways_studio_admin`, so `AssignOrganization` resolves this
    # organization from the session (the system-`administrator` org-skip does not
    # apply) and `/admin/users` is scoped to it.
    {:ok, admin_org} =
      Organizations.create_organization(%{
        name: "Admin Contracts Org",
        alias: "admin-contracts"
      })

    {:ok, org_admin} =
      Accounts.register_user(%{
        email: "admin-contracts@gtfs-planner.test",
        password: "AdminContracts123!"
      })

    Repo.update!(User.confirm_changeset(org_admin))

    {:ok, _org_admin_membership} =
      Accounts.create_user_org_membership(%{
        user_id: org_admin.id,
        organization_id: admin_org.id,
        roles: ["pathways_studio_admin"]
      })

    IO.puts("Browser seed: created organization admin #{org_admin.email} (id=#{org_admin.id})")

    # An accepted member has a password. `Admin.Components.member_status/1` derives
    # "Invitation pending" from a nil `hashed_password`, so accepted fixtures must
    # be registered and pending fixtures must go through `User.invite_changeset/2`.
    add_accepted_member = fn email, roles ->
      {:ok, member} = Accounts.register_user(%{email: email, password: "ContractsMember123!"})
      Repo.update!(User.confirm_changeset(member))

      {:ok, _membership} =
        Accounts.create_user_org_membership(%{
          user_id: member.id,
          organization_id: admin_org.id,
          roles: roles
        })

      member
    end

    _active_member =
      add_accepted_member.("contracts-active@gtfs-planner.test", ["pathways_studio_editor"])

    _multi_role_member =
      add_accepted_member.("contracts-multirole@gtfs-planner.test", [
        "pathways_studio_admin",
        "pathways_studio_editor"
      ])

    # Long local part and long domain, for reflow and target-size measurement.
    _long_email_member =
      add_accepted_member.(
        "contracts-very-long-email-address-for-responsive-verification@long-domain-name-for-administration.gtfs-planner.test",
        ["pathways_studio_editor"]
      )

    # Dedicated destructive target: the deactivation-confirmation workflow owns
    # this row and restores it, so the file stays re-runnable.
    _deactivation_target =
      add_accepted_member.("contracts-deactivate-target@gtfs-planner.test", [
        "pathways_studio_editor"
      ])

    # Already deactivated, so the "Activate user" row action is present on load.
    deactivated_member =
      add_accepted_member.("contracts-deactivated@gtfs-planner.test", ["pathways_studio_editor"])

    {:ok, _deactivated_membership} =
      Organizations.deactivate_user_in_organization(deactivated_member.id, admin_org.id)

    # Invitation pending: `invite_user/2` uses `User.invite_changeset/2`, which
    # sets no password, so the row renders "Invitation pending" and offers
    # "Resend invite".
    {:ok, pending_member} =
      Accounts.invite_user("contracts-pending@gtfs-planner.test", admin_org.id)

    {:ok, _pending_membership} =
      Accounts.create_user_org_membership(%{
        user_id: pending_member.id,
        organization_id: admin_org.id,
        roles: ["pathways_studio_editor"]
      })

    IO.puts(
      "Browser seed: administration fixtures in #{admin_org.name} (id=#{admin_org.id}) — " <>
        "active, multi-role, long-email, deactivate-target, deactivated, invitation-pending"
    )

  {:error, changeset} ->
    raise "Browser seed failed: #{inspect(changeset.errors)}"
end
