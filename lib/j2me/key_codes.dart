/// Touches du « téléphone » virtuel.
/// Les codes négatifs suivent la convention Nokia/Sony Ericsson (les plus courants).
enum J2meKey {
  up(-1, '▲'),
  down(-2, '▼'),
  left(-3, '◀'),
  right(-4, '▶'),
  fire(-5, 'OK'),
  softLeft(-6, 'Menu'),
  softRight(-7, 'Retour'),
  num0(48, '0'),
  num1(49, '1'),
  num2(50, '2'),
  num3(51, '3'),
  num4(52, '4'),
  num5(53, '5'),
  num6(54, '6'),
  num7(55, '7'),
  num8(56, '8'),
  num9(57, '9'),
  star(42, '*'),
  pound(35, '#');

  const J2meKey(this.keyCode, this.label);

  final int keyCode;
  final String label;

  static J2meKey digit(int d) => values.firstWhere((k) => k.keyCode == 48 + d);
}

/// Constantes de javax.microedition.lcdui.Game et Canvas.getGameAction().
class GameAction {
  static const up = 1;
  static const left = 2;
  static const right = 5;
  static const down = 6;
  static const fire = 8;
  static const gameA = 9;
  static const gameB = 10;
  static const gameC = 11;
  static const gameD = 12;

  /// Équivalent de Canvas.getGameAction(keyCode). Renvoie 0 si aucune action.
  static int fromKeyCode(int code) {
    switch (code) {
      case -1:
      case 50:
        return up;
      case -2:
      case 56:
        return down;
      case -3:
      case 52:
        return left;
      case -4:
      case 54:
        return right;
      case -5:
      case 53:
        return fire;
      case 49:
        return gameA;
      case 51:
        return gameB;
      case 55:
        return gameC;
      case 57:
        return gameD;
      default:
        return 0;
    }
  }
}
