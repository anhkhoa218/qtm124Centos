#!/usr/bin/env bash
# ==============================================================================
#   1. Tat SELinux vinh vien
#   2. Cau hinh IP tinh (NetworkManager & Firewalld Zone)
#   3. Cau hinh NAT Gateway (Masquerade & Policy lan-to-wan)
#   4. Cau hinh DNS Server (BIND9)
#   5. Cau hinh DHCP Server (ISC DHCP)
#   6. Cau hinh FTP Server (vsftpd)
#   7. Cau hinh Web Server (Nginx & OpenSSL SSL)
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Kiem tra quyen root chung cho toan bo script
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[!] Loi: Script bat buoc phai chay voi quyen root (sudo $0).${NC}"
    exit 1
fi

pause_menu() {
    echo ""
    read -rp "Nhan [Enter] de quay lai Menu chinh..."
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
    echo -e "[*] Trang thai SELinux hien tai: ${YELLOW}${current_selinux}${NC}"

    if [[ "$current_selinux" == "Enforcing" ]]; then
        echo -e "${YELLOW}[*] SELinux dang Enforcing. Dang chay setenforce 0...${NC}"
        setenforce 0
    elif [[ "$current_selinux" == "Permissive" ]]; then
        echo -e "${GREEN}[✓] SELinux hien da o che do Permissive (tam tat).${NC}"
    elif [[ "$current_selinux" == "Disabled" ]]; then
        echo -e "${GREEN}[✓] SELinux da duoc tat hoan toan (Disabled).${NC}"
    fi

    if [[ -f /etc/selinux/config ]]; then
        sed -i 's/^SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
        sed -i 's/^SELINUX=permissive/SELINUX=disabled/' /etc/selinux/config
        echo -e "${GREEN}[✓] Da cap nhat SELINUX=disabled trong /etc/selinux/config.${NC}"
        echo -e "[*] Noi dung cau hinh hien tai:"
        grep -E '^SELINUX=' /etc/selinux/config
    else
        echo -e "${RED}[!] Khong tim thay file /etc/selinux/config!${NC}"
    fi

    echo -e "${CYAN}[i] Luu y: Trang thai hien tai la $(getenforce). Khoi dong lai may (reboot) de SELinux chuyen han sang Disabled.${NC}"
}

# ==============================================================================
# 2. CAU HINH IP TINH
# ==============================================================================
module_setup_ip() {
    echo ""
    echo "======================================================================"
    echo "               DANH SACH CARD MANG DANG CO TREN HE THONG              "
    echo "======================================================================"
    printf "%-12s %-20s %-18s %-20s\n" "Interface" "IPv4 Address" "Gateway" "DNS"
    echo "----------------------------------------------------------------------"

    mapfile -t DEVICES < <(nmcli -t -f DEVICE,TYPE device status | grep -E ':(ethernet|wifi)$' | cut -d: -f1)
    local TOTAL_DEV=${#DEVICES[@]}

    if [[ $TOTAL_DEV -eq 0 ]]; then
        echo -e "${RED}[-] Loi: Khong tim thay card mang vat ly nao tren he thong!${NC}"
        return 1
    fi

    for dev in "${DEVICES[@]}"; do
        local ip_addr gw dns
        ip_addr=$(nmcli -g IP4.ADDRESS device show "$dev" 2>/dev/null | head -n1)
        gw=$(nmcli -g IP4.GATEWAY device show "$dev" 2>/dev/null)
        dns=$(nmcli -g IP4.DNS device show "$dev" 2>/dev/null | tr '\n' ' ')
        
        printf "%-12s %-20s %-18s %-20s\n" \
            "$dev" \
            "${ip_addr:-Chua co}" \
            "${gw:-Chua co}" \
            "${dns:-Chua co}"
    done
    echo "======================================================================"

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
            echo "[!] Ten card '$selected' khong hop le. Vui long nhap dung ten tu danh sach tren." >&2
        done
    }

    thu_thap_thong_so() {
        local iface="$1"
        local role_label="$2"
        local mode ip gw dns

        echo ""
        echo "--- Thiet lap cho $role_label ($iface) ---"
        echo "  1) DHCP (Nhan IP tu dong)"
        echo "  2) IP Tinh (Static IP)"
        read -rp "Chon che do (1/2): " mode

        if [[ "$mode" == "1" ]]; then
            CFG_MODE["$iface"]="dhcp"
        else
            CFG_MODE["$iface"]="static"
            read -rp "  > IP/Subnet (VD: 192.168.1.10/24): " ip
            read -rp "  > Gateway (Nhan Enter neu khong can GW): " gw
            read -rp "  > DNS (Cac IP cach nhau bang khoang trang, Enter de bo qua): " dns
            
            CFG_IP["$iface"]="$ip"
            CFG_GW["$iface"]="$gw"
            CFG_DNS["$iface"]="$dns"
        fi
    }

    local SINGLE_IFACE EXT_IFACE INT_IFACE

    if [[ $TOTAL_DEV -eq 1 ]]; then
        SINGLE_IFACE="${DEVICES[0]}"
        echo ""
        echo "[i] Phat hien he thong chi co 1 card mang ($SINGLE_IFACE)."
        echo "[i] Bo qua phan chia External/Internal -> Card se duoc gan vao Zone 'public'."
        thu_thap_thong_so "$SINGLE_IFACE" "CARD MANG"
    else
        echo ""
        echo "[*] BUOC 1: CHON CARD MANG"
        EXT_IFACE=$(chon_card "Nhap ten card EXTERNAL (Noi Internet)")

        while true; do
            INT_IFACE=$(chon_card "Nhap ten card INTERNAL (Mang noi bo LAN)")
            if [[ "$INT_IFACE" != "$EXT_IFACE" ]]; then
                break
            fi
            echo "[!] Card Internal khong duoc trung voi External ($EXT_IFACE)."
        done

        thu_thap_thong_so "$EXT_IFACE" "EXTERNAL"
        thu_thap_thong_so "$INT_IFACE" "INTERNAL"
    fi

    echo ""
    echo "[*] BUOC 2: XOA TOAN BO CONNECTION PROFILE CU..."
    mapfile -t ALL_UUIDS < <(nmcli -t -f UUID connection show)
    for uuid in "${ALL_UUIDS[@]}"; do
        if [[ -n "$uuid" ]]; then
            nmcli connection delete uuid "$uuid" >/dev/null 2>&1 || true
        fi
    done
    echo "[+] Da don sach cac profile cu."

    tao_connection() {
        local iface="$1"
        local zone="$2"

        echo "[*] Dang tao profile '$iface' cho card $iface (Zone: $zone)..."

        if [[ "${CFG_MODE[$iface]}" == "dhcp" ]]; then
            nmcli connection add type ethernet con-name "$iface" ifname "$iface" \
                ipv4.method auto connection.zone "$zone" connection.autoconnect yes >/dev/null
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

            nmcli connection add "${args[@]}" >/dev/null
        fi

        nmcli connection up "$iface" >/dev/null
        echo "[+] Da khoi dong profile '$iface' thanh cong."
    }

    echo ""
    echo "[*] BUOC 3: TAO PROFILE VA DONG BO FIREWALL..."

    if ! systemctl is-active --quiet firewalld; then
        systemctl enable --now firewalld >/dev/null 2>&1
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

    firewall-cmd --reload >/dev/null
    echo "[+] Dong bo Firewalld hoan tat."

    echo ""
    echo "======================================================================"
    echo "                   KET QUA CAU HINH HOAN TAT                          "
    echo "======================================================================"
    echo "[*] Danh sach Connection (NAME trung DEVICE):"
    nmcli connection show
    echo ""
    echo "[*] Thong so IP hien tai:"
    ip -br addr show
    echo ""
    echo "[*] Zone dang active tren Firewalld:"
    firewall-cmd --get-active-zones
    echo "======================================================================"
}

