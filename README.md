# PixelBox

**PixelBox** est un émulateur de jeux **J2ME / Java ME** (fichiers `.jar` de vieux téléphones à clapet et Nokia) écrit entièrement en **Flutter / Dart**. Il n'utilise aucune machine virtuelle Java : le bytecode des jeux est lu et exécuté par un interpréteur écrit pour le projet.

> **État du projet : expérimental.** Plusieurs jeux démarrent et s'affichent, mais la compatibilité est partielle (voir [Limites connues](#limites-connues)). PixelBox ne contient aucun jeu : il faut fournir ses propres fichiers `.jar`.

## Fonctionnalités

- Ouverture d'un `.jar` depuis Fichiers, iCloud ou AirDrop, lecture du manifeste (`MIDlet-1`, version, éditeur, profil MIDP) et choix du MIDlet à lancer.
- Interpréteur de bytecode Java : classes, héritage, interfaces, exceptions, tableaux, `long` et `double` sur deux emplacements de pile, plusieurs threads Java exécutés à tour de rôle.
- **MIDP / LCDUI** : `Canvas`, `GameCanvas`, `Graphics` (rectangles, lignes, arcs, triangles, texte, images avec les 8 transformations), `Image` (décodage PNG), `Font`, `Display`, `Command` déclenchées par les touches Menu et Retour.
- **Entrées** : croix directionnelle, touches 0 à 9, `*`, `#`, touches Menu et Retour. Un mode « 2 4 6 8 » remplace les flèches pour les jeux qui lisent le pavé numérique.
- **Bibliothèque Java** (sous-ensemble de CLDC 1.1) : `String`, `StringBuffer`, `Integer`, `Math`, `System`, `Thread`, `Runtime`, `Class`, `Random`, `Vector`, `Stack`, `Hashtable`, `Enumeration`, flux d'entrée/sortie (`DataInputStream`, `ByteArrayInputStream`…), ressources du JAR avec `getResourceAsStream`.
- **Sauvegardes (RMS)** : `RecordStore` et énumération des enregistrements.
- **Audio** : `javax.microedition.media` (`Manager`, `Player`, `VolumeControl`, `PlayerListener`) et `Manager.playTone`.
- **Compatibilité Nokia** : `FullCanvas`, `DeviceControl` (sans effet).
- Interface iOS native avec le paquet `cupertino_native_better` (boutons et verre « Liquid Glass »).

## Comment ça marche

```
.jar  →  JarPackage  →  ClassFile  →  Vm (interpréteur)  →  Midp (Canvas, Graphics)  →  Surface ARGB  →  image Flutter
          (zip,          (constant      threads, pile,         natives Java et MIDP        240×320
        manifeste)         pool, code)   exceptions                                          pixels
```

1. `JarPackage` décompresse le `.jar` en mémoire et lit le manifeste.
2. `ClassFile` analyse chaque fichier `.class` (constant pool, méthodes, attribut `Code`).
3. `Vm` exécute le bytecode par tranches de quelques milliers d'instructions, dans une limite de temps par image, pour ne pas bloquer l'interface.
4. Les appels aux classes Java standard sont des **méthodes natives** écrites en Dart (`natives.dart`, `java_library.dart`, `midp.dart`, `rms.dart`).
5. Les images dessinées par le jeu sont stockées dans une `Surface` (pixels ARGB) puis converties en image Flutter, à l'écran à environ 60 images par seconde.

### Structure du dépôt

