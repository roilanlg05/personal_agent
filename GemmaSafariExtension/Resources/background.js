const api = (typeof browser !== 'undefined') ? browser : chrome;
// Keep these identities and collection order aligned with amazon_scheduler.py.
const EMPLOYEE_ID = '204193941';
const LOGIN_URL = 'https://atoz.amazon.work/';
const API_ORIGIN = 'https://atoz-apps.amazon.work/';
let loginPageURL = LOGIN_URL;
let initializedToken = '';
let cookieStoreId;
let sourceWindowId;
const GRAPHQL_URL = 'https://atoz-apps.amazon.work/apis/ScheduleManagementAssociateGateway/graphql';
const ENDPOINTS = [
  'http://100.91.174.81:8081/v1/connection-services/amazon-atoz',
  'http://localhost:8081/v1/connection-services/amazon-atoz'
];
let lastSyncedCookie = '';
let lastSyncTime = 0;
let inFlight = null;
let retryTimer;

function decodeJwt(token) {
  try {
    const parts = token.split('.');
    if (parts.length !== 3) return null;
    const base64 = parts[1].replace(/-/g, '+').replace(/_/g, '/');
    return JSON.parse(atob(base64.padEnd(Math.ceil(base64.length / 4) * 4, '=')));
  } catch (_) { return null; }
}

function appliesToAPI(c) {
  const url = new URL(GRAPHQL_URL);
  const domain = (c.domain || '').replace(/^\./, '').toLowerCase();
  const path = c.path || '/';
  return domain && (c.hostOnly ? url.hostname === domain :
    url.hostname === domain || url.hostname.endsWith('.' + domain)) &&
    (url.pathname === path || (url.pathname.startsWith(path) &&
      (path.endsWith('/') || url.pathname[path.length] === '/'))) &&
    (!c.expirationDate || c.expirationDate > Date.now() / 1000);
}

async function selectCookieContext(sender = {}) {
  let tab = sender.tab;
  if (!tab && api.tabs.query) {
    const tabs = await api.tabs.query({ active: true, currentWindow: true });
    tab = tabs.find(t => { try { return new URL(t.url).hostname.endsWith('.amazon.work'); } catch (_) { return false; } });
  }
  if (tab) {
    try {
      const url = new URL(tab.url);
      if (url.hostname === 'atoz.amazon.work') loginPageURL = url.href;
    } catch (_) {}
    sourceWindowId = tab.windowId;
  }
  // Read the same browsing store as the tab, just as Selenium reads its driver.
  // Safari's implicit default store is not necessarily the current profile.
  if (api.cookies.getAllCookieStores) {
    const stores = await api.cookies.getAllCookieStores();
    const store = stores.find(s => s.tabIds?.includes(tab?.id));
    const selected = store?.id || tab?.cookieStoreId;
    if (selected !== cookieStoreId) { initializedToken = ''; lastSyncedCookie = ''; }
    cookieStoreId = selected;
  }
}

function readCookies(filter) {
  return api.cookies.getAll({ ...filter, ...(cookieStoreId ? { storeId: cookieStoreId } : {}) });
}

function isCurrentToken(value) {
  const jwt = decodeJwt(value || '');
  return Boolean(jwt && Number.isFinite(jwt.exp) && jwt.exp > Date.now()/1000 + 60);
}

