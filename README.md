# Wave

Une application native SwiftUI **100 % hors ligne**, légère et sobre pour écrire, organiser ses idées et partager leur contexte avec une IA. Une interface d’écriture inspirée d’iA Writer pour **macOS 13+**, **iPhone** et **iPad (iOS/iPadOS 17+)**.

Distribuée en open-source sous licence [MIT](LICENSE) par **Besty**.

## Ouvrir et lancer

Ouvrir `Wave.xcodeproj` dans Xcode, sélectionner le schéma **Wave**, puis **My Mac** ou un simulateur iPhone/iPad. Aucune dépendance externe n’est nécessaire.

Pour installer sur un iPhone ou iPad physique, sélectionnez votre équipe Apple dans **Signing & Capabilities** et lancez depuis Xcode.

Pour compiler localement la version Mac Release (`dist/Wave.app`) :

```sh
Scripts/build_mac.sh
```

### Publier une version Mac

Créer et pousser un tag de version (`git tag v1.1.0 && git push origin v1.1.0`). GitHub Actions compile Wave pour Apple Silicon et publie `Wave.zip` dans une Release publique. La première ouverture peut nécessiter d’autoriser l’app dans **Réglages Système → Confidentialité et sécurité** (build non notarié).

### Mises à jour automatiques (macOS)

L’app officielle vérifie les nouvelles Releases publiques de `besty-boy/waves` au lancement et toutes les 6 heures, **uniquement lorsqu’une connexion réseau est active** (`NWPathMonitor` — zéro requête réseau hors ligne). Lorsqu’une version est disponible, Wave télécharge `Wave.zip`, vérifie sa somme **SHA-256** et sa signature `codesign`, puis remplace le bundle et se relance.

Un token GitHub n’est **pas nécessaire** (le dépôt est public) ; vous pouvez néanmoins en enregistrer un dans le Trousseau macOS via **Réglages → Token GitHub** pour augmenter la limite API GitHub.

La version Debug s’appelle **Wave Dev** (`com.wave.notes.dev`) et coexiste avec l’app officielle sur la même bibliothèque de notes.

## Écrire, organiser, travailler hors ligne

- **Hors ligne & sobre en énergie** : fichiers Markdown locaux, surveillance événementielle `NSFilePresenter` (zéro polling périodique, ~0 % CPU au repos), sauvegarde non bloquante, aperçu `WKWebView` créé uniquement à la demande, respect du mode économie d’énergie.
- **Interface claire et sombre** : thème clair, sombre ou système, composants natifs Liquid Glass sur macOS/iOS 26+ tout en gardant la page d’écriture opaque et lisible.
- **Éditeur Markdown natif** : polices **iA Writer Mono, Duo et Quattro**, taille et largeur réglables, concentration sur la phrase ou le paragraphe, mode machine à écrire, coloration grammaticale locale (`NaturalLanguage`) et suggestions de style FR/EN.
- **Productivité locale** :
  - **Ouverture rapide** (`⌘O`) pour sauter instantanément vers une note ou la créer
  - **Note du jour** (`⇧⌘D`) et **modèles intégrés** (Réunion, Projet, Lecture, Journal…)
  - **Vue Tâches** globale avec cases à cocher interactives synchronisées avec le Markdown
  - **Liens internes `[[Note]]`** avec autocomplétion et panneau **Rétroliens / Sommaire / Historique**
  - **Rechercher & remplacer**, Favoris, Récents, hashtags, dossiers intelligents et Corbeille (30 jours)
  - **Carte d’idées** interactive avec zoom, liens entre idées et association aux notes
  - **Imports / Exports** : Markdown, HTML, PDF A4, Word `.docx`, pièces jointes (glisser-déposer & collage de captures d’écran), Quick Look et **Copier pour une IA**.

