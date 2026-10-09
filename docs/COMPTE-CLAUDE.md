# COMPTE-CLAUDE.md — Le compte claude.ai d'un estimateur (une fois par compte)

Ce que le repo ne peut pas copier : tout ce qui vit dans le **compte claude.ai**. Cette liste est la même pour
tous les comptes (Jo, Francis, estimateur 2, estimateurs juniors) ; elle se règle **à la main, dans claude.ai**,
une seule fois par compte. Rien ici ne passe par un script ni par un outil propre à un PC. Le code, les skills,
les règles (LENA.md) et les réglages Claude Code viennent du repo (RUNBOOK §11, `install-twin.ps1`).

Compte de référence : celui de Jo (`lena.ai.dr@gmail.com`). Quand cette page et le compte de Jo divergent,
on corrige la page, puis on aligne les autres comptes.

## 1. Comptes

| Compte Google | Qui | Branche / jumeau | Forfait |
|---|---|---|---|
| `lena.ai.dr@gmail.com` | Jo — compte de référence, checkout principal `lena-ai-jo` (`main`) | — | Max |
| `fvegiard@gmail.com` | Francis (développement) | `francis-dev` | — |
| `lena.ai.dr.routeur@gmail.com` | Estimateur 2 ; aussi les estimateurs juniors, pour le moment | `Estimateur-2`, `estimateur-junior` | Pro |

Chaque compte a **son** profil Chrome (extension Claude installée et autorisée dedans) et, sur un PC, **son**
dossier de config Claude Code (`%USERPROFILE%\.claude-<clé>`, créé par `install-twin.ps1`). Claude Desktop
ne tient qu'un compte à la fois.

### Qui tourne où (décision de Francis, 2026-10-09)

| PC | Compte principal (`%USERPROFILE%\.claude`, Claude Desktop) | Ce qui y tourne | Commande d'installation |
|---|---|---|---|
| **PC de Jo** (son Legion) — **le workspace** | Jo, `lena.ai.dr@gmail.com`, et personne d'autre | `lena-ai-jo` sur `main` (tâches planifiées, Qdrant, Ollama, OneDrive `Mes projets`) **et les estimateurs** : jumeaux `Estimateur-2`, `estimateur-junior`, chacun sous son compte et son dossier de config, qui travaillent avec Jo | `pwsh -File "$env:USERPROFILE\dev\lena-ai-jo\scripts\install-twin.ps1" -Branch Estimateur-2,estimateur-junior` |
| **PC de Francis** (son Legion) — **dev** | Francis, `fvegiard@gmail.com` | jumeau `francis-dev` : améliorations, corrections, pousser Léna plus loin ; `D:\github\lena-ai-jo` en miroir lecture seule pour l'installateur ; les jumeaux estimateurs seulement le temps d'un test | `pwsh -File "D:\github\lena-ai-jo\scripts\install-twin.ps1" -Root D:\github -Branch francis-dev` |
| PC d'un autre estimateur | le compte de cet estimateur | son jumeau | `-Branch <sa branche>` |

Règles :
- Le profil de Jo (`%USERPROFILE%\.claude`, son compte claude.ai, Claude Desktop, Desktop Commander « Jo ») est à Jo seul : aucun autre PC ne se connecte avec son compte, aucun jumeau ne tourne avec `-SharedLogin` sur son PC, l'installateur n'y touche jamais.
- Les estimateurs travaillent avec Jo dans le workspace de son PC, chacun par son lanceur et son compte (table §1). Ils n'ont pas accès au dossier de config de Jo, et Jo n'a pas besoin du leur.
- Entre les PC, **un seul canal : git**. Un jumeau pousse sa branche et ouvre une PR vers `main` ; le PC de Jo répond par le workflow (CI GitHub sur la PR, CI de nuit `lena-nightly-ci`, `@claude` dans la PR au besoin). Rien d'autre n'est partagé : ni dossier de config, ni appairage Desktop Commander, ni données locales, ni session.
- Le poste dev se connecte à Léna seulement pour améliorer, corriger ou aller plus loin ; les tests d'estimation se font dans un jumeau estimateur, et leur résultat revient au PC de Jo par la PR.

