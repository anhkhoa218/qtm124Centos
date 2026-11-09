#!/usr/bin/env bash
# ==============================================================================
# SCRIPT TONG HOP QUAN TRI HE THONG MANG - CENTOS STREAM 9
# Domain chuan: nhom5.local | Topology: 192.168.10.0/24
# ==============================================================================

set -o pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[!] Loi: Script bat buoc phai chay voi quyen root (sudo $0).${NC}"
    exit 1
fi

log_step() {
    echo -e "${CYAN}[*] $1${NC}"
}

log_success() {
    echo -e "${GREEN}[✓] $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}[!] $1${NC}"
}

log_error() {
    echo -e "${RED}[✘] $1${NC}"
}

pause_menu() {
    echo ""
    read -rp "Nhan [Enter] de quay lai Menu chinh..."
}

# Ham lay thong tin IP va Subnet LAN noi bo
get_lan_topology_info() {
    local INT_IFACE
    INT_IFACE=$(firewall-cmd --zone=internal --list-interfaces 2>/dev/null | awk '{print $1}')
    if [ -z "$INT_IFACE" ]; then
        local DEFAULT_ROUTE_DEV
        DEFAULT_ROUTE_DEV=$(ip route show default 2>/dev/null | awk '{print $5}' | head -n1)
        mapfile -t ALL_ETH < <(nmcli -t -f DEVICE,TYPE device status | grep ethernet | cut -d: -f1)
        for eth in "${ALL_ETH[@]}"; do
            if [[ "$eth" != "$DEFAULT_ROUTE_DEV" ]]; then
                INT_IFACE="$eth"
                break
            fi
        done
        INT_IFACE=${INT_IFACE:-$DEFAULT_ROUTE_DEV}
    fi

    TOPOLOGY_LAN_IFACE="$INT_IFACE"
    TOPOLOGY_LAN_IP=$(ip -4 addr show dev "$INT_IFACE" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)
    TOPOLOGY_LAN_IP=${TOPOLOGY_LAN_IP:-192.168.10.1}

    TOPOLOGY_LAN_SUBNET=$(ip route show dev "$INT_IFACE" proto kernel 2>/dev/null | awk '{print $1}' | head -n1)
    TOPOLOGY_LAN_SUBNET=${TOPOLOGY_LAN_SUBNET:-192.168.10.0/24}
}

# Ham tu dong tinh Zone nghich va PTR
calc_reverse_zone_info() {
    local ip="$1"
    local o1 o2 o3 o4
    IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
    if (( o1 >= 1 && o1 <= 126 )); then
        CALC_REV_ZONE="${o1}.in-addr.arpa"
        CALC_PTR_PREFIX="${o4}.${o3}.${o2}"
    elif (( o1 >= 128 && o1 <= 191 )); then
        CALC_REV_ZONE="${o2}.${o1}.in-addr.arpa"
        CALC_PTR_PREFIX="${o4}.${o3}"
    else
        CALC_REV_ZONE="${o3}.${o2}.${o1}.in-addr.arpa"
        CALC_PTR_PREFIX="${o4}"
    fi
}

# Ham tu dong them A record va MX record vao DNS Server
add_dns_mail_records() {
    local domain="$1"
    local mail_fqdn="$2"
    local server_ip="$3"

    local FWD_FILE="/var/named/${domain}.db"
    if [ -f "$FWD_FILE" ]; then
        log_step "Phat hien file Zone BIND ($FWD_FILE). Dang cap nhat ban ghi Mail..."
        if ! grep -q "mail" "$FWD_FILE"; then
            echo "mail    IN      A       ${server_ip}" >> "$FWD_FILE"
        fi
        if ! grep -q "MX" "$FWD_FILE"; then
            echo "@       IN      MX  10  ${mail_fqdn}." >> "$FWD_FILE"
        fi
        named-checkzone "$domain" "$FWD_FILE" >/dev/null 2>&1 && systemctl restart named 2>/dev/null || true
        log_success "Da cap nhat ban ghi A va MX vao BIND DNS!"
    fi

    if systemctl is-active --quiet samba 2>/dev/null && command -v samba-tool &>/dev/null; then
        log_step "Phat hien Samba AD DC. Dang dong bo DNS qua samba-tool..."
        samba-tool dns add 127.0.0.1 "$domain" mail A "$server_ip" -U administrator 2>/dev/null || true
        samba-tool dns add 127.0.0.1 "$domain" "@" MX "${mail_fqdn} 10" -U administrator 2>/dev/null || true
        log_success "Da cap nhat ban ghi A va MX tren Samba AD DC!"
    fi
}

# ==============================================================================
# 1. TAT SELINUX VINH VIEN
# ==============================================================================
module_disable_selinux() {
    echo -e "\n${BLUE}================================================================${NC}"
    echo -e "${BLUE}                  1. TAT SELINUX VINH VIEN                      ${NC}"
    echo -e "${BLUE}================================================================${NC}"

    local current_selinux
    current_selinux=$(getenforce 2>/dev/null || echo "Unknown")
    log_step "Trang thai SELinux hien tai: ${YELLOW}${current_selinux}${NC}"

    if [[ "$current_selinux" == "Enforcing" ]]; then
        log_step "SELinux dang Enforcing. Dang ha ve Permissive tam thoi (setenforce 0)..."
        setenforce 0 2>/dev/null || true
        log_success "Da chay setenforce 0 thanh cong."
    fi

    if [[ -f /etc/selinux/config ]]; then
        log_step "Dang cap nhat file /etc/selinux/config sang disabled..."
        sed -i 's/^SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
        sed -i 's/^SELINUX=permissive/SELINUX=disabled/' /etc/selinux/config
        log_success "Da cap nhat SELINUX=disabled vao file /etc/selinux/config."
        grep -E '^SELINUX=' /etc/selinux/config
    else
        log_error "Khong tim thay file /etc/selinux/config!"
    fi
    log_warn "Luu y: He thong can duoc khoi dong lai (reboot) de SELinux chuyen han sang Disabled."
}

