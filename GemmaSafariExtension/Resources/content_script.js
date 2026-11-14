const api = (typeof browser !== 'undefined') ? browser : chrome;

let hasSynced = false;
let checking = false;
let toastEl = null;

function showToast(text, isSuccess = true, buttonLabel = '', buttonAction = null) {
  if (toastEl) toastEl.remove();

  toastEl = document.createElement('div');
  toastEl.id = 'gemma-auto-toast';
  toastEl.style.cssText = [
    'position: fixed',
    'top: 14px',
    'left: 50%',
    'transform: translateX(-50%)',
    'background: ' + (isSuccess ? '#090d16' : '#1e1b4b'),
    'color: #ffffff',
    'padding: 12px 18px',
    'border-radius: 20px',
    'font-size: 13px',
    'font-weight: 600',
    'font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif',
    'box-shadow: 0 10px 30px rgba(0,0,0,0.6)',
    'border: 1px solid ' + (isSuccess ? '#22c55e' : '#6366f1'),
    'z-index: 999999999',
    'display: flex',
    'align-items: center',
    'gap: 12px',
    'max-width: 90vw',
    'transition: opacity 0.3s'
  ].join(';');

  const span = document.createElement('span');
  span.textContent = text;
  toastEl.appendChild(span);

  if (buttonLabel && buttonAction) {
    const btn = document.createElement('a');
    btn.textContent = buttonLabel;
    btn.href = '#';
    btn.style.cssText = 'background:#2563eb;color:#fff;text-decoration:none;padding:5px 12px;border-radius:12px;font-size:12px;font-weight:700;white-space:nowrap;';
    btn.addEventListener('click', (e) => {
      e.preventDefault();
      buttonAction();
    });
    toastEl.appendChild(btn);
  }

  document.body.appendChild(toastEl);
  if (isSuccess) {
    setTimeout(() => {
      if (toastEl) {
        toastEl.style.opacity = '0';
        setTimeout(() => toastEl?.remove(), 300);
      }
    }, 6000);
  }
}

function handleSuccessfulSync() {
  if (hasSynced) return;
  hasSynced = true;
  showToast('✅ Gemma: Sesión verificada con Amazon.', true, 'Volver a Gemma', () => {
    window.location.href = 'gemma://sync?success=true';
  });

}

function checkAndAutoSync(force = false) {
  if (hasSynced || checking || document.visibilityState === 'hidden') return;
  const url = window.location.href.toLowerCase();

  // Avoid running on intermediate login / identity provider redirect screens
  if (url.includes('/login') || url.includes('/federate') || url.includes('/idprism') || url.includes('signin') || url.includes('oauth')) {
    return;
  }

  checking = true;
  api.runtime.sendMessage({ action: 'checkAndSync', force }, (response) => {
    checking = false;
    if (response && response.success && response.verified) {
      handleSuccessfulSync();
    }
  });
}

// Run after page settles
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', () => setTimeout(checkAndAutoSync, 1500));
} else {
  setTimeout(checkAndAutoSync, 1500);
}

// Route change observer for Single-Page Application (SPA)
let lastUrl = location.href;
new MutationObserver(() => {
  const currentUrl = location.href;
  if (currentUrl !== lastUrl) {
    lastUrl = currentUrl;
    setTimeout(checkAndAutoSync, 1500);
  }
}).observe(document, { subtree: true, childList: true });

// Login may finish without navigation; keep checking until a verified sync.
setInterval(checkAndAutoSync, 10000);

// Safari can restore the existing page from its back/forward cache.
function recheckVisibleSession() {
  if (document.visibilityState === 'hidden') return;
  hasSynced = false;
  if (toastEl) { toastEl.remove(); toastEl = null; }
  checkAndAutoSync(true);
}
window.addEventListener('pageshow', recheckVisibleSession);
document.addEventListener('visibilitychange', recheckVisibleSession);
