# Wero Organisme POC

POC d’architecture de paiement Wero de bout en bout, exécuté localement sur OpenShift Local (CRC).

## Convention principale

- Banque simulée : **MayaBanque**
- Aucun nom de banque réelle dans le code, les namespaces ou les diagrammes du POC
- Wero/EPI, Consumer PSP, Acceptor PSP, SCT Inst et Merchant sont modélisés comme rôles génériques
- Le dépôt est un laboratoire d’architecture et de résilience, pas une reproduction d’un SI bancaire réel

## Objectifs

1. Comprendre Wero de bout en bout : P2P, e-commerce, consent, authorization, capture, settlement, refund.
2. Implémenter un parcours complet autour de MayaBanque.
3. Déployer les composants sur OpenShift Local / CRC.
4. Étudier API, événements, sécurité, fraude, ledger et réconciliation.
5. Tester les erreurs : timeout, retry, duplicate, UNKNOWN, webhook perdu, panne service, panne messaging, panne data.
6. Identifier les SPOF et expérimenter les remédiations.
7. Construire progressivement une cible HA/résiliente et documenter les ADR.

## Chaîne actuellement implémentée

```text
Client
  |
  v
OpenShift Route
  |
  v
API Gateway -- JWT/RBAC --> Keycloak
  |
  v
Payment Service --> PostgreSQL / Ledger / Outbox
  |
  v
Consumer PSP
  |
  v
Wero/EPI Mock
  |
  v
SCT Inst Mock --> PostgreSQL shared settlement store

Outbox --> Kafka/Redpanda --> Event Audit

OpenTelemetry --> Jaeger
Metrics -------> Prometheus --> Grafana
Git ------------> OpenShift GitOps / Argo CD --> OpenShift desired state
```

## Stack du lab

- OpenShift Local / CRC
- Java 21 + Quarkus
- REST / OpenAPI
- Kafka/Redpanda
- PostgreSQL
- Keycloak OAuth2/OIDC
- API Gateway
- OpenTelemetry + Prometheus + Grafana + Jaeger
- Kustomize
- Red Hat OpenShift GitOps / Argo CD

## Structure

```text
docs/                documentation d’architecture
services/            microservices du POC
mocks/               Wero/EPI et SCT Inst simulés
platform/            bootstrap OpenShift par itération
gitops/              desired state Kustomize + Argo CD
tests/               E2E, sécurité, observabilité, GitOps, résilience
```

## Roadmap

- V0 : cadrage et architecture de référence — terminé
- V1 : Single Immediate E2E — validé CRC
- V2 : état, ledger et réconciliation — validé CRC
- V2B : Kafka, outbox et audit — validé CRC
- V3A : Keycloak, JWT/RBAC, consentement et SCA — validé CRC
- V3B : API Gateway et isolation Zero Trust — validé CRC
- V4 : observabilité E2E — validé CRC
- V5 : GitOps / Kustomize / OpenShift GitOps / Argo CD — validé CRC
- V6 : SPOF, chaos, HA et résilience — phases A, B1, B2, B3, B4 et B5 validées CRC ; B6 implémentée, validation CRC en attente
- V7 : branchement optionnel à un sandbox externe lorsque possible

## V5 GitOps

Git est l’autorité du desired state pour les ressources runtime. L’Application Argo CD `wero-poc-crc` synchronise automatiquement, prune et self-heal.

Les secrets restent hors Git. Le build des images reste séparé du deployment plane ; la cible de production sera une promotion par image immutable/digest via pull request.

Voir `docs/architecture/07-gitops-argocd-v5.md`.

## V6 Resilience

La phase A a mis en N+1 cinq workloads initialement stateless : `api-gateway`, `payment-service`, `consumer-psp`, `event-audit-service` et `mock-wero`. Ils tournent à deux replicas avec un `PodDisruptionBudget` `minAvailable=1` et ont survécu à la suppression d’un pod sur CRC.

Les phases B1 à B3 ont ensuite validé la récupération PostgreSQL sur le même PVC, le buffering/replay transactionnel Outbox pendant une indisponibilité Kafka et le mode dégradé IAM avec JWT déjà émis pendant une panne Keycloak.

La phase B4 a supprimé le SPOF fonctionnel de `mock-sct-inst` : son état de settlement est maintenant partagé dans PostgreSQL, le mock tourne à deux replicas avec PDB, et un paiement ayant été settlé sur un pod a été réconcilié depuis `UNKNOWN` par un autre pod après suppression du premier, avec le même `settlementId`, une seule ligne rail et une seule écriture ledger.

La phase B5 a validé la panne Wero/EPI avant rail : le paiement passe `UNKNOWN`, SCT Inst reste à 0 ligne, aucun settlement ledger n’est créé, la même idempotency key ne provoque aucun blind replay pendant ni après la panne, Wero revient à deux replicas en 11 s et la réconciliation `NOT_FOUND` conserve `UNKNOWN`.

B6 introduit une récupération explicite de ce cas pré-rail : confirmation opérateur obligatoire, preflight SCT Inst `NOT_FOUND`, claim atomique local `UNKNOWN -> RECOVERY_PENDING`, puis une seule resoumission contrôlée. Aucun `UNKNOWN` arbitraire n’est automatiquement rejoué. Le code et le test B6 sont présents dans la branche mais doivent encore être validés sur CRC.

PostgreSQL, Kafka/Redpanda et Keycloak restent des dépendances mono-instance dans ce lab. CRC étant mono-nœud, ces validations couvrent des pannes de pod/processus et des indisponibilités contrôlées, pas une panne de nœud, zone ou site.

Voir :
- `docs/architecture/08-spof-chaos-ha-v6.md`
- `docs/architecture/09-sct-inst-shared-state-v6-b4.md`
- `docs/architecture/10-wero-outage-controlled-recovery-v6-b5-b6.md`
