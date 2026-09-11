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
    const compatibility = legacyCandidateResponse(request, env);
    if (compatibility) return privateResponse(compatibility);
    // One stable instance, never one instance per link or per customer.
    const backend = env.BACKEND.getByName('staging');
    return privateResponse(await backend.fetch(backendRequest(request)));
  }
};
