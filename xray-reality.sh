#!/usr/bin/env bash

# ============================================================
# Xray VLESS + REALITY Installer
# Ubuntu 24.04+
# TCP 443 / REALITY / XTLS Vision
# ============================================================

set -Eeuo pipefail

XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_INFO="/root/xray-reality-info.txt"
XRAY_PORT="443"
FLOW="xtls-rprx-vision"

SERVER_IP=""
SNI=""
UUID=""
PRIVATE_KEY=""
PUBLIC_KEY=""
SHORT_ID=""
VLESS_URL=""

XRAY_SERVICE_USER="nobody"
XRAY_SERVICE_GROUP=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;36m'
CYAN='\033[0;36m'
NC='\033[0m'

info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

ok() {
    echo -e "${GREEN}[ OK ]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

err() {
    echo -e "${RED}[ERROR]${NC} $*"
}

die() {
    err "$*"
    exit 1
}

trap 'echo; err "Installer failed at line ${LINENO}."; exit 1' ERR

# ============================================================
# ROOT CHECK
# ============================================================

if [[ "${EUID}" -ne 0 ]]; then
    die "Please run this script as root."
fi

# ============================================================
# OS CHECK
# ============================================================

if [[ ! -f /etc/os-release ]]; then
    die "/etc/os-release not found."
fi

source /etc/os-release

if [[ "${ID:-}" != "ubuntu" ]]; then
    warn "This script is designed for Ubuntu."
    warn "Detected OS: ${PRETTY_NAME:-unknown}"
fi

# ============================================================
# INSTALL DEPENDENCIES
# ============================================================

install_dependencies() {

    info "Updating package information..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update -y

    info "Installing required packages..."

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

    ok "Required packages installed."
}

# ============================================================
# DETECT PUBLIC IP
# ============================================================

detect_public_ip() {

    info "Detecting public IPv4 address..."

    SERVER_IP="$(
        curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true
    )"

    if [[ -z "${SERVER_IP}" ]]; then
        SERVER_IP="$(
            curl -4 -fsS --max-time 10 https://ifconfig.me 2>/dev/null || true
        )"
    fi

    if [[ -z "${SERVER_IP}" ]]; then
        SERVER_IP="$(
            curl -4 -fsS --max-time 10 https://icanhazip.com 2>/dev/null || true
        )"
    fi

    SERVER_IP="$(echo "${SERVER_IP}" | tr -d '[:space:]')"

    if ! [[ "${SERVER_IP}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        die "Unable to detect a valid public IPv4 address."
    fi

    ok "Public IPv4: ${SERVER_IP}"
}

# ============================================================
# CHECK LOCAL PORT 443
# ============================================================

check_local_port() {

    info "Checking whether TCP ${XRAY_PORT} is already in use..."

    if ss -lnt 2>/dev/null |
        awk '{print $4}' |
        grep -Eq "(:|\])${XRAY_PORT}$"; then

        err "TCP port ${XRAY_PORT} is already in use."

        echo
        ss -lntp |
            grep -E "(:|\])${XRAY_PORT}\b" || true

        echo

        die "Please stop the service using port ${XRAY_PORT}."
    fi

    ok "TCP ${XRAY_PORT} is available."
}

# ============================================================
# DOMAIN FORMAT CHECK
# ============================================================

valid_domain_format() {

    local domain="$1"

    [[ -n "${domain}" ]] || return 1

    [[ "${#domain}" -le 253 ]] || return 1

    [[ "${domain}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] ||
        return 1

    return 0
}

# ============================================================
# TEST SNI
# DNS
# TCP 443
# TLS 1.3
# ============================================================

validate_sni() {

    local domain="$1"
    local resolved_ip=""
    local tls_output=""

    echo
    info "Testing SNI: ${domain}"

    if ! valid_domain_format "${domain}"; then
        err "Invalid domain format."
        return 1
    fi

    # -------------------------
    # DNS
    # -------------------------

    info "Checking DNS resolution..."

    resolved_ip="$(
        getent ahostsv4 "${domain}" 2>/dev/null |
        awk 'NR==1 {print $1}' ||
        true
    )"

    if [[ -z "${resolved_ip}" ]]; then
        err "DNS resolution failed for ${domain}."
        return 1
    fi

    ok "DNS resolved: ${domain} -> ${resolved_ip}"

    # -------------------------
    # TCP 443
    # -------------------------

    info "Checking TCP connectivity to ${domain}:443..."

    if ! timeout 10 bash -c \
        "cat < /dev/null > /dev/tcp/${domain}/443" \
        2>/dev/null; then

        err "TCP connection to ${domain}:443 failed."
        return 1
    fi

    ok "TCP 443 connection successful."

    # -------------------------
    # TLS 1.3
    # -------------------------

    info "Checking TLS 1.3 handshake..."

    tls_output="$(
        timeout 15 \
        openssl s_client \
            -connect "${domain}:443" \
            -servername "${domain}" \
            -tls1_3 \
            </dev/null \
            2>&1 ||
        true
    )"

    if echo "${tls_output}" |
        grep -Eq 'Protocol[[:space:]]*:[[:space:]]*TLSv1\.3'; then

        ok "TLS 1.3 handshake successful."
        return 0
    fi

    if echo "${tls_output}" | grep -q "TLSv1.3"; then

        ok "TLS 1.3 handshake successful."
        return 0
    fi

    err "TLS 1.3 handshake failed."

    echo
    echo "TLS diagnostic:"
    echo "------------------------------------------------------------"
    echo "${tls_output}" | tail -n 20
    echo "------------------------------------------------------------"

    return 1
}

# ============================================================
# SELECT SNI
# ============================================================

select_sni() {

    local supplied="${1:-}"
    local choice=""
    local domain=""

    # Direct command-line domain
    if [[ -n "${supplied}" ]]; then

        info "Testing supplied SNI: ${supplied}"

        if validate_sni "${supplied}"; then
            SNI="${supplied}"
            return 0
        fi

        die "Supplied SNI failed validation."
    fi

    while true; do

        clear || true

        echo
        echo "============================================================"
        echo "        Xray VLESS + REALITY SNI Selection"
        echo "============================================================"
        echo
        echo "  1) www.microsoft.com"
        echo "  2) www.apple.com"
        echo "  3) www.google.com"
        echo "  4) www.cloudflare.com"
        echo "  5) Custom domain"
        echo "  0) Exit"
        echo

        read -r -p "Enter your choice [0-5]: " choice

        case "${choice}" in

            1)
                domain="www.microsoft.com"
                ;;

            2)
                domain="www.apple.com"
                ;;

            3)
                domain="www.google.com"
                ;;

            4)
                domain="www.cloudflare.com"
                ;;

            5)
                echo
                read -r -p "Enter custom domain: " domain

                domain="${domain#http://}"
                domain="${domain#https://}"
                domain="${domain%%/*}"
                domain="${domain%%:*}"
                ;;

            0)
                info "Installation cancelled."
                exit 0
                ;;

            *)
                err "Invalid choice."
                sleep 2
                continue
                ;;
        esac

        if validate_sni "${domain}"; then

            SNI="${domain}"

            echo
            ok "Selected SNI: ${SNI}"

            sleep 1

            return 0
        fi

        echo
        warn "This SNI failed validation."
        warn "Please select another SNI."
        echo

        read -r -p "Press Enter to return to the menu..." _
    done
}

