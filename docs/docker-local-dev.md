# Running Docker Container Locally with Host PostgreSQL

This guide explains how to run the GTFS Planner application in a Docker container while connecting to a PostgreSQL database running on your host machine.

## Prerequisites

1. **Docker Desktop** installed (Mac/Windows) or **Docker Engine** (Linux)
2. **PostgreSQL** running locally on port 5432
3. **Database created**: `gtfs_planner_dev`
4. **Database user**: `postgres` with password `postgres` (or adjust the configuration)

## Setup PostgreSQL for Docker Access

### Option A: Using Default Configuration (Recommended)

If you're using the default PostgreSQL configuration, it should already allow local connections.

### Option B: Explicit PostgreSQL Configuration (If needed)

If you encounter connection issues, configure PostgreSQL to accept connections from Docker:

1. **Edit `postgresql.conf`**:
   ```
   listen_addresses = '*'
   ```

2. **Edit `pg_hba.conf`** - Add these lines:
   ```
   # Docker network access
   host    all             all             172.17.0.0/16           md5
   host    all             all             ::1/128                 md5
   ```

3. **Restart PostgreSQL**:
   ```bash
   # Mac (Homebrew)
   brew services restart postgresql@16
   
   # Linux (systemd)
   sudo systemctl restart postgresql
   ```

## Running the Container

### Using Convenience Scripts (Recommended)

The easiest way to build and run the container:

```bash
# Build the Docker image
./scripts/docker-build.sh

# Run the container
./scripts/docker-run.sh
```

The scripts will:
- Build the Docker image (docker-build.sh)
- Check if PostgreSQL is running
- Verify the database exists
- Detect your OS and configure networking appropriately
- Set all required environment variables
- Start the container (docker-run.sh)

### Manual Docker Run

For more control, run Docker directly:

```bash
# Build the image
docker build -t gtfs-planner .

# Run the container (Mac/Windows)
docker run -it --rm \
  -p 4000:4000 \
  -e DATABASE_URL="ecto://postgres:postgres@host.docker.internal/gtfs_planner_dev" \
  -e SECRET_KEY_BASE="$(mix phx.gen.secret)" \
  -e PHX_SERVER=true \
  -e PHX_HOST=localhost \
  gtfs-planner

# Run the container (Linux)
docker run -it --rm \
  -p 4000:4000 \
  --add-host=host.docker.internal:host-gateway \
  -e DATABASE_URL="ecto://postgres:postgres@host.docker.internal/gtfs_planner_dev" \
  -e SECRET_KEY_BASE="$(mix phx.gen.secret)" \
  -e PHX_SERVER=true \
  -e PHX_HOST=localhost \
  gtfs-planner
```

## Accessing the Application

Once the container is running, access the application at:

```
http://localhost:4000
```

## How It Works

### The `host.docker.internal` DNS Name

- **Mac/Windows**: Docker Desktop automatically provides `host.docker.internal` which resolves to the host machine's IP
- **Linux**: We use `--add-host=host.docker.internal:host-gateway` to create this mapping

This allows the container to connect to `localhost` services on the host machine.

### Database Connection Flow

```
┌─────────────────────────┐
│  Docker Container       │
│  (Phoenix App)          │
│                         │
│  Connects to:           │
│  host.docker.internal   │
└───────────┬─────────────┘
            │
            │ Resolves to host IP
            ▼
┌─────────────────────────┐
│  Host Machine           │
│                         │
│  PostgreSQL on          │
│  localhost:5432         │
└─────────────────────────┘
```

## Troubleshooting

### Connection Refused

**Error**: `connection refused`

**Solutions**:
1. Verify PostgreSQL is running:
   ```bash
   pg_isready -h localhost
   ```

2. Check PostgreSQL is listening on the correct port:
   ```bash
   lsof -i :5432
   ```

3. On Linux, ensure `host.docker.internal` is mapped:
   ```bash
   docker run --add-host=host.docker.internal:host-gateway ...
   ```

### Database Does Not Exist

**Error**: `database "gtfs_planner_dev" does not exist`

**Solution**: Create the database first:
```bash
mix ecto.create
# or
createdb -U postgres gtfs_planner_dev
```

### Authentication Failed

**Error**: `password authentication failed for user "postgres"`

**Solutions**:
1. Update the `DATABASE_URL` with correct credentials:
   ```bash
   -e DATABASE_URL="ecto://your_user:your_password@host.docker.internal/gtfs_planner_dev"
   ```

2. Verify you can connect locally:
   ```bash
   psql -U postgres -h localhost -d gtfs_planner_dev
   ```

### host.docker.internal Not Found (Linux)

**Error**: `could not resolve host.docker.internal`

**Solution**: Make sure to add the `--add-host` flag:
```bash
docker run --add-host=host.docker.internal:host-gateway ...
```

Or use the `./scripts/docker-run.sh` script which handles this automatically.

## Environment Variables

You can customize these environment variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `DATABASE_URL` | PostgreSQL connection string | `ecto://postgres:postgres@host.docker.internal/gtfs_planner_dev` |
| `SECRET_KEY_BASE` | Phoenix secret key base | Generated or default |
| `PHX_SERVER` | Start Phoenix server | `true` |
| `PHX_HOST` | Application host | `localhost` |
| `PORT` | HTTP port | `4000` |

## Production Deployment

**Important**: This configuration is for local development only. For production:

1. Use a proper managed PostgreSQL service (RDS, Cloud SQL, etc.)
2. Generate a secure `SECRET_KEY_BASE`: `mix phx.gen.secret`
3. Use environment-specific configuration
4. Enable SSL for database connections
5. Use proper secrets management

## Alternative: Running PostgreSQL in Docker

If you prefer a fully containerized setup, see the main `docker-compose.yml` example in Option 3 from the analysis document.