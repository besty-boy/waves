## Résumé

<!-- Décrivez brièvement les changements apportés et pourquoi ils sont nécessaires. -->

## Type de changement

- [ ] Correction de bug
- [ ] Nouvelle fonctionnalité
- [ ] Performance / refactoring
- [ ] Documentation / CI

## Vérifications

- [ ] `swift test --scratch-path .build/Tests` passe sans erreur
- [ ] `python3 Scripts/test_mcp.py .build/Tests/debug/WaveMCP` passe sans erreur
- [ ] `Scripts/test_library.swift` passe sans erreur
- [ ] Compilation Xcode (`Wave`, macOS) sans erreur
- [ ] `CHANGELOG.md` mis à jour (si changement visible utilisateur)
- [ ] Aucun `DEVELOPMENT_TEAM` ni secret commité