# ============================================================
# INSTALL XRAY
# ============================================================

install_xray() {

    if [[ -x "${XRAY_BIN}" ]]; then

        info "Xray is already installed."

        "${XRAY_BIN}" version || true

    else

        info "Installing official Xray release..."

        bash -c "$(
            curl -L \
            https://github.com/XTLS/Xray-install/raw/main/install-release.sh
        )" @ install
    fi

    if [[ ! -x "${XRAY_BIN}" ]]; then
        die "Xray binary was not found at ${XRAY_BIN}."
    fi

    ok "Xray binary is available."

    "${XRAY_BIN}" version || true

    # Stop service before replacing config.
    systemctl stop xray 2>/dev/null || true
}

# ============================================================
# DETECT ACTUAL XRAY USER/GROUP
# ============================================================

detect_xray_service_account() {

    info "Detecting Xray systemd service account..."

    if ! getent passwd "${XRAY_SERVICE_USER}" >/dev/null; then
        die "User '${XRAY_SERVICE_USER}' does not exist."
    fi

    XRAY_SERVICE_GROUP="$(
        id -gn "${XRAY_SERVICE_USER}"
    )"

    if [[ -z "${XRAY_SERVICE_GROUP}" ]]; then
        die "Unable to determine group for ${XRAY_SERVICE_USER}."
    fi

    echo
    echo "Xray service account:"
    echo "  User : ${XRAY_SERVICE_USER}"
    echo "  Group: ${XRAY_SERVICE_GROUP}"
    echo

    ok "Xray service account detected."
}

