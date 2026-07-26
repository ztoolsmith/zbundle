import { Badge } from './badge.jsx';
import { titles, type Title } from './data.ts';

// A mini renderer: we evaluate the tree produced by jsx() to get text.
type Element = { type: unknown; props: { children?: unknown } };

function render(node: unknown): string {
  if (node === null || node === undefined || node === false) return '';
  if (typeof node !== 'object') return String(node);
  const el = node as Element;
  if (typeof el.type === 'function') {
    return render((el.type as (p: unknown) => unknown)(el.props));
  }
  const kids = el.props.children;
  const inner = Array.isArray(kids) ? kids.map(render).join('') : render(kids);
  return `<${String(el.type)}>${inner}</${String(el.type)}>`;
}

const list: Title[] = titles;
for (const t of list) {
  console.log(render(<Badge label={t.label} count={t.count} />));
}
