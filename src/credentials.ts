// Shared credential primitives. Database services own persistence; callers must
// supply the Worker-managed key, never a key stored beside the ciphertext.
export function randomSecret(): string {
  return btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32))))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export async function credentialDigest(value: string): Promise<string> {
  const bytes = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  return [...new Uint8Array(bytes)].map(b => b.toString(16).padStart(2, '0')).join('');
}

const PREFIX = 'sealed:v1:';
function bytes(value: string): Uint8Array {
  return Uint8Array.from(atob(value), c => c.charCodeAt(0));
}
async function keyFor(secret: string | undefined): Promise<CryptoKey> {
  try {
    if (!secret) throw new Error();
    const key = bytes(secret);
    if (key.length !== 32) throw new Error();
    return await crypto.subtle.importKey('raw', key, 'AES-GCM', false, ['encrypt', 'decrypt']);
  } catch { throw new Error('credential_encryption_unavailable'); }
}
function context(userId: string, purpose: string): Uint8Array {
  return new TextEncoder().encode(JSON.stringify(['tres-fort:credentials:v1', userId, purpose]));
}

export async function sealCredential(
  value: string | null, secret: string | undefined, userId: string, purpose: string,
  previous?: string | null,
): Promise<string | null> {
  if (value === null) return null;
  const key = await keyFor(secret);
  // Preserve the stored identity on an identical retry, so existing credential
  // generation/CAS fences continue to recognize a no-op.
  if (previous?.startsWith(PREFIX) && await openCredential(previous, secret, userId, purpose) === value) return previous;
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const encrypted = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv, additionalData: context(userId, purpose) }, key, new TextEncoder().encode(value),
  );
  return PREFIX + btoa(String.fromCharCode(...iv)) + ':' + btoa(String.fromCharCode(...new Uint8Array(encrypted)));
}

export async function openCredential(
  value: string | null | undefined, secret: string | undefined, userId: string, purpose: string,
): Promise<string | null> {
  if (value == null) return null;
  const key = await keyFor(secret);
  // Transitional reader only. The guarded storage cutover backfills every
  // legacy value and activates database triggers rejecting plaintext writes.
  if (!value.startsWith(PREFIX)) return value;
  try {
    const [iv, ciphertext, extra] = value.slice(PREFIX.length).split(':');
    if (!iv || !ciphertext || extra !== undefined) throw new Error();
    const decrypted = await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: bytes(iv), additionalData: context(userId, purpose) }, key, bytes(ciphertext),
    );
    return new TextDecoder('utf-8', { fatal: true, ignoreBOM: false }).decode(decrypted);
  } catch { throw new Error('credential_decryption_failed'); }
}

export async function oauthTokenDigest(token: string): Promise<string> {
  return 'sha256:' + await credentialDigest(token);
}
