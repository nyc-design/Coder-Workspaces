// Minimal service worker for installability. Intentionally has no `fetch`
// listener — any fetch listener (even no-op) wakes the SW thread for every
// request in scope, which adds latency across all of coder.tapiavala.com.
self.addEventListener('install', function () {
  self.skipWaiting();
});

self.addEventListener('activate', function (event) {
  event.waitUntil(self.clients.claim());
});
