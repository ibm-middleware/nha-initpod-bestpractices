# IBM MQ NativeHA CRR Vault Init Lab

This folder is a public-safe, flattened lab bundle for IBM MQ NativeHA with
Cross-Region Replication and Vault-injected certificate material.

The important point proven in the lab:

```text
Vault provides PEM files -> init container writes MQ mount paths -> MQ generates KDBs at runtime
```

No real application, NativeHA, or NHACRR private key material is stored in
OpenShift Secrets. The only OpenShift Secret in this pattern is a dummy one-day
admission/controller shim required by the IBM MQ Operator.

## Files

```text
README.md                         This file
CERTIFICATE_PROFILES.md           Final three Venafi profile recommendation
NATIVEHA_CRR_VAULT_INIT_PROOF.md  Sanitized runtime proof and command evidence
qmgr-live.yaml                    Public-safe USE/live QueueManager manifest
qmgr-recovery.yaml                Public-safe USW/recovery QueueManager manifest
mq_vault_cert_init.sh             Standalone init script source
deploy.sh                         Helper that creates dummy shim Secrets and applies both manifests
test_mq_vault_cert_init_sh.py     Unit test for the init script layout
```

There are no nested `bin/`, `manifests/`, or `tests/` folders in this flattened
bundle.

## Public Placeholder Values

```text
MQ queue manager name:       TMPQM001
USE namespace:               tmpqm001-use
USW namespace:               tmpqm001-usw
QueueManager CR name:        tmpqm001
Image:                       icr.io/ibm-messaging/mq:9.4.5.0-r2
Vault address placeholder:   https://vault.mycompany.org:8200
Vault KV mount:              kv
Vault cert base path:        mq/TMPQM001
```

USE route wildcard:

```text
*.apps.ocp-useqa01.ocp-use.qa.aws.mycompany.org
```

USW route wildcard:

```text
*.apps.ocp-uswqa01.ocp-usw.qa.aws.mycompany.org
```

## Certificate Sets

The init container fetches three Vault certificate sets:

```text
kv/data/mq/TMPQM001/app-pki
kv/data/mq/TMPQM001/nha-tls
kv/data/mq/TMPQM001/nhacrr-tls
```

Each set must expose:

```text
tls.key
tls.crt
ca.crt
```

The three Venafi profiles are documented in
`CERTIFICATE_PROFILES.md`:

```text
TMPQM001-APP
TMPQM001-NHA
TMPQM001-NHACRR
```

## Runtime Layout

App/client PKI:

```text
/etc/mqm/pki/keys/default
/run/runmqserver/tls/key.kdb
```

NativeHA internal PKI:

```text
/etc/mqm/ha/pki/keys/ha-vault
/run/runmqserver/ha/tls/key.kdb
```

NHACRR PKI:

```text
/etc/mqm/groupha/pki/keys/groupha
/etc/mqm/groupha/pki/trust/remote
/run/runmqserver/ha/tls/key.kdb
```

There is no separate CRR KDB. MQ merges the CRR material into the NativeHA
runtime KDB.

## Before Deploying

Replace these placeholders in both QueueManager manifests:

```text
REPLACE_WITH_VAULT_TOKEN
REPLACE_WITH_STORAGE_CLASS
https://vault.mycompany.org:8200
```

The public manifests intentionally do not contain a real Vault token, internal
registry, internal Vault path, or private domain.

## Deploy

```bash
./deploy.sh
```

The helper script creates the dummy admission shim Secret in both namespaces:

```text
tmpqm001-admission-shim
```

Then it applies:

```text
qmgr-live.yaml
qmgr-recovery.yaml
```

## Test

```bash
python3 -m unittest test_mq_vault_cert_init_sh.py -v
```

## Verify Runtime TLS

```bash
oc get qmgr,pod -n tmpqm001-use
oc get qmgr,pod -n tmpqm001-usw
```

Check generated PEM input paths:

```bash
oc exec -n tmpqm001-use tmpqm001-ibm-mq-1 -c qmgr -- sh -c '
  find /etc/mqm/pki /etc/mqm/ha/pki /etc/mqm/groupha/pki \
    -maxdepth 5 -type f \( -name "*.key" -o -name "*.crt" \) -print | sort
'
```

Check generated KDBs:

```bash
oc exec -n tmpqm001-use tmpqm001-ibm-mq-1 -c qmgr -- sh -c '
  find /run -name "*.kdb" -o -name "*.sth" -o -name "*.rdb" -o -name "*.crl" 2>/dev/null | sort
'
```

Check NativeHA and NHACRR TLS logs:

```bash
oc logs -n tmpqm001-use tmpqm001-ibm-mq-1 -c qmgr --tail=500 | \
  egrep -a 'AMQ3253|AMQ3255|AMQ3307|AMQ3308|AMQ3212|AMQ3214|TLS_'
```

## Cleanup

```bash
oc delete ns tmpqm001-use tmpqm001-usw
```
