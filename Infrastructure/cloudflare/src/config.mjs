// This adapter is deliberately staging-only. Production gets a separately reviewed
// configuration after fresh-database compatibility and end-to-end acceptance.
/** @returns {Record<string, string>} */
export function containerEnvironment(env) {
  if (env.STAGING_ENABLED !== 'true') throw new Error('Staging is not enabled');
  for (const key of ['DATABASE_URL', 'STAGING_DATABASE_HOST', 'JWT_SECRET',
    'R2_ACCOUNT_ID', 'R2_ACCESS_KEY_ID', 'R2_SECRET_ACCESS_KEY', 'R2_PUBLIC_URL']) {
    if (typeof env[key] !== 'string' || !env[key].trim()) throw new Error(`Missing ${key}`);
  }
  const database = new URL(env.DATABASE_URL);
  if (!['postgres:', 'postgresql:'].includes(database.protocol) ||
      database.hostname !== env.STAGING_DATABASE_HOST ||
      !database.username || !database.password || database.pathname === '/' ||
      !['require', 'verify-full'].includes(database.searchParams.get('sslmode'))) {
    throw new Error('An explicitly selected staging PostgreSQL host with TLS is required');
  }
  const candidate = env.STAGING_DEPLOYMENT === 'unified-candidate';
  if (env.STAGING_DEPLOYMENT !== undefined && !candidate) {
    throw new Error('Unknown staging deployment');
  }
  if (candidate && (env.STAGING_PLATFORM_ENABLED !== 'true' ||
      env.STAGING_DATABASE_HOST !== 'ep-solitary-union-zav239mi.c-2.eu-west-2.aws.neon.tech' ||
      database.pathname !== '/snaglist_platform_test_0910222943_fc44')) {
    throw new Error('The unified candidate requires its pinned synthetic database and platform configuration');
  }
  const uploadBucket = candidate ? 'snaglist-unified-staging-uploads' : 'snaglist-staging-uploads';
  if (env.R2_BUCKET_NAME !== uploadBucket) {
    throw new Error('The staging upload bucket is required');
  }
  const base = candidate
    ? 'https://snaglist-api-unified-staging.danielmccann1705.workers.dev'
    : 'https://snaglist-api-staging.danielmccann1705.workers.dev';
  if (env.BASE_URL !== base || env.MAGIC_LINK_BASE_URL !== base) {
    throw new Error('Staging links must stay on the staging origin');
  }
  const photos = new URL(env.R2_PUBLIC_URL);
  if (photos.protocol !== 'https:' || photos.username || photos.password ||
      photos.hostname === 'cdn.snaglist.dev' || photos.hostname === 'snaglist.dev' ||
      photos.pathname !== '/' || photos.search || photos.hash) {
    throw new Error('An isolated HTTPS staging photo origin is required');
  }
  if (candidate && (env.R2_ACCOUNT_ID !== '387d49014cd0d45f9e6434196ab513c0' ||
      photos.origin !== 'https://pub-d7c456d4b396462fb5ee8ef008dcf93b.r2.dev')) {
    throw new Error('The unified candidate requires its separate account-scoped upload bucket');
  }
  if (env.JWT_SECRET.length < 32) throw new Error('A separate strong staging JWT secret is required');
  // Optional. Absent, the container's maintenance route does not exist and the
  // scheduled handler does nothing — which is a visible no-op, not a silent failure.
  const maintenance = {};
  if (env.MAINTENANCE_SECRET !== undefined) {
    if (typeof env.MAINTENANCE_SECRET !== 'string' || env.MAINTENANCE_SECRET.length < 32 ||
        env.MAINTENANCE_SECRET === env.JWT_SECRET || env.MAINTENANCE_SECRET === env.LINK_GRANT_TOKEN_KEY) {
      throw new Error('The maintenance secret must be at least 32 characters and distinct from the JWT and Contractor link keys');
    }
    maintenance.MAINTENANCE_SECRET = env.MAINTENANCE_SECRET;
  }
  if (env.REVENUECAT_SECRET_API_KEY || env.APNS_PRIVATE_KEY) {
    throw new Error('Purchase and push providers are disabled in staging');
  }
  const email = {};
  if (env.RESEND_API_KEY) {
    if (env.STAGING_EMAIL_ENABLED !== 'true' ||
        env.EMAIL_ALLOWED_RECIPIENTS !== 'danielmccann1705@gmail.com' ||
        env.EMAIL_FROM !== 'Snaglist <notifications@mail.snaglist.dev>') {
      throw new Error('Staging email requires the approved sender and sole test recipient');
    }
    email.RESEND_API_KEY = env.RESEND_API_KEY;
    email.EMAIL_FROM = env.EMAIL_FROM;
    email.EMAIL_ALLOWED_RECIPIENTS = env.EMAIL_ALLOWED_RECIPIENTS;
  }
  return {
    DATABASE_URL: env.DATABASE_URL,
    DATABASE_TLS_DISABLE: 'false',
    JWT_SECRET: env.JWT_SECRET,
    BASE_URL: env.BASE_URL,
    MAGIC_LINK_BASE_URL: env.MAGIC_LINK_BASE_URL,
    R2_ACCOUNT_ID: env.R2_ACCOUNT_ID,
    R2_BUCKET_NAME: env.R2_BUCKET_NAME,
    R2_PUBLIC_URL: photos.origin,
    R2_ACCESS_KEY_ID: env.R2_ACCESS_KEY_ID,
    R2_SECRET_ACCESS_KEY: env.R2_SECRET_ACCESS_KEY,
    PORT: '8080',
    ...maintenance,
    ...email,
    ...platformEnvironment(env),
    ...appleEnvironment(env, candidate),
    ...importPreparation(env, candidate, base),
    ...privateStorage(env, candidate),
    ...logStream(env),
    ...capacity(env),
    ...measurementEnvironment(env, candidate)
  };
}

