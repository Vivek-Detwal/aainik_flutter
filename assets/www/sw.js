/* ═══════════════════════════════════════════════════
   AAINIK — SERVICE WORKER | sw.js
   Built by:     Account 1
   Extended by:  Account 2 — background notification delivery
   Handles: Offline caching, background sync, PWA install,
            background multi-reminder scheduling
═══════════════════════════════════════════════════ */

const CACHE_NAME    = 'aainik-v4';
const CACHE_VERSION = 4;

// Files to cache for offline use
const CACHE_FILES = [
  '/',
  '/index.html',
  '/app.js',
  '/styles.css',
  '/manifest.json',
  '/icons/icon-192.png',
  '/icons/icon-512.png'
];

/* ─── INSTALL: cache all app files ─── */
self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE_NAME).then(cache => {
      return Promise.allSettled(
        CACHE_FILES.map(file =>
          cache.add(file).catch(err => console.warn('[SW] Cache miss for', file, err))
        )
      );
    }).then(() => {
      return self.skipWaiting();
    })
  );
});

/* ─── ACTIVATE: clean old caches ─── */
self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(keys =>
      Promise.all(
        keys.filter(k => k !== CACHE_NAME).map(k => caches.delete(k))
      )
    ).then(() => self.clients.claim())
  );
});

/* ─── FETCH: serve from cache, fallback to network ─── */
self.addEventListener('fetch', event => {
  if (event.request.method !== 'GET') return;
  if (!event.request.url.startsWith(self.location.origin)) return;

  event.respondWith(
    caches.match(event.request).then(cached => {
      if (cached) return cached;
      return fetch(event.request).then(response => {
        if (!response || response.status !== 200 || response.type === 'opaque') return response;
        const toCache = response.clone();
        caches.open(CACHE_NAME).then(cache => cache.put(event.request, toCache));
        return response;
      }).catch(() => {
        if (event.request.mode === 'navigate') return caches.match('/index.html');
      });
    })
  );
});

/* ─── PUSH: handle push notifications (future use) ─── */
self.addEventListener('push', event => {
  if (!event.data) return;
  try {
    const data = event.data.json();
    event.waitUntil(
      self.registration.showNotification(data.title || 'Aainik', {
        body: data.body || '', icon: '/icons/icon-192.png',
        badge: '/icons/icon-192.png', tag: data.tag || 'aainik-notif',
        renotify: true, data
      })
    );
  } catch (e) { console.warn('[SW] Push error:', e); }
});

/* ─── NOTIFICATION CLICK: open app and route to correct screen ─── */
self.addEventListener('notificationclick', event => {
  event.notification.close();
  const data   = event.notification.data || {};
  const screen = data.screen || '';

  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then(clientList => {
      for (const client of clientList) {
        if ('focus' in client) {
          // Tell the app to navigate to the right screen
          if (screen) client.postMessage({ type: 'NAVIGATE_SCREEN', screen });
          return client.focus();
        }
      }
      // App not open — open it, screen stored in hash for pickup on init
      return clients.openWindow('/index.html' + (screen ? '#nav-' + screen : ''));
    })
  );
});

/* ─── ACCOUNT 2: PERIODIC SYNC — background notification check ─── */
self.addEventListener('periodicsync', event => {
  if (event.tag === 'check-notifications') {
    event.waitUntil(checkAndFireNotifications());
  }
  if (event.tag === 'check-ego-reports') {
    event.waitUntil(checkAndFireEgoReports());
  }
});

/* ─── ACCOUNT 2: MESSAGE — receive task data for background scheduling ─── */
self.addEventListener('message', event => {
  if (!event.data) return;

  if (event.data.type === 'SKIP_WAITING') {
    self.skipWaiting();
    return;
  }

  // App sends full appData snapshot so SW can fire reminders when page is closed
  if (event.data.type === 'SYNC_NOTIFICATION_DATA') {
    const data = event.data.payload;
    if (data) {
      // Store in IndexedDB-style using cache API as simple KV
      caches.open('aainik-data').then(cache => {
        const resp = new Response(JSON.stringify(data), { headers: { 'Content-Type': 'application/json' } });
        cache.put('/sw-data', resp);
      });
    }
  }
});

