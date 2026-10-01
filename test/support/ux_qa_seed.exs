# Creates the start state every UX QA journey begins from.
#
# `bin/ux-qa up` runs this script on its own throwaway database (a loopback
# `pg_tmp` server whose database is `test`), so the database is empty and no
# guard, reset or cleanup belongs here; config/test.exs already refuses any
# other database.
#
# It creates one organization, "Demo Transit Authority", with its
# administrator, the published "First Version" that registration creates, and
# one editor with the pathways studio editor role. With
# `UX_QA_SEED=sample-feed` it also imports test/fixtures/gtfs/ux_qa/sample-feed.zip
# into that version; `UX_QA_SEED=blank` leaves the version empty.
#
# The credentials below are test-only and are mirrored for the harness in
# assets/qa/accounts.mjs. They must not appear in application config.

alias GtfsPlanner.Accounts
alias GtfsPlanner.Accounts.User
alias GtfsPlanner.Gtfs.Import
alias GtfsPlanner.Organizations
alias GtfsPlanner.Repo
alias GtfsPlanner.Versions

seed = System.get_env("UX_QA_SEED")

unless seed in ["blank", "sample-feed"] do
  raise """
  UX_QA_SEED must be "blank" or "sample-feed", got: #{inspect(seed)}.
  bin/ux-qa up sets UX_QA_SEED from the scenario's Seed before running this script.
  """
end

sample_feed = Path.expand("../fixtures/gtfs/ux_qa/sample-feed.zip", __DIR__)

{:ok, admin} =
  Accounts.register_first_admin(%{
    email: "qa-admin@gtfs-planner.test",
    password: "QaAdmin12345!",
    password_confirmation: "QaAdmin12345!",
    organization_name: "Demo Transit Authority",
    organization_alias: "demo-transit"
  })

IO.puts("UX QA seed: created administrator #{admin.email} (id=#{admin.id})")

[org] = Organizations.list_organizations_for_user(admin.id)
IO.puts("UX QA seed: organization #{org.name} (#{org.alias}, id=#{org.id})")

# register_first_admin publishes "First Version"; reuse it instead of adding a
# second version, so a journey that picks the organization sees one version.
[version] = Versions.list_gtfs_versions(org.id)
IO.puts("UX QA seed: version #{version.name} (id=#{version.id})")

{:ok, editor} =
  Accounts.register_user(%{
    email: "qa-editor@gtfs-planner.test",
    password: "QaEditor12345!"
  })

_confirmed_editor = Repo.update!(User.confirm_changeset(editor))

{:ok, membership} =
  Accounts.create_user_org_membership(%{
    user_id: editor.id,
    organization_id: org.id,
    roles: ["pathways_studio_editor"]
  })

IO.puts(
  "UX QA seed: created editor #{editor.email} (id=#{editor.id}) with membership #{membership.id}"
)

if seed == "sample-feed" do
  case Import.import_files(org.id, version.id, [
         %{filename: "sample-feed.zip", content: File.read!(sample_feed)}
       ]) do
    {:ok, _import_result} ->
      IO.puts("UX QA seed: imported sample-feed.zip into version #{version.name}")

    {:error, reason} ->
      raise "UX QA seed: importing #{sample_feed} into version #{version.id} failed: #{inspect(reason)}"
  end
end
