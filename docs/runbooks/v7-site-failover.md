# Runbook V7 — bascule PRA Site A -> Site B

## Portée

Runbook de référence. Il ne doit être exécuté qu'après adaptation aux vrais clusters, LB/DNS, secrets, storage et procédures d'exploitation.

## Conditions d'entrée

- incident Site A confirmé ;
- décision de bascule approuvée ;
- Site B accessible ;
- propriétaires métier / exploitation identifiés ;
- canaux d'incident ouverts ;
- horodatage T0 enregistré.

## 1. Fencer le site A

Objectif : empêcher toute nouvelle écriture paiement sur le site supposé perdu ou partiellement joignable.

- retirer Site A du frontdoor global ;
- bloquer les créations paiement si un chemin réseau résiduel subsiste ;
- confirmer l'absence de trafic write entrant ;
- enregistrer l'heure de fencing.

**STOP** si le double-writer ne peut pas être exclu.

## 2. Vérifier Site B

- cluster OpenShift disponible ;
- Operators CNPG / Redpanda / Keycloak présents ;
- Argo CD accessible ;
- secrets/certificats requis présents sans les afficher ;
- storage sain ;
- routes / ingress préparés mais non encore ouverts aux clients.

## 3. PostgreSQL paiement

- observer le dernier WAL / lag connu ;
- calculer le RPO potentiel ;
- promouvoir le replica cluster selon la procédure CNPG validée ;
- vérifier exactement un primaire ;
- vérifier `mayabank-postgresql-rw` ;
- lancer un contrôle de lecture cohérente ledger/outbox.

## 4. IAM

- promouvoir / rendre disponible la DB IAM ;
- vérifier Keycloak Ready ;
- vérifier discovery, JWK et token endpoint via le chemin interne ;
- ne pas afficher de credentials dans les traces de runbook.

## 5. Redpanda

Si Shadowing est disponible :

- vérifier l'état du ShadowLink et son lag ;
- effectuer le failover selon la procédure Redpanda ;
- confirmer que le site source ne peut plus recevoir les clients write ;
- vérifier topic `payment-events`, ACL et offsets.

Sinon :

- appliquer la procédure de recovery prévue ;
- enregistrer le RPO/RTO plus faible ;
- ne pas revendiquer une continuité quasi temps réel.

## 6. Applications

- Argo `Synced/Healthy` ;
- replicas attendus Ready ;
- DB endpoints / Kafka bootstrap / OIDC résolus ;
- aucune Route admin/observabilité rendue publique par accident.

## 7. Ouvrir le frontdoor DR

- activer LB/GTM/DNS pour Site B ;
- vérifier certificat et issuer Keycloak ;
- mesurer le premier succès HTTPS API ;
- mesurer le premier succès OIDC.

## 8. Smoke tests paiement

Ordre minimal :

1. lecture d'un paiement existant connu ;
2. vérification ledger ;
3. création d'un nouveau paiement de test ;
4. confirmation `SETTLED` ;
5. vérification exactement 1 rail row et 1 settlement ledger ;
6. vérification audit / Outbox.

## 9. Réconciliation

- lister les paiements non finaux autour de T0 ;
- interroger le rail avant toute resoumission ;
- `SETTLED/FAILED` rail -> réconcilier sans resoumettre ;
- `NOT_FOUND` -> conserver `UNKNOWN` jusqu'à récupération contrôlée ;
- jamais de blind replay.

## 10. Mesures

Enregistrer :

- T0 incident ;
- T-fence ;
- T-DB ;
- T-IAM ;
- T-Kafka ;
- T-frontdoor ;
- T-payment-success ;
- RTO bout en bout ;
- RPO observé ;
- duplications rail = 0 ;
- lignes paiement perdues = 0 ou écarts explicitement documentés.

## 11. Failback

Le failback n'est jamais automatique :

- reconstruire / resynchroniser Site A ;
- comparer les données ;
- valider les écarts ;
- choisir une fenêtre ;
- fencer Site B ;
- promouvoir Site A ;
- rebasculer le frontdoor ;
- refaire les smoke tests et la réconciliation.