## 2. Paramètres claude.ai (claude.ai → Paramètres)

| Section | Réglage | Valeur |
|---|---|---|
| Général | Notifications : réponses terminées, notifications Code, courriels des sessions cloud Claude Code, Projets, commentaires sur vos artefacts, artefacts partagés avec vous | **activées** |
| Capacités | Artefacts IA | **activé** |
| Capacités | Sortie réseau (egress) | **activée, tous les domaines** |
| Capacités | Gestionnaires de paquets | **tous les domaines** |
| Mémoire | Rechercher et référencer les chats ; générer la mémoire à partir des chats ; inclure les sujets sensibles | **les trois activés** |
| Claude Code | Thème de code sombre | **Catppuccin Mocha** |
| Claude dans Chrome | Politique par défaut | **Autoriser tous les sites** |
| Compte | Type de travail | **Opérations** |
| Compte | Instructions pour Claude | le bloc **Identité** + **Règles absolues** de `docs/LENA.md`, avec les valeurs internes (RBQ, taux MO) ajoutées à la main — jamais dans le repo |
| Langue (menu du compte, en bas à gauche) | Interface | **Français (France)** (la liste n'a pas de variante Canada) |
| Langue | Voix | **Français (Canada)** |

## 3. Connecteurs (claude.ai → Paramètres → Connecteurs)

Obligatoires pour une Léna complète : **Gmail**, **Google Calendar**, **Google Drive**, **GitHub** (repo
`fvegiard-lena/lena-ai-jo`), **Desktop Commander** (appareil appairé sur le PC de la personne, RUNBOOK §3),
**Normes DR Électrique** (MCP personnalisé — URL : voir Francis). Utiles : **Mermaid Chart**, **Slack**,
**Cloudflare Developer Platform**, **Hugging Face**.

Chaque connecteur Google demande la connexion au compte Google **de la personne** ; Desktop Commander,
Cloudflare, Hugging Face et Slack demandent la connexion à leur propre compte. Ces connexions se font par la
personne (jamais de mot de passe tapé par un agent).

## 4. Extension Chrome « Claude »

Installée dans le profil Chrome du compte, autorisée pour ce compte (page « Claude for Chrome would like to
connect… » → Autoriser). Panneau latéral : le modèle le plus élevé disponible, effort Élevé (Fable 5.1 si le
forfait a des crédits, sinon Opus 5.5).

## 5. Claude Code sur le PC

Lanceur du jumeau (`<Root>\lena-<branche>.cmd`, RUNBOOK §11), ouvert depuis un terminal Windows normal (jamais
depuis une session Claude Desktop/Code : le lanceur refuse) → première fois : `/login` avec le compte de la
table §1, dans un navigateur dont la fenêtre privée est connectée à ce compte. Dans un jumeau : jamais `/logout`
ni `/chrome`. Le dossier de config du compte reçoit `config\claude\settings.json` du repo (plus
`DISABLE_AUTOUPDATER=1` : le binaire `claude` est partagé) ; les plugins et le HUD se font ensuite dans ce
dossier (RUNBOOK §5).

## 6. État au 2026-10-09

| Compte | §2 Paramètres | §3 Connecteurs | §4 Chrome | §5 Claude Code |
|---|---|---|---|---|
| `lena.ai.dr@gmail.com` (Jo) | référence | référence | oui | checkout principal |
| `lena.ai.dr.routeur@gmail.com` | alignés sur Jo | Gmail, Calendar, Drive, Mermaid, Normes faits ; Desktop Commander, GitHub, Slack, Cloudflare, Hugging Face : à connecter (login de la personne) | oui (profil « Lena-ai Dr-Routeur ») | jumeaux installés sur le PC de Francis, `/login` à faire |
| `fvegiard@gmail.com` (Francis) | à faire | à faire | extension installée dans le profil « Francis V » | jumeau `francis-dev` installé sur le PC de Francis, `/login` à faire ; le login principal de ce PC (`%USERPROFILE%\.claude`, Claude Desktop) est encore celui de Jo et doit passer à Francis (décision du 2026-10-09, à faire par Francis) |
