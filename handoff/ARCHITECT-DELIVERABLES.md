# Architect Deliverables — Fidela

*Auteur : Arch — 2026-05-11*
*Source de référence : `ARCHITECTURE_BRIEF.md` (racine)*

Document vivant. Mis à jour à chaque paquet de livrables produit.

---

## Plan de livraison

| Paquet | Livrables (section 9 du brief) | Statut |
|---|---|---|
| **1** | 1. Schéma DDL · 2. Policies RLS · 3. Diagramme archi | Validé tacitement par Solal ("ça va, continue") |
| **2** | 4. Routes API · 5. Server actions vs API · 6. Certifs Apple · 7. Flow client | **À VALIDER par Solal** |
| 3 | 8. Flow commerçant · 9. Stratégie tests · 10. Estimation complexité · 11. Risques · 12. Plan sprints | À venir |

---

# Paquet 1 — Fondations DB & architecture

## Livrable 1 — Schéma de données : critique + DDL

**Fichier exécutable : `db/schema.sql`** (à coller dans Supabase Studio → SQL Editor)

### Décisions sur les 3 arbitrages du brief (section 6)

**Q1 — Table `users` séparée de `merchants` pour anticiper multi-user ?**
**Non.** Le multi-user est explicitement hors scope MVP (section 4). YAGNI. Si pivot futur, une table `merchant_members(merchant_id, user_id, role)` est ajoutable en 1h sans casser l'existant. Garder simple maintenant.