// Replacement 2.0.1 measurement on the unified candidate (9 Oct 2026,
// outputs/measurement-2026-10-07/STAGING-PACKAGE-2.0.1-MEASUREMENT.md). Sandbox only, and only
// what receiver testing needs: the product-analytics switch with the PostHog sandbox project,
// the purchase-origin key behind the product purchase witness, and an optional sandbox
// RevenueCat webhook. Cross-company, LinkedIn, Singular, Apple Ads and provider erasure cannot
// be switched on through this adapter: their switches may only be absent or exactly "false",
// and their credentials are refused outright. All absent: exactly the previous behaviour.
/** @returns {Record<string, string>} */
function measurementEnvironment(env, candidate) {
  for (const key of ['POSTHOG_ERASURE_API_KEY', 'POSTHOG_ERASURE_PROJECT_ID', 'POSTHOG_ERASURE_INGESTION_LAG_SECONDS',
    'LINKEDIN_CONVERSIONS_ACCESS_TOKEN', 'LINKEDIN_SIGNUP_CONVERSION_RULE_ID', 'LINKEDIN_SUBSCRIPTION_CONVERSION_RULE_ID',
    'SINGULAR_API_KEY', 'SINGULAR_SERVER_EVENT_URL', 'SINGULAR_ERASURE_URL',
    'APPLE_ADSERVICES_OWNED_ORG_ID', 'APPLE_ADSERVICES_OWNED_CAMPAIGN_IDS', 'MEASUREMENT_CREDENTIAL_KEY']) {
    if (env[key] !== undefined) throw new Error('Advertising and provider-erasure settings are disabled in staging');
  }
  const selected = {};
  for (const key of ['FEATURE_CROSS_COMPANY_ADS_ENABLED', 'FEATURE_LINKEDIN_CONVERSIONS_ENABLED',
    'FEATURE_AD_MEASUREMENT_ENABLED']) {
    if (env[key] === undefined) continue;
    if (env[key] !== 'false') throw new Error('Advertising measurement switches can only be "false" in staging');
    selected[key] = 'false';
  }
  // The app's privacy-choices capability (registry key measurementChoicesEnabled). Absent, the
  // default false applies and the app hides its choices. Only the enabled unified candidate, which
  // serves the measurement routes, may say "true".
  if (env.FEATURE_MEASUREMENT_CHOICES_ENABLED !== undefined) {
    if (!['true', 'false'].includes(env.FEATURE_MEASUREMENT_CHOICES_ENABLED)) {
      throw new Error('FEATURE_MEASUREMENT_CHOICES_ENABLED is absent, "true" or "false"');
    }
    if (env.FEATURE_MEASUREMENT_CHOICES_ENABLED === 'true' && (!candidate || env.STAGING_PLATFORM_ENABLED !== 'true')) {
      throw new Error('Measurement choices require the enabled unified candidate');
    }
    selected.FEATURE_MEASUREMENT_CHOICES_ENABLED = env.FEATURE_MEASUREMENT_CHOICES_ENABLED;
  }
  const product = ['FEATURE_PRODUCT_ANALYTICS_ENABLED', 'POSTHOG_PROJECT_API_KEY', 'POSTHOG_MEASUREMENT_ENVIRONMENT'];
  const origin = ['MEASUREMENT_PURCHASE_ORIGIN_HMAC_KEY', 'MEASUREMENT_PURCHASE_ORIGIN_ENVIRONMENT'];
  const revenueCat = ['REVENUECAT_WEBHOOK_AUTHORIZATION', 'REVENUECAT_APP_ID'];
  const supplied = keys => keys.some(key => env[key] !== undefined);
  if (!supplied([...product, ...origin, ...revenueCat])) return selected;
  if (!candidate || env.STAGING_PLATFORM_ENABLED !== 'true') {
    throw new Error('Measurement configuration requires the enabled unified candidate');
  }
  if (supplied(product)) {
    if (!['true', 'false'].includes(env.FEATURE_PRODUCT_ANALYTICS_ENABLED) ||
        env.POSTHOG_MEASUREMENT_ENVIRONMENT !== 'sandbox' ||
        typeof env.POSTHOG_PROJECT_API_KEY !== 'string' || !/^phc_[A-Za-z0-9_-]{20,80}$/.test(env.POSTHOG_PROJECT_API_KEY)) {
      throw new Error('Staging product analytics needs its switch, the PostHog sandbox environment and a project ingestion key');
    }
    selected.FEATURE_PRODUCT_ANALYTICS_ENABLED = env.FEATURE_PRODUCT_ANALYTICS_ENABLED;
    selected.POSTHOG_MEASUREMENT_ENVIRONMENT = 'sandbox';
    selected.POSTHOG_PROJECT_API_KEY = env.POSTHOG_PROJECT_API_KEY;
  }
  if (supplied(origin)) {
    const others = [env.JWT_SECRET, env.LINK_GRANT_TOKEN_KEY, env.LINK_GRANT_TOKEN_PREVIOUS_KEY,
      env.APPLE_CREDENTIAL_KEY, env.APPLE_CREDENTIAL_PREVIOUS_KEY, env.MAINTENANCE_SECRET];
    if (env.MEASUREMENT_PURCHASE_ORIGIN_ENVIRONMENT !== 'sandbox' ||
        !validCapabilityKey(env.MEASUREMENT_PURCHASE_ORIGIN_HMAC_KEY) ||
        others.includes(env.MEASUREMENT_PURCHASE_ORIGIN_HMAC_KEY)) {
      throw new Error('A separate 32-byte purchase-origin key in the sandbox environment is required');
    }
    selected.MEASUREMENT_PURCHASE_ORIGIN_HMAC_KEY = env.MEASUREMENT_PURCHASE_ORIGIN_HMAC_KEY;
    selected.MEASUREMENT_PURCHASE_ORIGIN_ENVIRONMENT = 'sandbox';
  }
  if (supplied(revenueCat)) {
    if (typeof env.REVENUECAT_WEBHOOK_AUTHORIZATION !== 'string' ||
        !/^Bearer [\x21-\x7e]{24,256}$/.test(env.REVENUECAT_WEBHOOK_AUTHORIZATION) ||
        typeof env.REVENUECAT_APP_ID !== 'string' || !/^[A-Za-z0-9_-]{4,64}$/.test(env.REVENUECAT_APP_ID)) {
      throw new Error('The sandbox RevenueCat webhook needs its authorization header value and app identifier together');
    }
    selected.REVENUECAT_WEBHOOK_AUTHORIZATION = env.REVENUECAT_WEBHOOK_AUTHORIZATION;
    selected.REVENUECAT_APP_ID = env.REVENUECAT_APP_ID;
  }
  return selected;
}

