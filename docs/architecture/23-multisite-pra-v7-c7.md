# V7 C7 — Multi-site / PRA / continuité d'activité

## Statut

**Architecture PRA définie, non déployée.**

La cible V7 privilégie un modèle **deux sites, actif / secours chaud contrôlé** pour le chemin de paiement. Le choix évite un double writer métier et réduit le risque de split-brain / double soumission au rail.

## Topologie cible

```text
Clients
  |
Global traffic manager / LB / DNS
  |
  +--> Site A OpenShift (ACTIVE)
  |      - API Gateway / services
  |      - PostgreSQL paiement primaire HA
  |      - Redpanda primaire HA
  |      - Keycloak
  |
  +--> Site B OpenShift (DR / WARM STANDBY)
         - mêmes artefacts GitOps
         - PostgreSQL replica clusters / backups
         - Redpanda shadow / recovery target selon licence
         - Keycloak standby
```

Règle métier : **un seul site accepte les écritures paiement à un instant donné**.

## GitOps

Les deux clusters doivent être indépendants et enregistrés dans Argo CD avec des labels d'environnement / rôle. Les manifests ne contiennent ni URL de cluster privée ni credential.

Le même commit applicatif doit pouvoir reconstruire le site DR ; les paramètres secrets, DNS, certificats, storage class et endpoints inter-sites restent fournis par la plateforme.

## PostgreSQL paiement et IAM

CloudNativePG fournit le mécanisme de `replica cluster` entre clusters Kubernetes via streaming et/ou WAL archive. La cible C7 utilise :

- Site A : cluster primaire HA intra-site ;
- Site B : replica cluster autonome ;
- object storage externe pour backups + WAL ;
- promotion du Site B uniquement après décision de bascule ;
- retour arrière contrôlé, jamais deux primaires écrivant simultanément.

La réplication inter-site peut être asynchrone selon latence / architecture réseau : le RPO PRA doit donc être mesuré et ne doit pas être confondu avec le RPO=0 intra-site visé par la réplication synchrone locale.

## Redpanda

Deux stratégies sont documentées :

### Option A — Shadowing Redpanda Enterprise

Redpanda Shadowing fournit une réplication asynchrone, offset-preserving, active/passive entre clusters distincts. Pour Kubernetes, le mécanisme peut être géré via l'Operator / `ShadowLink`.

Cette option est la cible préférée lorsque la licence et le réseau inter-site sont disponibles.

### Option B — restauration / reconstruction

Sans Shadowing/licence adaptée, le dépôt ne revendique pas un PRA Redpanda quasi temps réel. La stratégie devient restauration à partir de stockage objet / procédures de recovery, avec un RTO/RPO plus faible et à mesurer.

Le transactional outbox PostgreSQL reste la protection métier : après failover, le consumer / broker ne doit jamais provoquer une duplication logique des paiements.

## Keycloak

Le PRA MayaBanque reste initialement actif/passif au niveau du service global.

Keycloak 26 propose aussi une architecture multi-site dédiée à deux sites avec réplication synchrone et sessions persistantes. Cette architecture ne doit être revendiquée que si ses prérequis de latence, base synchrone inter-site et cache externe sont réellement déployés.

Dans V7, le site DR Keycloak est donc traité comme un standby à valider avec sa DB IAM DR. La continuité exacte des sessions doit être mesurée.

## Frontdoor

La bascule globale doit :

1. arrêter / isoler l'ancien chemin d'écriture ;
2. vérifier la santé du site DR ;
3. promouvoir les dépendances stateful requises ;
4. ouvrir les écritures sur le site DR ;
5. basculer LB/DNS/GTM ;
6. vérifier OIDC puis paiement ;
7. lancer la réconciliation des paiements `UNKNOWN` / en cours.

Le mécanisme exact de GSLB/LB/DNS reste provider-neutral et sera fourni par l'infrastructure.

## Ordre de reprise

1. Décision d'incident / déclaration du site A indisponible.
2. Fencing du site A : aucune écriture paiement ne doit rester possible.
3. Vérification Site B OpenShift / Operators / storage / secrets.
4. PostgreSQL paiement : mesurer lag, promouvoir le replica DR.
5. PostgreSQL IAM / Keycloak : rendre l'IAM cohérent et Ready.
6. Redpanda : Shadowing failover ou recovery documenté.
7. Applications stateless : Synced / Healthy.
8. Frontdoor : activer le site B.
9. Smoke tests OIDC, statut paiement, création contrôlée.
10. Réconciliation de tous les paiements non finaux.
11. Surveillance renforcée et gel des changements non nécessaires.

## Anti split-brain

Aucune bascule n'est autorisée si l'équipe ne peut pas démontrer que le site A n'accepte plus d'écritures, sauf procédure exceptionnelle explicitement approuvée.

Le retour au site A est une opération distincte : resynchronisation, contrôle d'écart, nouveau fencing, puis failback planifié.

## Objectifs candidats

- RTO site : <= 30 minutes ;
- RPO inter-site : <= 5 minutes candidat ;
- 0 double soumission rail ;
- 0 perte silencieuse d'un résultat financier connu ;
- tous les écarts locaux vs rail passent par la réconciliation.

Ces valeurs sont des objectifs C6/C7 à tester, pas des résultats obtenus.

## Preuves requises

- timestamp de dernière réplication PostgreSQL avant bascule ;
- lag Redpanda / ShadowLink si utilisé ;
- état des clusters Argo CD ;
- statut Keycloak / OIDC ;
- temps de fencing ;
- temps de promotion DB ;
- temps d'ouverture du frontdoor DR ;
- RTO bout en bout ;
- RPO calculé ;
- liste des paiements non finaux et résultat de réconciliation ;
- preuve qu'aucun `paymentId` n'a généré plus d'un settlement rail.

## Limite

C7 peut être clôturé côté **architecture, runbook et automatisation de readiness** sans infrastructure. La preuve PRA nécessite deux clusters / sites et ne peut pas être simulée honnêtement sur CRC.
