import {productionPortalResponse} from './portal-proxy.mjs';

interface ProductionPortalEnv {
  ASSETS: Fetcher;
  BACKEND: Fetcher;
  PRODUCTION_PORTAL_ENABLED: string;
  PORTAL_ORIGIN: string;
}

export default {
  fetch(request: Request, env: ProductionPortalEnv): Promise<Response> {
    return productionPortalResponse(request, env);
  }
};
