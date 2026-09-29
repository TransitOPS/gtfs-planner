# Database Setup

## Install PostgreSQL

```bash
brew install postgresql@18
```

## Add psql to PATH

Add this to your `~/.zshrc`:

```bash
export PATH="/opt/homebrew/opt/postgresql@18/bin:$PATH"
```

Then reload:

```bash
source ~/.zshrc
```

## Start PostgreSQL

```bash
brew services start postgresql@18
```

## Create Role and Databases

Run these commands to set up the database for Phoenix:

```bash
psql -d postgres -c "CREATE ROLE postgres WITH LOGIN PASSWORD 'postgres' CREATEDB;"
psql -d postgres -c "CREATE DATABASE gtfs_planner_dev OWNER postgres;"
```

Tests connect as a separate `gtfs_planner_test` role that cannot reach the dev database. Create it once, as a Postgres superuser (`PGUSER`, default your own user, which owns a Homebrew server):

```bash
bin/setup-test-db-role
```

`mix test` creates its own `gtfs_planner_exunit*` databases as that role.

## Run Migrations

```bash
mix ecto.migrate
```

## Start the Server

```bash
mix phx.server
```

Visit [localhost:4000](http://localhost:4000) in your browser.