async function initializeAPIOrigin() {
  // Selenium visits AUTH_DOMAIN after login. Use a temporary tab to perform the
  // same navigation, so Safari can complete redirects and receive Set-Cookie.
  let tab;
  try {
    tab = await api.tabs.create({ url: API_ORIGIN, active: false,
      ...(sourceWindowId !== undefined ? { windowId: sourceWindowId } : {}) });
    if (tab.status !== 'complete') {
      await new Promise(resolve => {
        let timer;
        const done = () => {
          clearTimeout(timer);
          api.tabs.onUpdated.removeListener(listener);
          resolve();
        };
        const listener = (id, change) => {
          if (id === tab.id && change.status === 'complete') done();
        };
        api.tabs.onUpdated.addListener(listener);
        timer = setTimeout(done, 15000);
        // The load may have completed between create() and registering the listener.
        api.tabs.get(tab.id).then(t => { if (t.status === 'complete') done(); }).catch(done);
      });
    }
    await new Promise(resolve => setTimeout(resolve, 1000));
    const finalTab = await api.tabs.get(tab.id);
    const finalURL = new URL(finalTab.url || API_ORIGIN);
    return finalURL.hostname.endsWith('.amazon.work') ? finalURL.href : API_ORIGIN;
  } catch (_) {
    // Python also keeps the login cookies if AUTH_DOMAIN navigation fails.
    return API_ORIGIN;
  } finally {
    if (tab && tab.id !== undefined) await api.tabs.remove(tab.id).catch(() => {});
  }
}

async function collectAllCookies(initialize = false) {
  // Python: current A to Z page first; AUTH_DOMAIN second; name collisions are
  // replaced by the second source. Do not filter out login-only auth cookies.
  let loginCookies = await readCookies({ url: loginPageURL });
  const loginToken = loginCookies.find(c => c.name === 'atoz-oauth-token')?.value;
  let apiURL = API_ORIGIN;
  if (initialize && isCurrentToken(loginToken) && loginToken !== initializedToken) {
    await new Promise(resolve => setTimeout(resolve, 2000));
    loginCookies = await readCookies({ url: loginPageURL });
    apiURL = await initializeAPIOrigin();
    initializedToken = loginToken;
  }
  const merged = new Map();
  for (const c of loginCookies) if (c?.name) merged.set(c.name, c);
  try {
    for (const c of await readCookies({ url: apiURL })) {
      if (c?.name) merged.set(c.name, c);
    }
  } catch (_) {}
  return Array.from(merged.values());
}

function sessionState(cookies) {
  const identity = { employeeId: EMPLOYEE_ID };
  const token = cookies.find(c => c.name === 'atoz-oauth-token');
  const jwt = token && decodeJwt(token.value);
  if (!token) return { ...identity, isActive: false, reason: 'missing_token' };
  if (!jwt || !Number.isFinite(jwt.exp)) {
    return { ...identity, isActive: false, reason: 'invalid_token' };
  }
  if (jwt.exp <= Date.now() / 1000 + 60) {
    return { ...identity, isActive: false, reason: 'expired_token' };
  }
  // Python uses EMPLOYEE_ID; JWT sub is not assumed to be the employee ID.
  return { ...identity, isActive: true, expiresAt: jwt.exp };
}

async function performSync(force) {
  let cookies = await collectAllCookies();
  let state = sessionState(cookies);
  if (!state.isActive) return { success: false, count: cookies.length, ...state };
  let cookie = cookies.map(c => `${c.name}=${c.value}`).join('; ');
  if (!force && cookie === lastSyncedCookie && Date.now() - lastSyncTime < 60000) {
    return { success: true, verified: true, cached: true, ...state };
  }
  cookies = await collectAllCookies(true);
  state = sessionState(cookies);
  if (!state.isActive) return { success: false, count: cookies.length, ...state };
  cookie = cookies.map(c => `${c.name}=${c.value}`).join('; ');
  const payload = { verify: true, credentials: {
    cookie, employeeId: state.employeeId, capturedAt: Math.floor(Date.now() / 1000)
  } };
  for (const endpoint of ENDPOINTS) {
    let resp;
    try {
      resp = await fetch(endpoint, {
        method: 'POST', headers: { 'Content-Type': 'application/json',
          'Authorization': 'Bearer replace-me-with-a-long-random-string' },
        body: JSON.stringify(payload), signal: AbortSignal.timeout(20000)
      });
    } catch (_) { continue; }
    let result;
    try { result = await resp.json(); } catch (_) {
      return { success: false, reason: 'backend_update_required' };
    }
    if (!resp.ok) {
      return { success: false, reason: result.error?.code || result.error ||
        (resp.status === 401 ? 'backend_unauthorized' : 'validation_failed') };
    }
    // Older servers only store cookies. Never report them as a verified session.
    if (result.verified !== true) return { success: false, reason: 'backend_update_required' };
    lastSyncedCookie = cookie;
    lastSyncTime = Date.now();
    return { success: true, verified: true, count: cookies.length, ...state };
  }
  return { success: false, reason: 'backend_unreachable' };
}

