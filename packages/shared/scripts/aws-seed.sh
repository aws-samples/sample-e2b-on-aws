#!/bin/bash
set -e

echo "AWS Database Seed Script"
echo "========================"

# Ensure all required environment variables are set
DB_HOST=${DB_HOST:-"database-e2b.cluster-cqjwsuyea136.us-east-1.rds.amazonaws.com"}
DB_PORT=${DB_PORT:-"5432"}
DB_USER=${DB_USER:-"postgres"}
DB_PASSWORD=${DB_PASSWORD:-"Longyuan123"}
DB_NAME=${DB_NAME:-"postgres"}

echo "Using database: $DB_HOST"

# Create the team
TEAM_SQL="
INSERT INTO teams (id, name, email, tier) 
VALUES ('00000000-0000-0000-0000-000000000000', 'E2B', 'admin@example.com', 'base_v1')
ON CONFLICT (id) DO UPDATE SET name = 'E2B', email = 'admin@example.com'
RETURNING id;"

# Create a user
USER_ID=$(uuidgen)
USER_SQL="
INSERT INTO users (id, email)
VALUES ('$USER_ID', 'admin@example.com')
ON CONFLICT (email) DO UPDATE SET email = 'admin@example.com'
RETURNING id;"

# Associate user with team
USER_TEAM_SQL="
INSERT INTO users_teams (user_id, team_id, is_default)
VALUES ('$USER_ID', '00000000-0000-0000-0000-000000000000', true)
ON CONFLICT (user_id, team_id) DO UPDATE SET is_default = true;"

# Create access token
TOKEN_SQL="
INSERT INTO access_tokens (id, user_id)
VALUES ('e2b_access_token', '$USER_ID')
ON CONFLICT (id) DO UPDATE SET user_id = '$USER_ID';"

# Create team API key
TEAM_API_KEY_SQL="
INSERT INTO team_api_keys (api_key, team_id)
VALUES ('e2b_team_api_key', '00000000-0000-0000-0000-000000000000')
ON CONFLICT (api_key) DO UPDATE SET team_id = '00000000-0000-0000-0000-000000000000';"

# Create environment (template)
ENV_SQL="
INSERT INTO envs (id, team_id, public)
VALUES ('rki5dems9wqfm4r03t7g', '00000000-0000-0000-0000-000000000000', true)
ON CONFLICT (id) DO UPDATE SET team_id = '00000000-0000-0000-0000-000000000000', public = true;"

# Combine all SQL statements
SQL="BEGIN;
$TEAM_SQL
$USER_SQL
$USER_TEAM_SQL
$TOKEN_SQL
$TEAM_API_KEY_SQL
$ENV_SQL
COMMIT;"

# Execute the SQL against the database
export PGPASSWORD="$DB_PASSWORD"
echo "$SQL" | psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1

echo "Database seeded successfully for AWS environment"