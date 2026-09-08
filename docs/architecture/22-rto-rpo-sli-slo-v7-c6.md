# V7 C6 — RTO / RPO métier, SLI / SLO et critères d'acceptation

## Statut

**Design C6 défini. Les valeurs ci-dessous sont des objectifs d'architecture candidats, pas des SLA contractuels ni des preuves runtime.**

Ils doivent être validés par le métier / Product Owner et confrontés aux mesures C1-C5 puis C7.

## Principes

1. Un paiement confirmé au client ne doit jamais être recréé à l'aveugle après incident.
2. L'idempotence métier, la réconciliation rail et le transactional outbox restent des mécanismes de sûreté indépendants de la HA d'infrastructure.
3. RPO=0 n'est revendiqué que pour un périmètre où l'écriture synchrone et la preuve de panne l'établissent réellement.
4. Le PRA site est traité séparément de la HA intra-site.
5. Les dépendances de support, notamment l'observabilité, peuvent avoir des objectifs moins stricts que le chemin de paiement.

## Objectifs candidats

| Capacité | RTO cible intra-site | RPO cible intra-site | SLO disponibilité candidat | Critère principal |
|---|---:|---:|---:|---|
| API publique paiement / statut | <= 60 s | N/A | 99,95 % | HTTPS disponible et réponses métier cohérentes |
| Création / état paiement dans PostgreSQL | <= 60 s | 0 pour commit acquitté | 99,95 % | 1 primaire, service RW convergé, aucune ligne métier perdue |
| Paiement `SETTLED` / ledger | <= 60 s | 0 pour commit acquitté | 99,95 % | même `paymentId`, même résultat financier, aucune duplication rail |
| Récupération contrôlée `UNKNOWN` | <= 300 s | 0 logique | 99,90 % | aucun blind replay, exactement une resoumission contrôlée si rail `NOT_FOUND` |
| Outbox / Redpanda / audit | <= 120 s service, <= 300 s convergence audit | 0 logique depuis outbox commitée | 99,90 % | backlog drainé, consumer lag revenu sous seuil, pas de duplication logique |
| OIDC / émission de nouveaux tokens | <= 120 s | 0 pour données IAM commitée intra-site | 99,90 % | discovery/token/JWK cohérents, JWT existants tolérés durant indisponibilité courte |
| Frontdoor API / Keycloak | <= 60 s | N/A | 99,95 % | perte d'un router sans interruption au-delà du budget |
| Observabilité | <= 900 s | best effort / rétention à définir | 99,50 % | non bloquante pour le paiement |
| Perte complète du site primaire | <= 30 min | <= 5 min candidat | à valider | reprise contrôlée sur site DR + réconciliation avant retour aux écritures |

## Décision C6 pour PostgreSQL paiement

Le cluster `mayabank-postgresql` vise désormais une réplication synchrone vers au moins un standby :

```yaml
postgresql:
  synchronous:
    method: any
    number: 1
    dataDurability: required
```

Conséquence : un commit PostgreSQL ne doit être acquitté que lorsqu'au moins un standby synchrone l'a reçu. Cela fournit une **cible de durabilité intra-cluster** compatible avec RPO=0 sous les pannes couvertes, mais la cible reste à prouver en runtime.

Le compromis est explicite : si aucun standby synchrone n'est disponible, la disponibilité des écritures peut être sacrifiée au profit de la durabilité.

## Redpanda / Outbox

C3 conserve :

- `acks=all` ;
- idempotence Kafka ;
- RF=3 ;
- `min.insync.replicas=2` ;
- clé Kafka = `paymentId` ;
- transactional outbox PostgreSQL comme source de reprise logique.

C6 ne transforme pas ces paramètres en RPO=0 inter-site. Ils définissent le budget intra-site à vérifier sous perte broker/worker/zone.

## Keycloak

Objectifs séparés :

- JWT déjà émis : continuer à être validables tant que leurs clés sont connues et le token reste valide ;
- nouveaux tokens : RTO candidat <= 120 s ;
- données IAM persistées : dépendance à la DB IAM CloudNativePG ;
- sessions : comportement à mesurer explicitement pendant les scénarios C4 et C7.

## SLI à collecter

### Paiement

- taux de succès API ;
- p95 / p99 de création et lecture paiement ;
- temps `PROCESSING -> SETTLED` ;
- nombre / ratio de paiements `UNKNOWN` ;
- `duplicate rail rows` = 0 ;
- `settlement ledger duplicates` = 0 ;
- nombre de récupérations contrôlées et resoumissions.

### PostgreSQL

- temps d'élection / promotion ;
- temps de convergence du service `-rw` ;
- replication lag ;
- nombre de standbys synchrones ;
- perte de lignes métier observée ;
- succès restore / PITR.

### Redpanda

- leaderless partitions ;
- under-replicated partitions ;
- ISR ;
- producer error rate ;
- consumer lag ;
- âge du plus ancien outbox pending ;
- temps de drain après reprise.

### IAM

- disponibilité OIDC discovery ;
- token endpoint success rate ;
- JWK endpoint success rate ;
- login / refresh success rate ;
- temps de convergence après perte pod/DB/router.

### Frontdoor

- disponibilité HTTPS API et OIDC ;
- 5xx router ;
- handshake TLS ;
- temps de bascule router/LB/DNS selon le scénario.

## Mapping des preuves

| Preuve | Objectif C6 alimenté |
|---|---|
| C1 perte worker / zone | disponibilité workloads et budget 60 s |
| C2-F1..F6 | PostgreSQL RTO/RPO, restore/PITR |
| C3-F1..F4 | Redpanda RTO, ISR, lag, continuité Outbox/Audit |
| C4-F1..F6 | IAM RTO, session, token, JWK |
| C5-F1..F6 | frontdoor RTO, TLS, LB/DNS |
| C7 site failover | RTO/RPO PRA et retour au nominal |

## Critères de clôture C6

Le design C6 est clôturable dans Git lorsque :

- les objectifs candidats sont documentés ;
- les SLI sont définis ;
- les scripts d'évidence peuvent comparer des mesures aux budgets ;
- chaque scénario C1-C7 est mappé à un critère.

La **validation C6 production** reste ouverte tant que les mesures d'un environnement multi-worker/multi-zone et du site DR n'existent pas.
