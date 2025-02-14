#!/bin/bash
# Instalación de Prosody y configuración de base de datos MySQL externa.

# Variables
db_host="10.211.3.10"
db_user="admin"
db_password="Admin123"
db_name="prosody"

LOG_FILE="/var/log/setup_script.log"

# Función para verificar que una instancia esté activa y en funcionamiento
check_instance_status() {
    instance_ip=$1
    status=$(aws ec2 describe-instance-status --instance-ids "$instance_ip" --query "InstanceStatuses[0].InstanceState.Name" --output text)
    while [ "$status" != "running" ]; do
        echo "Esperando a que la instancia con IP $instance_ip esté activa..." | tee -a $LOG_FILE
        sleep 10
        status=$(aws ec2 describe-instance-status --instance-ids "$instance_ip" --query "InstanceStatuses[0].InstanceState.Name" --output text)
    done
    echo "La instancia con IP $instance_ip está en funcionamiento." | tee -a $LOG_FILE
}

# Verificar el estado de las instancias de la base de datos
check_instance_status "10.211.3.10"
check_instance_status "10.211.3.11"

# Instalación de Prosody
echo "Instalando Prosody y módulos adicionales..." | tee -a $LOG_FILE
sudo apt update
sudo apt install lua-dbi-mysql lua-dbi-postgresql lua-dbi-sqlite3 -y 

# Configurar Prosody
echo "Configurando Prosody..." | tee -a $LOG_FILE
sudo tee /etc/prosody/prosody.cfg.lua > /dev/null <<EOL
modules_enabled = {
                'roster'; -- Allow users to have a roster. Recommended ;)
                'saslauth'; -- Authentication for clients and servers. Recommended if you want to log in.
                'tls'; -- Add support for secure TLS on c2s/s2s connections
                'dialback'; -- s2s dialback support
                'disco'; -- Service discovery
                'private'; -- Private XML storage (for room bookmarks, etc.)
                'vcard4'; -- User Profiles (stored in PEP)
                'vcard_legacy'; -- Conversion between legacy vCard and PEP Avatar, vcard
                'version'; -- Replies to server version requests
                'uptime'; -- Report how long server has been running
                'time'; -- Let others know the time here on this server
                'ping'; -- Replies to XMPP pings with pongs
                'register'; --Allows clients to register an account on your server
                'pep'; -- Enables users to publish their mood, activity, playing music and more
                'carbons'; -- XEP-0280: Message Carbons, synchronize messages accross devices
                'smacks'; -- XEP-0198: Stream Management, keep chatting even when the network drops for a few seconds
                'mam'; -- XEP-0313: Message Archive Management, allows to retrieve chat history from server
                'csi_simple'; -- XEP-0352: Client State Indication
                'admin_adhoc'; -- Allows administration via an XMPP client that supports ad-hoc commands
                'blocklist'; -- XEP-0191  blocking of users
                'bookmarks'; -- Synchronize currently joined groupchat between different clients.
                'server_contact_info'; --add contact info in the case of issues with the server
                --'cloud_notify'; -- Support for XEP-0357 Push Notifications for compatibility with ChatSecure/iOS.
                -- iOS typically end the connection when an app runs in the background and requires use of Apple's Push servers to wake up and receive a message. Enabling this module allows your server to do that for your contacts on iOS.
                -- However we leave it commented out as it is another example of vertically integrated cloud platforms at odds with federation, with all the meta-data-based surveillance consequences that that might have.
                'bosh';
                'websocket';
                's2s_bidi';
                's2s_whitelist';
                's2sout_override';
                'certs_s2soutinjection';
                's2s_auth_certs';
                's2s_auth_dane_in';
                's2s';
                'scansion_record';
                'server_contact_info';
                'http';
--                'http_upload';
};
http_interfaces = { "0.0.0.0", "::" }
 
allow_registration = false; -- Enable to allow people to register accounts on your server from their clients, for more information see http://prosody.im/doc/creating_accounts
certificates = '/etc/prosody/claves/prosody5.duckdns.org' -- Path where prosody looks for the certificates see: https://prosody.im/doc/letsencrypt
https_certificate = '/etc/prosody/claves/grups.duckdns.org'
c2s_require_encryption = true -- Force clients to use encrypted connections
s2s_secure_auth = true
s2s_secure_domains = { 'prosody5.duckdns.org' };
pidfile = '/var/run/prosody/prosody.pid'
authentication = 'internal_hashed'
archive_expires_after = '1w' -- Remove archived messages after 1 week
http_ports = { 5280 }
https_ports = { 5281 }
log = { --disable for extra privacy
        info = '/var/log/prosody/prosody.log'; -- Change 'info' to 'debug' for verbose logging
        error = '/var/log/prosody/prosody.err';
        '*syslog';
}
    disco_items = { -- allows clients to find the capabilities of your server
        {'upload.prosody5.duckdns.org', 'file uploads'};
        {'grups.prosody5.duckdns.org', 'group chats'};
}
admin = { 'diego.prosody5.duckdns.org' };
VirtualHost 'prosody5.duckdns.org'
 
storage = 'sql'
sql = { driver = 'MySQL', database = 'prosody', username = 'admin', password = 'Admin123', host = '10.203.3.10' }
 
ssl = {
    certificate = '/etc/prosody/claves/prosody5.duckdns.org/fullchain.pem',
    key = '/etc/prosody/claves/prosody5.duckdns.org/privkey.pem',
}
Component 'uploads.prosody5.duckdns.org' 'http_upload'
--    http_upload_path = "/var/lib/prosody/uploads"
--    http_upload_expire_after = 604800 -- 7 días
--    http_upload_max_file_size = 10485760 -- 10 MB
ssl = {
    certificate = '/etc/prosody/claves/uploads.prosody5.duckdns.org/fullchain.pem',
    key = '/etc/prosody/claves/uploads.prosody5.duckdns.org/privkey.pem',
}
 
Component 'grups.prosody5.duckdns.org' 'muc'
ssl = {
    certificate = '/etc/prosody/claves/grups.prosody5.duckdns.org/fullchain.pem',
    key = '/etc/prosody/claves/grups.prosody5.duckdns.org/privkey.pem',
}
modules_enabled = { 'muc_mam', 'vcard_muc' } -- enable archives and avatars for group chats
restrict_room_creation = 'admin'
default_config = {persistent = false;}
Component 'proxy.prosody5.duckdns.org' 'proxy65'
ssl = {
    certificate = '/etc/prosody/claves/proxy.prosody5.duckdns.org/fullchain.pem',
    key = '/etc/prosody/claves/proxy.prosody5.duckdns.org/privkey.pem',
}
EOL

# Reiniciar Prosody
echo "Reiniciando Prosody..." | tee -a $LOG_FILE
sudo systemctl restart prosody

# Crear usuario administrador
echo "Creando usuario admin@jherrerog-prosody.duckdns.org..." | tee -a $LOG_FILE
sudo prosodyctl register admin jherrerog-prosody.duckdns.org "Admin123"

echo "Prosody instalado y configurado con éxito en jherrerog-prosody.duckdns.org" | tee -a $LOG_FILE
