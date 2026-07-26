// A static field that CALLS: the class registers itself when defined. The
// statement is therefore IMPURE -> a root -> kept, even though nobody imports
// it. Exactly the case a naive shaker breaks.
function register(name) {
  globalThis.__CLASS_REGISTRY__ = name;
  return name;
}
export class RegistersItself {
  static id = register('RegistersItself');
}
