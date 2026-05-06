#!/bin/bash
set -e

echo "=== Loading database connection info from config file ==="
# Load config file, extracting only the variables we need
CONFIG_FILE="/opt/config.properties"
if [ -f "$CONFIG_FILE" ]; then
  echo "Found config file: $CONFIG_FILE"
  # Extract only the CFNDBURL variable, avoiding execution of other possible commands
  CFNDBURL=$(grep "^CFNDBURL=" "$CONFIG_FILE" | cut -d'=' -f2-)
  AWSREGION=$(grep "^AWSREGION=" "$CONFIG_FILE" | cut -d'=' -f2-)

  if [ -z "$CFNDBURL" ]; then
    echo "Error: CFNDBURL not found in config file"
    exit 1
  fi

  echo "Successfully extracted database connection info"
else
  echo "Error: config file $CONFIG_FILE does not exist"
  exit 1
fi

echo "Retrieving database connection info from Secrets Manager..."
# Read all database connection information from Secrets Manager
DB_CREDENTIAL_SECRET=$(grep "^CFNDBCredentialSecretName=" "$CONFIG_FILE" | cut -d'=' -f2-)
DB_SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id "$DB_CREDENTIAL_SECRET" --query SecretString --output text)
DB_HOST=$(echo "$DB_SECRET_JSON" | jq -r '.host')
DB_USER=$(echo "$DB_SECRET_JSON" | jq -r '.username')
DB_NAME=$(echo "$DB_SECRET_JSON" | jq -r '.dbname')
DB_PASSWORD=$(echo "$DB_SECRET_JSON" | jq -r '.password')

echo "Database connection info:"
echo "- Host: $DB_HOST"
echo "- Database: $DB_NAME"
echo "- User: $DB_USER"
echo "- Password: ********"

# Check database connection
echo -e "\n=== Checking database connection ==="
max_attempts=5
attempt=0

while [ $attempt -lt $max_attempts ]; do
  attempt=$((attempt+1))
  echo "Attempting to connect to database... attempt $attempt/$max_attempts"

  if PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "SELECT 1" > /dev/null 2>&1; then
    echo "Database connection successful!"
    break
  else
    echo "Connection failed, waiting to retry..."
    if [ $attempt -eq $max_attempts ]; then
      echo "Error: unable to connect to database, maximum attempts exceeded"
      echo "Please check database connection info and network connectivity"
      exit 1
    fi
    sleep 5
  fi
done

# Execute all SQL files sorted by filename
echo -e "\n=== Starting SQL migrations ==="
for sql_file in $(ls -v *.sql); do
  echo "Executing: $sql_file"
  if ! PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -U $DB_USER -d $DB_NAME -f $sql_file; then
    echo "Execution of $sql_file failed, retrying..."
    # Retry up to 3 times
    for i in {1..3}; do
      echo "Retry $i/3..."
      if PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -U $DB_USER -d $DB_NAME -f $sql_file; then
        echo "Retry successful!"
        break
      fi
      if [ $i -eq 3 ]; then
        echo "Execution of $sql_file failed, please check SQL syntax"
        exit 1
      fi
      sleep 2
    done
  fi
done

echo "All SQL migrations completed successfully"

# Check that all tables exist
echo -e "\n=== Checking database tables ==="
PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
SELECT table_schema, table_name 
FROM information_schema.tables 
WHERE table_schema NOT IN ('pg_catalog', 'information_schema') 
ORDER BY table_schema, table_name;"

echo -e "\n=== Migration complete! ==="
