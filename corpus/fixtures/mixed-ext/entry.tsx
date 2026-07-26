import { Row } from './row.jsx';
import { rows } from './data.ts';

type Props = { title: string };

export function Table({ title }: Props) {
  return (
    <table>
      <caption>{title}</caption>
      {rows.map((r) => (
        <Row key={r.id} value={r.value} />
      ))}
    </table>
  );
}
