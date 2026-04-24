#!/bin/bash
# init-db.sh - One-click database initialization (including table creation and data population)

set -e

# Change to the directory of the script
cd "$(dirname "$0")"

MIGRATION_SQL="./.migration.sql"
SEED_SQL="./.seed-db.sql"
CONFIG_FILE="/opt/config.properties"


# First, execute init-config.sh to generate configuration
echo "Generating configuration file..."
if [ -f "./init-config.sh" ]; then
    bash ./init-config.sh
    if [ $? -ne 0 ]; then
        echo "Error: Failed to generate configuration"
        exit 1
    fi
    echo "Configuration generated successfully!"
else
    echo "Error: init-config.sh not found"
    exit 1
fi
# Check if config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file $CONFIG_FILE does not exist"
    exit 1
fi

# Read all database connection information from Secrets Manager
DB_CREDENTIAL_SECRET=$(grep "^CFNDBCredentialSecretName=" "$CONFIG_FILE" | cut -d'=' -f2)
DB_SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id "$DB_CREDENTIAL_SECRET" --query SecretString --output text)
DB_HOST=$(echo "$DB_SECRET_JSON" | jq -r '.host')
DB_PORT=$(echo "$DB_SECRET_JSON" | jq -r '.port')
DB_NAME=$(echo "$DB_SECRET_JSON" | jq -r '.dbname')
DB_USER=$(echo "$DB_SECRET_JSON" | jq -r '.username')
DB_PASSWORD=$(echo "$DB_SECRET_JSON" | jq -r '.password')

# Check if all database variables are set
for VAR_NAME in DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD; do
    VAR_VALUE=${!VAR_NAME}
    if [ -z "$VAR_VALUE" ]; then
        echo "Error: $VAR_NAME variable is missing in the configuration file"
        exit 1
    fi
    if [ "$VAR_NAME" = "DB_PASSWORD" ]; then
        echo "Using $VAR_NAME = ***"
    else
        echo "Using $VAR_NAME = $VAR_VALUE"
    fi
done

# Check if migration.sql exists
if [ ! -f "$MIGRATION_SQL" ]; then
    echo "Error: migration.sql file not found: $MIGRATION_SQL"
    exit 1
fi

# Check if seed-db.sql exists
if [ ! -f "$SEED_SQL" ]; then
    echo "Error: seed-db.sql file not found: $SEED_SQL"
    exit 1
fi

# Read E2B configuration from Secrets Manager
echo "Reading E2B configuration from Secrets Manager..."
AWSREGION=$(grep "^AWSREGION=" "$CONFIG_FILE" | cut -d'=' -f2)
E2B_CONFIG_SECRET=$(grep "^e2b_config_secret_name=" "$CONFIG_FILE" | cut -d'=' -f2)
E2B_CONFIG_JSON=$(aws secretsmanager get-secret-value \
    --secret-id "$E2B_CONFIG_SECRET" --region "$AWSREGION" \
    --query SecretString --output text)

if [ -z "$E2B_CONFIG_JSON" ]; then
    echo "Error: Failed to retrieve E2B config from Secrets Manager"
    exit 1
fi

email=$(echo "$E2B_CONFIG_JSON" | jq -r '.email')
teamId=$(echo "$E2B_CONFIG_JSON" | jq -r '.teamId')
accessToken=$(echo "$E2B_CONFIG_JSON" | jq -r '.accessToken')
teamApiKey=$(echo "$E2B_CONFIG_JSON" | jq -r '.teamApiKey')

# Check database connection
if ! PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -c '\q' &>/dev/null; then
    echo "Error: Cannot connect to PostgreSQL database server. Please check connection parameters."
    exit 1
fi

# Step 1: Execute migration.sql to create table structure
PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -f "$MIGRATION_SQL"
if [ $? -ne 0 ]; then
    echo "Error: Table structure creation failed"
    exit 1
fi
echo "Table structure created successfully!"

# Step 2: Check if database contains data
TEAM_COUNT=$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM teams;" 2>/dev/null || echo "0")
TEAM_COUNT=$(echo $TEAM_COUNT | tr -d ' ')

if [ "$TEAM_COUNT" = "" ] || [ "$TEAM_COUNT" = "0" ]; then
    # Step 3: Execute seed-db.sql to populate initial data
    PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
        -v email="$email" \
        -v teamID="$teamId" \
        -v accessToken="$accessToken" \
        -v teamAPIKey="$teamApiKey" \
        -f "$SEED_SQL"
    
    if [ $? -ne 0 ]; then
        echo "Error: Data population failed"
        exit 1
    fi
    echo "Database initialization completed!"
elif [ "$TEAM_COUNT" -gt 1 ]; then
    echo "Database already contains data (team count: $TEAM_COUNT). Skipping data population step."
else
    echo "Database already has one team. To reinitialize, please clear the database first."
fi

echo "==================="
echo "User: $email"
echo "Team ID: $teamId"
echo "Access Token: ***${accessToken: -4}"
echo "Team API Key: ***${teamApiKey: -4}"
