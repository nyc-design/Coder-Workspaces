# Default - show available recipes
default:
    @just --list

# Build and start all services
up:
    docker compose -f services/docker-compose.dev.yml build
    docker compose -f services/docker-compose.dev.yml up -d

# Stop all services
down:
    docker compose -f services/docker-compose.dev.yml down

# Rebuild and restart
restart: down up

# View logs (optionally for a specific service)
logs service="":
    docker compose -f services/docker-compose.dev.yml logs -f {{service}}

# Show running containers
ps:
    docker compose -f services/docker-compose.dev.yml ps

# Start likec4 architecture viewer
arch:
    likec4 dev --listen 0.0.0.0 --port 4010
