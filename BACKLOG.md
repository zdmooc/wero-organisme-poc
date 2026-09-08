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
- [x] mécanisme de promotion par image immutable/digest préparé dans `scripts/prepare-v7-image-promotion.sh` ; vrais digests à fournir par le registry réel
- [x] scaffold overlay `prod` architecture cible ajouté en V7 C1
- [x] scaffold overlay `preprod` architecture cible ajouté en V7 C1
- [x] ApplicationSets provider-neutral preprod/prod + ingress ajoutés ; enregistrement des vrais clusters Argo CD reste infra-dépendant
- [x] progressive delivery conçue avec Argo Rollouts dans `docs/architecture/25-progressive-delivery-v7.md`
- [ ] activer/tester Argo Rollouts sur un vrai preprod après installation Operator, métriques SLO et images digest

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

> **Statut dépôt : design / Git / CI / runbooks terminés dans la limite de ce qui est faisable sans infrastructure réelle.** Les cases restantes ci-dessous requièrent explicitement un vrai OpenShift multi-worker/multi-zone, des services d’infrastructure ou deux sites.

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
- [ ] **INFRA** validation runtime perte worker / zone sur OpenShift multi-worker / multi-zone

### C2 — PostgreSQL HA
- [x] architecture de référence CloudNativePG choisie
- [x] composant CNPG `mayabank-postgresql` à 3 instances avec anti-affinity worker et secret applicatif externe à Git
- [x] modèle lab `Deployment postgresql + PVC unique + Service postgresql` supprimé des rendus preprod/prod
- [x] preprod : cluster CNPG 3 instances avec spread sur 2 zones
- [x] prod : cluster CNPG 3 instances avec spread sur 3 zones
- [x] `payment-service`, `event-audit-service` et `mock-sct-inst` pointent vers `mayabank-postgresql-rw` sans modification Java
- [x] cible C6 de durabilité : réplication synchrone vers 1 standby (`any / 1 / dataDurability=required`)
- [x] CI Kustomize vérifie le cluster CNPG, l’endpoint RW, l’absence de l’ancien PostgreSQL et l’absence de Secrets runtime
- [x] lab C2-F1 de failover primaire ajouté dans `tests/production/test-v7-cnpg-failover.sh` et syntaxe validée par CI
- [x] architecture backup / WAL / PITR définie avec Barman Cloud CNPG-I Plugin dans `docs/architecture/15-postgresql-backup-pitr-v7-c2.md`
- [ ] **INFRA** sélectionner le provider object storage et créer l’`ObjectStore`, credentials externes et `ScheduledBackup`
- [ ] **INFRA** exécuter C2-F1/F2/F3/F4 : primaire, worker, standby, switchover et mesurer RTO
- [ ] **INFRA** exécuter C2-F5 restore et C2-F6 PITR dans un cluster de récupération séparé
- [ ] **INFRA** mesurer le RPO réel et confronter les résultats aux objectifs C6

### C3 — Kafka/Redpanda HA
- [x] architecture de référence Redpanda Operator 3 brokers définie dans `docs/architecture/16-redpanda-ha-v7-c3.md`
- [x] scaffold `cluster.redpanda.com/v1alpha2` / `Redpanda` créé pour Redpanda `v26.2.2`
- [x] cible 3 brokers, PVC persistants `20Gi` placeholder et rack awareness `topology.kubernetes.io/zone`
- [x] politique cible `default_topic_replications=3` et `minimum_topic_replications=3`
- [x] TLS activé, SASL/SCRAM activé, Admin API authentifiée et secrets/certificats référencés hors Git
- [x] `Topic/payment-events` défini à 3 partitions, replication factor 3 et `min.insync.replicas=2`
- [x] identités least-privilege `payment-producer` et `event-audit-consumer` avec ACL topic/group déclarées
- [x] contrat CA/credentials/bootstrap documenté dans `docs/architecture/17-redpanda-security-clients-v7-c3.md`
- [x] `payment-service` et `event-audit-service` transmettent les propriétés TLS/SASL à leurs clients Kafka construits manuellement ; CRC conserve `PLAINTEXT` par défaut
- [x] producer Outbox conserve `acks=all`, idempotence Kafka et clé `paymentId` pour l’ordre par paiement
- [x] preprod/prod incluent Redpanda HA sécurisé et suppriment le `Deployment/Service kafka` du lab
- [x] CI vérifie Redpanda HA, TLS/SASL, topic RF3/minISR2, users/ACL, overlays et absence de `Secret` runtime
- [x] stratégie DR Redpanda mappée à C7 : Shadowing Enterprise si disponible, sinon recovery avec RTO/RPO explicites
- [ ] **INFRA** provisionner `redpanda-superusers`, secrets SCRAM/JAAS et `redpanda-client-ca`
- [ ] **INFRA** vérifier en runtime partitions/RF/ISR, auth/ACL et disponibilité `acks=all`
- [ ] **INFRA** exécuter perte broker/worker/zone/decommission, mesurer leaderless/URP/RTO/outbox/consumer lag
- [ ] **INFRA** confirmer continuité Outbox/audit et absence de duplication logique sous panne broker