# ============================================================
# GENERATE UUID / X25519 / SHORT ID
# ============================================================

generate_credentials() {

    info "Generating Xray UUID..."

    UUID="$(uuidgen)"

    [[ -n "${UUID}" ]] ||
        die "Failed to generate UUID."

    ok "UUID generated."

    # -------------------------
    # X25519
    # -------------------------

    info "Generating X25519 key pair..."

    local key_output=""

    key_output="$(
        "${XRAY_BIN}" x25519 2>&1
    )"

    echo
    echo "X25519 output:"
    echo "------------------------------------------------------------"
    echo "${key_output}"
    echo "------------------------------------------------------------"
    echo

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

    # Compatibility fallback
    if [[ -z "${PUBLIC_KEY}" ]]; then

        PUBLIC_KEY="$(
            echo "${key_output}" |
            sed -n 's/^PublicKey:[[:space:]]*//p' |
            head -n 1 |
            tr -d '\r'
        )"
    fi

    [[ -n "${PRIVATE_KEY}" ]] ||
        die "Failed to extract X25519 private key."

    [[ -n "${PUBLIC_KEY}" ]] ||
        die "Failed to extract X25519 public key."

    ok "X25519 key pair generated."

    # -------------------------
    # Short ID
    # -------------------------

    info "Generating REALITY Short ID..."

    SHORT_ID="$(openssl rand -hex 8)"

    [[ -n "${SHORT_ID}" ]] ||
        die "Failed to generate Short ID."

    ok "Short ID: ${SHORT_ID}"
}

# ============================================================
# CREATE XRAY CONFIG
# ============================================================

create_config() {

    info "Creating Xray configuration..."

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

    [[ -s "${XRAY_CONFIG}" ]] ||
        die "Failed to create ${XRAY_CONFIG}"

    # --------------------------------------------------------
    # IMPORTANT
    #
    # Do NOT use:
    #
    #   chown root:nobody
    #
    # because Ubuntu commonly uses:
    #
    #   nobody:nogroup
    #
    # We detected the actual group dynamically above.
    # --------------------------------------------------------

    chown root:"${XRAY_SERVICE_GROUP}" "${XRAY_CONFIG}"

    chmod 640 "${XRAY_CONFIG}"

    # Directory must be searchable by Xray.
    chown root:root "$(dirname "${XRAY_CONFIG}")"
    chmod 755 "$(dirname "${XRAY_CONFIG}")"

    echo
    echo "Configuration permissions:"
    ls -ld "$(dirname "${XRAY_CONFIG}")"
    ls -l "${XRAY_CONFIG}"
    echo

    ok "Xray configuration created."
}

# ============================================================
# VALIDATE JSON
# ============================================================

validate_json() {

    info "Validating JSON syntax..."

    if ! jq empty "${XRAY_CONFIG}" >/dev/null 2>&1; then

        err "Invalid JSON configuration."

        echo
        cat "${XRAY_CONFIG}"
        echo

        die "JSON validation failed."
    fi

    ok "JSON syntax is valid."
}

# ============================================================
# VALIDATE XRAY CONFIG
# ============================================================

validate_xray_config() {

    info "Testing Xray configuration..."

    local output=""

    if ! output="$(
        "${XRAY_BIN}" run \
        -test \
        -config "${XRAY_CONFIG}" \
        2>&1
    )"; then

        err "Xray configuration test failed."

        echo
        echo "------------------------------------------------------------"
        echo "${output}"
        echo "------------------------------------------------------------"
        echo

        die "Xray configuration validation failed."
    fi

    echo "${output}"

    ok "Xray configuration test passed."
}

# ============================================================
# FIREWALL
# ============================================================

configure_firewall() {

    # -------------------------
    # UFW
    # -------------------------

    if command -v ufw >/dev/null 2>&1; then

        if ufw status 2>/dev/null |
            grep -q "Status: active"; then

            info "UFW is active. Allowing TCP 443..."

            ufw allow 443/tcp >/dev/null

            ok "UFW allows TCP 443."
        fi
    fi

    # -------------------------
    # iptables
    # -------------------------

    if command -v iptables >/dev/null 2>&1; then

        if iptables -C INPUT \
            -p tcp \
            --dport 443 \
            -j ACCEPT \
            2>/dev/null; then

            info "iptables already allows TCP 443."

        else

            info "Adding iptables rule for TCP 443..."

            iptables -I INPUT \
                -p tcp \
                --dport 443 \
                -j ACCEPT

            ok "iptables allows TCP 443."
        fi
    fi
}

