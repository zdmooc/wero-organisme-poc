# Wero Organisme POC

POC d’architecture de paiement Wero/EPI de bout en bout autour d’une banque simulée **MayaBanque**.

Le dépôt sert de laboratoire d’architecture, de GitOps, de sécurité, d’observabilité et de résilience. Il ne reproduit pas un SI bancaire réel et ne contient aucune donnée bancaire réelle.

## Convention principale

- Banque simulée : **MayaBanque**
- Wero/EPI, Consumer PSP, Acceptor PSP, SCT Inst et Merchant sont modélisés comme rôles génériques
- aucun secret runtime dans Git
- CRC sert au lab local et aux preuves mono-nœud
- les architectures multi-worker / multi-zone / multi-site ne sont déclarées validées qu’après preuve sur une infrastructure adaptée

## Chaîne fonctionnelle

```text
Client
  |
  v
OpenShift Route / Frontdoor
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

## Stack

### Lab CRC

- OpenShift Local / CRC
- Java 21 + Quarkus
- PostgreSQL
- Kafka/Redpanda
- Keycloak OAuth2/OIDC
- OpenTelemetry, Prometheus, Grafana, Jaeger
- Kustomize
- Red Hat OpenShift GitOps / Argo CD

### Cible V7 production HA

- OpenShift multi-worker / multi-zone
- CloudNativePG
- Redpanda Operator, 3 brokers, TLS + SASL/SCRAM + ACL
- Keycloak Operator + base IAM dédiée
- OpenShift IngressController shardé preprod/prod
- TLS public API + re-encrypt Keycloak
- ApplicationSets Argo CD provider-neutral
- promotion d’images par digest
- RTO/RPO + SLI/SLO
- PRA deux sites actif / secours chaud contrôlé

## Structure

```text
docs/                documentation d’architecture et runbooks
services/            microservices du POC
mocks/               Wero/EPI et SCT Inst simulés
platform/            bootstrap OpenShift par itération
gitops/              desired state Kustomize + Argo CD
tests/               E2E, sécurité, observabilité, GitOps, résilience, production-readiness
scripts/             outils de préparation/promotion
```

## Roadmap

- V0 : cadrage et architecture de référence — terminé
- V1 : Single Immediate E2E — validé CRC
- V2 : état, ledger et réconciliation — validé CRC
- V2B : Kafka, outbox et audit — validé CRC
- V3A : Keycloak, JWT/RBAC, consentement et SCA — validé CRC
- V3B : API Gateway et isolation Zero Trust — validé CRC
- V4 : observabilité E2E — validé CRC
- V5 : GitOps / Kustomize / OpenShift GitOps / Argo CD — validé CRC ; contrats production complétés en V7
- V6 : SPOF / chaos / résilience — **terminée et validée sur CRC** pour A + B1-B8
- V7 : cible HA production — **design, Git, CI et runbooks terminés dans la limite du travail réalisable sans infrastructure réelle**
- V8 : sandbox externe — optionnelle, à connecter lorsque les prérequis existent ; le mock local reste autonome

## V6 — preuve CRC terminée

V6 a validé sur CRC :

- workloads stateless en N+1 et PDB ;
- récupération PostgreSQL sur le même PVC ;
- Outbox pendant panne Kafka puis drain ;
- mode dégradé Keycloak ;
- état SCT Inst partagé et failover inter-pods ;
- panne Wero avant rail avec `UNKNOWN` et absence de blind replay ;
- récupération contrôlée `UNKNOWN -> RECOVERY_PENDING -> SETTLED` après preflight rail `NOT_FOUND` ;
- exclusion concurrente B7 avec exactement un winner de recovery ;
- modes dégradés SCT Inst / API Gateway ;
- régression finale `V4 OK` + `V5 OK` avec Argo CD `Synced/Healthy`.

Les mesures CRC restent des preuves de panne pod/processus sur un cluster mono-nœud, pas des preuves de panne worker/zone/site.

Docs V6 :

- `docs/architecture/08-spof-chaos-ha-v6.md`
- `docs/architecture/09-sct-inst-shared-state-v6-b4.md`
- `docs/architecture/10-wero-outage-controlled-recovery-v6-b5-b6.md`
- `docs/architecture/11-concurrent-controlled-recovery-v6-b7.md`
- `docs/architecture/12-degraded-modes-v6-b8.md`

## V7 — cible HA production

### C1 — OpenShift multi-node / multi-zone

Preprod cible 2 replicas/2 zones ; prod cible 3 replicas/3 zones, anti-affinity worker, topology spread et PDB. Le rendu Kustomize est validé ; la panne réelle worker/zone reste à tester.

Voir `docs/architecture/13-production-ha-topology-v7-c1.md`.

### C2 — PostgreSQL HA

CloudNativePG remplace le PostgreSQL lab dans preprod/prod. Le cluster paiement cible 3 instances et une réplication synchrone vers au moins un standby :

```yaml
postgresql:
  synchronous:
    method: any
    number: 1
    dataDurability: required
