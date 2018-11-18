#!/bin/bash
#
# Copyright (C) 2018 Jared H. Hudson
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
#
# Alternate source of Icinga2 packages:
#
# rpm --import https://packages.icinga.com/icinga.key
# zypper -n ar -c -f http://packages.icinga.com/SUSE/ICINGA-release.repo
# zypper -n ar -c -f https://packages.icinga.com/SUSE/ICINGA-snapshot.repo
#
warn_if_fail() {
    local -i rc=$?
    if [ $rc -ne 0 ]; then
        printf 'WARNING: %s\n' "$1"
    fi
}

error_if_fail() {
    local -i rc=$?
    if [ $rc -ne 0 ]; then
        printf 'ERROR: %s\n' "$1"
        exit_program
    fi
}

declare -i ERROR=
exit_program() {
    exit $ERROR
}

cleanup() {
    systemctl stop postgresql
    rm -rf /var/lib/pgsql/data /var/cache/icinga2 /var/log/icinga2 /var/spool/icinga2 /var/spool/icinga \
           /var/lib/systemd/migrated/icinga2 /var/lib/icinga2 /var/log/icinga /var/log/icingaweb2 \
           /var/log/icinga /var/lib/icinga /var/spool/icinga /var/lib/systemd/migrated/icingaweb2-module-director-jobs
}

setup_proxy() {
    nohup yast2 --ncurses proxy set http=http://192.168.1.1:3128/ &>/dev/null
    warn_if_fail "setting http proxy"
    nohup yast2 --ncurses proxy set https=http://192.168.1.1:3128/ &>/dev/null
    warn_if_fail "setting https proxy"
    nohup yast2 --ncurses proxy enable &>/dev/null
    warn_if_fail "enabling proxy"
}

