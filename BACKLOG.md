# Backlog — Wero Organisme POC

## V0 — Socle
- [x] Initialiser le dépôt
- [x] Définir MayaBanque comme banque simulée
- [x] Définir l’architecture logique initiale
- [x] Ajouter le projet OpenShift `wero-poc`

## V1 — Single Immediate Payment
- [x] `payment-service`
- [x] `consumer-psp`
- [x] `mock-wero`
- [x] `mock-sct-inst`
- [x] paiement E2E `SETTLED`
- [x] `paymentId` de bout en bout
- [x] tests CRC

## V2 — State / Ledger / Réconciliation
- [x] état transactionnel
- [x] idempotency key
- [x] ledger
- [x] gestion `UNKNOWN`
- [x] status query / réconciliation
- [x] tests CRC

## V2B — Event Driven
- [x] Kafka/Redpanda
- [x] transactional outbox
- [x] audit consumer
- [x] déduplication événement
- [x] replay contrôlé
- [x] tests CRC

## V3A — Sécurité / Consentement
- [x] Keycloak
- [x] OAuth2/OIDC JWT
- [x] RBAC
- [x] consentement lié au paiement et au principal
- [x] SCA simulée
- [x] secrets hors Git
- [x] tests CRC

## V3B — API Gateway / Zero Trust
- [x] API Gateway unique
- [x] token relay + revalidation backend
- [x] suppression des Routes backend
- [x] NetworkPolicy gateway-only
- [x] tests CRC

## V4 — Observabilité
- [x] OpenTelemetry
- [x] propagation `X-Correlation-Id`
- [x] continuité de trace HTTP + Outbox/Kafka
- [x] Prometheus
- [x] Grafana
- [x] Jaeger
- [x] dashboard transaction E2E
- [x] tests CRC

## V5 — GitOps
- [x] Kustomize base
- [x] overlay CRC
- [x] AppProject Argo CD
- [x] Application Argo CD
- [x] automated sync
- [x] prune
- [x] self-heal
- [x] desired state runtime complet dans Git
- [x] secrets exclus du desired state Git
- [x] test de drift automatique ajouté
- [x] CI de rendu Kustomize ajoutée
- [x] validation runtime CRC V5 (`V4 OK` + `V5 OK`)
- [ ] promotion par image immutable/digest
- [ ] overlays preprod/prod lorsque ces environnements existeront
- [ ] progressive delivery dans une itération dédiée

## V6 — SPOF / Résilience
### Phase A — pod HA sur CRC
- [x] catalogue SPOF initial
- [x] 2 replicas pour les 5 workloads réellement stateless
- [x] PDB `minAvailable=1` pour les 5 workloads stateless
- [x] `mock-sct-inst` reclassé stateful car settlement en mémoire
- [x] bootstrap GitOps V6
- [x] test kill-pod + mesure du temps de récupération ajouté
- [x] régression V5 paramétrable avec `api-gateway replicas=2`
- [x] timeout healthy-path CRC ajusté après observation du dépassement de 2 s sous charge N+1
- [x] restauration automatique des credentials de démonstration Keycloak après restart du pod
- [x] validation runtime CRC phase A (`V6 OK (phase A)`)

### Phase B — stateful / dépendances
- [x] test PostgreSQL pod-restart + persistance PVC + mesure RTO/RPO observé ajouté
- [x] validation runtime PostgreSQL recovery (`V6 OK (phase B1)`, 36 s, même PVC, 0 ligne sélectionnée perdue)
- [x] panne Kafka + backlog outbox + drain après reprise
- [x] validation runtime Kafka/Outbox (`V6 OK (phase B2)`, backlog 3, 2 tentatives échouées, drain 3/3 en 7 s, audit exactement-une-fois logique)
- [x] découverte Prometheus par pod pour les workloads N+1
- [x] test panne Keycloak + JWT existant / nouveau token ajouté
- [ ] validation runtime Keycloak outage/recovery
- [ ] externaliser ou redéfinir l’état de `mock-sct-inst` avant N+1
- [ ] timeout Wero/EPI + état `UNKNOWN`
- [ ] panne SCT Inst + réconciliation
- [ ] tests retry/idempotence sous panne
- [ ] modes dégradés

### Phase C — cible HA production
- [ ] anti-affinity/topology spread multi-node
- [ ] HA PostgreSQL
- [ ] Kafka/Redpanda multi-broker
- [ ] Keycloak clusterisé + DB HA
- [ ] HA ingress/LB/DNS
- [ ] RTO/RPO cibles métier
- [ ] multi-site / PRA
- [ ] runbooks de reprise

## V7 — Sandbox externe
- [ ] connecter un adaptateur externe de test si les prérequis sont disponibles
- [ ] conserver le mock local comme mode autonome
