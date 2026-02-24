# GtfsPlanner

GTFS Planner is a multi-tenant application for managing GTFS transit data with built-in authentication and authorization features.

## Getting Started

To start your Phoenix server:

- Run `mix setup` to install and setup dependencies
- Run `mix ecto.setup` to create the database and run migrations
- Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

### OTP Export Prerequisites

Manual end-to-end export graph builds require local OTP assets that are not committed:

- `priv/otp/opentripplanner.jar`
- `priv/otp/region.osm.pbf`

Use the built-in checker before running Export page graph tests:

```bash
mix gtfs.otp.check --create-dir
```

Install missing artifacts automatically:

```bash
mix gtfs.otp.install
```

Run in preview mode without downloading:

```bash
mix gtfs.otp.install --dry-run
```

`mix setup` runs this checker in warning mode so missing local assets are always surfaced early.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Docker

Run GTFS Planner in a Docker container while connecting to your local PostgreSQL database.

```sh
scripts/docker-build.sh
scripts/docker-run.sh
```

### Accessing the Application

Once the container is running, access the application at:

- **Web Interface:** http://localhost:4000
- **Health Check:** http://localhost:4000/health

### Environment Variables

The container accepts these environment variables:

| Variable          | Description                           | Required | Default       |
| ----------------- | ------------------------------------- | -------- | ------------- |
| `DATABASE_URL`    | PostgreSQL connection string          | Yes      | -             |
| `SECRET_KEY_BASE` | Phoenix secret for signing/encryption | Yes      | -             |
| `PHX_SERVER`      | Start the Phoenix web server          | No       | `false`       |
| `PHX_HOST`        | Hostname for URL generation           | No       | `example.com` |
| `PORT`            | HTTP port to bind                     | No       | `4000`        |

### Troubleshooting

**Cannot connect to database:**

- Verify PostgreSQL is running: `pg_isready -h localhost`
- Ensure database exists: `psql -U postgres -l | grep gtfs_planner_dev`
- On Linux, verify you used `--add-host=host.docker.internal:host-gateway`

**Build fails:**

- Ensure you have sufficient disk space (build requires ~2GB)
- Check Docker daemon is running: `docker info`
- Clear build cache: `docker builder prune`

**Container exits immediately:**

- Check logs: `docker logs gtfs-planner-dev` or `docker-compose logs`
- Verify `DATABASE_URL` and `SECRET_KEY_BASE` are set
- Ensure `PHX_SERVER=true` is set to start the web server

For comprehensive troubleshooting and advanced configuration, see [Docker Local Development Guide](docs/docker-local-dev.md).

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
