import { format } from './format.js';

export const Row = ({ value }) => <tr><td>{format(value)}</td></tr>;
