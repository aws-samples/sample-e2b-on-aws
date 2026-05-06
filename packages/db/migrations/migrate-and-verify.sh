#!/bin/bash
set -e

echo "=== Starting database migration and verification ==="

# Check if config file exists
CONFIG_FILE="/opt/config.properties"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "Error: config file $CONFIG_FILE does not exist"
  exit 1
fi

# Read all database connection information from Secrets Manager
DB_CREDENTIAL_SECRET=$(grep "^CFNDBCredentialSecretName=" "$CONFIG_FILE" | cut -d'=' -f2-)
DB_SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id "$DB_CREDENTIAL_SECRET" --query SecretString --output text)
DB_HOST=$(echo "$DB_SECRET_JSON" | jq -r '.host')
DB_USER=$(echo "$DB_SECRET_JSON" | jq -r '.username')
DB_NAME=$(echo "$DB_SECRET_JSON" | jq -r '.dbname')
DB_PASSWORD=$(echo "$DB_SECRET_JSON" | jq -r '.password')
AWSREGION=$(grep "^AWSREGION=" "$CONFIG_FILE" | cut -d'=' -f2-)

echo "Database connection info:"
echo "- Host: $DB_HOST"
echo "- Database: $DB_NAME"
echo "- User: $DB_USER"
echo "- Password: ********"
echo "- Region: $AWSREGION"

# Execute migrations
echo -e "\n=== Executing SQL migrations ==="
./run-all-migrations.sh

# Verify tables
echo -e "\n=== Verifying database tables ==="
./check-tables.sh

echo -e "\n=== Migration and verification complete ==="
echo "Database successfully initialized, all tables created"
echo "Database connection info:"
echo "- Host: $DB_HOST"
echo "- Database: $DB_NAME"
echo "- User: $DB_USER"