# ==============================================================================
# 2. CAU HINH IP TINH (NETWORKMANAGER & FIREWALLD)
# ==============================================================================
module_setup_ip() {
    echo -e "\n${BLUE}======================================================================${NC}"
    echo -e "${BLUE}               DANH SACH CARD MANG DANG CO TREN HE THONG              ${NC}"
    echo -e "${BLUE}======================================================================${NC}"
    printf "%-12s %-20s %-18s %-20s\n" "Interface" "IPv4 Address" "Gateway" "DNS"
    echo "----------------------------------------------------------------------"

    mapfile -t DEVICES < <(nmcli -t -f DEVICE,TYPE device status | grep -E ':(ethernet|wifi)$' | cut -d: -f1)
    local TOTAL_DEV=${#DEVICES[@]}

    if [[ $TOTAL_DEV -eq 0 ]]; then
        log_error "Khong tim thay card mang vat ly nao tren he thong!"
        return 1
    fi

    for dev in "${DEVICES[@]}"; do
        local ip_addr gw dns
        ip_addr=$(nmcli -g IP4.ADDRESS device show "$dev" 2>/dev/null | head -n1)
        gw=$(nmcli -g IP4.GATEWAY device show "$dev" 2>/dev/null)
        dns=$(nmcli -g IP4.DNS device show "$dev" 2>/dev/null | tr '\n' ' ')
        printf "%-12s %-20s %-18s %-20s\n" "$dev" "${ip_addr:-Chua co}" "${gw:-Chua co}" "${dns:-Chua co}"
    done
    echo "----------------------------------------------------------------------"

    unset CFG_MODE CFG_IP CFG_GW CFG_DNS
    declare -A CFG_MODE CFG_IP CFG_GW CFG_DNS

    chon_card() {
        local prompt_text="$1"
        local selected=""
        while true; do
            read -rp "$prompt_text: " selected
            for d in "${DEVICES[@]}"; do
                if [[ "$d" == "$selected" ]]; then
                    echo "$selected"
                    return 0
                fi
            done
            log_warn "Ten card '$selected' khong ton tai. Vui long nhap dung ten!" >&2
        done
    }

    thu_thap_thong_so() {
        local iface="$1"
        local role_label="$2"
        local mode ip gw dns

        echo ""
        log_step "Thiet lap thong so cho $role_label ($iface)"
        echo "  1) DHCP (Nhan IP tu dong)"
        echo "  2) IP Tinh (Static IP)"
        read -rp "Chon che do (1/2): " mode

        if [[ "$mode" == "1" ]]; then
            CFG_MODE["$iface"]="dhcp"
            log_success "Card $iface se nhan IP tu dong qua DHCP."
        else
            CFG_MODE["$iface"]="static"
            read -rp "  > IP/Subnet (VD: 192.168.10.1/24): " ip
            if [[ "$role_label" != "INTERNAL" ]]; then
                read -rp "  > Gateway (Enter neu khong can GW): " gw
            else
                gw=""
                log_warn "Card LAN (INTERNAL) tu dong bo qua Gateway de chong Routing Loop."
            fi
            read -rp "  > DNS (Cac IP cach nhau boi khoang trang, Enter de bo qua): " dns
            
            CFG_IP["$iface"]="$ip"
            CFG_GW["$iface"]="$gw"
            CFG_DNS["$iface"]="$dns"
        fi
    }

    local SINGLE_IFACE EXT_IFACE INT_IFACE

    if [[ $TOTAL_DEV -eq 1 ]]; then
        SINGLE_IFACE="${DEVICES[0]}"
        log_warn "He thong chi co 1 card mang ($SINGLE_IFACE). Gan vao zone 'public'."
        thu_thap_thong_so "$SINGLE_IFACE" "CARD MANG"
    else
        log_step "Phan chia vai tro Card External va Internal:"
        EXT_IFACE=$(chon_card "Nhap ten card EXTERNAL (Noi Internet/VMnet8/Bridge)")

        while true; do
            INT_IFACE=$(chon_card "Nhap ten card INTERNAL (Mang LAN noi bo)")
            if [[ "$INT_IFACE" != "$EXT_IFACE" ]]; then
                break
            fi
            log_warn "Card Internal khong duoc trung voi External ($EXT_IFACE)!"
        done

        thu_thap_thong_so "$EXT_IFACE" "EXTERNAL"
        thu_thap_thong_so "$INT_IFACE" "INTERNAL"
    fi

    log_step "Dang don sach toan bo connection profile cu..."
    mapfile -t ALL_UUIDS < <(nmcli -t -f UUID connection show)
    for uuid in "${ALL_UUIDS[@]}"; do
        if [[ -n "$uuid" ]]; then
            nmcli connection delete uuid "$uuid" >/dev/null 2>&1 || true
        fi
    done
    log_success "Da xoa sach connection profile cu."

    tao_connection() {
        local iface="$1"
        local zone="$2"

        log_step "Dang tao connection profile '$iface' (Zone: $zone)..."

        if [[ "${CFG_MODE[$iface]}" == "dhcp" ]]; then
            nmcli connection add type ethernet con-name "$iface" ifname "$iface" \
                ipv4.method auto ipv4.dns-priority 100 connection.zone "$zone" connection.autoconnect yes >/dev/null
        else
            local args=(
                type ethernet
                con-name "$iface"
                ifname "$iface"
                ipv4.method manual
                ipv4.addresses "${CFG_IP[$iface]}"
                connection.zone "$zone"
                connection.autoconnect yes
            )

            if [[ -n "${CFG_GW[$iface]}" ]]; then
                args+=(ipv4.gateway "${CFG_GW[$iface]}")
            fi

            if [[ -n "${CFG_DNS[$iface]}" ]]; then
                args+=(ipv4.dns "${CFG_DNS[$iface]}")
            fi

            if [[ "$zone" == "internal" ]]; then
                args+=(ipv4.never-default yes ipv4.dns-priority 10)
            fi

            nmcli connection add "${args[@]}" >/dev/null
        fi

        log_step "Kich hoat profile '$iface'..."
        nmcli connection up "$iface" >/dev/null
        log_success "Profile '$iface' da hoat dong."
    }

    log_step "Kiem tra dich vu Firewalld..."
    if ! systemctl is-active --quiet firewalld; then
        systemctl enable --now firewalld
    fi

    if [[ $TOTAL_DEV -eq 1 ]]; then
        tao_connection "$SINGLE_IFACE" "public"
        firewall-cmd --permanent --zone=public --change-interface="$SINGLE_IFACE" >/dev/null
    else
        tao_connection "$EXT_IFACE" "external"
        tao_connection "$INT_IFACE" "internal"
        
        firewall-cmd --permanent --zone=external --change-interface="$EXT_IFACE" >/dev/null
        firewall-cmd --permanent --zone=internal --change-interface="$INT_IFACE" >/dev/null
        firewall-cmd --permanent --zone=external --remove-masquerade >/dev/null 2>&1 || true
    fi

    log_step "Reload Firewalld de ap dung interface..."
    firewall-cmd --reload >/dev/null
    log_success "Cau hinh mang va Firewalld hoan tat!"
    ip -br addr show
}

# ==============================================================================
# 3. CAU HINH NAT GATEWAY
# ==============================================================================
module_setup_nat() {
    echo -e "\n${BLUE}=====================================================${NC}"
    echo -e "${BLUE}  CAU HINH NAT GATEWAY (CENTOS STREAM 9)             ${NC}"
    echo -e "${BLUE}=====================================================${NC}"

    systemctl is-active --quiet firewalld || systemctl enable --now firewalld

    mapfile -t AVAIL_IFACES < <(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="ethernet" {print $1}')
    if [[ ${#AVAIL_IFACES[@]} -lt 2 ]]; then
        log_error "May chu can toi thieu 2 card mang de lam gateway/NAT."
        return 1
    fi

    local EXT_IF INT_IF
    EXT_IF=$(firewall-cmd --zone=external --list-interfaces 2>/dev/null | awk '{print $1}')
    INT_IF=$(firewall-cmd --zone=internal --list-interfaces 2>/dev/null | awk '{print $1}')

    if [[ -z "$EXT_IF" || -z "$INT_IF" ]]; then
        log_warn "Chua gan card vao zone external/internal. Vui long chon:"
        read -rp "Nhap ten card WAN (external, vi du: ${AVAIL_IFACES[0]}): " EXT_IF
        read -rp "Nhap ten card LAN (internal, vi du: ${AVAIL_IFACES[1]}): " INT_IF
        firewall-cmd --zone=external --add-interface="$EXT_IF" --permanent
        firewall-cmd --zone=internal --add-interface="$INT_IF" --permanent
        firewall-cmd --reload
    fi

    log_step "Kich hoat IP Forwarding tai Kernel..."
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-ipforward.conf
    sysctl -p /etc/sysctl.d/99-ipforward.conf
    log_success "Da bat net.ipv4.ip_forward = 1."

    log_step "Kich hoat Masquerade tren zone external..."
    firewall-cmd --zone=external --add-masquerade --permanent
    log_success "Da bat Masquerade cho zone external."

    log_step "Khai bao Policy dinh tuyen 'lan-to-wan'..."
    local POLICY_NAME="lan-to-wan"
    if ! firewall-cmd --get-policies | grep -qw "$POLICY_NAME"; then
        firewall-cmd --permanent --new-policy "$POLICY_NAME"
    fi

    firewall-cmd --permanent --policy "$POLICY_NAME" --add-ingress-zone internal 2>/dev/null || true
    firewall-cmd --permanent --policy "$POLICY_NAME" --add-egress-zone external 2>/dev/null || true
    firewall-cmd --permanent --policy "$POLICY_NAME" --set-target ACCEPT
    
    log_step "Reload Firewalld..."
    firewall-cmd --reload
    log_success "Cau hinh NAT Gateway hoan tat! Policy '$POLICY_NAME' da active."
}

# ==============================================================================
# 4. CAU HINH DNS SERVER (BIND9)
# ==============================================================================
module_setup_dns() {
    echo -e "\n${BLUE}======================================================${NC}"
    echo -e "${BLUE} CAU HINH BIND DNS SERVER (NAMED)                     ${NC}"
    echo -e "${BLUE}======================================================${NC}"

    log_step "Kiem tra va cai dat bind, bind-utils..."
    dnf install -y bind bind-utils

    local SERIAL_DATE
    SERIAL_DATE="$(date +%Y%m%d)01"

    get_lan_topology_info
    read -rp "Nhap ten mien Zone thuan [nhom5.local]: " FORWARD_ZONE
    FORWARD_ZONE=${FORWARD_ZONE:-nhom5.local}

    read -rp "Nhap IP cua DNS Server [$TOPOLOGY_LAN_IP]: " SERVER_IP
    SERVER_IP=${SERVER_IP:-$TOPOLOGY_LAN_IP}

    calc_reverse_zone_info "$SERVER_IP"
    local REVERSE_ZONE="$CALC_REV_ZONE"
    local PTR_PREFIX="$CALC_PTR_PREFIX"

    log_step "Zone thuan: $FORWARD_ZONE | Zone nghich: $REVERSE_ZONE (PTR prefix: $PTR_PREFIX)"

    log_step "Tao file zone thuan /var/named/${FORWARD_ZONE}.db..."
    local FWD_FILE="/var/named/${FORWARD_ZONE}.db"
    cat << EOF_FWD > "$FWD_FILE"
\$TTL 1D
@       IN SOA  ns1.${FORWARD_ZONE}. admin.${FORWARD_ZONE}. (
                                        ${SERIAL_DATE} ; Serial
                                        1D         ; Refresh
                                        1H         ; Retry
                                        1W         ; Expire
                                        3H )       ; Minimum TTL
@       IN      NS      ns1.${FORWARD_ZONE}.
ns1     IN      A       ${SERVER_IP}
@       IN      A       ${SERVER_IP}
www     IN      A       ${SERVER_IP}
mail    IN      A       ${SERVER_IP}
@       IN      MX  10  mail.${FORWARD_ZONE}.
EOF_FWD

    log_step "Tao file zone nghich /var/named/${REVERSE_ZONE}.db voi ban ghi PTR..."
    local REV_FILE="/var/named/${REVERSE_ZONE}.db"
    cat << EOF_REV > "$REV_FILE"
\$TTL 1D
@       IN SOA  ns1.${FORWARD_ZONE}. admin.${FORWARD_ZONE}. (
                                        ${SERIAL_DATE} ; Serial
                                        1D         ; Refresh
                                        1H         ; Retry
                                        1W         ; Expire
                                        3H )       ; Minimum TTL
@       IN      NS      ns1.${FORWARD_ZONE}.
${PTR_PREFIX}       IN      PTR     ns1.${FORWARD_ZONE}.
${PTR_PREFIX}       IN      PTR     ${FORWARD_ZONE}.
${PTR_PREFIX}       IN      PTR     mail.${FORWARD_ZONE}.
EOF_REV

    if [ -f /etc/named.conf ] && [ ! -f /etc/named.conf.bak ]; then
        cp -p /etc/named.conf /etc/named.conf.bak
        log_success "Da tao ban sao luu: /etc/named.conf.bak"
    fi

    log_step "Ghi file /etc/named.conf..."
    cat << EOF_NAMED > /etc/named.conf
options {
    listen-on port 53 { any; };
    directory       "/var/named";
    allow-query     { any; };
    forwarders      { 8.8.8.8; };
    recursion yes;
    dnssec-validation no;
};

zone "." IN {
    type hint;
    file "named.ca";
};

zone "${FORWARD_ZONE}" IN {
    type master;
    file "${FORWARD_ZONE}.db";
    allow-update { none; };
};

zone "${REVERSE_ZONE}" IN {
    type master;
    file "${REVERSE_ZONE}.db";
    allow-update { none; };
};

include "/etc/named.rfc1912.zones";
include "/etc/named.root.key";
EOF_NAMED

    log_step "Phan quyen cho user 'named'..."
    chown root:named /etc/named.conf "$FWD_FILE" "$REV_FILE"
    chmod 640 /etc/named.conf "$FWD_FILE" "$REV_FILE"

    log_step "Kiem tra cu phap BIND..."
    named-checkconf /etc/named.conf
    named-checkzone "$FORWARD_ZONE" "$FWD_FILE"
    named-checkzone "$REVERSE_ZONE" "$REV_FILE"

    log_step "Khoi dong service named..."
    systemctl restart named
    systemctl enable named

    if systemctl is-active --quiet firewalld; then
        log_step "Mo cong DNS (53 tcp/udp) tren firewalld..."
        firewall-cmd --add-service=dns --permanent --zone=internal
        firewall-cmd --add-service=dns --permanent --zone=public
        firewall-cmd --reload
    fi
    log_success "BIND DNS Server da duoc cau hinh thanh cong cho mien $FORWARD_ZONE!"
}

# ==============================================================================
# 5. CAU HINH DHCP SERVER
# ==============================================================================
module_setup_dhcp() {
    echo -e "\n${BLUE}======================================================${NC}"
    echo -e "${BLUE} CAU HINH ISC DHCP SERVER                             ${NC}"
    echo -e "${BLUE}======================================================${NC}"

    log_step "Kiem tra va cai dat dhcp-server..."
    dnf install -y dhcp-server
    local CONF_PATH="/etc/dhcp/dhcpd.conf"

    get_lan_topology_info
    local NET_PREFIX
    NET_PREFIX=$(echo "$TOPOLOGY_LAN_IP" | cut -d. -f1-3)

    read -rp "Dia chi Subnet mang [$TOPOLOGY_LAN_SUBNET]: " SUBNET
    SUBNET=${SUBNET:-$TOPOLOGY_LAN_SUBNET}
    read -rp "Subnet Mask [255.255.255.0]: " NETMASK
    NETMASK=${NETMASK:-255.255.255.0}
    read -rp "Dai IP cap - Bat dau [${NET_PREFIX}.100]: " RANGE_START
    RANGE_START=${RANGE_START:-${NET_PREFIX}.100}
    read -rp "Dai IP cap - Ket thuc [${NET_PREFIX}.200]: " RANGE_END
    RANGE_END=${RANGE_END:-${NET_PREFIX}.200}
    read -rp "Default Gateway [$TOPOLOGY_LAN_IP]: " GATEWAY
    GATEWAY=${GATEWAY:-$TOPOLOGY_LAN_IP}
    read -rp "DNS Servers [$TOPOLOGY_LAN_IP]: " DNS_SERVERS
    DNS_SERVERS=${DNS_SERVERS:-$TOPOLOGY_LAN_IP}

    log_step "Ghi file cau hinh $CONF_PATH..."
    cat << EOF_DHCP > "$CONF_PATH"
default-lease-time 600;
max-lease-time 7200;
authoritative;

subnet $SUBNET netmask $NETMASK {
    range $RANGE_START $RANGE_END;
    option subnet-mask $NETMASK;
    option routers $GATEWAY;
    option domain-name-servers $DNS_SERVERS;
}
EOF_DHCP

    log_step "Kiem tra cu phap dhcpd.conf..."
    dhcpd -t -cf "$CONF_PATH"

    if systemctl is-active --quiet firewalld; then
        log_step "Mo dich vu DHCP tren Firewalld..."
        firewall-cmd --zone=internal --add-service=dhcp --permanent
        firewall-cmd --zone=public --add-service=dhcp --permanent
        firewall-cmd --reload
    fi

    log_step "Khoi dong lai service dhcpd..."
    systemctl enable --now dhcpd
    systemctl restart dhcpd
    log_success "DHCP Server da hoat dong on dinh!"
}

# ==============================================================================
# 6. CAU HINH FTP SERVER (VSFTPD)
# ==============================================================================
module_setup_ftp() {
    echo -e "\n${BLUE}======================================================${NC}"
    echo -e "${BLUE} CAU HINH VSFTPD SERVER                               ${NC}"
    echo -e "${BLUE}======================================================${NC}"

    log_step "Kiem tra va cai dat vsftpd..."
    dnf install -y vsftpd
    local CONF_FILE="/etc/vsftpd/vsftpd.conf"

    log_step "Ghi file cau hinh $CONF_FILE..."
    cat << 'EOF_FTP' > "$CONF_FILE"
listen=YES
listen_ipv6=NO
listen_port=21
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=022
chroot_local_user=YES
allow_writeable_chroot=YES
pasv_enable=YES
pasv_min_port=30000
pasv_max_port=31000
userlist_enable=NO
pam_service_name=vsftpd
EOF_FTP

    read -rp "Nhap ten user FTP [Mac dinh: ftpuser]: " FTP_USER
    FTP_USER=${FTP_USER:-ftpuser}

    if ! id "$FTP_USER" &>/dev/null; then
        log_step "Tao tai khoan '$FTP_USER' voi nologin shell..."
        useradd -m -s /sbin/nologin "$FTP_USER"
        echo "Dat mat khau cho tai khoan '$FTP_USER':"
        passwd "$FTP_USER"
    else
        log_warn "Tai khoan '$FTP_USER' da ton tai."
    fi

    if command -v getenforce &>/dev/null && [ "$(getenforce)" != "Disabled" ]; then
        log_step "Cap quyen SELinux ftpd_full_access..."
        setsebool -P ftpd_full_access 1 || true
    fi

    if systemctl is-active --quiet firewalld; then
        log_step "Mo port FTP (21) va Passive ports (30000-31000) tren ca 2 zone..."
        for z in internal public; do
            firewall-cmd --permanent --zone=$z --add-service=ftp
            firewall-cmd --permanent --zone=$z --add-port=30000-31000/tcp
        done
        firewall-cmd --reload
    fi

    log_step "Khoi dong service vsftpd..."
    systemctl enable --now vsftpd
    systemctl restart vsftpd
    log_success "FTP Server (vsftpd) cau hinh hoan tat!"
}

# ==============================================================================
# 7. CAU HINH WEB SERVER (NGINX & SSL)
# ==============================================================================
module_setup_web() {
    echo -e "\n${BLUE}======================================================${NC}"
    echo -e "${BLUE} CAU HINH NGINX & OPENSSL SSL                         ${NC}"
    echo -e "${BLUE}======================================================${NC}"

    log_step "Cai dat nginx, nano, openssl..."
    dnf install -y nginx nano openssl
    systemctl enable --now nginx
    mkdir -p /etc/nginx/ssl

    if systemctl is-active --quiet firewalld; then
        log_step "Mo port HTTP (80) va HTTPS (443) tren Firewalld..."
        for z in internal public; do
            firewall-cmd --zone=$z --add-service=http --permanent
            firewall-cmd --zone=$z --add-service=https --permanent
        done
        firewall-cmd --reload
    fi

    read -rp "Nhap Domain hoac IP website [nhom5.local]: " DOMAIN_IP
    DOMAIN_IP=${DOMAIN_IP:-nhom5.local}
    local WEB_ROOT="/var/www/$DOMAIN_IP"
    mkdir -p "$WEB_ROOT"

    log_step "Khoi tao file $WEB_ROOT/index.html..."
    cat << EOF_HTML > "$WEB_ROOT/index.html"
<!DOCTYPE html>
<html>
<head><title>Website $DOMAIN_IP</title></head>
<body><h1>Chao mung den voi website: $DOMAIN_IP</h1></body>
</html>
EOF_HTML

    chown -R nginx:nginx "$WEB_ROOT"
    chmod -R 755 "$WEB_ROOT"

    log_step "Khoi tao chung chi SSL tu ky bang OpenSSL..."
    local SSL_KEY="/etc/nginx/ssl/${DOMAIN_IP}.key"
    local SSL_CRT="/etc/nginx/ssl/${DOMAIN_IP}.crt"

    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$SSL_KEY" \
        -out "$SSL_CRT" \
        -subj "/C=VN/ST=HCM/L=HCM/O=Lab/CN=${DOMAIN_IP}" 2>/dev/null

    local CONF_FILE="/etc/nginx/conf.d/${DOMAIN_IP}.conf"
    log_step "Ghi file VirtualHost $CONF_FILE..."
    cat << 'EOF_NGINX' > "$CONF_FILE"
server {
    listen 80;
    server_name __DOMAIN__ www.__DOMAIN__;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name __DOMAIN__ www.__DOMAIN__;

    ssl_certificate /etc/nginx/ssl/__DOMAIN__.crt;
    ssl_certificate_key /etc/nginx/ssl/__DOMAIN__.key;

    root /var/www/__DOMAIN__;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }
}
EOF_NGINX
    sed -i "s/__DOMAIN__/$DOMAIN_IP/g" "$CONF_FILE"

    log_step "Kiem tra cu phap Nginx va nap lai..."
    nginx -t && systemctl reload nginx
    log_success "Web Server (Nginx HTTPS) san sang tai: $CONF_FILE"
}

# ==============================================================================
# 8. CAU HINH NFS SERVER & CLIENT
# ==============================================================================
module_setup_nfs() {
    chon_card_mang_va_subnet_nfs() {
        echo ""
        echo "--- DANH SACH CARD MANG DANG HOAT DONG ---"
        mapfile -t danh_sach_nic < <(ip -o -4 addr show | awk '$2 != "lo" {print $2, $4}')
        
        if [ ${#danh_sach_nic[@]} -eq 0 ]; then
            read -rp "Nhap dai mang Client (VD: 192.168.10.0/24): " CLIENT_NETWORK
            return
        fi

        for i in "${!danh_sach_nic[@]}"; do
            echo " $((i+1)). Card: $(echo "${danh_sach_nic[$i]}" | awk '{print $1}') | IP: $(echo "${danh_sach_nic[$i]}" | awk '{print $2}')"
        done
        echo " $(( ${#danh_sach_nic[@]} + 1 )). Nhap thu cong"
        echo "------------------------------------------"

        read -rp "Chon card mang cho NFS [1-$(( ${#danh_sach_nic[@]} + 1 ))]: " LUA_CHON

        if [[ "$LUA_CHON" -ge 1 && "$LUA_CHON" -le "${#danh_sach_nic[@]}" ]]; then
            local CHOSEN_NIC
            CHOSEN_NIC=$(echo "${danh_sach_nic[$((LUA_CHON-1))]}" | awk '{print $1}')
            local DETECTED_SUBNET
            DETECTED_SUBNET=$(ip route show dev "$CHOSEN_NIC" proto kernel 2>/dev/null | awk '{print $1}' | head -n1)
            
            if [ -n "$DETECTED_SUBNET" ]; then
                read -rp "Phat hien Subnet la [$DETECTED_SUBNET]. Dung dai nay? (Y/n): " XAC_NHAN
                XAC_NHAN=${XAC_NHAN:-Y}
                if [[ "$XAC_NHAN" =~ ^[Yy]$ ]]; then
                    CLIENT_NETWORK="$DETECTED_SUBNET"
                else
                    read -rp "Nhap dai mang cho card $CHOSEN_NIC: " CLIENT_NETWORK
                fi
            else
                read -rp "Nhap dai Subnet thu cong: " CLIENT_NETWORK
            fi
        else
            read -rp "Nhap dai mang Client cho phep (VD: 192.168.10.0/24): " CLIENT_NETWORK
        fi
    }

    nfs_setup_server() {
        echo -e "\n${BLUE}--- CAU HINH NFS SERVER ---${NC}"
        read -rp "Nhap duong dan thu muc chia se [/mnt/nfs_share]: " SHARE_DIR
        SHARE_DIR=${SHARE_DIR:-/mnt/nfs_share}

        local CLIENT_NETWORK=""
        chon_card_mang_va_subnet_nfs

        log_step "Cai dat goi nfs-utils..."
        dnf install -y nfs-utils

        log_step "Tao thu muc $SHARE_DIR va phan quyen..."
        mkdir -p "$SHARE_DIR"
        chown -R nobody:nobody "$SHARE_DIR"
        chmod -R 777 "$SHARE_DIR"

        log_step "Cap nhat /etc/exports..."
        touch /etc/exports
        sed -i "\|$SHARE_DIR|d" /etc/exports
        echo "$SHARE_DIR $CLIENT_NETWORK(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
        exportfs -rav

        log_step "Kich hoat nfs-server..."
        systemctl enable --now nfs-server

        if systemctl is-active --quiet firewalld; then
            log_step "Mo port NFS tren ca zone internal va public..."
            for z in internal public; do
                firewall-cmd --permanent --zone=$z --add-service=nfs
                firewall-cmd --permanent --zone=$z --add-service=rpc-bind
                firewall-cmd --permanent --zone=$z --add-service=mountd
            done
            firewall-cmd --reload
        fi
        log_success "NFS Server san sang tai $SHARE_DIR cho dai mang $CLIENT_NETWORK"
    }

    nfs_setup_client() {
        echo -e "\n${BLUE}--- CAU HINH NFS CLIENT ---${NC}"
        read -rp "Nhap IP cua NFS Server: " SERVER_IP
        while [ -z "$SERVER_IP" ]; do
            read -rp "IP Server khong duoc de trong: " SERVER_IP
        done

        read -rp "Thu muc tren Server [/mnt/nfs_share]: " REMOTE_SHARE
        REMOTE_SHARE=${REMOTE_SHARE:-/mnt/nfs_share}

        read -rp "Thu muc mount cuc bo [/mnt/client_share]: " LOCAL_MOUNT
        LOCAL_MOUNT=${LOCAL_MOUNT:-/mnt/client_share}

        log_step "Cai dat nfs-utils tren Client..."
        dnf install -y nfs-utils

        log_step "Tao thu muc $LOCAL_MOUNT..."
        mkdir -p "$LOCAL_MOUNT"

        log_step "Ghi /etc/fstab de mount tu dong..."
        touch /etc/fstab
        sed -i "\|$LOCAL_MOUNT|d" /etc/fstab
        echo "$SERVER_IP:$REMOTE_SHARE    $LOCAL_MOUNT    nfs    _netdev,auto,nofail    0  0" >> /etc/fstab

        log_step "Tien hanh mount -a..."
        mount -a || true

        if findmnt "$LOCAL_MOUNT" > /dev/null 2>&1; then
            log_success "Mount thanh cong tai: $LOCAL_MOUNT"
            findmnt "$LOCAL_MOUNT"
        else
            log_error "Mount that bai! Hay kiem tra 'showmount -e $SERVER_IP' va Firewall Server."
        fi
    }

    while true; do
        echo ""
        echo "=========================================="
        echo "    CONG CU CAU HINH NFS - CENTOS 9       "
        echo "=========================================="
        echo "  1) Cau hinh may nay lam NFS Server"
        echo "  2) Cau hinh may nay lam NFS Client"
        echo "  0) Quay lai Menu chinh"
        echo "=========================================="
        read -rp "Vui long chon [0-2]: " NFS_CHOICE

        case "$NFS_CHOICE" in
            1) nfs_setup_server; pause_menu ;;
            2) nfs_setup_client; pause_menu ;;
            0) return 0 ;;
            *) log_error "Lua chon khong hop le!" ;;
        esac
    done
}

# ==============================================================================
# 9. CAU HINH SAMBA FILE SHARING
# ==============================================================================
module_setup_samba() {
    echo -e "\n${BLUE}======================================================${NC}"
    echo -e "${BLUE}       CAU HINH SAMBA FILE SHARING (CENTOS 9)         ${NC}"
    echo -e "${BLUE}======================================================${NC}"

    log_step "Cai dat samba, samba-common, samba-client..."
    dnf install -y samba samba-common samba-client

    echo -e "\n--- CHON CARD MANG / SUBNET CHO SAMBA ---"
    mapfile -t IFACE_LIST < <(ip -o link show | awk -F': ' '{print $2}' | grep -v "^lo$")

    local index=1
    for iface in "${IFACE_LIST[@]}"; do
        local iface_ip
        iface_ip=$(ip -o -4 addr show "$iface" | awk '{print $4}' | head -n1)
        iface_ip=${iface_ip:-"Chua co IP"}
        echo "   [$index] Card: $iface ($iface_ip)"
        ((index++))
    done
    echo "   [$index] Nhap thu cong Subnet"
    echo "   [0] Lang nghe tren TAT CA card mang (Mac dinh)"

    read -rp "Lua chon [0-$index, mac dinh 0]: " NET_CHOICE
    NET_CHOICE=${NET_CHOICE:-0}

    local SMB_INTERFACES_CONF=""
    if [ "$NET_CHOICE" -ge 1 ] && [ "$NET_CHOICE" -lt "$index" ]; then
        local selected_iface="${IFACE_LIST[$((NET_CHOICE - 1))]}"
        SMB_INTERFACES_CONF="interfaces = 127.0.0.1 $selected_iface\n    bind interfaces only = yes"
    elif [ "$NET_CHOICE" -eq "$index" ]; then
        read -rp "Nhap dai Subnet/IP: " CUSTOM_NET
        SMB_INTERFACES_CONF="interfaces = 127.0.0.1 $CUSTOM_NET\n    bind interfaces only = yes"
    fi

    read -rp "Nhap ten Share [sambashare]: " SMB_SHARE_NAME
    SMB_SHARE_NAME=${SMB_SHARE_NAME:-sambashare}

    read -rp "Nhap duong dan thu muc [/srv/samba/share]: " SMB_SHARE_DIR
    SMB_SHARE_DIR=${SMB_SHARE_DIR:-/srv/samba/share}

    log_step "Tao thu muc $SMB_SHARE_DIR va phan quyen..."
    mkdir -p "$SMB_SHARE_DIR"
    chmod -R 777 "$SMB_SHARE_DIR"

    if command -v getenforce &>/dev/null && [ "$(getenforce)" != "Disabled" ]; then
        log_step "Gan nhan SELinux samba_share_t..."
        chcon -t samba_share_t "$SMB_SHARE_DIR" || true
        setsebool -P samba_enable_home_dirs 1 || true
    fi

    read -rp "Nhap user Samba [Mac dinh: smbuser]: " SMB_USER
    SMB_USER=${SMB_USER:-smbuser}

    if ! id "$SMB_USER" &>/dev/null; then
        useradd -m -s /sbin/nologin "$SMB_USER"
    fi
    log_step "Nhap mat khau Samba cho user '$SMB_USER':"
    smbpasswd -a "$SMB_USER"

    log_step "Ghi file /etc/samba/smb.conf..."
    cat << 'EOF_SMB_GLOBAL' > /etc/samba/smb.conf
[global]
    workgroup = SAMBA
    security = user
    passdb backend = tdbsam
    printing = cups
    printcap name = cups
    load printers = yes
    cups options = raw
EOF_SMB_GLOBAL

    if [ -n "$SMB_INTERFACES_CONF" ]; then
        echo -e "    $SMB_INTERFACES_CONF" >> /etc/samba/smb.conf
    fi

    cat << EOF_SMB_SHARE >> /etc/samba/smb.conf

[$SMB_SHARE_NAME]
    comment = Shared Folder via Samba
    path = $SMB_SHARE_DIR
    valid users = $SMB_USER
    read only = no
    browsable = yes
    writable = yes
    create mask = 0777
    directory mask = 0777
EOF_SMB_SHARE

    if systemctl is-active --quiet firewalld; then
        log_step "Mo dich vu Samba tren ca 2 zone Firewalld..."
        for z in internal public; do
            firewall-cmd --permanent --zone=$z --add-service=samba
        done
        firewall-cmd --reload
    fi

    log_step "Khoi dong smb va nmb..."
    systemctl enable --now smb nmb
    systemctl restart smb nmb
    log_success "Samba File Sharing da hoat dong!"
}

# ==============================================================================
# 10. CAU HINH SAMBA ACTIVE DIRECTORY DOMAIN CONTROLLER (AD DC)
# ==============================================================================
module_setup_samba_ad() {
    echo -e "\n${CYAN}==================================================================${NC}"
    echo -e "${CYAN}    CAU HINH SAMBA ACTIVE DIRECTORY DOMAIN CONTROLLER (AD DC)     ${NC}"
    echo -e "${CYAN}==================================================================${NC}"

    get_lan_topology_info

    echo -e "${YELLOW}Vui long nhap thong tin thiet lap Samba AD DC:${NC}"
    read -rp "1. Ten mien Domain FQDN [nhom5.local]: " DOMAIN_NAME
    DOMAIN_NAME="${DOMAIN_NAME:-nhom5.local}"

    local REALM_DEFAULT
    REALM_DEFAULT=$(echo "$DOMAIN_NAME" | tr '[:lower:]' '[:upper:]')
    read -rp "2. Realm Kerberos (mac dinh: $REALM_DEFAULT): " REALM
    REALM="${REALM:-$REALM_DEFAULT}"

    local NETBIOS_DEFAULT
    NETBIOS_DEFAULT=$(echo "$DOMAIN_NAME" | cut -d. -f1 | tr '[:lower:]' '[:upper:]')
    read -rp "3. NetBIOS Domain Name (mac dinh: $NETBIOS_DEFAULT): " NETBIOS_NAME
    NETBIOS_NAME="${NETBIOS_NAME:-$NETBIOS_DEFAULT}"

    read -rp "4. Hostname may chu DC [srvads]: " SERVER_HOSTNAME
    SERVER_HOSTNAME="${SERVER_HOSTNAME:-srvads}"

    echo -e "${CYAN}[*] Luu y: Card DC phai la card LAN noi bo (VD: $TOPOLOGY_LAN_IFACE). Tuyet doi khong chon card WAN!${NC}"
    read -rp "5. Card mang LAN cho DC [$TOPOLOGY_LAN_IFACE]: " INTERFACE
    INTERFACE="${INTERFACE:-$TOPOLOGY_LAN_IFACE}"

    read -rp "6. Dia chi IP DC [$TOPOLOGY_LAN_IP]: " STATIC_IP
    STATIC_IP="${STATIC_IP:-$TOPOLOGY_LAN_IP}"

    read -rp "7. Subnet Mask Prefix (CIDR) [24]: " NETMASK
    NETMASK="${NETMASK:-24}"

    read -rp "8. DNS Forwarder ra Internet [8.8.8.8]: " DNS_FORWARDER
    DNS_FORWARDER="${DNS_FORWARDER:-8.8.8.8}"

    read -rp "9. Mat khau Administrator AD [Admin@Nhom52026!]: " ADMIN_PASS
    ADMIN_PASS="${ADMIN_PASS:-Admin@Nhom52026!}"

    echo ""
    echo -e "${YELLOW}Chon DNS Backend cho AD DC:${NC}"
    echo " 1) SAMBA_INTERNAL - DNS tich hop san cua Samba (Don gian, khuyen nghi)"
    echo " 2) BIND9_DLZ      - Tich hop vao dich vu BIND9/named"
    read -rp "Lua chon [1 hoac 2, mac dinh 1]: " DNS_CHOICE
    DNS_CHOICE="${DNS_CHOICE:-1}"

    local DNS_BACKEND="SAMBA_INTERNAL"
    local DNS_BACKEND_NAME="Samba Internal DNS"
    if [ "$DNS_CHOICE" == "2" ]; then
        DNS_BACKEND="BIND9_DLZ"
        DNS_BACKEND_NAME="BIND9 DLZ"
    fi

    log_step "[1/9] Thiet lap Hostname va /etc/hosts..."
    hostnamectl set-hostname "${SERVER_HOSTNAME}.${DOMAIN_NAME}"
    log_success "Da doi hostname thanh: $(hostname)"

    cat << EOF_HOSTS > /etc/hosts
127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4
::1         localhost localhost.localdomain localhost6 localhost6.localdomain6
${STATIC_IP} ${SERVER_HOSTNAME}.${DOMAIN_NAME} ${SERVER_HOSTNAME}
EOF_HOSTS
    log_success "Da cap nhat file /etc/hosts."

    log_step "Cap nhat DNS 127.0.0.1 tren card $INTERFACE..."
    nmcli con mod "$INTERFACE" ipv4.dns "127.0.0.1" 2>/dev/null || true
    nmcli con up "$INTERFACE" || true

    log_step "[2/9] Vo hieu hoa avahi-daemon va kiem tra SELinux..."
    setenforce 0 2>/dev/null || true
    systemctl stop avahi-daemon.service avahi-daemon.socket 2>/dev/null || true
    systemctl disable avahi-daemon.service avahi-daemon.socket 2>/dev/null || true
    log_success "Avahi-daemon da duoc tat."

    log_step "[3/9] Mo cong Active Directory tren Firewalld (Zone internal & public)..."
    systemctl enable --now firewalld
    for z in internal public; do
        log_step "  -> Mo cong tren zone: $z"
        firewall-cmd --zone=$z --permanent --add-port={53,88,389,464}/tcp
        firewall-cmd --zone=$z --permanent --add-port={53,88,389,464}/udp
        firewall-cmd --zone=$z --permanent --add-port=123/udp
        firewall-cmd --zone=$z --permanent --add-port={135,445,636,3268,3269}/tcp
        firewall-cmd --zone=$z --permanent --add-port=49152-65535/tcp
    done
    firewall-cmd --reload
    log_success "Mo port Firewalld cho AD DC hoan tat."

    log_step "[4/9] Cai dat kho goi Tranquil IT Samba va cac package can thiet..."
    dnf install -y epel-release wget
    dnf config-manager --set-enabled crb 2>/dev/null || true

    wget -q -O /etc/pki/rpm-gpg/RPM-GPG-KEY-TISSAMBA-9 https://samba.tranquil.it/RPM-GPG-KEY-TISSAMBA-9
    rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-TISSAMBA-9

    cat << 'EOF_REPO' > /etc/yum.repos.d/tissamba.repo
[tis-samba]
name=tis-samba
baseurl=https://samba.tranquil.it/redhat9/samba-4.24/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-TISSAMBA-9
EOF_REPO

    local COMMON_PACKAGES="samba samba-dc samba-winbind samba-winbind-clients krb5-workstation ldb-tools bind-utils chrony samba-client python3-markdown"
    if [ "$DNS_BACKEND" == "BIND9_DLZ" ]; then
        dnf --enablerepo=crb install -y $COMMON_PACKAGES bind samba-dc-bind-dlz
    else
        dnf --enablerepo=crb install -y $COMMON_PACKAGES
    fi
    log_success "Cai dat goi phan mem Samba AD hoan tat."

    log_step "[5/9] Khoi tao file cau hinh Kerberos /etc/krb5.conf..."
    cat << EOF_KRB > /etc/krb5.conf
[libdefaults]
    default_realm = ${REALM}
    dns_lookup_kdc = false
    dns_lookup_realm = false

[realms]
    ${REALM} = {
        kdc = 127.0.0.1
    }
EOF_KRB
    log_success "Da tao file Kerberos config."

    log_step "[6/9] Khoi tao AD DC (Provisioning)..."
    if [ -f /etc/samba/smb.conf ]; then
        cp /etc/samba/smb.conf /etc/samba/smb.conf.ad.bak
        rm -f /etc/samba/smb.conf
    fi

    samba-tool domain provision \
        --realm="${REALM}" \
        --domain="${NETBIOS_NAME}" \
        --server-role=dc \
        --dns-backend="${DNS_BACKEND}" \
        --use-rfc2307 \
        --adminpass="${ADMIN_PASS}"

    rm -f /var/lib/samba/private/krb5.conf
    ln -sf /etc/krb5.conf /var/lib/samba/private/krb5.conf

    if [ "$DNS_BACKEND" == "SAMBA_INTERNAL" ]; then
        if ! grep -q "dns forwarder" /etc/samba/smb.conf; then
            sed -i "/\[global\]/a \    dns forwarder = ${DNS_FORWARDER}" /etc/samba/smb.conf
        fi
    else
        if ! grep -q "server services = -dns" /etc/samba/smb.conf; then
            sed -i '/\[global\]/a \    server services = -dns' /etc/samba/smb.conf
        fi
    fi

    log_step "Dat mat khau Administrator khong bao gio het han..."
    samba-tool user setexpiry administrator --noexpiry
    log_success "Provisioning Domain Controller thanh cong!"

    log_step "[7/9] Cau hinh Chrony dong bo gio MS-SNTP cho AD..."
    mkdir -p /var/lib/samba/ntp_signd
    chown -R root:chrony /var/lib/samba/ntp_signd
    chmod 750 /var/lib/samba/ntp_signd

    sed -i '/ntpsigndsocket/d' /etc/chrony.conf
    sed -i '/allow /d' /etc/chrony.conf

    local NETWORK_SUBNET
    NETWORK_SUBNET=$(echo "$STATIC_IP" | cut -d. -f1-3).0
    cat << EOF_CHRONY >> /etc/chrony.conf
ntpsigndsocket /var/lib/samba/ntp_signd
allow ${NETWORK_SUBNET}/${NETMASK}
EOF_CHRONY
    systemctl restart chronyd
    log_success "Chrony da duoc dong bo voi NTP sign socket."

    log_step "[8/9] Thiet lap Backend DNS ($DNS_BACKEND_NAME)..."
    if [ "$DNS_BACKEND" == "BIND9_DLZ" ]; then
        local BIND_VER
        BIND_VER=$(named -v 2>/dev/null | awk '{print $2}' | cut -d. -f1,2)
        if [ -f "/var/lib/samba/bind-dns/named.conf" ]; then
            case "$BIND_VER" in
                "9.16") sed -i -E 's|#\s*(database "dlopen .*/dlz_bind9_16.so";)|\1|' /var/lib/samba/bind-dns/named.conf ;;
                "9.18") sed -i -E 's|#\s*(database "dlopen .*/dlz_bind9_18.so";)|\1|' /var/lib/samba/bind-dns/named.conf ;;
                *)
                    local MODULE
                    MODULE=$(find /usr/lib64/samba/bind9 /usr/lib/samba/bind9 -name "dlz_bind9*.so" 2>/dev/null | sort -V | tail -n1)
                    if [ -n "$MODULE" ]; then
                        local MOD_NAME
                        MOD_NAME=$(basename "$MODULE")
                        sed -i -E "s|#\s*(database \"dlopen .*$MOD_NAME\";)|\1|" /var/lib/samba/bind-dns/named.conf
                    fi
                    ;;
            esac
        fi

        cat << EOF_BIND_AD > /etc/named.conf
