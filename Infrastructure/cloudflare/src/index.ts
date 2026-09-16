import { Container } from '@cloudflare/containers';
import { containerEnvironment } from './config.mjs';
import { backendRequest, privateResponse } from './proxy.mjs';
import { legacyCandidateResponse } from './candidate-compatibility.mjs';

interface BackendEnv {
  BACKEND: DurableObjectNamespace<SnaglistBackend>;
  [key: string]: unknown;
}

export class SnaglistBackend extends Container<BackendEnv> {
  defaultPort = 8080;
  sleepAfter = '10m';
  enableInternet = true;
  envVars = containerEnvironment(this.env);
}

export default {
  async fetch(request: Request, env: BackendEnv): Promise<Response> {
    try {
      containerEnvironment(env);
    } catch {
      return new Response('Snaglist staging is awaiting configuration.', {
        status: 503,
        headers: { 'Cache-Control': 'no-store' }
      });
    }
    // Maintenance is reachable from the scheduler and from nowhere else. The container
    // also refuses it without the shared secret; this makes the public surface refuse
    // it without needing to be right about the secret.
    if (new URL(request.url).pathname.startsWith('/internal/')) {
      return privateResponse(new Response('Not found', { status: 404 }));
    }
    const compatibility = legacyCandidateResponse(request, env);
    if (compatibility) return privateResponse(compatibility);
    // One stable instance, never one instance per link or per customer.
    const backend = env.BACKEND.getByName('staging');
    return privateResponse(await backend.fetch(backendRequest(request)));
  },

  // The container sleeps after ten minutes of quiet, so it cannot run its own timer:
  // a sleep inside it never finishes. Cron is outside it and fetching wakes it, which
  // is the whole reason this handler exists.
  async scheduled(_event: ScheduledController, env: BackendEnv, ctx: ExecutionContext): Promise<void> {
    let configured: Record<string, string>;
    try {
      configured = containerEnvironment(env) as Record<string, string>;
    } catch {
      return;
    }
    const secret = configured.MAINTENANCE_SECRET;
    if (!secret) return;
    ctx.waitUntil((async () => {
      const backend = env.BACKEND.getByName('staging');
      await backend.fetch(new Request('https://container.invalid/internal/maintenance/cleanup', {
        method: 'POST',
        headers: { Authorization: `Bearer ${secret}`, 'X-Forwarded-Proto': 'https' }
      }));
    })());
  }
};
