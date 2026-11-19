# Journal des versions

Ce journal résume les changements publiés. Le guide d’utilisation et le détail des mises à jour se trouvent dans le [README](README.md).

## 1.1.0 — Publication open-source (MIT) & hors ligne

- **Publication open-source sous licence MIT** : les mises à jour macOS vérifient directement les Releases publiques sans token GitHub requis (token conservé en option dans le Trousseau).
- **Architecture 100 % hors ligne & zéro CPU au repos** : surveillance événementielle `NSFilePresenter` (fin du polling toutes les 5 s), sauvegarde coordonnée non bloquante, détection réseau `NWPathMonitor` (zéro requête hors ligne), aperçu `WKWebView` créé à la demande et respect du mode économie d’énergie.
- **Mode sombre complet** : palette dynamique clair/sombre dans l’interface, l’éditeur, l’aperçu Markdown et la carte d’idées.
- **Nouvelles fonctionnalités d’écriture** : Ouverture rapide (`⌘O`), Note du jour (`⇧⌘D`), modèles intégrés, vue Tâches globale interactive, autocomplétion `[[liens internes]]`, panneau Sommaire / Rétroliens / Historique local, Rechercher & remplacer, renommage/suppression de dossiers, collage de captures d’écran et glisser-déposer de pièces jointes.
- **Serveur MCP enrichi** : ajout des outils `list_tasks`, `list_tags` et `read_backlinks` en plus de l’écriture opt-in sécurisée par révision SHA-256.

## 1.0.9 — 5 octobre 2026

- La concentration reste limitée à la zone visible quand le curseur est hors écran ; les emoji restent entièrement mis en forme, même dans une très longue ligne.
- Une demande de mise en forme liée au défilement reste conservée si une autre mise à jour de l’éditeur intervient avant son application.
- Les résultats de recherche sont réutilisés tant que la requête et les notes ne changent pas. Vérifications du cache sur 600 notes temporaires.
- Les modifications externes d’une note sans brouillon actif s’affichent dans l’éditeur après le rafraîchissement de la bibliothèque.
- La mise à la Corbeille depuis l’éditeur enregistre les dernières modifications avant le déplacement. Les suppressions dans la Corbeille invalident les rafraîchissements en cours.
- Nettoyage des observateurs SwiftUI obsolètes sur iOS, avec conservation de la compatibilité macOS 13. Trois tests de non-régression de l’éditeur et mesure de concentration hors écran ; calcul du p95 corrigé pour les petites séries.

## 1.0.8 — 4 octobre 2026

- Le serveur MCP peut créer et modifier des notes après activation de l’écriture dans **IA & appareils**. La configuration copiée au client transmet cette autorisation.
- `update_note` exige la révision retournée par `read_note` et refuse d’écraser une note modifiée depuis sa lecture.
- Tests du mode lecture seule, des écritures, des déplacements de dossier, des conflits et des pièces jointes conservées.

## 1.0.7 — 4 octobre 2026

- La mise en forme du texte est différée et limitée à la zone visible pendant la saisie et le défilement, pour garder l’éditeur réactif sur les longs documents.
- La sélection reste lisible en noir, y compris en mode concentration ; le texte non sélectionné retrouve sa couleur après changement de mode.
- Les commandes Markdown modifient seulement la sélection, rendent le clavier à l’éditeur et ne se répètent plus après un passage dans l’aperçu.
- Tests de frappe Unicode répétée, de sélection et de mise en forme sur un document long.

## 1.0.6 — 4 octobre 2026

- Réglages et navigation réorganisés avec des libellés plus courts et une présentation plus cohérente sur Mac et iPhone.
- Vérification des mises à jour renforcée : contrôle de l’archive, de sa signature et de la version de l’app avant installation.
- Rafraîchissement de la bibliothèque accéléré grâce à une vérification légère des fichiers modifiés ; moins de chargements inutiles.
- Nettoyage du code et retrait de l’identifiant d’équipe Apple du projet pour faciliter la contribution.

## 1.0.5 — 4 octobre 2026

- **Écriture fluide sur les longs documents** : le style (titres, gras, italique, code) n’est plus recalculé sur tout le document à chaque frappe, mais uniquement sur la zone visible ; une passe complète suit dès que la frappe s’arrête. Le coût par frappe passe de ~8–23 ms à moins de 1 ms sur un long document.
- **Le scroll ne saute plus pendant l’écriture** : appliquer le style ne déplace plus la position de lecture ; seules les frappes font défiler la page.
- Détection de la phrase / du paragraphe limitée à une fenêtre autour du curseur et expressions régulières mises en cache (documents longs).

## 1.0.4 — 4 octobre 2026

- **Corbeille** : les documents se suppriment en glissant vers la gauche (iPhone/iPad), depuis le menu contextuel ou avec `⌘⌫` (Mac) — au lieu d’une suppression définitive.
- Nouvelle entrée **Corbeille** dans la barre latérale : récupérer un document, le supprimer définitivement ou vider la corbeille. Les documents y restent **30 jours**, puis sont supprimés automatiquement.

## 1.0.3 — 4 octobre 2026

- Nouvelle page **Réglages** dans l’app (barre latérale → ⚙︎, ou menu ⋯ → Réglages) : token GitHub, état des mises à jour, version et emplacement des notes.
- Ouverture fiabilisée de la fenêtre Réglages macOS (`⌘,`) depuis la bannière de mise à jour.

## 1.0.2 — 4 octobre 2026

**Mises à jour automatiques**

- L’app officielle vérifie les nouvelles Releases de `besty-boy/waves` au lancement et toutes les 6 heures, puis propose une bannière **Mettre à jour** : téléchargement de `Wave.zip`, remplacement de l’app et relance automatique. Options **Plus tard** et **Ignorer cette version**.
- Accès au dépôt privé avec un token GitHub fine-grained (« Contents : Read »), conservé dans le trousseau macOS et configuré une seule fois dans **Réglages (`⌘,`) → Token GitHub**.
- Menu **Wave → Rechercher des mises à jour…** pour vérifier manuellement.

**Deux applications**

- **Wave** (`com.wave.notes`) : l’app officielle, installée depuis les Releases GitHub.
- **Wave Dev** (`com.wave.notes.dev`) : le build Debug de Xcode. Les deux coexistent et partagent les mêmes notes.

**Publication**

- La version de l’app est reprise du tag par la CI : publier une version revient à `git tag vX.Y.Z && git push origin vX.Y.Z`.

## 1.0.1 — 4 octobre 2026

**Nouvelle icône**

- L’icône Icon Composer (`App/AppIcon.icon`, trois vagues sur fond ivoire) remplace l’ancienne icône du catalogue.
- Rétrocompatibilité : l’artwork est coloré directement, sans fond de couche derrière un masque SVG, pour éviter le rectangle bleu sur iOS/macOS antérieurs à 26.

## 1.0.0 — Version initiale

Première version publique de Wave : écriture, bibliothèque, recherche, carte d’idées, contexte pour l’IA (MCP), exports Markdown, HTML, PDF et Word.
