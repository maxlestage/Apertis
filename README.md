# Apertis

Caméra professionnelle, laboratoire photo RAW et studio vidéo pour iPhone et iPad — 100 % Swift.

- **Caméra** : photo HEIF, RAW (DNG Bayer) et Apple ProRAW selon l'appareil ; exposition, ISO, vitesse,
  balance des blancs (Kelvin/teinte) et mise au point manuelles ; vidéo jusqu'en 4K, HDR (HLG) et Apple Log
  quand l'objectif les propose ; HEVC, H.264 et ProRes ; vumètre audio ; verrouillage AE/AWB.
- **Retouche photo non destructive** : développement RAW via `CIRAWFilter`, lumière, couleur, courbes
  RVB par canal, TSL 8 plages, étalonnage 3 voies, LUT 3D `.cube`, fondu, grain, vignette, netteté,
  réduction du bruit, redressement et recadrage, styles intégrés, historique annuler/rétablir,
  comparaison avant/après (appui long), export JPEG / HEIF / HEIF 10 bits / TIFF 16 bits.
- **Studio vidéo** : timeline à temps exacts (alignés sur les images), coupe, découpe entrée/sortie,
  réorganisation, ralenti/accéléré, piste musique, volume par plan, étalonnage par plan appliqué en direct,
  copie de l'étalonnage vers tous les plans, export HEVC/H.264 jusqu'en 4K.
- **Local et privé** : aucun cloud. Les originaux ne sont jamais modifiés ; projets versionnés,
  enregistrés de façon atomique ; tout est visible dans l'app Fichiers.

Le site et l'application rendent les images de la même façon : voir [PARITE.md](PARITE.md).

## Architecture

```
Apertis/
├── project.yml                  # projet Xcode (XcodeGen)
├── Packages/ApertisCore/        # cœur Swift pur (Foundation), testé sur macOS et Linux
│   ├── DevelopSettings.swift    # réglages de développement, décodage tolérant
│   ├── ColorGradeProcessor.swift# étape couleur de référence → cube 3D GPU
│   ├── ToneCurve.swift          # courbes cubiques monotones
│   ├── CubeLUT.swift            # LUT .cube
│   ├── EditHistory.swift        # historique non destructif
│   ├── Projects.swift           # projets photo/vidéo versionnés, détection des originaux manquants
│   ├── Timeline.swift           # timeline multipiste validée
│   ├── Rational.swift           # temps exacts (→ CMTime)
│   ├── CaptureCapabilities.swift# matrice des modes caméra réellement disponibles
│   └── Presets.swift            # styles
└── Apertis/                     # application SwiftUI
    ├── Camera/                  # AVFoundation : capture photo/RAW/vidéo, réglages manuels
    ├── Rendering/               # Core Image + Metal : pipeline de rendu partagé photo/vidéo
    ├── PhotoEditor/             # éditeur photo, éditeur de courbes, export
    ├── VideoEditor/             # timeline → AVComposition, étalonnage par plan, export
    ├── Library/                 # bibliothèque, import Photos/Fichiers
    └── Shared/                  # stockage local, enregistrement dans Photos
```

### Pipeline de rendu

Un seul pipeline sert à l'aperçu, à l'export photo et à chaque image vidéo, ce qui garantit que
l'export correspond à l'aperçu :

1. **Géométrie** — redressement, recadrage.
2. **Linéaire** — dématriçage RAW (`CIRAWFilter` : exposition, balance des blancs, bruit), ou pour les
   images développées : gains de balance des blancs et exposition en lumière linéaire ; puis
   récupération des hautes lumières et débouchage des ombres.
