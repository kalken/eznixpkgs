# ezcert: a certificate authority of one's own, and certificates signed by it.
# Run by ezcert.service (modules/ezcert.nix) with openssl and coreutils on PATH; plain sh and
# only what both OpenSSL and LibreSSL know, so it can be tried by hand on any machine:
#
#   sh ezcert.sh ca       DIR NAME
#   sh ezcert.sh cert     OUT CA_CERT CA_KEY DAYS RENEW_DAYS OWNER GROUP NAME...
#   sh ezcert.sh keystore OUT PATH ALIAS PASSWORD OWNER GROUP        (needs keytool as well)
#
# All do nothing when what they would make is already there and still good, so they are run
# at every boot and by a timer. `cert` and `keystore` print "changed" when they wrote something.
set -eu

# An authority in DIR (ca.pem, ca-key.pem), made once and then left alone: everything that
# trusts it would have to be told again otherwise.
make_ca() {
  dir=$1 name=$2
  [ -s "$dir/ca.pem" ] && [ -s "$dir/ca-key.pem" ] && return 0
  mkdir -p "$dir"
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  cat > "$tmp/ca.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3_ca
prompt = no
[dn]
CN = $name
[v3_ca]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF
  ( umask 077; openssl genrsa -out "$tmp/ca-key.pem" 2048 2>/dev/null )
  # A hundred years: nothing limits how long an authority one adds oneself may last, and a
  # new one means importing it everywhere again.
  openssl req -x509 -new -key "$tmp/ca-key.pem" -sha256 -days 36500 -config "$tmp/ca.cnf" -out "$tmp/ca.pem"
  chmod 600 "$tmp/ca-key.pem"
  chmod 644 "$tmp/ca.pem"
  mv "$tmp/ca-key.pem" "$dir/ca-key.pem"
  mv "$tmp/ca.pem" "$dir/ca.pem"
  echo "ezcert: made the authority \"$name\" in $dir" >&2
}

# A certificate in OUT (cert.pem, key.pem, fullchain.pem) for the names given, the first of
# which is also its common name. Written anew when there is none, when the names asked for are
# other ones than it was made for, when it runs out within RENEW_DAYS, or when it is not signed
# by this authority (the authority was replaced, or another one is now used).
make_cert() {
  out=$1 ca_cert=$2 ca_key=$3 days=$4 renew=$5 owner=$6 group=$7
  shift 7
  [ $# -gt 0 ] || { echo "ezcert: $out: no names given" >&2; exit 1; }
  [ -s "$ca_cert" ] && [ -s "$ca_key" ] || { echo "ezcert: the authority is not there: $ca_cert, $ca_key" >&2; exit 1; }
  want=$(printf '%s\n' "$@" | sort)

  why=
  if [ ! -s "$out/cert.pem" ] || [ ! -s "$out/key.pem" ]; then why="there was none"
  elif [ "$(cat "$out/names" 2>/dev/null)" != "$want" ]; then why="the names changed"
  elif ! openssl x509 -in "$out/cert.pem" -noout -checkend $((renew * 86400)) >/dev/null 2>&1; then why="it runs out within $renew days"
  elif ! openssl verify -CAfile "$ca_cert" "$out/cert.pem" >/dev/null 2>&1; then why="it is not from this authority"
  fi

  if [ -n "$why" ]; then
    mkdir -p "$out"
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    # An address goes in as an address and a name as a name: a browser compares them as such.
    san=
    for n in "$@"; do
      case "$n" in
        *:*) kind=IP ;;
        *[!0-9.]*) kind=DNS ;;
        *.*.*.*) kind=IP ;;
        *) kind=DNS ;;
      esac
      san="${san:+$san, }$kind:$n"
    done
    cat > "$tmp/ext.cnf" <<EOF
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = $san
EOF
    ( umask 077; openssl genrsa -out "$tmp/key.pem" 2048 2>/dev/null )
    openssl req -new -key "$tmp/key.pem" -subj "/CN=$1" -out "$tmp/req.pem"
    openssl x509 -req -in "$tmp/req.pem" -CA "$ca_cert" -CAkey "$ca_key" -set_serial "0x$(openssl rand -hex 16)" \
      -days "$days" -sha256 -extfile "$tmp/ext.cnf" -out "$tmp/cert.pem" 2>/dev/null
    cat "$tmp/cert.pem" "$ca_cert" > "$tmp/fullchain.pem"
    printf '%s\n' "$want" > "$tmp/names"
    # The key last: whoever finds a key finds the certificate that belongs to it.
    for f in cert.pem fullchain.pem names key.pem; do mv "$tmp/$f" "$out/$f"; done
    echo "ezcert: new certificate in $out ($why)" >&2
    echo changed
  fi

  # Every time, not only for a new one: who may read it can be changed without the rest.
  chown "$owner:$group" "$out" "$out/cert.pem" "$out/fullchain.pem" "$out/names" "$out/key.pem"
  chmod 755 "$out"
  chmod 644 "$out/cert.pem" "$out/fullchain.pem" "$out/names"
  chmod 640 "$out/key.pem"
}

# The certificate in OUT as a Java keystore at PATH, for a service that reads nothing else (the
# UniFi controller). Written anew when it is not there, when it was made from another
# certificate than the one in OUT now, or when something else has written the file since:
# the service itself may replace it, and what is declared is what should be there. What it
# was made from is noted beside it, in PATH.ezcert.
make_keystore() {
  out=$1 path=$2 alias=$3 pass=$4 owner=$5 group=$6
  # The folder is the service's own and is not made here: created by root it would lock the
  # service out of its own data. Until the service has made it there is nothing to do, and
  # the next run finds it.
  if [ ! -d "$(dirname "$path")" ]; then
    echo "ezcert: $(dirname "$path") is not there yet, the keystore is written at a later run" >&2
    return 0
  fi
  want=$(openssl x509 -in "$out/cert.pem" -noout -fingerprint -sha256)
  note="$path.ezcert"
  if [ -s "$path" ] && [ "$(cat "$note" 2>/dev/null)" = "$want" ] && [ ! "$path" -nt "$note" ]; then
    return 0
  fi
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  ( umask 077
    openssl pkcs12 -export -in "$out/fullchain.pem" -inkey "$out/key.pem" -name "$alias" \
      -password "pass:$pass" -out "$tmp/cert.p12"
    keytool -importkeystore -noprompt -srckeystore "$tmp/cert.p12" -srcstoretype PKCS12 -srcstorepass "$pass" \
      -destkeystore "$tmp/keystore" -deststorepass "$pass" -destkeypass "$pass" -alias "$alias" >/dev/null 2>&1 )
  chown "$owner:$group" "$tmp/keystore"
  chmod 640 "$tmp/keystore"
  mv "$tmp/keystore" "$path"
  printf '%s\n' "$want" > "$note"
  echo "ezcert: wrote the keystore $path" >&2
  echo changed
}

case "${1:-}" in
  ca)       shift; make_ca "$@" ;;
  cert)     shift; make_cert "$@" ;;
  keystore) shift; make_keystore "$@" ;;
  *)        echo "usage: ezcert.sh ca DIR NAME | cert OUT CA_CERT CA_KEY DAYS RENEW_DAYS OWNER GROUP NAME... | keystore OUT PATH ALIAS PASSWORD OWNER GROUP" >&2; exit 2 ;;
esac
