# Venafi Certificate Profiles for TMPQM001 NativeHA CRR

This document gives the final three-profile certificate design for a two-region
IBM MQ NativeHA CRR deployment.

Regions and OpenShift route wildcard domains:

```text
USE cluster route wildcard:
  *.apps.ocp-useqa01.ocp-use.qa.aws.mycompany.org

USW cluster route wildcard:
  *.apps.ocp-uswqa01.ocp-usw.qa.aws.mycompany.org
```

The design uses three Venafi profiles only:

```text
TMPQM001-APP
TMPQM001-NHA
TMPQM001-NHACRR
```

The certs are stored in Vault as PEM material and injected by the MQ init
container. MQ generates the runtime KDB files inside the pod.

## Wildcard Rule

`*.apps.ocp-useqa01.ocp-use.qa.aws.mycompany.org` matches exactly one DNS label
under that wildcard.

It matches:

```text
tmpqm001-ibm-mq-qm-tmpqm001-use.apps.ocp-useqa01.ocp-use.qa.aws.mycompany.org
tmpqm001-ibm-mq-nhacrr-tmpqm001-use.apps.ocp-useqa01.ocp-use.qa.aws.mycompany.org
any-single-label.apps.ocp-useqa01.ocp-use.qa.aws.mycompany.org
```

It does not match:

```text
x.y.apps.ocp-useqa01.ocp-use.qa.aws.mycompany.org
tmpqm001-ibm-mq.tmpqm001-use.svc.cluster.local
qmgr.mycompany.org
*.apps.ocp-uswqa01.ocp-usw.qa.aws.mycompany.org
```

So the OpenShift route wildcards are useful for app and NHACRR route traffic.
They do not cover Kubernetes internal `.svc` names.

## Profile 1: TMPQM001-APP

Purpose:

```text
MQ client / application channel TLS through the QueueManager route.
```

Vault location:

```text
kv/data/mq/TMPQM001/app-pki
```

MQ input path after init injection:

```text
/etc/mqm/pki/keys/default/tls.key
/etc/mqm/pki/keys/default/tls.crt
/etc/mqm/pki/keys/default/ca.crt
/etc/mqm/pki/trust/default/ca.crt
```

MQ generated runtime keystore:

```text
/run/runmqserver/tls/key.kdb
```

Recommended Venafi request:

```text
Profile: TMPQM001-APP
CN:      tmpqm001-qmgr.qa.aws.mycompany.org

SAN:
  DNS:tmpqm001-qmgr.qa.aws.mycompany.org
  DNS:qmgr.mycompany.org
  DNS:*.apps.ocp-useqa01.ocp-use.qa.aws.mycompany.org
  DNS:*.apps.ocp-uswqa01.ocp-usw.qa.aws.mycompany.org

EKU:
  serverAuth

Key:
  RSA 2048 or stronger, or ECDSA if your MQ/client standards allow it

Format returned to Vault:
  tls.key
  tls.crt
  ca.crt
```

Notes:

```text
qmgr.mycompany.org belongs in this cert because clients use it.
qmgr.mycompany.org does not belong in the NHA or NHACRR cert unless those links use that hostname.
```

If clients connect using `qmgr.mycompany.org`, the OpenShift route must also be
created or configured to accept that host/SNI. A DNS CNAME to the router is not
enough by itself if the route host does not match.

## Profile 2: TMPQM001-NHA

Purpose:

```text
NativeHA internal pod-to-pod replication inside each OpenShift cluster.
```

Vault location:

```text
kv/data/mq/TMPQM001/nha-tls
```

MQ input path after init injection:

```text
/etc/mqm/ha/pki/keys/ha-vault/tls.key
/etc/mqm/ha/pki/keys/ha-vault/tls.crt
/etc/mqm/ha/pki/keys/ha-vault/ca.crt
```

MQ generated runtime keystore:

```text
/run/runmqserver/ha/tls/key.kdb
```

Recommended Venafi request:

```text
Profile: TMPQM001-NHA
CN:      TMPQM001-NHA

SAN:
  DNS:tmpqm001-nha.qa.aws.mycompany.org
  DNS:*.tmpqm001-use.svc
  DNS:*.tmpqm001-use.svc.cluster.local
  DNS:*.tmpqm001-usw.svc
  DNS:*.tmpqm001-usw.svc.cluster.local

EKU:
  serverAuth
  clientAuth

Key:
  RSA 2048 or stronger, or ECDSA if your MQ standards allow it

Format returned to Vault:
  tls.key
  tls.crt
  ca.crt
```

