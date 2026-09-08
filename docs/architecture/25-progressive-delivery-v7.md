# V7 — Progressive delivery design

## Décision

Argo Rollouts est retenu comme mécanisme cible pour les workloads stateless **après** disponibilité d'un vrai preprod, de digests immutables et de métriques SLO fiables.

Aucun CR `Rollout` n'est appliqué dans V7 aujourd'hui : installer des CRDs ou convertir des Deployments sans environnement de test créerait une fausse impression de readiness.

## Candidats initiaux

- `api-gateway`
- `payment-service`
- `consumer-psp`
- `event-audit-service`
- `mock-wero`
- `mock-sct-inst`

Les stateful Operators CNPG / Redpanda / Keycloak conservent leurs propres stratégies de rolling update.

## Stratégie candidate

Canary par étapes, à calibrer en preprod :

```text
5 % -> analyse -> 25 % -> analyse -> 50 % -> analyse -> 100 %
```

Gates d'analyse :

- taux 5xx / erreurs métier ;
- p95/p99 de latence ;
- paiements `UNKNOWN` ;
- duplications rail/ledger = 0 ;
- Outbox pending / consumer lag ;
- disponibilité OIDC/frontdoor.

## Prérequis avant activation

1. Argo Rollouts Operator/CRDs installés.
2. Métriques Prometheus durables et accessibles à l'AnalysisTemplate.
3. Images pinées par digest.
4. Smoke tests C6 automatisés.
5. Rollback testé en preprod.
6. Politique d'approbation prod définie.

## État

Le design est terminé côté dépôt. L'implémentation/runtime progressive delivery reste une tâche d'infrastructure/preprod et ne bloque pas la clôture Git de V7.