# ==============================================================================
# 3. CAU HINH NAT GATEWAY
# ==============================================================================
module_setup_nat() {
    echo ""
    echo -e "${BLUE}=====================================================${NC}"
    echo -e "${BLUE}  KIEM TRA VA CAU HINH NAT GATEWAY (CENTOS STREAM 9)  ${NC}"
    echo -e "${BLUE}=====================================================${NC}"

    systemctl is-active --quiet firewalld || {
        echo -e "${YELLOW}[CANH BAO] firewalld chua chay. Dang khoi dong firewalld...${NC}"
        systemctl enable --now firewalld
    }

    mapfile -t AVAIL_IFACES < <(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="ethernet" {print $1}')
    local IFACE_COUNT=${#AVAIL_IFACES[@]}

    echo -e "\n${BLUE}[1/5] Kiem tra so luong card mang...${NC}"
    echo "Danh sach card mang Ethernet tim thay: ${AVAIL_IFACES[*]} (Tong: ${IFACE_COUNT})"

    if [[ $IFACE_COUNT -lt 2 ]]; then
        echo -e "${RED}[LOI] May chu chi co ${IFACE_COUNT} card mang. Can toi thieu 2 card mang de lam gateway/NAT.${NC}"
        return 1
    fi
    echo -e "${GREEN}✓ Dat dieu kien so luong card mang (>= 2).${NC}"

    echo -e "\n${BLUE}[2/5] Kiem tra zone 'external' va 'internal'...${NC}"
    local EXT_IF INT_IF
    EXT_IF=$(firewall-cmd --zone=external --list-interfaces 2>/dev/null | awk '{print $1}')
    INT_IF=$(firewall-cmd --zone=internal --list-interfaces 2>/dev/null | awk '{print $1}')

    if [[ -z "$EXT_IF" || -z "$INT_IF" ]]; then
        echo -e "${YELLOW}[!] Chua gan day du card mang vao zone external va internal.${NC}"
        echo "Cac card mang kha dung: ${AVAIL_IFACES[*]}"
        
        if [[ -z "$EXT_IF" ]]; then
            read -rp "Nhap ten card mang ra Internet (external, vi du: ${AVAIL_IFACES[0]}): " EXT_IF
            firewall-cmd --zone=external --add-interface="$EXT_IF" --permanent
        fi
        
        if [[ -z "$INT_IF" ]]; then
            read -rp "Nhap ten card mang noi bo LAN (internal, vi du: ${AVAIL_IFACES[1]}): " INT_IF
            firewall-cmd --zone=internal --add-interface="$INT_IF" --permanent
        fi
        firewall-cmd --reload
    fi

    echo -e "Card External: ${GREEN}${EXT_IF}${NC}"
    echo -e "Card Internal: ${GREEN}${INT_IF}${NC}"

    if [[ "$EXT_IF" == "$INT_IF" ]]; then
        echo -e "${RED}[LOI] Card External va Internal khong duoc phep trung nhau!${NC}"
        return 1
    fi

    echo -e "\n${BLUE}[3/5] Kiem tra cau hinh dia chi IP...${NC}"
    local EXT_IP INT_IP
    EXT_IP=$(ip -4 addr show dev "$EXT_IF" 2>/dev/null | awk '/inet / {print $2}' | head -n1)
    INT_IP=$(ip -4 addr show dev "$INT_IF" 2>/dev/null | awk '/inet / {print $2}' | head -n1)

    if [[ -z "$EXT_IP" ]]; then
        echo -e "${RED}[LOI] Card ${EXT_IF} (external) chua duoc dat IP. Vui long cau hinh IP truoc.${NC}"
        return 1
    fi

    if [[ -z "$INT_IP" ]]; then
        echo -e "${RED}[LOI] Card ${INT_IF} (internal) chua duoc dat IP. Vui long cau hinh IP truoc.${NC}"
        return 1
    fi

    echo -e "IP External (${EXT_IF}): ${GREEN}${EXT_IP}${NC}"
    echo -e "IP Internal (${INT_IF}): ${GREEN}${INT_IP}${NC}"
    echo -e "${GREEN}✓ Ca 2 card mang da co day du IPv4.${NC}"

    echo -e "\n${BLUE}[4/5] Cau hinh nmcli 'never-default' cho ket noi Internal...${NC}"
    local INT_CONN
    INT_CONN=$(nmcli -t -f NAME,DEVICE connection show --active | awk -F: -v dev="$INT_IF" '$2==dev {print $1}' | head -n1)

    if [[ -z "$INT_CONN" ]]; then
        INT_CONN=$(nmcli -t -f NAME,DEVICE connection show | awk -F: -v dev="$INT_IF" '$2==dev {print $1}' | head -n1)
    fi

    if [[ -n "$INT_CONN" ]]; then
        echo "Thiet lap ipv4.never-default=yes cho connection '${INT_CONN}'..."
        nmcli connection modify "$INT_CONN" ipv4.never-default yes
        nmcli connection up "$INT_CONN" >/dev/null 2>&1 || true
        echo -e "${GREEN}✓ Da bat 'ipv4.never-default yes' cho ${INT_CONN}.${NC}"
    else
        echo -e "${YELLOW}[CANH BAO] Khong tim thay connection profile cua ${INT_IF}. Bo qua buoc nay.${NC}"
    fi

    echo -e "\n${BLUE}[5/5] Cau hinh IP Forwarding, Masquerade va Policy lan-to-wan...${NC}"

    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-ipforward.conf
    sysctl -p /etc/sysctl.d/99-ipforward.conf >/dev/null
    echo -e "${GREEN}✓ Da kich hoat net.ipv4.ip_forward = 1.${NC}"

    firewall-cmd --zone=external --add-masquerade --permanent >/dev/null

    local POLICY_NAME="lan-to-wan"
    local POLICIES
    POLICIES=$(firewall-cmd --get-policies)

    if ! echo "$POLICIES" | grep -qw "$POLICY_NAME"; then
        echo "Tao policy moi: ${POLICY_NAME}..."
        firewall-cmd --permanent --new-policy "$POLICY_NAME" >/dev/null
    fi

    firewall-cmd --permanent --policy "$POLICY_NAME" --add-ingress-zone internal >/dev/null 2>&1 || true
    firewall-cmd --permanent --policy "$POLICY_NAME" --add-egress-zone external >/dev/null 2>&1 || true
    firewall-cmd --permanent --policy "$POLICY_NAME" --set-target ACCEPT >/dev/null

    firewall-cmd --reload >/dev/null

    echo -e "\n${GREEN}=====================================================${NC}"
    echo -e "${GREEN}             HOAN TAT CAU HINH THANH CONG!            ${NC}"
    echo -e "${GREEN}=====================================================${NC}"

    echo -e "\n${BLUE}--- KIEM TRA TRANG THAI ---${NC}"
    echo -e "1. Kernel Forwarding: $(sysctl -n net.ipv4.ip_forward)"
    echo -e "2. Masquerade External: $(firewall-cmd --zone=external --query-masquerade)"
    echo -e "3. Policy Target (${POLICY_NAME}): $(firewall-cmd --permanent --policy=${POLICY_NAME} --get-target 2>/dev/null || echo 'Chua nhan')"
    echo -e "4. Policy Active (${POLICY_NAME}): $(firewall-cmd --get-active-policies | grep -qw "$POLICY_NAME" && echo 'Dang hoat dong' || echo 'Chua active')"
    echo -e "5. Default Route may chu: $(ip route | grep default | head -n1)"
}

# ==============================================================================
# 4. CAU HINH DNS SERVER (BIND)
# ==============================================================================
module_setup_dns() {
    echo ""
    echo "======================================================"
    echo " KIEM TRA VA CAI DAT BIND DNS TREN CENTOS STREAM 9"
    echo "======================================================"

    local PACKAGES=("bind" "bind-utils")
    local TO_INSTALL=()

    for pkg in "${PACKAGES[@]}"; do
        if ! rpm -q "$pkg" >/dev/null 2>&1; then
            TO_INSTALL+=("$pkg")
        fi
    done

    if [ ${#TO_INSTALL[@]} -gt 0 ]; then
        echo "[*] Cac goi chua cai dat: ${TO_INSTALL[*]}"
        echo "[*] Dang tien hanh cai dat qua dnf..."
        dnf install -y "${TO_INSTALL[@]}"
        echo "[+] Da cai dat xong goi BIND."
    else
        echo "[+] He thong da co san bind va bind-utils."
    fi

    detect_network_class() {
        local ip="$1"
        local o1 o2 o3 o4
        IFS='.' read -r o1 o2 o3 o4 <<< "$ip"

        if (( o1 >= 1 && o1 <= 126 )); then
            DETECTED_CLASS="A"
            CALC_REV_ZONE="${o1}.in-addr.arpa"
            CALC_PTR_PREFIX="${o4}.${o3}.${o2}"
        elif (( o1 >= 128 && o1 <= 191 )); then
            DETECTED_CLASS="B"
            CALC_REV_ZONE="${o2}.${o1}.in-addr.arpa"
            CALC_PTR_PREFIX="${o4}.${o3}"
        elif (( o1 >= 192 && o1 <= 223 )); then
            DETECTED_CLASS="C"
            CALC_REV_ZONE="${o3}.${o2}.${o1}.in-addr.arpa"
            CALC_PTR_PREFIX="${o4}"
        else
            DETECTED_CLASS="Custom"
            CALC_REV_ZONE="${o3}.${o2}.${o1}.in-addr.arpa"
            CALC_PTR_PREFIX="${o4}"
        fi
    }

    local SERIAL_DATE
    SERIAL_DATE="$(date +%Y%m%d)01"
    local ACTION_MODE="NEW"
    local HAS_ZONES=false
    local HAS_BACKUP=false

    if [ -f /etc/named.conf ] && grep -q 'type master;' /etc/named.conf 2>/dev/null; then
        HAS_ZONES=true
    fi

    if [ -f /etc/named.conf.bak ]; then
        HAS_BACKUP=true
    fi

    if [ "$HAS_ZONES" = true ] || [ "$HAS_BACKUP" = true ]; then
        echo ""
        echo "======================================================"
        echo " MENU LUA CHON CHE DO HOAT DONG"
        echo "======================================================"
        echo "  1) Them cap Zone moi (Thuan & Nghich) vao named.conf hien tai"
        echo "  2) Ghi de va cau hinh lai toan bo tu dau"
        echo "  3) Khoi phuc (Restore) file cau hinh goc tu /etc/named.conf.bak"
        read -rp ">> Chon thao tac (1, 2 hoac 3, mac dinh 1): " MODE_CHOICE
        MODE_CHOICE=${MODE_CHOICE:-1}

        case "$MODE_CHOICE" in
            1) ACTION_MODE="APPEND" ;;
            2) ACTION_MODE="NEW" ;;
            3) ACTION_MODE="RESTORE" ;;
            *) ACTION_MODE="APPEND" ;;
        esac
    fi

    # CHE DO 3: KHOI PHUC (RESTORE) TU FILE BACKUP
    if [[ "$ACTION_MODE" == "RESTORE" ]]; then
        echo ""
        echo "======================================================"
        echo " TIEN TRINH KHOI PHUC NAMED.CONF TU BAN SAO LUU"
        echo "======================================================"

        if [ ! -f /etc/named.conf.bak ]; then
            echo "[!] Loi: Khong tim thay file sao luu /etc/named.conf.bak tren he thong!"
            return 1
        fi

        echo "[*] Dang khoi phuc /etc/named.conf tu /etc/named.conf.bak..."
        cp -pf /etc/named.conf.bak /etc/named.conf

        chown root:named /etc/named.conf
        chmod 640 /etc/named.conf

        if command -v restorecon >/dev/null 2>&1; then
            restorecon -F /etc/named.conf
        fi

        read -rp ">> Ban co muon xoa cac file zone (*.db) trong /var/named/ khong? (y/n, mac dinh: n): " DEL_DB
        DEL_DB=${DEL_DB:-n}
        if [[ "$DEL_DB" =~ ^[yY]$ ]]; then
            find /var/named/ -maxdepth 1 -name "*.db" -type f -exec rm -v {} +
            echo "[+] Da don dep cac file *.db."
        fi

        echo "[*] Dang kiem tra cu phap sau khi restore..."
        named-checkconf /etc/named.conf && echo "[OK] File named.conf sau restore hop le."

        echo "[*] Dang khoi dong lai service named..."
        systemctl restart named

        echo ""
        echo "======================================================"
        echo " [OK] DA KHOI PHUC NAMED.CONF VE TRANG THAI GOC THANH CONG!"
        echo "======================================================"
        return 0
    fi

    # CHE DO 1: THEM CAP ZONE MOI VAO NAMED.CONF HIEN TAI
    if [[ "$ACTION_MODE" == "APPEND" ]]; then
        echo ""
        echo "======================================================"
        echo " THEM CAP ZONE MOI VAO NAMED.CONF HIEN TAI"
        echo "======================================================"

        local NEW_ZONE_FILES=()
        local NEW_ZONE_NAMES=()

        while true; do
            echo ""
            read -rp ">> Nhap ten mien Zone thuan moi (vi du: phu.local): " NEW_FWD_ZONE
            while [[ -z "$NEW_FWD_ZONE" ]]; do
                read -rp "[!] Ten mien khong duoc de trong: " NEW_FWD_ZONE
            done

            read -rp ">> Nhap IP tuong ung cho Zone moi (vi du: 192.168.20.1): " NEW_IP
            while [[ -z "$NEW_IP" ]]; do
                read -rp "[!] IP khong duoc de trong: " NEW_IP
            done

            detect_network_class "$NEW_IP"
            echo "[*] Nhan dien Lop ${DETECTED_CLASS}. Zone nghich goi y: ${CALC_REV_ZONE}"
            echo "[*] PTR prefix goi y: ${CALC_PTR_PREFIX}"
            read -rp ">> Nhan Enter de dung gia tri tren, hoac nhap zone nghich khac: " NEW_REV_ZONE_INPUT
            local NEW_REV_ZONE=${NEW_REV_ZONE_INPUT:-$CALC_REV_ZONE}

            local NEW_FWD_FILE="/var/named/${NEW_FWD_ZONE}.db"
            cat <<EOF > "$NEW_FWD_FILE"
\$TTL 1D
@       IN SOA  ns1.${NEW_FWD_ZONE}. admin.${NEW_FWD_ZONE}. (
                                        ${SERIAL_DATE} ; Serial
                                        1D         ; Refresh
                                        1H         ; Retry
                                        1W         ; Expire
                                        3H )       ; Minimum TTL

; Name Server Record
@       IN      NS      ns1.${NEW_FWD_ZONE}.

; A Records
ns1     IN      A       ${NEW_IP}
@       IN      A       ${NEW_IP}
www     IN      A       ${NEW_IP}
EOF

            local NEW_REV_FILE="/var/named/${NEW_REV_ZONE}.db"
            cat <<EOF > "$NEW_REV_FILE"
\$TTL 1D
@       IN SOA  ns1.${NEW_FWD_ZONE}. admin.${NEW_FWD_ZONE}. (
                                        ${SERIAL_DATE} ; Serial
                                        1D         ; Refresh
                                        1H         ; Retry
                                        1W         ; Expire
                                        3H )       ; Minimum TTL

; Name Server Record
@       IN      NS      ns1.${NEW_FWD_ZONE}.

; PTR Records
${CALC_PTR_PREFIX}       IN      PTR     ns1.${NEW_FWD_ZONE}.
${CALC_PTR_PREFIX}       IN      PTR     ${NEW_FWD_ZONE}.
EOF

            local APPEND_BLOCK
            APPEND_BLOCK=$(cat <<EOF

// --- Forward Zone: ${NEW_FWD_ZONE} ---
zone "${NEW_FWD_ZONE}" IN {
    type master;
    file "${NEW_FWD_ZONE}.db";
    allow-update { none; };
};

// --- Reverse Zone: ${NEW_REV_ZONE} ---
zone "${NEW_REV_ZONE}" IN {
    type master;
    file "${NEW_REV_ZONE}.db";
    allow-update { none; };
};
EOF
)

            local TEMP_CONF
            TEMP_CONF=$(mktemp)
            awk -v block="$APPEND_BLOCK" '
                /include "\/etc\/named.rfc1912.zones";/ { print block "\n" }
                { print }
            ' /etc/named.conf > "$TEMP_CONF"
            mv "$TEMP_CONF" /etc/named.conf

            NEW_ZONE_FILES+=("$NEW_FWD_FILE" "$NEW_REV_FILE")
            NEW_ZONE_NAMES+=("$NEW_FWD_ZONE" "$NEW_REV_ZONE")

            echo "[+] Da chen thanh cong cap zone ${NEW_FWD_ZONE} va ${NEW_REV_ZONE} vao named.conf"

            read -rp ">> Ban co muon them tiep cap zone nao nua khong? (y/n, mac dinh: n): " CONTINUE_ADD
            CONTINUE_ADD=${CONTINUE_ADD:-n}
            if [[ ! "$CONTINUE_ADD" =~ ^[yY]$ ]]; then
                break
            fi
        done

        for f in "${NEW_ZONE_FILES[@]}"; do
            chown named:named "$f"
            chmod 640 "$f"
        done
        chown root:named /etc/named.conf
        chmod 640 /etc/named.conf

        if command -v restorecon >/dev/null 2>&1; then
            restorecon -F /etc/named.conf
            restorecon -Rv /var/named/
        fi

        echo ""
        echo "======================================================"
        echo " KIEM TRA CU PHAP ZONE MOI (SYNTAX CHECK)"
        echo "======================================================"
        named-checkconf /etc/named.conf && echo "[OK] /etc/named.conf hop le."
        for i in "${!NEW_ZONE_NAMES[@]}"; do
            named-checkzone "${NEW_ZONE_NAMES[$i]}" "${NEW_ZONE_FILES[$i]}"
        done

        systemctl restart named
        echo ""
        echo "[OK] Da tai lai BIND service voi cac zone moi thanh cong!"
        return 0
    fi

    # CHE DO 2: CAU HINH MOI TOAN BO HE THONG
    echo ""
    echo "======================================================"
    echo " THIET LAP THONG SO NAMED.CONF TU DAU"
    echo "======================================================"

    read -rp ">> Nhap IP lang nghe port 53 ('any' hoac IP cu the, mac dinh: any): " LISTEN_INPUT
    LISTEN_INPUT=${LISTEN_INPUT:-any}
    local LISTEN_VAL
    if [[ "$LISTEN_INPUT" == "any" ]]; then
        LISTEN_VAL="any;"
    else
        LISTEN_VAL="127.0.0.1; ${LISTEN_INPUT};"
    fi

    read -rp ">> Nhap dai mang duoc truy van ('any', 'localhost', hoac subnet vd: 192.168.10.0/24, mac dinh: any): " QUERY_INPUT
    QUERY_INPUT=${QUERY_INPUT:-any}
    local QUERY_VAL
    if [[ "$QUERY_INPUT" == "any" ]]; then
        QUERY_VAL="any;"
    else
        QUERY_VAL="localhost; ${QUERY_INPUT};"
    fi

    read -rp ">> Ban co muon cau hinh forwarder ra 8.8.8.8 khong? (y/n, mac dinh: y): " FWD_CHOICE
    FWD_CHOICE=${FWD_CHOICE:-y}
    local FORWARDER_CONF=""
    if [[ "$FWD_CHOICE" =~ ^[yY]$ ]]; then
        FORWARDER_CONF="    forwarders { 8.8.8.8; };"
        echo "[+] Da bat forwarder ra 8.8.8.8."
    else
        echo "[-] Bo qua forwarder."
    fi

    echo ""
    echo "======================================================"
    echo " THIET LAP CAP ZONE CHINH (THUAN & NGHICH)"
    echo "======================================================"

    local ZONES_CONFIG=""
    local ZONE_FILES=()
    local ZONE_NAMES=()

    read -rp ">> Nhap ten mien Zone thuan chinh (vi du: nhom5.local): " FORWARD_ZONE
    while [[ -z "$FORWARD_ZONE" ]]; do
        read -rp "[!] Ten mien khong duoc de trong. Nhap lai: " FORWARD_ZONE
    done

    read -rp ">> Nhap IP cua DNS Server (vi du: 10.0.0.1, 172.16.1.1, 192.168.10.1): " SERVER_IP
    while [[ -z "$SERVER_IP" ]]; do
        read -rp "[!] IP server khong duoc de trong. Nhap lai: " SERVER_IP
    done

    detect_network_class "$SERVER_IP"

    echo "[*] Nhan dien IP thuoc Lop ${DETECTED_CLASS}."
    echo "[*] Zone nghich goi y: ${CALC_REV_ZONE}"
    echo "[*] PTR prefix goi y: ${CALC_PTR_PREFIX}"
    read -rp ">> Nhan Enter de dung zone nghich tren, hoac nhap ten khac: " REVERSE_ZONE_INPUT
    local REVERSE_ZONE=${REVERSE_ZONE_INPUT:-$CALC_REV_ZONE}

    ZONES_CONFIG+=$(cat <<EOF

// --- Forward Zone: ${FORWARD_ZONE} ---
zone "${FORWARD_ZONE}" IN {
    type master;
    file "${FORWARD_ZONE}.db";
    allow-update { none; };
};

// --- Reverse Zone: ${REVERSE_ZONE} ---
zone "${REVERSE_ZONE}" IN {
    type master;
    file "${REVERSE_ZONE}.db";
    allow-update { none; };
};
EOF
)

    local FWD_FILE="/var/named/${FORWARD_ZONE}.db"
    cat <<EOF > "$FWD_FILE"
\$TTL 1D
@       IN SOA  ns1.${FORWARD_ZONE}. admin.${FORWARD_ZONE}. (
                                        ${SERIAL_DATE} ; Serial
                                        1D         ; Refresh
                                        1H         ; Retry
                                        1W         ; Expire
                                        3H )       ; Minimum TTL

; Name Server Record
@       IN      NS      ns1.${FORWARD_ZONE}.

; A Records
ns1     IN      A       ${SERVER_IP}
@       IN      A       ${SERVER_IP}
www     IN      A       ${SERVER_IP}
EOF

    ZONE_FILES+=("$FWD_FILE")
    ZONE_NAMES+=("$FORWARD_ZONE")

    local REV_FILE="/var/named/${REVERSE_ZONE}.db"
    cat <<EOF > "$REV_FILE"
\$TTL 1D
@       IN SOA  ns1.${FORWARD_ZONE}. admin.${FORWARD_ZONE}. (
                                        ${SERIAL_DATE} ; Serial
                                        1D         ; Refresh
                                        1H         ; Retry
                                        1W         ; Expire
                                        3H )       ; Minimum TTL

; Name Server Record
@       IN      NS      ns1.${FORWARD_ZONE}.

; PTR Records
${CALC_PTR_PREFIX}       IN      PTR     ns1.${FORWARD_ZONE}.
${CALC_PTR_PREFIX}       IN      PTR     ${FORWARD_ZONE}.
EOF

    ZONE_FILES+=("$REV_FILE")
    ZONE_NAMES+=("$REVERSE_ZONE")

    echo ""
    echo "======================================================"
    echo " THEM CAC CAP ZONE BO SUNG (THUAN & NGHICH)"
    echo "======================================================"

    local ZONE_COUNT=1
    while true; do
        read -rp ">> Ban co muon them cap zone (thuan & nghich) nao nua khong? (y/n, mac dinh: n): " ADD_MORE
        ADD_MORE=${ADD_MORE:-n}
        if [[ ! "$ADD_MORE" =~ ^[yY]$ ]]; then
            break
        fi

        ZONE_COUNT=$((ZONE_COUNT + 1))
        echo ""
        echo "--- Nhap thong tin Cap Zone thu ${ZONE_COUNT} ---"

        read -rp "  >> Nhap ten mien Zone thuan (vi du: phu.local): " EXTRA_FWD_ZONE
        while [[ -z "$EXTRA_FWD_ZONE" ]]; do
            read -rp "  [!] Ten mien khong duoc de trong. Nhap lai: " EXTRA_FWD_ZONE
        done

        read -rp "  >> Nhap IP tuong ung (mac dinh: ${SERVER_IP}): " EXTRA_IP
        EXTRA_IP=${EXTRA_IP:-$SERVER_IP}

        detect_network_class "$EXTRA_IP"
        echo "  [*] Nhan dien Lop ${DETECTED_CLASS}. Zone nghich goi y: ${CALC_REV_ZONE}"
        echo "  [*] PTR prefix goi y: ${CALC_PTR_PREFIX}"
        read -rp "  >> Nhan Enter de dung zone nghich tren, hoac nhap ten khac: " EXTRA_REV_ZONE_INPUT
        local EXTRA_REV_ZONE=${EXTRA_REV_ZONE_INPUT:-$CALC_REV_ZONE}

        local EXTRA_FWD_FILE="/var/named/${EXTRA_FWD_ZONE}.db"
        cat <<EOF > "$EXTRA_FWD_FILE"
\$TTL 1D
@       IN SOA  ns1.${EXTRA_FWD_ZONE}. admin.${EXTRA_FWD_ZONE}. (
                                        ${SERIAL_DATE} ; Serial
                                        1D         ; Refresh
                                        1H         ; Retry
                                        1W         ; Expire
                                        3H )       ; Minimum TTL

; Name Server Record
@       IN      NS      ns1.${EXTRA_FWD_ZONE}.

; A Records
ns1     IN      A       ${EXTRA_IP}
@       IN      A       ${EXTRA_IP}
www     IN      A       ${EXTRA_IP}
EOF

        local EXTRA_REV_FILE="/var/named/${EXTRA_REV_ZONE}.db"
        cat <<EOF > "$EXTRA_REV_FILE"
\$TTL 1D
@       IN SOA  ns1.${EXTRA_FWD_ZONE}. admin.${EXTRA_FWD_ZONE}. (
                                        ${SERIAL_DATE} ; Serial
                                        1D         ; Refresh
                                        1H         ; Retry
                                        1W         ; Expire
                                        3H )       ; Minimum TTL

; Name Server Record
@       IN      NS      ns1.${EXTRA_FWD_ZONE}.

; PTR Records
${CALC_PTR_PREFIX}       IN      PTR     ns1.${EXTRA_FWD_ZONE}.
${CALC_PTR_PREFIX}       IN      PTR     ${EXTRA_FWD_ZONE}.
EOF

        ZONES_CONFIG+=$(cat <<EOF

// --- Forward Zone: ${EXTRA_FWD_ZONE} ---
zone "${EXTRA_FWD_ZONE}" IN {
    type master;
    file "${EXTRA_FWD_ZONE}.db";
    allow-update { none; };
};

// --- Reverse Zone: ${EXTRA_REV_ZONE} ---
zone "${EXTRA_REV_ZONE}" IN {
    type master;
    file "${EXTRA_REV_ZONE}.db";
    allow-update { none; };
};
EOF
)

        ZONE_FILES+=("$EXTRA_FWD_FILE" "$EXTRA_REV_FILE")
        ZONE_NAMES+=("$EXTRA_FWD_ZONE" "$EXTRA_REV_ZONE")
        echo "  [+] Da them cap zone: ${EXTRA_FWD_ZONE} va ${EXTRA_REV_ZONE}"
    done

    if [ -f /etc/named.conf ] && [ ! -f /etc/named.conf.bak ]; then
        echo ""
        echo "[*] Dang sao luu file mac dinh /etc/named.conf thanh /etc/named.conf.bak..."
        cp -p /etc/named.conf /etc/named.conf.bak
        echo "[+] Da tao ban sao luu: /etc/named.conf.bak"
    fi

    echo "[*] Dang khoi tao file /etc/named.conf moi..."
    cat <<EOF > /etc/named.conf
// Cau hinh BIND DNS Server tu dong
options {
    listen-on port 53 { ${LISTEN_VAL} };
    listen-on-v6 port 53 { ::1; };
    directory       "/var/named";
    dump-file       "/var/named/data/cache_dump.db";
    statistics-file "/var/named/data/named_stats.txt";
    memstatistics-file "/var/named/data/named_mem_stats.txt";
    secroots-file   "/var/named/data/named.secroots";
    recursing-file  "/var/named/data/named.recursing";
    allow-query     { ${QUERY_VAL} };
${FORWARDER_CONF}

    recursion yes;
    dnssec-validation no;

    managed-keys-directory "/var/named/dynamic";
    pid-file "/run/named/named.pid";
    session-keyfile "/run/named/session.key";

    include "/etc/crypto-policies/back-ends/bind.config";
};

logging {
    channel default_debug {
        file "data/named.run";
        severity dynamic;
    };
};

zone "." IN {
    type hint;
    file "named.ca";
};
${ZONES_CONFIG}

include "/etc/named.rfc1912.zones";
include "/etc/named.root.key";
EOF

    echo ""
    echo "[*] Dang thiet lap quyen he thong va SELinux..."
    chown root:named /etc/named.conf
    chmod 640 /etc/named.conf

    for f in "${ZONE_FILES[@]}"; do
        chown named:named "$f"
        chmod 640 "$f"
    done

    if command -v restorecon >/dev/null 2>&1; then
        restorecon -F /etc/named.conf
        restorecon -Rv /var/named/
    fi

    echo ""
    echo "======================================================"
    echo " KIEM TRA CU PHAP CAU HINH (SYNTAX CHECK)"
    echo "======================================================"

    named-checkconf /etc/named.conf && echo "[OK] File /etc/named.conf hop le."

    for i in "${!ZONE_NAMES[@]}"; do
        named-checkzone "${ZONE_NAMES[$i]}" "${ZONE_FILES[$i]}"
    done

    echo ""
    echo "[*] Dang khoi dong service named..."
    systemctl restart named
    systemctl enable named

    if systemctl is-active --quiet firewalld; then
        echo "[*] Dang mo cong DNS tren firewalld..."
        firewall-cmd --add-service=dns --permanent --zone=internal
        firewall-cmd --reload
        echo "[OK] Da mo thanh cong service DNS tren firewall."
    fi

    echo ""
    echo "======================================================"
    echo " HOAN TAT CAU HINH DNS SERVER THANH CONG!"
    echo "======================================================"
    echo "- File backup mac dinh : /etc/named.conf.bak"
    echo "- File cau hinh chinh  : /etc/named.conf"
    if [[ -n "$FORWARDER_CONF" ]]; then
        echo "- Forwarder            : 8.8.8.8"
    fi
    echo "- Danh sach file zone da tao:"
    for f in "${ZONE_FILES[@]}"; do
        echo "  + $f"
    done
    echo ""
    echo "Lenh kiem tra phan giai:"
    echo "  dig @localhost ${FORWARD_ZONE}"
    echo "  dig -x ${SERVER_IP} @localhost"
}

