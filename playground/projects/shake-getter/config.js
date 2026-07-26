globalThis.__GETTER_CALLS__ = 0;

const source = {
  get value() {
    globalThis.__GETTER_CALLS__ += 1;
    return 'depuis-le-getter';
  },
};

// `source.value` est un ACCES MEMBRE : potentiellement un getter, donc un appel
// deguise. Le juger pur et le supprimer changerait le comportement observable.
export const config = source.value;
