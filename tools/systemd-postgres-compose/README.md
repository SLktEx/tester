# systemd + PostgreSQL Compose example

A small Docker Compose example with:

- Ubuntu 26.04 running systemd as PID 1
- PostgreSQL 18
- PostgreSQL healthcheck with `pg_isready`
- startup ordering via `depends_on: condition: service_healthy`
- an end-to-end healthcheck from the systemd container to PostgreSQL using `psql SELECT 1`

## Requirements

- Docker Engine 28+ for `security_opt: writable-cgroups=true`
- cgroup v2
- rootful Docker (Docker currently rejects writable cgroups with rootless mode)

## Run

```bash
cd tools/systemd-postgres-compose
docker compose up -d --build
docker compose ps
```

Both services should eventually report `healthy`.

The systemd container connects to PostgreSQL through the Compose service name `postgres` on port `5432`; no PostgreSQL host port is published.

## Check systemd

```bash
docker compose exec systemd systemctl is-system-running
```

## Check PostgreSQL from the systemd container

```bash
docker compose exec systemd psql -c 'SELECT 1'
```

## Stop

```bash
docker compose down
```

To remove the PostgreSQL data volume as well:

```bash
docker compose down -v
```

PostgreSQL 18 uses `/var/lib/postgresql` as the image volume mount point, so the Compose file mounts the named volume there rather than the pre-18 `/var/lib/postgresql/data` path.
