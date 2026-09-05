# V4 — Observabilité E2E : OpenTelemetry, Prometheus, Grafana et Jaeger

## Objectif

V4 rend le flux Wero du POC observable de bout en bout sans modifier les garanties fonctionnelles V1 à V3B. Trois signaux sont reliés : traces distribuées, métriques et logs corrélés.

## Topologie

```text
Client
  | X-Correlation-Id + JWT
  v
api-gateway
  | traceparent automatique HTTP
  v
payment-service ---- PostgreSQL
  |
  v
consumer-psp -> mock-wero -> mock-sct-inst
  |
  +-> transaction DB -> outbox
                     |
                     | traceparent + X-Correlation-Id Kafka headers
                     v
                   Kafka
                     |
                     v
              event-audit-service -> PostgreSQL

Tous les services -> OTLP/gRPC -> Jaeger
Tous les /q/metrics -> Prometheus -> Grafana
Logs console -> traceId/spanId + correlationId/paymentId dans les messages métier
```

## Identifiants

- `traceId` : identifiant technique OpenTelemetry d'une exécution distribuée.
- `spanId` : étape technique dans la trace.
- `X-Correlation-Id` : identifiant de corrélation contrôlé par le client/gateway et propagé entre composants.
- `paymentId` : identifiant métier du paiement.

Le gateway conserve le `X-Correlation-Id` fourni ou en génère un. Il expose aussi `X-Trace-Id` dans la réponse du POC pour faciliter les tests et l'investigation.

## Traces synchrones

Quarkus OpenTelemetry instrumente les appels HTTP REST. Les attributs métier utiles sont ajoutés aux spans : `wero.payment_id`, `wero.correlation_id`, `wero.payment.status` et `wero.operation`.

La datasource PostgreSQL de `payment-service` et `event-audit-service` active également la télémétrie JDBC.

## Continuité asynchrone Outbox / Kafka

Le point important de V4 est de ne pas perdre la trace au passage asynchrone :

1. `payment-service` capture le contexte OpenTelemetry actif lors de l'écriture de l'outbox ;
2. l'outbox conserve `correlationId` et `traceparent` ;
3. `OutboxPublisher` crée un span `PRODUCER` enfant et place son `traceparent` dans les headers Kafka ;
4. `event-audit-service` extrait le header et crée un span `CONSUMER` enfant ;
5. l'audit persiste aussi le `correlationId` et le `traceId` métier/technique dans la ligne d'audit.

La garantie de livraison reste celle de V2B : at-least-once avec déduplication par `eventId`. La télémétrie n'est pas une garantie transactionnelle supplémentaire.

## Métriques Prometheus

Principales métriques métier ajoutées :

- `wero_payments_total{status="..."}` ;
- `wero_payments_idempotent_replays_total` ;
- `wero_payments_reconciliations_total{outcome="..."}` ;
- `wero_audit_events_total{event_type="..."}`.

Les métriques HTTP/JVM Quarkus/Micrometer restent également disponibles sur `/q/metrics`.

`paymentId` et `correlationId` ne sont volontairement pas utilisés comme labels Prometheus : leur cardinalité serait trop élevée. Ils appartiennent aux traces et aux logs, pas aux dimensions de métriques agrégées.

## Grafana

Le dashboard `MayaBanque Wero — V4 Observability` est provisionné automatiquement. Il affiche notamment : paiements par statut, débit HTTP, replays idempotents, événements Kafka d'audit et nombre de targets Prometheus disponibles.

Les datasources Prometheus et Jaeger sont provisionnées automatiquement.

## Sécurité

V4 conserve V3B : `payment-service` et `event-audit-service` n'ont aucune Route publique. Les NetworkPolicies continuent d'autoriser le gateway et ajoutent uniquement `app=prometheus` pour le scraping de `/q/metrics`.

Les Routes Jaeger, Prometheus et Grafana sont exposées uniquement pour le laboratoire CRC. Grafana est configuré en lecture anonyme pour faciliter le lab. Ce modèle est interdit tel quel en production.

## Limites CRC

- Jaeger mono-réplique et stockage éphémère ;
- Prometheus mono-réplique avec rétention 2 h et `emptyDir` ;
- Grafana mono-réplique et configuration provisionnée par ConfigMaps ;
- composants d'observabilité accessibles par Routes HTTP de lab ;
- pas d'alerting SLO ni de stockage long terme ;
- pas de logs centralisés Loki/ELK dans cette itération.

## Cible production

Une cible production remplacerait ce lab par un OpenTelemetry Collector en gateway/agent, TLS/mTLS, contrôle d'accès aux interfaces, stockage durable des traces, Prometheus HA avec stockage long terme (Thanos/Mimir ou équivalent), Grafana authentifié, règles d'alerting SLO et politique de rétention conforme.

## Validation V4

`tests/e2e/test-v4-observability.sh` vérifie :

1. présence des Routes observabilité et maintien de l'isolation V3B ;
2. paiement SETTLED avec `X-Correlation-Id` et `X-Trace-Id` ;
3. ledger ;
4. audit Kafka portant le même correlationId et traceId ;
5. targets Prometheus et métrique métier SETTLED ;
6. trace Jaeger traversant gateway, paiement, PSP, Wero mock, SCT Inst et audit Kafka ;
7. santé Grafana et dashboard provisionné.

La prochaine itération V5 appliquera GitOps/Argo CD au déploiement de cette plateforme.