// The one staging Durable Object, and so the one container, this Worker addresses (Lane 2, 28 Sep 2026).
// Cloudflare starts a container at the nearest location with a pre-fetched image to its Durable Object, and a
// Durable Object lives where its first request arrived. The original "staging" object starts its container in
// Lisbon (lis01), about 40 ms from the London database, and every database statement of every request paid it;
// production's container runs in Amsterdam (ams13). Another name creates another object near its first request.
// The old object and its sleeping container are left alone; switch only while the old container sleeps, because
// the application runs at most one instance. Absent, exactly the previous "staging" object.
/** @returns {string} */
export function backendInstance(env) {
  const name = env.BACKEND_INSTANCE;
  if (name === undefined) return 'staging';
  if (typeof name !== 'string' || !/^staging(-[a-z0-9]{1,16}){0,2}$/.test(name)) {
    throw new Error('BACKEND_INSTANCE is absent, "staging" or "staging-<lowercase letters and digits>"');
  }
  return name;
}

// The database pool and the staging-only runtime diagnostics route (wave 3, 28 Sep 2026).
// Both are optional; absent, the container runs exactly as before (one database
// connection per event loop, no diagnostics route). DATABASE_MAX_CONNECTIONS is the
// total pool across event loops, a whole number from 1 to 16 (a JSON number or string).
// RUNTIME_DIAGNOSTICS is absent or exactly "enabled"; the production adapter refuses it.
/** @returns {Record<string, string>} */
function capacity(env) {
  const selected = {};
  const pool = databaseConnections(env.DATABASE_MAX_CONNECTIONS);
  if (pool !== undefined) selected.DATABASE_MAX_CONNECTIONS = pool;
  if (env.RUNTIME_DIAGNOSTICS !== undefined) {
    if (env.RUNTIME_DIAGNOSTICS !== 'enabled') {
      throw new Error('RUNTIME_DIAGNOSTICS is either absent or exactly "enabled"');
    }
    selected.RUNTIME_DIAGNOSTICS = 'enabled';
  }
  return selected;
}

