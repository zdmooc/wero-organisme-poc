# Architecture V0 — Wero Organisme POC

## 1. Périmètre

Le laboratoire simule un écosystème Wero de bout en bout autour de **MayaBanque**.

Rôles modélisés :
- Client MayaBanque
- Application MayaBanque
- Consumer PSP
- Wero/EPI simulé
- Acceptor PSP
- Merchant
- SCT Inst simulé
- Banque bénéficiaire simulée

## 2. Principes d’architecture

1. Séparer orchestration Wero et mouvement financier SCT Inst.
2. Conserver un identifiant de transaction et une idempotency key de bout en bout.
3. Gérer explicitement les états `PENDING`, `SUCCESS`, `FAILED`, `UNKNOWN`.
4. Ne jamais faire de retry aveugle sur une opération financière.
5. Journaliser chaque transition métier.
6. Prévoir la réconciliation comme mécanisme de résilience.
7. Instrumenter chaque transaction avec un correlation-id.
8. Déployer sur OpenShift Local / CRC.

## 3. Flux logique

```text
Client
  |
  v
MayaBanque App
  |
  v
Consumer PSP
  |
  v
Wero/EPI Mock
  |          \
  |           \
  v            v
Acceptor PSP   SCT Inst Mock
  |              |
  v              v
Merchant       Beneficiary Bank Mock
```

## 4. Microservices cibles

- `consumer-psp`
- `acceptor-psp`
- `payment-service`
- `wallet-service`
- `proxy-alias-service`
- `fraud-service`
- `consent-service`
- `authorization-service`
- `capture-service`
- `refund-service`
- `ledger-service`
- `reconciliation-service`
- `notification-service`

## 5. Services de plateforme

- PostgreSQL
- Kafka/Redpanda
- Keycloak
- OpenTelemetry
- Prometheus
- Grafana
- Jaeger
- Argo CD

## 6. Premier scénario fonctionnel

Le premier scénario implémenté sera le **Single Immediate Payment** :

```text
Create Payment
  -> Consent
  -> Authorization
  -> Capture
  -> Settlement
  -> SUCCESS
```

## 7. Scénarios de résilience futurs

- réponse perdue après traitement
- webhook dupliqué
- webhook absent
- timeout EPI
- retry non idempotent
- panne Kafka
- panne DB
- panne Consumer PSP
- panne Acceptor PSP
- panne SCT Inst simulée
- perte d’un pod
- perte d’un namespace/service

## 8. Statut

V0 : conception initiale. Aucun composant métier n’est encore implémenté.
