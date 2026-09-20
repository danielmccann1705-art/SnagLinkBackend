// Separate from the pinned synthetic staging adapter. This is a candidate only:
// the checked-in deployment is disabled and contains no database or provider keys.
export const productionAPIOrigin = 'https://api.snaglist.dev';
export const productionPortalOrigin = 'https://app.usesnaglist.com';

/** @returns {Record<string, string>} */
export function productionContainerEnvironment(env) {
  if (env.PRODUCTION_ENABLED !== 'true' || env.PLATFORM_ENVIRONMENT !== 'production') {
    throw new Error('Production must be explicitly enabled');
  }
  if (Object.keys(env).some(key => key.startsWith('STAGING_') || key === 'STAGED_LEGACY_IMPORT_ENABLED') ||
      env.IMPORT_PREVIEW_API_ORIGIN !== undefined) {
    throw new Error('Development and staging switches are forbidden in production');
  }
  const required = key => {
    if (typeof env[key] !== 'string' || !env[key].trim()) throw new Error(`Missing ${key}`);
    return env[key];
  };
  const database = new URL(required('DATABASE_URL'));
  const host = required('PRODUCTION_DATABASE_HOST');
  const name = required('PRODUCTION_DATABASE_NAME');
  if (!/^[a-z0-9-]+\.[a-z0-9.-]+\.neon\.tech$/.test(host) ||
      !/^[a-z][a-z0-9_]*$/.test(name) || /test|staging|preview/i.test(name) ||
      ['ep-bitter-wave-zacpbrh7.c-2.eu-west-2.aws.neon.tech',
       'ep-solitary-union-zav239mi.c-2.eu-west-2.aws.neon.tech'].includes(host) ||
      !['postgres:', 'postgresql:'].includes(database.protocol) || database.hostname !== host ||
      database.pathname !== '/' + name || !database.username || !database.password ||
      !['require', 'verify-full'].includes(database.searchParams.get('sslmode'))) {
    throw new Error('A separately selected production Neon database with TLS is required');
  }
  if (env.BASE_URL !== productionAPIOrigin || env.MAGIC_LINK_BASE_URL !== productionAPIOrigin ||
      env.PORTAL_ORIGIN !== productionPortalOrigin) {
    throw new Error('Production origins must match the approved native, portal and Contractor link hosts');
  }
  if (env.R2_ACCOUNT_ID !== '387d49014cd0d45f9e6434196ab513c0' ||
      env.R2_BUCKET_NAME !== 'snaglist-production-uploads' ||
      env.R2_PRIVATE_BUCKET_NAME !== 'snaglist-production-private' ||
      env.R2_PUBLIC_URL !== productionAPIOrigin) {
    throw new Error('Production uses separate buckets and no public R2 origin');
  }
  // One immutable private-storage configuration: R2_PRIVATE_NAMESPACE installs the
  // create-only content store and the erasure fence that replaces what it wrote.
  // Production is greenfield, so every allocation is create-only from its first
  // byte — there is no legacy production row and there must never be one. A missing
  // namespace, or any other prefix, is a refusal rather than a default.
  if (env.R2_PRIVATE_NAMESPACE !== 'private-v1/') {
    throw new Error('Production private media requires its pinned create-only namespace');
  }
  // Deletion that cannot fence is deletion that cannot finish. The switch is an exact
  // literal, and 'true' is reachable only past the namespace required above.
  const deletion = env.ACCOUNT_DELETION_ENABLED === undefined ? 'false' : env.ACCOUNT_DELETION_ENABLED;
  if (deletion !== 'true' && deletion !== 'false') {
    throw new Error('Account deletion is switched by an exact true or false');
  }
  const jwt = required('JWT_SECRET'), maintenance = required('MAINTENANCE_SECRET');
  const link = required('LINK_GRANT_TOKEN_KEY'), apple = required('APPLE_CREDENTIAL_KEY');
  if (jwt.length < 32 || maintenance.length < 32 || !capabilityKey(link) || !capabilityKey(apple) ||
      new Set([jwt, maintenance, link, apple]).size !== 4) {
    throw new Error('Independent production session, maintenance, Contractor link and Apple encryption keys are required');
  }
  if (env.APPLE_BUNDLE_ID !== 'com.snaglist.app' || env.APPLE_CLIENT_ID !== 'com.snaglist.app' ||
      required('APPLE_TEAM_ID') !== '52ZZHYHM62' || !/^[A-Z0-9]{10}$/.test(required('APPLE_KEY_ID')) ||
      !required('APPLE_PRIVATE_KEY').includes('BEGIN PRIVATE KEY')) {
    throw new Error('Production Apple sign-in and revocation must use the shipping bundle and team credential');
  }
  const googleID = value => typeof value === 'string' && value.length <= 200 &&
    /^[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com$/.test(value);
  if (env.GOOGLE_AUTH_ENVIRONMENT !== 'production' || !googleID(env.GOOGLE_WEB_CLIENT_ID) ||
      !googleID(env.GOOGLE_IOS_CLIENT_ID) || env.GOOGLE_WEB_CLIENT_ID === env.GOOGLE_IOS_CLIENT_ID) {
    throw new Error('Production requires separately registered web and iOS Google clients');
  }
  if (!/^re_[A-Za-z0-9_]+$/.test(required('RESEND_API_KEY')) ||
      env.EMAIL_FROM !== 'Snaglist <notifications@mail.usesnaglist.com>' ||
      env.EMAIL_ALLOWED_RECIPIENTS !== undefined) {
    throw new Error('Production requires the verified business sender and a production mail key');
  }
  required('REVENUECAT_SECRET_API_KEY');
  const values = {
    DATABASE_URL: env.DATABASE_URL, DATABASE_TLS_DISABLE: 'false', PORT: '8080',
    BASE_URL: productionAPIOrigin, MAGIC_LINK_BASE_URL: productionAPIOrigin,
    PLATFORM_ENVIRONMENT: 'production', PORTAL_ORIGIN: productionPortalOrigin,
    R2_ACCOUNT_ID: env.R2_ACCOUNT_ID, R2_BUCKET_NAME: env.R2_BUCKET_NAME,
    R2_PRIVATE_BUCKET_NAME: env.R2_PRIVATE_BUCKET_NAME, R2_PUBLIC_URL: productionAPIOrigin,
    R2_PRIVATE_NAMESPACE: env.R2_PRIVATE_NAMESPACE, ACCOUNT_DELETION_ENABLED: deletion,
    R2_ACCESS_KEY_ID: required('R2_ACCESS_KEY_ID'), R2_SECRET_ACCESS_KEY: required('R2_SECRET_ACCESS_KEY'),
    JWT_SECRET: jwt, MAINTENANCE_SECRET: maintenance, LINK_GRANT_TOKEN_KEY: link,
    APPLE_BUNDLE_ID: env.APPLE_BUNDLE_ID, APPLE_CLIENT_ID: env.APPLE_CLIENT_ID,
    APPLE_TEAM_ID: env.APPLE_TEAM_ID, APPLE_KEY_ID: env.APPLE_KEY_ID,
    APPLE_PRIVATE_KEY: env.APPLE_PRIVATE_KEY, APPLE_CREDENTIAL_KEY: apple,
    GOOGLE_AUTH_ENVIRONMENT: 'production', GOOGLE_WEB_CLIENT_ID: env.GOOGLE_WEB_CLIENT_ID,
    GOOGLE_IOS_CLIENT_ID: env.GOOGLE_IOS_CLIENT_ID,
    RESEND_API_KEY: env.RESEND_API_KEY, EMAIL_FROM: env.EMAIL_FROM,
    REVENUECAT_SECRET_API_KEY: env.REVENUECAT_SECRET_API_KEY
  };
  if (env.PRODUCTION_LEGACY_IMPORT_ENABLED !== undefined && env.PRODUCTION_LEGACY_IMPORT_ENABLED !== 'false') {
    if (env.PRODUCTION_LEGACY_IMPORT_ENABLED !== 'true' || env.PRODUCTION_IMPORT_API_ORIGIN !== productionAPIOrigin) {
      throw new Error('Production import requires its separate approval switch and exact API identity');
    }
    values.PRODUCTION_LEGACY_IMPORT_ENABLED = 'true';
    values.PRODUCTION_IMPORT_API_ORIGIN = productionAPIOrigin;
  } else if (env.PRODUCTION_IMPORT_API_ORIGIN !== undefined) {
    throw new Error('Production import identity cannot be configured without its explicit switch');
  }
  for (const key of ['LINK_GRANT_TOKEN_PREVIOUS_KEY', 'APPLE_CREDENTIAL_PREVIOUS_KEY']) {
    if (env[key] !== undefined) {
      if (!capabilityKey(env[key]) || Object.values(values).includes(env[key])) {
        throw new Error('Previous encryption keys must be valid and distinct');
      }
      values[key] = env[key];
    }
  }
  const pushKeys = ['APNS_KEY_ID', 'APNS_TEAM_ID', 'APNS_PRIVATE_KEY', 'APNS_BUNDLE_ID', 'APNS_ENVIRONMENT'];
  if (pushKeys.some(key => env[key] !== undefined)) {
    for (const key of pushKeys) required(key);
    if (env.APNS_BUNDLE_ID !== 'com.snaglist.app' || env.APNS_ENVIRONMENT !== 'production' ||
        env.APNS_TEAM_ID !== env.APPLE_TEAM_ID || !/^[A-Z0-9]{10}$/.test(env.APNS_KEY_ID) ||
        !encodedPEM(env.APNS_PRIVATE_KEY)) {
      throw new Error('Push must use the production app and Apple service');
    }
    for (const key of pushKeys) values[key] = env[key];
  }
  return values;
}

function capabilityKey(value) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9+/]{43}=$/.test(value)) return false;
  try { const decoded = atob(value); return decoded.length === 32 && btoa(decoded) === value; }
  catch { return false; }
}

function encodedPEM(value) {
  if (typeof value !== 'string' || value.length > 16_384) return false;
  try {
    const decoded = atob(value);
    return btoa(decoded) === value && /^-----BEGIN PRIVATE KEY-----\r?\n[A-Za-z0-9+/=\r\n]+\r?\n-----END PRIVATE KEY-----\s*$/.test(decoded);
  } catch { return false; }
}
