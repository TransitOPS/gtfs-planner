# Creates a deterministic browser-test user for Playwright E2E tests.
# This script runs after `MIX_ENV=test mix ecto.reset`, so the database
# is empty and idempotency is unneeded. The user is confirmed and has
# a full organization+membership+version setup via register_first_admin/1.
#
# Credentials are test-only and must not appear in application config.
case GtfsPlanner.Accounts.register_first_admin(%{
       email: "browser-test@gtfs-planner.test",
       password: "BrowserTest123!",
       password_confirmation: "BrowserTest123!",
       organization_name: "Browser Test Org",
       organization_alias: "browser-test"
     }) do
  {:ok, user} ->
    IO.puts("Browser seed: created #{user.email} (id=#{user.id})")

  {:error, changeset} ->
    raise "Browser seed failed: #{inspect(changeset.errors)}"
end
