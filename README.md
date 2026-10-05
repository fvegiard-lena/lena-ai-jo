# Léna pour Jo

Léna, c'est ton assistante IA (Claude) branchée sur tes projets, tes plans `.qpl` et tes courriels.
Ce repo garde ses outils et une copie de sa config, en sécurité sur GitHub. Tu n'as rien à faire ici : tu parles à Léna, elle s'occupe du reste.

## Ce que tu peux lui dire

| Tu dis | Léna fait |
|---|---|
| « Inventaire S-xxxx » | La liste du matériel du projet, sortie du plan `.qpl`. |
| « Trace les conduits S-xxxx » **(en test)** | Le tracé des conduits, sorti du plan. |
| « Bordereau S-xxxx » | Le bordereau de quantités prêt pour la soumission (les prix, c'est toi qui les donnes). |
| « Brief du matin » | Courriels, agenda et chantiers du jour, en une page. |
| « Retrouve le courriel de … sur … » **(bientôt — en attente de la réparation Outlook)** | Elle fouille tes courriels et te sort le bon. |

Remplace `S-xxxx` par ton numéro de projet (ex. `S-0723`).

## Où sont les choses

- **Tes projets** : OneDrive `DANIEL-FRANCIS-JO\Mes projets` (plans `.qpl`) et Google Drive `plan expert qpl`.
- **Les outils de Léna** : ce repo (`%USERPROFILE%\dev\lena-ai-jo`)
  - `plan-tools/` : lecture des plans `.qpl` (inventaire, conduits, bordereau)
  - `email-vectorizer/` : recherche dans tes courriels (bientôt — en attente de la réparation Outlook)
  - `config/` : copie de la config (mots de passe masqués), mise à jour chaque jour
  - `scripts/` : sauvegardes, mises à jour et vérification de nuit automatiques
- **Sauvegarde des conversations** : `D:\Backups\claude`

## Si ça marche pas

Appelle **Francis**. Il a le [RUNBOOK](docs/RUNBOOK.md) (quoi faire quand quelque chose casse).

## Pour aller plus loin

- [Architecture](docs/ARCHITECTURE.md) : comment tout est branché
- [Inventaire](docs/INVENTAIRE.md) : l'état de la machine
- [CI-CD](docs/CI-CD.md) : les vérifications automatiques (GitHub et la nuit sur ton PC)
- [LENA.md](docs/LENA.md) : les règles de Léna