# ============================================================
# START XRAY
# ============================================================

start_xray() {

    info "Reloading systemd..."

    systemctl daemon-reload

    info "Enabling Xray service..."

    systemctl enable xray >/dev/null 2>&1

    info "Starting Xray..."

    if ! systemctl restart xray; then

        err "Xray failed to start."

        echo
        echo "==================== SYSTEMD STATUS ======================="

        systemctl status xray \
            --no-pager \
            -l || true

        echo
        echo "==================== XRAY JOURNAL ========================="

        journalctl -u xray \
            -n 100 \
            --no-pager || true

        die "Xray service failed to start."
    fi

    sleep 2

    if systemctl is-active --quiet xray; then

        ok "Xray service is running."

    else

        err "Xray service is not active."

        echo
        systemctl status xray \
            --no-pager \
            -l || true

        echo
        journalctl -u xray \
            -n 100 \
            --no-pager || true

        die "Xray service is not running."
    fi
}

# ============================================================
# VERIFY PORT 443
# ============================================================

verify_port() {

    info "Checking TCP port ${XRAY_PORT}..."

    if ss -lntp 2>/dev/null |
        grep -Eq "(:|\])${XRAY_PORT}\b"; then

        ok "Xray is listening on TCP ${XRAY_PORT}."

        echo
        ss -lntp |
            grep -E "(:|\])${XRAY_PORT}\b" || true
        echo

    else

        err "TCP port ${XRAY_PORT} is not listening."

        systemctl status xray \
            --no-pager \
            -l || true

        echo

        journalctl -u xray \
            -n 100 \
            --no-pager || true

        die "Port verification failed."
    fi
}

# ============================================================
# GENERATE VLESS URL
# ============================================================

generate_vless_url() {

    VLESS_URL="vless://${UUID}@${SERVER_IP}:${XRAY_PORT}?type=tcp&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=${SNI}&sid=${SHORT_ID}&spx=%2F&flow=${FLOW}#Xray-REALITY"

    ok "VLESS URL generated."
}

# ============================================================
# SAVE INFORMATION
# ============================================================

save_information() {

    info "Saving connection information..."

    cat > "${XRAY_INFO}" <<EOF
============================================================
XRAY VLESS + REALITY
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
FILES
============================================================

Xray config:
${XRAY_CONFIG}

Connection information:
${XRAY_INFO}

============================================================
COMMANDS
============================================================

Check status:
systemctl status xray --no-pager

Restart:
systemctl restart xray

Stop:
systemctl stop xray

Start:
systemctl start xray

Logs:
journalctl -u xray -n 100 --no-pager

Config test:
xray run -test -config ${XRAY_CONFIG}

Port check:
ss -lntp | grep ':443'

============================================================
EOF

    chown root:root "${XRAY_INFO}"
    chmod 600 "${XRAY_INFO}"

    ok "Connection information saved:"
    echo "${XRAY_INFO}"
}

# ============================================================
# FINAL RESULT
# ============================================================

show_result() {

    echo
    echo "============================================================"
    echo "     Xray VLESS + REALITY Installation Complete"
    echo "============================================================"
    echo

    echo "Server IP : ${SERVER_IP}"
    echo "Port      : ${XRAY_PORT}"
    echo "Protocol  : VLESS"
    echo "Transport : TCP"
    echo "Security  : REALITY"
    echo "Flow      : ${FLOW}"
    echo "SNI       : ${SNI}"
    echo

    echo "UUID:"
    echo "${UUID}"
    echo

    echo "Public Key:"
    echo "${PUBLIC_KEY}"
    echo

    echo "Short ID:"
    echo "${SHORT_ID}"
    echo

    echo "VLESS URL:"
    echo "${VLESS_URL}"
    echo

    echo "Config:"
    echo "${XRAY_CONFIG}"
    echo

    echo "Info:"
    echo "${XRAY_INFO}"
    echo

    echo "============================================================"
    echo "Service status"
    echo "============================================================"

    systemctl status xray \
        --no-pager \
        -l |
        sed -n '1,15p' || true

    echo
}

# ============================================================
# MAIN
# ============================================================

echo
echo "============================================================"
echo "       Xray VLESS + REALITY Installer"
echo "============================================================"
echo

info "Starting installation..."

install_dependencies

detect_public_ip

check_local_port

select_sni "${1:-}"

install_xray

detect_xray_service_account

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
ok "Installation completed successfully."
echo
