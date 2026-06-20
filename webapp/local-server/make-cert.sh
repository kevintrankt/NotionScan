#!/usr/bin/env bash
#
# Generate a self-signed TLS certificate for the NotionScan local server.
#
# The camera API (getUserMedia) only runs in a "secure context", which over a
# LAN IP means HTTPS. Browsers also require the certificate to list the address
# you visit in its Subject Alternative Name (SAN) — a plain CN is ignored — so
# this script bakes the IP/hostname into the SAN.
#
# Usage:
#   ./make-cert.sh                 # certificate for 192.168.86.239
#   ./make-cert.sh 192.168.1.50    # certificate for another IP
#   ./make-cert.sh myhost.local    # certificate for a hostname
#
# Output: certs/cert.pem and certs/key.pem (auto-detected by server.js).

set -euo pipefail

HOST="${1:-192.168.86.239}"
DIR="$(cd "$(dirname "$0")" && pwd)/certs"
DAYS="${DAYS:-3650}"

# Decide whether the argument is an IP address or a DNS name for the SAN entry.
if [[ "$HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  SAN="IP:${HOST}"
else
  SAN="DNS:${HOST}"
fi

mkdir -p "$DIR"

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$DIR/key.pem" \
  -out "$DIR/cert.pem" \
  -days "$DAYS" \
  -subj "/CN=${HOST}" \
  -addext "subjectAltName=${SAN}"

echo "Created:"
echo "  $DIR/cert.pem"
echo "  $DIR/key.pem"
echo "Certificate is valid for ${HOST} (SAN: ${SAN}) for ${DAYS} days."
