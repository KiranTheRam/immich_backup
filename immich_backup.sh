#!/bin/bash

# Load configuration from .env file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "Error: .env file not found at ${ENV_FILE}"
    echo "Please create a .env file with the required configuration"
    exit 1
fi

source "$ENV_FILE"

# Validate required variables
if [ -z "$IMMICH_SERVER" ] || [ -z "$BACKUP_SERVER" ] || [ -z "$BACKUP_SERVER_PORT" ] || [ -z "$IMMICH_BACKUP_DIR" ] || [ -z "$BACKUP_DEST_BASE" ]; then
    echo "Error: Missing required configuration in .env file"
    echo "Required variables: IMMICH_SERVER, BACKUP_SERVER, BACKUP_SERVER_PORT, IMMICH_BACKUP_DIR, BACKUP_DEST_BASE"
    exit 1
fi

# Get current date in MM-DD-YYYY format
CURRENT_DATE=$(date +%m-%d-%Y)

# Get Immich version from the database (latest version)
echo "Getting Immich version..."
IMMICH_VERSION=$(ssh $IMMICH_SERVER "docker exec immich_postgres psql -U postgres -d immich -t -c 'select version from version_history order by \"createdAt\" desc limit 1'" | tr -d ' ')

if [ -z "$IMMICH_VERSION" ]; then
    echo "Error: Could not retrieve Immich version"
    exit 1
fi

echo "Immich version: $IMMICH_VERSION"

# Create backup filename with timestamp
BACKUP_FILENAME="dump_${CURRENT_DATE}.sql.gz"
FOLDER_NAME="${CURRENT_DATE} ${IMMICH_VERSION}"

echo "Creating database backup on Immich server..."
ssh $IMMICH_SERVER "docker exec -t immich_postgres pg_dumpall --clean --if-exists --username=postgres | gzip > '${IMMICH_BACKUP_DIR}/${BACKUP_FILENAME}'"

if [ $? -ne 0 ]; then
    echo "Error: Backup creation failed"
    exit 1
fi

echo "Backup created successfully: ${BACKUP_FILENAME}"

echo "Creating backup directory on backup server..."
ssh -p $BACKUP_SERVER_PORT $BACKUP_SERVER "mkdir -p '${BACKUP_DEST_BASE}/${FOLDER_NAME}'"

if [ $? -ne 0 ]; then
    echo "Error: Could not create backup directory"
    exit 1
fi

echo "Transferring backup to Raspberry Pi..."
rsync -av ${IMMICH_SERVER}:${IMMICH_BACKUP_DIR}/${BACKUP_FILENAME} /tmp/${BACKUP_FILENAME}

if [ $? -ne 0 ]; then
    echo "Error: Failed to download backup to Raspberry Pi"
    exit 1
fi

echo "Uploading backup to backup server..."
rsync -av -e "ssh -p ${BACKUP_SERVER_PORT}" /tmp/${BACKUP_FILENAME} "${BACKUP_SERVER}:${BACKUP_DEST_BASE}/${FOLDER_NAME}/"

if [ $? -ne 0 ]; then
    echo "Error: Failed to upload backup to backup server"
    rm /tmp/${BACKUP_FILENAME}
    exit 1
fi

echo "Cleaning up temporary file on Raspberry Pi..."
rm /tmp/${BACKUP_FILENAME}

echo "Backup completed successfully!"
echo "Location: ${BACKUP_DEST_BASE}/${FOLDER_NAME}/${BACKUP_FILENAME}"

# Optional: Clean up the backup file from the Immich server
if [ "${AUTO_CLEANUP}" = "true" ]; then
    echo "Auto-cleanup enabled, removing backup from Immich server..."
    ssh $IMMICH_SERVER "rm '${IMMICH_BACKUP_DIR}/${BACKUP_FILENAME}'"
    echo "Backup file removed from Immich server"
else
    read -p "Do you want to delete the backup from the Immich server? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        ssh $IMMICH_SERVER "rm '${IMMICH_BACKUP_DIR}/${BACKUP_FILENAME}'"
        echo "Backup file removed from Immich server"
    fi
fi