### C4 — Keycloak HA
- [x] architecture Keycloak Operator `v2beta1` + production mode définie dans `docs/architecture/18-keycloak-ha-v7-c4.md`
- [x] implémentation C4 documentée dans `docs/architecture/19-keycloak-ha-v7-c4-implementation.md`
- [x] composant `gitops/components/keycloak-ha` créé : Keycloak, base IAM dédiée et PDB explicite
- [x] preprod : 2 instances Keycloak, anti-affinity worker, spread 2 domaines workers/zones, PDB `minAvailable=1`
- [x] prod : 3 instances Keycloak, anti-affinity worker, spread 3 domaines workers/zones, PDB `minAvailable=2`
- [x] base IAM CloudNativePG dédiée `mayabank-keycloak-postgresql` à 3 instances, endpoint RW role-aware et cible synchrone vers 1 standby
- [x] Secret DB `keycloak-db` référencé hors Git ; aucun credential runtime ajouté au desired state
- [x] contrat OIDC interne `http://keycloak:8080` conservé via `spec.http.serviceName/serviceHttpPort`
- [x] anciens `Deployment/Service/Route keycloak` du lab retirés des rendus preprod/prod ; CRC reste inchangé
- [x] production mode / cache distribué Infinispan + découverte `jdbc-ping` documentés comme cible
- [x] bootstrap realm one-shot `gitops/bootstrap/keycloak/mayabanque-realm-import.yaml` ajouté hors overlays continus, sans mot de passe dans Git
- [x] CI dédiée C4 + gate global contrôlent composant, scheduling, PDB, service interne, DB IAM et absence de `Secret`
- [x] frontdoor C5 Git/render défini et IAM mappé aux objectifs C6
- [ ] **INFRA** provisionner Keycloak Operator/CRDs, `keycloak-db` et bootstrap admin externe
- [ ] **INFRA** exécuter C4-F1..F6 : perte pod/worker/zone/DB IAM/rolling update/bootstrap frais
- [ ] **INFRA** vérifier login/session/refresh-token/discovery/JWK/signing keys et mesurer IAM RTO/RPO

