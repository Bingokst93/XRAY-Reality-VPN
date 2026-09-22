#!/usr/bin/env bash

# ============================================================
# Xray VLESS + REALITY Installer
# Target OS: Ubuntu 24.04+
# Transport: TCP
# Security: REALITY
# Port: 443
# ============================================================

set -Eeuo pipefail

# -----------------------------
# Configuration
# -----------------------------
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_INFO="/root/xray-reality-info.txt"
XRAY_BIN="/usr/local/bin/xray"
XRAY_PORT="443"
FLOW="xtls-rprx-vision"

SERVER_IP=""
SNI=""
UUID=""
PRIVATE_KEY=""
PUBLIC_KEY=""
SHORT_ID=""
VLESS_URL=""

# -----------------------------
# Colors
# -----------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# -----------------------------
# Functions
# -----------------------------
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_ok() {
    echo -e "${GREEN}[ OK ]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

die() {
    log_error "$*"
    exit 1
}

pause_line() {
    echo
}

# -----------------------------
# Error handler
# -----------------------------
trap 'echo; log_error "Installer failed at line $LINENO."; exit 1' ERR

# -----------------------------
# Root check
# -----------------------------
if [[ "${EUID}" -ne 0 ]]; then
    die "Please run this script as root."
fi

# -----------------------------
# OS check
# -----------------------------
if [[ ! -f /etc/os-release ]]; then
    die "/etc/os-release not found."
fi

source /etc/os-release

if [[ "${ID}" != "ubuntu" ]]; then
    log_warn "This installer is designed for Ubuntu."
    log_warn "Detected OS: ${PRETTY_NAME:-unknown}"
fi

# -----------------------------
# Install required packages
# -----------------------------
install_dependencies() {

    log_info "Updating package information..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update -y

    log_info "Installing required packages..."

    apt-get install -y \
        curl \
        wget \
        jq \
        openssl \
        uuid-runtime \
        ca-certificates \
        iproute2 \
        iptables \
        dnsutils \
        coreutils

    log_ok "Required packages installed."
}

# -----------------------------
# Detect public IPv4
# -----------------------------
detect_public_ip() {

    log_info "Detecting public IPv4 address..."

    local detected_ip=""

    detected_ip="$(curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"

    if [[ -z "${detected_ip}" ]]; then
        detected_ip="$(curl -4 -fsS --max-time 10 https://ifconfig.me 2>/dev/null || true)"
    fi

    if [[ -z "${detected_ip}" ]]; then
        detected_ip="$(curl -4 -fsS --max-time 10 https://icanhazip.com 2>/dev/null || true)"
    fi

    if [[ -z "${detected_ip}" ]]; then
        die "Unable to detect public IPv4 address."
    fi

    if ! [[ "${detected_ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        die "Invalid public IPv4 detected: ${detected_ip}"
    fi

    SERVER_IP="${detected_ip}"

    log_ok "Public IPv4: ${SERVER_IP}"
}

# -----------------------------
# Check local port
# -----------------------------
check_local_port() {

    log_info "Checking whether local TCP port ${XRAY_PORT} is already in use..."

    if ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\])${XRAY_PORT}$"; then
        log_error "TCP port ${XRAY_PORT} is already in use."

        echo
        ss -lntp | grep -E "(:|\])${XRAY_PORT}\b" || true
        echo

        die "Please stop the existing service using port ${XRAY_PORT}, then run the installer again."
    fi

    log_ok "TCP port ${XRAY_PORT} is available."
}

# -----------------------------
# Validate domain format
# -----------------------------
validate_domain_format() {

    local domain="$1"

    if [[ -z "${domain}" ]]; then
        return 1
    fi

    if [[ "${#domain}" -gt 253 ]]; then
        return 1
    fi

    if ! [[ "${domain}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
        return 1
    fi

    return 0
}

# -----------------------------
# Validate SNI
# -----------------------------
validate_sni() {

    local domain="$1"
    local ip=""
    local tls_output=""

    echo
    log_info "Testing SNI: ${domain}"

    # Domain syntax
    if ! validate_domain_format "${domain}"; then
        log_error "Invalid domain format."
        return 1
    fi

    # DNS
    log_info "Checking DNS resolution..."

    ip="$(getent ahostsv4 "${domain}" 2>/dev/null | awk 'NR==1 {print $1}' || true)"

    if [[ -z "${ip}" ]]; then
        log_error "DNS resolution failed for ${domain}."
        return 1
    fi

    log_ok "DNS resolved: ${domain} -> ${ip}"

    # TCP 443
    log_info "Checking TCP connectivity to ${domain}:443..."

    if ! timeout 10 bash -c "cat < /dev/null > /dev/tcp/${domain}/443" 2>/dev/null; then
        log_error "TCP connection to ${domain}:443 failed."
        return 1
    fi

    log_ok "TCP 443 connection successful."

    # TLS 1.3
    log_info "Checking TLS 1.3 handshake..."

    tls_output="$(
        timeout 15 \
        openssl s_client \
            -connect "${domain}:443" \
            -servername "${domain}" \
            -tls1_3 \
            </dev/null 2>&1 || true
    )"

    if echo "${tls_output}" | grep -Eq 'Protocol[[:space:]]*:[[:space:]]*TLSv1\.3'; then
        log_ok "TLS 1.3 handshake successful."
        return 0
    fi

    # Some OpenSSL versions format the output differently.
    if echo "${tls_output}" | grep -q "TLSv1.3"; then
        log_ok "TLS 1.3 handshake successful."
        return 0
    fi

    log_error "TLS 1.3 handshake failed."

    echo
    echo "TLS diagnostic output:"
    echo "----------------------------------------"
    echo "${tls_output}" | tail -n 20
    echo "----------------------------------------"
    echo

    return 1
}

# -----------------------------
# SNI menu
# -----------------------------
select_sni() {

    local supplied_domain="${1:-}"
    local choice=""
    local custom_domain=""

    # If domain was supplied as argument, use it.
    if [[ -n "${supplied_domain}" ]]; then

        log_info "Domain supplied through command line: ${supplied_domain}"

        if validate_sni "${supplied_domain}"; then
            SNI="${supplied_domain}"
            return 0
        fi

        die "Supplied SNI is not suitable for REALITY."
    fi

    while true; do

        clear || true

        echo
        echo "============================================================"
        echo "        Xray VLESS + REALITY SNI Selection"
        echo "============================================================"
        echo
        echo "Select a TLS SNI / target domain:"
        echo
        echo "  1) www.microsoft.com"
        echo "  2) www.apple.com"
        echo "  3) www.google.com"
        echo "  4) www.cloudflare.com"
        echo "  5) Custom domain"
        echo "  0) Exit"
        echo
        read -r -p "Enter your choice [1-5]: " choice

        case "${choice}" in

            1)
                custom_domain="www.microsoft.com"
                ;;

            2)
                custom_domain="www.apple.com"
                ;;

            3)
                custom_domain="www.google.com"
                ;;

            4)
                custom_domain="www.cloudflare.com"
                ;;

            5)
                echo
                read -r -p "Enter custom domain: " custom_domain

                custom_domain="${custom_domain#http://}"
                custom_domain="${custom_domain#https://}"
                custom_domain="${custom_domain%%/*}"
                ;;

            0)
                log_info "Installation cancelled."
                exit 0
                ;;

            *)
                log_error "Invalid choice."
                sleep 2
                continue
                ;;
        esac

        if validate_sni "${custom_domain}"; then

            SNI="${custom_domain}"

            echo
            log_ok "Selected SNI: ${SNI}"

            sleep 1

            return 0
        fi

        echo
        log_warn "The selected domain failed validation."
        log_warn "Please choose another SNI."
        echo

        read -r -p "Press Enter to return to the SNI menu..." _
    done
}

