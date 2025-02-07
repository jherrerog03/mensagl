#!/bin/bash

# ARCHIVO DE LOG
LOG_FILE="laboratorio.log"
# Redirigir toda la salida al archivo de log


###########################################                       
#            VARIABLES DE PRUEBA          #
###########################################

# Variables VPC
read -r -p "Pon el nombre del laboratorio: " NOMBRE_ALUMNO
REGION="us-east-1"

# Variables AMI-ID (Ubuntu server 24.04) y CLAVE SSH
KEY_NAME="ssh-mensagl-2025-${NOMBRE_ALUMNO}"
AMI_ID="ami-04b4f1a9cf54c11d0" # Llamar variable claves         

# Crear par de claves SSH
aws ec2 create-key-pair \
    --key-name "${KEY_NAME}" \
    --query "KeyMaterial" \
    --output text > "${KEY_NAME}.pem"
chmod 400 "${KEY_NAME}.pem"
echo "Clave SSH creada: ${KEY_NAME}.pem"


# Variables para RDS, se pueden cambiar los valores por los deseados
RDS_INSTANCE_ID="wordpress-db"
read -r -p "Ingrese el nombre de la base de datos: " DB_NAME
read -r -p "Ingrese el nombre de usuario de la BD: " DB_USERNAME
read -r -p "Ingrese la contraseña de la BD: " DB_PASSWORD


exec > "$LOG_FILE" 2>&1

##############################                       
#             VPC            #
##############################

# Crear VPC
VPC_ID=$(aws ec2 create-vpc --cidr-block "10.225.0.0/16" --query 'Vpc.VpcId' --output text)
aws ec2 create-tags --resources "$VPC_ID" --tags Key=Name,Value="vpc-mensagl-2025-${NOMBRE_ALUMNO}"

# Crear Subnets publicas
SUBNET_PUBLIC1_ID=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "10.225.1.0/24" --availability-zone "${REGION}a" --query 'Subnet.SubnetId' --output text)
SUBNET_PUBLIC2_ID=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "10.225.2.0/24" --availability-zone "${REGION}b" --query 'Subnet.SubnetId' --output text)

# Crear Subnets privadas
SUBNET_PRIVATE1_ID=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "10.225.3.0/24" --availability-zone "${REGION}a" --query 'Subnet.SubnetId' --output text)
SUBNET_PRIVATE2_ID=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "10.225.4.0/24" --availability-zone "${REGION}b" --query 'Subnet.SubnetId' --output text)

# Crear Internet Gateway
IGW_ID=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --vpc-id "$VPC_ID" --internet-gateway-id "$IGW_ID"

# Crear Tabla de Rutas Públicas
RTB_PUBLIC_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id "$RTB_PUBLIC_ID" --destination-cidr-block "0.0.0.0/0" --gateway-id "$IGW_ID"
aws ec2 associate-route-table --subnet-id "$SUBNET_PUBLIC1_ID" --route-table-id "$RTB_PUBLIC_ID"
aws ec2 associate-route-table --subnet-id "$SUBNET_PUBLIC2_ID" --route-table-id "$RTB_PUBLIC_ID"

# Crear Elastic IP y NAT Gateway
EIP_ID=$(aws ec2 allocate-address --query 'AllocationId' --output text)
NAT_ID=$(aws ec2 create-nat-gateway --subnet-id "$SUBNET_PUBLIC1_ID" --allocation-id "$EIP_ID" --query 'NatGateway.NatGatewayId' --output text)

echo "Creando GATEWAY NAT..."
while true; do
    STATUS=$(aws ec2 describe-nat-gateways --nat-gateway-ids "$NAT_ID" --query 'NatGateways[0].State' --output text)
    echo "Estado del NAT Gateway: $STATUS"
    if [ "$STATUS" == "available" ]; then
        break
    fi
    sleep 10
done

# Crear Tabla de Rutas Privadas
RTB_PRIVATE1_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id "$RTB_PRIVATE1_ID" --destination-cidr-block "0.0.0.0/0" --nat-gateway-id "$NAT_ID"
aws ec2 associate-route-table --subnet-id "$SUBNET_PRIVATE1_ID" --route-table-id "$RTB_PRIVATE1_ID"

RTB_PRIVATE2_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id "$RTB_PRIVATE2_ID" --destination-cidr-block "0.0.0.0/0" --nat-gateway-id "$NAT_ID"
aws ec2 associate-route-table --subnet-id "$SUBNET_PRIVATE2_ID" --route-table-id "$RTB_PRIVATE2_ID"