# ==============================================================================
# 5. CAU HINH DHCP SERVER
# ==============================================================================
module_setup_dhcp() {
    local CONF_PATH="/etc/dhcp/dhcpd.conf"
    local BACKUP_DIR="/etc/dhcp/backups"

    echo ""
    echo -e "${BLUE}======================================================${NC}"
    echo -e "${BLUE}   QUAN LY VA CAU HINH ISC DHCP SERVER - CENTOS STREAM 9   ${NC}"
    echo -e "${BLUE}======================================================${NC}\n"

    mkdir -p "$BACKUP_DIR"

    backup_config() {
        if [[ -f "$CONF_PATH" ]]; then
            local timestamp
            timestamp=$(date +%Y%m%d_%H%M%S)
            local backup_file="$BACKUP_DIR/dhcpd.conf.bak.${timestamp}"
            cp "$CONF_PATH" "$backup_file"
            echo -e "${YELLOW}[i] Da tu dong backup file cau hinh tai: ${backup_file}${NC}"
        fi
    }

    restore_config() {
        echo -e "\n${CYAN}=== DANH SACH BAN BACKUP TRONG $BACKUP_DIR ===${NC}"
        mapfile -t backups < <(ls -1t "$BACKUP_DIR"/dhcpd.conf.bak.* 2>/dev/null)

        if [[ ${#backups[@]} -eq 0 ]]; then
            echo -e "${RED}[!] Khong tim thay ban backup nao trong he thong!${NC}"
            return 1
        fi

        local index=1
        for b in "${backups[@]}"; do
            local file_time
            file_time=$(date -r "$b" "+%d/%m/%Y %H:%M:%S")
            echo -e "  ${YELLOW}$index)${NC} $(basename "$b") - [Ngay tao: $file_time]"
            ((index++))
        done

        echo ""
        read -rp "Chon so thu tu ban backup muon restore (1-${#backups[@]} | 0 de huy): " choice

        if [[ "$choice" -eq 0 ]]; then
            echo -e "${YELLOW}[*] Da huy thao tac restore.${NC}"
            return 1
        fi

        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#backups[@]}" ]; then
            local selected_file="${backups[$((choice - 1))]}"
            backup_config
            cp "$selected_file" "$CONF_PATH"
            echo -e "${GREEN}[✓] Da khoi phuc thanh cong file cau hinh tu: $(basename "$selected_file")${NC}"
            return 0
        else
            echo -e "${RED}[!] Lua chon khong hop le.${NC}"
            return 1
        fi
    }

    input_and_append_subnet() {
        echo -e "\n${CYAN}--- NHAP THONG SO SUBNET MOI ---${NC}"
        read -rp "Dia chi Subnet mang (VD: 192.168.10.0): " SUBNET
        read -rp "Subnet Mask (VD: 255.255.255.0): " NETMASK
        read -rp "Dai IP cap - Bat dau (VD: 192.168.10.100): " RANGE_START
        read -rp "Dai IP cap - Ket thuc (VD: 192.168.10.200): " RANGE_END
        read -rp "Default Gateway / Router (VD: 192.168.10.1): " GATEWAY
        read -rp "DNS Servers (phan cach boi dau phay, VD: 8.8.8.8, 1.1.1.1): " DNS_SERVERS
        read -rp "Domain Name (VD: lan.local - de trong neu khong co): " DOMAIN_NAME

        cat <<EOF >> "$CONF_PATH"

# Subnet: $SUBNET (Them boi script vao $(date "+%Y-%m-%d %H:%M:%S"))
subnet $SUBNET netmask $NETMASK {
    range $RANGE_START $RANGE_END;
    option subnet-mask $NETMASK;
    option routers $GATEWAY;
EOF

        if [[ -n "$DNS_SERVERS" ]]; then
            echo "    option domain-name-servers $DNS_SERVERS;" >> "$CONF_PATH"
        fi

        if [[ -n "$DOMAIN_NAME" ]]; then
            echo "    option domain-name \"$DOMAIN_NAME\";" >> "$CONF_PATH"
        fi

        echo "}" >> "$CONF_PATH"
        echo -e "${GREEN}[✓] Da them subnet $SUBNET vao file $CONF_PATH${NC}"
    }

    local IS_INSTALLED=false
    if rpm -q dhcp-server &>/dev/null; then
        IS_INSTALLED=true
        echo -e "${GREEN}[✓] Phat hien goi 'dhcp-server' da duoc cai dat tren he thong.${NC}"
    else
        echo -e "${YELLOW}[-] Goi 'dhcp-server' chua duoc cai dat. Tien hanh cai dat qua dnf...${NC}"
        if dnf install -y dhcp-server; then
            echo -e "${GREEN}[✓] Cai dat goi dhcp-server thanh cong!${NC}"
        else
            echo -e "${RED}[!] Loi khi cai dat dhcp-server. Kiem tra lai ket noi mang hoac dnf repository.${NC}"
            return 1
        fi
    fi

    local NEED_ADD_SUBNET=true

    if [[ "$IS_INSTALLED" == true && -f "$CONF_PATH" ]]; then
        echo -e "\n${BLUE}He thong da co san file cau hinh DHCP. Vui long chon thao tac:${NC}"
        echo "1) Them subnet moi vao file cau hinh hien tai (giu nguyen cac thiet lap cu)"
        echo "2) Restore lai dhcpd.conf tu ban backup cu"
        echo "3) Tao moi hoan toan dhcpd.conf (ghi de file moi sau khi backup)"
        read -rp "Lua chon cua ban [1/2/3, mac dinh la 1]: " ACTION_CHOICE
        ACTION_CHOICE=${ACTION_CHOICE:-1}

        case "$ACTION_CHOICE" in
            1)
                backup_config
                ;;
            2)
                if restore_config; then
                    read -rp "Ban co muon them them subnet nao vao file vua restore khong? (y/n) [n]: " ADD_MORE_AFTER_RESTORE
                    if [[ "$ADD_MORE_AFTER_RESTORE" =~ ^[yY]$ ]]; then
                        NEED_ADD_SUBNET=true
                    else
                        NEED_ADD_SUBNET=false
                    fi
                else
                    return 1
                fi
                ;;
            3)
                backup_config
                echo -e "${YELLOW}[*] Khoi tao file cau hinh dhcpd.conf moi...${NC}"
                read -rp "Default lease time (giay) [600]: " DEF_LEASE
                DEF_LEASE=${DEF_LEASE:-600}
                read -rp "Max lease time (giay) [7200]: " MAX_LEASE
                MAX_LEASE=${MAX_LEASE:-7200}

                cat <<EOF > "$CONF_PATH"
# /etc/dhcp/dhcpd.conf
# Khoi tao moi vao $(date)

default-lease-time $DEF_LEASE;
max-lease-time $MAX_LEASE;
authoritative;
EOF
                ;;
            *)
                echo -e "${RED}[!] Lua chon khong hop le.${NC}"
                return 1
                ;;
        esac
    else
        backup_config
        echo -e "\n${YELLOW}[*] Khoi tao file cau hinh dhcpd.conf goc...${NC}"
        read -rp "Default lease time (giay) [600]: " DEF_LEASE
        DEF_LEASE=${DEF_LEASE:-600}
        read -rp "Max lease time (giay) [7200]: " MAX_LEASE
        MAX_LEASE=${MAX_LEASE:-7200}

        cat <<EOF > "$CONF_PATH"
# /etc/dhcp/dhcpd.conf
# Khoi tao boi setup_dhcp.sh vao $(date)

default-lease-time $DEF_LEASE;
max-lease-time $MAX_LEASE;
authoritative;
EOF
    fi

    if [[ "$NEED_ADD_SUBNET" == true ]]; then
        while true; do
            input_and_append_subnet
            echo ""
            read -rp "Ban co muon them subnet nao khac nua khong? (y/n) [n]: " ADD_ANOTHER
            if [[ ! "$ADD_ANOTHER" =~ ^[yY]$ ]]; then
                break
            fi
        done
    fi

    echo -e "\n${YELLOW}[*] Dang kiem tra cu phap file cau hinh dhcpd.conf...${NC}"
    if ! dhcpd -t -cf "$CONF_PATH" &>/dev/null; then
        echo -e "${RED}[!] Phat hien loi cu phap trong $CONF_PATH! Noi dung loi chi tiet:${NC}"
        dhcpd -t -cf "$CONF_PATH"
        echo -e "${YELLOW}[!] Vui long kiem tra va sua lai file $CONF_PATH hoac su dung lua chon Restore.${NC}"
        return 1
    fi
    echo -e "${GREEN}[✓] Cu phap file cau hinh hoan toan hop le.${NC}"

    if systemctl is-active --quiet firewalld; then
        echo -e "${YELLOW}[*] Dang mo port DHCP (UDP 67) tren Firewalld (Zone: internal)...${NC}"
        firewall-cmd --zone=internal --add-service=dhcp --permanent &>/dev/null
        firewall-cmd --reload &>/dev/null
        echo -e "${GREEN}[✓] Da mo dich vu DHCP tren zone 'internal' thanh cong.${NC}"
    else
        echo -e "${YELLOW}[!] Firewalld khong chay, bo qua buoc mo firewall.${NC}"
    fi

    echo -e "${YELLOW}[*] Dang enable va restart dich vu dhcpd...${NC}"
    systemctl enable dhcpd &>/dev/null
    systemctl restart dhcpd

    if systemctl is-active --quiet dhcpd; then
        echo -e "\n${GREEN}======================================================${NC}"
        echo -e "${GREEN}[✓] DICH VU DHCP SERVER DA HOAT DONG THANH CONG!${NC}"
        echo -e "${GREEN}======================================================${NC}"
        echo -e "Trang thai: Active (running)"
        echo -e "File cau hinh chinh: $CONF_PATH"
        echo -e "Thu muc backup: $BACKUP_DIR"
        echo -e "Xem nhat ky cap IP (leases): cat /var/lib/dhcpd/dhcpd.leases"
        echo -e "Theo doi log truc tiep: journalctl -u dhcpd -f"
    else
        echo -e "\n${RED}[!] Khoi dong dhcpd that bai. Nguyen nhan pho bien:${NC}"
        echo -e "  - Server chua co IP tinh thuoc dai subnet da cau hinh."
        echo -e "  - Kiem tra loi bang lenh: ${YELLOW}journalctl -xeu dhcpd${NC}"
    fi
}