main() {
    local TEMP
    TEMP=$(getopt -o 'cpt:' -n 'icinga_install.sh' -- "$@")
    error_if_fail "getopt"
    
    eval set -- "$TEMP"
    unset TEMP
    type=client
    while true; do
        case "$1" in
                '-c')
                printf 'cleaning up...'
                shift
                cleanup
                printf 'done\n'
                continue
                ;;
                '-p')
                shift
                printf 'setting up proxy...'
                setup_proxy
                printf 'done\n'
                continue
                ;;
                '-t')
                shift
                
                if [ "$1" != "master" ] && [ "$1" != "satellite" ] && [ "$1" != "client" ]; then
                    printf 'Valid types are: master, satellite or client\n\n'
                    exit_program 1
                fi
                
                type="$1"
                shift
                continue
                ;;
                '--')
                shift
                break
                ;;
                *)
                false
                error_if_fail "argument unrecognized"
                ;;
        esac
    done
    
    snapper create -d icinga
    error_if_fail "snapper create"
    
    systemctl enable kexec-load kexec.target
    error_if_fail "enable kexec*"
    systemctl start kexec-load
    error_if_fail "start kexec-load"
    
    if ps -C zypper h &>/dev/null; then
        printf 'Waiting for zypper to finish running.'
        while ps -C zypper &>/dev/null; do
            sleep 1
            printf '.'
        done
    fi
    
    
    test -f /etc/os-release && . /etc/os-release
    if [ "$ID" = "opensuse-leap" ]; then
        case "$VERSION" in
            "15.0")
            rpm --import https://download.opensuse.org/repositories/server:/monitoring/openSUSE_Leap_15.0/repodata/repomd.xml.key
            warn_if_fail "rpm key import"
            
            if [ ! -f /etc/zypp/repos.d/server_monitoring.repo ]; then
                zypper -n ar -c -f https://download.opensuse.org/repositories/server:/monitoring/openSUSE_Leap_15.0/server:monitoring.repo
                error_if_fail "zypper ar server:monitoring.repo"
            fi
            
            # master get DB
            if [ "$type" = "master" ]; then
                zypper -n in postgresql10 postgresql10-contrib postgresql10-server php7-imagick
                warn_if_fail "zypper in postgresql10*"
            fi
            
            # master and satellite get icingaweb setup
            if [ "$type" != "client" ]; then
                firewall-cmd --add-service=http
                firewall-cmd --add-service=https
                firewall-cmd --add-service=http --permanent
                firewall-cmd --add-service=https --permanent
            fi
            
            # all node types
            firewall-cmd --add-port=5665/tcp
            firewall-cmd --add-port=5665/tcp --permanent
            ;;
            *)
            printf 'openSUSE Leap version '\''%s'\''not recognized.\n' "$VERSION"
            exit 1
            ;;
        esac
    elif [ "$ID" = "sles" ]; then
        case "$VERSION" in
            "12-SP3")
            if [ ! -f /etc/zypp/repos.d/SUSE_Linux_Enterprise_Software_Development_Kit_12_SP3_x86_64:SLE-SDK12-SP3-Pool.repo ] || \
            [ ! -f /etc/zypp/repos.d/SUSE_Linux_Enterprise_Software_Development_Kit_12_SP3_x86_64:SLE-SDK12-SP3-Updates.repo ]; then
                SUSEConnect -p sle-sdk/12.3/x86_64
            fi
            
            rpm --import https://download.opensuse.org/repositories/server:/monitoring/SLE_12_SP3/repodata/repomd.xml.key
            warn_if_fail "rpm key import"
            if [ ! -f /etc/zypp/repos.d/server_monitoring.repo ]; then
                zypper -n ar -c -f https://download.opensuse.org/repositories/server:/monitoring/SLE_12_SP3/server:monitoring.repo
                error_if_fail "zypper ar server:monitoring.repo"
            fi
            
            # master get DB
            if [ "$type" = "master" ]; then
                zypper -n in postgresql96 postgresql96-contrib postgresql96-server
                warn_if_fail "zypper in postgresql96*"
            fi
            
            # master and satellite get icingaweb setup
            if [ "$type" != "client" ]; then
                SuSEfirewall2 open EXT TCP 443
                SuSEfirewall2 open EXT TCP 80
                SuSEfirewall2 open DMZ TCP 443
                SuSEfirewall2 open DMZ TCP 80
            fi
            
            # all node types
            SuSEfirewall2 open EXT TCP 5665
            SuSEfirewall2 open DMZ TCP 5665
            SuSEfirewall2
            ;;
            "15")
            SUSEConnect    -p sle-module-desktop-applications/15/x86_64
            error_if_fail
            SUSEConnect    -p sle-module-development-tools/15/x86_64
            error_if_fail
            if [ ! -f /etc/zypp/repos.d/SUSE_Package_Hub_15_x86_64:SUSE-PackageHub-15.repo ] || \
            [ ! -f /etc/zypp/repos.d/SUSE_Package_Hub_15_x86_64:SUSE-PackageHub-15-Pool.repo ]; then
                if ! SUSEConnect    -p PackageHub/15/x86_64; then
                    SUSEConnect    -p PackageHub/15/x86_64
                fi
            fi
            
            SUSEConnect    -p sle-module-web-scripting/15/x86_64
            error_if_fail
            
            rpm --import https://download.opensuse.org/repositories/server:/monitoring/SLE_15/repodata/repomd.xml.key
            warn_if_fail "rpm key import"
            
            if [ ! -f /etc/zypp/repos.d/server_monitoring.repo ]; then
                zypper -n ar -c -f https://download.opensuse.org/repositories/server:/monitoring/SLE_15/server:monitoring.repo
                error_if_fail "zypper ar server:monitoring.repo"
            fi
            
            # master get DB
            if [ "$type" = "master" ]; then
                zypper -n in postgresql10 postgresql10-contrib postgresql10-server system-user-wwwrun
                error_if_fail "zypper in postgresql10*"
            fi
            
            # master and satellite get icingaweb setup
            if [ "$type" != "client" ]; then
                firewall-cmd --add-service=http
                error_if_fail
                firewall-cmd --add-service=https
                error_if_fail
                firewall-cmd --add-service=http --permanent
                error_if_fail
                firewall-cmd --add-service=https --permanent
                error_if_fail
            fi
            
            firewall-cmd --add-port=5665/tcp
            error_if_fail
            firewall-cmd --add-port=5665/tcp --permanent
            error_if_fail
            ;;
            *)
            printf 'SUSE Linux Enterprise Server version '\''%s'\''not recognized.\n' "$VERSION"
            exit 1
            ;;
        esac
        
    fi
    
    zypper -n in icinga2 icinga2-doc sudo patch vim-icinga2 nano-icinga2
    error_if_fail
    
    if [ "$type" != "client" ]; then
        zypper -n in php7-pgsql apache2-mod_php7 
        error_if_fail "zypper in php7-pgsql apache2-mod_php7"
        
        zypper -n in icinga2-ido-pgsql icingaweb2 icingaweb2-icingacli \
        icingaweb2-module-director icingaweb2-module-pnp icingaweb2-vendor-HTMLPurifier icingaweb2-vendor-JShrink icingaweb2-vendor-Parsedown icingaweb2-vendor-dompdf \
        icingaweb2-vendor-lessphp icingaweb2-vendor-zf1 php-Icinga pnp4nagios-icinga php7-mbstring
        error_if_fail
        
        test -d /etc/systemd/system/icinga2.service.d || mkdir /etc/systemd/system/icinga2.service.d
        cat > /etc/systemd/system/icinga2.service.d/override.conf <<-EOF