/** @returns {string | undefined} */
export function databaseConnections(value) {
  if (value === undefined) return undefined;
  const text = typeof value === 'number' ? String(value) : value;
  if (typeof text !== 'string' || !/^([1-9]|1[0-6])$/.test(text)) {
    throw new Error('DATABASE_MAX_CONNECTIONS must be a whole number from 1 to 16');
  }
  return text;
}

// Where the container's log goes, and the marker that switches the one-run
// log-stream diagnostic on. Both are optional; absent, the container logs on
// standard output exactly as it always has and emits no probe line at all.
//
// This adapter is an allowlist - a key reaches the container only because it is
// named here - so these two have to be named or the image could never see them.
// Naming them is also what makes the fix deployable without a rebuild: moving
// the log from one stream to the other is LOG_STREAM plus a Worker deploy.
//
// Neither value may be anything but the shapes below. LOG_STREAM is one of two
// literal words. The probe marker's alphabet is uppercase letters, digits and
// the hyphen, which is narrow enough that no base64 key, bearer, cookie or
// Contractor link token can be routed through it - every one of those carries
// lowercase or one of + / = - and that matters because the marker is written
// into a log line verbatim.
/** @returns {Record<string, string>} */
function logStream(env) {
  const selected = {};
  if (env.LOG_STREAM !== undefined) {
    if (env.LOG_STREAM !== 'stdout' && env.LOG_STREAM !== 'stderr') {
      throw new Error('The container log stream must be stdout or stderr');
    }
    selected.LOG_STREAM = env.LOG_STREAM;
  }
  if (env.LOG_STREAM_PROBE !== undefined) {
    if (typeof env.LOG_STREAM_PROBE !== 'string' ||
        !/^[A-Z0-9][A-Z0-9-]{6,46}[A-Z0-9]$/.test(env.LOG_STREAM_PROBE)) {
      throw new Error('A log-stream probe marker is 8 to 48 characters of A-Z, 0-9 and the hyphen');
    }
    selected.LOG_STREAM_PROBE = env.LOG_STREAM_PROBE;
  }
  return selected;
}

