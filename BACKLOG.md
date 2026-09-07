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
- [x] scaffold overlay `prod` architecture cible ajouté en V7 C1
- [x] scaffold overlay `preprod` architecture cible ajouté en V7 C1
- [ ] applications Argo CD preprod/prod lorsque les environnements existent
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
- [x] `startupProbe` Keycloak adaptée au démarrage Quarkus lent sur CRC
- [x] refresh JWK forcé à 5 s sur les resource servers OIDC du seul overlay CRC
- [x] validation runtime Keycloak outage/recovery (`V6 OK (phase B3)`, JWT existant utilisable, nouveau token indisponible pendant panne ; validation initiale 131/135 s, régression finale token/JWK 120/124 s)
- [x] externaliser l’état `mock-sct-inst` dans PostgreSQL partagé
- [x] passer `mock-sct-inst` à 2 replicas + PDB `minAvailable=1`
- [x] validation failover inter-pods SCT Inst (`V6 OK (phase B4)`: POST sur pod A, suppression pod A, GET/reconcile sur pod B, même `settlementId`, 1 rail row, 1 ledger settlement)
- [x] test panne Wero/EPI avant rail + `UNKNOWN` + anti-blind-replay ajouté
- [x] validation runtime Wero/EPI outage (`V6 OK (phase B5)`: `UNKNOWN`, rail=0, ledger=0, anti-blind-replay, Wero recovery 11 s lors de la régression finale, reconcile `NOT_FOUND -> UNKNOWN`, V4/V5 OK)
- [x] définir la politique de récupération contrôlée d’un `UNKNOWN` pré-rail : confirmation explicite + preflight rail `NOT_FOUND` + claim local exclusif avant resoumission
- [x] implémentation récupération contrôlée + état `RECOVERY_PENDING` + endpoint gateway + test B6 ajoutés
- [x] validation runtime récupération contrôlée (`V6 OK (phase B6)`: preflight `NOT_FOUND`, `RESUBMITTED -> SETTLED`, 1 rail row, 1 settlement ledger, `PAYMENT_RECOVERY_STARTED=1`, `PAYMENT_RECOVERED=1`, second recovery `ALREADY_FINAL`, Wero recovery 12 s lors de la régression finale)
- [x] tests retry/idempotence concurrente sous panne (`V6 OK (phase B7)`: 8 recoveries simultanées, exactement 1 `RESUBMITTED`; régression finale 2 `RECOVERY_ALREADY_CLAIMED` + 5 `RECOVERY_ALREADY_IN_PROGRESS`, avec `RECONCILED_WITHOUT_RESUBMIT` reconnu comme résultat concurrent sûr possible ; final 1 rail row, 1 settlement ledger, 1 `PAYMENT_RECOVERY_STARTED`, 1 `PAYMENT_RECOVERED`, 0 duplication)
- [x] modes dégradés (`V6 OK (phase B8)` : deux exécutions initiales puis régression finale. SCT Inst complet `2 -> 0` donne `UNKNOWN`, rail=0, ledger=0, aucun blind replay, reconcile `NOT_FOUND -> UNKNOWN`, recovery contrôlée unique ; RTO initiaux 14 s puis 12 s, régression finale 11 s. API Gateway complet `2 -> 0` rend reads/creates indisponibles sans side effect backend, puis retry intact `SETTLED` une fois ; RTO initiaux 16 s puis 11 s, régression finale 12 s)
- [x] régression finale V4/V5/V6 avant clôture CRC : phases A et B1-B8 repassées/confirmées, dernier `V4 OK` + `V5 OK`, Argo CD `Synced/Healthy`, workloads attendus Ready

## V7 — Cible HA production

### C1 — topologie OpenShift multi-node / multi-zone
- [x] branche `v7-production-ha-architecture` créée depuis la baseline V6 finale
- [x] overlay `gitops/overlays/preprod` créé dans le namespace cible `wero-poc-preprod`
- [x] preprod : 2 replicas pour les 6 workloads applicatifs, séparation worker et spread sur 2 zones
- [x] overlay `gitops/overlays/prod` créé dans le namespace cible `wero-poc-prod`
- [x] prod : 3 replicas pour les 6 workloads applicatifs N+1
- [x] anti-affinity stricte par `kubernetes.io/hostname`
- [x] topology spread par `topology.kubernetes.io/zone`, `maxSkew: 1`, `DoNotSchedule`
- [x] prod : `minDomains: 3`, PDB `minAvailable: 2`
- [x] preprod : `minDomains: 2`, PDB de base `minAvailable: 1`
- [x] CI Kustomize vérifie les rendus CRC, preprod et prod et l’absence de `Secret` dans le desired state
- [x] documentation `docs/architecture/13-production-ha-topology-v7-c1.md`
- [ ] validation runtime multi-worker / multi-zone sur un environnement OpenShift adapté

### C2 — PostgreSQL HA
- [ ] choisir l’architecture PostgreSQL HA selon les RPO/RTO métier
- [ ] supprimer le modèle production single Deployment + PVC unique
- [ ] failover contrôlé
- [ ] sauvegarde / restauration / PITR
- [ ] test de panne et mesure RTO/RPO

### C3 — Kafka/Redpanda HA
- [ ] architecture multi-broker
- [ ] réplication/quorum/storage
- [ ] perte d’un broker
- [ ] continuité Outbox / audit sous défaillance broker

### C4 — Keycloak HA
- [ ] Keycloak multi-replicas
- [ ] base Keycloak HA
- [ ] sessions / cache / clés de signature
- [ ] test perte pod / worker / zone IAM

### C5 — Ingress / LB / DNS HA
- [ ] routers/ingress HA
- [ ] load balancer multi-failure-domain
- [ ] DNS / health checks / certificats
- [ ] test perte d’un point d’entrée

### C6 — RTO/RPO métier
- [ ] définir RTO/RPO par capacité de paiement
- [ ] mapper les objectifs aux dépendances techniques
- [ ] définir SLI/SLO et critères de validation

### C7 — multi-site / PRA / runbooks
- [ ] stratégie multi-site
- [ ] réplication et bascule
- [ ] runbooks de reprise
- [ ] exercices de perte de site
- [ ] preuves de reprise et critères de retour au nominal

## V8 — Sandbox externe
- [ ] connecter un adaptateur externe de test si les prérequis sont disponibles
- [ ] conserver le mock local comme mode autonome