Notes:

```text
The OpenShift *.apps wildcard does not help NativeHA internal pod-to-pod traffic.
NativeHA does not use the external route hostnames for internal replica traffic.
```

If Venafi policy does not allow `.svc` or `.svc.cluster.local` names, use the
logical SAN only:

```text
DNS:tmpqm001-nha.qa.aws.mycompany.org
```

In this lab, MQ accepted the NativeHA TLS link based on the configured
certificate label, mutual trust chain, and MQ NativeHA TLS settings. The
effective MQ label was:

```text
CertificateLabel=ha-vault
```

## Profile 3: TMPQM001-NHACRR

Purpose:

```text
NativeHA CRR cross-region group-to-group TLS over the OpenShift nhacrr route.
```

Vault location:

```text
kv/data/mq/TMPQM001/nhacrr-tls
```

MQ input path after init injection:

```text
/etc/mqm/groupha/pki/keys/groupha/tls.key
/etc/mqm/groupha/pki/keys/groupha/tls.crt
/etc/mqm/groupha/pki/keys/groupha/ca.crt
/etc/mqm/groupha/pki/keys/ha-group/tls.key
/etc/mqm/groupha/pki/keys/ha-group/tls.crt
/etc/mqm/groupha/pki/keys/ha-group/ca.crt
/etc/mqm/groupha/pki/trust/remote/ca.crt
```

MQ generated runtime keystore:

```text
/run/runmqserver/ha/tls/key.kdb
```

Important:

```text
There is no separate CRR KDB. CRR material is merged into the NativeHA KDB.
```

Recommended Venafi request:

```text
Profile: TMPQM001-NHACRR
CN:      TMPQM001-NHACRR

SAN:
  DNS:tmpqm001-nhacrr.qa.aws.mycompany.org
  DNS:*.apps.ocp-useqa01.ocp-use.qa.aws.mycompany.org
  DNS:*.apps.ocp-uswqa01.ocp-usw.qa.aws.mycompany.org

EKU:
  serverAuth
  clientAuth

Key:
  RSA 2048 or stronger, or ECDSA if your MQ standards allow it

Format returned to Vault:
  tls.key
  tls.crt
  ca.crt
```

This covers CRR route hosts such as:

```text
tmpqm001-ibm-mq-nhacrr-tmpqm001-use.apps.ocp-useqa01.ocp-use.qa.aws.mycompany.org
tmpqm001-ibm-mq-nhacrr-tmpqm001-usw.apps.ocp-uswqa01.ocp-usw.qa.aws.mycompany.org
```

The QueueManager CR uses those route hosts in the remote group addresses:

```yaml
nativeHAGroups:
  remotes:
    - name: recovery
      addresses:
        - tmpqm001-ibm-mq-nhacrr-tmpqm001-usw.apps.ocp-uswqa01.ocp-usw.qa.aws.mycompany.org:443
```

and:

```yaml
nativeHAGroups:
  remotes:
    - name: live
      addresses:
        - tmpqm001-ibm-mq-nhacrr-tmpqm001-use.apps.ocp-useqa01.ocp-use.qa.aws.mycompany.org:443
```

## Final Mapping

```text
Vault app-pki       -> Venafi TMPQM001-APP     -> /etc/mqm/pki/keys/default
Vault nha-tls       -> Venafi TMPQM001-NHA     -> /etc/mqm/ha/pki/keys/ha-vault
Vault nhacrr-tls    -> Venafi TMPQM001-NHACRR  -> /etc/mqm/groupha/pki/keys/groupha
```

Runtime labels:

```text
QueueManager channel TLS label:  default
NativeHA internal TLS label:     ha-vault
NHACRR group TLS label:          groupha
```

Runtime KDB files:

```text
App/client TLS:
  /run/runmqserver/tls/key.kdb

NativeHA and NHACRR TLS:
  /run/runmqserver/ha/tls/key.kdb
```

## Maintenance Position

This keeps the operational model to three certificate profiles and three Vault
certificate sets per queue manager:

```text
TMPQM001-APP
TMPQM001-NHA
TMPQM001-NHACRR
```

The route wildcard SANs avoid adding every generated OpenShift route hostname to
the app and NHACRR certs. The tradeoff is blast radius: a wildcard route cert is
valid for any single-label route under that cluster apps domain, so Venafi policy
approval must allow that scope.

