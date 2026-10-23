# VoxFlowAir

Traitement vocal en temps réel pour macOS. VoxFlowAir capte votre micro, le fait passer dans une chaîne
de plugins Audio Units et de nœuds intégrés que vous construisez dans un éditeur de nœuds, puis envoie
le résultat :

- vers un **micro virtuel** qu'OBS, FaceTime, Zoom, Discord et les autres applications choisissent comme
  entrée ;
- vers votre **casque** (monitoring), avec son propre niveau.

<!-- Screenshot: save it as Docs/images/main-window.png, then replace this comment with ![Fenêtre principale de VoxFlowAir](Docs/images/main-window.png) -->

La documentation détaillée est en anglais : voir le [README anglais](README.md). L'interface de
l'application est disponible en français.

## Fonctionnalités

- Éditeur de nœuds : branches parallèles, sections, contournement par nœud ou par section.
- Tous les effets Audio Units installés (AUv2 et AUv3), chargés par défaut dans un processus isolé.
- Nœuds intégrés : Gain, Analyseur, sortie monitoring dédiée.
- Trois commandes indépendantes : MONITOR, MUTE OUT, BYPASS (à niveau compensé).
- Presets avec import et export, vumètres, spectre, oscilloscope, phase, sonie LUFS.
- Moniteurs de mesure sur l'entrée et la sortie, retour d'appel, panneau dans la barre des menus.
- Micro virtuel facultatif « VoxFlowAir Micro », renommable par preset.

## Configuration requise

- Mac Apple Silicon, macOS 26 ou plus récent, Xcode 26 ou plus récent pour compiler.
- Un périphérique virtuel : [BlackHole 2ch](https://existential.audio/blackhole/) ou le pilote
  « VoxFlowAir Micro » fourni.

## Installation

Pas encore de binaire notarisé : compilez depuis les sources.

```bash
git clone https://github.com/Kede0111/VoxFlowAir.git
cd VoxFlowAir
Scripts/build-xcode.sh      # application, pilote et outil (Release, signature ad hoc)
Scripts/install.sh          # copie dans /Applications et lance l'application
```

Une copie compilée sur un autre Mac est bloquée par Gatekeeper la première fois : Réglages Système ›
Confidentialité et sécurité › **Ouvrir quand même**. Détails :
[Docs/INSTALLATION.md](Docs/INSTALLATION.md).

## Démarrage rapide

1. Sortie virtuelle : si aucune n'est trouvée, un bandeau propose d'installer BlackHole 2ch ; pour
   « VoxFlowAir Micro » (conseillé pour les appels), passez par l'onglet Sortie virtuelle des réglages,
   qui lance l'installation dans le Terminal.
2. Choisissez le micro dans Réglages › Audio.
3. Double-cliquez sur un plugin de la bibliothèque pour l'ajouter en fin de chaîne. Un nouveau preset
   relie simplement l'entrée micro à la sortie virtuelle.
4. Dans OBS, FaceTime… choisissez **BlackHole 2ch** ou **VoxFlowAir Micro** comme micro.

Guide complet : [Docs/USAGE.md](Docs/USAGE.md).

## Ajouter vos Audio Units

Installez le plugin avec son installateur, ou copiez son `.component` dans
`/Library/Audio/Plug-Ins/Components` ou `~/Library/Audio/Plug-Ins/Components`, puis relancez la recherche
des plugins (onglet Plugins des réglages, ou bouton ↻ sous la bibliothèque). Les extensions AUv3 fournies par des applications sont aussi reconnues.
Réglages › Plugins permet d'afficher tous les plugins ou seulement ceux que vous choisissez, de masquer
des plugins et de changer leur catégorie (clic droit dans la bibliothèque). Un dossier personnalisé est
impossible : c'est macOS qui recense les Audio Units, pas l'application. Voir
[Adding your own Audio Units](README.md#adding-your-own-audio-units).

## Documentation

| Document | Contenu |
|---|---|
| [Docs/INSTALLATION.md](Docs/INSTALLATION.md) | Compilation, installation, mise à jour, désinstallation |
| [Docs/USAGE.md](Docs/USAGE.md) | Interface, éditeur de nœuds, presets, réglages |
| [Docs/METER-MONITORS.md](Docs/METER-MONITORS.md) | Moniteurs de mesure |
| [Docs/TROUBLESHOOTING.md](Docs/TROUBLESHOOTING.md) | Dépannage, appels et annulation d'écho |
| [Docs/LIMITATIONS.md](Docs/LIMITATIONS.md) | État et limitations connues |
| [Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md) | Fonctionnement interne |
| [Docs/VIRTUAL-DEVICE.md](Docs/VIRTUAL-DEVICE.md) | Sortie virtuelle et pilote VoxFlowAir Micro |
| [Docs/BUILDING.md](Docs/BUILDING.md) | Projet Xcode, tests, installateur, signature, CI |

## Contribuer

Voir [CONTRIBUTING.md](CONTRIBUTING.md). Les rapports de bug, de compatibilité de plugins et les
traductions sont bienvenus.

## Soutenir le projet

VoxFlowAir est gratuit. S'il vous est utile, un don aide à le faire vivre : bouton de don dans
l'onglet « À propos » des réglages, ou bouton **Sponsor** de la page GitHub du dépôt.

## Licence

[MIT](LICENSE) © 2026 Quentin Descotte. BlackHole est un projet distinct d'Existential Audio (GPL-3.0),
non inclus.