```
lib/
├── main.dart, theme.dart
├── audio/
│   └── audio_engine.dart      moteur audio utilisé par javax.microedition.media
├── j2me/
│   ├── jar_loader.dart        .jar + manifeste
│   ├── class_parser.dart      format .class
│   ├── emulator_session.dart  une partie : crée la VM, la fait avancer, expose l'image
│   ├── key_codes.dart         touches et actions de jeu
│   ├── gfx/                   surface de pixels, primitives de dessin, polices
│   └── vm/
│       ├── vm.dart            interpréteur, threads, exceptions
│       ├── runtime.dart       classes, objets, tableaux, cadres d'exécution
│       ├── natives.dart       java.lang de base
│       ├── java_library.dart  flux, collections, String/Integer, audio, classes Nokia
│       ├── midp.dart          Canvas, Graphics, Image, Display
│       └── rms.dart           sauvegardes (RecordStore)
└── ui/
    ├── home_screen.dart       choix du jeu
    ├── player_screen.dart     écran de jeu et commandes
    └── widgets/               croix directionnelle, boutons de jeu
```

## Installation

Prérequis : Flutter (une version récente : `cupertino_native_better` demande un Dart récent, voir sa documentation), Xcode, un iPhone ou un simulateur.

```bash
git clone <url-du-depot>
cd pixelbox
flutter pub get
flutter run --release
```

> Lance de préférence en **mode release** (`--release`) ou `--profile` : en mode debug, l'interpréteur est beaucoup plus lent et les mesures de performance ne veulent rien dire.

Ensuite, ouvre un fichier `.jar` depuis l'écran d'accueil et appuie sur **Lancer le jeu**.

## Diagnostiquer un jeu qui ne marche pas

L'émulateur écrit son journal dans la console de Flutter, avec le préfixe `[J2ME]`. Il contient notamment :

- `Moteur : N classes, M natives.` : l'état du moteur au démarrage ;
- `Classe manquante : …` ou `Méthode non implémentée : …` : le jeu appelle une classe ou une méthode Java que PixelBox ne connaît pas encore ;
- `Exception non rattrapée (thread) : …` suivie de la pile d'appels du jeu ;
- `Perf : …` et `Images du jeu : …` : mesures de vitesse toutes les 3 secondes.

### Ajouter une méthode manquante

Les méthodes natives sont enregistrées dans un dictionnaire, avec la clé `classe.méthode(descripteur)` :

```dart
n['java/lang/Integer.valueOf(Ljava/lang/String;)Ljava/lang/Integer;'] =
    (vm, t, a) => JObject(intClass)..native = parse(a[0], 10);
```

- `a` contient les arguments, **récepteur en premier** pour une méthode d'instance ; un `long` ou un `double` compte pour **un seul** argument.
- Un `boolean` se renvoie en `1` ou `0`, un `void` en `null`.
- Une exception Java se lève avec `throw JavaThrow('java/lang/NumberFormatException', 'message')`.
- Les classes natives se déclarent avec `vm.defineClass(nom, classeParente)`.

## Limites connues

- **Écrans de haut niveau absents** : `Form`, `List`, `Alert`, `TextBox`, `Ticker`. `Display.setCurrent` n'accepte que les `Canvas`.
- **Résolution fixe** de 240×320 (certains jeux visent 128×160 ou 176×208).
- **Bibliothèque incomplète** : les classes `Long`, `Boolean`, `Short`, `Byte`, `Float`, `Double`, `Date`, `Calendar`, `Timer` et plusieurs méthodes de `String` ne sont pas encore toutes présentes.
- **Pas de réseau** (`HttpConnection`, sockets), de SMS, de Bluetooth, ni de graphismes 3D (M3G).
- `synchronized` et `wait`/`notify` sont simplifiés, `Thread.join` et `isAlive` ne reflètent pas l'état réel du thread.
- `Hashtable` ne compare par valeur que les clés `String` et `Integer`. Les filtres et comparateurs de `RecordStore.enumerateRecords` sont ignorés.
- Les arcs et rectangles à coins arrondis sont dessinés de façon approximative.
- **Performance** : l'interpréteur est écrit en Dart pur. Certains jeux sont lents, surtout en mode debug.

## Légal

PixelBox est un projet d'émulation à but éducatif. Il ne fournit, ne télécharge et ne distribue aucun jeu. N'utilise que des fichiers `.jar` que tu as le droit d'utiliser.
