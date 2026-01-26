#!/bin/bash
#
# Build the Docker image for GTFS Planner
#
# Usage:
#   ./scripts/docker-build.sh
#

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}==> Building GTFS Planner Docker image...${NC}"
echo -e "${YELLOW}This may take several minutes on first build${NC}"
echo ""

# Build the image
docker build -t gtfs-planner .

echo ""
echo -e "${GREEN}✓ Docker image built successfully!${NC}"
echo ""
echo "View the image:"
echo "  docker images | grep gtfs-planner"
echo ""
echo "Run the container:"
echo "  ./scripts/docker-run.sh"