# V2 — État transactionnel, idempotence, ledger et réconciliation

## Objectif

La V1 prouve le chemin nominal. La V2 traite le problème critique des paiements distribués : **le système peut perdre la réponse alors que le paiement a déjà été exécuté**.

Dans ce cas, le paiement ne doit pas être déclaré `FAILED` et ne doit surtout pas être rejoué aveuglément. Son état devient `UNKNOWN`, puis un mécanisme de réconciliation interroge le rail SCT Inst simulé.

## Architecture V2

```text
Client
  |
  | POST /payments/single-immediate
  | Idempotency-Key
  v
payment-service
  |
  +---- PostgreSQL
  |       |- payments
  |       `- ledger_entries
  |
  v
consumer-psp
  |
  v
mock-wero
  |
  v
mock-sct-inst
```

## Machine d'états

```text
CREATED
   |
   v
PROCESSING
   |-----------------------|
   |                       |
   v                       v
SETTLED                  FAILED
   |
   `--> ledger

PROCESSING
   |
   | timeout / réponse perdue
   v
UNKNOWN
   |
   | status query / reconciliation
   v
SETTLED
   |
   `--> ledger
```

`UNKNOWN` signifie : **le résultat du paiement n'est pas connu localement**. Il ne signifie pas que le paiement a échoué.

## Idempotence

Chaque création requiert :

```http
Idempotency-Key: <clé unique du client>
```

Même clé + même payload : retour de la transaction existante, avec `X-Idempotent-Replay: true`.

Même clé + payload différent : `409 IDEMPOTENCY_CONFLICT`.

Même `paymentId` avec une autre clé : `409 PAYMENT_ID_CONFLICT`.

## Ledger

Une entrée `SETTLEMENT` est créée uniquement lorsque le paiement est confirmé `SETTLED`.

La création est protégée contre les doublons applicatifs : la réconciliation répétée ne doit pas créer plusieurs entrées de settlement pour le même paiement.

Endpoint de lecture :

```text
GET /payments/{paymentId}/ledger
```

## Réconciliation

Endpoint :

```text
POST /payments/{paymentId}/reconcile
```

Le service :

1. lit l'état local ;
2. interroge `mock-sct-inst` par `paymentId` ;
3. si le rail confirme `SETTLED`, met à jour l'état local ;
4. enregistre le settlement dans le ledger ;
5. ne rejoue jamais le paiement.

## Scénario de panne V2

`simulateMode=TIMEOUT_AFTER_SETTLEMENT` provoque volontairement le scénario suivant :

```text
mock-sct-inst
    |
    |-- enregistre SETTLED
    |
    `-- attend 5 secondes avant de répondre

payment-service
    |
    `-- timeout après 2 secondes -> UNKNOWN
```

La réconciliation trouve ensuite le paiement déjà `SETTLED` côté SCT Inst et fait converger l'état local.

## Persistance

PostgreSQL est déployé dans `wero-poc` avec un PVC de 1 GiB.

Tables générées par Hibernate :

- `payments`
- `ledger_entries`

## Limites volontaires de V2

- le mock SCT Inst conserve encore son index de statuts en mémoire ;
- ledger et orchestration sont dans le même service pour limiter la consommation du CRC ;
- pas encore de Kafka/outbox ;
- pas encore de compensation ni de refund ;
- pas encore de Keycloak/SCA.

La prochaine sous-étape V2B ajoutera **Kafka + transactional outbox + événements de paiement** avant de séparer physiquement le ledger et la réconciliation.
