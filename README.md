# MySpotify

Un vinyle avec la pochette de la musique Spotify en cours, qui tourne pendant la lecture.

- **Coin en bas à gauche** : le disque reste caché dans le coin. Passe la souris dessus pour l'ouvrir. La carte contient la progression (cliquable), les commandes de lecture, l'aléatoire, la répétition et le volume, plus des boutons pour copier le lien, ouvrir Spotify, ❤️ J'aime, 🎵 À suivre et 💬 Paroles synchronisées.
  - Clic sur le disque : lecture / pause. Faire tourner le disque à la main (scratch) : avance ou recule (1 tour = 4 s).
- **Bureau** : un grand vinyle fixe, centré sur le bureau, avec un bras de lecture. Une onde suit le son et pulse sur les kicks, et les paroles défilent en dessous.
- **Changement de morceau** : l'ancien disque sort, le nouveau arrive, et les couleurs glissent de l'une à l'autre.
- **Menu ◎** : style (vinyle noir / picture disc), taille, vitesse (Douce / 33 / 45 tours), intensité de l'onde, bras, paroles, masquage en plein écran, compte Spotify, ouverture au démarrage.

## Construire

```sh
./build.sh           # → build/MySpotify.app
./build.sh install   # → /Applications/MySpotify.app (et la lance)
swift Tools/MakeIcon.swift . && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns   # régénérer l'icône
```

L'app est signée avec le certificat local « MySpotify Local Signing » (dans le trousseau de session). Ainsi, macOS garde les autorisations d'une compilation à l'autre. S'il est absent, la signature est ad hoc.

## Autorisations

1. **Contrôler Spotify** (AppleScript) : titre, pochette, commandes.
2. **Enregistrer l'audio du système** : pour l'onde. Seul le son de Spotify est analysé, rien n'est enregistré. Sans cette autorisation, l'onde est simulée.
3. **Compte Spotify** (facultatif, menu ◎ → Connecter) : J'aime et file d'attente. Cela passe par l'app développeur « MySpotify » sur developer.spotify.com (Client ID dans `Sources/Config.swift`, connexion PKCE, jeton dans le Trousseau, à renouveler tous les 180 jours).

Les paroles viennent de [LRCLIB](https://lrclib.net), qui ne reçoit que le titre, l'artiste, l'album et la durée.

## Performances

- La rotation des disques est faite par Core Animation, donc sans coût pour l'app.
- L'onde du bureau est redessinée 30 fois par seconde et se met en pause quand la roue est entièrement cachée par des fenêtres.
- Ordre de grandeur : environ 1,5 % de CPU en pause, environ 3 % avec le coin seul, environ 15 % avec la roue du bureau visible pendant la lecture.