### C5 — Ingress / LB / DNS / TLS HA
- [x] architecture provider-neutral documentée dans `docs/architecture/20-ingress-lb-dns-tls-ha-v7-c5.md`
- [x] implémentation C5 documentée dans `docs/architecture/21-ingress-lb-dns-tls-ha-v7-c5-implementation.md`
- [x] IngressController public preprod : 2 routers, shard `preprod-public`
- [x] IngressController public prod : 3 routers, shard `prod-public`
- [x] `domain`, `defaultCertificate`, `endpointPublishingStrategy` et `nodePlacement` laissés à l’environnement réel
- [x] composant `gitops/components/frontdoor-ha` limité à `api-gateway-public` et `keycloak-public`
- [x] Routes lab/admin observabilité retirées des cibles C5
- [x] API Gateway TLS `edge` + redirect ; Keycloak TLS `reencrypt` vers 8443
- [x] certificat backend Keycloak par contrat OpenShift `service-ca` sans `Secret` commité
- [x] overlays C5 `preprod-c5` et `prod-c5`
- [x] NetworkPolicies provider-neutral frontdoor API Gateway/Keycloak ajoutées ; ingress namespace, OIDC interne et metrics internes explicités
- [x] CI dédiée `.github/workflows/ci-v7-frontdoor.yml`
- [x] runbook C5-F1 `tests/production/test-v7-ingress-failover.sh` dry-run par défaut
- [x] scénarios C5 mappés aux objectifs C6
- [ ] **INFRA** provisionner domaine, hostnames, publication/LB, certificats publics et node placement
- [ ] **INFRA** confirmer les labels/chemins réseau réels et le modèle d’accès admin observabilité ; adapter les NetworkPolicies si nécessaire
- [ ] **INFRA** exécuter C5-F1..F6 : router, worker, zone, LB, rotation certificat, DNS/failover
- [ ] **INFRA** vérifier issuer/discovery/token/JWK via le vrai hostname HTTPS et mesurer les fenêtres d’erreur

### C6 — RTO/RPO métier
- [x] objectifs RTO/RPO candidats par capacité documentés dans `docs/architecture/22-rto-rpo-sli-slo-v7-c6.md`
- [x] dépendances techniques C1-C7 mappées aux objectifs
- [x] SLI/SLO candidats et critères d’acceptation définis
- [x] cible PostgreSQL paiement synchrone vers 1 standby alignée avec le RPO=0 intra-site candidat
- [x] évaluateur non destructif `tests/production/test-v7-rto-rpo-evidence.sh` ajouté
- [x] CI `.github/workflows/ci-v7-continuity.yml` valide les contrats C6/C7
- [ ] **MÉTIER/INFRA** faire valider les objectifs candidats par les responsables métier/SRE ; ils ne sont pas des SLA contractuels
- [ ] **INFRA** alimenter l’évaluateur avec les mesures réelles C1-C5/C7 et produire les preuves finales

### C7 — multi-site / PRA / runbooks
- [x] stratégie deux sites actif / secours chaud contrôlé définie dans `docs/architecture/23-multisite-pra-v7-c7.md`
- [x] règle anti split-brain : un seul site accepte les écritures paiement
- [x] architecture DR CNPG paiement/IAM, Redpanda Shadowing ou recovery, Keycloak standby et frontdoor définie
- [x] ordre de bascule/fencing/réconciliation/failback documenté
- [x] runbook `docs/runbooks/v7-site-failover.md` ajouté
- [x] check non destructif `tests/production/test-v7-dr-readiness.sh` ajouté
- [x] objectifs PRA candidats RTO <=30 min / RPO <=5 min mappés à C6 sans les présenter comme preuves
- [ ] **INFRA** provisionner le second cluster/site, réseau inter-site, object storage et mécanisme Redpanda retenu
- [ ] **INFRA** exécuter un exercice perte de site complet avec fencing, promotion, frontdoor et réconciliation
- [ ] **INFRA** conserver les preuves RTO/RPO, absence de double settlement et réaliser un exercice de failback

### Clôture V7 sans infrastructure
- [x] ApplicationSets preprod/prod/ingress provider-neutral dans `gitops/argocd/applicationset-v7-environments.yaml`
- [x] AppProject étendu aux namespaces preprod/prod/ingress sans URL/credential de cluster en Git
- [x] mécanisme de promotion immutable/digest documenté et scripté dans `docs/architecture/24-gitops-promotion-v7.md`
- [x] design progressive delivery Argo Rollouts dans `docs/architecture/25-progressive-delivery-v7.md`
- [x] CI dédiée `V7 GitOps production-readiness contracts`
- [x] tous les travaux réalisables honnêtement sans infrastructure réelle sont consignés ; les tâches restantes sont marquées **INFRA** ou **MÉTIER/INFRA**

## V8 — Sandbox externe
- [ ] connecter un adaptateur externe de test si les prérequis sont disponibles
- [x] conserver le mock local comme mode autonome