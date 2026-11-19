<div align="center">
  <img src="App/AppIcon.icon/Assets/Image.svg" alt="Wave" width="96" />

  <h1>Wave</h1>

  <p><strong>Écrire, organiser ses idées et partager leur contexte avec une IA — 100 % hors ligne.</strong></p>

  <p>
    Application native SwiftUI inspirée d’iA Writer pour <strong>macOS 13+</strong>, <strong>iPhone</strong> et <strong>iPad (iOS/iPadOS 17+)</strong>.<br />
    Zéro dépendance externe · Fichiers Markdown locaux · Serveur MCP intégré.
  </p>

  <p>
    <a href="https://github.com/besty-boy/waves/releases/latest">
      <img src="https://img.shields.io/github/v/release/besty-boy/waves?display_name=tag&style=flat-square&color=0088FF&label=Release" alt="Latest Release" />
    </a>
    <img src="https://img.shields.io/badge/Platforms-macOS%2013%2B%20%7C%20iOS%2017%2B%20%7C%20iPadOS%2017%2B-1D1D1F?style=flat-square" alt="Platforms" />
    <img src="https://img.shields.io/badge/Swift-5.9%2B-F05138?style=flat-square" alt="Swift" />
    <img src="https://img.shields.io/badge/MCP-Ready-7547CC?style=flat-square" alt="MCP Ready" />
    <a href="LICENSE">
      <img src="https://img.shields.io/github/license/besty-boy/waves?style=flat-square&color=1F8049" alt="MIT License" />
    </a>
  </p>

  <p>
    <a href="https://github.com/besty-boy/waves/releases/latest"><strong>⬇️ Télécharger Wave pour macOS</strong></a>
    &nbsp;·&nbsp;
    <a href="CHANGELOG.md">Journal des versions</a>
    &nbsp;·&nbsp;
    <a href="#connecter-une-ia-avec-mcp">Serveur MCP</a>
    &nbsp;·&nbsp;
    <a href="CONTRIBUTING.md">Contribuer</a>
  </p>
</div>

---

## Téléchargement et installation (macOS)

