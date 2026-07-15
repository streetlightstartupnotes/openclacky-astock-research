const listeners = new Set();
export function t(key) { return key === "title" ? "A股投研" : key; }
export function onLangChange(fn) {
  listeners.add(fn);
  return () => listeners.delete(fn);
}