# -----------------------------
# Install Xray
# -----------------------------
install_xray() {

    if [[ -x "${XRAY_BIN}" ]]; then
        log_info "Xray binary already exists."

        "${XRAY_BIN}" version || true

    else

        log_info "Installing official Xray release..."

        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

    fi

    if [[ ! -x "${XRAY_BIN}" ]]; then
        die "Xray binary was not found at ${XRAY_BIN}."
    fi

    log_ok "Xray installed."

    "${XRAY_BIN}" version || true

    # Stop Xray while replacing configuration.
    systemctl stop xray 2>/dev/null || true
}

# -----------------------------
# Generate credentials
# -----------------------------
generate_credentials() {

    log_info "Generating Xray UUID..."

    UUID="$(uuidgen)"

    if [[ -z "${UUID}" ]]; then
        die "Failed to generate UUID."
    fi

    log_ok "UUID generated."

    log_info "Generating X25519 key pair..."

    local key_output=""

    key_output="$("${XRAY_BIN}" x25519 2>&1)"

    echo
    echo "X25519 output:"
    echo "----------------------------------------"
    echo "${key_output}"
    echo "----------------------------------------"
    echo

    # Current Xray output:
    #
    # PrivateKey: xxxxx
    # Password (PublicKey): xxxxx
    #
    PRIVATE_KEY="$(
        echo "${key_output}" |
        sed -n 's/^PrivateKey:[[:space:]]*//p' |
        head -n 1 |
        tr -d '\r'
    )"

    PUBLIC_KEY="$(
        echo "${key_output}" |
        sed -n 's/^Password (PublicKey):[[:space:]]*//p' |
        head -n 1 |
        tr -d '\r'
    )"

    # Fallback for older output.
    if [[ -z "${PUBLIC_KEY}" ]]; then
        PUBLIC_KEY="$(
            echo "${key_output}" |
            sed -n 's/^PublicKey:[[:space:]]*//p' |
            head -n 1 |
            tr -d '\r'
        )"
    fi

    if [[ -z "${PRIVATE_KEY}" ]]; then
        die "Failed to extract X25519 PrivateKey."
    fi

    if [[ -z "${PUBLIC_KEY}" ]]; then
        die "Failed to extract X25519 PublicKey."
    fi

    log_ok "X25519 key pair generated."

    log_info "Generating REALITY Short ID..."

    SHORT_ID="$(openssl rand -hex 8)"

    if [[ -z "${SHORT_ID}" ]]; then
        die "Failed to generate REALITY Short ID."
    fi

    log_ok "Short ID: ${SHORT_ID}"
}