/* ─────────────────────────────────────────────
   ACCOUNT 2 — checkAndFireNotifications
   Called by periodicsync when page is in background.
   Reads appData snapshot from cache, fires any due reminders.
───────────────────────────────────────────── */
async function checkAndFireNotifications() {
  let appData = null;
  try {
    const cache   = await caches.open('aainik-data');
    const resp    = await cache.match('/sw-data');
    if (resp) appData = await resp.json();
  } catch (e) {
    console.warn('[SW] Could not read app data:', e);
    return;
  }

  if (!appData || !appData.tasks) return;

  const now        = new Date();
  const hhmm       = String(now.getHours()).padStart(2,'0') + ':' + String(now.getMinutes()).padStart(2,'0');
  const today      = now.getFullYear() + '-' +
                     String(now.getMonth()+1).padStart(2,'0') + '-' +
                     String(now.getDate()).padStart(2,'0');
  const dayOfWeek  = now.getDay();
  const isWeekday  = dayOfWeek >= 1 && dayOfWeek <= 5;
  const isWeekend  = dayOfWeek === 0 || dayOfWeek === 6;

  const fromStr = (appData.settings && appData.settings.notifWindowFrom) || '06:00';
  const toStr   = (appData.settings && appData.settings.notifWindowTo)   || '23:00';
  if (hhmm < fromStr || hhmm > toStr) return;

  for (const task of appData.tasks) {
    if (!task.active || !task.notifications) continue;

    const done = (appData.history || []).find(
      h => h.taskId === task.id && h.date === today && h.completed
    );
    if (done) continue;

    for (const n of task.notifications) {
      if (!n.enabled || n.time !== hhmm) continue;
      if (!swShouldFireToday(n, dayOfWeek, isWeekday, isWeekend)) continue;

      await self.registration.showNotification('Aainik: ' + task.name, {
        body:     n.message,
        icon:     '/icons/icon-192.png',
        badge:    '/icons/icon-192.png',
        tag:      'bg-' + task.id + '-' + n.id,
        renotify: true,
        data:     { taskId: task.id }
      });
    }
  }
}

function swShouldFireToday(n, dayOfWeek, isWeekday, isWeekend) {
  const r = n.repeat || 'daily';
  if (r === 'daily')    return true;
  if (r === 'weekdays') return isWeekday;
  if (r === 'weekends') return isWeekend;
  if (r === 'custom')   return (n.customDays || []).includes(dayOfWeek);
  return true;
}

