#!/usr/bin/env bash
set -euo pipefail
umask 077

if [[ ! ${SSH_ORIGINAL_COMMAND:-} =~ ^deploy\ ([0-9a-f]{40})$ ]]; then
  printf 'Expected a deployment commit.\n' >&2
  exit 2
fi
revision=${BASH_REMATCH[1]}
cd /opt/smartrecruit
mkdir -p -m 700 backups
exec 9>backups/deploy.lock
flock -n 9

compose=(docker compose -p smartrecruit-production -f compose.production.yml -f compose.server.yml)
backend="smartrecruit-release-backend:$revision"
web="smartrecruit-release-web:$revision"
db=smartrecruit-production-postgres-1
backup=$(mktemp -d "backups/$(date -u +%Y%m%dT%H%M%SZ)-${revision:0:12}.XXXXXX")
bundle="$backup/images.tar.gz"
rehearsal=
resume_previous=false
cleanup() {
  local status=$?
  rm -f -- "$bundle"
  if [[ -n $rehearsal ]]; then
    docker exec "$db" sh -ec 'dropdb --if-exists -U "$POSTGRES_USER" "$1"' _ "$rehearsal" || true
  fi
  if [[ $resume_previous == true ]]; then
    "${compose[@]}" start api worker || true
  fi
  if (( status != 0 )); then printf 'Deployment failed. Release files: %s\n' "$backup" >&2; fi
}
trap cleanup EXIT

cat > "$bundle"
docker load -i "$bundle"
rm -f -- "$bundle"
docker image inspect "$backend" "$web" --format '{{.Os}}/{{.Architecture}}' | awk '$0 != "linux/amd64" { exit 1 }'

for service in api worker web; do
  docker inspect "smartrecruit-production-$service-1" --format '{{.Image}}' > "$backup/$service.image-id"
done
cp -p deploy/runtime.production.env "$backup/runtime.production.env"

printf 'services:\n  api:\n    image: %s\n' "$backend" > "$backup/candidate.yml"
candidate=("${compose[@]}" -f "$backup/candidate.yml")
"${candidate[@]}" config --quiet
"${candidate[@]}" run --rm --no-deps --pull never api node scripts/migrate-postgres.mjs --status

# Keep the pre-upgrade dump consistent with application writes.
resume_previous=true
"${compose[@]}" stop api worker
docker exec "$db" sh -ec 'pg_dump -Fc -U "$POSTGRES_USER" -d "$POSTGRES_DB"' > "$backup/postgres.dump"
rehearsal="release_check_${revision:0:12}_$$"
docker exec "$db" sh -ec 'createdb -U "$POSTGRES_USER" "$1"' _ "$rehearsal"
docker exec -i "$db" sh -ec 'pg_restore --exit-on-error -U "$POSTGRES_USER" -d "$1"' _ "$rehearsal" < "$backup/postgres.dump"
"${candidate[@]}" run --rm --no-deps --pull never -e DATABASE_URL= -e "PGDATABASE=$rehearsal" api node scripts/migrate-postgres.mjs
"${candidate[@]}" run --rm --no-deps --pull never -e DATABASE_URL= -e "PGDATABASE=$rehearsal" api node scripts/migrate-postgres.mjs --check
docker exec "$db" sh -ec 'dropdb -U "$POSTGRES_USER" "$1"' _ "$rehearsal"
rehearsal=
printf 'Pre-upgrade backup: %s\n' "$backup"

resume_previous=false
"${candidate[@]}" run --rm --no-deps --pull never api node scripts/migrate-postgres.mjs
"${candidate[@]}" run --rm --no-deps --pull never api node scripts/migrate-postgres.mjs --check

# The default image names remain usable for subsequent maintenance commands.
docker tag "$backend" smartrecruit-backend:local
docker tag "$web" smartrecruit-production-web:latest
"${compose[@]}" up -d --force-recreate --no-deps --no-build --pull never --wait --wait-timeout 180 api worker web
"${compose[@]}" ps api worker web
printf 'Deployed %s\n' "$revision"