##############################                       
# Crear Grupos de Seguridad  #
##############################

# Grupo de seguridad para los Proxy Inversos
SG_PROXY_ID=$(aws ec2 create-security-group --group-name "sg_proxy_inverso" --description "SG para el proxy inverso" --vpc-id "$VPC_ID" --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id "$SG_PROXY_ID" --protocol tcp --port 22 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_PROXY_ID" --protocol tcp --port 443 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_PROXY_ID" --protocol tcp --port 8448 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-egress --group-id "$SG_PROXY_ID" --protocol -1 --port all --cidr "0.0.0.0/0"

# Grupo de seguridad para el CMS
SG_CMS_ID=$(aws ec2 create-security-group --group-name "sg_cms" --description "SG para el cluster CMS" --vpc-id "$VPC_ID" --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id "$SG_CMS_ID" --protocol tcp --port 22 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_CMS_ID" --protocol tcp --port 80 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_CMS_ID" --protocol tcp --port 443 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_CMS_ID" --protocol tcp --port 33060 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_CMS_ID" --protocol tcp --port 53 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-egress --group-id "$SG_CMS_ID" --protocol -1 --port all --cidr "0.0.0.0/0"

# Grupo de seguridad para MySQL
SG_MYSQL_ID=$(aws ec2 create-security-group --group-name "sg_mysql" --description "SG para servidores MySQL" --vpc-id "$VPC_ID" --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id "$SG_MYSQL_ID" --protocol tcp --port 22 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_MYSQL_ID" --protocol tcp --port 3306 --source-group "$SG_MYSQL_ID"
aws ec2 authorize-security-group-ingress --group-id "$SG_MYSQL_ID" --protocol tcp --port 3306 --cidr "$(aws ec2 describe-subnets --subnet-ids "$SUBNET_PRIVATE1_ID" --query 'Subnets[0].CidrBlock' --output text)"
aws ec2 authorize-security-group-egress --group-id "$SG_MYSQL_ID" --protocol -1 --port all --cidr "0.0.0.0/0"

# Grupo de seguridad para Mensajeria (XMPP Prosody + MySQL)
SG_MENSAJERIA_ID=$(aws ec2 create-security-group --group-name "sg_mensajeria" --description "SG para XMPP Prosody y MySQL" --vpc-id "$VPC_ID" --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id "$SG_MENSAJERIA_ID" --protocol tcp --port 5222 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_MENSAJERIA_ID" --protocol tcp --port 5347 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_MENSAJERIA_ID" --protocol tcp --port 3306 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_MENSAJERIA_ID" --protocol udp --port 10000 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_MENSAJERIA_ID" --protocol tcp --port 5269 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_MENSAJERIA_ID" --protocol tcp --port 4443 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_MENSAJERIA_ID" --protocol tcp --port 5281 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_MENSAJERIA_ID" --protocol tcp --port 5280 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_MENSAJERIA_ID" --protocol tcp --port 80 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_MENSAJERIA_ID" --protocol tcp --port 22 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_MENSAJERIA_ID" --protocol tcp --port 443 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-egress --group-id "$SG_MENSAJERIA_ID" --protocol -1 --port all --cidr "0.0.0.0/0"

##############################                       
#             RDS             #
##############################

# Crear subnet RD
aws rds create-db-subnet-group \
    --db-subnet-group-name wp-rds-subnet-group \
    --db-subnet-group-description "RDS Subnet Group for WordPress" \
    --subnet-ids "$SUBNET_PRIVATE1_ID" "$SUBNET_PRIVATE2_ID"


# SG de RDS
SG_ID_RDS=$(aws ec2 create-security-group \
  --group-name "RDS-MySQL" \
  --description "SG para RDS MySQL" \
  --vpc-id "$VPC_ID" \
  --query 'GroupId' \
  --output text)

# Permitir acceso MySQL
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID_RDS" \
  --protocol tcp \
  --port 3306 \
  --cidr 0.0.0.0/0  

# Crear instancia RDS (Single-AZ en Private Subnet 2)
aws rds create-db-instance \
    --db-instance-identifier "$RDS_INSTANCE_ID" \
    --db-instance-class db.t3.medium \
    --engine mysql \
    --allocated-storage 20 \
    --storage-type gp2 \
    --master-username "$DB_USERNAME" \
    --master-user-password "$DB_PASSWORD" \
    --db-subnet-group-name wp-rds-subnet-group \
    --vpc-security-group-ids "$SG_ID_RDS" \
    --backup-retention-period 7 \
    --no-publicly-accessible \
    --availability-zone "us-east-1b" \
    --no-multi-az  # Se asegura que no se despliega en multiple AZ

# ESPERA A QUE EL RDS ESTE DISPONIBLE
echo "ESPERANDO A QUE EL RDS ESTE DISPONIBLE..."
aws rds wait db-instance-available --db-instance-identifier "$RDS_INSTANCE_ID"

# Recibe el RDS ENDPOINT PARA USARLO MAS ADELANTE
RDS_ENDPOINT=$(aws rds describe-db-instances \
    --db-instance-identifier "$RDS_INSTANCE_ID" \
    --query 'DBInstances[0].Endpoint.Address' \
    --output text)
echo "RDS Endpoint: $RDS_ENDPOINT"

##################################################                       
#             INSTANCIAS Y SERVICIOS             #
##################################################
# proxy-prosody
INSTANCE_NAME="proxy-prosody"
SUBNET_ID="${SUBNET_PUBLIC1_ID}"
SECURITY_GROUP_ID="${SG_PROXY_ID}"
PRIVATE_IP="10.225.1.10"
INSTANCE_TYPE="t2.micro"
VOLUME_SIZE=8

USER_DATA_SCRIPT=$(cat DATOS-DE-USUARIO/haproxy_prosody.sh)

INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$VOLUME_SIZE,VolumeType=gp3,DeleteOnTermination=true}" \
    --network-interfaces "SubnetId=$SUBNET_ID,AssociatePublicIpAddress=true,DeviceIndex=0,PrivateIpAddresses=[{Primary=true,PrivateIpAddress=$PRIVATE_IP}],Groups=[$SECURITY_GROUP_ID]" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
    --query "Instances[0].InstanceId" \
    --output text)
echo "${INSTANCE_NAME} creada: ${INSTANCE_ID}"

# PROXY-2
INSTANCE_NAME="proxy-wordpress"
SUBNET_ID="${SUBNET_PUBLIC2_ID}"
PRIVATE_IP="10.225.2.10"

USER_DATA_SCRIPT=$(cat DATOS-DE-USUARIO/haproxy_wordpress.sh)

INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$VOLUME_SIZE,VolumeType=gp3,DeleteOnTermination=true}" \
    --network-interfaces "SubnetId=$SUBNET_ID,AssociatePublicIpAddress=true,DeviceIndex=0,PrivateIpAddresses=[{Primary=true,PrivateIpAddress=$PRIVATE_IP}],Groups=[$SECURITY_GROUP_ID]" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
    --user-data "$USER_DATA_SCRIPT" \
    --query "Instances[0].InstanceId" \
    --output text)