/* ─────────────────────────────────────────────
   SW: CHECK & FIRE EGO AI REPORTS (background)
   Weekly + Daily Progress + Auto-coach
   Calls Gemini API directly — sends real AI responses in notification
───────────────────────────────────────────── */
async function checkAndFireEgoReports() {
  let appData = null;
  try {
    const cache = await caches.open('aainik-data');
    const resp  = await cache.match('/sw-data');
    if (resp) appData = await resp.json();
  } catch (e) { console.warn('[SW] Could not read app data:', e); return; }
  if (!appData || !appData.settings) return;

  const apiKey = appData.settings.coachApiKey;
  if (!apiKey) return;

  const now   = new Date();
  const hhmm  = String(now.getHours()).padStart(2,'0') + ':' + String(now.getMinutes()).padStart(2,'0');
  const today = now.getFullYear() + '-' + String(now.getMonth()+1).padStart(2,'0') + '-' + String(now.getDate()).padStart(2,'0');

  // ── Weekly report ──
  if (appData.settings.weeklyReportEnabled && appData.settings.weeklyReportTime === hhmm) {
    const weekKey = swGetISOWeekKey(now);
    if (!((appData.settings.lastWeeklyReportFired || {})[weekKey])) {
      try {
        const r = await swCallGeminiForWeekly(appData, apiKey, now, today);
        await swSaveReportToCache(appData, { type: 'weekly', weekKey, today, fullResponse: r.fullResponse, headline: r.headline });
        await swShowAiNotification('📊 ' + r.headline, r.notifBody, 'weekly-report-' + weekKey, 'weekly');
      } catch (e) {
        console.warn('[SW] Weekly report failed:', e);
        await self.registration.showNotification('📊 Aainik — Weekly Report', {
          body: 'Teri weekly performance report ready hai — app kholo aur dekho kahan khade ho is hafte!',
          icon: '/icons/icon-192.png', badge: '/icons/icon-192.png',
          tag: 'weekly-report-' + weekKey, renotify: true, data: { screen: 'coach' }
        }).catch(() => {});
      }
    }
  }

  // ── Daily progress report ──
  if (appData.settings.dailyProgressEnabled && appData.settings.dailyProgressTime === hhmm) {
    if (!((appData.settings.lastDailyProgressFired || {})[today])) {
      try {
        const r = await swCallGeminiForDaily(appData, apiKey, today);
        await swSaveReportToCache(appData, { type: 'daily_progress', today, fullResponse: r.fullResponse, headline: r.headline });
        await swShowAiNotification('📈 ' + r.headline, r.notifBody, 'daily-progress-' + today, 'daily_progress');
      } catch (e) {
        console.warn('[SW] Daily progress failed:', e);
        await self.registration.showNotification('📈 Aainik — Daily Progress', {
          body: 'Tera aaj ka overall progress report ready hai — app kholo aur full analysis dekho!',
          icon: '/icons/icon-192.png', badge: '/icons/icon-192.png',
          tag: 'daily-progress-' + today, renotify: true, data: { screen: 'coach' }
        }).catch(() => {});
      }
    }
  }

  // ── Auto-coach check times ──
  if (appData.settings.autoCoachEnabled) {
    const times = appData.settings.autoCoachTimes || [];
    for (const entry of times) {
      if (!entry.enabled || entry.time !== hhmm) continue;
      const fireKey = today + '_' + entry.time;
      if ((appData.settings.lastAutoCoachFired || {})[fireKey]) continue;
      try {
        const r = await swCallGeminiForAutoCoach(appData, apiKey, today, entry.time);
        await swSaveReportToCache(appData, { type: 'auto', fireKey, today, triggerTime: entry.time, fullResponse: r.fullResponse, headline: r.headline });
        await swShowAiNotification(r.headline, r.notifBody, 'auto-coach-' + entry.time, 'auto');
      } catch (e) {
        console.warn('[SW] Auto-coach failed:', e);
        await self.registration.showNotification('🤖 Aainik — Ego Check', {
          body: 'Ego check time! App kholo — aaj ke tasks ka full AI analysis milega.',
          icon: '/icons/icon-192.png', badge: '/icons/icon-192.png',
          tag: 'auto-coach-' + entry.time, renotify: true, data: { screen: 'coach' }
        }).catch(() => {});
      }
    }
  }
}

/* ─── SW helper: show AI notification with 4-5 line summary + Read Full action ─── */
async function swShowAiNotification(title, fullBody, tag, convType) {
  const lines   = (fullBody || '').split('\n').filter(l => l.trim().length > 0);
  const summary = lines.slice(0, 4).join('\n').substring(0, 450) || (fullBody || '').substring(0, 450);
  await self.registration.showNotification(title, {
    body: summary, icon: '/icons/icon-192.png', badge: '/icons/icon-192.png',
    tag, renotify: true, requireInteraction: false,
    actions: [{ action: 'open-coach', title: '📖 Read Full' }],
    data: { screen: 'coach', convType }
  });
}

