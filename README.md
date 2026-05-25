# Aainik — Flutter Android App

## What Changed From Capacitor Version

**Problem:** Ego/Josh auto-mode notifications required the app to be running.

**Fix:** This Flutter version uses Android **WorkManager** — the same technology WhatsApp/Gmail use for background processing. WorkManager can:
- Call the Gemini API at the scheduled time even when app is **completely killed**
- Show a rich, expandable notification with the **full AI response**
- Reschedule itself for the next day automatically

---

## How to Build (GitHub Actions — No Setup Needed)

1. Create a new GitHub repo (e.g. `aainik-flutter`)
2. Push all files from this zip:
   ```bash
   git init
   git add .
   git commit -m "Aainik Flutter app"
   git remote add origin https://github.com/YOUR_USERNAME/aainik-flutter.git
   git push -u origin main
   ```
3. Go to **Actions** tab on GitHub
4. The **"Build Aainik Android APK"** workflow runs automatically
5. Wait ~10-15 minutes for build to complete
6. Download **aainik-debug-apk** from the workflow run's Artifacts section
7. Install the APK on your Android phone:
   - Settings → Security → Install unknown apps → Enable
   - Open downloaded APK → Install
   - Grant notification permission when asked

---

## First-Time Setup After Install

1. Open the app
2. Go to **Settings** → Add your Gemini API key(s)
3. Go to **Coach** screen → Enable **Ego Auto-Mode** and/or **Josh Auto-Mode**
4. Set your preferred auto-check times
5. **Important:** Go to Android Settings → Apps → Aainik → Battery → Set to **"Unrestricted"**
   - This prevents Android from stopping background tasks

---

## How Background Notifications Work

```
App saves settings
      ↓
Flutter bridge receives schedule
      ↓
WorkManager registers one-off tasks
(e.g., "Call Gemini at 12:00 with today's task data")
      ↓
12:00 arrives — Android OS wakes WorkManager
App is KILLED? No problem — WorkManager runs anyway
      ↓
WorkManager reads app data from SharedPreferences
Calls Gemini API → Gets AI response
      ↓
Shows expandable notification:
  🧠 "Bhai 3/5 tasks done. Reasoning aur Banking skip kiya..."
  (Swipe down to expand full AI response — like Gmail)
      ↓
User opens app → AI conversation auto-appears in Coach history
```

---

## Project Structure

```
lib/
  main.dart              — App entry, WorkManager init
  webview_screen.dart    — WebView + JS bridge (JS ↔ Flutter)
  background_service.dart — WorkManager Gemini API tasks
  notification_service.dart — All Android notification channels

assets/www/
  index.html             — App HTML (with Flutter bridge injected)
  app.js                 — Original app logic (unchanged)
  styles.css             — Original styles (unchanged)
  flutter_bridge.js      — NEW: JS ↔ Flutter communication
  sw.js, manifest.json   — PWA files (kept for compatibility)
  icons/                 — App icons

android/                 — Android project files
.github/workflows/       — GitHub Actions CI/CD
```

---

## All Features Preserved

✅ Today screen — task list, working windows, effort scoring
✅ Categories — CRUD, colored cards
✅ Progress — daily/weekly analytics, streaks, charts
✅ Tera-Ego chat — manual AI coach with full context
✅ Tera-Josh chat — motivational AI chat
✅ **Ego Auto-Mode** — NOW WORKS WHEN APP IS KILLED ✅
✅ **Josh Auto-Mode** — NOW WORKS WHEN APP IS KILLED ✅
✅ Task reminders — pre-scheduled via AlarmManager
✅ Working window expiry alerts
✅ Weekly/daily reports
✅ Multiple Gemini API keys with auto-switching
✅ Dark/light mode
✅ All data in local storage — no cloud required

---

## Troubleshooting

**"Background AI notifications not coming"**
→ Settings → Apps → Aainik → Battery → Set "Unrestricted"
→ Some Android skins (MIUI, OneUI) aggressively kill background tasks
→ Also check: Settings → Apps → Aainik → Battery → Remove from "restricted apps"

**"App not installing"**
→ Enable "Install from unknown sources" in Android Settings → Security

**"Build failing"**
→ Check Actions tab for logs
→ Most common issue: Gradle cache — try re-running the workflow