options {
    listen-on port 53 { any; };
    listen-on-v6 { none; };
    directory "/var/named";
    allow-query { any; };
    allow-recursion { any; };
    recursion yes;
    dnssec-validation no;
    forwarders {
        ${DNS_FORWARDER};
    };
    tkey-gssapi-keytab "/var/lib/samba/bind-dns/dns.keytab";
    minimal-responses yes;
};
include "/var/lib/samba/bind-dns/named.conf";
EOF_BIND_AD
        systemctl enable named samba
        systemctl restart named
        systemctl restart samba
    else
        log_step "Tat va mask dich vu named de giai phong Port 53 cho Samba DNS..."
        systemctl disable --now named 2>/dev/null || true
        systemctl mask named 2>/dev/null || true
        systemctl enable samba
        systemctl restart samba
    fi

    log_step "[9/9] Khoi dong cac dich vu va tu dong tao Zone nghich tren AD..."
    systemctl disable --now smb nmb winbind 2>/dev/null || true
    systemctl mask smb nmb winbind 2>/dev/null || true

    systemctl restart chronyd
    firewall-cmd --reload
    sleep 3

    calc_reverse_zone_info "$STATIC_IP"
    local AD_REV_ZONE="$CALC_REV_ZONE"
    local AD_PTR_PREFIX="$CALC_PTR_PREFIX"
    local DC_FQDN="${SERVER_HOSTNAME}.${DOMAIN_NAME}"

    log_step "Dang khoi tao Zone nghich ($AD_REV_ZONE) tren Samba AD..."
    samba-tool dns zonecreate 127.0.0.1 "$AD_REV_ZONE" -U administrator --password="${ADMIN_PASS}" 2>/dev/null || true

    log_step "Dang tao ban ghi PTR ($STATIC_IP -> ${DC_FQDN})..."
    samba-tool dns add 127.0.0.1 "$AD_REV_ZONE" "$AD_PTR_PREFIX" PTR "${DC_FQDN}." -U administrator --password="${ADMIN_PASS}" 2>/dev/null || true

    if [ -f /etc/dhcp/dhcpd.conf ]; then
        log_step "  -> Phat hien DHCP Server dang cai dat. Dang cap nhat DNS sang $STATIC_IP..."
        sed -i -E "s/option domain-name-servers .*/option domain-name-servers ${STATIC_IP};/" /etc/dhcp/dhcpd.conf
        systemctl restart dhcpd 2>/dev/null || true
    fi

    echo -e "nameserver 127.0.0.1\nnameserver ${DNS_FORWARDER}" > /etc/resolv.conf
    log_success "Samba Active Directory DC da san sang!"
}

