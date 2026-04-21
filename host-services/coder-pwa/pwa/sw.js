// Minimal pass-through service worker. Present so Chromium-based browsers
// consider the page installable; does NOT cache Coder responses.
self.addEventListener('install', function () {
  self.skipWaiting();
});

self.addEventListener('activate', function (event) {
  event.waitUntil(self.clients.claim());
});

self.addEventListener('fetch', function () {
  // No-op — let the network handle everything. A fetch listener must exist
  // for some browsers to mark the app installable.
});