1. Téléchargez **`Wave.zip`** depuis la [dernière Release GitHub](https://github.com/besty-boy/waves/releases/latest) *(Apple Silicon — macOS 13+)*.
2. Décompressez l’archive et glissez **`Wave.app`** dans votre dossier **`/Applications`**.
3. **Première ouverture** : Wave étant signé localement (non notarié Apple Developer), macOS peut bloquer le premier lancement. Ouvrez **Réglages Système → Confidentialité et sécurité** et cliquez sur **Ouvrir quand même**, ou exécutez :

```sh
xattr -dr com.apple.quarantine /Applications/Wave.app
```

> [!TIP]
> Pour vérifier l’intégrité du téléchargement avant ouverture, comparez la somme SHA-256 avec le fichier `Wave.zip.sha256` joint à chaque Release :
> ```sh
> shasum -a 256 -c Wave.zip.sha256
> ```

### Mises à jour automatiques (macOS)

L’app officielle vérifie les nouvelles Releases publiques de `besty-boy/waves` au lancement et toutes les 6 heures, **uniquement lorsqu’une connexion réseau est active** (`NWPathMonitor` — zéro requête réseau hors ligne). Lorsqu’une version est disponible, Wave télécharge `Wave.zip`, vérifie sa taille, sa somme **SHA-256** et sa signature **`codesign`**, puis remplace le bundle et se relance.

Aucun token GitHub ni accès au Trousseau macOS n’est requis (le dépôt est public).

---

## Fonctionnalités

- **100 % hors ligne & sobre en énergie** : fichiers Markdown locaux, surveillance événementielle `NSFilePresenter` (zéro polling périodique, ~0 % CPU au repos), sauvegarde coordonnée non bloquante, aperçu `WKWebView` créé uniquement à la demande, respect du mode économie d’énergie.
- **Clair, sombre & natif** : thème clair, sombre ou système, composants natifs Liquid Glass sur macOS/iOS 26+ tout en gardant la page d’écriture opaque et lisible.
- **Éditeur Markdown natif** : polices **iA Writer Mono, Duo et Quattro**, taille et largeur réglables, coloration incrémentale sur la zone visible (< 1 ms/frappe sur les longs documents), concentration sur la phrase ou le paragraphe, mode machine à écrire, coloration grammaticale locale (`NaturalLanguage`) et suggestions de style FR/EN.
- **Productivité locale** :
  - **Ouverture rapide** (`⌘O`) pour sauter instantanément vers une note ou la créer
  - **Note du jour** (`⇧⌘D`) et **modèles intégrés** (Réunion, Projet, Lecture, Journal…)
  - **Vue Tâches** globale avec cases à cocher interactives synchronisées avec le Markdown
  - **Liens internes `[[Note]]`** avec autocomplétion et panneau **Rétroliens / Sommaire / Historique local**
  - **Rechercher & remplacer**, Favoris, Récents, hashtags, dossiers intelligents et Corbeille (30 jours)
  - **Carte d’idées** interactive avec zoom, liens entre idées et association aux notes
  - **Imports / Exports** : Markdown, HTML, PDF A4, Word `.docx`, pièces jointes (glisser-déposer & collage de captures d’écran), Quick Look et **Copier pour une IA**.

Les notes locales sont stockées dans `~/Library/Application Support/Wave/Notes` sur Mac.

### Raccourcis clavier (macOS)

| Raccourci | Action |
| --- | --- |
| `⌘N` | Nouveau document |
| `⌘O` | Ouverture rapide |
| `⇧⌘D` | Note du jour |
| `⌘S` | Enregistrer |
| `⌘D` | Mode concentration |
| `⌘R` / `⌥⌘R` | Aperçu / Aperçu côte à côte |
| `⌘B` / `⌘I` / `⌘K` | Gras / Italique / Lien |
| `⇧⌘L` | Afficher ou masquer la bibliothèque |
| `⌘⌫` | Mettre le document à la Corbeille |
| `⌘,` | Réglages |

---

## Synchroniser Mac, iPhone et iPad (iCloud Drive)

1. Créez un dossier **Wave** dans iCloud Drive (Finder ou Fichiers).
2. Dans **IA & appareils → Choisir un dossier partagé**, sélectionnez ce même dossier sur chaque appareil.

Les notes, pièces jointes et `MindMap.json` restent des fichiers standards lisibles hors ligne et coordonnés automatiquement avec iCloud Drive.

---

## Connecter une IA avec MCP

Wave embarque un serveur **Model Context Protocol (MCP)** local sur `stdio` (`Wave.app/Contents/Helpers/WaveMCP`). Sur Mac, ouvrez **IA & appareils** dans Wave pour copier la configuration JSON prête à l’emploi dans votre client MCP (Claude Desktop, Cursor, etc.).

### Outils et ressources exposés

| Mode | Outils / Ressources | Description |
| --- | --- | --- |
| **Lecture seule** *(par défaut)* | `list_notes`, `search_notes`, `read_note` | Explorer et lire les notes du coffre |
| **Lecture seule** *(par défaut)* | `list_tasks`, `list_tags`, `read_backlinks` | Tâches Markdown, hashtags et rétroliens `[[Note]]` |
| **Lecture seule** *(par défaut)* | `read_attachment`, `read_mind_map` | Lire pièces jointes (PDF, DOCX, texte) et carte d’idées |
| **Ressources MCP** | `wave://notes/{UUID}`, `wave://mind-map` | Accès direct aux ressources du coffre |
| **Écriture opt-in** *(`WAVE_MCP_WRITE=1`)* | `create_note`, `update_note` | Création et modification protégée par révision SHA-256 (`read_note` requis avant écriture) |

Lancement manuel depuis les sources :

```sh
swift run WaveMCP
WAVE_VAULT_PATH="/chemin/vers/Wave" WAVE_MCP_WRITE=1 swift run WaveMCP
```

Versions du protocole MCP négociées : `2024-11-05`, `2025-03-26`, `2025-06-18` et `2025-11-25`.

---

## Compiler depuis les sources

### Xcode (macOS, iOS et iPadOS)

Ouvrez `Wave.xcodeproj` dans Xcode, sélectionnez le schéma **Wave**, puis **My Mac** ou un simulateur iPhone/iPad. Aucune dépendance externe n’est nécessaire.

- Pour installer sur un iPhone ou iPad physique, sélectionnez votre équipe Apple dans **Signing & Capabilities** et lancez depuis Xcode.
- La version Debug s’appelle **Wave Dev** (`com.wave.notes.dev`) et coexiste avec l’app officielle (`com.wave.notes`) sur la même bibliothèque de notes.

### Build Release macOS local

```sh
Scripts/build_mac.sh
```

Produit `dist/Wave.app` (avec `WaveMCP` intégré) et `dist/Wave.zip`.

### Publier une nouvelle Release macOS

Créer et pousser un tag sémantique déclenche automatiquement GitHub Actions et publie `Wave.zip` + `Wave.zip.sha256` dans une Release GitHub publique :

```sh
git tag v1.1.0
git push origin v1.1.0
```

Vous pouvez aussi tester, compiler et publier une Release directement depuis votre Mac via `gh` :

```sh
Scripts/release_mac.sh v1.1.0
```

---

## Vérifications, tests et benchmarks

```sh
# Tests unitaires Swift (WaveCore + WaveEditor)
swift test --scratch-path .build/Tests

# Tests d’intégration du serveur MCP (38 échanges)
python3 Scripts/test_mcp.py .build/Tests/debug/WaveMCP

# Vérifications de bibliothèque (600 notes, cache, corbeille, modifications externes)
swiftc -O Sources/WaveCore/*.swift App/Theme.swift App/WaveStore.swift Scripts/test_library.swift -o .build/library-checks
.build/library-checks
```

Benchmarks synthétiques (600 notes, document de ~180 Ko) :

```sh
swiftc -O Sources/WaveCore/*.swift Scripts/benchmark.swift -o .build/wave-benchmark && .build/wave-benchmark
swiftc -O Sources/WaveCore/*.swift Sources/WaveEditor/WritingTextView.swift Scripts/benchmark_writer.swift -o .build/writer-benchmark && .build/writer-benchmark
```

Voir aussi le rapport d’audit détaillé dans [docs/AUDIT_2026-10-05.md](docs/AUDIT_2026-10-05.md).

---

## Architecture du projet

```text
App/                     Interface SwiftUI, aperçu WebKit, mises à jour, polices et icône
Sources/WaveCore/        Modèles, recherche, Markdown, exports et stockage coordonné
Sources/WaveEditor/      Éditeur AppKit/UIKit et coloration incrémentale
Sources/WaveMCP/         Serveur MCP JSON-RPC sur stdio
Tests/WaveCoreTests/     Tests unitaires du cœur, des exports et du stockage
Tests/WaveEditorTests/   Tests unitaires de l’éditeur et de la coloration
Scripts/                 Build macOS, tests MCP/bibliothèque et benchmarks
Wave.xcodeproj/          Projet Xcode macOS, iPadOS et iOS
.github/workflows/       CI (tests + build) et publication automatique des Releases macOS
```

---

## Contribuer, sécurité & licence

- **Contribuer** : consultez [CONTRIBUTING.md](CONTRIBUTING.md) et le [Code de conduite](CODE_OF_CONDUCT.md).
- **Sécurité** : pour signaler une vulnérabilité, consultez [SECURITY.md](SECURITY.md).
- **Licence** : le code source de Wave est distribué sous licence **MIT** (voir [LICENSE](LICENSE)).
- **Polices** : les polices **iA Writer Mono, Duo et Quattro** proviennent du dépôt officiel [iA-Fonts](https://github.com/iaolo/iA-Fonts) (Copyright Information Architects Inc. et IBM Corp.) et sont distribuées sous **SIL Open Font License 1.1** (licences incluses dans `App/Fonts/`).
