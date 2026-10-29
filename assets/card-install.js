/* Personal card shortcuts: the private token stays in #card only.
 * iOS home-screen WEB APP may ignore the personal URL and open the
 * generic merchant sign-in. Use a Safari home-screen BOOKMARK instead:
 * iOS 26+ users must disable "Open as Web App" when adding it.
 * Android Chrome retains the native installable PWA + same-origin storage.
 * No personal card credentials go into a manifest request.
 */
(() => {
  'use strict';
  const isIOS = /iPad|iPhone|iPod/.test(navigator.userAgent) ||
    (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
  const isAndroid = /Android/i.test(navigator.userAgent);
  const isEmbedded = /FBAN|FBAV|Instagram|WhatsApp|Telegram|\bwv\b|; wv\)/i.test(navigator.userAgent);
  const standalone = () => navigator.standalone === true || matchMedia('(display-mode: standalone)').matches;
  const uuid = value => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value || '');
  const route = new URLSearchParams(location.search);
  const SHORTCUT_KEY = 'look_personal_card_home_v1';
  const cardManifest = isAndroid ? 'card-android.webmanifest' : 'card.webmanifest';
  // The Android app starts at a public URL and redirects inside the same
  // browser profile to the saved personal card (token remains in the fragment).
  if (route.has('cardhome') && isAndroid) {
    let saved = '';
    try { saved = localStorage.getItem(SHORTCUT_KEY) || ''; } catch {}
    try {
      const url = new URL(saved);
      const card = new URLSearchParams(url.hash.slice(1)).get('card');
      if (url.origin === location.origin && uuid(url.searchParams.get('nfc')) && uuid(card)) {
        location.replace(url.href);
      } else {
        location.replace(new URL(location.pathname, location.origin).href);
      }
    } catch {
      location.replace(new URL(location.pathname, location.origin).href);
    }
    return; // no ejecutar el login mientras se abre el acceso directo
  }
  // Customer shortcut on iPhone must be a Safari bookmark, not the
  // merchant web app whose launch URL may revert to the sign-in screen.
  // Older iOS defaults to a bookmark without the standalone metadata.
  // On iOS 26+, Safari additionally requires "Open as Web App" OFF.
  if (uuid(route.get('nfc'))) {
    if (isIOS) {
      document.querySelector('link[rel="manifest"]')?.remove();
      document.querySelector('meta[name="apple-mobile-web-app-capable"]')?.setAttribute('content', 'no');
    } else {
      const link = document.querySelector('link[rel="manifest"]');
      if (link) link.href = cardManifest + '?v=20261029';
    }
  }
  let active = null;
  let previousFocus = null;
  let pendingInstallPrompt = null;
  let installed = false;
  function personalURL(profile, token) {
    const url = new URL(location.pathname, location.origin);
    url.searchParams.set('nfc', profile.id);
    url.hash = new URLSearchParams({ card: token }).toString();
    return url;
  }
  function closeGuide() {
    const dialog = document.getElementById('lookSaveGuide');
    if (dialog?.open) dialog.close();
  }
  function guide() {
    if (!active || standalone() || installed) return;
    history.replaceState(null, '', active.url.href);
    const dialog = document.getElementById('lookSaveGuide');
    const intro = document.getElementById('lookSaveIntro');
    const steps = document.getElementById('lookSaveSteps');
    const browserNote = document.getElementById('lookSaveBrowserNote');
    intro.textContent = 'Guardá el logo de LOOK en tu celular para entrar directo a tu tarjeta de ' + active.business + '.';
    steps.replaceChildren();
    const instructions = isIOS
      ? ['Abrí tu tarjeta personal en Safari, no en WhatsApp ni en otra aplicación.', 'Tocá Compartir (cuadrado con flecha ↑) y después “Agregar a Inicio”.', 'MUY IMPORTANTE: desactivá “Abrir como app web” para guardar el enlace de tu tarjeta, no la página de ingreso de LOOK.', 'Tocá “Agregar”. El ícono LOOK abrirá directamente tu tarjeta desde Safari.']
      : isAndroid
      ? ['Abrí el menú del navegador (⋮).', 'Elegí “Agregar a pantalla principal”, “Añadir a pantalla de inicio” o “Instalar aplicación”.', 'Confirmá “Agregar” o “Instalar”. El nombre será LOOK.']
      : ['Abrí esta tarjeta en el navegador de tu celular.', 'En iPhone: Compartir → Agregar a inicio.', 'En Android: menú ⋮ → Agregar a pantalla principal.'];
    for (const text of instructions) {
      const li = document.createElement('li'); li.textContent = text; steps.append(li);
    }
    browserNote.hidden = !isEmbedded;
    browserNote.textContent = 'Abriste la tarjeta dentro de otra app. Tocá “Copiar enlace” y abrilo en ' + (isIOS ? 'Safari' : 'Chrome') + ' para agregarla al inicio.';
    previousFocus = document.activeElement;
    if (!dialog.open) dialog.showModal();
  }
  // Android Chrome: show the native install prompt from the actual button tap.
  // iPhone/iPad: the browser does not offer a programmable one-tap install.
  function install() {
    if (!active || standalone() || installed) return;
    history.replaceState(null, '', active.url.href);
    if (isAndroid) {
      try { localStorage.setItem(SHORTCUT_KEY, active.url.href); } catch {}
    }
    const prompt = pendingInstallPrompt;
    if (prompt && !isEmbedded) {
      pendingInstallPrompt = null; // browser permits each prompt only once
      try {
        const answer = prompt.prompt();
        Promise.resolve(answer || prompt.userChoice).catch(() => guide());
      } catch {
        guide();
      }
      return;
    }
    guide();
  }
  function showAfterRegistration() {
    if (!active || standalone() || installed) return;
    closeGuide();
    const banner = document.getElementById('lookSaveCard');
    if (banner) {
      banner.hidden = false;
      banner.scrollIntoView({ behavior: 'smooth', block: 'start' });
      banner.querySelector('.look-save-primary')?.focus({ preventScroll: true });
    }
  }
  window.addEventListener('beforeinstallprompt', event => {
    if (!uuid(route.get('nfc')) || standalone()) return;
    event.preventDefault();
    pendingInstallPrompt = event;
  });
  window.addEventListener('appinstalled', () => {
    if (!uuid(route.get('nfc'))) return;
    installed = true;
    pendingInstallPrompt = null;
    document.getElementById('lookSaveCard')?.remove();
    document.getElementById('lookSaveAgain')?.remove();
    closeGuide();
  });
  function mount(profile, token) {
    const customer = document.getElementById('customer');
    const currentRoute = new URLSearchParams(location.search);
    if (!customer || !uuid(profile?.id) || !uuid(token) || currentRoute.get('nfc') !== profile.id || currentRoute.has('preview')) return;
    active = { url: personalURL(profile, token), business: profile.business || 'este comercio' };
    // Also restore #card after a reload: iOS must be able to launch the exact
    // card without relying on Safari's localStorage being copied to the web app.
    history.replaceState(null, '', active.url.href);
    // Android PWA manifest is public and never contains card credentials.
    // iOS intentionally has no card manifest: always keep Safari's complete
    // personal URL (#card) for an Add-to-Home-Screen browser bookmark.
    if (!isIOS) {
      const manifest = document.querySelector('link[rel="manifest"]');
      const manifestURL = new URL(cardManifest + '?v=20261029&merchant=' + profile.id, location.href);
      if (manifest && manifest.href !== manifestURL.href) manifest.href = manifestURL.href;
    }
    if (standalone() || installed) {
      document.getElementById('lookSaveCard')?.remove();
      document.getElementById('lookSaveAgain')?.remove();
      closeGuide();
      return;
    }
    if (!document.getElementById('lookSaveCard')) {
      const banner = document.createElement('section');
      banner.id = 'lookSaveCard'; banner.className = 'look-save-card';
      banner.setAttribute('aria-label', 'Guardar tu tarjeta');
      banner.innerHTML = '<img src="assets/look-home-192.png?v=20261028" alt="" width="48" height="48"><div><strong>Tu tarjeta, siempre a mano</strong><p>Entrá con un toque, sin volver a registrarte.</p></div><button type="button" class="look-save-dismiss" aria-label="Ocultar sugerencia de guardar">×</button><button type="button" class="look-save-primary">Agregar mi tarjeta al inicio</button>';
      customer.prepend(banner);
      banner.querySelector('.look-save-primary').onclick = install;
      banner.querySelector('.look-save-dismiss').onclick = () => { banner.hidden = true; };
    }
    const actions = document.getElementById('cardActions');
    if (actions && !document.getElementById('lookSaveAgain')) {
      const button = document.createElement('button');
      button.id = 'lookSaveAgain'; button.type = 'button'; button.className = 'secondary';
      button.textContent = 'Agregar mi tarjeta al inicio'; button.onclick = install; actions.append(button);
    }
    if (!document.getElementById('lookSaveGuide')) {
      const dialog = document.createElement('dialog'); dialog.id = 'lookSaveGuide'; dialog.className = 'look-save-guide';
      dialog.setAttribute('aria-labelledby', 'lookSaveTitle');
      dialog.innerHTML = '<button type="button" class="look-save-close" aria-label="Cerrar indicaciones">×</button><img src="assets/look-home-192.png?v=20261028" alt="LOOK" width="64" height="64"><h2 id="lookSaveTitle">Guardá tu tarjeta en el inicio</h2><p id="lookSaveIntro"></p><p id="lookSaveBrowserNote" class="look-save-note" hidden></p><ol id="lookSaveSteps"></ol><p class="look-save-note">En iPhone, desactivá “Abrir como app web”. Si ya tenés un ícono que abre la pantalla INGRESAR, eliminá ese ícono anterior y guardá de nuevo tu tarjeta. El enlace es personal: no lo compartas.</p><button type="button" id="lookSaveCopy" class="secondary">Copiar enlace de mi tarjeta</button><button type="button" id="lookSaveDone" class="look-save-primary">Entendido</button><p id="lookSaveFeedback" role="status" aria-live="polite"></p>';
      document.body.append(dialog);
      dialog.querySelector('.look-save-close').onclick = closeGuide;
      document.getElementById('lookSaveDone').onclick = closeGuide;
      dialog.addEventListener('close', () => previousFocus?.focus?.());
      dialog.addEventListener('click', event => { if (event.target === dialog) { const r = dialog.getBoundingClientRect(); if (event.clientX < r.left || event.clientX > r.right || event.clientY < r.top || event.clientY > r.bottom) closeGuide(); } });
      document.getElementById('lookSaveCopy').onclick = async () => {
        try {
          await navigator.clipboard.writeText(active.url.href);
          document.getElementById('lookSaveFeedback').textContent = 'Enlace copiado.';
        } catch {
          window.prompt('Copiá el enlace personal de tu tarjeta:', active.url.href);
        }
      };
    }
  }
  window.LookCardInstall = { mount, guide, install, showAfterRegistration };
})();