# -----------------------------
# Create Xray config
# -----------------------------
create_config() {

    log_info "Creating Xray configuration..."

    mkdir -p "$(dirname "${XRAY_CONFIG}")"

    cat > "${XRAY_CONFIG}" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "${FLOW}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${SNI}:443",
          "xver": 0,
          "serverNames": [
            "${SNI}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF

    # --------------------------------------------------------
    # IMPORTANT:
    # Official Xray systemd service runs as user "nobody".
    # Therefore root:root 600 would cause:
    #
    # permission denied
    #
    # Use root:nobody + 640 instead.
    # --------------------------------------------------------

    chown root:nobody "${XRAY_CONFIG}"
    chmod 640 "${XRAY_CONFIG}"
    chmod 755 /usr/local/etc/xray

    log_ok "Xray configuration created."

    echo
    echo "Configuration file:"
    echo "${XRAY_CONFIG}"
    echo

    ls -lah "${XRAY_CONFIG}"
    echo
}

# -----------------------------
# Validate JSON
# -----------------------------
validate_json() {

    log_info "Validating JSON syntax..."

    if ! jq empty "${XRAY_CONFIG}" >/dev/null 2>&1; then

        log_error "Invalid JSON configuration."

        echo
        cat "${XRAY_CONFIG}"
        echo

        die "JSON validation failed."
    fi

    log_ok "JSON syntax is valid."
}

# -----------------------------
# Validate Xray configuration
# -----------------------------
validate_xray_config() {

    log_info "Testing Xray configuration..."

    local output=""

    output="$(
        "${XRAY_BIN}" run \
            -test \
            -config "${XRAY_CONFIG}" 2>&1
    )" || {

        log_error "Xray configuration test failed."

        echo
        echo "----------------------------------------"
        echo "${output}"
        echo "----------------------------------------"
        echo

        die "Xray configuration validation failed."
    }

    echo "${output}"

    log_ok "Xray configuration is valid."
}

# -----------------------------
# Configure firewall
# -----------------------------
configure_firewall() {

    # UFW
    if command -v ufw >/dev/null 2>&1; then

        if ufw status 2>/dev/null | grep -q "Status: active"; then

            log_info "UFW is active. Allowing TCP 443..."

            ufw allow 443/tcp >/dev/null || true

            log_ok "UFW rule added for TCP 443."
        fi
    fi

    # iptables
    if command -v iptables >/dev/null 2>&1; then

        if iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null; then

            log_info "iptables already allows TCP 443."

        else

            log_info "Adding iptables rule for TCP 443..."

            iptables -I INPUT -p tcp --dport 443 -j ACCEPT

            log_ok "iptables rule added."
        fi
    fi
}

# -----------------------------
# Start Xray
# -----------------------------
start_xray() {

    log_info "Reloading systemd..."

    systemctl daemon-reload

    log_info "Enabling Xray service..."

    systemctl enable xray >/dev/null 2>&1

    log_info "Starting Xray..."

    if ! systemctl restart xray; then

        log_error "Xray failed to start."

        echo
        echo "================ Xray Status ================"
        systemctl status xray --no-pager -l || true

        echo
        echo "================ Xray Journal ==============="
        journalctl -u xray -n 80 --no-pager || true

        echo

        die "Xray service failed to start."
    fi

    sleep 2

    if systemctl is-active --quiet xray; then

        log_ok "Xray service is running."

    else

        log_error "Xray service is not active."

        echo
        systemctl status xray --no-pager -l || true

        echo
        journalctl -u xray -n 80 --no-pager || true

        die "Xray service is not running."
    fi
}

