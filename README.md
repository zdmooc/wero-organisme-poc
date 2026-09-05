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
SCT Inst Mock

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
- V5 : GitOps / Kustomize / OpenShift GitOps / Argo CD — implémentation prête, validation CRC en cours
- V6 : SPOF, chaos, HA et résilience
- V7 : branchement optionnel à un sandbox externe lorsque possible

## V5 GitOps

Git devient l’autorité du desired state pour les ressources runtime. L’Application Argo CD `wero-poc-crc` pointe vers `gitops/overlays/crc` avec synchronisation automatique, prune et self-heal.

Les secrets restent hors Git. Le build des images reste séparé du deployment plane ; la cible de production sera une promotion par image immutable/digest via pull request.

Voir `docs/architecture/07-gitops-argocd-v5.md`.