/* ─── SW helper: get available API key using RPD/RPM tracking ─── */
function swGetAvailableKey(appData) {
  const s = appData.settings || {};
  const candidates = [
    { key: s.coachApiKey,  id: 'key_0' },
    { key: s.coachApiKey2, id: 'key_1' },
    { key: s.coachApiKey3, id: 'key_2' }
  ].filter(k => k.key && k.key.trim());

  if (!candidates.length) return null;

  const stats    = s.apiKeyStats || {};
  const now      = new Date();
  const today    = now.getFullYear() + '-' + String(now.getMonth()+1).padStart(2,'0') + '-' + String(now.getDate()).padStart(2,'0');
  const minuteStr = today + 'T' + String(now.getHours()).padStart(2,'0') + ':' + String(now.getMinutes()).padStart(2,'0');

  for (const k of candidates) {
    const ks      = stats[k.id] || {};
    const rpdUsed = (ks.rpd && ks.rpd.date   === today)     ? ks.rpd.count  : 0;
    const rpmUsed = (ks.rpm && ks.rpm.minute === minuteStr) ? ks.rpm.count  : 0;
    if (rpdUsed >= 18) continue;
    if (rpmUsed >= 4)  continue;
    return { key: k.key, keyId: k.id };
  }
  return null;
}

/* ─── SW helper: call Gemini API with smart key rotation ─── */
async function swCallGemini(apiKey, model, systemText, userText, maxTokens) {
  const url = `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${apiKey}`;
  const resp = await fetch(url, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      systemInstruction: { parts: [{ text: systemText }] },
      contents: [{ role: 'user', parts: [{ text: userText }] }],
      generationConfig: { maxOutputTokens: maxTokens || 800, temperature: 0.85, thinkingConfig: { thinkingBudget: 0 } }
    })
  });
  if (!resp.ok) throw new Error('Gemini ' + resp.status);
  const data = await resp.json();
  return (data.candidates?.[0]?.content?.parts || []).map(p => p.text || '').join('') || '';
}

function swBuildTone(personality, type) {
  const p = personality || 'beast';
  if (type === 'weekly') {
    if (p === 'beast')    return 'Tu ek brutal honest Hinglish weekly coach hai. 7 din ka full reality check de.';
    if (p === 'balanced') return 'Tu ek balanced Hinglish weekly coach hai. 7 din ka honest analysis de.';
    return 'Tu ek encouraging Hinglish weekly coach hai. 7 din ki achievements celebrate kar.';
  }
  if (type === 'daily_progress') {
    if (p === 'beast')    return 'Tu ek brutal reality-check Hinglish coach hai. Overall journey ka honest assessment de.';
    if (p === 'balanced') return 'Tu ek balanced Hinglish coach hai. Overall progress pe honest view de.';
    return 'Tu ek encouraging Hinglish coach hai. Journey celebrate karo, growth highlight karo.';
  }
  if (p === 'beast')    return 'Tu ek brutal no-excuse Hinglish coach hai. Harsh, sarcastic if needed.';
  if (p === 'balanced') return 'Tu ek honest Hinglish coach hai. Direct but not cruel.';
  return 'Tu ek encouraging Hinglish coach hai. Warm but real.';
}

function swGetDailyScore(appData, dateStr) {
  const tasks = (appData.tasks || []).filter(t => t.active !== false);
  const done  = (appData.history || []).filter(h => h.date === dateStr && h.completed).length;
  return { score: tasks.length > 0 ? Math.round((done / tasks.length) * 100) : 0, done, total: tasks.length };
}

function swDateNDaysAgo(n) {
  const d = new Date(); d.setDate(d.getDate() - n);
  return d.getFullYear() + '-' + String(d.getMonth()+1).padStart(2,'0') + '-' + String(d.getDate()).padStart(2,'0');
}