[Service]
TasksMax=10000
EOF
        systemctl daemon-reload
        error_if_fail
    fi
    
    if [ "$type" = "master" ]; then
        systemctl is-enabled postgresql || systemctl enable postgresql
        systemctl start postgresql
        error_if_fail
        cd / || exit_program 1
        sudo -u postgres psql -c "CREATE ROLE icinga WITH LOGIN PASSWORD 'icinga'"
        error_if_fail
        sudo -u postgres psql -c "CREATE ROLE icingaweb2 WITH LOGIN PASSWORD 'icingaweb2'"
        error_if_fail
        sudo -u postgres psql -c "CREATE ROLE director WITH LOGIN PASSWORD 'director'"
        error_if_fail
        sudo -u postgres createdb -O icinga -E UTF8 icinga
        error_if_fail
        sudo -u postgres createdb -O icingaweb2 -E UTF8 icingaweb2
        error_if_fail
        sudo -u postgres createdb -O director -E UTF8 director
        error_if_fail
        sudo -u postgres psql -c "CREATE EXTENSION pgcrypto"
        error_if_fail
    
        # The icinga and icingaweb2
        # find first line that is not a comment so we can put our configuration before this line
        buffer=$(grep -vE -m1 -n '^$|\#' ~postgres/data/pg_hba.conf)
        lineno=${buffer%:*}
        tophalf=$(mktemp)
        bottomhalf=$(mktemp)
        newfile=$(mktemp)
    
        head -n $((lineno-1)) ~postgres/data/pg_hba.conf > "$tophalf"
        tail -n +"$lineno" ~postgres/data/pg_hba.conf > "$bottomhalf"
    
        cp "$tophalf" "$newfile"
        if ! grep icinga ~postgres/data/pg_hba.conf; then
            cat >> "$newfile" <<EOF
local   icinga      icinga                            md5
host    icinga      icinga      127.0.0.1/32          md5
host    icinga      icinga      ::1/128               md5
EOF
        fi

        if ! grep icingaweb2 ~postgres/data/pg_hba.conf; then
            cat >> "$newfile" <<EOF
local   icingaweb2      icingaweb2                            md5
host    icingaweb2      icingaweb2      127.0.0.1/32          md5
host    icingaweb2      icingaweb2      ::1/128               md5
EOF
        fi
    
        if ! grep director ~postgres/data/pg_hba.conf; then
            cat >> "$newfile" <<EOF
local   director      director                            md5
host    director      director      127.0.0.1/32          md5
host    director      director      ::1/128               md5
EOF
        fi
    
    
        cat "$bottomhalf" >> "$newfile"
        chown postgres:postgres "$newfile"
        error_if_fail
        chmod 0600 "$newfile"
        error_if_fail
        mv "$newfile" ~postgres/data/pg_hba.conf
        error_if_fail
    
        systemctl reload postgresql
        error_if_fail
        export PGPASSWORD=icinga
        psql -U icinga -d icinga --quiet < /usr/share/icinga2-ido-pgsql/schema/pgsql.sql
        warn_if_fail "psql import icinga2-ido schema"
            
        export PGPASSWORD=icingaweb2
        psql -U icingaweb2 -d icingaweb2 --quiet < /usr/share/doc/icingaweb2/schema/pgsql.schema.sql
        warn_if_fail "psql import icingaweb2 schema"
            
        password=$(openssl passwd -1 icinga)
        psql -U icingaweb2 -d icingaweb2 -c "INSERT INTO icingaweb_user (name, active, password_hash) VALUES ('root', 1, '$password')"
        warn_if_fail "icingaweb2 create root"
        
        tmpfile=$(mktemp)
        cat > "$tmpfile" <<'EOF'
--- /etc/icinga2/features-available/ido-pgsql.conf.orig 2018-07-04 18:39:13.187301920 -0500
+++ /etc/icinga2/features-available/ido-pgsql.conf      2018-07-04 18:39:46.503440925 -0500
@@ -6,8 +6,8 @@
 library "db_ido_pgsql"

 object IdoPgsqlConnection "ido-pgsql" {
-  //user = "icinga"
-  //password = "icinga"
-  //host = "localhost"
-  //database = "icinga"
+  user = "icinga"
+  password = "icinga"
+  host = "localhost"
+  database = "icinga"
 }
EOF
        patch -d / -p1 -t -N -borig < "$tmpfile"
        rm "$tmpfile"
        
        icinga2 feature enable ido-pgsql
        error_if_fail
        icinga2 api setup
        error_if_fail
        icingacli setup config directory
        error_if_fail
        
        if ! grep \"icingaweb2\" /etc/icinga2/conf.d/api-users.conf; then
            cat >> /etc/icinga2/conf.d/api-users.conf <<EOF