# -----------------------------
# Verify port 443
# -----------------------------
verify_port() {

    log_info "Checking local TCP port ${XRAY_PORT}..."

    if ss -lntp 2>/dev/null | grep -Eq "(:|\])${XRAY_PORT}\b"; then

        log_ok "Xray is listening on TCP ${XRAY_PORT}."

        echo
        ss -lntp | grep -E "(:|\])${XRAY_PORT}\b" || true
        echo

    else

        log_error "TCP port ${XRAY_PORT} is not listening."

        systemctl status xray --no-pager -l || true

        journalctl -u xray -n 50 --no-pager || true

        die "Port verification failed."
    fi
}

# -----------------------------
# Generate VLESS URL
# -----------------------------
generate_vless_url() {

    VLESS_URL="vless://${UUID}@${SERVER_IP}:${XRAY_PORT}?type=tcp&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=${SNI}&sid=${SHORT_ID}&spx=%2F&flow=${FLOW}#Xray-REALITY"

    log_ok "VLESS URL generated."
}

# -----------------------------
# Save information
# -----------------------------
save_information() {

    log_info "Saving connection information..."

    cat > "${XRAY_INFO}" <<EOF
============================================================
Xray VLESS + REALITY
============================================================

Server IP:
${SERVER_IP}

Port:
${XRAY_PORT}

Protocol:
VLESS

Transport:
TCP

Security:
REALITY

Flow:
${FLOW}

SNI / Server Name:
${SNI}

UUID:
${UUID}

Private Key:
${PRIVATE_KEY}

Public Key:
${PUBLIC_KEY}

Short ID:
${SHORT_ID}

VLESS URL:
${VLESS_URL}

============================================================
Xray Configuration
============================================================

Config:
${XRAY_CONFIG}

Service:
xray

Useful commands:

systemctl status xray
systemctl restart xray
systemctl stop xray
systemctl start xray

journalctl -u xray -n 100 --no-pager

Xray config test:

xray run -test -config ${XRAY_CONFIG}

Port check:

ss -lntp | grep ':443'

============================================================
EOF

    chmod 600 "${XRAY_INFO}"
    chown root:root "${XRAY_INFO}"

    log_ok "Connection information saved to:"
    echo "${XRAY_INFO}"
}

# -----------------------------
# Final output
# -----------------------------
show_result() {

    clear || true

    echo
    echo "============================================================"
    echo "        Xray VLESS + REALITY Installation Complete"
    echo "============================================================"
    echo

    echo -e "${GREEN}Server IP:${NC}        ${SERVER_IP}"
    echo -e "${GREEN}Port:${NC}             ${XRAY_PORT}"
    echo -e "${GREEN}Protocol:${NC}         VLESS"
    echo -e "${GREEN}Transport:${NC}        TCP"
    echo -e "${GREEN}Security:${NC}         REALITY"
    echo -e "${GREEN}Flow:${NC}             ${FLOW}"
    echo -e "${GREEN}SNI:${NC}              ${SNI}"
    echo
    echo -e "${GREEN}UUID:${NC}"
    echo "${UUID}"
    echo
    echo -e "${GREEN}Public Key:${NC}"
    echo "${PUBLIC_KEY}"
    echo
    echo -e "${GREEN}Short ID:${NC}"
    echo "${SHORT_ID}"
    echo
    echo -e "${GREEN}VLESS URL:${NC}"
    echo "${VLESS_URL}"
    echo
    echo "------------------------------------------------------------"
    echo
    echo -e "${CYAN}Configuration:${NC}"
    echo "${XRAY_CONFIG}"
    echo
    echo -e "${CYAN}Connection information:${NC}"
    echo "${XRAY_INFO}"
    echo
    echo "------------------------------------------------------------"
    echo
    echo -e "${GREEN}Service status:${NC}"
    systemctl --no-pager --full status xray | sed -n '1,12p' || true
    echo
    echo "============================================================"
}

# ============================================================
# Main
# ============================================================

echo
echo "============================================================"
echo "       Xray VLESS + REALITY Installer"
echo "============================================================"
echo

log_info "Starting installation..."

install_dependencies

detect_public_ip

check_local_port

select_sni "${1:-}"

install_xray

generate_credentials

create_config

validate_json

validate_xray_config

configure_firewall

start_xray

verify_port

generate_vless_url

save_information

show_result

echo
log_ok "Installation completed successfully."
echo