# ==============================================================================
# 11. XOA BO SAMBA ACTIVE DIRECTORY (GO BO AD DC)
# ==============================================================================
module_remove_samba_ad() {
    echo -e "\n${RED}==================================================================${NC}"
    echo -e "${RED}         11. XOA BO VA GO BO HOAN TOAN SAMBA AD DC                ${NC}"
    echo -e "${RED}==================================================================${NC}"
    read -rp "Xac nhan xoa Samba AD DC khoi he thong? (y/n): " CONFIRM_RM
    [[ ! "$CONFIRM_RM" =~ ^[Yy]$ ]] && return 0

    log_step "[1/6] Dung va vo hieu hoa dich vu Samba AD DC..."
    systemctl stop samba 2>/dev/null || true
    systemctl disable samba 2>/dev/null || true

    log_step "[2/6] Mo khoa (unmask) smb, nmb, winbind, named..."
    systemctl unmask smb nmb winbind named 2>/dev/null || true

    log_step "[3/6] Xoa bo co so du lieu AD..."
    rm -rf /var/lib/samba/private /var/lib/samba/bind-dns /var/lib/samba/ntp_signd /etc/krb5.conf /etc/samba/smb.conf
    [ -f /etc/samba/smb.conf.ad.bak ] && mv /etc/samba/smb.conf.ad.bak /etc/samba/smb.conf

    log_step "[4/6] Don dep cau hinh Chrony NTP..."
    sed -i '/ntpsigndsocket/d' /etc/chrony.conf
    systemctl restart chronyd 2>/dev/null || true

    log_step "[5/6] Dong cac port tuong lua Active Directory..."
    for z in internal public; do
        firewall-cmd --zone=$z --permanent --remove-port={88,389,464}/tcp >/dev/null 2>&1 || true
        firewall-cmd --zone=$z --permanent --remove-port={88,389,464}/udp >/dev/null 2>&1 || true
        firewall-cmd --zone=$z --permanent --remove-port={135,636,3268,3269}/tcp >/dev/null 2>&1 || true
        firewall-cmd --zone=$z --permanent --remove-port=49152-65535/tcp >/dev/null 2>&1 || true
    done
    firewall-cmd --reload >/dev/null 2>&1 || true

    log_step "[6/6] Khoi phuc DNS local..."
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    log_success "Da xoa sach Samba AD DC!"
}