echo "${INSTANCE_NAME} creada: ${INSTANCE_ID}"
##############
#    MySQL   #
##############
# sgbd_principal
INSTANCE_NAME="sgbd_principal-zona1"
SUBNET_ID="${SUBNET_PRIVATE1_ID}"
SECURITY_GROUP_ID="${SG_MYSQL_ID}"
PRIVATE_IP="10.225.3.10"

# Cargar el script para la base de datos primaria
USER_DATA_SCRIPT=$(sed 's/role=".*"/role="primary"/' DATOS-DE-USUARIO/configuracion-bd-primaria-y-slave.sh)

INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$VOLUME_SIZE,VolumeType=gp3,DeleteOnTermination=true}" \
    --network-interfaces "SubnetId=$SUBNET_ID,DeviceIndex=0,PrivateIpAddresses=[{Primary=true,PrivateIpAddress=$PRIVATE_IP}],Groups=[$SECURITY_GROUP_ID]" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
    --user-data "$USER_DATA_SCRIPT" \
    --query "Instances[0].InstanceId" \
    --output text)
echo "${INSTANCE_NAME} creada: ${INSTANCE_ID}"

# sgbd_secundario
INSTANCE_NAME="sgbd_replica-zona1"
PRIVATE_IP="10.225.3.11"

# Cargar el script para la base de datos secundaria
USER_DATA_SCRIPT=$(sed 's/role=".*"/role="secondary"/' DATOS-DE-USUARIO/configuracion-bd-primaria-y-slave.sh)

INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$VOLUME_SIZE,VolumeType=gp3,DeleteOnTermination=true}" \
    --network-interfaces "SubnetId=$SUBNET_ID,DeviceIndex=0,PrivateIpAddresses=[{Primary=true,PrivateIpAddress=$PRIVATE_IP}],Groups=[$SECURITY_GROUP_ID]" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
    --user-data "$USER_DATA_SCRIPT" \
    --query "Instances[0].InstanceId" \
    --output text)
echo "${INSTANCE_NAME} creada: ${INSTANCE_ID}"


##############
#    XMPP    #
#############
# mensajeria-1
INSTANCE_NAME="mensajeria-1"
SUBNET_ID="${SUBNET_PRIVATE1_ID}"
SECURITY_GROUP_ID="${SG_MENSAJERIA_ID}"
PRIVATE_IP="10.225.3.20"

#USER_DATA_SCRIPT=$(cat <<EOF
#EOF
#)

# INSTANCE_ID=$(aws ec2 run-instances \
#     --image-id "$AMI_ID" \
#     --instance-type "$INSTANCE_TYPE" \
#     --key-name "$KEY_NAME" \
#     --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$VOLUME_SIZE,VolumeType=gp3,DeleteOnTermination=true}" \
#     --network-interfaces "SubnetId=$SUBNET_ID,DeviceIndex=0,PrivateIpAddresses=[{Primary=true,PrivateIpAddress=$PRIVATE_IP}],Groups=[$SECURITY_GROUP_ID]" \
#     --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
#     --user-data "$USER_DATA_SCRIPT" \
#     --query "Instances[0].InstanceId" \
#     --output text)
# echo "${INSTANCE_NAME} creada: ${INSTANCE_ID}"

# # mensajeria-2
# INSTANCE_NAME="mensajeria-2"
# PRIVATE_IP="10.225.3.30"

# INSTANCE_ID=$(aws ec2 run-instances \
#     --image-id "$AMI_ID" \
#     --instance-type "$INSTANCE_TYPE" \
#     --key-name "$KEY_NAME" \
#     --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$VOLUME_SIZE,VolumeType=gp3,DeleteOnTermination=true}" \
#     --network-interfaces "SubnetId=$SUBNET_ID,DeviceIndex=0,PrivateIpAddresses=[{Primary=true,PrivateIpAddress=$PRIVATE_IP}],Groups=[$SECURITY_GROUP_ID]" \
#     --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
#     --query "Instances[0].InstanceId" \
#     --output text)
# echo "${INSTANCE_NAME} creada: ${INSTANCE_ID}"

##############
# WORDPRESS  #
##############
# soporte-1
INSTANCE_NAME="soporte-1"
SUBNET_ID="${SUBNET_PRIVATE2_ID}"
SECURITY_GROUP_ID="${SG_CMS_ID}"
PRIVATE_IP="10.225.4.10"

