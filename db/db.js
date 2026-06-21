require('dotenv').config({ path: require('path').join(__dirname, '.env') });

const { Pool } = require('pg');

const required = ['DB_USER', 'DB_HOST', 'DB_NAME', 'DB_PASS', 'DB_PORT'];
const missing = required.filter((key) => !process.env[key]);
if (missing.length) {
  throw new Error(`Missing required env vars: ${missing.join(', ')}. Check db/.env`);
}

const pool = new Pool({
  user: process.env.DB_USER,
  host: process.env.DB_HOST,
  database: process.env.DB_NAME,
  password: process.env.DB_PASS,
  port: Number(process.env.DB_PORT),
  max: 10,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
});

pool.on('error', (err) => {
  console.error('Unexpected PG pool error:', err);
});

pool
  .query('SELECT NOW()')
  .then((res) => console.log('Postgres connected. Server time:', res.rows[0].now))
  .catch((err) => console.error('Postgres connection failed:', err.message));

module.exports = pool;
