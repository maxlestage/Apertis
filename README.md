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
