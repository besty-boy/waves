# Contribuer à Wave

Merci de votre intérêt pour **Wave** ! Les rapports de bugs, suggestions d’améliorations et Pull Requests sont les bienvenus.

## Principes du projet

Wave suit trois règles simples :

1. **100 % hors ligne par défaut** : aucune télémétrie, aucun appel réseau non sollicité, et respect strict des fichiers Markdown locaux.
2. **Zéro dépendance externe** : uniquement les frameworks natifs Apple (SwiftUI, AppKit, UIKit, Foundation, NaturalLanguage, WebKit, CryptoKit, Network).
3. **Sobriété & réactivité** : pas de polling périodique, coloration incrémentale de l’éditeur, compatibilité **macOS 13+** et **iOS/iPadOS 17+**.

## Environnement de développement

- **macOS** avec **Xcode 16+** (Xcode 26+ recommandé pour Liquid Glass et Icon Composer).
- **Python 3** (pour les tests d’intégration MCP).

Ouvrez `Wave.xcodeproj` dans Xcode et sélectionnez le schéma **Wave** :
- Le build **Debug** crée **Wave Dev** (`com.wave.notes.dev`) et n’interfère pas avec une installation officielle de **Wave** (`com.wave.notes`).
- **Ne committez jamais votre `DEVELOPMENT_TEAM`** dans `Wave.xcodeproj/project.pbxproj`.

## Lancer les vérifications avant une Pull Request

```sh
# 1. Tests unitaires Swift (WaveCore + WaveEditor)
swift test --scratch-path .build/Tests

# 2. Tests d’intégration du serveur MCP
python3 Scripts/test_mcp.py .build/Tests/debug/WaveMCP

# 3. Tests du modèle de bibliothèque (600 notes)
swiftc -O Sources/WaveCore/*.swift App/Theme.swift App/WaveStore.swift Scripts/test_library.swift -o .build/library-checks
.build/library-checks
```

Si vous modifiez l’éditeur ou le stockage, vérifiez également les benchmarks :

```sh
swiftc -O Sources/WaveCore/*.swift Scripts/benchmark.swift -o .build/wave-benchmark && .build/wave-benchmark
swiftc -O Sources/WaveCore/*.swift Sources/WaveEditor/WritingTextView.swift Scripts/benchmark_writer.swift -o .build/writer-benchmark && .build/writer-benchmark
```

## Soumettre une Pull Request

1. Créez une branche dédiée depuis `main` (`fix/...`, `feat/...`, `docs/...`).
2. Gardez des commits clairs, ciblés et atomiques.
3. Ajoutez ou mettez à jour les tests unitaires / MCP couvrant votre modification.
4. Mettez à jour `CHANGELOG.md` si le changement est visible pour les utilisateurs.
5. Ouvrez une Pull Request en remplissant le modèle proposé et vérifiez que la CI passe au vert.

## Signaler un bug ou proposer une idée

Utilisez les [GitHub Issues](https://github.com/besty-boy/waves/issues/new/choose) en choisissant le modèle adapté (**Rapport de bug** ou **Proposition de fonctionnalité**).