function checkAndSync(force = false) {
  if (!inFlight) {
    inFlight = performSync(force).catch(() => ({ success: false, reason: 'cookie_access_failed' }))
      .finally(() => { inFlight = null; });
  }
  return inFlight;
}

// Troubleshooting contains metadata only: never cookie or JWT values.
let lastDiagnosticTime = 0;
async function reportDiagnostics(result) {
  if (Date.now() - lastDiagnosticTime < 5000) return;
  lastDiagnosticTime = Date.now();
  const queries = [
    { url: loginPageURL }, { url: API_ORIGIN }, { domain: 'amazon.work' }
  ];
  const sources = await Promise.all(queries.map(async query => {
    try {
      const cookies = await readCookies(query);
      return { query, cookies: cookies.filter(c => {
        const d = (c.domain || '').replace(/^\./, '');
        return d === 'amazon.work' || d.endsWith('.amazon.work');
      }).map(c => {
        const jwt = c.name === 'atoz-oauth-token' ? decodeJwt(c.value) : null;
        return { name: c.name, domain: c.domain, path: c.path,
          hostOnly: c.hostOnly, httpOnly: c.httpOnly, expirationDate: c.expirationDate,
          apiEligible: Boolean(appliesToAPI(c)),
          ...(c.name === 'atoz-oauth-token' ? { token: { decodable: Boolean(jwt),
            claims: jwt ? Object.keys(jwt) : [], hasSub: Boolean(jwt?.sub),
            subType: typeof jwt?.sub, exp: jwt?.exp } } : {}) };
      }) };
    } catch (_) { return { query, error: 'cookie_access_failed' }; }
  }));
  const metadata = { version: '1.3.1', storeId: cookieStoreId || 'implicit', capturedAt: Math.floor(Date.now()/1000),
    reason: result.reason || (result.verified ? 'verified' : 'token_detected'), sources };
  for (const endpoint of ENDPOINTS) {
    try {
      const response = await fetch(endpoint.replace(/amazon-atoz$/, 'amazon-atoz-diagnostics'), {
        method: 'POST', headers: { 'Content-Type': 'application/json',
          'Authorization': 'Bearer replace-me-with-a-long-random-string' },
        body: JSON.stringify({credentials: metadata}), signal: AbortSignal.timeout(5000)
      });
      if (response.ok) break;
    } catch (_) {}
  }
}

api.runtime.onMessage.addListener((request, sender, sendResponse) => {
  if (!['checkAndSync', 'getAllCookies'].includes(request.action)) return;
  (async () => {
    await selectCookieContext(sender);
    const result = request.action === 'checkAndSync'
      ? await checkAndSync(Boolean(request.force))
      : await collectAllCookies().then(cookies => ({ count: cookies.length, ...sessionState(cookies) }));
    await reportDiagnostics(result).catch(() => {});
    sendResponse(result);
  })().catch(() => sendResponse({ success: false, isActive: false, reason: 'cookie_access_failed', count: 0 }));
  return true;
});

function scheduleSync() {
  clearTimeout(retryTimer);
  retryTimer = setTimeout(() => checkAndSync(), 1500);
}
if (api.cookies.onChanged) {
  api.cookies.onChanged.addListener(change => {
    if (change.cookie && ['atoz-oauth-token', 'atoz-auth-session', 'atoz-refresh-token'].includes(change.cookie.name)) {
      initializedToken = '';
      scheduleSync();
    }
  });
}
if (api.tabs && api.tabs.onUpdated) {
  api.tabs.onUpdated.addListener((id, change, tab) => {
    try {
      if (change.status === 'complete' && new URL(tab.url).hostname.endsWith('.amazon.work')) scheduleSync();
    } catch (_) {}
  });
}
