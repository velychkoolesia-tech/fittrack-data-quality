import { Pool } from 'pg';

export const pool = new Pool({
  host:     process.env.PGHOST     ?? 'localhost',
  port:     parseInt(process.env.PGPORT ?? '5432', 10),
  database: process.env.PGDATABASE ?? 'fittrack',
  user:     process.env.PGUSER     ?? 'fittrack',
  password: process.env.PGPASSWORD ?? 'fittrack',
});