**Q2 — Soft-deletes RGPD vs intégrité stats ?**
Stratégie **hybride** :
- `merchants`, `customer_passes` → soft-delete via `deleted_at` (timestamp NULL = vivant).
- `customers` → **anonymisation** via fonction `anonymize_customer(id)` qui NULL email/phone et flag `anonymized_at`. La ligne reste pour préserver l'historique des stamps (sinon "nombre total de tampons" devient faux).
- `stamps`, `rewards_claimed` → **immutables** (jamais delete, jamais update). RGPD géré via la cascade de l'anonymisation customer.
- `waitlist` → hard-delete possible (pas d'historique à préserver).

**Q3 — Indexation ?**
Voir `schema.sql`. Les index posés :
- `merchants(user_id)`, `merchants(slug)` — lookup auth + landing client
- `customer_passes(serial_number)` UNIQUE — lookup pass Apple/Google
- `customer_passes(merchant_id)`, `customer_passes(customer_id)` — listings dashboard
- `customers(merchant_id, email)`, `customers(merchant_id, phone)` — dedup inscription
- `stamps(customer_pass_id, created_at DESC)` — anti-fraude lookup dernier tampon
- `stamps(merchant_id, created_at DESC)` — stats merchant

### Critiques et corrections du schéma initial

| Point | Schéma initial | Correction |
|---|---|---|
| **Dedup customers** | "Déduplication par couple (email, phone, **merchant_id**)" mais la table n'avait pas `merchant_id` | Ajout `merchant_id` direct sur `customers`. Un même email chez 2 merchants = 2 lignes. Simplifie aussi les RLS. |
| **Apple PassKit auth** | Aucun token | Ajout `auth_token` sur `customer_passes`. Apple PassKit Web Service exige un `authenticationToken` pour les callbacks device→server (sans lui, impossible de pousser des mises à jour). |
| **Devices Apple** | Table manquante | Ajout table `apple_devices` (deviceLibraryIdentifier + pushToken). Requis par la spec PassKit Web Service quand un iPhone enregistre le pass. |
| **Google Wallet push** | Pas de table dédiée | Confirmé : pas besoin. Google Wallet se met à jour via PATCH sur l'objet côté serveur, pas via push token client. |
| **Anti-fraude tampon** | Règle "1 tampon / 30 min" mais aucun mécanisme | Fonction PL/pgSQL `add_stamp(pass_id)` (security definer) qui vérifie le dernier tampon avant insertion. **Atomique = pas de race condition.** Toutes les routes API doivent passer par cette fonction, jamais d'INSERT direct dans `stamps`. |
| **Couleurs hex** | `text` libre | `text` + `CHECK regex '^#[0-9A-Fa-f]{6}$'` pour éviter qu'un programme casse le rendu du pass avec une valeur invalide. |
| **Slug merchant** | `text` libre | `text UNIQUE + CHECK regex '^[a-z0-9-]{3,60}$'` (URL-safe). |
| **`stamps_required`** | `int` libre | `CHECK between 1 and 50`. 0 tampon n'a aucun sens, 50+ détecte erreur de saisie. |
| **Soft-delete customer_passes** | Absent | Ajout `deleted_at` (un client peut vouloir retirer son pass sans effacer son historique de tampons côté merchant pour les stats). |
| **`updated_at` automatique** | À gérer côté code | Trigger PL/pgSQL `set_updated_at()` sur toutes les tables qui en ont. Une seule fonction, pas de répétition. |
| **`business_type`** | `text` libre | ENUM (boulangerie, restaurant, cafe, coiffeur, institut_beaute, fleuriste, autre) — facilite stats + filtres. |

### Décisions hors arbitrage à signaler à Solal

1. **`email` en `citext`** (case-insensitive) au lieu de `text` : `Jean@x.fr` et `jean@x.fr` = même email. Évite les doublons "fantômes".
2. **Pas de table `merchants_settings` séparée** : tout reste dans `merchants` pour MVP. À séparer plus tard si on ajoute des dizaines de toggles.
3. **Fonction `add_stamp` en `security definer`** : elle bypasse RLS et fait elle-même les checks. C'est la seule manière propre d'enforcer l'anti-fraude de manière atomique. La fonction est `GRANT EXECUTE TO authenticated` mais elle vérifie en interne que l'appelant est bien le merchant propriétaire.

---

## Livrable 2 — Policies RLS exhaustives

**Fichier exécutable : `db/rls.sql`** (à coller APRÈS `schema.sql`).

### Modèle de sécurité (3 rôles)

| Rôle Supabase | Qui | Droits |
|---|---|---|
| `anon` | Visiteur non-connecté (landing pub, page `/c/[slug]`) | Lecture seule : `merchants` non supprimés, `loyalty_programs` actifs. INSERT autorisé sur `waitlist`. |
| `authenticated` | Commerçant connecté | Accès à SES données via `merchants.user_id = auth.uid()`. |
| `service_role` | Routes API serveur (côté Next.js) | Bypass RLS. Utilisé pour : génération pass, webhooks Stripe/Apple, inscription client, anti-fraude. **Jamais exposé côté client.** |

### Table par table

| Table | anon | authenticated (merchant) | service_role |
|---|---|---|---|
| `merchants` | SELECT (non-deleted) | SELECT/UPDATE own | All (INSERT onboarding, soft-delete) |
| `loyalty_programs` | SELECT (is_active) | SELECT/INSERT/UPDATE own | All |
| `customers` | — | SELECT/UPDATE own merchant's customers | INSERT (inscription client), DELETE |
| `customer_passes` | — | SELECT own | All (génération, incrément stamps) |
| `apple_devices` | — | — | All (callbacks PassKit) |
| `stamps` | — | SELECT own | INSERT via fonction `add_stamp` |
| `rewards_claimed` | — | SELECT/INSERT own | All |
| `waitlist` | INSERT | INSERT | All |

### Pièges évités

- **Pas de policy INSERT sur `merchants` pour `authenticated`** : sinon un user pourrait créer un compte merchant en bypassant le paiement Stripe. L'onboarding passe obligatoirement par route API serveur (vérifie le paiement, crée le merchant en service_role).
- **Pas de policy INSERT directe sur `stamps`** : sinon on bypasse l'anti-fraude 30 min. Tout passe par `add_stamp()`.
- **Pas de DELETE applicatif** sur les tables d'historique (`stamps`, `rewards_claimed`). Immutables.

---

## Livrable 3 — Diagramme d'architecture applicative

### Vue d'ensemble

```
                          ┌──────────────────────────────┐
                          │     UTILISATEURS FINAUX      │
                          ├──────────────────────────────┤
                          │  Commerçant (smartphone)     │
                          │  Client final (smartphone)   │
                          │  Visiteur landing            │
                          └──────────────┬───────────────┘
                                         │ HTTPS
                                         ▼
   ┌─────────────────────────────────────────────────────────────────┐
   │                    NEXT.JS 15 — APP ROUTER (Vercel)             │
   │                                                                 │
   │  ┌─── CLIENT (React Server Components + Client Components) ──┐  │
   │  │   - Landing publique (/)                                  │  │
   │  │   - Inscription commerçant (/signup)                      │  │
   │  │   - Dashboard merchant (/dashboard/*)                     │  │
   │  │   - Inscription client (/c/[slug])                        │  │
   │  │   - Scan tampon (/dashboard/stamp)                        │  │
   │  └───────────────┬──────────────────────┬────────────────────┘  │
   │                  │                      │                       │
   │                  ▼                      ▼                       │
   │  ┌── SERVER ACTIONS ──┐    ┌─────── ROUTES API ─────────────┐   │
   │  │  Mutations simples │    │  /api/passes/apple/[serial]    │   │
   │  │  côté dashboard    │    │  /api/passes/google/[serial]   │   │
   │  │  (update profil,   │    │  /api/stamps  (utilise add_stamp│  │
   │  │   créer programme) │    │  /api/webhooks/stripe          │   │
   │  │                    │    │  /api/webhooks/apple-wallet    │   │
   │  │                    │    │  /api/customers/signup         │   │
   │  └─────────┬──────────┘    └─────────────┬──────────────────┘   │
   │            │                             │                      │
   │            │      service_role           │                      │
   │            ▼                             ▼                      │
   │  ┌────────────────────────────────────────────────────────┐     │
   │  │           lib/  (Supabase, Stripe, Wallets)            │     │
   │  └──┬──────────────┬───────────────┬──────────────┬───────┘     │
   └─────┼──────────────┼───────────────┼──────────────┼─────────────┘
         │              │               │              │
         ▼              ▼               ▼              ▼
   ┌──────────┐  ┌────────────┐  ┌────────────┐  ┌──────────┐
   │ SUPABASE │  │   STRIPE   │  │   APPLE    │  │  GOOGLE  │
   │ Frankfurt│  │  Checkout  │  │  PassKit   │  │  Wallet  │
   │          │  │  + Subs    │  │  (signing  │  │  REST    │
   │ Postgres │  │  + Webhook │  │   .pkpass) │  │  API     │
   │ + Auth   │  │            │  │  + APNs    │  │  + OAuth │
   │ + Storage│  │            │  │            │  │          │
   └──────────┘  └────────────┘  └────────────┘  └──────────┘
```

### Frontières clés

| Frontière | Ce qui la traverse |
|---|---|
| **Client → Server (Next.js)** | Server Actions (mutations simples auth), Fetch API routes (génération pass, webhooks) |
| **Server → Supabase** | Côté `authenticated` : queries via `@supabase/ssr` avec cookie session. Côté `service_role` : opérations sensibles via `lib/supabase/admin.ts`. |
| **Server ↔ Stripe** | Checkout session create + webhook IN (signature vérifiée obligatoire) |
| **Server → Apple** | `passkit-generator` signe le .pkpass localement avec les certifs. APNs côté Apple notifié pour push update. |
| **Server → Google Wallet** | API REST authentifiée via JWT (service account). |
| **Apple → Server** | Callbacks PassKit Web Service : `/api/webhooks/apple-wallet/v1/devices/...` (enregistrement device, log errors). |

### Choix de patterns

1. **Server Actions pour les mutations simples authentifiées du dashboard** (créer programme, update profil). Plus simple que des routes API, intégration native Next 15.
2. **Routes API pour tout le reste** : génération pass (besoin de retourner un binaire `.pkpass`), webhooks (besoin de répondre 200/400 spécifiquement), inscription client (utilisée par un visiteur anonyme, pas un user authentifié).
3. **Pas de couche service/repository en plus** entre routes et Supabase pour MVP. Le SDK Supabase est déjà une couche d'abstraction. Ajouter un repository pattern = code en plus que Solal devra maintenir sans gain. Si la logique se complexifie, on extraira par module dans `lib/`.
4. **`lib/wallets/apple.ts` et `lib/wallets/google.ts`** comme seuls points d'entrée vers ces deux APIs externes. Tout le reste du code ne connaît que ces deux fonctions.

### Diagramme : flow tampon (exemple, sera détaillé dans le livrable 7)

```
Commerçant scanne QR du pass client
        │
        ▼
[Dashboard /dashboard/stamp] (client)
        │ POST /api/stamps { serial_number }
        ▼
[Route API /api/stamps] (server, authenticated)
        │ supabase.rpc('add_stamp', { pass_id })
        ▼
[Postgres : fonction add_stamp]
        │ - check ownership merchant
        │ - check dernier tampon > 30 min
        │ - INSERT stamps
        │ - UPDATE customer_passes.current_stamps
        ▼
[Route API] retourne new_count
        │ + déclenche push update wallet (background)
        ▼
[lib/wallets/apple.ts] → APNs
[lib/wallets/google.ts] → PATCH objet
```

---

---

# Paquet 2 — Routes, certifs Apple, flow client

## Livrable 4 — Routes API exhaustives

**Conventions générales** :
- Toutes les routes sous `app/api/...` (App Router Next.js 15)
- Auth `authenticated` = cookie Supabase session vérifié via `@supabase/ssr` côté serveur
- Auth `service_role` = JAMAIS appelable directement par le client, uniquement utilisée en interne par les routes elles-mêmes
- Toutes les routes valident leur body avec Zod
- Toutes les routes loggent vers Sentry en cas d'erreur 5xx
- Toutes les routes en français pour les messages d'erreur exposés au client

### Routes publiques (anon)

| Méthode | Path | Body / Query | Réponse | Notes |
|---|---|---|---|---|
| `POST` | `/api/waitlist` | `{ email: string, source?: string }` | `201 { ok: true }` ou `400 { error }` | Rate-limit IP (10/h) |
| `GET`  | `/api/c/[slug]` | path: `slug` | `200 { merchant: { business_name, logo_url, ... }, program: { name, stamps_required, reward_description, colors } }` | Sert au render initial de `/c/[slug]`. Filtre les colonnes sensibles. |
| `POST` | `/api/customers/signup` | `{ slug: string, email?: string, phone?: string, consent: true, user_agent: string }` | `200 { pass_url: string, platform: "apple" \| "google" }` | Détecte iOS/Android via UA. Crée customer + customer_pass + génère wallet pass. |
| `GET`  | `/api/passes/apple/[serial]` | header `Authorization: ApplePass <auth_token>` | `200 application/vnd.apple.pkpass` (binaire) | Sert le `.pkpass` à jour. Vérifie `auth_token`. |

### Routes Apple PassKit Web Service (callbacks Apple → notre serveur)

Spec imposée par Apple, paths exacts (réf : [Apple Developer — Adding Web Service to Update Passes](https://developer.apple.com/documentation/walletpasses)) :

| Méthode | Path | Rôle |
|---|---|---|
| `POST` | `/api/webhooks/apple-wallet/v1/devices/[deviceLibraryIdentifier]/registrations/[passTypeIdentifier]/[serial]` | iPhone enregistre un pass — body `{ pushToken }`. Insert dans `apple_devices`. Renvoie `201`. |
| `DELETE` | `/api/webhooks/apple-wallet/v1/devices/[deviceLibraryIdentifier]/registrations/[passTypeIdentifier]/[serial]` | iPhone désenregistre. Delete `apple_devices`. Renvoie `200`. |
| `GET` | `/api/webhooks/apple-wallet/v1/devices/[deviceLibraryIdentifier]/registrations/[passTypeIdentifier]?passesUpdatedSince=...` | Apple demande la liste des passes modifiés depuis date X. Renvoie `200 { serialNumbers, lastUpdated }` ou `204`. |
| `GET` | `/api/webhooks/apple-wallet/v1/passes/[passTypeIdentifier]/[serial]` | Apple veut le pass à jour. Header `Authorization: ApplePass <token>` vérifié. Renvoie `.pkpass` binaire. |
| `POST` | `/api/webhooks/apple-wallet/v1/log` | Apple envoie des logs d'erreur. Body `{ logs: string[] }`. Log dans Sentry. Renvoie `200`. |

### Routes Stripe (webhooks)

| Méthode | Path | Rôle |
|---|---|---|
| `POST` | `/api/webhooks/stripe` | Vérifie signature `Stripe-Signature` (OBLIGATOIRE). Body raw. Events traités : `checkout.session.completed` (active subscription), `invoice.payment_failed` (passe en past_due), `customer.subscription.deleted` (canceled). |

### Routes authenticated (merchant connecté)

| Méthode | Path | Body | Réponse | Rôle |
|---|---|---|---|---|
| `POST` | `/api/onboarding/checkout` | — | `200 { checkout_url }` | Crée Stripe Checkout session (setup 99€ + subscription 19€/mo) |
| `POST` | `/api/stamps` | `{ pass_id: uuid }` ou `{ serial_number: string }` | `200 { new_count: int, reward_unlocked: bool }` ou `429 { error: "Tampon déjà ajouté il y a moins de 30 min" }` | Appelle `add_stamp()` Postgres |
| `POST` | `/api/rewards/claim` | `{ pass_id: uuid }` | `200 { remaining_stamps: int }` | INSERT `rewards_claimed` + reset `current_stamps` à 0 |
| `POST` | `/api/customers/[id]/anonymize` | — | `200 { ok: true }` | RGPD : appelle `anonymize_customer()` |
| `GET` | `/api/customers/[id]/export` | — | `200 application/json` (download) | RGPD droit d'accès |
| `POST` | `/api/uploads/logo` | `multipart/form-data` | `200 { url: string }` | Upload vers Supabase Storage bucket `logos`, retourne URL publique |

### Pas de routes pour ces opérations (server actions à la place)

- Update profil merchant
- Création / update / désactivation programme fidélité
- Update couleurs / branding

→ Voir livrable 5.

---

## Livrable 5 — Server actions vs routes API : décisions

### Critères de décision

| Choisir **server action** si | Choisir **route API** si |
|---|---|
| Mutation simple déclenchée depuis le dashboard merchant authentifié | Besoin de retourner un binaire (`.pkpass`, fichier JSON export) |
| Side-effect = DB write + revalidation cache Next.js | Webhook entrant (signature à vérifier, body raw nécessaire) |
| Retour minimal (succès/erreur, valeur simple) | Appelé par un système externe (Apple, Stripe, Google ne peuvent pas appeler une server action) |
| Pas besoin de codes HTTP spécifiques | Appelé par un user non-authentifié (`/c/[slug]` qui inscrit un client) |
| | Besoin d'un endpoint public stable (Apple PassKit Web Service exige des paths précis) |
| | Besoin de rate-limiting fin par IP |

### Décisions concrètes

| Opération | Type | Justification |
|---|---|---|
| `updateMerchantProfile` | Server action | Mutation simple, user authentifié, juste un revalidate de `/dashboard/settings` |
| `createLoyaltyProgram` | Server action | Idem |
| `updateLoyaltyProgram` | Server action | Idem |
| `setProgramActive(boolean)` | Server action | Soft-toggle, pas de DELETE applicatif |
| Inscription commerçant (signup) | Route API (`/api/onboarding/checkout`) | Doit créer une session Stripe externe, retourner URL |
| Inscription client | Route API (`/api/customers/signup`) | Appelé par anon, doit retourner URL de pass (binaire URL ou Google Save URL) |
| Ajout tampon | Route API (`/api/stamps`) | Server action OK techniquement, mais on veut un endpoint stable qu'on pourra un jour exposer à des intégrations caisse externes. Anticipation acceptable. |
| Génération pass Apple/Google | Route API | Retourne binaire / JWT signé |
| Upload logo | Route API | Multipart form-data, plus simple en route API |
| Tous les webhooks | Route API | Pas le choix |
| Tous les callbacks Apple PassKit | Route API | Pas le choix |

### Anti-pattern à éviter

❌ **Ne pas mélanger** server action + route API qui font la même chose. Une opération = un seul point d'entrée.
❌ **Ne pas appeler de route API depuis une server action** (double hop inutile). Si tu as besoin de la même logique, extraire dans une fonction `lib/...` partagée.

---

## Livrable 6 — Stratégie certificats Apple

### Ce qu'il faut comprendre d'abord

Pour que `passkit-generator` puisse fabriquer un `.pkpass` valide, il a besoin de **3 fichiers cryptographiques** :

1. **Le certificat Pass Type ID** (`.p12` ou `.pem`) — propre à TON application. Contient une clé privée.
2. **Le certificat WWDR** (`AppleWWDRCAG3.pem`) — intermédiaire Apple, public, valable plusieurs années.
3. **Une passphrase** — protège la clé privée du `.p12`.

Ces 3 éléments **signent cryptographiquement** chaque pass pour qu'iOS accepte de l'installer. Sans signature valide, iOS refuse le pass.

### Process complet (one-shot setup)

#### Étape 1 — Compte Apple Developer

- S'inscrire : https://developer.apple.com/programs/
- **Coût : 99 USD / an** (renouvellement automatique).
- Validation peut prendre 24-48h.
- **Recommandation Arch :** compte au nom de Solal en tant qu'individu pour MVP. Si SAS Fidela créée plus tard, migrer en compte Organization (process Apple existant).

#### Étape 2 — Créer un Pass Type ID dans Apple Developer Console

- Aller : Certificates, Identifiers & Profiles → Identifiers → "+" → Pass Type IDs
- Identifier : `pass.fr.fidela.loyalty` (convention reverse-DNS, à fixer définitivement, **ne change plus jamais après**)
- Description : "Fidela Loyalty Card"

#### Étape 3 — Générer le CSR (Certificate Signing Request) sur Windows

⚠️ Solal est sur Windows, donc pas de Keychain Access. Solution : **OpenSSL via Git Bash ou WSL.**

```bash
# Dans Git Bash (livré avec Git for Windows)
openssl req -nopass -newkey rsa:2048 -keyout fidela-passkit.key -out fidela-passkit.csr
# Country: FR, State: Ile-de-France, Common Name: pass.fr.fidela.loyalty, Email: ton@email.fr
```

Sortie : `fidela-passkit.key` (clé privée) + `fidela-passkit.csr` (à uploader Apple).

#### Étape 4 — Récupérer le certificat signé Apple

- Apple Developer Console → ton Pass Type ID → "Create Certificate" → upload le `.csr` → télécharger `pass.cer` (DER format).

#### Étape 5 — Convertir en `.pem` exploitable par passkit-generator

```bash
# Convertir le .cer DER en .pem
openssl x509 -inform DER -outform PEM -in pass.cer -out fidela-passkit.pem

# Combiner clé privée + certificat en .pem unique avec passphrase
openssl pkcs12 -export -out fidela-passkit.p12 -inkey fidela-passkit.key -in fidela-passkit.pem
# Passphrase à définir et conserver précieusement
```

#### Étape 6 — Récupérer le WWDR intermediate

- Télécharger : https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer
- Convertir : `openssl x509 -inform DER -outform PEM -in AppleWWDRCAG3.cer -out wwdr.pem`

### Stockage

#### En local (dev)

```
fidela/
├── certificates/
│   ├── fidela-passkit.p12     ← jamais commit
│   ├── wwdr.pem               ← jamais commit (public mais cohérence)
│   └── README.md              ← instructions, lisible
├── .gitignore                 ← contient `certificates/*.p12` et `certificates/*.pem`
└── .env.local                 ← PASSKIT_PASSPHRASE=...
```

Le code `lib/wallets/apple.ts` lit les fichiers en local :

```typescript
const cert = readFileSync('certificates/fidela-passkit.p12');
```

#### En production (Vercel)

⚠️ Vercel n'a pas de filesystem persistant. Solution : **base64-encode les certificats** et les mettre en variables d'environnement.

```bash
# Pour chaque fichier
base64 -w 0 certificates/fidela-passkit.p12 > p12.b64
base64 -w 0 certificates/wwdr.pem > wwdr.b64
```

Variables Vercel à créer (Settings → Environment Variables, en mode "Sensitive") :

| Nom | Valeur |
|---|---|
| `APPLE_PASS_TYPE_ID` | `pass.fr.fidela.loyalty` |
| `APPLE_TEAM_ID` | trouvé dans Apple Developer Console |
| `APPLE_PASSKIT_P12_BASE64` | contenu de `p12.b64` |
| `APPLE_PASSKIT_WWDR_BASE64` | contenu de `wwdr.b64` |
| `APPLE_PASSKIT_PASSPHRASE` | la passphrase choisie étape 5 |

Le code `lib/wallets/apple.ts` détecte l'environnement :

```typescript
const cert = process.env.APPLE_PASSKIT_P12_BASE64
  ? Buffer.from(process.env.APPLE_PASSKIT_P12_BASE64, 'base64')
  : readFileSync('certificates/fidela-passkit.p12');
```

### Rotation

- Le certificat Pass Type ID est **valable 1 an** depuis sa création.
- **30 jours avant expiration** : refaire les étapes 3-5 (nouveau CSR, nouveau certificat).
- Remplacer le `.p12` en local + en variables Vercel.
- **Les passes déjà émis restent valides** (signature embarquée, l'expiration ne casse pas les passes existants, elle empêche juste d'en signer de nouveaux).
- **À mettre en agenda Solal :** alerte récurrente "Renouveler certif Apple Pass" 30 jours avant la date d'expiration. Sentry peut alerter aussi si une signature échoue.

### Erreur classique à éviter

❌ **Committer le `.p12` ou le `.key` sur Git.** Même en privé. Si compromis : Apple peut révoquer le certificat, et tout pass émis devient invalide → catastrophe utilisateur.
❌ **Mélanger passphrase et clé** dans le même fichier d'environnement. Séparer toujours.

---

## Livrable 7 — Flow détaillé du parcours client

### Vue séquentielle complète

```
[1] Client en boutique scanne le QR code Fidela imprimé
        │
        │ → URL: https://fidela.fr/c/boulangerie-dupont
        ▼
[2] Navigateur mobile charge la page /c/[slug]
        │
        │ Server Component: SELECT merchant + active loyalty_program
        │ filtré aux colonnes safe (branding, pas de PII)
        ▼
[3] Client voit page de branding avec :
        - logo, nom boutique, couleurs
        - "Rejoins le programme fidélité — X tampons = [récompense]"
        - formulaire : email OU téléphone + checkbox consentement RGPD
        - bouton "Recevoir ma carte de fidélité"
        │
        ▼
[4] Soumission formulaire → POST /api/customers/signup
        body: { slug, email?, phone?, consent: true, user_agent }
        │
        ▼
[5] Route API (service_role) exécute :
        a) Lookup merchant par slug
        b) Dedup customer : SELECT existant par (merchant_id, email/phone)
           - si existant non-anonymisé → réutilise customer.id
           - sinon → INSERT customer
        c) Génère serial_number aléatoire (32 chars) + auth_token (64 chars)
        d) INSERT customer_pass (current_stamps = 0)
        e) Détecte plateforme via user_agent :
             - iOS / iPadOS → branche Apple
             - autre → branche Google
        ▼
[6a] Branche APPLE :                  [6b] Branche GOOGLE :
   - lib/wallets/apple.ts             - lib/wallets/google.ts
   - charge cert + wwdr               - service account OAuth (JWT)
   - construit pass.json              - PUT objet loyaltyObject
     (logo, couleurs, current_stamps, - Google retourne object ID
      stamps_required, etc.)          - construit "save URL"
   - signe avec passkit-generator       (https://pay.google.com/gp/v/save/[jwt])
   - Stocke .pkpass sur               - retourne save URL au client
     Supabase Storage bucket "passes"
   - retourne URL au client
        │                                  │
        ▼                                  ▼
[7] Client mobile reçoit la réponse :
   iOS : navigateur télécharge .pkpass → iOS Wallet propose "Ajouter"
   Android : clic sur lien "Save URL" → Google Wallet propose "Ajouter"
        │
        ▼
[8] APRÈS AJOUT :
   iOS Wallet enregistre auprès de notre webService :
      POST /api/webhooks/apple-wallet/v1/devices/[deviceLib]/registrations/[passTypeId]/[serial]
      body: { pushToken }
      → INSERT apple_devices(device_library_identifier, customer_pass_id, push_token)
      → 201 Created
   Google : pas d'enregistrement device, l'update se fera par PATCH côté serveur
```

### Le pass est dans le Wallet — flow tampon

```
[A] Commerçant ouvre dashboard /dashboard/stamp, scanne QR du client OU saisit code court
        │ POST /api/stamps { serial_number }
        ▼
[B] Route API authenticated :
    - Résout pass_id depuis serial_number
    - supabase.rpc('add_stamp', { p_customer_pass_id: pass_id })
        │ → fonction add_stamp() exécute en atomique :
        │     - vérifie ownership merchant
        │     - vérifie last_stamp > 30 min
        │     - INSERT stamps
        │     - UPDATE customer_passes.current_stamps += 1
        │     - retourne new_count
        ▼
[C] Route API déclenche en background (Promise non awaitée OK ici) :
    - regenerate .pkpass avec new_count → upload Supabase Storage (overwrite)
    - APNs push : pour chaque apple_devices.push_token de ce pass,
        envoie payload vide (juste un wake-up) via apn lib
    - Google Wallet : PATCH loyaltyObject avec new loyaltyPoints.balance
        ▼
[D] Côté client (passif, automatique) :
    iOS : APNs réveille Wallet → Wallet appelle :
        GET /api/webhooks/apple-wallet/v1/passes/[passTypeId]/[serial]
        avec header Authorization: ApplePass <auth_token>
        → notre serveur sert le nouveau .pkpass
        → Wallet met à jour visuellement (animation "9/10 tampons")
    Android : Google push automatique au device, mise à jour visuelle
```

### Cas spécial : récompense débloquée

Quand `current_stamps == stamps_required` :
- Le pass affiche "Récompense disponible : [reward_description]"
- Bouton "Réclamer" visible dans le dashboard merchant
- Sur clic merchant → `POST /api/rewards/claim` :
  - INSERT `rewards_claimed`
  - UPDATE `customer_passes` SET `current_stamps = 0`, `total_rewards_claimed += 1`
  - Regénère le pass avec compteur à zéro
  - Push update

### Cas limite à gérer (signalé pour Bob)

1. **Email ET téléphone fournis** : on enregistre les deux, dedup sur l'un OU l'autre.
2. **Client refuse iOS Wallet une fois et revient plus tard** : route API doit pouvoir re-servir le .pkpass à la demande via un lien stocké dans email/SMS de confirmation. → Email de bienvenue avec le lien `pass_url`.
3. **Commerçant tamponne 2x dans la même session** : la fonction `add_stamp` renvoie 429 (anti-fraude 30 min), UI doit afficher message clair "Veuillez patienter 30 min".
4. **Apple devices désinstalle puis réinstalle le pass** : le device se réenregistre via le callback `POST .../registrations/...`. On UPSERT au lieu d'INSERT pour éviter erreur unique.
5. **Push APNs échoue** (token expiré) : on log Sentry, on DELETE l'apple_devices row. Le client réenregistrera au prochain ajout au Wallet.

---

## Validation attendue de Solal (paquet 2)

Avant que je passe au paquet 3, valider :

1. **Routes API** : la liste est-elle complète ? Tu vois un endpoint manquant ?
2. **Server actions vs routes API** : OK avec mes critères ? Tu préfères tout en routes API pour plus de cohérence (acceptable mais plus verbeux) ?
3. **Stratégie certifs Apple** : tu as compris le process ? Tu veux que je détaille un point ?
4. **Flow client** : ça correspond à ce que tu imaginais ? La distinction iOS/Android te va ?

Note : tu n'as **rien à exécuter** pour ce paquet (pas de SQL). Tout est de la spec.
