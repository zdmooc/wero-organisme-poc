# V1 — Single Immediate

## Objectif

Exécuter un premier paiement Wero simulé de bout en bout sur OpenShift Local / CRC.

## Flux

```text
Client
  |
  v
payment-service
  |
  v
consumer-psp
  |
  v
mock-wero
  |
  v
mock-sct-inst
  |
  v
SETTLED
```

## Contrat d'entrée

`POST /payments/single-immediate`

```json
{
  "paymentId": "PAY-000001",
  "amountCents": 1250,
  "currency": "EUR",
  "debtorAlias": "+33600000001",
  "creditorAlias": "+33600000002"
}
```

## Réponse attendue

```json
{
  "paymentId": "PAY-000001",
  "status": "SETTLED",
  "settlementId": "SCT-..."
}
```

## Limites volontaires V1

- pas encore de base de données ;
- pas encore de Kafka ;
- pas encore d'idempotence ;
- pas de statut UNKNOWN ;
- pas de retry ;
- pas de ledger ;
- pas de réconciliation ;
- pas d'authentification.

Ces fonctions seront ajoutées progressivement pour permettre de mesurer précisément leur rôle dans la résilience.

## Déploiement CRC

```bash
bash platform/openshift/v1/deploy-v1.sh
bash tests/e2e/test-single-immediate.sh
```