# ==============================================================================
# 12. CAU HINH MAIL SERVER CO BAN (POSTFIX + DOVECOT - LOCAL USER)
# ==============================================================================
module_setup_mail_basic() {
    echo -e "\n${BLUE}================================================================${NC}"
    echo -e "${BLUE}   12. CAU HINH MAIL SERVER LOCAL USER (POSTFIX + DOVECOT)      ${NC}"
    echo -e "${BLUE}================================================================${NC}"

    get_lan_topology_info

    read -rp "1. Nhap Ten mien (Domain) [nhom5.local]: " DOMAIN
    DOMAIN=${DOMAIN:-nhom5.local}

    read -rp "2. Nhap FQDN Mail Server [mail.$DOMAIN]: " MAIL_FQDN
    MAIL_FQDN=${MAIL_FQDN:-mail.$DOMAIN}

    echo -e "${CYAN}[*] Dai mang LAN noi bo tu dong nhan dien: $TOPOLOGY_LAN_SUBNET${NC}"
    read -rp "3. Dai mang tin cay (Trusted Subnet) [$TOPOLOGY_LAN_SUBNET]: " TRUSTED_NET
    TRUSTED_NET=${TRUSTED_NET:-$TOPOLOGY_LAN_SUBNET}

    read -rp "4. Ban co muon doi Hostname he thong thanh $MAIL_FQDN khong? (y/n) [n]: " CHANGE_HOST
    CHANGE_HOST=${CHANGE_HOST:-n}
    if [[ "$CHANGE_HOST" =~ ^[Yy]$ ]]; then
        hostnamectl set-hostname "$MAIL_FQDN"
        log_success "Da cap nhat Hostname he thong thanh: $MAIL_FQDN"
    else
        log_warn "Giu nguyen Hostname he thong hien tai: $(hostname)"
    fi

    if ! grep -q "$MAIL_FQDN" /etc/hosts; then
        echo "$TOPOLOGY_LAN_IP $MAIL_FQDN mail" >> /etc/hosts
        log_success "Da them '$TOPOLOGY_LAN_IP $MAIL_FQDN mail' vao /etc/hosts."
    fi

    echo ""
    log_step "[Buoc 1/7] Cai dat Postfix, Dovecot va cac cong cu kiem thu..."
    dnf install -y postfix dovecot s-nail telnet openssl
    log_success "Cai dat cac goi Mail hoan tat."

    log_step "[Buoc 2/7] Tao chung chi SSL tu ky cho $MAIL_FQDN..."
    local SSL_DIR="/etc/pki/tls/mail"
    mkdir -p "$SSL_DIR"
    openssl req -new -x509 -days 3650 -nodes \
        -out "$SSL_DIR/mail.crt" \
        -keyout "$SSL_DIR/mail.key" \
        -subj "/C=VN/ST=HCM/L=HCM/O=MailServer/CN=$MAIL_FQDN" 2>/dev/null
    chmod 600 "$SSL_DIR/mail.key"
    chmod 644 "$SSL_DIR/mail.crt"
    log_success "Chung chi SSL da duoc luu tai $SSL_DIR."

    log_step "[Buoc 3/7] Cau hinh Postfix MTA (main.cf, master.cf)..."
    [ -f /etc/postfix/main.cf.bak ] || cp /etc/postfix/main.cf /etc/postfix/main.cf.bak

    postconf -e "myhostname = $MAIL_FQDN"
    postconf -e "mydomain = $DOMAIN"
    postconf -e "myorigin = \$mydomain"
    postconf -e "inet_interfaces = all"
    postconf -e "inet_protocols = ipv4"
    postconf -e "mydestination = \$myhostname, localhost.\$mydomain, localhost, \$mydomain"
    postconf -e "mynetworks = 127.0.0.0/8, $TRUSTED_NET"
    postconf -e "home_mailbox = Maildir/"

    postconf -e "smtpd_sasl_type = dovecot"
    postconf -e "smtpd_sasl_path = private/auth"
    postconf -e "smtpd_sasl_auth_enable = yes"
    postconf -e "smtpd_sasl_security_options = noanonymous"
    postconf -e "smtpd_recipient_restrictions = permit_sasl_authenticated, permit_mynetworks, reject_unauth_destination"
    postconf -e "smtpd_tls_auth_only = no"
    postconf -e "smtpd_tls_cert_file = $SSL_DIR/mail.crt"
    postconf -e "smtpd_tls_key_file = $SSL_DIR/mail.key"
    postconf -e "smtpd_tls_security_level = may"

    sed -i 's/^#\?submission inet n       -       n       -       -       smtpd/submission inet n       -       n       -       -       smtpd/' /etc/postfix/master.cf
    sed -i '/^submission inet/,/^[^ ]/ s/^#\?  -o syslog_name=postfix\/submission/  -o syslog_name=postfix\/submission/' /etc/postfix/master.cf
    sed -i '/^submission inet/,/^[^ ]/ s/^#\?  -o smtpd_sasl_auth_enable=yes/  -o smtpd_sasl_auth_enable=yes/' /etc/postfix/master.cf
    sed -i '/^submission inet/,/^[^ ]/ s/^#\?  -o smtpd_reject_unlisted_recipient=no/  -o smtpd_reject_unlisted_recipient=no/' /etc/postfix/master.cf
    sed -i '/^submission inet/,/^[^ ]/ s/^#\?  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject/  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject/' /etc/postfix/master.cf
    log_success "Cau hinh Postfix MTA thanh cong!"

    log_step "[Buoc 4/7] Cau hinh Dovecot MDA va SASL authentication..."
    sed -i 's/^#\?protocols =.*/protocols = imap pop3 lmtp/' /etc/dovecot/dovecot.conf
    sed -i 's/^#\?listen =.*/listen = *, ::/' /etc/dovecot/dovecot.conf

    sed -i 's|^#\?mail_location =.*|mail_location = maildir:~/Maildir|' /etc/dovecot/conf.d/10-mail.conf
    sed -i 's/^#\?disable_plaintext_auth =.*/disable_plaintext_auth = no/' /etc/dovecot/conf.d/10-auth.conf
    sed -i 's/^#\?auth_mechanisms =.*/auth_mechanisms = plain login/' /etc/dovecot/conf.d/10-auth.conf

    sed -i 's/^#\?ssl =.*/ssl = yes/' /etc/dovecot/conf.d/10-ssl.conf
    sed -i "s|^#\?ssl_cert =.*|ssl_cert = <$SSL_DIR/mail.crt|" /etc/dovecot/conf.d/10-ssl.conf
    sed -i "s|^#\?ssl_key =.*|ssl_key = <$SSL_DIR/mail.key|" /etc/dovecot/conf.d/10-ssl.conf

    cat << 'EOF_DOVECOT_LOCAL' > /etc/dovecot/conf.d/10-master.conf
service imap-login {
  inet_listener imap {
    port = 143
  }
  inet_listener imaps {
    port = 993
    ssl = yes
  }
}

service pop3-login {
  inet_listener pop3 {
    port = 110
  }
  inet_listener pop3s {
    port = 995
    ssl = yes
  }
}

service lmtp {
}

service imap {
}

service pop3 {
}

service auth {
  unix_listener auth-userdb {
  }

  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
}

service auth-worker {
}

service dict {
}
EOF_DOVECOT_LOCAL
    log_success "Cau hinh Dovecot 10-master.conf chuan cu phap hoan tat."

    log_step "[Buoc 5/7] Thiet lap Maildir skeleton va khoi tao user local..."
    mkdir -p /etc/skel/Maildir/{cur,new,tmp}
    chmod -R 700 /etc/skel/Maildir

    read -rp "Nhap danh sach tai khoan local muon tao (cach nhau boi khoang trang) [tien xuyen]: " LOCAL_USERS
    LOCAL_USERS=${LOCAL_USERS:-tien xuyen}
    for u in $LOCAL_USERS; do
        if ! id "$u" &>/dev/null; then
            useradd -m "$u"
            echo "$u:qtmmtK24@" | chpasswd
            mkdir -p "/home/$u/Maildir/"{cur,new,tmp}
            chown -R "$u:$u" "/home/$u/Maildir"
            chmod -R 700 "/home/$u/Maildir"
            log_success "Da tao user: $u@$DOMAIN (Mat khau mac dinh: qtmmtK24@)"
        else
            log_warn "User $u da ton tai."
        fi
    done

    log_step "[Buoc 6/7] Kiem tra cu phap cac dich vu..."
    if doveconf -n >/dev/null; then
        log_success "Cu phap Dovecot: [HOP LE]"
    else
        log_error "Loi cu phap Dovecot!"
        doveconf -n
        return 1
    fi

    if postfix check; then
        log_success "Cu phap Postfix: [HOP LE]"
    else
        log_error "Loi cu phap Postfix!"
        return 1
    fi

    log_step "[Buoc 7/7] Mo port Firewalld va khoi chay dich vu..."
    if systemctl is-active --quiet firewalld; then
        for z in internal public; do
            firewall-cmd --zone=$z --permanent --add-port={25,110,143,587,993,995}/tcp
            firewall-cmd --zone=$z --permanent --add-service={smtp,smtp-submission,imap,imaps,pop3,pop3s} >/dev/null 2>&1 || true
        done
        firewall-cmd --reload
        log_success "Da mo cac port Mail tren ca internal va public."
    fi

    systemctl enable --now postfix dovecot
    systemctl restart postfix dovecot
    add_dns_mail_records "$DOMAIN" "$MAIL_FQDN" "$TOPOLOGY_LAN_IP"

    echo ""
    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN}       DA CAI DAT MAIL SERVER LOCAL USER THANH CONG!            ${NC}"
    echo -e "${GREEN}================================================================${NC}"
    systemctl is-active --quiet postfix && echo -e "  - Postfix: ${GREEN}RUNNING${NC}" || echo -e "  - Postfix: ${RED}STOPPED${NC}"
    systemctl is-active --quiet dovecot && echo -e "  - Dovecot: ${GREEN}RUNNING${NC}" || echo -e "  - Dovecot: ${RED}STOPPED${NC}"
    echo -e "  - Domain:        ${CYAN}$DOMAIN${NC}"
    echo -e "  - Mail Hostname: ${CYAN}$MAIL_FQDN${NC}"
    echo -e "  - IMAP:          Port 143 (STARTTLS/Plain) | Port 993 (SSL/TLS)"
    echo -e "  - POP3:          Port 110 (STARTTLS/Plain) | Port 995 (SSL/TLS)"
    echo -e "  - SMTP:          Port 25 (Internal)       | Port 587 (Submission)"
    echo -e "  - Client Setup:  Dung Thunderbird ket noi vao $MAIL_FQDN voi cac user vua tao."
    echo -e "${GREEN}================================================================${NC}"
}

