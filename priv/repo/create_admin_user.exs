alias GtfsPlanner.Organizations
alias GtfsPlanner.Organizations.Organization
alias GtfsPlanner.Accounts
alias GtfsPlanner.Accounts.User
alias GtfsPlanner.Repo
alias GtfsPlanner.Accounts.UserOrgMembership

# 1. Create or get the Organization
org_attrs = %{name: "Pathways Studio", alias: "pathwaysstudio"}
{:ok, org} =
  case Organizations.get_organization_by_alias(org_attrs.alias) do
    nil -> Organizations.create_organization(org_attrs)
    existing_org -> {:ok, existing_org}
  end

IO.puts("Organization 'pathwaysstudio' (ID: #{org.id}) is ready.")

# 2. Create or get the User
user_email = "editor@studio.com"
user_password = "YourSecurePassword123!"

{:ok, user} =
  case Accounts.get_user_by_email(user_email) do
    nil -> Accounts.register_user(%{email: user_email, password: user_password})
    existing_user -> {:ok, existing_user}
  end

IO.puts("User '#{user.email}' (ID: #{user.id}) is ready.")

# 3. Assign roles
roles = ["pathways_studio_admin", "pathways_studio_editor"]

# Check if membership already exists
membership = Repo.get_by(UserOrgMembership, user_id: user.id, organization_id: org.id)

if membership do
  # Update existing membership
  {:ok, _updated_membership} =
    membership
    |> UserOrgMembership.changeset(%{roles: roles})
    |> Repo.update()
  IO.puts("Updated roles for user in organization.")
else
  # Create new membership
  %UserOrgMembership{}
  |> UserOrgMembership.changeset(%{
    user_id: user.id,
    organization_id: org.id,
    roles: roles
  })
  |> Repo.insert()
  IO.puts("Added user to organization with roles.")
end
