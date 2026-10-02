// U2 (FABLE-U1-U2-DESIGN §2): the product switch for uploading Contractor-link photos as they are added.
//
// CONTRACTOR_EARLY_UPLOAD is exactly 'disabled' (which is also what absent means) or 'enabled'; anything else is refused,
// like the other switches, so a typo cannot choose a state. CONTRACTOR_EARLY_UPLOAD_WORKSPACES, optional and only beside
// 'enabled', narrows it to a canary: comma-separated workspace UUIDs.
//
// The Worker forwards the decision on every request it proxies as one header, set only from its own variables (a header a
// caller sent is always removed first), and the container reads it on the Contractor page GET. That makes turning the
// switch on or off a vars-only Worker deploy: a running container keeps the environment it started with, so a container
// variable would need an image rollout - minutes of 503 - to take effect and again to be undone. The switch is independent
// of RUNTIME_DIAGNOSTICS: early uploads never need Server-Timing, the diagnostics route or the failure record.
export const earlyUploadHeader = 'X-Snaglist-Early-Upload';
const workspaceID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** The header value to forward, or null for off. Throws on any value that is not exactly one of the two states.
 *  @returns {string | null} */
export function earlyUploadSetting(env) {
  const mode = env.CONTRACTOR_EARLY_UPLOAD === undefined ? 'disabled' : env.CONTRACTOR_EARLY_UPLOAD;
  if (mode !== 'disabled' && mode !== 'enabled') {
    throw new Error("CONTRACTOR_EARLY_UPLOAD is 'disabled' or 'enabled'; it is disabled when absent");
  }
  const list = env.CONTRACTOR_EARLY_UPLOAD_WORKSPACES;
  if (list === undefined) return mode === 'enabled' ? 'enabled' : null;
  if (mode !== 'enabled') {
    throw new Error('CONTRACTOR_EARLY_UPLOAD_WORKSPACES narrows an enabled switch and cannot be set while it is disabled');
  }
  const ids = typeof list === 'string' ? list.split(',').map(id => id.trim()) : [];
  if (!ids.length || ids.length > 50 || !ids.every(id => workspaceID.test(id)) ||
      new Set(ids.map(id => id.toLowerCase())).size !== ids.length) {
    throw new Error('CONTRACTOR_EARLY_UPLOAD_WORKSPACES is 1 to 50 distinct workspace UUIDs, comma-separated');
  }
  return ids.join(',');
}
