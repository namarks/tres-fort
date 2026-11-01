// src/types.ts (shared with the API Worker) names a few Worker-only binding
// types in its Env interface. The web app never touches Env, so these empty
// declarations only let the shared calendar and plan types compile here.
interface D1Database {}
interface R2Bucket {}
