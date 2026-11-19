# Politique de sécurité

## Versions prises en charge

Seule la dernière version publiée sur la page [Releases](https://github.com/besty-boy/waves/releases/latest) reçoit les correctifs de sécurité.

## Garanties de sécurité intégrées

- **Exécution locale & hors ligne** : Wave ne collecte aucune télémétrie et n’envoie jamais vos notes sur des serveurs tiers. Les vérifications de mise à jour macOS sont désactivées hors ligne (`NWPathMonitor`).
- **Mises à jour vérifiées** : l’outil de mise à jour macOS vérifie la taille de l’archive, sa somme **SHA-256** fournie par GitHub, la signature `codesign --verify --deep --strict`, l’identifiant de bundle et la version avant tout remplacement.
- **Serveur MCP sécurisé par défaut** :
  - Lecture seule par défaut (`WAVE_MCP_WRITE=0`).
  - L’accès aux pièces jointes empêche toute traversée de répertoire (`../`).
  - En mode écriture opt-in, `update_note` impose le contrôle de révision SHA-256 (`read_note` préalable requis) pour éviter tout écrasement concurrent.
- **Aperçu Markdown** : l’aperçu HTML échappe le HTML brut et bloque les liens exécutables (`javascript:`, etc.).

## Signaler une vulnérabilité

**Merci de ne pas ouvrir d’issue publique pour une faille de sécurité.**

Utilisez plutôt les [GitHub Security Advisories](https://github.com/besty-boy/waves/security/advisories/new) du dépôt pour signaler le problème de manière privée, en précisant :

- La version de Wave et le système (macOS / iOS / iPadOS) concernés.
- Une description claire de la vulnérabilité et de son impact potentiel.
- Les étapes de reproduction ou une preuve de concept minimale.

Vous recevrez un accusé de réception dès que possible afin de coordonner un correctif avant toute divulgation publique.
