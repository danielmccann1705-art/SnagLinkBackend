import {Container} from '@cloudflare/containers';
import {productionContainerEnvironment} from './production-config.mjs';
import {productionResponse, productionMaintenance} from './production-backend.mjs';

interface ProductionEnv {
  BACKEND: DurableObjectNamespace<SnaglistProductionBackend>;
  [key: string]: unknown;
}

export class SnaglistProductionBackend extends Container<ProductionEnv> {
  defaultPort = 8080;
  sleepAfter = '10m';
  enableInternet = true;
  envVars = productionContainerEnvironment(this.env);
}

export default {
  fetch(request: Request, env: ProductionEnv): Promise<Response> {
    return productionResponse(request, env);
  },
  async scheduled(_event: ScheduledController, env: ProductionEnv, ctx: ExecutionContext): Promise<void> {
    // Unconfigured candidates remain dormant; a configured cleanup failure rejects.
    if (env.PRODUCTION_ENABLED !== 'true') return;
    ctx.waitUntil(productionMaintenance(env));
  }
};