3. **Couleur** — `ColorGradeProcessor` (points blanc/noir, contraste, courbes, TSL, vibrance,
   saturation, étalonnage, fondu, LUT) est une fonction pure, testée, *cuite* dans un cube 3D appliqué
   sur le GPU par `CIColorCubeWithColorSpace` (33³ en aperçu, 64³ à l'export).
4. **Spatial** — réduction du bruit, netteté, vignette, grain.

### Capacités matérielles

Au démarrage, `CameraController` parcourt les formats de chaque objectif (résolutions, cadences, espaces
couleur) et construit un `CaptureCapabilities`. L'interface ne propose que ces combinaisons ; si un choix
devient impossible (changement d'objectif, par exemple), le mode valide le plus proche est retenu.

## Compiler

Prérequis : Xcode 16 ou plus récent, iOS 17 minimum sur l'appareil.

```sh
brew install xcodegen
xcodegen generate
open Apertis.xcodeproj
```

Choisissez votre équipe de signature dans *Signing & Capabilities*, puis lancez sur un iPhone
(la caméra n'est pas disponible dans le simulateur).

Tests du cœur :

```sh
swift test --package-path Packages/ApertisCore
```

## Site web (Paquets)

Le site d'Apertis est dans [`site/`](site), écrit en Rust avec [Paquets](https://github.com/maxlestage/Paquets) :

- **Accueil** : présentation, comparateur avant/après, fonctionnalités, styles, tarifs, questions
  fréquentes et liste d'accès anticipé (PostgreSQL sur Heroku, sans API publique) ;
- **Labo photo** (`/labo`) : un vrai laboratoire de développement dans le navigateur, sur vos propres
  photos : lumière, couleur, courbe paramétrique, TSL 8 plages, étalonnage 3 voies, grain, vignette,
  netteté, rotation, miroir, recadrage, redressement, 9 styles avec vignettes, histogramme et alerte
  d'écrêtage, avant/après, historique (⌘Z), recettes `.json`, export JPEG/PNG/WebP en pleine résolution ;
- **Labo vidéo** (`/labo/video`) : chaque image est étalonnée en direct pendant la lecture, points
  d'entrée et de sortie, styles, histogramme, export MP4/WebM avec le son ;
- **Confidentialité**, **mentions légales**, page 404.

Le moteur ([`site/src/grade.rs`](site/src/grade.rs)) reprend le pipeline de l'app iOS : étape linéaire
(balance des blancs, exposition), tonalité et couleur cuites dans une LUT 3D 33³, effets. Il tourne sur
le GPU (WebGL2, [`site/src/client`](site/src/client)) et est testé en Rust natif. Tout est calculé sur
l'appareil : aucune image n'est envoyée. Les images de démonstration du site sont développées avec ce
même moteur (`cargo run -p apertis-site --example bake`).

En local :

```sh
cd site && paquets dev          # http://localhost:3000
cargo test -p apertis-site      # depuis la racine
```

### Publier sur GitHub Pages

Le workflow [`.github/workflows/pages.yml`](.github/workflows/pages.yml) publie le site sur
**https://maxlestage.github.io/Apertis/** à chaque commit sur `master` qui touche le site. Il compile
le serveur et les laboratoires, puis exporte le site en fichiers statiques
(`apertis-site export`, liens préfixés par `/Apertis`). Les laboratoires photo et vidéo y fonctionnent
entièrement ; la liste d'accès anticipé, qui a besoin d'un serveur, renvoie vers le projet GitHub.

Activation, une seule fois (possible depuis le téléphone, sur github.com) : *Settings → Pages →
Build and deployment → Source* : **GitHub Actions**, puis *Actions → Deploy to GitHub Pages →
Run workflow*.

En local : `./heroku-build.sh && cd site && BASE_PATH=/Apertis ./target/release/apertis-site export ../dist`.

### Déployer sur Heroku depuis un téléphone

[![Deploy to Heroku](https://www.herokucdn.com/deploy/button.svg)](https://heroku.com/deploy?template=https://github.com/maxlestage/Apertis)

1. **Déployer** : touchez le bouton *Deploy to Heroku* ci-dessus (ou ouvrez
   `https://heroku.com/deploy?template=https://github.com/maxlestage/Apertis`), choisissez un nom et
   touchez **Deploy app**. Heroku lit [`app.json`](app.json), ajoute une base PostgreSQL (pour la liste
   d'attente) et compile le site avec le buildpack Rust ([`RustConfig`](RustConfig),
   [`heroku-build.sh`](heroku-build.sh), [`Procfile`](Procfile)). La première compilation prend 10 à
   20 minutes. Touchez ensuite **View**.
2. **Déploiements automatiques** (facultatif) : sur GitHub, *Settings → Secrets and variables →
   Actions*, ajoutez le secret `HEROKU_API_KEY` (Heroku → *Account settings* → *API Key*) et la
   variable `HEROKU_APP_NAME`. Chaque commit sur `master` qui touche le site est alors redéployé par
   [`.github/workflows/heroku.yml`](.github/workflows/heroku.yml) ; on peut aussi le lancer à la main
   depuis l'onglet *Actions* de l'app GitHub (*Run workflow*).

Coût : Heroku n'a pas d'offre gratuite (dyno Eco ≈ 5 $/mois, Postgres Essential-0 ≈ 5 $/mois).
Pour consulter la liste d'attente : Heroku → l'application → *Resources* → *Heroku Postgres* →
*Dataclips*, requête `select email from inscriptions`.

## État et prochaines étapes

Fait : socle complet décrit ci-dessus. Le cœur est couvert par des tests automatisés ; l'application
est compilée par la CI mais doit encore être validée sur appareils réels.

À venir, par priorité :

1. Validation sur appareils de référence (RAW, ProRAW, 4K HDR, Log, thermique, mémoire).
2. Viseur : histogramme, zébras, focus peaking, niveau à bulle.
3. Retouche locale : masques pinceau, dégradés linéaires/radiaux, sélection du sujet et du ciel (Vision).
4. Vidéo : pistes vidéo superposées et transitions (compositeur personnalisé), titres, scopes
   (waveform, vectorscope), gestion du profil d'entrée Log/HDR et export HDR.
5. Styles personnels, copier/coller des réglages, traitement par lots.
6. Abonnement Pro (StoreKit 2), avec accès garanti aux projets et originaux.
