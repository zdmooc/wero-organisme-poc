# V7 C3 — Redpanda security and Kafka client contract

## Status

**Architecture + GitOps desired state defined and render-validated. Runtime multi-broker validation is still open.**

This document closes the C3 client/security design boundary for the MayaBanque POC. It does not claim production HA evidence from CRC.

## Security target

The target Redpanda cluster uses:

- TLS for Kafka transport encryption;
- SASL with SCRAM-SHA-512 for client authentication;
- Redpanda ACLs for least-privilege authorization;
- authenticated Admin API;
- runtime secrets and CA material outside Git.

The repository renders references to secret names only. It never stores passwords, JAAS credentials or private keys.

## Kafka endpoint model

Redpanda's internal Kafka listener uses the broker identities exposed through the headless Service. The target bootstrap lists are explicit so clients can discover and connect directly to partition leaders.

### Preproduction

```text
redpanda-0.redpanda.wero-poc-preprod.svc.cluster.local:9093,
redpanda-1.redpanda.wero-poc-preprod.svc.cluster.local:9093,
redpanda-2.redpanda.wero-poc-preprod.svc.cluster.local:9093
```

### Production

```text
redpanda-0.redpanda.wero-poc-prod.svc.cluster.local:9093,
redpanda-1.redpanda.wero-poc-prod.svc.cluster.local:9093,
redpanda-2.redpanda.wero-poc-prod.svc.cluster.local:9093
```

CRC remains on its existing single-broker lab endpoint and PLAINTEXT mode. V7 client support defaults to `PLAINTEXT` unless an environment explicitly supplies the secured settings.

## Runtime secret contract

The target environment must provision these resources outside Git.

### `redpanda-superusers`

Referenced by the Redpanda cluster bootstrap/auth configuration. Its exact population is owned by the target secret-management process and Redpanda Operator deployment procedure.

### `redpanda-payment-producer`

Required keys:

```text
password
jaas-config
```

- `password` is consumed by the Redpanda `User/payment-producer` resource.
- `jaas-config` is consumed by `payment-service` as `KAFKA_SASL_JAAS_CONFIG`.
- both values must describe the same SCRAM identity and password.

The JAAS value conceptually represents:

```text
ScramLoginModule required username="payment-producer" password="<runtime-secret>";
```

The real value is never committed or printed by tests.

### `redpanda-event-audit-consumer`

Required keys:

```text
password
jaas-config
```

The SCRAM principal is `event-audit-consumer`. The same consistency rule applies between `password` and `jaas-config`.

### `redpanda-client-ca`

Required key:

```text
ca.crt
```

This is the stable application-facing trust contract. The target platform must populate/synchronize it from the CA that signs the Redpanda internal Kafka certificates. The generic repository deliberately does not guess an Operator-generated certificate Secret name or a production certificate issuer.

Applications mount it read-only at:

```text
/etc/redpanda-ca/ca.crt
```

## Client configuration

Both custom Kafka clients now accept the standard security properties through MicroProfile Config and copy them into the Kafka client `Properties` object.

Target environment values:

```text
KAFKA_SECURITY_PROTOCOL=SASL_SSL
KAFKA_SASL_MECHANISM=SCRAM-SHA-512
KAFKA_SASL_JAAS_CONFIG=<from runtime Secret>
KAFKA_SSL_TRUSTSTORE_TYPE=PEM
KAFKA_SSL_TRUSTSTORE_LOCATION=/etc/redpanda-ca/ca.crt
```

`KAFKA_BOOTSTRAP_SERVERS` is environment-specific and uses the three internal broker FQDNs shown above.

### Payment Outbox producer

`payment-service` keeps the correctness settings already present before C3:

```text
acks=all
enable.idempotence=true
```

Each produced record is keyed by `paymentId`. With the target `payment-events` topic split across three partitions, events for the same payment continue to map to one Kafka partition and therefore keep per-payment ordering.

The producer identity has only:

- `Write` on topic `payment-events`;
- `Describe` on topic `payment-events`.

### Event Audit consumer

`event-audit-service` keeps:

```text
group.id=payment-audit-v1
enable.auto.commit=false
```

The consumer identity has only:

- `Read` + `Describe` on topic `payment-events`;
- `Read` on consumer group `payment-audit-v1`.

## Topic target

The Operator-managed `Topic/payment-events` desired state is:

```text
partitions = 3
replicationFactor = 3
min.insync.replicas = 2
```

This is configuration intent, not proof of durability. Runtime validation must demonstrate broker placement, replica health, leader election, ISR behavior and application continuity.

## Preprod/prod migration

Both V7 overlays now:

1. include `gitops/components/redpanda-ha`;
2. remove the V6 `Deployment kafka` dev-container;
3. remove the V6 `Service kafka`;
4. configure `payment-service` for the producer SCRAM identity;
5. configure `event-audit-service` for the audit consumer SCRAM identity;
6. mount the external CA contract;
7. leave all secret material outside Git.

No other application consumes Kafka directly in the current POC.

## Code impact

The custom producer and consumer previously built raw Kafka `Properties` and therefore ignored global Quarkus Kafka security properties.

C3 adds targeted forwarding of:

- `security.protocol`;
- `sasl.mechanism`;
- `sasl.jaas.config`;
- `ssl.truststore.type`;
- `ssl.truststore.location`.

Only these components require rebuild for C3 runtime testing:

```text
services/payment-service
services/event-audit-service
```

No rebuild is needed for `api-gateway`, `consumer-psp`, `mock-wero` or `mock-sct-inst` due to C3 client security.

## Runtime validation still required

C3 is not complete as production HA evidence until an appropriate multi-worker environment proves at least:

1. all three brokers Ready with independent persistent volumes;
2. `payment-events` has RF=3 and healthy replicas/ISR;
3. producer can authenticate only with its allowed identity;
4. audit consumer can authenticate only with its allowed identity/group;
5. wrong credentials and unauthorized operations are rejected;
6. deleting one broker does not lose committed `payment-events` data;
7. producer resumes/continues with `acks=all` under one-broker loss when quorum/ISR permits;
8. audit consumer continues and does not duplicate logical audit rows;
9. Outbox backlog drains after broker recovery;
10. observed interruption/RTO and partition/ISR evidence are recorded;
11. worker/zone loss is tested separately from simple pod deletion;
12. disaster-recovery requirements are mapped later to C6/C7.

## Evidence boundary

CI currently proves only that:

- CRC still renders independently;
- preprod and prod render the secured Redpanda target;
- the old lab Kafka deployment is absent from those target overlays;
- Redpanda has three brokers, TLS/SASL and RF=3 intent;
- `payment-events`, users and ACLs are present;
- no runtime Secret manifest is committed;
- the two Java Kafka clients compile with security-property forwarding.

It does **not** prove broker failover, zone HA, certificate issuance, credential provisioning, RTO/RPO or production SLA.
