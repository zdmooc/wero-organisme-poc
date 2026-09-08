# V7 — GitOps promotion, ApplicationSets et images immutables

## Statut

Le mécanisme Git de promotion est défini. Les **vrais digests** ne peuvent être écrits qu'après construction/publication des six images dans le registry cible.

## Règle de production

CRC conserve son ImageStream `:latest` pour le lab local. Preprod/prod doivent promouvoir exactement les six images applicatives par digest :

```text
<registry>/<repository>@sha256:<64 hex>
```

Aucun tag mutable `latest` n'est une preuve de promotion production.

## Script

`scripts/prepare-v7-image-promotion.sh preprod|prod`

Le script :

- exige les 6 références digest via variables d'environnement ;
- refuse un tag ou un digest mal formé ;
- modifie seulement l'overlay `<env>-c5` via `kustomize edit set image` ;
- rend l'overlay après modification ;
- vérifie que les six anciennes références applicatives `:latest` ne restent pas dans le rendu.

Il ne pousse aucune image, ne lit aucun credential de registry et ne committe rien automatiquement.

## ApplicationSets

`gitops/argocd/applicationset-v7-environments.yaml` fournit quatre scaffolds :

- workload preprod ;
- workload prod ;
- IngressController preprod ;
- IngressController prod.

Les clusters sont découverts par le générateur `clusters` Argo CD via le label :

```text
mayabanque.io/environment=preprod|prod
```

Le `server` provient de l'enregistrement Argo CD (`{{.server}}`) et n'est jamais stocké dans ce dépôt.

## Promotion recommandée

1. Build signé/scanné dans la chaîne CI de l'organisation.
2. Résoudre le digest réel de chaque image.
3. Exécuter le script de préparation sur une branche de promotion.
4. Vérifier le diff Git : uniquement les digests attendus.
5. CI Kustomize + sécurité.
6. Merge approuvé vers la branche/révision gérée.
7. Argo CD sync preprod.
8. Tests C1-C6 / smoke tests.
9. Promouvoir **les mêmes digests** vers prod.

## Limites en attente d'infrastructure

- registry production et politique de signature ;
- scanner / SBOM / admission policy ;
- clusters enregistrés dans Argo CD ;
- vrais digests ;
- promotion runtime et rollback réel.
