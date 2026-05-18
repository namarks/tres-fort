import { Hono } from 'hono';
import type { HonoEnv } from './types';
import { authRoutes } from './routes/auth';
import { apiRoutes } from './routes/api';
import { mcpRoutes } from './mcp';

const app = new Hono<HonoEnv>();

app.get('/health', (c) => c.json({ ok: true, service: 'lift-coach' }));

app.route('/auth', authRoutes);
app.route('/api', apiRoutes);
app.route('/mcp', mcpRoutes);

app.onError((err, c) => {
  console.error('unhandled', err);
  return c.json({ error: 'internal', message: err.message }, 500);
});

app.notFound((c) => c.json({ error: 'not_found' }, 404));

export default app;
