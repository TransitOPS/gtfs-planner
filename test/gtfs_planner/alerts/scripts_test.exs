defmodule GtfsPlanner.Alerts.ScriptsTest do
  @moduledoc """
  Step 10: `Alerts` stores an organization's message scripts and writing
  guidelines, validates a template as data rather than code, and reads the
  built-in defaults without writing on read (AC-11, R10, R5).

  Every expected value is a literal from the spec's rules, the prototype's
  script and guideline list (`evidence/prototype/data.js`) and the stable built-in
  keys, never a value recomputed by the modules under test.

  A non-editor fixture passes an empty role list, which
  `organization_membership_fixture/3` accepts and `Alerts` refuses
  (`GtfsPlanner.Authorization.Roles` defines no "viewer" role, and an undefined
  one makes the fixture itself raise before the assertion runs).

  Proof boundary: one local PostgreSQL partition under the SQL Sandbox. It says
  nothing about a second connection racing a save - the guidelines lock and
  `optimistic_lock/2` are exercised here only against the committed row. The
  first-save race is exercised on two connections in `concurrency_test.exs`.
  """

  use GtfsPlanner.DataCase

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Alerts
  alias GtfsPlanner.Alerts.AlertScript
  alias GtfsPlanner.Alerts.AlertSettings
  alias GtfsPlanner.Alerts.BuiltInScripts
  alias GtfsPlanner.Alerts.Message
  alias GtfsPlanner.Gtfs.AuditContext

  @built_in_keys [
    "builtin:detour",
    "builtin:delay",
    "builtin:stop_moved",
    "builtin:stop_closed",
    "builtin:no_service_day",
    "builtin:accessibility",
    "builtin:rider_information",
    "builtin:suspension"
  ]

  @detour_script %{
    "name" => "Detour, stops skipped",
    "situation" => "detour",
    "header_template" => "Route [route] detour: [first skipped] to [last skipped] not served",
    "description_template" =>
      "[when], Route [route] buses [direction] are detoured[because]. " <>
        "Stops from [first skipped] to [last skipped] are not served."
  }

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)
    agency_fixture(organization.id, version.id)

    %{
      organization: organization,
      version: version,
      actor: actor,
      audit: audit_context(organization, version, actor)
    }
  end

  describe "list_scripts/1" do
    test "with no organization scripts it returns the eight built-ins, read-only", context do
      scripts = Alerts.list_scripts(context.audit)

      assert length(scripts) == 8
      assert Enum.map(scripts, & &1.key) == @built_in_keys
      assert Enum.all?(scripts, & &1.built_in?)
      assert Enum.all?(scripts, &is_nil(&1.id))

      # A built-in carries everything a chooser needs: a name, the situation it
      # is offered for and both templates.
      assert Enum.all?(scripts, &(&1.name =~ ~r/\S/))
      assert Enum.all?(scripts, &is_atom(&1.situation))
      assert Enum.all?(scripts, &(&1.header_template =~ ~r/\S/))
      assert Enum.all?(scripts, &(&1.description_template =~ ~r/\S/))

      # Reading the defaults stores nothing.
      assert Repo.aggregate(AlertScript, :count) == 0
    end

    test "the built-in templates use only the placeholder vocabulary", context do
      for script <- Alerts.list_scripts(context.audit) do
        assert Message.unknown_placeholders(script.header_template) == []
        assert Message.unknown_placeholders(script.description_template) == []
      end
    end

    test "organization scripts come first, ordered by position", context do
      {:ok, first} = Alerts.create_script(context.audit, Map.put(@detour_script, "name", "First"))

      {:ok, second} =
        Alerts.create_script(context.audit, Map.put(@detour_script, "name", "Second"))

      {:ok, moved_ahead} =
        Alerts.create_script(context.audit, Map.put(@detour_script, "name", "Ahead"))

      {:ok, ahead} =
        Alerts.update_script(context.audit, moved_ahead.id, %{"position" => 0})

      scripts = Alerts.list_scripts(context.audit)

      assert Enum.map(scripts, & &1.key) ==
               [
                 "org:#{ahead.id}",
                 "org:#{first.id}",
                 "org:#{second.id}"
               ] ++ @built_in_keys

      # A saved position is not private state on the row: it is the order the
      # settings table and the message chooser both read.
      assert ahead.position == 0
      assert Enum.take(scripts, 3) |> Enum.all?(&(not &1.built_in?))
      assert Enum.drop(scripts, 3) |> Enum.all?(& &1.built_in?)
    end

    test "a script saved without a position is listed after the ordered ones", context do
      {:ok, numbered} =
        Alerts.create_script(context.audit, Map.put(@detour_script, "name", "Numbered"))

      {:ok, _earlier} =
        Alerts.create_script(
          context.audit,
          Map.merge(@detour_script, %{"name" => "Ahead", "position" => 2})
        )

      {:ok, unordered} =
        Alerts.create_script(context.audit, Map.put(@detour_script, "name", "Unordered"))

      # The unordered script takes the next place in the list rather than
      # sorting ahead of the ones an operator already arranged.
      assert numbered.position == 1
      assert unordered.position == 3

      assert Alerts.list_scripts(context.audit) |> Enum.map(& &1.name) |> Enum.take(3) ==
               ["Numbered", "Ahead", "Unordered"]
    end

    test "a member without the editor role reads no scripts, not even the built-ins", context do
      viewer = user_fixture()
      organization_membership_fixture(viewer, context.organization, [])

      assert Alerts.list_scripts(audit_context(context.organization, context.version, viewer)) ==
               []
    end
  end

  describe "create_script/2" do
    test "stores the script in the context's organization", context do
      assert {:ok, script} = Alerts.create_script(context.audit, @detour_script)

      assert script.organization_id == context.organization.id
      assert script.name == "Detour, stops skipped"
      assert script.situation == :detour
      assert script.header_template == @detour_script["header_template"]
      assert script.description_template == @detour_script["description_template"]

      stored = Repo.get!(AlertScript, script.id)

      assert stored.header_template == @detour_script["header_template"]
      assert stored.description_template == @detour_script["description_template"]
    end

    test "ignores an organization cast from the params", context do
      other = organization_fixture()

      assert {:ok, script} =
               Alerts.create_script(
                 context.audit,
                 Map.put(@detour_script, "organization_id", other.id)
               )

      assert script.organization_id == context.organization.id

      assert Repo.aggregate(from(s in AlertScript, where: s.organization_id == ^other.id), :count) ==
               0
    end

    test "the second script with a name in one organization is a name error", context do
      assert {:ok, _script} = Alerts.create_script(context.audit, @detour_script)

      assert {:error, changeset} = Alerts.create_script(context.audit, @detour_script)

      assert {"has already been taken", _options} = changeset.errors[:name]
      assert Repo.aggregate(AlertScript, :count) == 1
    end

    test "another organization may reuse the name", context do
      other = organization_fixture()
      other_version = gtfs_version_fixture(other.id)
      other_actor = editor_fixture(other)
      other_audit = audit_context(other, other_version, other_actor)

      assert {:ok, _mine} = Alerts.create_script(context.audit, @detour_script)
      assert {:ok, theirs} = Alerts.create_script(other_audit, @detour_script)

      assert theirs.name == "Detour, stops skipped"
      assert theirs.organization_id == other.id

      # The name reuse is not a leak in either direction.
      mine = Alerts.list_scripts(context.audit)
      theirs_scripts = Alerts.list_scripts(other_audit)

      assert Enum.find(mine, &(&1.key == "org:#{theirs.id}")) == nil

      assert Enum.find(theirs_scripts, &(&1.key == "org:#{theirs.id}"))[:name] ==
               "Detour, stops skipped"
    end

    test "stores a description template longer than 255 characters", context do
      template = String.duplicate("a", 256)

      assert {:ok, script} =
               Alerts.create_script(
                 context.audit,
                 Map.put(@detour_script, "description_template", template)
               )

      assert Repo.get!(AlertScript, script.id).description_template == template
    end

    test "stores a description template of exactly 2,000 characters", context do
      template = String.duplicate("a", 2_000)

      assert {:ok, script} =
               Alerts.create_script(
                 context.audit,
                 Map.put(@detour_script, "description_template", template)
               )

      assert Repo.get!(AlertScript, script.id).description_template == template
    end

    test "refuses a description template of more than 2,000 characters", context do
      assert {:error, changeset} =
               Alerts.create_script(
                 context.audit,
                 Map.put(@detour_script, "description_template", String.duplicate("a", 2_001))
               )

      assert changeset.errors[:description_template]
      assert Repo.aggregate(AlertScript, :count) == 0
    end

    test "refuses a template carrying an EEx tag", context do
      assert {:error, changeset} =
               Alerts.create_script(
                 context.audit,
                 Map.put(@detour_script, "header_template", "Route [route] <%= 1 %> detour")
               )

      assert {message, _options} = changeset.errors[:header_template]
      assert message =~ "plain text"
      assert Repo.aggregate(AlertScript, :count) == 0
    end

    test "refuses a template naming a placeholder this app does not fill", context do
      assert {:error, changeset} =
               Alerts.create_script(
                 context.audit,
                 Map.put(@detour_script, "description_template", "[when], use [street]")
               )

      assert {message, _options} = changeset.errors[:description_template]
      assert message =~ "\"street\""
      assert Repo.aggregate(AlertScript, :count) == 0
    end

    test "refuses a padded placeholder name the fill would never match", context do
      assert {:error, changeset} =
               Alerts.create_script(
                 context.audit,
                 Map.put(@detour_script, "header_template", "Route [route ] detour")
               )

      assert {message, _options} = changeset.errors[:header_template]
      assert message =~ "\"route \""
      assert Repo.aggregate(AlertScript, :count) == 0
    end

    test "refuses a template the fill would silently pass through", context do
      assert {:error, changeset} =
               Alerts.create_script(
                 context.audit,
                 Map.put(@detour_script, "description_template", "[Use instead]")
               )

      assert {_message, _options} = changeset.errors[:description_template]
      assert Repo.aggregate(AlertScript, :count) == 0
    end

    test "requires a name, a situation and both templates", context do
      assert {:error, changeset} = Alerts.create_script(context.audit, %{})

      assert changeset.errors[:name]
      assert changeset.errors[:situation]
      assert changeset.errors[:header_template]
      assert changeset.errors[:description_template]
      assert Repo.aggregate(AlertScript, :count) == 0
    end

    test "refuses a situation the app has no alert for", context do
      assert {:error, changeset} =
               Alerts.create_script(
                 context.audit,
                 Map.put(@detour_script, "situation", "earthquake")
               )

      assert {_message, _options} = changeset.errors[:situation]
      assert Repo.aggregate(AlertScript, :count) == 0
    end

    test "a member without the editor role cannot create a script", context do
      viewer = user_fixture()
      organization_membership_fixture(viewer, context.organization, [])

      assert {:error, :forbidden} =
               Alerts.create_script(
                 audit_context(context.organization, context.version, viewer),
                 @detour_script
               )

      assert Repo.aggregate(AlertScript, :count) == 0
    end
  end

  describe "update_script/3 and delete_script/2" do
    setup context do
      {:ok, script} = Alerts.create_script(context.audit, @detour_script)
      %{script: script}
    end

    test "saves the operator's own fields", context do
      assert {:ok, updated} =
               Alerts.update_script(context.audit, context.script.id, %{
                 "name" => "Detour, stops to skip",
                 "situation" => "service_change",
                 "header_template" => "Route [route] uses a different street",
                 "description_template" => "[when], all stops are served."
               })

      assert updated.name == "Detour, stops to skip"
      assert updated.situation == :service_change
      assert Repo.get!(AlertScript, context.script.id).situation == :service_change
    end

    test "keeps the typed values when a template is refused", context do
      assert {:error, changeset} =
               Alerts.update_script(context.audit, context.script.id, %{
                 "name" => "Renamed",
                 "header_template" => "<%= File.rm!(\"x\") %>"
               })

      assert {_message, _options} = changeset.errors[:header_template]

      stored = Repo.get!(AlertScript, context.script.id)

      assert stored.name == @detour_script["name"]
      assert stored.header_template == @detour_script["header_template"]
    end

    test "refuses to move a script to another organization through params", context do
      other = organization_fixture()

      assert {:ok, updated} =
               Alerts.update_script(
                 context.audit,
                 context.script.id,
                 %{"organization_id" => other.id}
               )

      assert updated.organization_id == context.organization.id
      assert Repo.get!(AlertScript, context.script.id).organization_id == context.organization.id
    end

    test "another tenant's script is not found, and stays unchanged", context do
      other = organization_fixture()
      other_version = gtfs_version_fixture(other.id)
      other_actor = editor_fixture(other)
      other_audit = audit_context(other, other_version, other_actor)
      {:ok, theirs} = Alerts.create_script(other_audit, Map.put(@detour_script, "name", "Theirs"))

      assert {:error, :not_found} =
               Alerts.update_script(context.audit, theirs.id, %{"name" => "Stolen"})

      assert {:error, :not_found} = Alerts.delete_script(context.audit, theirs.id)
      assert Repo.get!(AlertScript, theirs.id).name == "Theirs"
    end

    test "an unknown or malformed id is not found", context do
      assert {:error, :not_found} = Alerts.delete_script(context.audit, Ecto.UUID.generate())
      assert {:error, :not_found} = Alerts.update_script(context.audit, "not-a-uuid", %{})
    end

    test "a built-in cannot be edited or deleted in place", context do
      built_in = Enum.find(Alerts.list_scripts(context.audit), & &1.built_in?)

      assert is_nil(built_in.id)

      # A built-in has no row: only its copy is an organization script.
      assert {:error, :not_found} =
               Alerts.update_script(context.audit, built_in.key, %{"name" => "Mine now"})

      assert {:error, :not_found} = Alerts.delete_script(context.audit, built_in.key)

      refute Enum.any?(Alerts.list_scripts(context.audit), &(&1.name == "Mine now"))

      # The describe's own script leads; the built-ins follow it unchanged.
      assert Enum.map(Alerts.list_scripts(context.audit), & &1.key) ==
               ["org:#{context.script.id}"] ++ @built_in_keys
    end

    test "delete removes the script and is not repeatable", context do
      assert {:ok, deleted} = Alerts.delete_script(context.audit, context.script.id)
      assert deleted.id == context.script.id

      assert {:error, :not_found} = Alerts.delete_script(context.audit, context.script.id)
      assert Enum.map(Alerts.list_scripts(context.audit), & &1.key) == @built_in_keys
    end

    test "a member without the editor role cannot change or delete a script", context do
      viewer = user_fixture()
      organization_membership_fixture(viewer, context.organization, [])
      viewer_audit = audit_context(context.organization, context.version, viewer)

      assert {:error, :forbidden} =
               Alerts.update_script(viewer_audit, context.script.id, %{"name" => "Renamed"})

      assert {:error, :forbidden} = Alerts.delete_script(viewer_audit, context.script.id)
      assert Repo.get!(AlertScript, context.script.id).name == @detour_script["name"]
    end
  end

  describe "copy_built_in_script/2" do
    test "copies the built-in's templates into an editable organization script", context do
      assert {:ok, copy} = Alerts.copy_built_in_script(context.audit, "detour")
      built_in = BuiltInScripts.script("detour")

      assert copy.organization_id == context.organization.id
      assert copy.name == built_in.name
      assert copy.situation == built_in.situation
      assert copy.header_template == built_in.header_template
      assert copy.description_template == built_in.description_template

      scripts = Alerts.list_scripts(context.audit)

      assert [%{key: "org:" <> key, built_in?: false} = copied] = Enum.take(scripts, 1)
      assert copied.id == copy.id
      assert key == copy.id

      # Editing the copy leaves the built-in alone.
      assert {:ok, _renamed} = Alerts.update_script(context.audit, copy.id, %{"name" => "Ours"})
      assert BuiltInScripts.script("detour").name == built_in.name
    end

    test "every built-in key copies", context do
      for key <-
            ~w(detour delay stop_moved stop_closed no_service_day accessibility rider_information suspension) do
        assert {:ok, copy} = Alerts.copy_built_in_script(context.audit, key)
        assert copy.header_template == BuiltInScripts.script(key).header_template
      end

      assert Alerts.list_scripts(context.audit) |> Enum.take(8) |> Enum.all?(&(not &1.built_in?))
      assert Alerts.list_scripts(context.audit) |> length() == 16
    end

    test "copying the same built-in twice is a second variant, not a name failure", context do
      assert {:ok, first} = Alerts.copy_built_in_script(context.audit, "detour")
      assert {:ok, second} = Alerts.copy_built_in_script(context.audit, "detour")

      assert first.name == "Detour, stops skipped"
      assert second.name == "Detour, stops skipped 2"
      assert second.header_template == first.header_template
    end

    test "an unknown key stores nothing", context do
      assert {:error, :unknown_built_in} = Alerts.copy_built_in_script(context.audit, "commute")
      assert Alerts.copy_built_in_script(context.audit, nil) == {:error, :unknown_built_in}
      assert Repo.aggregate(AlertScript, :count) == 0
    end

    test "a member without the editor role cannot copy a built-in", context do
      viewer = user_fixture()
      organization_membership_fixture(viewer, context.organization, [])

      assert {:error, :forbidden} =
               Alerts.copy_built_in_script(
                 audit_context(context.organization, context.version, viewer),
                 "detour"
               )

      assert Repo.aggregate(AlertScript, :count) == 0
    end
  end

  describe "get_guidelines/1 and save_guidelines/3" do
    test "with no stored row it reads the built-in text at revision 0", context do
      assert %{text: text, revision: 0} = Alerts.get_guidelines(context.audit)
      assert text == BuiltInScripts.guidelines()

      # The recommended text is the prototype's guidelines, not a placeholder.
      assert text =~ "Lead with the route and the change."
      assert text =~ "Keep the short message short."
      assert text =~ "Tell riders what to do."
      assert text =~ "Times the way riders say them."

      # Reading writes nothing.
      assert Repo.aggregate(AlertSettings, :count) == 0
    end

    test "the first save stores the row at revision 1", context do
      assert {:ok, settings} = Alerts.save_guidelines(context.audit, "Our own wording.", 0)

      assert settings.revision == 1
      assert settings.guidelines == "Our own wording."
      assert settings.organization_id == context.organization.id

      assert %{text: "Our own wording.", revision: 1} = Alerts.get_guidelines(context.audit)
    end

    test "a save at revision 0 after the first is stale and overwrites nothing", context do
      assert {:ok, settings} = Alerts.save_guidelines(context.audit, "First wording.", 0)

      assert {:error, :stale} = Alerts.save_guidelines(context.audit, "Second wording.", 0)

      assert %{text: "First wording.", revision: 1} = Alerts.get_guidelines(context.audit)
      assert Repo.get!(AlertSettings, settings.id).guidelines == "First wording."
      assert Repo.get!(AlertSettings, settings.id).revision == 1
    end

    test "a save at the current revision advances it", context do
      assert {:ok, _settings} = Alerts.save_guidelines(context.audit, "First wording.", 0)
      assert {:ok, second} = Alerts.save_guidelines(context.audit, "Second wording.", 1)

      assert second.revision == 2
      assert Alerts.get_guidelines(context.audit) == %{text: "Second wording.", revision: 2}
    end

    test "a save at any other revision is stale", context do
      assert {:ok, _settings} = Alerts.save_guidelines(context.audit, "First wording.", 0)

      assert {:error, :stale} = Alerts.save_guidelines(context.audit, "Older.", 0)
      assert {:error, :stale} = Alerts.save_guidelines(context.audit, "Newer.", 99)

      # A revision that cannot be any row's revision is refused the same way,
      # rather than reaching the database as a cast failure.
      assert {:error, :stale} = Alerts.save_guidelines(context.audit, "Negative.", -1)
      assert {:error, :stale} = Alerts.save_guidelines(context.audit, "Text.", "1")

      assert Alerts.get_guidelines(context.audit) == %{text: "First wording.", revision: 1}
    end

    test "one tenant's guidelines are never another's", context do
      other = organization_fixture()
      other_version = gtfs_version_fixture(other.id)
      other_actor = editor_fixture(other)
      other_audit = audit_context(other, other_version, other_actor)

      assert {:ok, _settings} = Alerts.save_guidelines(context.audit, "Ours.", 0)
      assert {:ok, theirs} = Alerts.save_guidelines(other_audit, "Theirs.", 0)

      assert theirs.guidelines == "Theirs."
      assert Alerts.get_guidelines(context.audit).text == "Ours."
      assert Alerts.get_guidelines(other_audit).text == "Theirs."
      assert Repo.aggregate(AlertSettings, :count) == 2
    end

    test "an organization may save its own empty text and read it back", context do
      assert {:ok, settings} = Alerts.save_guidelines(context.audit, "", 0)

      # Ecto casts the empty string to the field's nil; reading answers the text.
      assert is_nil(settings.guidelines)
      assert Alerts.get_guidelines(context.audit) == %{text: "", revision: 1}
    end

    test "refuses guidelines of more than 10,000 characters and keeps the stored text",
         context do
      assert {:ok, _settings} = Alerts.save_guidelines(context.audit, "Ours.", 0)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Alerts.save_guidelines(context.audit, String.duplicate("a", 10_001), 1)

      assert changeset.errors[:guidelines]
      assert Alerts.get_guidelines(context.audit) == %{text: "Ours.", revision: 1}
    end

    test "a second settings row for one organization is a changeset error, not a raise",
         context do
      assert {:ok, _settings} = Alerts.save_guidelines(context.audit, "Ours.", 0)

      assert {:error, changeset} =
               %AlertSettings{}
               |> AlertSettings.changeset(%{"guidelines" => "Again."})
               |> Ecto.Changeset.put_change(:organization_id, context.organization.id)
               |> Repo.insert()

      assert {"has already been taken", _options} = changeset.errors[:organization_id]
    end

    test "a member without the editor role reads no text and saves nothing", context do
      viewer = user_fixture()
      organization_membership_fixture(viewer, context.organization, [])
      viewer_audit = audit_context(context.organization, context.version, viewer)

      assert Alerts.get_guidelines(viewer_audit) == %{text: "", revision: 0}
      assert {:error, :forbidden} = Alerts.save_guidelines(viewer_audit, "Ours.", 0)

      assert Repo.aggregate(AlertSettings, :count) == 0

      # Nor can a non-editor overwrite the text an editor already stored.
      {:ok, settings} = Alerts.save_guidelines(context.audit, "Ours.", 0)

      assert {:error, :forbidden} =
               Alerts.save_guidelines(viewer_audit, "Theirs.", settings.revision)

      assert Alerts.get_guidelines(context.audit).text == "Ours."
    end

    test "a deactivated member is refused as well", context do
      membership = organization_membership_fixture(user_fixture(), context.organization)
      deactivate_membership_fixture(membership)

      actor = Repo.get!(GtfsPlanner.Accounts.User, membership.user_id)
      viewer_audit = audit_context(context.organization, context.version, actor)

      assert Alerts.get_guidelines(viewer_audit) == %{text: "", revision: 0}
      assert {:error, :forbidden} = Alerts.save_guidelines(viewer_audit, "Ours.", 0)
      assert Repo.aggregate(AlertSettings, :count) == 0
    end
  end

  defp audit_context(organization, version, actor) do
    %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: actor.id,
      actor_email: actor.email
    }
  end
end
