# User Management

This guide covers user management operations in GTFS Planner, including user invitations, registration flows, password management, role-based access control, and organization membership.

## Table of Contents

- [User Invitation Process](#user-invitation-process)
- [User Registration Flow](#user-registration-flow)
- [Password Reset Flow](#password-reset-flow)
- [Role Management](#role-management)
- [Organization Membership](#organization-membership)
- [Email Configuration](#email-configuration)
- [User Settings](#user-settings)

---

## User Invitation Process

Admin users can invite new users to join organizations through a secure email-based workflow.

### Inviting a User

1. Navigate to your organization's user management page
2. Click "Invite User"
3. Enter the user's email address
4. Select the appropriate role (e.g., `:administrator` or leave empty for member)
5. Submit the invitation

### What Happens Next

1. **User Record Created**: A user account is created with the provided email address but no password
2. **Invite Token Generated**: A secure, single-use token is generated
3. **Email Sent**: The user receives an invitation email with a link
4. **Token Expiry**: The invitation token expires after 7 days

### Accepting an Invitation

1. User clicks the invitation link from their email
2. They are directed to the password setup page
3. User sets their password (12-72 characters)
4. Organization membership is automatically created
5. User can now log in with their credentials

### Security Features

- **Single-use tokens**: Once used, invitation tokens cannot be reused
- **7-day expiry**: Tokens automatically expire after 7 days
- **Secure password hashing**: Passwords are hashed using Argon2
- **No password storage in plaintext**: Raw passwords are never stored

### API Example

To invite a user programmatically:

```elixir
# Invite a user with the administrator role
{:ok, user} = GtfsPlanner.Accounts.invite_user(
  organization,
  %{
    email: "user@example.com",
    roles: [:administrator]
  }
)

# The invitation email is sent automatically
```

---

## User Registration Flow

GTFS Planner uses an invitation-based registration system to ensure all users are properly associated with organizations.

### Registration Steps

1. **Receive Invitation**: User must receive an invitation from an organization admin
2. **Click Invite Link**: User clicks the unique link from their email
3. **Set Password**: User chooses a secure password
4. **Complete Registration**: Account is activated and ready to use

### Password Requirements

- **Minimum Length**: 12 characters
- **Maximum Length**: 72 characters
- **Recommended**: Mix of uppercase, lowercase, numbers, and special characters
- **Storage**: Passwords are hashed using Argon2 and never stored in plaintext

### Registration Security

- **Argon2 Hashing**: Memory-hard algorithm resistant to brute force attacks
- **Timing Attack Protection**: Constant-time comparisons prevent username enumeration
- **Session Fixation Protection**: New session created on login
- **CSRF Protection**: Built-in Phoenix CSRF tokens

---

## Password Reset Flow

Users can reset their passwords securely via email when they forget their credentials.

### Requesting a Password Reset

1. Navigate to the login page
2. Click "Forgot Password?"
3. Enter the email address associated with your account
4. Submit the form

### Reset Process

1. **Token Generated**: A secure, single-use token is created
2. **Email Sent**: User receives a password reset link via email
3. **Token Expiry**: The reset token expires after 24 hours
4. **All Sessions Invalidated**: Upon successful reset, all active sessions are terminated

### Completing the Reset

1. Click the password reset link from the email
2. Enter your new password
3. Confirm your new password
4. Submit the form
5. Your password is updated and you can log in

### Security Features

- **Single-use tokens**: Reset tokens cannot be reused
- **24-hour expiry**: Tokens expire after 1 day
- **Session invalidation**: All existing sessions are terminated on password change
- **No information leakage**: Success message displayed regardless of email existence

### API Example

To programmatically initiate a password reset:

```elixir
# Request password reset for a user
case GtfsPlanner.Accounts.deliver_user_reset_password_instructions(
  user,
  &url(~p"/users/reset_password/#{&1}")
) do
  {:ok, _} -> # Email sent successfully
  {:error, reason} -> # Handle error
end
```

---

## Role Management

GTFS Planner implements a flexible role-based authorization system for browser sessions and companion API sessions (user-owned `api_session` tokens).

### Available Roles

| Role             | Description                                          |
| ---------------- | ---------------------------------------------------- |
| `:administrator` | Full administrative access to organization resources |
| `nil` (empty)    | Regular member with basic access                     |

### Role Specifications

The system supports several role specification formats:

#### Single Role

```elixir
# Require exactly one specific role
{:ok, user} = GtfsPlanner.Accounts.invite_user(
  organization,
  %{email: "admin@example.com", roles: [:administrator]}
)
```

#### Any Membership (No Specific Role)

```elixir
# Invite user as a regular member
{:ok, user} = GtfsPlanner.Accounts.invite_user(
  organization,
  %{email: "member@example.com", roles: []}
)
```

#### Multiple Roles

```elixir
# User can have multiple roles
{:ok, user} = GtfsPlanner.Accounts.invite_user(
  organization,
  %{email: "power_user@example.com", roles: [:administrator, :moderator]}
)
```

### Authorization Patterns

#### In LiveViews

```elixir
defmodule GtfsPlannerWeb.AdminLive do
  use GtfsPlannerWeb, :live_view

  on_mount {GtfsPlannerWeb.EnsureRole, :administrator}
  # or
  on_mount {GtfsPlannerWeb.EnsureRole, any: [:administrator, :manager]}
  # or
  on_mount {GtfsPlannerWeb.EnsureRole, all: [:administrator, :manager]}
end
```

#### In API Endpoints

```elixir
pipeline :require_admin do
  plug GtfsPlannerWeb.EnsureRole, :administrator
end

pipeline :require_any_role do
  plug GtfsPlannerWeb.EnsureRole, any: [:administrator, :editor]
end
```

### Updating User Roles

```elixir
# Update roles for a user in an organization
{:ok, membership} = GtfsPlanner.Organizations.update_user_roles(
  organization,
  user,
  [:administrator]
)
```

### Checking Roles Programmatically

```elixir
# Check if a user has a specific role in an organization
has_admin_role? = Enum.member?(membership.roles, :administrator)
```

---

## Organization Membership

GTFS Planner uses a multi-tenant architecture where users belong to organizations.

### Membership Structure

- **Users**: Individual user accounts with email/password credentials
- **Organizations**: Tenant entities with unique aliases
- **Memberships**: Join table linking users to organizations with roles

### Creating Organization Membership

```elixir
# Add user to organization with specific roles
{:ok, membership} = GtfsPlanner.Organizations.add_user_to_organization(
  organization,
  user,
  [:administrator]
)
```

### Removing User from Organization

```elixir
# Remove a user from an organization
{:ok, _} = GtfsPlanner.Organizations.remove_user_from_organization(
  organization,
  user
)
```

### Listing Users in Organization

```elixir
# Get all users for an organization
users = GtfsPlanner.Organizations.list_users_in_organization(organization)
```

### Listing Organizations for User

```elixir
# Get all organizations a user belongs to
organizations = GtfsPlanner.Organizations.list_organizations_for_user(user)
```

### Organization Scoping

Organization-scoped routes use the organization alias:

```
/organizations/:org_alias/dashboard
/organizations/:org_alias/users
```

The current organization is automatically assigned to the connection and accessible as `@current_organization` in LiveViews. Companion clients select an organization with `X-Organization-Id` after `POST /api/v1/auth/login` (see [API Authentication](./api-authentication.md)).

---

## Email Configuration

Email notifications are essential for user invitation and password reset workflows. GTFS Planner uses Swoosh for email delivery.

### Configuration

#### Development

```elixir
# config/dev.exs
config :gtfs_planner, GtfsPlanner.Mailer,
  adapter: Swoosh.Adapters.Local
```

#### Production

```elixir
# config/prod.exs
config :gtfs_planner, GtfsPlanner.Mailer,
  adapter: Swoosh.Adapters.SendGrid,
  api_key: System.get_env("SENDGRID_API_KEY")
```

### Supported Email Adapters

- **Local**: Stores emails in the filesystem (development only)
- **SendGrid**: Production-ready with templates
- **Mailgun**: Alternative production adapter
- **SMTP**: Generic SMTP server support
- **Amazon SES**: AWS Simple Email Service

### Email Templates

Email templates are located in `lib/gtfs_planner/accounts/emails/`:

- `UserInviteEmail`: Invitation to join organization
- `ResetPasswordEmail`: Password reset instructions
- `EmailConfirmationEmail`: Email confirmation (if enabled)

### Customizing Email Templates

Email templates can be customized by modifying the respective email modules:

```elixir
defmodule GtfsPlanner.Accounts.Emails.UserInviteEmail do
  import Swoosh.Email

  def deliver(user, invite_url) do
    new()
    |> to({user.email, user.email})
    |> from({"GTFS Planner", "noreply@gtfsplanner.com"})
    |> subject("You're invited to join GTFS Planner")
    |> html_body("""
      <h1>Welcome to GTFS Planner!</h1>
      <p>You've been invited to join our platform.</p>
      <p><a href="#{invite_url}">Accept Invitation</a></p>
    """)
    |> text_body("""
      Welcome to GTFS Planner!
      You've been invited to join our platform.

      Accept your invitation: #{invite_url}
    """)
  end
end
```

### Testing Email Delivery

In development, emails are stored in the local mailer directory:

```bash
# View sent emails
ls priv/static/email/
```

Use the Swoosh inbox UI to preview emails:

```elixir
# config/dev.exs
config :swoosh, :api_client, false
```

---

## User Settings

Users can manage their account settings through the settings interface.

### Email Address Changes

1. Navigate to Settings page
2. Click "Change Email"
3. Enter new email address
4. Enter current password for verification
5. Submit the form
6. Confirm email via the link sent to the new address

### Password Changes

1. Navigate to Settings page
2. Click "Change Password"
3. Enter current password
4. Enter new password
5. Confirm new password
6. Submit the form

### Settings Security

- **Password Verification**: Email changes require current password
- **Session Invalidation**: Password changes invalidate all sessions
- **Email Confirmation**: Email changes require confirmation via email link

### API Example

To update user email:

```elixir
# Initiate email change
{:ok, user} = GtfsPlanner.Accounts.apply_user_email(user, %{
  "email" => "newemail@example.com",
  "current_password" => "current_password"
})

# Confirmation email is sent automatically
```

To update user password:

```elixir
# Update password
{:ok, user} = GtfsPlanner.Accounts.update_user_password(
  user,
  %{
    "password" => "new_secure_password",
    "password_confirmation" => "new_secure_password",
    "current_password" => "current_password"
  }
)
```

---

## Best Practices

### User Management

1. **Principle of Least Privilege**: Grant users only the roles they need
2. **Regular Audits**: Review user roles and memberships periodically
3. **Immediate Revocation**: Remove access promptly when users leave
4. **Strong Passwords**: Encourage users to use password managers

### Security

1. **Monitor Failed Logins**: Track and alert on suspicious activity
2. **Enforce Password Policies**: Require strong, unique passwords
3. **Enable MFA**: Consider adding multi-factor authentication
4. **Regular Rotation**: Encourage users to change passwords periodically

### Email Configuration

1. **Use Verified Senders**: Ensure your email domain is properly authenticated (SPF, DKIM, DMARC)
2. **Test Deliverability**: Verify emails reach inboxes, not spam folders
3. **Monitor Bounce Rates**: Track and handle invalid email addresses
4. **Rate Limiting**: Implement limits to prevent abuse

### Organization Management

1. **Clear Aliases**: Use meaningful organization aliases
2. **Consistent Naming**: Follow naming conventions for organizations
3. **Document Roles**: Clearly document what each role can do
4. **Audit Trail**: Track who made what changes and when

---

## Troubleshooting

### Common Issues

#### Invitation Email Not Received

1. Check spam folder
2. Verify email address is correct
3. Check mailer logs
4. Verify SMTP credentials (production)

#### Password Reset Not Working

1. Ensure link hasn't expired (24-hour limit)
2. Verify token hasn't been used (single-use)
3. Check for typos in password
4. Ensure new password meets requirements

#### Cannot Log In

1. Verify correct email and password
2. Check if account is locked
3. Verify password was properly reset
4. Clear browser cookies and cache

#### Companion API session issues

1. Confirm login via `POST /api/v1/auth/login` (not legacy organization keys)
2. Send `Authorization: Bearer <api_session_token>`
3. For multi-org users, send `X-Organization-Id`
4. Ensure the membership still has the required roles for write routes

---

## Additional Resources

- [Authentication Guide](./authentication-guide.md) - Complete authentication system documentation
- [API Authentication](./api-authentication.md) - Companion session usage and authorization
- [Warbler Authentication Implementation](./warbler-authentication-implementation.md) - Historical reference only

---

## Support

For issues or questions related to user management:

1. Check this documentation
2. Review the authentication guide
3. Consult the companion API authentication docs
4. Open an issue on GitHub

---

**Last Updated**: July 20, 2026