// Sign in with Apple. Three separable things: the audience staging is allowed to accept,
// the team credential that turns an authorization code into a refresh token so a
// deleted account's Apple grant can be revoked, and the web Services ID the portal
// signs in with beside that audience. All are optional, all are all-or-nothing, and
// each audience is named explicitly — never widened to make a build work.
/** @returns {Record<string, string>} */
function appleEnvironment(env, candidate) {
  const keys = ['APPLE_BUNDLE_ID', 'APPLE_CLIENT_ID', 'APPLE_TEAM_ID', 'APPLE_KEY_ID',
    'APPLE_PRIVATE_KEY', 'APPLE_CREDENTIAL_KEY', 'APPLE_CREDENTIAL_PREVIOUS_KEY'];
  const web = appleWebEnvironment(env);
  if (web === null && keys.every(key => env[key] === undefined)) return {};
  if (!candidate || env.STAGING_PLATFORM_ENABLED !== 'true') {
    throw new Error('Apple sign-in configuration requires the enabled unified candidate');
  }
  // Staging signs in as the staging bundle, and may accept only that audience.
  if (env.APPLE_BUNDLE_ID !== 'com.snaglist.app.staging' ||
      env.APPLE_CLIENT_ID !== 'com.snaglist.app.staging') {
    throw new Error('Staging Apple sign-in requires the staging bundle identifier');
  }
  const apple = { APPLE_BUNDLE_ID: env.APPLE_BUNDLE_ID, APPLE_CLIENT_ID: env.APPLE_CLIENT_ID };
  const exchange = ['APPLE_TEAM_ID', 'APPLE_KEY_ID', 'APPLE_PRIVATE_KEY', 'APPLE_CREDENTIAL_KEY'];
  if (exchange.some(key => env[key] !== undefined)) {
    if (exchange.some(key => typeof env[key] !== 'string' || !env[key].trim())) {
      throw new Error('Apple token exchange needs the team, key, private key and credential key together');
    }
    if (!/^[A-Za-z0-9]{1,20}$/.test(env.APPLE_TEAM_ID) || !/^[A-Za-z0-9]{1,20}$/.test(env.APPLE_KEY_ID)) {
      throw new Error('The Apple team and key identifiers are malformed');
    }
    if (!env.APPLE_PRIVATE_KEY.includes('BEGIN PRIVATE KEY')) {
      throw new Error('The Apple sign-in key must be the PKCS#8 private key Apple issued');
    }
    if (!validCapabilityKey(env.APPLE_CREDENTIAL_KEY) ||
        env.APPLE_CREDENTIAL_KEY === env.JWT_SECRET ||
        env.APPLE_CREDENTIAL_KEY === env.LINK_GRANT_TOKEN_KEY) {
      throw new Error('A separate 32-byte Apple credential key is required');
    }
    for (const key of exchange) apple[key] = env[key];
    if (env.APPLE_CREDENTIAL_PREVIOUS_KEY !== undefined) {
      if (!validCapabilityKey(env.APPLE_CREDENTIAL_PREVIOUS_KEY) ||
          env.APPLE_CREDENTIAL_PREVIOUS_KEY === env.APPLE_CREDENTIAL_KEY) {
        throw new Error('The previous Apple credential key must be valid and distinct');
      }
      apple.APPLE_CREDENTIAL_PREVIOUS_KEY = env.APPLE_CREDENTIAL_PREVIOUS_KEY;
    }
  }
  if (web !== null) {
    // The web flow signs its client secret with the team key above (`sub` = the
    // Services ID rather than the bundle) and escrows the refresh token under the
    // same credential key, so it cannot be on without the whole exchange group.
    if (exchange.some(key => apple[key] === undefined) || web.APPLE_WEB_CLIENT_ID === apple.APPLE_CLIENT_ID) {
      throw new Error('Apple web sign-in requires the staging token exchange beside its own Services ID');
    }
    Object.assign(apple, web);
  }
  return apple;
}

