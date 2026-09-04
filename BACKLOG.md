# Backlog — Wero Organisme POC

## V0 — Socle
- [x] Initialiser le dépôt
- [x] Définir MayaBanque comme banque simulée
- [x] Définir l’architecture logique initiale
- [x] Ajouter le projet OpenShift `wero-poc`
- [ ] Ajouter les namespaces/projets logiques si séparation nécessaire
- [ ] Ajouter conventions de nommage et labels
- [ ] Ajouter ADR-001 : choix Java 21 + Quarkus
- [ ] Ajouter ADR-002 : Kafka/Redpanda
- [ ] Ajouter ADR-003 : PostgreSQL

## V1 — Single Immediate Payment
- [ ] `payment-service`
- [ ] `consumer-psp`
- [ ] `mock-epi-wero`
- [ ] `mock-sct-inst`
- [ ] API OpenAPI
- [ ] état transactionnel
- [ ] idempotency key
- [ ] correlation-id
- [ ] tests E2E

## V2 — Event Driven / Ledger / Réconciliation
- [ ] Kafka/Redpanda
- [ ] ledger-service
- [ ] reconciliation-service
- [ ] outbox/inbox pattern
- [ ] gestion UNKNOWN
- [ ] replay contrôlé

## V3 — Sécurité
- [ ] Keycloak
- [ ] OAuth2/OIDC
- [ ] mTLS interne si pertinent
- [ ] secrets management
- [ ] fraud-service

## V4 — Observabilité
- [ ] OpenTelemetry
- [ ] Prometheus
- [ ] Grafana
- [ ] Jaeger
- [ ] dashboard transaction E2E

## V5 — GitOps
- [ ] Argo CD
- [ ] overlays/dev
- [ ] overlays/test
- [ ] progressive delivery

## V6 — SPOF / Résilience
- [ ] catalogue SPOF
- [ ] kill pod
- [ ] timeout EPI
- [ ] webhook perdu/dupliqué
- [ ] panne DB
- [ ] panne Kafka
- [ ] tests de retry/idempotence
- [ ] scénarios de reprise

## V7 — Sandbox externe
- [ ] connecter un adaptateur externe de test si les prérequis sont disponibles
- [ ] conserver le mock local comme mode autonome
