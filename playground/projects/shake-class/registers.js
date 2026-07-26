// Un champ statique qui APPELLE : la classe s'enregistre a la definition.
// Le statement est donc IMPUR -> racine -> garde, meme si personne ne
// l'importe. C'est exactement le cas qu'un shaker naif casse.
function register(name) {
  globalThis.__CLASS_REGISTRY__ = name;
  return name;
}
export class RegistersItself {
  static id = register('RegistersItself');
}