# ==============================================================================
# 6. CAU HINH FTP SERVER (VSFTPD)
# ==============================================================================
module_setup_ftp() {
    local CONF_FILE="/etc/vsftpd/vsftpd.conf"
    local ORIG_FILE="/etc/vsftpd/vsftpd.conf.orig"

    install_vsftpd() {
        if rpm -q vsftpd &>/dev/null; then
            echo "[+] Goi vsftpd da duoc cai dat tren he thong."
        else
            echo "[*] Dang tien hanh cai dat vsftpd qua dnf..."
            dnf install -y vsftpd
            echo "[+] Cai dat vsftpd thanh cong."
        fi

        if [ -f "$CONF_FILE" ] && [ ! -f "$ORIG_FILE" ]; then
            cp "$CONF_FILE" "$ORIG_FILE"
            echo "[+] DA LUU BAN GOC HE THONG TAI: $ORIG_FILE"
        fi
    }

    restore_to_original() {
        echo ""
        if [ ! -f "$ORIG_FILE" ]; then
            echo "[-] Khong tim thay ban goc: $ORIG_FILE"
            echo "[-] Vui long chay cai dat truoc de tao ban goc."
            return
        fi

        read -r -p "Ban co chac muon khoi phuc ve file goc mac dinh? (y/N): " CONFIRM
        if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
            cp "$ORIG_FILE" "$CONF_FILE"
            systemctl restart vsftpd
            echo "[+] Da khoi phuc thanh cong ve file cau hinh goc!"
            echo "[+] Trang thai dich vu: $(systemctl is-active vsftpd)"
        else
            echo "[*] Da huy thao tac khoi phuc."
        fi
    }

    configure_vsftpd() {
        install_vsftpd

        echo ""
        echo "--- [1/4] Chon card mang chay FTP ---"
        local IF_NAMES=()
        local IF_IPS=()
        local i=1

        while read -r ifname ip; do
            IF_NAMES[i]="$ifname"
            IF_IPS[i]="$ip"
            echo "  $i) Card mang: $ifname (IP: $ip)"
            ((i++))
        done < <(ip -4 -o addr show scope global | awk '{print $2, $4}' | cut -d/ -f1)

        echo "  0) Tat ca card mang (0.0.0.0)"
        read -r -p "Chon card mang muon gan [Mac dinh: 0]: " IF_CHOICE
        IF_CHOICE=${IF_CHOICE:-0}

        local LISTEN_CONFIG=""
        local SELECTED_IP=""
        if [ "$IF_CHOICE" -ne 0 ] && [ -n "${IF_IPS[$IF_CHOICE]}" ]; then
            SELECTED_IP="${IF_IPS[$IF_CHOICE]}"
            LISTEN_CONFIG="listen_address=${SELECTED_IP}"
            echo "[+] Gan FTP vao card ${IF_NAMES[$IF_CHOICE]} (IP: $SELECTED_IP)"
        else
            echo "[+] Lang nghe tren tat ca cac card mang."
        fi

        echo ""
        echo "--- [2/4] Ghi tep cau hinh vsftpd.conf ---"
        cat <<EOF > "$CONF_FILE"
# Chay doc lap tren cong 21
listen=YES
listen_ipv6=NO
listen_port=21
EOF

        if [ -n "$LISTEN_CONFIG" ]; then
            echo "$LISTEN_CONFIG" >> "$CONF_FILE"
        fi

        cat <<'EOF' >> "$CONF_FILE"

# Cho phep tai khoan local dang nhap va co quyen ghi (upload/xoa)
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=022

# Co lap thu muc ca nhan (Chroot)
chroot_local_user=YES
allow_writeable_chroot=YES

# Cau hinh Passive Mode cho mang noi bo/may ao
pasv_enable=YES
pasv_min_port=30000
pasv_max_port=31000

# Tat whitelist de moi user tao ra deu dang nhap duoc ngay
userlist_enable=NO

# Xac thuc tai khoan
pam_service_name=vsftpd
EOF
        echo "[+] Da ap dung cau hinh Lab."

        echo ""
        echo "--- [3/4] Cau hinh Nguoi dung & Thu muc ---"
        read -r -p "Nhap ten user FTP [Mac dinh: ftpuser]: " FTP_USER
        FTP_USER=${FTP_USER:-ftpuser}

        grep -qx "/sbin/nologin" /etc/shells || echo "/sbin/nologin" >> /etc/shells
        grep -qx "/usr/sbin/nologin" /etc/shells || echo "/usr/sbin/nologin" >> /etc/shells

        if id "$FTP_USER" &>/dev/null; then
            echo "[*] Tai khoan '$FTP_USER' da ton tai."
        else
            echo "[*] Dang tao tai khoan '$FTP_USER'..."
            useradd -m -s /sbin/nologin "$FTP_USER"
            echo "[*] Dat mat khau cho tai khoan '$FTP_USER':"
            passwd "$FTP_USER"
        fi

        local USER_HOME
        USER_HOME=$(getent passwd "$FTP_USER" | cut -d: -f6)
        read -r -p "Thu muc upload ben trong home [Mac dinh: ftp/upload]: " REL_DIR
        REL_DIR=${REL_DIR:-ftp/upload}
        local FULL_UPLOAD_DIR="${USER_HOME}/${REL_DIR}"

        mkdir -p "$FULL_UPLOAD_DIR"
        chown -R "$FTP_USER":"$FTP_USER" "${USER_HOME}/ftp"
        chmod 755 "${USER_HOME}/ftp"
        chmod 775 "$FULL_UPLOAD_DIR"
        echo "[+] Thu muc upload da san sang: $FULL_UPLOAD_DIR"

        echo ""
        echo "--- [4/4] Thiet lap Tuong lua & SELinux ---"
        if command -v getenforce &>/dev/null && [ "$(getenforce)" != "Disabled" ]; then
            setsebool -P ftpd_full_access 1
            echo "[+] Da cap quyen SELinux (ftpd_full_access)."
        fi

        if systemctl is-active --quiet firewalld; then
            read -r -p "Mo port 21 va 30000-31000/tcp tren Firewalld? (Y/n): " CONFIRM_FW
            CONFIRM_FW=${CONFIRM_FW:-Y}
            if [[ "$CONFIRM_FW" =~ ^[Yy]$ ]]; then
                firewall-cmd --permanent --add-service=ftp --zone=internal
                firewall-cmd --permanent --add-port=30000-31000/tcp --zone=internal
                firewall-cmd --reload
                echo "[+] Da mo port tren Firewalld thanh cong."
            fi
        fi

        systemctl enable --now vsftpd
        systemctl restart vsftpd

        local BIND_INFO="${SELECTED_IP:-0.0.0.0 (Tat ca card)}"
        echo ""
        echo "=============================================="
        echo "          CAU HINH THANH CONG                 "
        echo "=============================================="
        echo "Dia chi bind:     $BIND_INFO"
        echo "Port:             21"
        echo "Passive ports:    30000 - 31000"
        echo "User:             $FTP_USER"
        echo "Thu muc upload:   $FULL_UPLOAD_DIR"
        echo "Trang thai:       $(systemctl is-active vsftpd)"
        echo "=============================================="
    }

    while true; do
        echo ""
        echo "=============================================="
        echo "     QUAN LY VSFTPD - CENTOS STREAM 9         "
        echo "=============================================="
        echo "  1) Cai dat & Cau hinh Lab"
        echo "  2) Khoi phuc ve file goc mac dinh (Restore .orig)"
        echo "  3) Kiem tra trang thai dich vu vsftpd"
        echo "  0) Quay lai Menu chinh"
        echo "----------------------------------------------"
        read -r -p "Nhap lua chon cua ban [0-3]: " OPTION

        case "$OPTION" in
            1)
                configure_vsftpd
                ;;
            2)
                restore_to_original
                ;;
            3)
                echo ""
                systemctl status vsftpd --no-pager
                ;;
            0)
                return 0
                ;;
            *)
                echo "[-] Lua chon khong hop le, vui long chon lai."
                ;;
        esac
    done
}