USER_DATA_SCRIPT=$(cat <<EOF
#!/bin/bash
##############################
#  INSTALACION WP / PLUGINS  #
##############################
# Actualizar e instalar dependencias necesarias
sudo apt update
sudo apt install -y apache2 mysql-client php php-mysql libapache2-mod-php php-curl php-xml php-mbstring php-zip curl git unzip

# Instalar WP-CLI
curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
chmod +x wp-cli.phar
sudo mv wp-cli.phar /usr/local/bin/wp

# Limpiar el directorio de Apache
sudo rm -rf /var/www/html/*
sudo chmod -R 755 /var/www/html
sudo chown -R ubuntu:ubuntu /var/www/html

# Descargar WordPress como usuario ubuntu
sudo -u ubuntu wp core download --path=/var/www/html

# Eliminar el archivo wp-config.php existente si hay uno
sudo -u ubuntu rm -f /var/www/html/wp-config.php

# Configurar wp-config.php
sudo -u ubuntu wp core config --dbname="${DB_NAME}" --dbuser="${DB_USERNAME}" --dbpass="${DB_PASSWORD}" --dbhost="${RDS_ENDPOINT}" --dbprefix=wp_ --path=/var/www/html

# Instalar WordPress
sudo -u ubuntu wp core install --url="http://${PRIVATE_IP}" --title="CMS - TICKETING" --admin_user="${DB_USERNAME}" --admin_password="${DB_PASSWORD}" --admin_email="srestrepoj01@educantabria.es" --path=/var/www/html

# Instalar plugins adicionales
sudo -u ubuntu wp plugin install supportcandy --activate --path=/var/www/html
sudo -u ubuntu wp plugin install user-registration --activate --path=/var/www/html

# Configurar Apache para WordPress
sudo bash -c "cat > /etc/apache2/sites-available/wordpress.conf <<APACHE
<VirtualHost *:80>
    ServerName ${PRIVATE_IP}
    DocumentRoot /var/www/html
    <Directory /var/www/html>
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
APACHE"

# Habilitar el sitio de WordPress y reiniciar Apache
sudo a2dissite 000-default.conf
sudo a2ensite wordpress.conf
sudo a2enmod rewrite
sudo systemctl restart apache2
EOF
)

INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$VOLUME_SIZE,VolumeType=gp3,DeleteOnTermination=true}" \
    --network-interfaces "SubnetId=$SUBNET_ID,DeviceIndex=0,PrivateIpAddresses=[{Primary=true,PrivateIpAddress=$PRIVATE_IP}],Groups=[$SECURITY_GROUP_ID]" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
    --user-data "$USER_DATA_SCRIPT" \
    --query "Instances[0].InstanceId" \
    --output text)
echo "${INSTANCE_NAME} creada: ${INSTANCE_ID}"

# # soporte-2
# INSTANCE_NAME="soporte-2"
# SUBNET_ID="${SUBNET_PRIVATE2_ID}"
# SECURITY_GROUP_ID="${SG_CMS_ID}"
# PRIVATE_IP="10.225.4.11"

# USER_DATA_SCRIPT=$(cat <<EOF
# #!/bin/#!/bin/bash
# set -e
# sudo apt update
# sudo apt install apache2 mysql-client mysql-server php php-mysql -y
# curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
# chmod +x wp-cli.phar
# sudo mv wp-cli.phar /usr/local/bin/wp
# sudo rm -rf /var/www/html/*
# sudo chmod -R 755 /var/www/html
# sudo chown -R ubuntu:ubuntu /var/www/html
# # MySQL credentials
# MYSQL_CMD="mysql -h ${RDS_ENDPOINT} -u ${DB_USERNAME} -p${DB_PASSWORD}"
# $MYSQL_CMD <<EOF2
# CREATE DATABASE IF NOT EXISTS ${DB_NAME};
# CREATE USER IF NOT EXISTS '${DB_USERNAME}'@'%' IDENTIFIED BY '${DB_PASSWORD}';
# GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USERNAME}'@'%';
# FLUSH PRIVILEGES;
# EOF2
# sudo -u ubuntu -k -- wp core download --path=/var/www/html
# sudo -u ubuntu -k -- wp core config --dbname=${DB_NAME} --dbuser=${DB_USERNAME} --dbpass=${DB_PASSWORD} --dbhost=${RDS_ENDPOINT} --dbprefix=wp_ --path=/var/www/html
# sudo -u ubuntu -k -- wp core install --url=10.225.4.100  --title=Site_Title --admin_user=${DB_USERNAME} --admin_password=${DB_PASSWORD} --admin_email=majam02@educantabria.es --path=/var/www/html
# #sudo -u ubuntu -k -- wp option update home 'http://10.225.4.10' --path=/var/www/html
# #sudo -u ubuntu -k -- wp option update siteurl 'http://10.225.4.10' --path=/var/www/html
# sudo -u ubuntu -k -- wp plugin install supportcandy --activate --path=/var/www/html
# echo "WP configurado / montado"
# EOF
# )
# INSTANCE_ID=$(aws ec2 run-instances \
#     --image-id "$AMI_ID" \
#     --instance-type "$INSTANCE_TYPE" \
#     --key-name "$KEY_NAME" \
#     --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$VOLUME_SIZE,VolumeType=gp3,DeleteOnTermination=true}" \
#     --network-interfaces "SubnetId=$SUBNET_ID,DeviceIndex=0,PrivateIpAddresses=[{Primary=true,PrivateIpAddress=$PRIVATE_IP}],Groups=[$SECURITY_GROUP_ID]" \
#     --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
#     --user-data "$USER_DATA_SCRIPT" \
#     --query "Instances[0].InstanceId" \
#     --output text)
# echo "${INSTANCE_NAME} creada: ${INSTANCE_ID}"