```

La configuration vise une durabilité compatible avec RPO=0 intra-site pour les commits acquittés sous les pannes couvertes ; seule une preuve runtime pourra valider le RPO/RTO obtenu.

Backup/WAL/PITR sont documentés ; le provider object storage et les tests restore/PITR dépendent de l’infrastructure.

Voir :

- `docs/architecture/14-postgresql-ha-v7-c2.md`
- `docs/architecture/15-postgresql-backup-pitr-v7-c2.md`

### C3 — Redpanda HA

La cible définit 3 brokers, RF=3, `min.insync.replicas=2`, rack awareness, TLS + SASL/SCRAM, ACL least-privilege et topic `payment-events` à 3 partitions.

Les clients Kafka construits manuellement dans `payment-service` et `event-audit-service` acceptent désormais la configuration TLS/SASL, tout en conservant CRC en PLAINTEXT par défaut.

Voir :

- `docs/architecture/16-redpanda-ha-v7-c3.md`
- `docs/architecture/17-redpanda-security-clients-v7-c3.md`

### C4 — Keycloak HA

La cible utilise Keycloak Operator, plusieurs instances, cache distribué, PDB et une base IAM CloudNativePG dédiée. Le contrat OIDC interne `http://keycloak:8080` est conservé pour ne pas imposer une refonte Java. Le bootstrap realm est one-shot et hors overlays continus.

Voir :

- `docs/architecture/18-keycloak-ha-v7-c4.md`
- `docs/architecture/19-keycloak-ha-v7-c4-implementation.md`

### C5 — Frontdoor / LB / DNS / TLS

La cible définit :

- 2 routers preprod / 3 routers prod ;
- shards `preprod-public` / `prod-public` ;
- seulement deux Routes publiques : API Gateway et Keycloak ;
- API Gateway en TLS edge + redirect ;
- Keycloak en TLS re-encrypt vers 8443 ;
- certificat backend via OpenShift service-ca ;
- NetworkPolicies provider-neutral API Gateway / Keycloak ;
- observabilité non publique par défaut.

Les vrais DNS, certificats publics, LB, node placement et labels réseau restent à fournir par l’environnement.

Voir :

- `docs/architecture/20-ingress-lb-dns-tls-ha-v7-c5.md`
- `docs/architecture/21-ingress-lb-dns-tls-ha-v7-c5-implementation.md`

### C6 — RTO / RPO / SLI / SLO

Les objectifs candidats et les critères de preuve sont définis dans `docs/architecture/22-rto-rpo-sli-slo-v7-c6.md`.

Exemples de budgets candidats :

- API/frontdoor et DB paiement intra-site : RTO <= 60 s ;
- nouveaux tokens IAM : RTO <= 120 s ;
- Redpanda : RTO service <= 120 s ;
- audit : convergence <= 300 s ;
- perte complète de site : RTO <= 30 min, RPO <= 5 min candidat.

Ce ne sont **pas des SLA contractuels**. Ils doivent être validés métier/SRE et alimentés par les mesures réelles.

Évaluateur : `tests/production/test-v7-rto-rpo-evidence.sh`.

### C7 — PRA multi-site

La stratégie retenue est deux sites avec **un seul site writer paiement à un instant donné** : actif / secours chaud contrôlé.

Le design couvre fencing, promotion PostgreSQL, stratégie Redpanda Shadowing ou recovery, IAM, frontdoor, réconciliation et failback. Le runbook interdit une bascule si le double-writer ne peut pas être exclu.

Voir :

- `docs/architecture/23-multisite-pra-v7-c7.md`
- `docs/runbooks/v7-site-failover.md`
- `tests/production/test-v7-dr-readiness.sh`

## GitOps production-readiness

Le dépôt contient désormais :

- `gitops/argocd/applicationset-v7-environments.yaml` pour preprod/prod/ingress sans URL ni credential de cluster dans Git ;
- AppProject étendu aux namespaces cibles ;
- `scripts/prepare-v7-image-promotion.sh` pour préparer une promotion des 6 images par digest `sha256` réel ;
- `docs/architecture/24-gitops-promotion-v7.md` ;
- `docs/architecture/25-progressive-delivery-v7.md` avec Argo Rollouts comme cible future ;
- workflows CI dédiés C4, C5, C6/C7 et GitOps production-readiness.

Aucun faux digest, faux DNS, faux certificat, faux endpoint de cluster ou secret runtime n’est commité.

## Ce qui reste — uniquement infrastructure / validation métier

Le dépôt est maintenant arrivé au point où les travaux restants exigent un environnement réel :

- OpenShift multi-worker / multi-zone ;
- Operators et secrets réels ;
- registry, digests, signature/scanning/admission ;
- object storage CNPG + backup/PITR ;
- Redpanda runtime 3 brokers ;
- DNS/LB/certificats/node placement ;
- exécution des pannes C1-C5 ;
- validation métier/SRE des objectifs C6 ;
- second site/cluster et exercice PRA C7 ;
- activation/test Argo Rollouts en preprod.

Voir `BACKLOG.md` : toutes les tâches restantes sont explicitement marquées **INFRA** ou **MÉTIER/INFRA**.
