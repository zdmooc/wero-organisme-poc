# V3A — Security, consent and SCA

## Goal

V3A secures the V2B payment chain with a local IAM layer and introduces an explicit payment consent bound to the payment payload before execution.

This is an educational MayaBanque POC. It is not an implementation of the official Wero/EPI security specification and the SCA challenge is simulated.

## Architecture

```text
Client
  |
  | OpenID Connect / JWT
  v
Keycloak (realm: mayabanque)
  |
  +--> roles
  |     - payment-create
  |     - payment-read
  |     - payment-reconcile
  |     - consent-create
  |     - consent-sca
  |     - audit-read
  |
  v
payment-service
  |-- consent + SCA state in PostgreSQL
  |-- payment + ledger + transactional outbox
  |
  v
consumer-psp -> mock-wero -> mock-sct-inst
  |
  v
Kafka -> event-audit-service (audit-read protected API)
```

## Consent state machine

```text
PENDING_SCA
   | correct challenge
   v
AUTHORIZED

PENDING_SCA -- 3 invalid attempts --> LOCKED
PENDING_SCA -- expiry -------------> EXPIRED
```

The consent is bound to:

- authenticated JWT subject
- paymentId
- amountCents
- currency
- creditorAlias

A new payment is rejected unless the consent is still valid, is `AUTHORIZED`, belongs to the authenticated subject and exactly matches those payment attributes.

## Idempotency interaction

Consent is checked for the first execution of a new payment. Once a payment has been accepted, an exact replay using the same `Idempotency-Key` returns the existing result and does not trigger a second payment or a second SCA.

## RBAC model

`alice` is the POC payment identity and receives the create/read/reconcile/consent/SCA roles. `auditor` receives only `payment-read` and `audit-read`.

Passwords are not committed to Git. The deployment script generates demo credentials at runtime and stores them in OpenShift Secrets.

## Secrets

Runtime data is injected from OpenShift Secrets:

- Keycloak bootstrap administrator credentials
- PostgreSQL application credentials
- demo identity credentials
- SCA demo code

No real banking credential or payment data belongs in this repository.

## Keycloak profile

V3A uses Keycloak in `start-dev` mode on OpenShift Local/CRC only. It is intentionally not a production IAM deployment. Production would require TLS, durable database, HA, hardened hostname/proxy configuration, credential rotation, backup/restore and operational monitoring.

## V3A validation target

The E2E test verifies:

1. request without JWT -> `401`
2. read-only identity attempting consent creation -> `403`
3. consent creation -> `PENDING_SCA`
4. payment before SCA -> `403`
5. successful SCA -> `AUTHORIZED`
6. authorized payment -> `SETTLED`
7. replay remains idempotent
8. payment retains `consentId`
9. Kafka audit is still consumed and its HTTP API requires `audit-read`

## Still outside V3A

The following remain subsequent V3 increments:

- API gateway / policy enforcement point
- fraud/risk service and decision rules
- real SCA/authenticator integration
- token exchange / service-to-service identities
- mTLS
- Vault or external secrets manager
- production Keycloak HA
- authorization policies by merchant, device, geography and transaction risk
