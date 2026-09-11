import {portalResponse} from './portal-proxy.mjs';

interface PortalEnv {
  ASSETS: Fetcher;
  BACKEND: Fetcher;
  STAGING_PORTAL_ENABLED: string;
  PORTAL_ORIGIN: string;
}

export default {
  fetch(request: Request, env: PortalEnv): Promise<Response> {
    return portalResponse(request, env);
  }
};