object ApiUser "icingaweb2" {
  password = "icingaweb2"
  permissions = [ "status/query", "actions/*", "objects/modify/*", "objects/query/*" ]
}
EOF
        fi
        
        if ! grep \"director\" /etc/icinga2/conf.d/api-users.conf; then
            cat >> /etc/icinga2/conf.d/api-users.conf <<EOF
object ApiUser "director" {
  password = "director"
  permissions = [ "*" ]
}
EOF
        fi
        
        mkdir -p /etc/icingaweb2/modules/setup
        cat > /etc/icingaweb2/modules/setup/config.ini <<EOF
[schema]
path = /usr/share/doc/icingaweb2/schema
EOF
    
        mkdir -p /etc/icingaweb2/modules/translation
        cat > /etc/icingaweb2/modules/translation/config.ini <<EOF
[translation]
msgmerge = /usr/bin/msgmerge
xgettext = /usr/bin/xgettext
msgfmt = /usr/bin/msgfmt
EOF

        mkdir -p /etc/icingaweb2/modules/monitoring
        cat > /etc/icingaweb2/modules/monitoring/backends.ini <<EOF
[icinga]
type = "ido"
resource = "icinga_ido"
EOF
        cat > /etc/icingaweb2/modules/monitoring/commandtransports.ini <<EOF
[icinga2]
transport = "api"
host = "127.0.0.1"
port = "5665"
username = "icingaweb2"
password = "icingaweb2"
EOF

        cat > /etc/icingaweb2/modules/monitoring/config.ini <<EOF
[security]
protected_customvars = "*pw*,*pass*,community"
EOF
        mkdir -p /etc/icingaweb2/modules/director/
        cat > /etc/icingaweb2/modules/director/config.ini <<EOF
[db]
resource = "director_db"
EOF

        cat > /etc/icingaweb2/modules/director/kickstart.ini <<EOF
[config]
endpoint = $(hostname -f)
; host = 127.0.0.1
; port = 5665
username = director
password = director
EOF

        cat > /etc/icingaweb2/config.ini <<EOF
[global]
show_stacktraces = "1"
config_backend = "db"
config_resource = "icingaweb_db"

[logging]
log = "syslog"
level = "ERROR"
application = "icingaweb2"
facility = "user"
EOF

        cat > /etc/icingaweb2/authentication.ini <<EOF
[icingaweb2]
backend = "db"
resource = "icingaweb_db"
EOF

        cat > /etc/icingaweb2/roles.ini <<EOF
[Administrators]
users = "root"
permissions = "*"
groups = "Administrators"
EOF

        cat > /etc/icingaweb2/groups.ini <<EOF
[icingaweb2]
backend = "db"
resource = "icingaweb_db"
EOF

        cat > /etc/icingaweb2/resources.ini <<EOF
[icingaweb_db]
type = "db"
db = "pgsql"
host = "localhost"
port = "5432"
dbname = "icingaweb2"
username = "icingaweb2"
password = "icingaweb2"
charset = "utf8"
persistent = "0"

[icinga_ido]
type = "db"
db = "pgsql"
host = "localhost"
port = "5432"
dbname = "icinga"
username = "icinga"
password = "icinga"
charset = "utf8"
persistent = "0"

[director_db]
type = "db"
db = "pgsql"
host = "localhost"
port = "5432"
dbname = "director"
username = "director"
password = "director"
charset = "utf8"
persistent = "0"
EOF
    
        test -d /etc/icingaweb2/enabledModules || mkdir /etc/icingaweb2/enabledModules
        cd /etc/icingaweb2/enabledModules || exit_program 1
        for dir in /usr/share/icingaweb2/modules/*; do
            test -s "$(basename "$dir")" || ln -s "$dir" "$(basename "$dir")"
        done
        #rm setup
        cd || exit_program 1

        systemctl restart icinga2
    
        icingacli director migration run --verbose
        icingacli director kickstart run
        icingacli director config deploy
    
        a2enmod -l | grep rewrite &>/dev/null || a2enmod rewrite
        a2enmod -l | grep php7 &>/dev/null || a2enmod php7
        systemctl is-enabled apache2 || systemctl enable apache2
        
        if ! grep -F 'RedirectMatch "^/$" /icingaweb2/' /etc/apache2/default-server.conf; then
            printf 'RedirectMatch "^/$" /icingaweb2/' >> /etc/apache2/default-server.conf
        fi
        
        systemctl restart apache2
    fi
    
    systemctl enable icinga2
    error_if_fail
}

main "$@"
