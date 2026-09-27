defmodule GtfsPlanner.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via to `GtfsPlanner.Accounts` context.
  """

  @doc """
  Extracts a token from a confirmation/reset email sent to given user.

  The passed `fun` is a function that expects a URL argument
  and delivers an email containing the token.
  """
  def extract_user_token(fun) do
    # Call the function with a dummy URL
    # The actual token will be in the generated URL in the email
    {:ok, _} = fun.("http://localhost:4000")

    captured_email =
      receive do
        {:email, email} -> email
      after
        100 -> raise "No email received"
      end

    # Extract token from the URL in the email body
    html_body = captured_email.html_body || ""
    [_, token] = Regex.run(~r/\/users\/[^\/]+\/([^"\s]+)/, html_body)
    token
  end

  @doc """
  Generate a user fixture.
  """
  def user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> valid_user_attributes()
      |> GtfsPlanner.Accounts.register_user()

    user
  end

  @doc """
  Returns a map of valid user attributes.
  """
  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: unique_user_email(),
      password: valid_user_password()
    })
  end

  @doc """
  Generates a unique user email.
  """
  def unique_user_email do
    "user-#{System.unique_integer([:positive, :monotonic])}@example.com"
  end

  def valid_user_password, do: "valid user password 123456"

  @doc """
  Generate an active organization membership for a user.

  Interactive calendar commands resolve the actor's current membership from the
  server-held identity, so tests must supply a real active membership row rather
  than only an `%AuditContext{}`.
  """
  def organization_membership_fixture(user, organization, roles \\ ["pathways_studio_editor"]) do
    {:ok, membership} =
      GtfsPlanner.Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: roles
      })

    membership
  end

  @doc """
  Generate a user with an active `pathways_studio_editor` membership in the organization.
  """
  def editor_fixture(organization) do
    user = user_fixture()
    organization_membership_fixture(user, organization)
    user
  end

  @doc """
  Deactivate an existing membership the way the application does.

  `UserOrgMembership.changeset/2` never casts `deactivated_at`, so the lifecycle
  column is set explicitly here, exactly as the real deactivation path does.
  """
  def deactivate_membership_fixture(membership) do
    membership
    |> Ecto.Changeset.change(%{deactivated_at: DateTime.utc_now() |> DateTime.truncate(:second)})
    |> GtfsPlanner.Repo.update!()
  end
end
