# plan-tools

Lit les fichiers **Plan Expert** (`.qpl`) de DR Électrique et produit un **inventaire**, un
**bordereau (BOM)** au format de Francis et un **tracé IA des conduits**. Les `.qpl` d'origine ne
sont jamais modifiés : le tracé est écrit dans une copie `<nom> - IA.qpl`.

## Installation

```powershell
cd "$env:USERPROFILE\dev\lena-ai-jo\plan-tools"
uv sync
```

## Commandes

```powershell
uv run plan-tools find-project S-0723          # chemin du .qpl le plus récent (ignore « * - IA.qpl »)
uv run plan-tools inventory S-0723             # inventaire CSV + JSON
uv run plan-tools bom S-0723                   # bordereau 13 colonnes
uv run plan-tools roundtrip-check --all "<dossier Mes projets>"
uv run plan-tools classify-report S-0723       # rôle de chaque symbole (panneau / appareil / ignoré)
uv run plan-tools route S-0723 [--plan "R1 - 10"] [--force]   # tracé IA des conduits
```

- Cible acceptée : code projet (`S-0723`), chemin d'un `.qpl` ou d'un dossier de projet.
  Le code correspond aux dossiers `S-0723 (…)`, `S-0723-1 …`, `S-0723_…`, `S-0723.…` (pas
  `S-07230`). Plusieurs dossiers : celui dont le `.qpl` est le plus récent est pris et la commande
  affiche « Plusieurs dossiers trouvés, j'ai pris : … (autres : …) ».
- Fichier de sortie ouvert dans Excel / Plan Expert : « Impossible d'écrire … : ferme-le (Excel /
  Plan Expert) puis relance. » (code de sortie 2).
- Dossier des projets : variable `PLAN_TOOLS_PROJECTS_ROOT` (défaut : OneDrive « Mes projets »).
- Sortie par défaut : `%LOCALAPPDATA%\plan-tools\out\<projet>\` — **jamais dans OneDrive**.
  `--out <dossier>` pour un autre dossier ; `--out IA` = dossier `IA\` à côté du `.qpl`.
- CSV : UTF-8 avec BOM, séparateur `;`, virgule décimale → s'ouvre directement dans Excel FR.

## Bordereau (BOM)

Colonnes exactes : `Plan;Discipline;Code Canonique DR;Description Technique;Modele / Reference Fabricant;Localisation;Qte Brute;Correction / Regle Appliquee;Qte Finale;Unite;Statut Action;Notes Chantier;Reference feuille`

- Une ligne par objet quantifiable (Counter, Line, Perimeter, Area) ; Rectangle, Legend, Note et
  Angle sont des annotations et ne vont pas au bordereau (ils restent dans l'inventaire).
- Code / Description : article du catalogue (`<Group GroupID>` → `EEExchangeData` Key/Description),
  sinon le nom de l'objet. Discipline, Modèle et Correction restent vides (jamais inventés).
- Qte Brute : nombre de symboles (`un`) ou longueur en pixels (`px`). Statut : `À valider`.
- Échelle : `length_scaled = length_px × Scale.Value` seulement si Value > 0, toujours marqué
  `[À CONFIRMER — Jo] unité d'échelle`. Échelle 0 → `[À CONFIRMER — Jo] échelle non définie`.

## Tracé IA des conduits (`route`)

```powershell
uv run plan-tools route S-0723                     # tous les plans
uv run plan-tools route S-0723 --plan "R1 - 10"    # un plan (nom entier préféré : « R1 - 1 » ≠ « R1 - 10 »)
```

Produit dans le dossier de sortie (défaut `%LOCALAPPDATA%\plan-tools\out\<projet>\`) :

- `<nom> - IA.qpl` : copie du projet + un calque **« IA - Conduits »** (Index = max + 1, inactif)
  par plan tracé, une `Line` magenta (`Color="-65281"`) par parcours, nommée
  `IA conduit 3/4 – <circuit>`, GroupID du conduit 3/4 du catalogue s'il existe, autres attributs
  clonés d'une `Line` existante. Rien d'autre ne change dans le fichier (vérifié par test : en
  retirant les calques IA on retrouve l'original à l'octet près). Le `.qpl` d'origine n'est jamais
  écrit ; un fichier de sortie existant n'est remplacé qu'avec `--force`.
- `<plan> - IA.png` : l'image du plan (même dossier que le `.qpl`) réduite à 4000 px de large,
  avec les parcours en magenta semi-transparent, les panneaux en cercle, les appareils en carré.
  Image absente → avertissement, pas d'aperçu.
- `rapport.md` (FR) : bloc « Pour Jo » en tête (original intact, fichier résultat, points
  `[À CONFIRMER — Jo]`), puis par plan, parcours, appareils par parcours, longueur en px, drapeaux.
  `--plan` sans appareil à relier (aucun plan, ou plans sans symbole) : « Aucun symbole à router
  sur … », rien n'est écrit.

Méthode (v1, géométrie pure, sans image ni ML) :

1. Rôle de chaque symbole (`Counter/@Name`) selon `config.toml` : `ignore` (à enlever,
   existant) → `panel` (sauf `panel_exclude` : luminaires, détecteurs, alarme incendie…) →
   `device`. `classify-report` affiche le tableau pour validation.
2. Groupes : étiquette de circuit (`\b[A-Z]{1,3}-?\d{1,3}\b` dans `@Name` puis `@Text`), sinon
   proximité (plus proche voisin glouton, `max_devices_per_run = 12`) ; une étiquette trop chargée
   est scindée (`L1.1`, `L1.2`…).
3. Chaque groupe part du panneau le plus proche de son centre (sans panneau : de l'appareil le
   plus central, drapeau `[À CONFIRMER — Jo] aucun panneau détecté`), puis chaîne au plus proche
   voisin. Chaque saut est un L : horizontal d'abord, sauf si le coude vertical d'abord recouvre
   moins les conduits déjà posés (existants + IA). Déterministe.
4. `--wall-aware` : non implémenté (lève une erreur, aucun repli factice) — raisons dans
   `route.wall_aware_unavailable`.

Les règles sont dans `config.toml` (autre fichier : variable `PLAN_TOOLS_CONFIG`) ; le bloc
`# [À CONFIRMER — Jo]` liste les 50 noms de symboles les plus fréquents sur les 371 fichiers.

## Fidélité aller-retour

`qpl_io` relit le XML avec lxml et le réécrit dans le style exact de Plan Expert (BOM, CRLF,
tabulations, `<X></X>` vide, `<Element .. />` avec espace sous `<Line>` seulement,
`&apos;`/`&quot;` dans les attributs). Vérifié : **371/371 fichiers réels identiques à l'octet**.
Filet de sécurité : si un document **non modifié** ne se reproduit pas à l'octet, `dumps()` renvoie
les octets d'origine ; `roundtrip-check` mesure le sérialiseur seul (sans ce repli).

## Développement

```powershell
uv run ruff check
uv run ruff format --check
uv run pytest -q
```
