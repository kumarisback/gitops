#!/usr/bin/env bash
# Rebuilds ca-bundle.pem in feature-flags/components/rds and
# streaming/components/flag-changes-rds, the certificates Unleash and
# Debezium trust for their database (roadmap step 23, docs/DATABASE.md):
#
#   - AWS's bundle of RDS certificate authorities, every region, for the
#     instance itself (its certificate is signed by the RDS CA chosen with
#     tf rds_ca_cert_identifier);
#   - Amazon Trust Services' four roots, for RDS Proxy, whose certificate
#     comes from ACM.
#
# Run it when AWS announces a new RDS CA (they have a lifetime; RDS emails
# before one expires), then commit the result. Refuses any certificate whose
# issuer isn't Amazon.
set -euo pipefail
cd "$(dirname "$0")/.."
outs=(feature-flags/components/rds/ca-bundle.pem streaming/components/flag-changes-rds/ca-bundle.pem)
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT

curl -fsSL --max-time 60 -o "${tmp}/rds.pem" https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
for i in 1 2 3 4; do
  curl -fsSL --max-time 60 -o "${tmp}/root${i}.pem" "https://www.amazontrust.com/repository/AmazonRootCA${i}.pem"
done
cat "${tmp}/rds.pem" "${tmp}"/root?.pem > "${tmp}/bundle.pem"

total=$(grep -c 'BEGIN CERTIFICATE' "${tmp}/bundle.pem")
amazon=$(openssl crl2pkcs7 -nocrl -certfile "${tmp}/bundle.pem" | openssl pkcs7 -print_certs -noout |
  grep '^issuer=' | grep -c -E 'O ?= ?(Amazon Web Services, Inc\.|Amazon)[,/]')
if [ "${total}" -eq 0 ] || [ "${total}" -ne "${amazon}" ]; then
  echo "refusing: ${amazon} of ${total} certificates issued by Amazon" >&2
  exit 1
fi
for out in "${outs[@]}"; do
  cp "${tmp}/bundle.pem" "${out}"
  echo "${out}: ${total} certificates"
done
