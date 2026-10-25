# Parité site ↔ application

Le laboratoire en ligne et l'application iOS partagent **le même moteur de rendu** :
`site/src/grade.rs` (Rust, WebGL2) et `Packages/ApertisCore` (Swift, Core Image) font
les mêmes calculs. `Packages/ApertisCore/Tests/ApertisCoreTests/Resources/parity.json`
est produit par le moteur du site ; les tests Swift vérifient que l'app rend les mêmes
couleurs (écart maximal mesuré : 5·10⁻⁷), les mêmes styles et le même cadrage.
`cargo test` échoue si le fichier n'est plus à jour (`UPDATE_PARITY=1 cargo test`).

| Fonction | Site (labo photo / vidéo) | App photo | App vidéo |
|---|---|---|---|
| 9 styles (Original, Naturel, Portra, Kodachrome, Cinéma, Nordique, Heure dorée, Noir et blanc, N&B doux) | ✓ / ✓ | ✓ vignettes | ✓ |
| Styles personnels | — | ✓ Mes styles | ✓ |
| Lumière : exposition, contraste, hautes lumières, ombres, blancs, noirs | ✓ / ✓ | ✓ | ✓ |
| Couleur : température, teinte, vibrance, saturation | ✓ / ✓ | ✓ | ✓ |
| Courbe paramétrique 4 zones | ✓ / ✓ | ✓ | ✓ |
| Courbes à points RVB | — | ✓ | — |
| TSL 8 plages | ✓ / ✓ | ✓ | ✓ |
| Étalonnage 3 voies (+ fondu) | ✓ / ✓ | ✓ (+ luminosité) | ✓ |
| Effets : fondu, grain, taille du grain, vignette, netteté | ✓ / ✓ | ✓ | ✓ |
| LUT 3D .cube, réduction du bruit | — | ✓ | ✓ LUT |
| Formats Original, 1:1, 4:5, 3:2, 4:3, 16:9, 9:16 + redressement | ✓ / ✓ | ✓ | ✓ format du film |
| Rotation 90°, miroir | ✓ / — | ✓ | — |
| Histogramme RVB et alerte d'écrêtage | ✓ / ✓ | ✓ | — |
| Avant / après | ✓ / ✓ | ✓ | ✓ |
| Annuler / rétablir | ✓ / ✓ | ✓ historique | — |
| Recettes JSON (`apertis-recette`, version 1) | ✓ / — | ✓ copier, coller, fichier | — |
| Entrée, sortie, export | ✓ / ✓ | export JPEG, HEIF, HEIF 10 bits, TIFF 16 bits | coupe, vitesse, ordre, musique, HEVC / H.264 |

Une recette exportée par l'app s'ouvre dans le laboratoire en ligne et inversement. Les
réglages propres à l'app (courbes à points, réduction du bruit, luminosité des roues)
voyagent sous des clés que le site ignore.

## Formules

Identiques à la carte « Tarifs » du site.

- **Gratuit** : caméra photo et vidéo en mode P (correction d'exposition), RAW et ProRAW,
  balance des blancs et mise au point manuelles, histogramme et niveau ; lumière, couleur,
  effets, cadrage ; styles Original, Naturel et Noir et blanc, styles personnels ; montage
  simple (un étalonnage pour tout le montage) ; exports JPEG et HEIF sans filigrane.
- **Pro, 7,99 € par mois** (sans engagement, 7 jours d'essai, produit
  `fr.apertis.pro.mensuel`) :
  - appareil photo : modes A, S, M et ouverture variable, focus peaking, zébras, fausses
    couleurs, loupe, bracketing, pose longue, intervallomètre, balance des blancs sur
    charte grise, traitement minimal, priorités de l'automatisme, cadres de visée,
    réglages personnels C1 à C3 ;
  - retouche : courbes, TSL, étalonnage, LUT 3D, réduction du bruit RAW, tous les styles ;
  - vidéo : étalonnage plan par plan, piste musique ;
  - export HEIF 10 bits et TIFF 16 bits.

À la fin de l'abonnement, l'appareil revient en mode P avec les aides désactivées.
Un projet créé avec des outils Pro s'ouvre, s'affiche et s'exporte toujours après la fin
de l'abonnement ; seuls ces outils ne sont plus modifiables.