async function swCallGeminiForWeekly(appData, apiKey, now, today) {
  const keyInfo = swGetAvailableKey(appData);
  const activeKey = keyInfo ? keyInfo.key : apiKey; // fallback to passed key
  const model = appData.settings.geminiModel || 'gemini-2.5-flash';
  const personality = appData.settings.autoCoachPersonality || 'beast';
  const last7 = [];
  for (let i = 7; i >= 1; i--) { const d = swDateNDaysAgo(i); const ds = swGetDailyScore(appData, d); last7.push({ date: d, score: ds.score, done: ds.done, total: ds.total }); }
  const avgWeekly = last7.length ? Math.round(last7.reduce((a, b) => a + b.score, 0) / last7.length) : 0;
  const lifeGoals = (appData.settings.egoLifeGoals || '').trim();
  const negWords  = (appData.settings.egoNegativeWords || '').trim();
  const sysText   = swBuildTone(personality, 'weekly') + (lifeGoals ? '\n\n🎯 LIFE GOALS:\n' + lifeGoals : '') + (negWords ? '\n\n💬 LOG KYA KEHTE HAIN:\n' + negWords : '');
  const userText  = `WEEKLY REPORT MODE:\nWeekly Average: ${avgWeekly}%\nLast 7 days:\n${last7.map(d => `${d.date}: ${d.score}% (${d.done}/${d.total})`).join('\n')}\n\nIs 7 din ka full reality check de. Pattern dekh. Next hafte ke liye 2-3 actionable goals bata.\nFormat:\nLine 1: Ek punchy headline (max 90 chars, Hinglish, personal)\nBlank line\nFull weekly reality check response`;
  const raw = await swCallGemini(activeKey, model, sysText, userText, 800);
  const lines = raw.trim().split('\n').filter(l => l.trim());
  return { headline: lines[0].replace(/[*_#]/g, '').substring(0, 90) || '📊 Weekly Report', notifBody: lines.slice(1).join('\n').trim() || raw.trim(), fullResponse: raw };
}

async function swCallGeminiForDaily(appData, apiKey, today) {
  const _ki = swGetAvailableKey(appData);
  const activeKey = _ki ? _ki.key : apiKey;
  const model = appData.settings.geminiModel || 'gemini-2.5-flash';
  const personality = appData.settings.autoCoachPersonality || 'beast';
  const allDates = [...new Set((appData.history || []).map(h => h.date))].sort().filter(d => d < today);
  const scores   = allDates.map(d => swGetDailyScore(appData, d).score);
  const avg      = scores.length ? Math.round(scores.reduce((a, b) => a + b, 0) / scores.length) : 0;
  const best     = scores.length ? Math.max(...scores) : 0;
  const worst    = scores.length ? Math.min(...scores) : 0;
  const lifeGoals = (appData.settings.egoLifeGoals || '').trim();
  const negWords  = (appData.settings.egoNegativeWords || '').trim();
  const sysText   = swBuildTone(personality, 'daily_progress') + (lifeGoals ? '\n\n🎯 LIFE GOALS:\n' + lifeGoals : '') + (negWords ? '\n\n💬 LOG KYA KEHTE HAIN:\n' + negWords : '');
  const userText  = `OVERALL PROGRESS REPORT:\nTotal days: ${allDates.length} | Avg: ${avg}% | Best: ${best}% | Worst: ${worst}% | Started: ${allDates[0] || 'N/A'}\n\nPoori journey ka honest assessment de. Specific numbers use kar.\nFormat:\nLine 1: Ek punchy headline (max 90 chars)\nBlank line\nFull overall progress reality check`;
  const raw = await swCallGemini(activeKey, model, sysText, userText, 800);
  const lines = raw.trim().split('\n').filter(l => l.trim());
  return { headline: lines[0].replace(/[*_#]/g, '').substring(0, 90) || '📈 Progress Report', notifBody: lines.slice(1).join('\n').trim() || raw.trim(), fullResponse: raw };
}

async function swCallGeminiForAutoCoach(appData, apiKey, today, triggerTime) {
  const _ki2 = swGetAvailableKey(appData);
  const activeKey = _ki2 ? _ki2.key : apiKey;
  const model = appData.settings.geminiModel || 'gemini-2.5-flash';
  const personality = appData.settings.autoCoachPersonality || 'beast';
  const tasks = (appData.tasks || []).filter(t => t.active !== false);
  const lifeGoals = (appData.settings.egoLifeGoals || '').trim();
  const negWords  = (appData.settings.egoNegativeWords || '').trim();
  const tasksDue  = tasks.filter(t => (t.workingWindowStart || t.scheduledTime || '00:00') <= triggerTime).map(t => {
    const entry = (appData.history || []).find(h => h.taskId === t.id && h.date === today);
    const done  = entry && entry.completed;
    const cat   = (appData.categories || []).find(c => c.id === t.categoryId);
    const wEnd  = t.workingWindowEnd || '';
    return { name: t.name, category: cat ? cat.name : '', completed: !!done, effortScore: done && entry ? (entry.effortScore || 0) : 0, isUntracked: !done && !!wEnd && wEnd <= triggerTime, isPending: !done && !!wEnd && wEnd > triggerTime, whyMatters: t.whyMatters || '', window: `${t.workingWindowStart || t.scheduledTime || '?'}→${wEnd || '?'}` };
  });
  const doneCount = tasksDue.filter(t => t.completed).length;
  const sysText   = swBuildTone(personality, 'auto') + (lifeGoals ? '\n\n🎯 LIFE GOALS:\n' + lifeGoals : '') + (negWords ? '\n\n💬 LOG KYA KEHTE HAIN:\n' + negWords : '');
  const taskLines = tasksDue.map(t => `• [${t.category}] ${t.name} — ${t.completed ? `✅ DONE (effort ${t.effortScore}/10)` : t.isUntracked ? `⚠️ UNTRACKED` : t.isPending ? `⏳ PENDING` : `❌ NOT DONE`} | Window: ${t.window} | Why: ${t.whyMatters}`).join('\n') || 'Koi task due nahi';
  const userText  = `AUTO CHECK TIME: ${triggerTime}\nTasks due by now:\n${taskLines}\nSummary: ${doneCount}/${tasksDue.length} done\n\nFormat:\nLine 1: Ek punchy headline (max 90 chars, Hinglish, personal)\nBlank line\nFull detailed reality check (task-by-task, efforts, goals connect)`;
  const raw = await swCallGemini(activeKey, model, sysText, userText, 800);
  const lines = raw.trim().split('\n').filter(l => l.trim());
  return { headline: lines[0].replace(/[*_#]/g, '').substring(0, 90) || 'Tera-Ego ka check!', notifBody: lines.slice(1).join('\n').trim() || raw.trim(), fullResponse: raw };
}

/* ─── SW helper: save fired flag + conversation to cached appData ─── */
async function swSaveReportToCache(appData, opts) {
  try {
    const s = appData.settings;
    if (opts.type === 'weekly'   && opts.weekKey) { if (!s.lastWeeklyReportFired)   s.lastWeeklyReportFired   = {}; s.lastWeeklyReportFired[opts.weekKey]   = true; }
    if (opts.type === 'daily_progress' && opts.today) { if (!s.lastDailyProgressFired) s.lastDailyProgressFired = {}; s.lastDailyProgressFired[opts.today]   = true; }
    if (opts.type === 'auto'     && opts.fireKey) { if (!s.lastAutoCoachFired)      s.lastAutoCoachFired      = {}; s.lastAutoCoachFired[opts.fireKey]      = true; }
    if (!appData.conversations) appData.conversations = [];
    appData.conversations.unshift({
      id: 'conv_sw_' + opts.type + '_' + Date.now(), type: opts.type,
      timestamp: Date.now(), date: opts.today || '', triggerTime: opts.triggerTime || '',
      response: opts.fullResponse || '', headline: opts.headline || '',
      scoreLabel: opts.type === 'weekly' ? '📊 Weekly Report (background)' : opts.type === 'daily_progress' ? '📈 Daily Progress (background)' : `🤖 Auto Check — ${opts.triggerTime || ''} (background)`
    });
    if (appData.conversations.length > 30) appData.conversations = appData.conversations.slice(0, 30);
    const cache = await caches.open('aainik-data');
    await cache.put('/sw-data', new Response(JSON.stringify(appData), { headers: { 'Content-Type': 'application/json' } }));
  } catch (e) { console.warn('[SW] Could not save report to cache:', e); }
}

function swGetISOWeekKey(date) {
  const d   = new Date(Date.UTC(date.getFullYear(), date.getMonth(), date.getDate()));
  const day = d.getUTCDay() || 7;
  d.setUTCDate(d.getUTCDate() + 4 - day);
  const yearStart = new Date(Date.UTC(d.getUTCFullYear(), 0, 1));
  const week      = Math.ceil((((d - yearStart) / 86400000) + 1) / 7);
  return `${d.getUTCFullYear()}-W${String(week).padStart(2, '0')}`;
}

