// ==UserScript==
// @name         Gemma Amazon A to Z Sync
// @namespace    https://github.com/personal_agent
// @version      1.0
// @description  Sincroniza tu sesión de Amazon A to Z iniciada con Face ID en Safari directamente con Gemma
// @match        https://atoz.amazon.work/*
// @match        https://atoz-apps.amazon.work/*
// @grant        GM_xmlhttpRequest
// @grant        GM_notification
// @run-at       document-idle
// ==/UserScript==

(function() {
    'use strict';

    console.log('[Gemma Sync] Script cargado en Amazon A to Z');

    function createBanner() {
        if (document.getElementById('gemma-sync-btn')) return;

        const container = document.createElement('div');
        container.id = 'gemma-sync-container';
        container.style.position = 'fixed';
        container.style.bottom = '20px';
        container.style.right = '20px';
        container.style.zIndex = '999999';
        container.style.background = '#1e293b';
        container.style.color = '#f8fafc';
        container.style.padding = '12px 16px';
        container.style.borderRadius = '12px';
        container.style.boxShadow = '0 10px 25px rgba(0,0,0,0.5)';
        container.style.fontFamily = '-apple-system, BlinkMacSystemFont, sans-serif';
        container.style.fontSize = '14px';
        container.style.display = 'flex';
        container.style.alignItems = 'center';
        container.style.gap = '10px';
        container.style.border = '1px solid #334155';

        container.innerHTML = `
            <span>⚡ Gemma</span>
            <button id="gemma-sync-btn" style="background:#3b82f6;color:white;border:none;padding:6px 12px;border-radius:6px;font-weight:600;font-size:13px;cursor:pointer;">
                Sincronizar Sesión
            </button>
        `;

        document.body.appendChild(container);

        document.getElementById('gemma-sync-btn').addEventListener('click', doSync);
    }

    async function doSync() {
        const btn = document.getElementById('gemma-sync-btn');
        btn.textContent = 'Enviando...';
        btn.disabled = true;

        try {
            // Read all accessible cookies and local storage tokens
            let cookies = document.cookie;
            let employeeId = '';

            for (let i = 0; i < localStorage.length; i++) {
                const k = localStorage.key(i);
                const v = localStorage.getItem(k);
                if (v && typeof v === 'string') {
                    const m = v.match(/["']?employeeId["']?\s*:\s*["']?([0-9]{6,12})["']?/);
                    if (m && m[1]) {
                        employeeId = m[1];
                        break;
                    }
                }
            }

            const payload = JSON.stringify({
                credentials: {
                    cookie: cookies,
                    employeeId: employeeId || '204193941',
                    capturedAt: Date.now() / 1000
                }
            });

            const endpoints = [
                'http://100.91.174.81:8081/v1/connection-services/amazon-atoz',
                'http://localhost:8081/v1/connection-services/amazon-atoz'
            ];

            function sendRequest(url, data) {
                return new Promise((resolve) => {
                    if (typeof GM_xmlhttpRequest !== 'undefined') {
                        GM_xmlhttpRequest({
                            method: 'POST',
                            url: url,
                            headers: {
                                'Content-Type': 'application/json',
                                'Authorization': 'Bearer replace-me-with-a-long-random-string'
                            },
                            data: data,
                            onload: (res) => resolve(res.status >= 200 && res.status < 300),
                            onerror: () => resolve(false),
                            ontimeout: () => resolve(false)
                        });
                    } else {
                        fetch(url, {
                            method: 'POST',
                            headers: {
                                'Content-Type': 'application/json',
                                'Authorization': 'Bearer replace-me-with-a-long-random-string'
                            },
                            body: data
                        }).then(r => resolve(r.ok)).catch(() => resolve(false));
                    }
                });
            }

            let ok = false;
            for (const url of endpoints) {
                ok = await sendRequest(url, payload);
                if (ok) break;
            }

            if (ok) {
                btn.textContent = '✅ Sincronizado';
                btn.style.background = '#22c55e';
            } else {
                btn.textContent = '❌ Falló (Revisa Tailscale)';
                btn.style.background = '#ef4444';
                setTimeout(() => { btn.textContent = 'Reintentar'; btn.disabled = false; }, 2500);
            }
        } catch (e) {
            btn.textContent = '❌ Error';
            btn.style.background = '#ef4444';
        }
    }

    setTimeout(createBanner, 2000);
})();
