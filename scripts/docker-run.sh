#!/bin/bash
#
# Run the GTFS Planner Docker container
#
# Usage:
#   ./scripts/docker-run.sh
#
# Prerequisites:
#   - Docker image built (run ./scripts/docker-build.sh first)
#   - PostgreSQL running locally on default port 5432
#   - Database gtfs_planner_dev exists
#

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Check if image exists
if ! docker images | grep -q gtfs-planner; then
    echo -e "${RED}Error: Docker image 'gtfs-planner' not found${NC}"
    echo -e "${YELLOW}Build it first with: ./scripts/docker-build.sh${NC}"
    exit 1
fi

echo -e "${GREEN}==> Checking prerequisites...${NC}"

# Check PostgreSQL
if command -v pg_isready &> /dev/null; then
    if pg_isready -h localhost -p 5432 > /dev/null 2>&1; then
        echo -e "${GREEN}✓ PostgreSQL is running${NC}"
    else
        echo -e "${YELLOW}Warning: PostgreSQL doesn't appear to be running on localhost:5432${NC}"
    fi
fi

# Check if database exists
if command -v psql &> /dev/null; then
    if psql -h localhost -U postgres -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw gtfs_planner_dev; then
        echo -e "${GREEN}✓ Database gtfs_planner_dev found${NC}"
    else
        echo -e "${YELLOW}Warning: Database gtfs_planner_dev not found${NC}"
        echo -e "${YELLOW}Create it with: mix ecto.create${NC}"
    fi
fi

# Generate SECRET_KEY_BASE if not set
if [ -z "$SECRET_KEY_BASE" ]; then
    SECRET_KEY_BASE="$(openssl rand -base64 48)"
fi

# Determine platform and set appropriate args
EXTRA_ARGS=""
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    EXTRA_ARGS="--add-host=host.docker.internal:host-gateway"
    echo -e "${GREEN}✓ Detected Linux - using host-gateway${NC}"
else
    echo -e "${GREEN}✓ Detected Mac/Windows - using built-in host.docker.internal${NC}"
fi

DATABASE_URL="ecto://postgres:postgres@host.docker.internal/gtfs_planner_dev"

echo ""
echo -e "${GREEN}==> Starting container...${NC}"
echo "Access the app at: http://localhost:4000"
echo "Health check at: http://localhost:4000/health"
echo ""
echo "Press Ctrl+C to stop the container"
echo ""

# Run the container
docker run -it --rm \
    -p 4000:4000 \
    -e DATABASE_URL="$DATABASE_URL" \
    -e SECRET_KEY_BASE="$SECRET_KEY_BASE" \
    -e PHX_SERVER=true \
    -e PHX_HOST=localhost \
    -e PORT=4000 \
    -e PHX_CHECK_ORIGIN=false \
    $EXTRA_ARGS \
    --name gtfs-planner-dev \
    gtfs-planner