/* ═══════════════════════════════════════════════════════════════
   AAINIK — FLUTTER BRIDGE
   Connects the WebView JavaScript to Flutter native code.
   This file is loaded AFTER app.js.

   What this does:
   1. Detects Flutter WebView and sets window._isFlutterApp
   2. Patches window.Notification so Android WebView behaves like
      a browser that supports notifications — routes them to Flutter
      NotificationService via callHandler('showNotification', ...)
   3. Patches saveData() to sync full appData to Flutter
      → Flutter stores it in SharedPreferences
      → WorkManager background tasks can read it when app is killed
   4. Patches scheduleAllCapacitorNotifications() to ALSO register
      background tasks with Flutter WorkManager
      → WorkManager calls Gemini API at scheduled time even when killed
      → Shows rich notification with full AI response
   5. On load, asks Flutter for any pending AI results generated
      while app was killed → injects them into conversations history
═══════════════════════════════════════════════════════════════ */

(function () {
  'use strict';

  // ── Detect Flutter WebView ─────────────────────────────────────
  // flutter_inappwebview provides window.flutter_inappwebview
  function isFlutter() {
    return !!(window.flutter_inappwebview);
  }

  if (!isFlutter()) {
    // Not inside Flutter WebView — bridge not needed
    return;
  }

  // Mark as Flutter app
  window._isFlutterApp = true;
  window._isCapacitorApp = false; // Disable Capacitor path
  document.documentElement.classList.remove('capacitor-native');
  document.documentElement.classList.add('flutter-native');

  console.log('[FlutterBridge] Flutter WebView detected — bridge active');

  // ── Helper: call Flutter handler safely ───────────────────────
  function callFlutter(handlerName, data) {
    try {
      if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
        window.flutter_inappwebview.callHandler(handlerName, data);
      }
    } catch (e) {
      console.warn('[FlutterBridge] callHandler error:', handlerName, e);
    }
  }

  // ── FIX: Shim window.Notification for Flutter WebView ─────────
  // Android WebView does NOT support window.Notification natively.
  // app.js checks `!('Notification' in window)` and shows error toast
  // if it's missing. We shim it here so:
  //   1. `'Notification' in window` → true  (no more error toast)
  //   2. `Notification.permission`  → 'granted' (Flutter already
  //      requested permission in main.dart via NotificationService.initialize())
  //   3. `new Notification(title, opts)` → routes to Flutter via
  //      callHandler('showNotification', ...) → NotificationService
  //   4. `Notification.requestPermission()` → resolves 'granted' and
  //      also asks Flutter to ensure permission is active
  // ──────────────────────────────────────────────────────────────
  (function shimNotification() {
    try {
      if (!('Notification' in window)) {
        // window.Notification does not exist — create full shim
        function FlutterNotification(title, opts) {
          try {
            callFlutter('showNotification', JSON.stringify({
              title: title || '',
              body: (opts && opts.body) || '',
              tag: (opts && opts.tag) || '',
              icon: (opts && opts.icon) || ''
            }));
          } catch (e) {
            console.warn('[FlutterBridge] showNotification shim error:', e);
          }
        }

        FlutterNotification.permission = 'granted';
        FlutterNotification.requestPermission = async function () {
          // Also tell Flutter to (re-)request permission just in case
          callFlutter('requestNotificationPermission', '');
          return 'granted';
        };

        window.Notification = FlutterNotification;
        console.log('[FlutterBridge] window.Notification shimmed for Flutter');

      } else {
        // window.Notification exists but may report wrong permission —
        // override permission to 'granted' since Flutter handles it natively
        try {
          Object.defineProperty(window.Notification, 'permission', {
            get: function () { return 'granted'; },
            configurable: true
          });
        } catch (e) {
          // read-only — ignore, not critical
        }

        const _origRequestPerm = window.Notification.requestPermission;
        window.Notification.requestPermission = async function () {
          callFlutter('requestNotificationPermission', '');
          return 'granted';
        };

        console.log('[FlutterBridge] window.Notification.permission patched to granted');
      }
    } catch (e) {
      console.warn('[FlutterBridge] shimNotification error:', e);
    }
  })();

  // ── Sync full appData to Flutter SharedPreferences ────────────
  // Called every time saveData() is called in app.js
  // WorkManager background tasks read this to build Gemini prompts.
  window._flutterSyncAppData = function (dataJson) {
    callFlutter('syncAppData', dataJson);
  };

  // ── Register/update background task schedule with Flutter ─────
  // Flutter WorkManager handles the actual background Gemini API calls
  window._flutterScheduleBackgroundTasks = function (scheduleJson) {
    callFlutter('scheduleBackgroundTasks', scheduleJson);
  };

  // ── Flutter → JS: inject pending AI conversations ─────────────
  // Called by Flutter when app opens after background AI tasks ran
  window._flutterInjectPendingConversations = function (pendingJson) {
    try {
      if (!pendingJson || typeof pendingJson !== 'string') return;
      const pending = JSON.parse(pendingJson);

      if (!pending || (!pending.egoConversations && !pending.joshConversations)) return;

      // Wait for appData to be loaded
      const inject = function () {
        if (typeof appData === 'undefined' || !appData) {
          setTimeout(inject, 500);
          return;
        }

        let changed = false;

        // Inject Ego conversations
        if (pending.egoConversations && pending.egoConversations.length > 0) {
          if (!appData.conversations) appData.conversations = [];
          // Prepend — newest first, avoid duplicates by id
          const existingIds = new Set(appData.conversations.map(c => c.id));
          const toAdd = pending.egoConversations.filter(c => !existingIds.has(c.id));
          if (toAdd.length > 0) {
            appData.conversations = toAdd.concat(appData.conversations);
            if (appData.conversations.length > 30) appData.conversations = appData.conversations.slice(0, 30);
            changed = true;
          }
        }

        // Inject Josh conversations
        if (pending.joshConversations && pending.joshConversations.length > 0) {
          if (!appData.joshConversations) appData.joshConversations = [];
          const existingIds = new Set(appData.joshConversations.map(c => c.id));
          const toAdd = pending.joshConversations.filter(c => !existingIds.has(c.id));
          if (toAdd.length > 0) {
            appData.joshConversations = toAdd.concat(appData.joshConversations);
            if (appData.joshConversations.length > 30) appData.joshConversations = appData.joshConversations.slice(0, 30);
            changed = true;
          }
        }

        if (changed) {
          // Save to localStorage so it persists, then refresh UI
          try { localStorage.setItem('taskMastery_v1', JSON.stringify(appData)); } catch (e) {}
          if (typeof renderCoachScreen === 'function' && typeof currentScreen !== 'undefined' && currentScreen === 'coach') {
            renderCoachScreen();
          }
          if (typeof showToast === 'function' && pending.egoConversations && pending.egoConversations.length > 0) {
            showToast('🧠 Background AI check results ready — Coach screen dekho!');
          }
          console.log('[FlutterBridge] Injected', (pending.egoConversations || []).length, 'ego +', (pending.joshConversations || []).length, 'josh conversations');
        }

        // Tell Flutter we've consumed the pending data
        callFlutter('clearPendingConversations', '');
      };

      inject();
    } catch (e) {
      console.warn('[FlutterBridge] injectPendingConversations error:', e);
    }
  };

  // ── Patch saveData ─────────────────────────────────────────────
  // app.js defines saveData() globally. We wrap it here to also sync to Flutter.
  const _waitForSaveData = function () {
    if (typeof saveData !== 'function') {
      setTimeout(_waitForSaveData, 300);
      return;
    }

    const _originalSaveData = saveData;
    window.saveData = function () {
      _originalSaveData.apply(this, arguments);
      // Sync to Flutter after save
      try {
        const raw = localStorage.getItem('taskMastery_v1');
        if (raw) {
          window._flutterSyncAppData(raw);
        }
      } catch (e) {
        console.warn('[FlutterBridge] syncAppData error:', e);
      }
    };
    console.log('[FlutterBridge] saveData patched');
  };
  _waitForSaveData();

  // ── Patch scheduleAllCapacitorNotifications ────────────────────
  // Also register background tasks with Flutter WorkManager
  const _waitForScheduleFn = function () {
    if (typeof scheduleAllCapacitorNotifications !== 'function') {
      setTimeout(_waitForScheduleFn, 300);
      return;
    }

    const _originalSchedule = scheduleAllCapacitorNotifications;
    window.scheduleAllCapacitorNotifications = async function () {
      // Also register Flutter WorkManager background tasks
      try {
        const raw = localStorage.getItem('taskMastery_v1');
        if (raw) {
          const data = JSON.parse(raw);
          const s = data.settings || {};

          // Build schedule config for Flutter
          const scheduleConfig = {
            // Ego auto-coach
            egoEnabled: !!(s.autoCoachEnabled),
            egoTimes: (s.autoCoachTimes || []).filter(t => t.enabled && t.time),
            egoPersonality: s.autoCoachPersonality || 'beast',
            egoMaxPerDay: s.autoCoachMaxPerDay || 3,

            // Josh auto-reminder
            joshEnabled: !!(s.joshAutoEnabled),
            joshTimes: (s.joshAutoTimes || []).filter(t => t.enabled && t.time),
            joshPersonality: s.joshPersonality || 'energetic',
            joshMaxPerDay: s.joshAutoMaxPerDay || 3,

            // Task reminders (for Flutter local notifications)
            tasks: (data.tasks || []).filter(t => t.active !== false).map(t => ({
              id: t.id,
              name: t.name,
              categoryId: t.categoryId,
              workingWindowEnd: t.workingWindowEnd || '',
              notifications: (t.notifications || []).filter(n => n.enabled && n.time && n.message)
            })),

            // Categories (for notification context)
            categories: (data.categories || []).map(c => ({ id: c.id, name: c.name })),

            // API keys (needed by background tasks)
            apiKey1: s.coachApiKey || '',
            apiKey2: s.coachApiKey2 || '',
            apiKey3: s.coachApiKey3 || '',
            geminiModel: s.geminiModel || 'gemini-2.5-flash',
            geminiSearchEnabled: s.geminiSearchEnabled !== false,
          };

          window._flutterScheduleBackgroundTasks(JSON.stringify(scheduleConfig));
        }
      } catch (e) {
        console.warn('[FlutterBridge] scheduleBackgroundTasks error:', e);
      }
    };
    console.log('[FlutterBridge] scheduleAllCapacitorNotifications patched');
  };
  _waitForScheduleFn();

  // ── On load: request pending AI conversations from Flutter ─────
  window.addEventListener('load', function () {
    setTimeout(function () {
      callFlutter('requestPendingConversations', '');
    }, 1500); // Small delay to let appData load first
  });

  console.log('[FlutterBridge] Initialized successfully');

})();
