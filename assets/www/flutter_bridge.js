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

  // ── Inbox Bridge Functions ────────────────────────────────────────────

  // Get ego inbox items from Flutter SharedPreferences
  window._flutterGetEgoInbox = async function () {
    try {
      const result = await window.flutter_inappwebview.callHandler('getEgoInbox');
      const parsed = typeof result === 'string' ? JSON.parse(result) : result;
      return parsed.items || [];
    } catch (e) {
      console.warn('[FlutterBridge] getEgoInbox error:', e);
      return [];
    }
  };

  // Get josh inbox items from Flutter SharedPreferences
  window._flutterGetJoshInbox = async function () {
    try {
      const result = await window.flutter_inappwebview.callHandler('getJoshInbox');
      const parsed = typeof result === 'string' ? JSON.parse(result) : result;
      return parsed.items || [];
    } catch (e) {
      console.warn('[FlutterBridge] getJoshInbox error:', e);
      return [];
    }
  };

  // Save generated response back to inbox item in SharedPreferences
  window._flutterUpdateInboxItemResponse = function (isEgo, itemId, response) {
    try {
      callFlutter('updateInboxItemResponse', JSON.stringify({ isEgo, itemId, response }));
    } catch (e) {
      console.warn('[FlutterBridge] updateInboxItemResponse error:', e);
    }
  };

  // Get full appData from SharedPreferences for building Gemini prompt in inbox
  window._flutterGetAppDataForInbox = async function () {
    try {
      const result = await window.flutter_inappwebview.callHandler('getAppDataForInbox');
      return typeof result === 'string' ? JSON.parse(result) : result;
    } catch (e) {
      console.warn('[FlutterBridge] getAppDataForInbox error:', e);
      return null;
    }
  };

  console.log('[FlutterBridge] Initialized successfully');

})();