// Sign in with Apple on the web. Three names, all-or-nothing, and every one an exact
// literal: the switch is 'true' or 'false' (absent reads as 'false'), the environment
// is staging's own, and the client is the one Services ID registered for the staging
// portal origin. The identity cannot be configured with the switch off — an identity
// lying in the map without its switch is an ambiguity, not a default — and the
// switch cannot be on with a missing, foreign or bundle-shaped identity. Null means
// off and nothing forwarded; the container then reports the web flow disabled.
/** @returns {Record<string, string> | null} */
function appleWebEnvironment(env) {
  const enabled = env.APPLE_WEB_ENABLED === undefined ? 'false' : env.APPLE_WEB_ENABLED;
  if (enabled !== 'true' && enabled !== 'false') {
    throw new Error('Apple web sign-in is switched by an exact true or false');
  }
  if (enabled === 'false') {
    if (env.APPLE_WEB_AUTH_ENVIRONMENT !== undefined || env.APPLE_WEB_CLIENT_ID !== undefined) {
      throw new Error('The Apple web Services ID cannot be configured without its explicit switch');
    }
    return null;
  }
  if (env.APPLE_WEB_AUTH_ENVIRONMENT !== 'staging' || env.APPLE_WEB_CLIENT_ID !== 'com.snaglist.app.staging.web') {
    throw new Error('Staging Apple web sign-in requires the staging Services ID in the staging environment');
  }
  return {APPLE_WEB_ENABLED: 'true', APPLE_WEB_AUTH_ENVIRONMENT: 'staging', APPLE_WEB_CLIENT_ID: env.APPLE_WEB_CLIENT_ID};
}

// Private legacy import preparation/publication is an explicit staging opt-in for the
// enabled unified candidate only, bound to the candidate's own API origin. The backend
// separately refuses it outside development/staging; production never receives it.
/** @returns {Record<string, string>} */
function importPreparation(env, candidate, base) {
  if (env.STAGED_LEGACY_IMPORT_ENABLED === undefined && env.IMPORT_PREVIEW_API_ORIGIN === undefined) return {};
  if (!candidate || env.STAGING_PLATFORM_ENABLED !== 'true' ||
      env.STAGED_LEGACY_IMPORT_ENABLED !== 'true' || env.IMPORT_PREVIEW_API_ORIGIN !== base) {
    throw new Error('Legacy import preparation requires the enabled unified candidate bound to its own API origin');
  }
  return { STAGED_LEGACY_IMPORT_ENABLED: 'true', IMPORT_PREVIEW_API_ORIGIN: base };
}

// Private media is one installation, not two: R2_PRIVATE_NAMESPACE names the single
// create-only prefix that both the content store and the erasure fence replacing what
// it wrote are built from. Only the enabled unified candidate has a private bucket to
// fence, and it uses the same pinned prefix production does. Deletion that cannot
// fence is deletion that cannot finish, so the deletion switch is accepted only
// beside that namespace, and only as an exact literal.
/** @returns {Record<string, string>} */
function privateStorage(env, candidate) {
  if (env.R2_PRIVATE_NAMESPACE === undefined && env.ACCOUNT_DELETION_ENABLED === undefined) return {};
  const deletion = env.ACCOUNT_DELETION_ENABLED === undefined ? 'false' : env.ACCOUNT_DELETION_ENABLED;
  if (!candidate || env.STAGING_PLATFORM_ENABLED !== 'true' ||
      env.R2_PRIVATE_NAMESPACE !== 'private-v1/' || (deletion !== 'true' && deletion !== 'false')) {
    throw new Error('Private media requires the enabled unified candidate and its pinned create-only namespace');
  }
  return { R2_PRIVATE_NAMESPACE: env.R2_PRIVATE_NAMESPACE, ACCOUNT_DELETION_ENABLED: deletion };
}

