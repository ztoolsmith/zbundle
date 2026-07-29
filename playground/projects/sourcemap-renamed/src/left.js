export const shared = () => "left";

// `shared` used SEVERAL times inside its own module: the declaration and both
// references become `shared$1` in the bundle, and all three must lead back to
// the `shared` written here.
export const twice = () => shared() + "+" + shared();
