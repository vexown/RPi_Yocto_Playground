#!/bin/bash
# Generate the playground's RAUC signing keys (session 11).
#
# Usage:  ./scripts/rauc-gen-keys.sh
#
# WHY THIS SCRIPT EXISTS
# ----------------------
# A RAUC update bundle is a SIGNED artifact. The device refuses to install
# anything it can't verify. That means two halves that must match:
#
#   * the private signing key  — lives ONLY on the build machine, and is the
#     thing an attacker would need to push malicious firmware to your fleet.
#     It must never enter a git repo, especially not a public one.
#   * the CA certificate      — the "trust anchor", baked into the image at
#     /etc/rauc/ca.cert.pem. It is PUBLIC by design: every device carries a
#     copy, and it contains no secret. Tracking it in git is correct.
#
# So this script splits them exactly along that line:
#   private key + signing cert  ->  $KEYDIR (on the build disk, untracked)
#   ca.cert.pem                 ->  copied into meta-playground (tracked)
#
# meta-rauc ships scripts/openssl-ca.sh and meta-rauc-community ships
# create-example-keys.sh which do roughly this; we write our own so the
# whole chain is reproducible from THIS repo, and so the certificate
# subject is ours rather than "Test Org".
#
# This is a DEVELOPMENT CA. Real products keep the CA key offline (an HSM
# or a locked-down signing server), issue short-lived intermediate certs,
# and plan for key rotation — RAUC supports keyring updates for exactly
# that reason. None of which is happening on a learning laptop.
set -e

# Off-repo, on the build disk — same reasoning as poky/downloads/sstate:
# regenerable or private, never tracked.
KEYDIR="/media/blankmcu/EmbeddedLinux/yocto/rauc-keys"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Where the image's trust anchor lives, consumed by our rauc-conf.bbappend.
CA_DEST="$REPO_DIR/meta-playground/recipes-core/rauc/files/ca.cert.pem"

# Certificate subject. Deliberately generic — certificates are shipped to
# every device and are readable by anyone holding the image, so no real
# names or addresses go in here.
ORG="Playground"
CA_CN="Playground Development CA"
SIGN_CN="Playground Development Signing Key 1"

if [ -e "$KEYDIR" ]; then
    echo "ERROR: $KEYDIR already exists."
    echo "Keys are already generated. Delete the directory to start over —"
    echo "but note that regenerating the CA invalidates every bundle signed"
    echo "with the old one, AND every device already carrying the old"
    echo "ca.cert.pem will reject new bundles until it is re-flashed."
    exit 1
fi

mkdir -p "$KEYDIR"/{private,certs}
chmod 700 "$KEYDIR/private"
touch "$KEYDIR/index.txt"        # openssl ca's database of issued certs
echo 01 > "$KEYDIR/serial"       # ...and its serial counter

# openssl's `ca` command is driven entirely by a config file; there is no
# usable command-line-only path. This is the minimum that produces a CA
# plus one leaf certificate signed by it.
cat > "$KEYDIR/openssl.cnf" <<'EOF'
[ ca ]
default_ca      = CA_default

[ CA_default ]
dir             = .
database        = $dir/index.txt
new_certs_dir   = $dir/certs
certificate     = $dir/ca.cert.pem
serial          = $dir/serial
private_key     = $dir/private/ca.key.pem

# Certificates valid "forever". A real product would use a sane lifetime
# and a rotation plan; an expired signing cert bricks your update path.
default_startdate = 19700101000000Z
default_enddate   = 99991231235959Z
default_crl_days  = 30
default_md        = sha256

policy          = policy_any
email_in_dn     = no
name_opt        = ca_default
cert_opt        = ca_default
copy_extensions = none

[ policy_any ]
organizationName = match
commonName       = supplied

[ req ]
default_bits       = 4096
distinguished_name = req_distinguished_name
x509_extensions    = v3_leaf
encrypt_key        = no
default_md         = sha256

[ req_distinguished_name ]
commonName     = Common Name
commonName_max = 64

# CA:TRUE — this certificate is allowed to sign other certificates.
[ v3_ca ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer:always
basicConstraints       = CA:TRUE

# CA:FALSE — a leaf. It can sign bundles, but cannot mint more certs.
[ v3_leaf ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer:always
basicConstraints       = CA:FALSE
EOF

cd "$KEYDIR"
export OPENSSL_CONF="$KEYDIR/openssl.cnf"

echo ">>> Generating development CA (self-signed root)..."
openssl req -newkey rsa:4096 -keyout private/ca.key.pem -out ca.csr.pem \
    -subj "/O=$ORG/CN=$CA_CN"
openssl ca -batch -selfsign -extensions v3_ca \
    -in ca.csr.pem -out ca.cert.pem -keyfile private/ca.key.pem

echo ">>> Generating signing key, signed BY the CA..."
openssl req -newkey rsa:4096 -keyout private/development-1.key.pem \
    -out development-1.csr.pem -subj "/O=$ORG/CN=$SIGN_CN"
openssl ca -batch -extensions v3_leaf \
    -in development-1.csr.pem -out development-1.cert.pem

chmod 600 private/*.key.pem

# The public half goes into the repo, so a fresh clone + rebuild produces
# an image that trusts the same CA. (If you ever regenerate, this copy is
# what must be committed alongside.)
mkdir -p "$(dirname "$CA_DEST")"
cp ca.cert.pem "$CA_DEST"

echo
echo ">>> Done."
echo "    Private keys (NEVER commit):  $KEYDIR/private/"
echo "    Trust anchor (commit this):   $CA_DEST"
echo
echo "conf-templates/local.conf already points RAUC_KEY_FILE / RAUC_CERT_FILE"
echo "at $KEYDIR — nothing else to configure."
