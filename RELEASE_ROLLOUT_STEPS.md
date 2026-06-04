# ArcOps Release & Update — Devreye Alma Adımları (Senin yapacakların, sırayla)

> Kod yazıldı, doğrulandı, **henüz hiçbir şey push edilmedi.** Bu doküman sistemi
> CANLI hale getirmek için **senin** sırayla yapman gereken adımlar. Teknik
> referans: `commons/RELEASE_AND_UPDATE.md`. "→ Claude" yazan adımları, onay
> verdiğinde ben yaparım.

---

## FAZ 0 — Secret'lar ve ön hazırlık  (push'tan ÖNCE, sadece sen yapabilirsin)

- [ ] **Adım 1 — Yayın token'ı üret.**
  Güçlü rastgele bir değer üret ve bir yere kaydet (2 yerde kullanacaksın):
  ```
  openssl rand -hex 32
  ```
  Bu, `ARCOPS_RELEASE_PUBLISH_TOKEN` değeri olacak.

- [ ] **Adım 2 — GHCR_PAT üret.**
  GitHub → Settings → Developer settings → Personal access tokens.
  `write:packages` + `read:packages` yetkili, **arcyintel** org paketlerine
  yazabilen bir token (fine-grained ise: arcyintel/* için Packages: write).
  release.yml/promote.yml çapraz-repo imaj re-tag'i için şart (varsayılan
  `GITHUB_TOKEN` kardeş repo'ların paketlerine yazamaz).

- [ ] **Adım 3 — commons repo secret'larını gir.**
  GitHub → `arcyintel/commons` → Settings → Secrets and variables → Actions →
  New repository secret (3 adet):
  | Secret | Değer |
  |--------|-------|
  | `GHCR_PAT` | Adım 2'deki token |
  | `LICENCE_SERVER_URL` | `https://licence.arcyintel.com` (gerçek origin) |
  | `ARCOPS_RELEASE_PUBLISH_TOKEN` | Adım 1'deki değer |

- [ ] **Adım 4 — licence-server'a env ekle.**
  Lisans sunucusu deployment'ının ortam değişkenlerine **Adım 1'deki AYNI değeri**
  ekle:
  ```
  ARCOPS_RELEASE_PUBLISH_TOKEN=<Adım 1'deki değer>
  ```
  (Boş kalırsa `POST /api/v1/release/manifest` 503 döner → promote manifesti
  canlı endpoint'e yazamaz, sadece commons'a commit'ler.)

---

## FAZ 1 — Gözden geçir + push  (bana onay ver → Claude push eder)

- [ ] **Adım 5 — (Opsiyonel) Gözden geçir.**
  Değişen 5 yer: `commons`, `license-server`, `gateway`, `licence-portal`,
  kök `ARCHITECTURE.md`. İstersen "dosya listesini çıkar" de.

- [ ] **Adım 6 — Push onayı ver. → Claude**
  Bana **"push et"** dediğinde, 5 repo'yu sırayla commit + push ederim:
  - `license-server` + `gateway` → Actions → ghcr `:latest` (yeni manifest
    endpoint + `X-Installed-Version` canlı olur)
  - `commons` → arcops-updater imajı `:latest` + Maven SNAPSHOT
  - `licence-portal` → build/deploy ("Filo" sayfası)

- [ ] **Adım 7 — Lisans sunucusunu güncelle.**
  `license-server`'ın yeni `:latest` imajının **lisans kutusuna** deploy
  olduğunu doğrula (lisans sunucusu kendi mekanizmasıyla güncellenir; müşteri
  filosu manifest'inde değildir). Doğrulama:
  ```
  curl -s https://licence.arcyintel.com/api/v1/release/manifest?channel=stable
  # henüz promote edilmediği için 404 "no manifest" beklenir — endpoint AYAKTA demektir.
  ```

---

## FAZ 2 — Test sunucusu cutover (edge)

- [ ] **Adım 8 — test.uconos.com'u watchtower → arcops-updater (edge)'e geçir.**
  Runbook: `RELEASE_AND_UPDATE.md` §6. Özet:
  1. Yeni compose'u çek, `.env`'i yedekle.
  2. `.env`'e edge knob'larını ekle (`ARCOPS_CHANNEL=edge`, `ARCOPS_UPDATER_TAG=latest`,
     `ARCOPS_EDGE_TAG=latest`, `INSTALLED_VERSION=edge`, poll=120,
     `ARCOPS_EDGE_CADDYFILE_URL=` boş bırak).
  3. `docker compose stop watchtower && docker rm -f watchtower`
  4. `docker compose pull arcops-updater && docker compose up -d arcops-updater`
  5. `docker logs -f arcops-updater` → bir tur izle.
  → Claude: "kutuda cutover yap" dersen SSH ile yaparım (her durum değiştiren
  adım için ayrı onayını alırım). Kutu interneti yavaş (~475 KB/s), sabırlı olmak gerek.

- [ ] **Adım 9 — Edge'i doğrula.**
  Küçük bir `main` push'tan sonra edge kutusunun kendini güncellediğini gör
  (`docker logs arcops-updater` → "change detected" → "all services healthy").

---

## FAZ 3 — İlk gerçek release + promote

- [ ] **Adım 10 — İlk sürümü kes.** → Claude (istersen)
  `commons`'ta sürüm etiketi at:
  ```
  git tag v1.5.0 && git push origin v1.5.0
  ```
  `release.yml` tüm servislerin doğrulanmış `:latest` digest'ini `:1.5.0`'a pinler.

- [ ] **Adım 11 — Promote et.**
  GitHub → `commons` → Actions → **Promote — :X.Y.Z → :stable + manifest** →
  Run workflow → `version=1.5.0`. → `:stable` re-tag + `manifest-stable.json`
  commit + lisans sunucusuna POST.

- [ ] **Adım 12 — Doğrula.**
  ```
  curl -s https://licence.arcyintel.com/api/v1/release/manifest?channel=stable | jq .version   # 1.5.0
  ```
  licence-portal → **Filo** sayfası kutuları + sürümleri gösterir.

---

## FAZ 4 — Müşteri yaygınlaştırma

- [ ] **Adım 13 — Yeni müşteri kurulumları.**
  ```
  sudo ./setup.sh --domain mdm.MUSTERI.com --license-server-url https://licence.arcyintel.com
  ```
  (Varsayılan `stable`; manifest'ten en güncel sürüme yakınsar.)

- [ ] **Adım 14 — Mevcut müşteri kutuları (cutover).**
  Her biri için watchtower → arcops-updater (stable) geçişi: Runbook §6, ama
  `ARCOPS_CHANNEL=stable` + `ARCOPS_UPDATER_TAG=stable` + `INSTALLED_VERSION`'ı
  o kutunun mevcut sürümüne ayarla. Bundan sonra filo kendi kendini günceller.

---

## İlgili / ayrı işler (bu sistemden bağımsız)

- **Task #71 — Production master key cutover** (lisans imzalama RSA anahtarı):
  gerçek müşteri go-live'ından önce; update sisteminden bağımsız bir adım.
- **U5 (sürüm gömme `/actuator/info`)**: tasarımca ertelendi — Fleet view zaten
  `INSTALLED_VERSION` ile sürümü raporluyor, gerek yok.

---

### Özet sıra
`Faz 0 (secret'lar)` → `Faz 1 (push)` → `Faz 2 (edge cutover + doğrula)` →
`Faz 3 (release + promote + doğrula)` → `Faz 4 (müşteriler)`.
**Kritik bağımlılık:** Adım 11 (promote) çalışmadan önce Adım 3 + 4 (secret'lar) şart.
