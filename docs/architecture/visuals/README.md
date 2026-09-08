# Visuels d’architecture — Wero Organisme POC

Série de **10 visuels grand format paysage (SVG 1600×900)** couvrant le POC MayaBanque Wero/EPI de bout en bout, depuis le socle fonctionnel jusqu’à la cible HA/PRA V7.

> Les visuels distinguent explicitement les preuves obtenues sur OpenShift Local / CRC des architectures de production préparées mais non encore validées sur une infrastructure multi-worker / multi-zone / multi-site.

## Série

1. [Vue d’ensemble](./01-overview-landscape.svg) — contexte MayaBanque, chaîne de paiement, résultat V6 CRC et préparation V7.
2. [Architecture end-to-end](./02-e2e-architecture-landscape.svg) — flux métier, sécurité, persistance, événements, observabilité et GitOps.
3. [GitOps et déploiement](./03-gitops-deployment-landscape.svg) — Git, Kustomize, Argo CD, CRC, preprod et prod.
4. [V0 à V5 — construction du socle](./04-v0-to-v5-landscape.svg) — cadrage, parcours nominal, sécurité, intégrations, observabilité et GitOps.
5. [V6 — Phase A, B1, B2, B3](./05-v6-a-b1-b2-b3-landscape.svg) — N+1/PDB, PostgreSQL recovery, Kafka/Outbox et Keycloak outage.
6. [V6 — B4, B5, B6](./06-v6-b4-b5-b6-landscape.svg) — SCT Inst shared state, panne Wero et controlled recovery.
7. [V6 — B7 et B8](./07-v6-b7-b8-landscape.svg) — concurrence/idempotence et modes dégradés.
8. [Bilan V6 CRC](./08-v6-crc-summary-landscape.svg) — preuves, limites et métriques observées.
9. [V7 — C1 à C5](./09-v7-c1-to-c5-landscape.svg) — OpenShift HA, PostgreSQL HA, Redpanda HA, Keycloak HA et Frontdoor HA.
10. [V7 — C6, C7 et prochaines étapes](./10-v7-c6-c7-next-steps-landscape.svg) — RTO/RPO, PRA multi-site et validations restantes quand l’infrastructure sera disponible.

## Usage

Ces visuels sont destinés à :

- présenter le POC en entretien ou soutenance ;
- expliquer l’architecture de paiement de bout en bout ;
- montrer les preuves V6 sans sur-vendre les limites CRC ;
- présenter la trajectoire vers une architecture HA production ;
- servir de support aux futures campagnes de tests preprod/prod.

## Statut

- V6 CRC : preuves applicatives et de dépendances contrôlées terminées.
- V7 C1–C7 : design, GitOps, CI, sécurité, runbooks et readiness préparés.
- Restant : validations **INFRA** / **MÉTIER+INFRA** sur les environnements réels.
- PR #8 et PR #9 : aucune fusion automatique depuis cette série de visuels.
