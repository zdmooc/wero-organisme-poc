# V2B — Kafka API, transactional outbox et événements de paiement

## Objectif

La V2B supprime le couplage entre la transaction métier et la publication d'événements.

Le principe critique est le **transactional outbox** : le paiement et l'événement à publier sont écrits dans la même transaction PostgreSQL. Le service ne tente donc pas de faire une pseudo-transaction distribuée PostgreSQL + Kafka.

## Chaîne

```text
Client
  |
  v
payment-service
  |
  | transaction PostgreSQL
  +---- payments
  +---- ledger_entries
  `---- outbox_events
             |
             | publisher asynchrone
             v
        Kafka API : payment-events
             |
             v
      event-audit-service
             |
             `---- payment_audit_events
```

## Broker du lab CRC

Pour limiter la consommation mémoire d'OpenShift Local, le lab utilise un broker **Redpanda mono-nœud** exposant l'API Kafka sous `kafka:9092`.

C'est un choix de laboratoire, pas une prescription d'architecture Wero. Une cible entreprise peut remplacer ce broker par Kafka/AMQ Streams sans modifier le contrat des événements ni le pattern outbox.

Le broker du lab est volontairement éphémère. PostgreSQL reste la source durable de l'outbox et peut republier les lignes non marquées `publishedAt` après indisponibilité du broker.

## Événements

Topic :

```text
payment-events
```

Événements produits :

- `PAYMENT_CREATED`
- `PAYMENT_PROCESSING`
- `PAYMENT_PENDING`
- `PAYMENT_SETTLED`
- `PAYMENT_FAILED`
- `PAYMENT_UNKNOWN`
- `PAYMENT_RECONCILED`

Le `paymentId` est utilisé comme clé Kafka pour conserver l'ordre des événements d'un même paiement dans une partition.

Exemple logique :

```json
{
  "schemaVersion": 1,
  "eventId": "...",
  "eventType": "PAYMENT_SETTLED",
  "paymentId": "PAY-123",
  "status": "SETTLED",
  "amountCents": 4200,
  "currency": "EUR",
  "settlementId": "SCT-...",
  "occurredAt": "..."
}
```

Les alias débiteur/créditeur ne sont volontairement pas publiés dans cet événement de démonstration afin de réduire la diffusion de données personnelles.

## Atomicité métier

Dans `payment-service` :

```text
BEGIN
  UPDATE/INSERT payment
  INSERT outbox_event
COMMIT
```

Si PostgreSQL annule la transaction, ni l'état métier ni l'événement outbox ne sont conservés.

Après le commit, un publisher planifié lit les lignes :

```text
published_at IS NULL
```

Il publie l'événement sur le topic puis renseigne `published_at`.

## Garantie de livraison

Le pattern fournit ici une sémantique **at-least-once**.

Cas important :

```text
Kafka accepte l'événement
        |
        X payment-service tombe avant UPDATE published_at
        |
        v
l'événement pourra être republié
```

Le consumer doit donc être idempotent.

`event-audit-service` utilise `eventId` comme clé de déduplication persistée avec une contrainte unique dans `payment_audit_events`.

## UNKNOWN et réconciliation

Le scénario V2 reste valide :

```text
SCT Inst exécute
   |
   X réponse perdue
   |
payment-service = UNKNOWN
   |
reconcile
   |
rail = SETTLED
   |
SETTLED
```

V2B ajoute les événements correspondants :

```text
PAYMENT_CREATED
PAYMENT_PROCESSING
PAYMENT_UNKNOWN
PAYMENT_RECONCILED
PAYMENT_SETTLED
```

La réconciliation ne rejoue toujours pas le paiement.

## Idempotence

Un replay HTTP avec le même `Idempotency-Key` et le même payload retourne le paiement existant et **ne crée aucun nouvel événement outbox**.

Deux couches d'idempotence existent donc :

1. idempotence de la commande de paiement ;
2. idempotence de consommation par `eventId`.

## APIs de diagnostic du lab

```text
GET /outbox/{paymentId}
GET /audit/events/{paymentId}
```

Elles permettent de visualiser respectivement :

- les événements écrits atomiquement avec le paiement ;
- les événements réellement consommés depuis Kafka.

## Limites volontaires

- broker mono-nœud et éphémère ;
- un seul publisher outbox ;
- polling de l'outbox au lieu de CDC/Debezium ;
- pas encore de Schema Registry ;
- JSON sans contrat Avro/Protobuf ;
- pas encore de DLQ ;
- pas encore de retry topic ;
- pas encore de métriques de lag/outbox.

## Étape suivante

La suite logique est :

```text
Schema Registry
+ versionnement des contrats
+ retry/DLQ
+ métriques consumer lag / outbox age
+ séparation ledger/reconciliation
+ sécurité Kafka
+ GitOps
```