# ==============================================================================
# 7. CAU HINH WEB SERVER (NGINX & OPENSSL)
# ==============================================================================
module_setup_web() {
    echo ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}   HE THONG CAU HINH NGINX & OPENSSL SSL - CENTOS STREAM 9      ${NC}"
    echo -e "${BLUE}================================================================${NC}\n"

    # 1. KIEM TRA VA TAT SELINUX
    echo -e "${YELLOW}--- [1/3] KIEM TRA VA XU LY SELINUX ---${NC}"
    local CURRENT_SELINUX
    CURRENT_SELINUX=$(getenforce 2>/dev/null)
    echo "Trang thai SELinux hien tai: $CURRENT_SELINUX"

    if [ "$CURRENT_SELINUX" = "Enforcing" ]; then
        echo -e "${YELLOW}[*] SELinux dang Enforcing. Dang chay setenforce 0...${NC}"
        setenforce 0
        if [ -f /etc/selinux/config ]; then
            sed -i 's/^SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
            sed -i 's/^SELINUX=permissive/SELINUX=disabled/' /etc/selinux/config
        fi
        echo -e "${GREEN}[✔] Da chay setenforce 0 va sua /etc/selinux/config thanh disabled.${NC}"
    elif [ "$CURRENT_SELINUX" = "Permissive" ]; then
        echo -e "${GREEN}[✔] SELinux da o che do Permissive.${NC}"
        if [ -f /etc/selinux/config ]; then
            sed -i 's/^SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
            sed -i 's/^SELINUX=permissive/SELINUX=disabled/' /etc/selinux/config
        fi
    elif [ "$CURRENT_SELINUX" = "Disabled" ]; then
        echo -e "${GREEN}[✔] SELinux da duoc tat hoan toan (Disabled).${NC}"
    fi

    # 2. KIEM TRA VA CAI DAT NGINX, NANO, OPENSSL
    echo -e "\n${YELLOW}--- [2/3] KIEM TRA CAC GOI DICH VU CAN THIET ---${NC}"
    local PACKAGES_TO_INSTALL=()

    for pkg in nginx nano openssl; do
        if ! rpm -q "$pkg" &>/dev/null; then
            PACKAGES_TO_INSTALL+=("$pkg")
        fi
    done

    if [ ${#PACKAGES_TO_INSTALL[@]} -gt 0 ]; then
        echo -e "${YELLOW}[*] Dang cai dat: ${PACKAGES_TO_INSTALL[*]}...${NC}"
        dnf install -y "${PACKAGES_TO_INSTALL[@]}"
        echo -e "${GREEN}[✔] Cai dat thanh cong.${NC}"
    else
        echo -e "${GREEN}[✔] Cac goi (nginx, nano, openssl) da co san tren he thong.${NC}"
    fi

    systemctl enable --now nginx
    if ! systemctl is-active --quiet nginx; then
        systemctl start nginx
    fi

    mkdir -p /etc/nginx/ssl

    # 3. CAU HINH TUONG LUA ZONE INTERNAL
    echo -e "\n${YELLOW}--- [3/3] CAU HINH TUONG LUA (ZONE INTERNAL) ---${NC}"
    if systemctl is-active --quiet firewalld; then
        firewall-cmd --zone=internal --add-service=http --permanent &>/dev/null
        firewall-cmd --zone=internal --add-service=https --permanent &>/dev/null
        firewall-cmd --zone=internal --add-service=dns --permanent &>/dev/null
        firewall-cmd --reload &>/dev/null
        echo -e "${GREEN}[✔] Da mo dich vu HTTP, HTTPS va DNS cho zone 'internal'.${NC}"
    else
        echo -e "${YELLOW}[!] Firewalld khong hoat dong. Bo qua cau hinh tuong lua.${NC}"
    fi

    # 4. VONG LAP CAU HINH WEBSITE
    while true; do
        echo -e "\n${BLUE}================================================================${NC}"
        echo -e "${BLUE}                   THIET LAP WEBSITE MOI                        ${NC}"
        echo -e "${BLUE}================================================================${NC}"

        local DOMAIN_IP=""
        while true; do
            read -rp "Nhap Domain hoac IP cua website (VD: nhom5.local hoac 192.168.1.50): " DOMAIN_IP
            if [[ -n "$DOMAIN_IP" ]]; then
                break
            fi
            echo -e "${RED}[!] Khong duoc de trong.${NC}"
        done

        # KIEM TRA VA CAU HINH BIND DNS (NEU LA DOMAIN)
        if [[ ! "$DOMAIN_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo -e "\n${YELLOW}[*] Dang kiem tra domain '$DOMAIN_IP' trong /etc/named.conf...${NC}"
            
            local NAMED_CONF="/etc/named.conf"
            local DOMAIN_EXISTS=false

            if [[ -f "$NAMED_CONF" ]] && grep -q "zone \"$DOMAIN_IP\"" "$NAMED_CONF"; then
                DOMAIN_EXISTS=true
            fi

            if [ "$DOMAIN_EXISTS" = true ]; then
                echo -e "${GREEN}[✔] Domain $DOMAIN_IP da ton tai trong $NAMED_CONF.${NC}"
            else
                echo -e "${YELLOW}[!] Domain $DOMAIN_IP CHUA CO trong $NAMED_CONF.${NC}"
                read -rp "Ban co muon tao ban ghi thuan va nghich (Forward/Reverse) tren BIND cho $DOMAIN_IP khong? (y/n): " CREATE_DNS

                if [[ "$CREATE_DNS" =~ ^[Yy]$ ]]; then
                    if ! rpm -q bind &>/dev/null; then
                        echo -e "${YELLOW}[*] Dang cai dat bind va bind-utils...${NC}"
                        dnf install -y bind bind-utils
                        systemctl enable named
                    fi

                    sed -i 's/listen-on port 53 { 127.0.0.1; };/listen-on port 53 { any; };/' /etc/named.conf
                    sed -i 's/allow-query     { localhost; };/allow-query     { any; };/' /etc/named.conf

                    local DNS_IP=""
                    while true; do
                        read -rp "Nhap dia chi IP may chu cho domain $DOMAIN_IP: " DNS_IP
                        if [[ "$DNS_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                            break
                        fi
                        echo -e "${RED}[!] Dinh dang IP khong hop le.${NC}"
                    done

                    local SERIAL_DATE
                    SERIAL_DATE=$(date +%Y%m%d01)

                    local FWD_ZONE_FILE="/var/named/${DOMAIN_IP}.db"
                    cat <<EOF > "$FWD_ZONE_FILE"
\$TTL 86400
@   IN  SOA     ns1.${DOMAIN_IP}. admin.${DOMAIN_IP}. (
                $SERIAL_DATE ; Serial
                3600         ; Refresh
                1800         ; Retry
                604800       ; Expire
                86400 )      ; Minimum TTL
@       IN  NS      ns1.${DOMAIN_IP}.
ns1     IN  A       $DNS_IP
@       IN  A       $DNS_IP
www     IN  A       $DNS_IP
EOF
                    chown root:named "$FWD_ZONE_FILE"
                    chmod 640 "$FWD_ZONE_FILE"

                    cat <<EOF >> /etc/named.conf

zone "${DOMAIN_IP}" IN {
    type master;
    file "${DOMAIN_IP}.db";
    allow-update { none; };
};
EOF

                    local ip1 ip2 ip3 ip4
                    IFS='.' read -r ip1 ip2 ip3 ip4 <<< "$DNS_IP"
                    local REV_ZONE="${ip3}.${ip2}.${ip1}.in-addr.arpa"
                    local REV_ZONE_FILE="/var/named/${REV_ZONE}.db"

                    if [[ ! -f "$REV_ZONE_FILE" ]]; then
                        cat <<EOF > "$REV_ZONE_FILE"
\$TTL 86400
@   IN  SOA     ns1.${DOMAIN_IP}. admin.${DOMAIN_IP}. (
                $SERIAL_DATE ; Serial
                3600         ; Refresh
                1800         ; Retry
                604800       ; Expire
                86400 )      ; Minimum TTL
@       IN  NS      ns1.${DOMAIN_IP}.
$ip4    IN  PTR     ${DOMAIN_IP}.
EOF
                        chown root:named "$REV_ZONE_FILE"
                        chmod 640 "$REV_ZONE_FILE"

                        cat <<EOF >> /etc/named.conf

zone "${REV_ZONE}" IN {
    type master;
    file "${REV_ZONE}.db";
    allow-update { none; };
};
EOF
                    else
                        echo "$ip4    IN  PTR     ${DOMAIN_IP}." >> "$REV_ZONE_FILE"
                    fi

                    if named-checkconf /etc/named.conf; then
                        systemctl restart named
                        echo -e "${GREEN}[✔] Cau hinh Forward & Reverse DNS BIND thanh cong!${NC}"
                    else
                        echo -e "${RED}[✘] Loi cu phap named.conf! Kiem tra lai bang 'named-checkconf'.${NC}"
                    fi
                fi
            fi
        fi

        # CAU HINH THU MUC WEB & INDEX.HTML
        local DEFAULT_ROOT="/var/www/$DOMAIN_IP"
        read -rp "Nhap thu muc chua web (Mac dinh: $DEFAULT_ROOT): " WEB_ROOT
        WEB_ROOT=${WEB_ROOT:-$DEFAULT_ROOT}

        if [[ ! -d "$WEB_ROOT" ]]; then
            mkdir -p "$WEB_ROOT"
            echo -e "${GREEN}[✔] Da tao thu muc: $WEB_ROOT${NC}"
        fi

        local INDEX_FILE="$WEB_ROOT/index.html"
        read -rp "Ban co muon nhap/soan noi dung cho index.html bang nano khong? (y/n): " EDIT_INDEX

        if [[ "$EDIT_INDEX" =~ ^[Yy]$ ]]; then
            if [[ ! -f "$INDEX_FILE" ]]; then
                cat <<EOF > "$INDEX_FILE"
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Website $DOMAIN_IP</title>
</head>
<body>
    <h1>Website $DOMAIN_IP dang hoat dong voi HTTPS!</h1>
</body>
</html>
EOF
            fi
            nano "$INDEX_FILE"
        else
            if [[ ! -f "$INDEX_FILE" ]]; then
                cat <<EOF > "$INDEX_FILE"
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Website $DOMAIN_IP</title>
</head>
<body>
    <h1>Chao mung den voi website: $DOMAIN_IP</h1>
    <p>Trang web chay tren CentOS Stream 9 bang Nginx.</p>
</body>
</html>
EOF
                echo -e "${GREEN}[✔] Da tao file index.html mac dinh.${NC}"
            fi
        fi

        echo -e "${YELLOW}[*] Dang phan quyen cho thu muc $WEB_ROOT...${NC}"
        chown -R nginx:nginx "$WEB_ROOT"
        chmod -R 755 "$WEB_ROOT"
        echo -e "${GREEN}[✔] Da phan quyen nginx:nginx va chmod 755.${NC}"

        # TAO SSL BANG OPENSSL VA CAU HINH VIRTUAL HOST
        read -rp "Ban co muon tao chung chi SSL tu ky (OpenSSL) cho $DOMAIN_IP khong? (y/n): " SETUP_SSL
        local CONF_FILE="/etc/nginx/conf.d/${DOMAIN_IP}.conf"

        if [[ "$SETUP_SSL" =~ ^[Yy]$ ]]; then
            local SSL_KEY="/etc/nginx/ssl/${DOMAIN_IP}.key"
            local SSL_CRT="/etc/nginx/ssl/${DOMAIN_IP}.crt"

            echo -e "${YELLOW}[*] Dang tao chung chi SSL tu ky cho $DOMAIN_IP bang OpenSSL...${NC}"
            openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
                -keyout "$SSL_KEY" \
                -out "$SSL_CRT" \
                -subj "/C=VN/ST=TayNinh/L=RachKien/O=Lab/CN=${DOMAIN_IP}" &>/dev/null

            chmod 600 "$SSL_KEY"
            chmod 644 "$SSL_CRT"
            echo -e "${GREEN}[✔] Da tao xong file chung chi: $SSL_CRT va private key: $SSL_KEY${NC}"

            cat <<EOF > "$CONF_FILE"
server {
    listen 80;
    server_name $DOMAIN_IP;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMAIN_IP;

    ssl_certificate $SSL_CRT;
    ssl_certificate_key $SSL_KEY;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    root $WEB_ROOT;
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }

    access_log /var/log/nginx/${DOMAIN_IP}_access.log;
    error_log /var/log/nginx/${DOMAIN_IP}_error.log;
}
EOF
            echo -e "${GREEN}[✔] Da tao cau hinh Nginx voi HTTPS (tu dong redirect port 80 -> 443).${NC}"
        else
            cat <<EOF > "$CONF_FILE"
server {
    listen 80;
    server_name $DOMAIN_IP;

    root $WEB_ROOT;
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }

    access_log /var/log/nginx/${DOMAIN_IP}_access.log;
    error_log /var/log/nginx/${DOMAIN_IP}_error.log;
}
EOF
            echo -e "${GREEN}[✔] Da tao cau hinh Nginx chi voi HTTP (Port 80).${NC}"
        fi

        if nginx -t &>/dev/null; then
            systemctl reload nginx
            echo -e "${GREEN}[✔] Nginx reload thanh cong! Website da san sang tai: $CONF_FILE${NC}"
        else
            echo -e "${RED}[✘] Cu phap Nginx bi loi! Hay kiem tra lai bang 'nginx -t'.${NC}"
        fi

        read -rp "Ban co muon cau hinh them website khac nua khong? (y/n): " MORE_WEB
        if [[ ! "$MORE_WEB" =~ ^[Yy]$ ]]; then
            echo -e "\n${GREEN}[✔] Hoan tat toan bo qua trinh cai dat Web Server!${NC}\n"
            break
        fi
    done
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
    echo -e "  ${YELLOW}2)${NC} Cau hinh IP tinh (NetworkManager & Firewalld)"
    echo -e "  ${YELLOW}3)${NC} Cau hinh NAT (Router / Gateway)"
    echo -e "  ${YELLOW}4)${NC} Cau hinh DNS (BIND9 Server)"
    echo -e "  ${YELLOW}5)${NC} Cau hinh DHCP (ISC DHCP Server)"
    echo -e "  ${YELLOW}6)${NC} Cau hinh FTP (vsftpd Server)"
    echo -e "  ${YELLOW}7)${NC} Cau hinh Web Server (Nginx & OpenSSL)"
    echo -e "  ${YELLOW}0)${NC} Thoat"
    echo -e "${CYAN}----------------------------------------------------------------${NC}"
    read -rp "Nhap lua chon cua ban [0-7]: " MAIN_CHOICE

    case "$MAIN_CHOICE" in
        1)
            module_disable_selinux
            pause_menu
            ;;
        2)
            module_setup_ip
            pause_menu
            ;;
        3)
            module_setup_nat
            pause_menu
            ;;
        4)
            module_setup_dns
            pause_menu
            ;;
        5)
            module_setup_dhcp
            pause_menu
            ;;
        6)
            module_setup_ftp
            ;;
        7)
            module_setup_web
            pause_menu
            ;;
        0)
            echo -e "${GREEN}[+] Tam biet!${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}[!] Lua chon khong hop le. Vui long nhap tu 0 den 7.${NC}"
            ;;
    esac
done