// Keep the recovery image's configuration valid until the unified candidate is
// deliberately enabled. Never silently drop a partially supplied platform config.
/** @returns {Record<string, string>} */
function platformEnvironment(env) {
  const keys = ['PLATFORM_ENVIRONMENT', 'PORTAL_ORIGIN', 'R2_PRIVATE_BUCKET_NAME',
    'LINK_GRANT_TOKEN_KEY', 'LINK_GRANT_TOKEN_PREVIOUS_KEY', 'GOOGLE_AUTH_ENVIRONMENT',
    'GOOGLE_WEB_CLIENT_ID', 'GOOGLE_IOS_CLIENT_ID'];
  if (env.STAGING_PLATFORM_ENABLED !== 'true') {
    if (keys.some(key => env[key] !== undefined && env[key] !== '')) {
      throw new Error('Platform configuration requires explicit staging enablement');
    }
    return {};
  }
  if (env.PLATFORM_ENVIRONMENT !== 'staging' ||
      env.PORTAL_ORIGIN !== 'https://staging-app.usesnaglist.com') {
    throw new Error('The isolated staging manager origin and environment are required');
  }
  if (env.R2_PRIVATE_BUCKET_NAME !== 'snaglist-staging-private' ||
      env.R2_PRIVATE_BUCKET_NAME === env.R2_BUCKET_NAME) {
    throw new Error('The separate private staging media bucket is required');
  }
  if (!validCapabilityKey(env.LINK_GRANT_TOKEN_KEY) ||
      env.LINK_GRANT_TOKEN_KEY === env.JWT_SECRET) {
    throw new Error('A separate 32-byte staging Contractor link key is required');
  }
  const platform = {
    PLATFORM_ENVIRONMENT: 'staging',
    PORTAL_ORIGIN: env.PORTAL_ORIGIN,
    R2_PRIVATE_BUCKET_NAME: env.R2_PRIVATE_BUCKET_NAME,
    LINK_GRANT_TOKEN_KEY: env.LINK_GRANT_TOKEN_KEY
  };
  if (env.LINK_GRANT_TOKEN_PREVIOUS_KEY !== undefined) {
    if (!validCapabilityKey(env.LINK_GRANT_TOKEN_PREVIOUS_KEY) ||
        env.LINK_GRANT_TOKEN_PREVIOUS_KEY === env.LINK_GRANT_TOKEN_KEY ||
        env.LINK_GRANT_TOKEN_PREVIOUS_KEY === env.JWT_SECRET) {
      throw new Error('The previous staging Contractor link key must be valid and distinct');
    }
    platform.LINK_GRANT_TOKEN_PREVIOUS_KEY = env.LINK_GRANT_TOKEN_PREVIOUS_KEY;
  }
  const googleKeys = ['GOOGLE_AUTH_ENVIRONMENT', 'GOOGLE_WEB_CLIENT_ID', 'GOOGLE_IOS_CLIENT_ID'];
  if (googleKeys.some(key => env[key] !== undefined)) {
    const validID = value => typeof value === 'string' && value.length <= 200 &&
      /^[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com$/.test(value);
    if (env.GOOGLE_AUTH_ENVIRONMENT !== 'staging' ||
        !validID(env.GOOGLE_WEB_CLIENT_ID) || !validID(env.GOOGLE_IOS_CLIENT_ID) ||
        env.GOOGLE_WEB_CLIENT_ID === env.GOOGLE_IOS_CLIENT_ID) {
      throw new Error('Google requires separate web/iOS clients in the staging environment');
    }
    for (const key of googleKeys) platform[key] = env[key];
  }
  return platform;
}

function validCapabilityKey(value) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9+/]{43}=$/.test(value)) return false;
  try {
    const decoded = atob(value);
    return decoded.length === 32 && btoa(decoded) === value;
  } catch { return false; }
}
