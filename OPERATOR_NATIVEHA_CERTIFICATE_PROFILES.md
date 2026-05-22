# IBM MQ Operator NativeHA Certificate Profiles

This document is for a standard IBM MQ Operator deployment that uses
OpenShift/Kubernetes Secrets for TLS material.

It does not assume a Vault init container, injected PEM mounts, or custom runtime
label overrides.

## Scope

Deployment shape:

```text
Queue manager name: TMPQM001
USE cluster apps wildcard: *.apps.ocp-useqa01.ocp-use.qa.aws.mycompany.org
USW cluster apps wildcard: *.apps.ocp-uswqa01.ocp-usw.qa.aws.mycompany.org
```

Target IBM MQ Operator pattern:

```text
spec.queueManager.availability.type: NativeHA
spec.queueManager.availability.tls.secretName: <secret>
spec.queueManager.availability.nativeHAGroups.local.tls.key.secretName: <secret>
```

IBM MQ Operator expects TLS key material through Kubernetes Secrets. The Secret
must contain the standard TLS files:

```text
tls.key
tls.crt
ca.crt
```

## Final Recommendation

Use three certificate profiles:

```text
TMPQM001-APP
TMPQM001-NHA
TMPQM001-NHACRR
```

These profiles map to three OpenShift Secret purposes:

```text
APP cert     -> client / application MQ route
NHA cert     -> NativeHA internal pod-to-pod TLS
NHACRR cert  -> Cross-region NativeHA group replication TLS
```

## Wildcard Rule

The wildcard:

```text
*.apps.ocp-useqa01.ocp-use.qa.aws.mycompany.org
```

matches:

```text
tmpqm001-ibm-mq-qm-tmpqm001-use.apps.ocp-useqa01.ocp-use.qa.aws.mycompany.org
tmpqm001-ibm-mq-nhacrr-tmpqm001-use.apps.ocp-useqa01.ocp-use.qa.aws.mycompany.org
```

It does not match:

```text
tmpqm001-ibm-mq.tmpqm001-use.svc.cluster.local
qmgr.mycompany.org
x.y.apps.ocp-useqa01.ocp-use.qa.aws.mycompany.org
*.apps.ocp-uswqa01.ocp-usw.qa.aws.mycompany.org
```

So the `*.apps...` wildcard helps for OpenShift route hosts. It does not cover
Kubernetes internal service names or external CNAMEs outside the apps domain.

## Profile 1: TMPQM001-APP

Purpose:

```text
TLS for MQ client/application traffic.
```

Use this for:

```text
QueueManager route
SVRCONN channels
Application connectivity
Client-facing CNAMEs such as qmgr.mycompany.org
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
  RSA 2048 or stronger

Output:
  tls.key
  tls.crt
  ca.crt
```

OpenShift Secret example:

```bash
oc create secret generic tmpqm001-app-tls \
  -n tmpqm001-use \
  --from-file=tls.key=./tls.key \
  --from-file=tls.crt=./tls.crt \
  --from-file=ca.crt=./ca.crt
```

QueueManager usage depends on how the MQ channels and route are configured. This
certificate is for application-facing TLS, not NativeHA replication.

Important:

```text
If applications connect to qmgr.mycompany.org, that exact DNS name must be in this cert SAN.
Do not rely on *.apps... to cover qmgr.mycompany.org.
```

## Profile 2: TMPQM001-NHA

Purpose:

```text
TLS for NativeHA pod-to-pod communication inside each OpenShift cluster.
```

This is local to the NativeHA group. It is not the app/client cert and it is not
the cross-region CRR cert.

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
  RSA 2048 or stronger

Output:
  tls.key
  tls.crt
  ca.crt
```

OpenShift Secret example:

```bash
oc create secret generic tmpqm001-nha-tls \
  -n tmpqm001-use \
  --from-file=tls.key=./tls.key \
  --from-file=tls.crt=./tls.crt \
  --from-file=ca.crt=./ca.crt
```

QueueManager NativeHA usage:

```yaml
spec:
  queueManager:
    availability:
      type: NativeHA
      tls:
        secretName: tmpqm001-nha-tls
        cipherSpec: ANY_TLS12_OR_HIGHER
```

Notes:

```text
The OpenShift *.apps... wildcard does not help NativeHA internal pod-to-pod TLS.
NativeHA internal traffic is not application route traffic.
```

If your Venafi policy does not allow `.svc` or `.svc.cluster.local`, keep the
logical DNS SAN only:

```text
DNS:tmpqm001-nha.qa.aws.mycompany.org
```

IBM MQ NativeHA validates TLS through the configured NativeHA TLS material and
trust chain. For hostname-based validation concerns, align the SANs with the
actual names used by the MQ Operator-generated NativeHA endpoints.

## Profile 3: TMPQM001-NHACRR

Purpose:

```text
TLS for NativeHA Cross-Region Replication between the live and recovery groups.
```

This cert is used for the `nhacrr` route, not the application `qm` route.

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
  RSA 2048 or stronger

Output:
  tls.key
  tls.crt
  ca.crt
```

This covers the typical Operator-generated `nhacrr` route hosts:

```text
tmpqm001-ibm-mq-nhacrr-tmpqm001-use.apps.ocp-useqa01.ocp-use.qa.aws.mycompany.org
tmpqm001-ibm-mq-nhacrr-tmpqm001-usw.apps.ocp-uswqa01.ocp-usw.qa.aws.mycompany.org
```

OpenShift Secret example:

```bash
oc create secret generic tmpqm001-nhacrr-tls \
  -n tmpqm001-use \
  --from-file=tls.key=./tls.key \
  --from-file=tls.crt=./tls.crt \
  --from-file=ca.crt=./ca.crt
```

QueueManager CRR usage:

```yaml
spec:
  queueManager:
    availability:
      type: NativeHA
      nativeHAGroups:
        local:
          name: live
          role: Live
          tls:
            key:
              secretName: tmpqm001-nhacrr-tls
        remotes:
          - name: recovery
            enabled: true
            addresses:
              - tmpqm001-ibm-mq-nhacrr-tmpqm001-usw.apps.ocp-uswqa01.ocp-usw.qa.aws.mycompany.org:443
```

For the recovery side, the remote address points back to the USE `nhacrr` route:

```yaml
addresses:
  - tmpqm001-ibm-mq-nhacrr-tmpqm001-use.apps.ocp-useqa01.ocp-use.qa.aws.mycompany.org:443
```

Important:

```text
qmgr.mycompany.org does not belong in the NHACRR cert unless CRR remotes use that hostname.
```

## Shared Cert vs Region-Specific Cert

To keep maintenance small with only three profiles, use one cert per profile that
contains both USE and USW route wildcard SANs.

That means:

```text
TMPQM001-APP cert has both USE and USW apps wildcards.
TMPQM001-NHA cert has internal names for both USE and USW namespaces, if allowed.
TMPQM001-NHACRR cert has both USE and USW apps wildcards.
```

This reduces operational overhead but increases wildcard blast radius. If your
security team rejects broad wildcard coverage, use the same three profiles but
issue region-specific certificates from each profile.

## Final Mapping

```text
TMPQM001-APP
  Use for client/application MQ TLS.
  Include qmgr.mycompany.org and both cluster apps wildcards.

TMPQM001-NHA
  Use for NativeHA internal pod-to-pod TLS.
  Include logical NHA DNS and internal .svc names if allowed.
  Do not rely on *.apps... for this profile.

TMPQM001-NHACRR
  Use for cross-region CRR TLS.
  Include both cluster apps wildcards.
  Do not include qmgr.mycompany.org unless CRR uses qmgr.mycompany.org.
```

