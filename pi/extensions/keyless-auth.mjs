export function suppressKeylessAuth(headers, providerId, providers) {
  const profile = providers?.[providerId];
  if (profile?.api !== 'openai-completions' || profile.apiKey !== 'statefulclanker-keyless' || profile.authHeader !== false) return;
  for (const name of Object.keys(headers)) {
    if (name.toLowerCase() === 'authorization') headers[name] = null;
  }
  headers.Authorization = null;
}
