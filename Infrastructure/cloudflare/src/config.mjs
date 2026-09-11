// This adapter is deliberately staging-only. Production gets a separately reviewed
// configuration after fresh-database compatibility and end-to-end acceptance.
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
  if (env.R2_BUCKET_NAME !== 'snaglist-staging-uploads') {
    throw new Error('The staging upload bucket is required');
  }
  const base = 'https://snaglist-api-staging.danielmccann1705.workers.dev';
  if (env.BASE_URL !== base || env.MAGIC_LINK_BASE_URL !== base) {
    throw new Error('Staging links must stay on the staging origin');
  }
  const photos = new URL(env.R2_PUBLIC_URL);
  if (photos.protocol !== 'https:' || photos.username || photos.password ||
      photos.hostname === 'cdn.snaglist.dev' || photos.hostname === 'snaglist.dev' ||
      photos.pathname !== '/' || photos.search || photos.hash) {
    throw new Error('An isolated HTTPS staging photo origin is required');
  }
  if (env.JWT_SECRET.length < 32) throw new Error('A separate strong staging JWT secret is required');
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
    ...email,
    ...platformEnvironment(env)
  };
}

// Keep the recovery image's configuration valid until the unified candidate is
// deliberately enabled. Never silently drop a partially supplied platform config.
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
