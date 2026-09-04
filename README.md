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

## Architecture logique initiale

```text
Client MayaBanque
      |
      v
MayaBanque App
      |
      v
Consumer PSP
      |
      v
Wero/EPI Mock
      |
      +-------------------+
      |                   |
      v                   v
Acceptor PSP          SCT Inst Mock
      |                   |
      v                   v
Merchant             Banque bénéficiaire simulée
```

## Stack cible du lab

- OpenShift Local / CRC
- Java 21 + Quarkus
- REST / OpenAPI
- Kafka ou Redpanda pour les événements
- PostgreSQL pour l’état transactionnel et le ledger
- Keycloak pour OAuth2/OIDC
- API Gateway à introduire dans une itération ultérieure
- OpenTelemetry + Prometheus + Grafana + Jaeger
- Argo CD / GitOps

## Structure

```text
docs/                documentation d’architecture
apps/                interfaces utilisateur
services/            microservices du POC
mocks/                Wero/EPI et SCT Inst simulés
platform/             OpenShift, Kafka, IAM, observabilité, GitOps
tests/                E2E, résilience et chaos
```

## Roadmap

- V0 : cadrage, architecture de référence et structure OpenShift
- V1 : paiement immédiat E2E
- V2 : Kafka, ledger, statuts et réconciliation
- V3 : sécurité, fraude et IAM
- V4 : observabilité transactionnelle
- V5 : GitOps
- V6 : SPOF, pannes et résilience
- V7 : branchement optionnel à un sandbox externe lorsque possible

## Statut

**V0 — Initialisation du référentiel**
