const api = (typeof browser !== 'undefined') ? browser : chrome;
const el = id => document.getElementById(id);
const messages = {
  missing_token: 'No se encontró atoz-oauth-token. Inicia sesión en A to Z y permite acceso a atoz.amazon.work y atoz-apps.amazon.work en Safari.',
  invalid_token: 'El token de A to Z no es válido. Vuelve a iniciar sesión.',
  expired_token: 'El token caducó o está por caducar. Actualiza A to Z para renovar la sesión.',
  cookie_access_failed: 'Safari no permitió leer las cookies. Revisa los permisos para los sitios de A to Z.',
  backend_unreachable: 'No se pudo contactar al servidor. Comprueba Tailscale y que el servicio esté iniciado.',
  backend_update_required: 'Actualiza y reinicia memory-service: falta la validación de sesiones de Amazon.',
  backend_unauthorized: 'El servidor rechazó la autorización de la extensión.',
  amazon_session_rejected: 'Amazon no aceptó las cookies exportadas. Renueva la sesión de A to Z.',
  amazon_unavailable: 'No se pudo verificar la sesión con Amazon. Intenta de nuevo más tarde.',
  invalid_credentials: 'Las credenciales capturadas están incompletas.',
  validation_failed: 'No se pudo validar la sesión con Amazon.'
};
function showFailure(reason) {
  el('sessionStatus').textContent = 'No verificada';
  el('sessionStatus').className = 'val err';
  el('returnBtn').style.display = 'none';
  el('statusMsg').textContent = messages[reason] || messages.validation_failed;
  el('statusMsg').className = 'status-msg warn';
}
async function findAtoZCookies() {
  el('returnBtn').style.display = 'none';
  el('syncBtn').disabled = true;
  el('sessionStatus').textContent = 'Buscando...';
  try {
    const granted = await api.permissions.contains({ origins: ['*://*.amazon.work/*'] });
    el('grantPermBtn').style.display = granted ? 'none' : 'block';
  } catch (_) { el('grantPermBtn').style.display = 'block'; }
  try {
    const res = await api.runtime.sendMessage({ action: 'getAllCookies' });
    el('cookiesCount').textContent = `${res.count || 0} de A to Z y API`;
    el('sessionStatus').textContent = res.isActive ? 'Token detectado; pendiente de validar' : 'Sesión incompleta';
    el('sessionStatus').className = res.isActive ? 'val' : 'val err';
    el('employeeId').textContent = res.employeeId || '--';
    el('tokenExpiry').textContent = res.expiresAt ? `${Math.max(0, Math.floor((res.expiresAt - Date.now()/1000)/60))} min` : '--';
    el('syncBtn').disabled = !res.isActive;
    el('openAtoZBtn').style.display = res.isActive ? 'none' : 'block';
    if (!res.isActive) showFailure(res.reason);
    else {
      el('statusMsg').textContent = 'Sincronizar verificará una consulta de lectura desde el servidor.';
      el('statusMsg').className = 'status-msg';
    }
  } catch (_) { showFailure('cookie_access_failed'); }
}
el('grantPermBtn').addEventListener('click', async () => {
  try {
    await api.permissions.request({ origins: ['*://*.amazon.work/*'] });
    await findAtoZCookies();
  } catch (_) { showFailure('cookie_access_failed'); }
});
el('openAtoZBtn').addEventListener('click', () => api.tabs.create({ url: 'https://atoz.amazon.work/' }));
el('refreshBtn').addEventListener('click', findAtoZCookies);
el('syncBtn').addEventListener('click', async () => {
  el('syncBtn').disabled = true;
  el('syncBtn').textContent = 'Verificando con Amazon...';
  try {
    const res = await api.runtime.sendMessage({ action: 'checkAndSync', force: true });
    if (res.success && res.verified) {
      el('sessionStatus').textContent = 'Verificada con Amazon ✅';
      el('sessionStatus').className = 'val ok';
      el('statusMsg').textContent = 'Sesión verificada y guardada. Ya puedes volver a Gemma.';
      el('statusMsg').className = 'status-msg ok';
      el('returnBtn').style.display = 'block';
    } else showFailure(res.reason);
  } catch (_) { showFailure('backend_unreachable'); }
  el('syncBtn').disabled = false;
  el('syncBtn').textContent = 'Sincronizar con Gemma';
});
el('returnBtn').addEventListener('click', () => { window.location.href = 'gemma://sync?success=true'; });
findAtoZCookies();
