#!/bin/bash
set -e

echo "=== Loading database connection info from config file ==="
# Load config file, extracting only the variables we need
CONFIG_FILE="/opt/config.properties"
if [ -f "$CONFIG_FILE" ]; then
  echo "Found config file: $CONFIG_FILE"
  # Extract only the CFNDBURL variable, avoiding execution of other possible commands
  echo "Successfully found config file"
else
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

echo "Checking tables in database..."

# Extract CREATE TABLE statements from all SQL files to get table names
echo "Analyzing table definitions in SQL files..."
expected_tables=$(grep -h -i "CREATE TABLE" *.sql | grep -v "IF NOT EXISTS" | sed -E 's/.*CREATE TABLE[[:space:]]+([^[:space:]()]+).*/\1/i' | sort | uniq)

# If no tables found, it may be due to different table name format, try another approach
if [ -z "$expected_tables" ]; then
  expected_tables=$(grep -h -i "CREATE TABLE" *.sql | grep -v "IF NOT EXISTS" | sed -E 's/.*CREATE TABLE[[:space:]]+"?([^"[:space:]()]+)"?.*/\1/i' | sort | uniq)
fi

echo "Expected tables:"
echo "$expected_tables"

# Get actual tables from database
echo -e "\nRetrieving actual tables from database..."
actual_tables=$(PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -U $DB_USER -d $DB_NAME -t -c "
SELECT table_name 
FROM information_schema.tables 
WHERE table_schema NOT IN ('pg_catalog', 'information_schema') 
AND table_type = 'BASE TABLE'
ORDER BY table_name;")

echo "Tables in database:"
echo "$actual_tables"

# Check if all expected tables exist
echo -e "\nVerifying table existence..."
missing_tables=0

for table in $expected_tables; do
  # Remove quotes and schema prefix
  clean_table=$(echo $table | sed 's/"//g' | sed 's/.*\.//')
  if ! echo "$actual_tables" | grep -q "$clean_table"; then
    echo "❌ Table '$clean_table' does not exist!"
    missing_tables=$((missing_tables+1))
  else
    echo "✅ Table '$clean_table' exists"
  fi
done

if [ $missing_tables -eq 0 ]; then
  echo -e "\n✅ All tables created successfully!"
else
  echo -e "\n❌ $missing_tables table(s) failed to create, please check SQL files"
  exit 1
fi
