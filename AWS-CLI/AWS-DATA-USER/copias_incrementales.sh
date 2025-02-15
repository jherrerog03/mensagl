# Se necesita tener AWS CLI, configurado e instalado

#!/bin/bash
# Configuración
DATE=$(date +%F)
BUCKET_NAME="backups-jherrerog"
DB1_HOST="10.211.3.10"
RDS_ENDPOINT="wordpress-db.cshuhd8ziwqh.us-east-1.rds.amazonaws.com"
DB1_USER="backup_user"
RDS_USER="admin"
DB1_PASS="Admin123"
RDS_PASS="Admin123"
DB_NAME_PROSODY="prosody"
DB_NAME_WP="wordpress_db"
BACKUP_DIR="/tmp/db_backups"

# Crear directorio temporal
mkdir -p $BACKUP_DIR

# Dump de la base de datos Prosody (Principal) usando usuario backup_user
mysqldump --single-transaction -h $DB1_HOST -u $DB1_USER -p$DB1_PASS $DB_NAME_PROSODY > $BACKUP_DIR/prosody-primary-$DATE.sql

# Dump de la base de datos WordPress usando admin
mysqldump --single-transaction --set-gtid-purged=OFF -h $RDS_ENDPOINT -u $RDS_USER -p$RDS_PASS $DB_NAME_WP > $BACKUP_DIR/wordpress-$DATE.sql

# Comprimir los archivos
tar -czvf $BACKUP_DIR/backup-$DATE.tar.gz $BACKUP_DIR/*.sql

# Subir a S3
aws s3 cp $BACKUP_DIR/backup-$DATE.tar.gz s3://$BUCKET_NAME/$DATE/

# Limpiar archivos temporales
rm -rf $BACKUP_DIR