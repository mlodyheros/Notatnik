// Service worker Notatnika — pozwala zainstalować appkę jako PWA i otworzyć ją bez internetu.
// Cała aplikacja to jeden index.html, więc w cache trzymamy tylko go + manifest i ikony.
// CACHE_NAME jest wersjonowany: podbicie numeru przy wdrożeniu sprawia, że "activate" kasuje
// stare cache, a skipWaiting() + clients.claim() przejmują otwarte karty od razu, bez czekania
// na zamknięcie wszystkich (index.html pokazuje wtedy toast „Dostępna nowa wersja”).
const CACHE_NAME = "notatnik-cache-v20";
const ASSETS = [
  "./index.html",
  "./manifest.json",
  "./icon-192.png",
  "./icon-512.png"
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    // błąd precache nie może zablokować instalacji — brakujące pliki dociągnie fetch niżej
    caches.open(CACHE_NAME).then((cache) => cache.addAll(ASSETS)).catch(() => {})
  );
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener("fetch", (event) => {
  // zapisy (POST/PATCH/DELETE, np. do API Supabase) zawsze idą prosto do sieci
  if (event.request.method !== "GET") return;

  // dokument HTML (cała aplikacja): najpierw sieć, cache tylko jako fallback offline —
  // inaczej powracający użytkownik zawsze widzi starą wersję do czasu odświeżenia w tle
  if (event.request.mode === "navigate" || event.request.destination === "document") {
    event.respondWith(
      fetch(event.request)
        .then((response) => {
          if (response && response.status === 200) {
            const copy = response.clone();
            caches.open(CACHE_NAME).then((cache) => cache.put(event.request, copy));
          }
          return response;
        })
        .catch(() => caches.match(event.request))
    );
    return;
  }

  // reszta zasobów (ikony, manifest): cache-first, w tle odśwież z sieci
  event.respondWith(
    caches.match(event.request).then((cached) => {
      const networkFetch = fetch(event.request)
        .then((response) => {
          if (response && response.status === 200) {
            const copy = response.clone();
            caches.open(CACHE_NAME).then((cache) => cache.put(event.request, copy));
          }
          return response;
        })
        .catch(() => cached);
      return cached || networkFetch;
    })
  );
});