Raccourcis Mac : `⌘N` nouveau document, `⌘O` ouverture rapide, `⇧⌘D` note du jour, `⌘S` enregistrer, `⌘D` concentration, `⌘R` aperçu, `⌥⌘R` aperçu côte à côte, `⌘B` gras, `⌘I` italique, `⌘K` lien, `⇧⌘L` bibliothèque.

Les notes locales sont stockées dans `~/Library/Application Support/Wave/Notes` sur Mac.

## Synchroniser Mac, iPhone et iPad (iCloud Drive)

1. Créer un dossier **Wave** dans iCloud Drive (Finder ou Fichiers).
2. Dans **IA & appareils → Choisir un dossier partagé**, sélectionner ce même dossier sur chaque appareil.

Les notes, pièces jointes et `MindMap.json` restent des fichiers standards lisibles hors ligne et coordonnés avec iCloud Drive.

## Connecter une IA avec MCP

Sur Mac, ouvrez **IA & appareils** pour copier la configuration prête à l’emploi dans votre client MCP **stdio local** (Claude Desktop, Cursor, etc.).

Outils exposés en lecture seule par défaut :

- `list_notes`, `search_notes`, `read_note`
- `list_tasks`, `list_tags`, `read_backlinks`
- `read_attachment` (PDF, DOCX et fichiers texte)
- `read_mind_map`
- Ressources `wave://notes/{UUID}` et `wave://mind-map`

L’écriture est **désactivée par défaut**. Activer **Autoriser l’écriture des notes** ajoute `WAVE_MCP_WRITE=1` et expose :

- `create_note` : crée une note Markdown dans le dossier choisi.
- `update_note` : modifie une note existante avec contrôle de révision SHA-256 (`read_note` préalable requis pour empêcher tout écrasement concurrent).

Lancement manuel :

```sh
swift run WaveMCP
WAVE_VAULT_PATH="/chemin/vers/Wave" WAVE_MCP_WRITE=1 swift run WaveMCP
```

Protocole MCP négocié : `2024-11-05`, `2025-03-26`, `2025-06-18` et `2025-11-25`.

## Vérifications & tests

```sh
swift test --scratch-path .build/Tests
python3 Scripts/test_mcp.py .build/Tests/debug/WaveMCP
swiftc -O Sources/WaveCore/*.swift App/Theme.swift App/WaveStore.swift Scripts/test_library.swift -o .build/library-checks
.build/library-checks
```

Benchmarks synthétiques (600 notes, document de ~180 Ko) :

```sh
swiftc -O Sources/WaveCore/*.swift Scripts/benchmark.swift -o .build/wave-benchmark && .build/wave-benchmark
swiftc -O Sources/WaveCore/*.swift Sources/WaveEditor/WritingTextView.swift Scripts/benchmark_writer.swift -o .build/writer-benchmark && .build/writer-benchmark
```

## Structure

```text
App/                     Interface SwiftUI, aperçu WebKit, polices et icônes
Sources/WaveCore/        Modèles, recherche, Markdown, exports et stockage coordonné
Sources/WaveEditor/      Éditeur AppKit/UIKit et coloration incrémentale
Sources/WaveMCP/         Serveur MCP JSON-RPC sur stdio
Tests/WaveCoreTests/     Tests unitaires du cœur, des exports et du stockage
Tests/WaveEditorTests/   Tests unitaires de l’éditeur et de la coloration
Scripts/                 Build macOS, tests MCP/bibliothèque et benchmarks
Wave.xcodeproj/          Projet Xcode macOS, iPadOS et iOS
```

## Licence et polices

- Le code source de Wave est distribué sous licence **MIT** (voir [LICENSE](LICENSE)).
- Les polices **iA Writer Mono, Duo et Quattro** proviennent du dépôt officiel [iA-Fonts](https://github.com/iaolo/iA-Fonts) (Copyright Information Architects Inc. et IBM Corp.) et sont distribuées sous **SIL Open Font License 1.1** (licences incluses dans `App/Fonts/`).