# ==============================================================================
# 13. CAU HINH ENTERPRISE WEBMAIL (PHP 8.3 APPSTREAM + ROUNDCUBE + POSTFIXADMIN)
# ==============================================================================
module_setup_webmail_enterprise() {
    echo -e "\n${BLUE}====================================================================${NC}"
    echo -e "${BLUE}   13. CAU HINH ENTERPRISE WEBMAIL (PHP 8.3 GOC + ROUNDCUBE)        ${NC}"
    echo -e "${BLUE}====================================================================${NC}"

    get_lan_topology_info

    read -rp "1. Nhap Ten mien (Domain) [nhom5.local]: " DOMAIN
    DOMAIN=${DOMAIN:-nhom5.local}

    read -rp "2. Nhap FQDN Mail Server [mail.$DOMAIN]: " MAIL_FQDN
    MAIL_FQDN=${MAIL_FQDN:-mail.$DOMAIN}

    echo -e "${CYAN}[*] Dai mang LAN noi bo tu dong nhan dien: $TOPOLOGY_LAN_SUBNET${NC}"
    read -rp "3. Dai mang tin cay (Trusted Subnet) [$TOPOLOGY_LAN_SUBNET]: " TRUSTED_NET
    TRUSTED_NET=${TRUSTED_NET:-$TOPOLOGY_LAN_SUBNET}

    read -rp "4. Ban co muon doi Hostname he thong thanh $MAIL_FQDN khong? (y/n) [n]: " CHANGE_HOST
    CHANGE_HOST=${CHANGE_HOST:-n}
    if [[ "$CHANGE_HOST" =~ ^[Yy]$ ]]; then
        hostnamectl set-hostname "$MAIL_FQDN"
        log_success "Da cap nhat Hostname he thong thanh: $MAIL_FQDN"
    else
        log_warn "Giu nguyen Hostname he thong hien tai: $(hostname)"
    fi

    if ! grep -q "$MAIL_FQDN" /etc/hosts; then
        echo "$TOPOLOGY_LAN_IP $MAIL_FQDN mail" >> /etc/hosts
        log_success "Da them '$TOPOLOGY_LAN_IP $MAIL_FQDN mail' vao /etc/hosts."
    fi

    read -rp "5. Mat khau chung cho Database (mailuser, roundcube) [qtmmtK24@]: " DB_COMMON_PASS
    DB_COMMON_PASS=${DB_COMMON_PASS:-qtmmtK24@}

    read -rp "6. Email admin he thong [admin@$DOMAIN]: " ADMIN_EMAIL
    ADMIN_EMAIL=${ADMIN_EMAIL:-admin@$DOMAIN}

    # Ma hoa ky tu @ thanh %40 cho chuoi ket noi MySQL DSN cua Roundcube
    local DB_COMMON_PASS_URL
    DB_COMMON_PASS_URL=$(echo -n "$DB_COMMON_PASS" | sed 's/@/%40/g')

    echo ""
    log_step "[Buoc 1/11] Kich hoat Module PHP 8.3 goc AppStream CentOS 9 (khong can Remi)..."
    dnf module reset php -y
    dnf module enable php:8.3 -y
    log_success "PHP 8.3 AppStream da duoc kich hoat."

    log_step "[Buoc 2/11] Cai dat Nginx, MariaDB, Postfix, Dovecot va PHP 8.3 extensions..."
    dnf install -y nginx mariadb-server \
        php php-fpm php-mysqlnd php-mbstring php-intl php-xml php-curl php-zip php-gd \
        postfix postfix-mysql dovecot dovecot-mysql \
        tar wget openssl nano s-nail
    log_success "Cai dat cac goi thanh cong."

    log_step "[Buoc 3/11] Thiet lap tai khoan vmail (UID/GID 5000) va tao SSL tu ky..."
    if ! id "vmail" &>/dev/null; then
        groupadd -g 5000 vmail
        useradd -g vmail -u 5000 vmail -d /var/vmail -m -s /sbin/nologin
    fi
    chmod 770 /var/vmail

    local SSL_DIR="/etc/pki/tls/mail"
    mkdir -p "$SSL_DIR"
    openssl req -new -x509 -days 3650 -nodes \
        -out "$SSL_DIR/mail.crt" \
        -keyout "$SSL_DIR/mail.key" \
        -subj "/C=VN/ST=HCM/L=HCM/O=MailServer/CN=$MAIL_FQDN" 2>/dev/null
    chmod 600 "$SSL_DIR/mail.key"
    chmod 644 "$SSL_DIR/mail.crt"
    log_success "Chung chi SSL san sang tai $SSL_DIR."

    log_step "[Buoc 4/11] Khoi dong MariaDB va tao co so du lieu / user..."
    systemctl enable --now mariadb
    mysql -u root << EOF_SQL
CREATE DATABASE IF NOT EXISTS mailserver CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'mailuser'@'127.0.0.1' IDENTIFIED BY '$DB_COMMON_PASS';
ALTER USER 'mailuser'@'127.0.0.1' IDENTIFIED BY '$DB_COMMON_PASS';
GRANT ALL PRIVILEGES ON mailserver.* TO 'mailuser'@'127.0.0.1';

CREATE DATABASE IF NOT EXISTS roundcubemail CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'roundcube'@'localhost' IDENTIFIED BY '$DB_COMMON_PASS';
CREATE USER IF NOT EXISTS 'roundcube'@'127.0.0.1' IDENTIFIED BY '$DB_COMMON_PASS';
ALTER USER 'roundcube'@'localhost' IDENTIFIED BY '$DB_COMMON_PASS';
ALTER USER 'roundcube'@'127.0.0.1' IDENTIFIED BY '$DB_COMMON_PASS';
GRANT ALL PRIVILEGES ON roundcubemail.* TO 'roundcube'@'localhost';
GRANT ALL PRIVILEGES ON roundcubemail.* TO 'roundcube'@'127.0.0.1';

FLUSH PRIVILEGES;
EOF_SQL
    log_success "Co so du lieu MariaDB khoi tao thanh cong."

    log_step "[Buoc 5/11] Cai dat PostfixAdmin 3.3.13..."
    mkdir -p /var/www/html/postfixadmin /tmp/pfa_extract
    local PFA_URL="https://github.com/postfixadmin/postfixadmin/archive/postfixadmin-3.3.13.tar.gz"
    wget -q "$PFA_URL" -O /tmp/pfa.tar.gz
    tar -xzf /tmp/pfa.tar.gz -C /tmp/pfa_extract
    cp -rf /tmp/pfa_extract/*/* /var/www/html/postfixadmin/
    rm -rf /tmp/pfa_extract /tmp/pfa.tar.gz
    mkdir -p /var/www/html/postfixadmin/templates_c

    cat << 'EOF_PFA' > /var/www/html/postfixadmin/config.local.php
<?php
$CONF['configured'] = true;
$CONF['setup_password'] = '__SETUP_PASS__';
$CONF['database_type'] = 'mysqli';
$CONF['database_host'] = '127.0.0.1';
$CONF['database_user'] = 'mailuser';
$CONF['database_password'] = '__DB_PASS__';
$CONF['database_name'] = 'mailserver';
$CONF['admin_email'] = '__ADMIN_EMAIL__';
$CONF['encrypt'] = 'php_crypt:BLOWFISH';
$CONF['default_aliases'] = array();
$CONF['domain_path'] = 'YES';
$CONF['domain_in_mailbox'] = 'NO';
EOF_PFA
    sed -i "s/__SETUP_PASS__/$DB_COMMON_PASS/g" /var/www/html/postfixadmin/config.local.php
    sed -i "s/__DB_PASS__/$DB_COMMON_PASS/g" /var/www/html/postfixadmin/config.local.php
    sed -i "s/__ADMIN_EMAIL__/$ADMIN_EMAIL/g" /var/www/html/postfixadmin/config.local.php
    log_success "PostfixAdmin 3.3.13 da duoc giai nen va cau hinh."

    log_step "[Buoc 6/11] Cau hinh Postfix Virtual Mailbox voi MariaDB..."
    mkdir -p /etc/postfix/sql

    cat << EOF_SQL_DOMAINS > /etc/postfix/sql/mysql_virtual_domains.cf
user = mailuser
password = $DB_COMMON_PASS
hosts = 127.0.0.1
dbname = mailserver
query = SELECT domain FROM domain WHERE domain='%s' AND active = 1
EOF_SQL_DOMAINS

    cat << EOF_SQL_MAILBOXES > /etc/postfix/sql/mysql_virtual_mailboxes.cf
user = mailuser
password = $DB_COMMON_PASS
hosts = 127.0.0.1
dbname = mailserver
query = SELECT maildir FROM mailbox WHERE username='%s' AND active = 1
EOF_SQL_MAILBOXES

    cat << EOF_SQL_ALIASES > /etc/postfix/sql/mysql_virtual_aliases.cf
user = mailuser
password = $DB_COMMON_PASS
hosts = 127.0.0.1
dbname = mailserver
query = SELECT goto FROM alias WHERE address='%s' AND active = 1
EOF_SQL_ALIASES

    chmod 640 /etc/postfix/sql/*
    chown root:postfix /etc/postfix/sql/*

    postconf -e "myhostname = $MAIL_FQDN"
    postconf -e "mydomain = $DOMAIN"
    postconf -e "myorigin = \$mydomain"
    postconf -e "inet_interfaces = all"
    postconf -e "inet_protocols = ipv4"
    postconf -e "mydestination = \$myhostname, localhost.\$mydomain, localhost"
    postconf -e "mynetworks = 127.0.0.0/8, $TRUSTED_NET"
    postconf -e "virtual_mailbox_domains = mysql:/etc/postfix/sql/mysql_virtual_domains.cf"
    postconf -e "virtual_mailbox_maps = mysql:/etc/postfix/sql/mysql_virtual_mailboxes.cf"
    postconf -e "virtual_alias_maps = mysql:/etc/postfix/sql/mysql_virtual_aliases.cf"
    postconf -e "virtual_mailbox_base = /var/vmail"
    postconf -e "virtual_minimum_uid = 5000"
    postconf -e "virtual_uid_maps = static:5000"
    postconf -e "virtual_gid_maps = static:5000"
    postconf -e "smtpd_sasl_type = dovecot"
    postconf -e "smtpd_sasl_path = private/auth"
    postconf -e "smtpd_sasl_auth_enable = yes"
    postconf -e "smtpd_sasl_security_options = noanonymous"
    postconf -e "smtpd_recipient_restrictions = permit_sasl_authenticated, permit_mynetworks, reject_unauth_destination"
    postconf -e "smtpd_tls_auth_only = no"
    postconf -e "smtpd_tls_cert_file = $SSL_DIR/mail.crt"
    postconf -e "smtpd_tls_key_file = $SSL_DIR/mail.key"
    postconf -e "smtpd_tls_security_level = may"

    sed -i 's/^#\?submission inet n       -       n       -       -       smtpd/submission inet n       -       n       -       -       smtpd/' /etc/postfix/master.cf
    sed -i '/^submission inet/,/^[^ ]/ s/^#\?  -o syslog_name=postfix\/submission/  -o syslog_name=postfix\/submission/' /etc/postfix/master.cf
    sed -i '/^submission inet/,/^[^ ]/ s/^#\?  -o smtpd_sasl_auth_enable=yes/  -o smtpd_sasl_auth_enable=yes/' /etc/postfix/master.cf
    sed -i '/^submission inet/,/^[^ ]/ s/^#\?  -o smtpd_reject_unlisted_recipient=no/  -o smtpd_reject_unlisted_recipient=no/' /etc/postfix/master.cf
    sed -i '/^submission inet/,/^[^ ]/ s/^#\?  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject/  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject/' /etc/postfix/master.cf
    log_success "Cau hinh Postfix Virtual Mailbox hoan tat."

    log_step "[Buoc 7/11] Cau hinh Dovecot Virtual Mailbox..."
    cat << EOF_DOVECOT_SQL > /etc/dovecot/dovecot-sql.conf.ext
driver = mysql
connect = host=127.0.0.1 dbname=mailserver user=mailuser password=$DB_COMMON_PASS
default_pass_scheme = BLF-CRYPT
password_query = SELECT username AS user, password FROM mailbox WHERE username = '%u' AND active = 1
user_query = SELECT CONCAT('/var/vmail/', maildir) AS home, 5000 AS uid, 5000 AS gid FROM mailbox WHERE username = '%u' AND active = 1
iterate_query = SELECT username AS user FROM mailbox WHERE active = 1
EOF_DOVECOT_SQL
    chmod 600 /etc/dovecot/dovecot-sql.conf.ext

    sed -i 's/^#\?protocols =.*/protocols = imap pop3 lmtp/' /etc/dovecot/dovecot.conf
    sed -i 's/^#\?listen =.*/listen = *, ::/' /etc/dovecot/dovecot.conf

    sed -i 's|^#\?mail_location =.*|mail_location = maildir:/var/vmail/%d/%n|' /etc/dovecot/conf.d/10-mail.conf
    sed -i 's/^#\?first_valid_uid =.*/first_valid_uid = 5000/' /etc/dovecot/conf.d/10-mail.conf

    sed -i 's/^!include auth-system.conf.ext/#!include auth-system.conf.ext/' /etc/dovecot/conf.d/10-auth.conf
    sed -i 's/^#!include auth-sql.conf.ext/!include auth-sql.conf.ext/' /etc/dovecot/conf.d/10-auth.conf
    sed -i 's/^#\?disable_plaintext_auth =.*/disable_plaintext_auth = no/' /etc/dovecot/conf.d/10-auth.conf
    sed -i 's/^#\?auth_mechanisms =.*/auth_mechanisms = plain login/' /etc/dovecot/conf.d/10-auth.conf

    sed -i 's/^#\?ssl =.*/ssl = yes/' /etc/dovecot/conf.d/10-ssl.conf
    sed -i "s|^#\?ssl_cert =.*|ssl_cert = <$SSL_DIR/mail.crt|" /etc/dovecot/conf.d/10-ssl.conf
    sed -i "s|^#\?ssl_key =.*|ssl_key = <$SSL_DIR/mail.key|" /etc/dovecot/conf.d/10-ssl.conf

    cat << 'EOF_DOVECOT_MASTER' > /etc/dovecot/conf.d/10-master.conf
service imap-login {
  inet_listener imap {
    port = 143
  }
  inet_listener imaps {
    port = 993
    ssl = yes
  }
}

service pop3-login {
  inet_listener pop3 {
    port = 110
  }
  inet_listener pop3s {
    port = 995
    ssl = yes
  }
}

service lmtp {
}

service imap {
}

service pop3 {
}

service auth {
  unix_listener auth-userdb {
  }

  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
}

service auth-worker {
}

service dict {
}
EOF_DOVECOT_MASTER
    log_success "Cau hinh Dovecot Virtual Mailbox hoan tat."

    log_step "[Buoc 8/11] Cai dat Roundcube Webmail 1.6.9..."
    mkdir -p /var/www/html/roundcube /tmp/rc_extract
    local RC_URL="https://github.com/roundcube/roundcubemail/releases/download/1.6.9/roundcubemail-1.6.9-complete.tar.gz"
    wget -q "$RC_URL" -O /tmp/rc.tar.gz
    tar -xzf /tmp/rc.tar.gz -C /tmp/rc_extract
    cp -rf /tmp/rc_extract/*/* /var/www/html/roundcube/
    rm -rf /tmp/rc_extract /tmp/rc.tar.gz
    mysql -u root roundcubemail < /var/www/html/roundcube/SQL/mysql.initial.sql

    cat << 'EOF_RC' > /var/www/html/roundcube/config/config.inc.php
<?php
$config = [];
$config['db_dsnw'] = 'mysql://roundcube:__DB_PASS_URL__@127.0.0.1/roundcubemail';
$config['default_host'] = '127.0.0.1';
$config['default_port'] = 143;
$config['smtp_server'] = '127.0.0.1';
$config['smtp_port'] = 587;
$config['smtp_user'] = '%u';
$config['smtp_pass'] = '%p';
$config['smtp_auth_type'] = 'LOGIN';
$config['smtp_conn_options'] = [
    'ssl' => [
        'verify_peer' => false,
        'verify_peer_name' => false,
        'allow_self_signed' => true
    ]
];
$config['des_key'] = 'rcmail-nhom5-local-secret-token_2026!';
$config['plugins'] = ['archive', 'zipdownload'];
$config['skin'] = 'elastic';
EOF_RC
    sed -i "s/__DB_PASS_URL__/$DB_COMMON_PASS_URL/g" /var/www/html/roundcube/config/config.inc.php
    log_success "Roundcube Webmail 1.6.9 da duoc nap co so du lieu va cau hinh."

    log_step "[Buoc 9/11] Cau hinh Nginx va socket PHP-FPM..."
    sed -i 's/^user = .*/user = nginx/' /etc/php-fpm.d/www.conf
    sed -i 's/^group = .*/group = nginx/' /etc/php-fpm.d/www.conf
    sed -i 's/^listen.acl_users/;&/' /etc/php-fpm.d/www.conf
    sed -i 's/^listen.acl_groups/;&/' /etc/php-fpm.d/www.conf
    sed -i 's/^;*listen.owner = .*/listen.owner = nginx/' /etc/php-fpm.d/www.conf
    sed -i 's/^;*listen.group = .*/listen.group = nginx/' /etc/php-fpm.d/www.conf
    sed -i 's/^;*listen.mode = .*/listen.mode = 0660/' /etc/php-fpm.d/www.conf

    chown -R nginx:nginx /var/www/html/roundcube /var/www/html/postfixadmin
    chown -R nginx:nginx /var/lib/php/session 2>/dev/null || true
    chmod -R 775 /var/www/html/roundcube/temp /var/www/html/roundcube/logs /var/www/html/postfixadmin/templates_c

    cat << 'EOF_NGINX_MAIL' > /etc/nginx/conf.d/mail.conf
server {
    listen 80;
    server_name __MAIL_FQDN__;

    root /var/www/html/roundcube;
    index index.php index.html;

    client_max_body_size 25M;

    location ~ ^/(config|temp|logs)/ {
        deny all;
    }

    location ~ /\. {
        deny all;
    }

    location ^~ /postfixadmin {
        alias /var/www/html/postfixadmin/public;
        index index.php index.html;
        try_files $uri $uri/ /postfixadmin/index.php?$args;

        location ~ \.php$ {
            include fastcgi_params;
            fastcgi_pass unix:/run/php-fpm/www.sock;
            fastcgi_index index.php;
            fastcgi_param SCRIPT_FILENAME $request_filename;
        }
    }

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass unix:/run/php-fpm/www.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    }

    location / {
        try_files $uri $uri/ /index.php?$args;
    }
}
EOF_NGINX_MAIL
    sed -i "s/__MAIL_FQDN__/$MAIL_FQDN/g" /etc/nginx/conf.d/mail.conf

    log_step "[Buoc 10/11] Kiem tra cu phap cac dich vu..."
    doveconf -n >/dev/null && log_success "Dovecot: [OK]" || { log_error "Dovecot syntax error"; return 1; }
    postfix check && log_success "Postfix: [OK]" || { log_error "Postfix syntax error"; return 1; }
    nginx -t >/dev/null 2>&1 && log_success "Nginx: [OK]" || { log_error "Nginx syntax error"; return 1; }

    log_step "[Buoc 11/11] Mo port Firewalld tren ca 2 zone va khoi chay he thong..."
    if systemctl is-active --quiet firewalld; then
        for z in internal public; do
            firewall-cmd --zone=$z --permanent --add-port={80,443,25,587,143,993,110,995}/tcp
        done
        firewall-cmd --reload
        log_success "Da mo cac port HTTP (80), HTTPS (443) va Mail Ports."
    fi

    systemctl enable --now mariadb php-fpm nginx postfix dovecot
    systemctl restart mariadb php-fpm nginx postfix dovecot

    # Dong bo ban ghi DNS
    add_dns_mail_records "$DOMAIN" "$MAIL_FQDN" "$TOPOLOGY_LAN_IP"

    echo ""
    echo -e "${GREEN}====================================================================${NC}"
    echo -e "${GREEN}       DA HOAN TAT TRIEN KHAI VIRTUAL MAIL SERVER & WEBMAIL!        ${NC}"
    echo -e "${GREEN}====================================================================${NC}"
    systemctl is-active --quiet postfix && echo -e "  - Postfix:   ${GREEN}RUNNING${NC}" || echo -e "  - Postfix:   ${RED}STOPPED${NC}"
    systemctl is-active --quiet dovecot && echo -e "  - Dovecot:   ${GREEN}RUNNING${NC}" || echo -e "  - Dovecot:   ${RED}STOPPED${NC}"
    systemctl is-active --quiet nginx   && echo -e "  - Nginx:     ${GREEN}RUNNING${NC}" || echo -e "  - Nginx:     ${RED}STOPPED${NC}"
    systemctl is-active --quiet php-fpm && echo -e "  - PHP-FPM:   ${GREEN}RUNNING (PHP 8.3 AppStream)${NC}" || echo -e "  - PHP-FPM:   ${RED}STOPPED${NC}"
    systemctl is-active --quiet mariadb && echo -e "  - MariaDB:   ${GREEN}RUNNING${NC}" || echo -e "  - MariaDB:   ${RED}STOPPED${NC}"
    echo "--------------------------------------------------------------------"
    echo -e "1. Quan tri PostfixAdmin:"
    echo -e "   - Setup ban dau:   ${CYAN}http://$MAIL_FQDN/postfixadmin/setup.php${NC}"
    echo -e "   - Trang dang nhap: ${CYAN}http://$MAIL_FQDN/postfixadmin/${NC}"
    echo -e "2. Giao dien Webmail Roundcube:"
    echo -e "   - Truy cap ngay:   ${CYAN}http://$MAIL_FQDN/${NC}"
    echo -e "${GREEN}====================================================================${NC}"
}

