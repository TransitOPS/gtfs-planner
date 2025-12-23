# GtfsPlanner

GTFS Planner is a multi-tenant application for managing GTFS transit data with built-in authentication and authorization features.

## Getting Started

To start your Phoenix server:

- Run `mix setup` to install and setup dependencies
- Run `mix ecto.setup` to create the database and run migrations
- Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Authentication & Authorization

GTFS Planner includes a comprehensive authentication and authorization system with the following features:

### User Authentication

- **Email/Password Authentication**: Users can log in with email and password
- **Secure Password Hashing**: Passwords are hashed using Argon2 (memory-hard algorithm)
- **Session Management**: 60-day session tokens with automatic renewal
- **Remember-Me**: Optional persistent sessions via signed cookies
- **Password Reset**: Users can reset passwords via secure email links
- **User Invitation**: Admins can invite users to organizations

### API Authentication

Programmatic access to GTFS Planner is available via API key authentication:

- **Bearer Token Format**: API keys use RFC 6750 compliant format: `Authorization: Bearer GtfsPlanner.V1.<encoded>`
- **Organization Scoping**: API keys are scoped to specific organizations
- **Role-Based Access**: API keys support role-based authorization
- **Security Features**: Constant-time comparison and random delays prevent timing attacks

#### Example API Request

```bash
# Make an authenticated API request
curl -H "Authorization: Bearer GtfsPlanner.V1.abcdefg" \
     http://localhost:4000/api/organizations/my-org/data
```

### Multi-Tenancy & Organizations

GTFS Planner supports organization-based multi-tenancy:

- **Organization Aliases**: Unique identifiers for organizations
- **URL-Based Scoping**: Access organization data via `/organizations/:org_alias/*`
- **User Memberships**: Users can belong to multiple organizations with different roles
- **Role-Based Authorization**: Flexible role system (e.g., `:administrator`, `:editor`, `:viewer`)

#### Organization-Scoped Routes

```elixir
# Access organization-specific data
/organizations/:org_alias/dashboard
/organizations/:org_alias/stops
/organizations/:org_alias/routes
```

### Role-Based Authorization

The authentication system supports flexible role-based access control:

- **Single Role**: `:administrator` requires user has administrator role
- **Any Membership**: `nil` requires user belongs to organization (any role)
- **Any Role in List**: `any: [:editor, :viewer]` requires user has at least one role
- **All Roles in List**: `all: [:editor, :publisher]` requires user has all specified roles

### Security Features

- **Session Fixation Protection**: Sessions are renewed on login
- **CSRF Protection**: Automatic CSRF token validation
- **Timing Attack Protection**: Constant-time comparisons for password/token verification
- **Rate Limiting**: Random delays on failed authentication attempts
- **Secure Email Tokens**: Single-use, time-limited tokens with database revocation
- **SSL Enforcement**: HTTPS required in production

### Documentation

For detailed documentation on authentication features:

- **[Authentication Guide](docs/authentication-guide.md)**: Complete overview of authentication architecture, flows, and best practices
- **[API Authentication](docs/api-authentication.md)**: API key creation, usage, and authentication details
- **[User Management](docs/user-management.md)**: User invitation, registration, and management workflows

## Development

### Running Tests

```bash
# Run all tests
mix test

# Run specific test file
mix test test/gtfs_planner/accounts_test.exs

# Run tests with coverage
mix test --cover
```

### Database Migrations

```bash
# Create a new migration
mix ecto.gen.migration create_new_table

# Run migrations
mix ecto.migrate

# Rollback migrations
mix ecto.rollback
```

### Code Quality

```bash
# Format code
mix format

# Run Credo for code quality checks
mix credo

# Run Dialyzer for static analysis
mix dialyzer
```

## Learn more

- Official website: https://www.phoenixframework.org/
- Guides: https://hexdocs.pm/phoenix/overview.html
- Docs: https://hexdocs.pm/phoenix
- Forum: https://elixirforum.com/c/phoenix-forum
- Source: https://github.com/phoenixframework/phoenix

## License

See [LICENSE](LICENSE) file for details.
