# V3B — API Gateway et exposition Zero Trust

## Objectif

V3B transforme la V3A en architecture à point d'entrée unique : les clients externes ne voient plus directement `payment-service` ni `event-audit-service`. Toute API métier passe par `api-gateway`.

## Flux

```text
Client
  |
  | JWT
  v
OpenShift Route
  |
  v
api-gateway
  | 1. valide JWT + rôle
  | 2. conserve X-Correlation-Id ou en génère un
  | 3. relaie le même Bearer token
  v
payment-service / event-audit-service
  | revalident JWT + rôle
  v
PostgreSQL / Kafka / Consumer PSP / mocks
```

## Contrôles de sécurité

- Une seule Route métier publique : `api-gateway`.
- La Route Keycloak reste publique pour le POC afin d'émettre les tokens.
- Les Routes `payment-service` et `event-audit-service` sont supprimées après déploiement.
- `NetworkPolicy` sélectionne les pods backend et n'autorise l'ingress TCP/8080 que depuis `app=api-gateway`.
- Le gateway valide le JWT OIDC et applique les mêmes rôles que les backends.
- Le Bearer token utilisateur est relayé ; le backend le revalide. On ne fait donc pas confiance au gateway seul.
- `X-Correlation-Id` est propagé et retourné pour préparer V4 observabilité.
- La taille du body HTTP est limitée à 1 MiB sur le gateway.
- Les réponses du gateway portent `Cache-Control: no-store`.

## Routes exposées par le gateway

- `POST /api/consents`
- `GET /api/consents/{consentId}`
- `POST /api/consents/{consentId}/sca`
- `POST /api/payments/single-immediate`
- `GET /api/payments/{paymentId}`
- `GET /api/payments/{paymentId}/ledger`
- `POST /api/payments/{paymentId}/reconcile`
- `GET /api/outbox/{paymentId}`
- `GET /api/audit/events/{paymentId}`

## Défense en profondeur

Le gateway n'est pas une frontière de confiance suffisante. Chaque backend conserve `quarkus-oidc` et `@RolesAllowed`. Si un acteur atteignait le Service Kubernetes directement, il lui faudrait toujours un JWT valide et le bon rôle. La `NetworkPolicy` ajoute une seconde barrière réseau.

## Périmètre CRC vs production

Ce POC utilise un gateway Quarkus mono-réplique pour limiter la consommation sur OpenShift Local. En production, un produit dédié comme Red Hat 3scale, Kong, Apigee ou équivalent peut assurer rate limiting distribué, quotas, politiques d'API, certificats, analytics et cycle de vie API.

Le POC CRC garde également `quarkus.oidc.token.issuer=any` car Keycloak est découvert par son Service interne alors que le token est émis via sa Route externe. Une architecture de production doit utiliser un hostname/issuer canonique unique et ne pas désactiver cette vérification.

## Limites restantes

- pas encore de mTLS inter-services ;
- pas de rate limiting distribué ;
- pas de WAF ;
- pas de rotation automatique des secrets ;
- Keycloak et api-gateway sont mono-répliques dans le lab ;
- pas encore de traces distribuées : objet de V4.

## Validation V3B attendue

Le test `tests/e2e/test-v3b-gateway-zero-trust.sh` vérifie :

1. absence des Routes backend ;
2. présence des NetworkPolicies ;
3. 401 sans JWT au gateway ;
4. 403 pour un rôle insuffisant ;
5. consentement puis SCA ;
6. paiement `SETTLED` ;
7. replay idempotent ;
8. lecture payment/ledger via gateway ;
9. audit Kafka protégé via gateway.
