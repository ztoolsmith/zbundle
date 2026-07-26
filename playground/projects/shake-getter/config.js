globalThis.__GETTER_CALLS__ = 0;

const source = {
  get value() {
    globalThis.__GETTER_CALLS__ += 1;
    return 'depuis-le-getter';
  },
};

// `source.value` is a MEMBER ACCESS: potentially a getter, so a disguised call.
// Judging it pure and removing it would change observable behaviour.
export const config = source.value;
