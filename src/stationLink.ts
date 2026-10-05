// Per-account secret for the local iPhone <-> iPad Station link. Both devices
// fetch it with their own app session and prove possession to each other over
// the local link, so public discovery data is never treated as authentication.
// Derived (not stored) from APP_JWT_SECRET under a dedicated label, so it needs
// no migration; rotating that secret re-keys every link.

export const STATION_LINK_KEY_VERSION = 1;

export async function deriveStationLinkKey(secret: string, userId: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const mac = await crypto.subtle.sign(
    'HMAC',
    key,
    new TextEncoder().encode(`tres-fort:station-link:v${STATION_LINK_KEY_VERSION}:${userId}`),
  );
  return btoa(String.fromCharCode(...new Uint8Array(mac)));
}