# ==============================================================================
# MENU CHINH
# ==============================================================================
while true; do
    echo ""
    echo -e "${CYAN}================================================================${NC}"
    echo -e "${CYAN}        MENU QUAN TRI HE THONG MANG - CENTOS STREAM 9           ${NC}"
    echo -e "${CYAN}================================================================${NC}"
    echo -e "  ${YELLOW}1)${NC} Tat SELinux vinh vien"
    echo -e "  ${YELLOW}2)${NC} Cau hinh IP tinh (NetworkManager & Firewalld Zone)"
    echo -e "  ${YELLOW}3)${NC} Cau hinh NAT (Router / Gateway - lan-to-wan)"
    echo -e "  ${YELLOW}4)${NC} Cau hinh DNS (BIND9 Server - Tao san Zone nghich & PTR)"
    echo -e "  ${YELLOW}5)${NC} Cau hinh DHCP (ISC DHCP Server)"
    echo -e "  ${YELLOW}6)${NC} Cau hinh FTP (vsftpd Server)"
    echo -e "  ${YELLOW}7)${NC} Cau hinh Web Server (Nginx & OpenSSL)"
    echo -e "  ${YELLOW}8)${NC} Cau hinh NFS (Server / Client)"
    echo -e "  ${YELLOW}9)${NC} Cau hinh Samba (Samba File Sharing)"
    echo -e "  ${YELLOW}10)${NC} Cau hinh Samba Active Directory (AD DC - Tu dong tao PTR)"
    echo -e "  ${YELLOW}11)${NC} Xoa bo Samba Active Directory (Go bo AD DC)"
    echo -e "  ${YELLOW}12)${NC} Cau hinh Mail Server Local User (Postfix + Dovecot)"
    echo -e "  ${YELLOW}13)${NC} Cau hinh Enterprise Webmail (PHP 8.3 AppStream + Roundcube)"
    echo -e "  ${YELLOW}0)${NC} Thoat"
    echo -e "${CYAN}----------------------------------------------------------------${NC}"
    read -rp "Nhap lua chon cua ban [0-13]: " MAIN_CHOICE

    case "$MAIN_CHOICE" in
        1) module_disable_selinux; pause_menu ;;
        2) module_setup_ip; pause_menu ;;
        3) module_setup_nat; pause_menu ;;
        4) module_setup_dns; pause_menu ;;
        5) module_setup_dhcp; pause_menu ;;
        6) module_setup_ftp; pause_menu ;;
        7) module_setup_web; pause_menu ;;
        8) module_setup_nfs ;;
        9) module_setup_samba; pause_menu ;;
        10) module_setup_samba_ad; pause_menu ;;
        11) module_remove_samba_ad; pause_menu ;;
        12) module_setup_mail_basic; pause_menu ;;
        13) module_setup_webmail_enterprise; pause_menu ;;
        0) echo -e "${GREEN}Tam biet!${NC}"; exit 0 ;;
        *) log_error "Lua chon khong hop le." ;;
    esac
done