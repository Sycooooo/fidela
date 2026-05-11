# Architect Deliverables — Fidela

*Auteur : Arch — 2026-05-11*
*Source de référence : `ARCHITECTURE_BRIEF.md` (racine)*

Document vivant. Mis à jour à chaque paquet de livrables produit.

---

## Plan de livraison

| Paquet | Livrables (section 9 du brief) | Statut |
|---|---|---|
| **1** | 1. Schéma DDL · 2. Policies RLS · 3. Diagramme archi | Validé tacitement par Solal ("ça va, continue") |
| **2** | 4. Routes API · 5. Server actions vs API · 6. Certifs Apple · 7. Flow client | Validé tacitement par Solal ("ça me va, commit") |
| **3** | 8. Flow commerçant · 9. Stratégie tests · 10. Estimation complexité · 11. Risques · 12. Plan sprints | **À VALIDER par Solal** |

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

---

# Paquet 3 — Opérationnel : flow commerçant, tests, planning, risques

## Livrable 8 — Flow détaillé du parcours commerçant

### Vue d'ensemble en 4 phases

```
Phase 1 — DÉCOUVERTE       Phase 2 — ONBOARDING           Phase 3 — CONFIG            Phase 4 — QUOTIDIEN
  Landing → CTA             Signup → wizard → paiement     Branding + programme        Scan tampon récurrent
                                                                                          + claim récompense
```

### Phase 1 — Découverte (avant inscription)

```
[1] Visite https://fidela.fr depuis canal acquisition (Insta, démarchage terrain)
        │ Server Component : page landing (next/image, statique sauf hero CTA)
        ▼
[2] Voit pitch + démo en GIF + tarif (99€ setup + 19€/mois)
        │ CTA primaire : "Démarrer mon programme" → /signup
        │ CTA secondaire : "S'inscrire à la liste d'attente" → POST /api/waitlist
        ▼
[3] Click "Démarrer" → /signup
```

### Phase 2 — Onboarding (inscription + paiement)

```
[4] /signup — formulaire email + mot de passe
        │ Supabase Auth : signUp({ email, password })
        │ Email de vérification envoyé automatiquement par Supabase
        ▼
[5] Click lien email → /auth/callback → session active
        │ Server Component détecte qu'il n'y a pas encore de merchant lié
        │ → redirige /onboarding
        ▼
[6] /onboarding — wizard multi-étapes (state local React, pas de persist tant que pas payé)
        │ Étape 1 : nom boutique, type d'activité (enum), adresse, téléphone
        │ Étape 2 : upload logo → POST /api/uploads/logo (Supabase Storage bucket "logos")
        │ Étape 3 : config programme (nom, stamps_required, reward_description, couleurs)
        │ Étape 4 : choix slug (`/c/[slug]`) — vérif disponibilité côté serveur
        │ Étape 5 : preview du pass Apple ET Google (mock visuel, pas de génération réelle)
        │ Étape 6 : récap + bouton "Procéder au paiement"
        ▼
[7] Click "Procéder au paiement" → POST /api/onboarding/checkout
        │ body: { tous les champs du wizard }
        │ Server :
        │   - Validation Zod
        │   - Crée stripe customer
        │   - Crée Stripe Checkout session (setup_fee 99€ + subscription 19€/mois)
        │   - Stocke draft merchant en table "onboarding_drafts" (clé = user_id)
        │   - Retourne checkout_url
        ▼
[8] Redirige Stripe Checkout (site Stripe, pas Fidela)
        │ Client paie
        ▼
[9] Stripe redirige /onboarding/success?session_id=...
        │ Server vérifie session_id, mais NE crée PAS le merchant ici
        │ (la création se fait dans le webhook, source de vérité Stripe)
        │ → écran "Activation en cours" avec polling /api/onboarding/status
        ▼
[10] Stripe envoie webhook POST /api/webhooks/stripe : event = checkout.session.completed
        │ Server (service_role) :
        │   - Vérifie signature (OBLIGATOIRE)
        │   - Idempotence : check stripe event ID pas déjà traité
        │   - Lit onboarding_drafts par user_id
        │   - INSERT merchant (subscription_status = active)
        │   - INSERT loyalty_program associé
        │   - DELETE onboarding_drafts row
        │   - Renvoie 200
        ▼
[11] Polling côté client détecte merchant créé → redirige /dashboard
```

### Phase 3 — Configuration post-paiement (one-time)

```
[12] /dashboard — première visite
        │ Server Component charge merchant + loyalty_program + stats
        ▼
[13] Affichage onboarding cards :
        - Card 1 : "Imprimer votre QR code boutique" → /dashboard/qrcode
        - Card 2 : "Test du flow client" → ouvre /c/[slug] dans nouvel onglet
        - Card 3 : "Premier client à tamponner" → /dashboard/stamp
        ▼
[14] /dashboard/qrcode
        │ Génère QR code (lib `qrcode`) pointant vers https://fidela.fr/c/[slug]
        │ Bouton "Télécharger PDF" (jspdf) format A5 prêt à imprimer
        ▼
[15] Commerçant imprime, affiche en caisse
```

### Phase 4 — Quotidien (récurrent)

#### A. Ajouter un tampon

```
[16] Commerçant ouvre dashboard sur smartphone → /dashboard/stamp
        │ Active caméra via lib `@yudiel/react-qr-scanner`
        ▼
[17] Scan du QR pass client (apparait dans Wallet du client, le client le montre)
        │ Le QR contient l'URL https://fidela.fr/p/[serial] OU directement le serial
        │ → app extrait serial_number
        ▼
[18] Affichage écran de confirmation :
        - photo logo client ou initiales
        - "Jean D. (jean@...) — 7/10 tampons"
        - Bouton "Ajouter un tampon"
        ▼
[19] Click → POST /api/stamps { serial_number }
        │ Server : add_stamp() Postgres function (atomique, anti-fraude 30 min)
        │ Background : push update Apple + Google
        ▼
[20] Écran succès :
        - Animation "8/10"
        - Si current_stamps == stamps_required : bandeau "RÉCOMPENSE DISPONIBLE"
        - Bouton "Tamponner un autre client" → retour /dashboard/stamp
```

#### B. Saisie code court (fallback si scan QR ne marche pas)

```
[17bis] Tap "Saisir code à la main"
        │ Modal : input 6-8 chars
        │ Le code court est dérivé du serial_number (ex: 6 premiers chars en majuscule)
        ▼
        Continue [18] avec serial complet récupéré DB par préfixe
```

#### C. Réclamer une récompense

```
[21] Sur écran tampon : si current_stamps == stamps_required
        Bouton "Récompense utilisée — Reset compteur"
        ▼
[22] Click → POST /api/rewards/claim { pass_id }
        │ Server : INSERT rewards_claimed + UPDATE customer_passes SET current_stamps = 0
        │ Background : push update wallet
        ▼
[23] Écran confirmation "Récompense remise à [client]. Compteur à zéro."
```

#### D. Voir ses clients / stats

```
[24] /dashboard — liste clients (paginée si > 50)
        - Colonnes : nom (déduit email), tampons, dernière visite, récompenses utilisées
        - Filtres : actifs (last_visit_at < 30j), inactifs, récompense disponible
[25] /dashboard/stats — basique :
        - Nombre de clients inscrits
        - Nombre total de tampons distribués (cette semaine, ce mois, total)
        - Nombre de récompenses utilisées
        - Heatmap horaire si nice-to-have
```

### Cas spéciaux (à gérer pour Bob)

1. **Stripe webhook arrive en retard** (latence Stripe) : page success affiche "Activation en cours, ça peut prendre 1-2 min". Polling sur `/api/onboarding/status` toutes les 3s, timeout 60s avant de proposer support.
2. **Stripe webhook jamais reçu** (rare mais possible) : cron job quotidien `/api/cron/reconcile-stripe` qui liste les `onboarding_drafts` > 1h et les réconcilie via API Stripe. Cron Vercel (Hobby plan limite à 2 cron/jour, suffisant).
3. **Paiement échoué initial** : Stripe Checkout gère, redirige `/onboarding/cancel`. On garde le draft, on propose "Réessayer le paiement" qui re-crée une session.
4. **Email de vérification non cliqué** : Supabase ne crée pas de session. L'user revient via `/signup`, on détecte email déjà inscrit non-vérifié, on renvoie l'email.
5. **Slug déjà pris** : feedback temps réel dans le wizard (debounce 500ms), suggestion alternative.

---

## Livrable 9 — Stratégie de tests minimale

### Philosophie

Tu es solo, junior, claude-powered. **Pas de TDD obsessionnel.** Mais 3 zones où une erreur coûte de l'argent ou casse l'expérience à grande échelle. Ces 3 zones DOIVENT être testées.

Ailleurs : tests manuels suffisent, à structurer en checklists par feature.

### Outils

| Type | Outil | Pourquoi |
|---|---|---|
| Unitaires & intégration | **Vitest** | Intégration native Next 15, rapide, syntaxe Jest-like |
| End-to-end | **Playwright** | Standard de fait, gère iOS/Android emulation, dev tools intégrés |
| Tests DB | Vitest + Supabase JS client | Pointer sur projet `fidela-test` séparé |

### Les 3 briques à tester (priorité haute)

#### 1. Génération `.pkpass` (Apple)

`lib/wallets/apple.test.ts` :

```typescript
describe('generateApplePass', () => {
  test('génère un pkpass parseable', async () => {
    const buffer = await generateApplePass(mockPass);
    expect(buffer).toBeInstanceOf(Buffer);
    expect(buffer.length).toBeGreaterThan(1000);
  });

  test('inclut le bon serial_number', async () => {
    const buffer = await generateApplePass(mockPass);
    const json = extractPassJson(buffer); // unzip pkpass et lire pass.json
    expect(json.serialNumber).toBe(mockPass.serial_number);
    expect(json.authenticationToken).toBe(mockPass.auth_token);
  });

  test('couleurs hex correctement appliquées', async () => {
    const buffer = await generateApplePass({ ...mockPass, primary_color: '#FF0000' });
    const json = extractPassJson(buffer);
    expect(json.backgroundColor).toBe('rgb(255, 0, 0)');
  });
});
```

+ test manuel E2E une fois par sprint : générer un pass réel, l'envoyer sur un iPhone, vérifier qu'il s'installe et s'ouvre.

#### 2. Webhook Stripe

`app/api/webhooks/stripe/route.test.ts` :

```typescript
describe('POST /api/webhooks/stripe', () => {
  test('rejette 400 si signature manquante', async () => {
    const res = await POST(makeRequest({ body: '{}' }));
    expect(res.status).toBe(400);
  });

  test('rejette 400 si signature invalide', async () => {
    const res = await POST(makeRequest({
      body: '{}',
      headers: { 'stripe-signature': 'invalide' }
    }));
    expect(res.status).toBe(400);
  });

  test('checkout.session.completed → crée merchant', async () => {
    const event = makeStripeEvent('checkout.session.completed', { /* ... */ });
    const res = await POST(makeRequest({
      body: JSON.stringify(event),
      headers: { 'stripe-signature': signEvent(event) }
    }));
    expect(res.status).toBe(200);
    const merchant = await supabase.from('merchants').select().eq('stripe_customer_id', event.data.object.customer);
    expect(merchant.data).toHaveLength(1);
    expect(merchant.data[0].subscription_status).toBe('active');
  });

  test('idempotence : 2 webhooks identiques = 1 seul merchant', async () => {
    // ...envoie 2x → vérifie 1 seule ligne
  });

  test('invoice.payment_failed → passe en past_due', async () => { /* ... */ });
});
```

#### 3. Anti-fraude `add_stamp`

`db/tests/add_stamp.test.sql` (ou Vitest qui appelle .rpc) :

```typescript
describe('add_stamp()', () => {
  test('ajoute un tampon si pass valide et > 30 min', async () => {
    const { data, error } = await supabase.rpc('add_stamp', { p_customer_pass_id: pass.id });
    expect(error).toBeNull();
    expect(data).toBe(1);
  });

  test('rejette si dernier tampon < 30 min', async () => {
    await supabase.rpc('add_stamp', { p_customer_pass_id: pass.id });
    const { error } = await supabase.rpc('add_stamp', { p_customer_pass_id: pass.id });
    expect(error.message).toContain('30 minutes');
  });

  test('rejette si caller ne possède pas le merchant', async () => {
    await supabaseAsOtherMerchant.rpc('add_stamp', { p_customer_pass_id: pass.id });
    expect(error.code).toBe('42501');
  });

  test('atomique sous race condition', async () => {
    // 10 appels concurrents → 1 seul succès, 9 erreurs
    const promises = Array.from({ length: 10 }, () =>
      supabase.rpc('add_stamp', { p_customer_pass_id: pass.id })
    );
    const results = await Promise.allSettled(promises);
    const successes = results.filter(r => r.status === 'fulfilled' && !r.value.error);
    expect(successes).toHaveLength(1);
  });
});
```

### 2 tests E2E Playwright (priorité haute)

#### E2E-1 — Inscription commerçant complète

```typescript
test('un commerçant peut créer son compte, payer et accéder au dashboard', async ({ page }) => {
  await page.goto('/');
  await page.click('text=Démarrer mon programme');
  // ... fill signup, mock Stripe test mode, complete checkout
  await expect(page).toHaveURL(/\/dashboard/);
  await expect(page.locator('h1')).toContainText('Bienvenue');
});
```

#### E2E-2 — Parcours client (inscription + ajout pass)

```typescript
test('un client peut scanner le QR et recevoir son pass', async ({ page }) => {
  await page.goto('/c/test-boulangerie');
  await page.fill('[name=email]', 'client@test.fr');
  await page.check('[name=consent]');
  await page.click('text=Recevoir ma carte');
  // vérifie qu'on récupère un lien pkpass ou un lien Google Wallet
  await expect(page.locator('a:has-text("Ajouter à")')).toBeVisible();
});
```

### Ce qu'on ne teste PAS (volontaire)

- UI dashboard (composants shadcn/ui standards, peu de logique)
- Server actions simples (updateMerchantProfile, etc.) : tests manuels au moment du build
- Pages publiques statiques (landing, conditions, politique de confidentialité)
- Génération QR code (lib `qrcode` éprouvée)
- Upload logo (Supabase Storage géré)

### Tests manuels structurés

`docs/test-checklists/` :
- `sprint-1-auth.md` — checklist signup, login, logout, reset password
- `sprint-3-apple-wallet.md` — checklist génération sur 3 iPhones différents (iOS 16, 17, 18)
- `sprint-6-tampon.md` — checklist scan QR, saisie code, anti-fraude UI, claim récompense

À cocher manuellement avant chaque déploiement production.

### Couverture cible

- **Code testé automatiquement : ~30%** (les briques critiques uniquement)
- **Couverture des risques business : 100%** (tout ce qui touche fric ou DB integrity est testé)

Couvre l'essentiel sans noyer dans la maintenance de tests.

---

## Livrable 10 — Estimation complexité par sprint

### Méthode

Pour chaque sprint, je découpe en sous-tâches granulaires et j'estime en **jours-homme pour Solal en mode claude-powered**. Hypothèses :
- 6h de focus dev par jour (le reste : interviews terrain, démarchage, admin)
- Claude écrit le code sous direction Bob, mais Solal doit comprendre, tester, débugger
- 1 jour de buffer par sprint pour les surprises

### Détail

| Sprint | Brief original | Mon estimation | Δ |
|---|---|---|---|
| **0 (setup)** | non prévu | **5j** | +5j |
| 1 (Landing + auth + waitlist) | 10j | **10j** | = |
| 2 (Dashboard config programme) | 10j | **10j** | = |
| 3 (Apple Wallet) | 15j | **20j** | +5j |
| 4 (Google Wallet) | 10j | **10j** | = |
| 5 (Parcours client `/c/[slug]`) | 10j | **10j** | = |
| 6 (Système tampon + push) | 10j | **15j** | +5j |
| **Total** | **65j (13 sem)** | **80j (16 sem)** | **+15j** |

### Justification des amendements

#### Sprint 0 — Setup (5j) — AJOUT

Pas dans le brief mais indispensable. Compte Apple Developer prend 24-48h de validation Apple, c'est bloquant pour le Sprint 3. À démarrer dès Sprint 1.

Contenu :
- Créer projets Supabase dev + prod
- Configurer Vercel + variables env
- Créer compte Apple Developer ($99 + délai validation)
- Créer compte Stripe + activation paiement
- Créer Pass Type ID + générer certificats (livrable 6)
- Setup repo Next 15 + ESLint + Prettier + Tailwind + shadcn init
- Premier déploiement preview vide qui marche
- Sentry init

#### Sprint 3 — Apple Wallet (+5j, total 20j)

Le brief sous-estime. La complexité Apple :
- Comprendre la spec PassKit (pass.json, manifest, signature)
- Maîtriser `passkit-generator` (peu doc'é)
- Implémenter les 5 callbacks Web Service Protocol
- Setup APNs (envoi push)
- Tester sur vrais iPhones (au moins 2-3 modèles différents)
- Debugging signature (la moitié du temps perdu en certif issues)

Sprint le plus risqué. **Si je devais conseiller un seul sprint à étaler, c'est celui-ci.**

#### Sprint 6 — Système tampon + push (+5j, total 15j)

Brief sous-estime aussi. Inclus :
- UI scan QR + saisie code (testée sur smartphone)
- API stamps + claim récompense
- Push update Apple (APNs réel, pas mock)
- Push update Google (PATCH objet, gestion erreurs API)
- Anti-fraude UI feedback
- Tests bout-en-bout flow complet

### Total : ~16 semaines (4 mois) de dev MVP

Pour un junior claude-powered à 6h/jour. Ajoute 4-8 semaines pour la phase 0 (interviews terrain, validation prix) et les imprévus = lancement réaliste **5-6 mois après le démarrage du code**.

---

## Livrable 11 — Risques techniques + mitigation

### Top 12 risques (du plus probable/grave au moins)

| # | Risque | Probabilité | Gravité | Mitigation |
|---|---|---|---|---|
| **R1** | **Certificat Apple expiré non renouvelé** : plus de nouveau pass possible | Haute (oubli) | Critique | Calendar alert 30j avant. Cron `/api/cron/check-cert-expiry` qui ping Slack/email à J-30, J-7, J-1. |
| **R2** | **Webhook Stripe manqué** : subscription payée mais non activée chez nous | Moyenne | Haute | Idempotence (table `stripe_events_processed`) + cron quotidien `reconcile-stripe` qui repère les paiements sans merchant. |
| **R3** | **Bug dans génération `.pkpass`** : tous les passes émis cassés | Faible | Critique | Tests automatisés (livrable 9). Feature flag pour basculer sur version précédente en cas de regression. Monitoring Sentry sur lib wallets. |
| **R4** | **APNs push tokens expirés en masse** : updates pass ne se propagent plus | Moyenne | Moyenne | Cleanup automatique sur échec APNs (DELETE row apple_devices). User réenregistrera son device au prochain ajout au Wallet. |
| **R5** | **Vercel function timeout** sur génération pass (>10s) | Faible | Haute | Optimiser passkit-generator (cache cert loading). Si vraiment besoin, passer au plan Pro Vercel (60s timeout). Budget monitor : alerte si > 5s. |
| **R6** | **Supabase free tier dépassé** (DB size, MAU) | Haute (succès) | Moyenne | Monitoring quota via Supabase dashboard. Upgrade Pro plan dès 30+ merchants. |
| **R7** | **Race condition tampon** : 2 tampons en parallèle bypass anti-fraude | Faible (déjà mitigée) | Haute | **Déjà mitigé par la fonction `add_stamp()` atomique en DB.** Test sous charge dans Sprint 6. |
| **R8** | **RGPD non conforme** : amende CNIL | Faible | Critique | Registre des traitements (Notion), droits accès + effacement implémentés, hébergement Frankfurt, consentement explicite. Faire relire par juriste avant lancement public. |
| **R9** | **Apple Developer account suspendu** (ToS violation accidentelle) | Très faible | Critique | MFA obligatoire sur compte. Lire les guidelines Wallet attentivement. Ne pas spammer push. Backup : compte secondaire d'urgence. |
| **R10** | **Vol/exposition certificat Apple `.p12`** | Faible | Critique | `.p12` jamais commité (gitignore). Variables Vercel marked "Sensitive". Rotation immédiate si suspicion. |
| **R11** | **Frankfurt outage Supabase** : app down quelques heures | Très faible | Haute | Pas de plan B en MVP (acceptable au volume). Statuspage Supabase suivi. Communication user via status page Fidela (à créer Sprint 1). |
| **R12** | **Google Wallet API rate limit** : si beaucoup de tampons en simultané | Faible | Moyenne | Queue async (par exemple Vercel KV ou simple debounce DB). Pas critique en MVP volume. |

### Risques business adjacents (rappel, hors scope archi mais à connaître)

- **Personne n'utilise** : MVP doit valider la traction avant les 6 sprints. → Phase 0 interviews terrain.
- **Stripe ferme le compte** (faux flag fraude) : compte test → vrai dès que possible, paperasse SAS prête.
- **Concurrent lance plus vite** : pas mon problème, c'est marché compétitif.

---

## Livrable 12 — Plan de découpage en sprints (amendé)

### Plan final 7 sprints (16 semaines = 4 mois)

#### Sprint 0 — Setup (semaine 1) — NOUVEAU

**Objectif :** environnement prêt à coder.

**Done quand :**
- [ ] Repo Next 15 init, déployé Vercel preview (page vide qui marche)
- [ ] Supabase dev + prod créés, `schema.sql` + `rls.sql` appliqués sur dev
- [ ] Compte Apple Developer validé, Pass Type ID créé, certificats générés et stockés local + Vercel
- [ ] Compte Stripe activé en mode test
- [ ] Sentry projet créé, DSN en env var
- [ ] ESLint + Prettier + Tailwind + shadcn init
- [ ] Variables env documentées dans `.env.example`

**Critères deploy :** Vercel preview accessible, healthcheck `/api/health` OK.

#### Sprint 1 — Landing + auth + waitlist (semaines 2-3)

**Objectif :** un visiteur peut s'inscrire à la waitlist OU démarrer un compte commerçant et se connecter.

**Done quand :**
- [ ] Landing publique `/` avec pitch + 2 CTAs
- [ ] Formulaire waitlist `/api/waitlist` fonctionnel
- [ ] Signup commerçant `/signup` avec Supabase Auth (email + password)
- [ ] Email de vérification reçu (Resend ou Postmark configuré)
- [ ] Login / logout fonctionnels
- [ ] Reset password fonctionnel
- [ ] Layout dashboard `/dashboard` (vide mais accessible une fois loggué)

**Critères deploy :** déploiement production, landing + waitlist live. Signup commerçant accessible mais pas annoncé publiquement.

#### Sprint 2 — Onboarding + config programme (semaines 4-5)

**Objectif :** un commerçant peut s'onboarder, payer, configurer son programme et imprimer son QR code.

**Done quand :**
- [ ] Wizard onboarding 6 étapes (infos boutique → logo → programme → slug → preview → paiement)
- [ ] Upload logo via `/api/uploads/logo` → Supabase Storage
- [ ] Stripe Checkout intégré (mode test) — 99€ setup + 19€/mois
- [ ] Webhook `/api/webhooks/stripe` traite checkout.session.completed
- [ ] Idempotence sur webhook (table `stripe_events_processed`)
- [ ] Dashboard `/dashboard` affiche infos merchant + programme + QR code téléchargeable PDF
- [ ] Server actions : updateMerchantProfile, updateLoyaltyProgram

**Critères deploy :** un beta-testeur peut payer (mode test) et accéder à son dashboard.

#### Sprint 3 — Apple Wallet (semaines 6-9, **4 semaines**)

**Objectif :** un pass Apple Wallet est généré, signé, et installable sur un iPhone réel.

**Done quand :**
- [ ] `lib/wallets/apple.ts` génère un `.pkpass` valide
- [ ] Tests unitaires Vitest passent (livrable 9 § 1)
- [ ] Route `GET /api/passes/apple/[serial]` sert le pass
- [ ] 5 callbacks PassKit Web Service Protocol implémentés
- [ ] APNs (Apple Push Notification) setup côté serveur
- [ ] Test E2E manuel : générer un pass, l'envoyer par email, l'ouvrir sur iPhone, vérifier qu'il s'installe et reste à jour quand on push une modif
- [ ] Documentation interne : comment renouveler le certificat

**Critères deploy :** pass Apple installable sur iOS 16, 17, 18.

#### Sprint 4 — Google Wallet (semaines 10-11)

**Objectif :** un pass Google Wallet est généré et installable sur Android.

**Done quand :**
- [ ] `lib/wallets/google.ts` crée un loyaltyObject via API REST
- [ ] Service account Google + JWT auth en place
- [ ] Route `GET /api/passes/google/[serial]` retourne save URL signée
- [ ] Test sur Android réel (au moins 2 versions)
- [ ] Mise à jour pass via PATCH loyaltyObject fonctionne

**Critères deploy :** pass Google installable sur Android 12+.

#### Sprint 5 — Parcours client `/c/[slug]` (semaines 12-13)

**Objectif :** un client peut scanner le QR, s'inscrire, recevoir son pass dans son Wallet.

**Done quand :**
- [ ] Page publique `/c/[slug]` avec branding merchant
- [ ] Détection iOS/Android via User-Agent
- [ ] Formulaire inscription (email OU phone) avec consentement RGPD
- [ ] Route `/api/customers/signup` : dedup, INSERT customer + pass, génère wallet
- [ ] Email de bienvenue avec lien de récupération du pass
- [ ] Test E2E Playwright passe (livrable 9 § E2E-2)
- [ ] RGPD : page politique de confidentialité, route `/api/customers/[id]/export`

**Critères deploy :** un client peut scanner et avoir son pass dans son Wallet en moins de 30 secondes.

#### Sprint 6 — Tampon + push update (semaines 14-16, **3 semaines**)

**Objectif :** un commerçant peut tamponner un client depuis son smartphone, et le pass se met à jour automatiquement.

**Done quand :**
- [ ] `/dashboard/stamp` : caméra scan QR pass + fallback saisie code
- [ ] Route `/api/stamps` utilise `add_stamp()` Postgres function
- [ ] Push Apple APNs déclenché → pass iOS mis à jour
- [ ] PATCH Google Wallet → pass Android mis à jour
- [ ] Route `/api/rewards/claim` fonctionnelle
- [ ] UI feedback anti-fraude 30 min (toast clair)
- [ ] Tests automatisés `add_stamp` passent (livrable 9 § 3)
- [ ] Test E2E manuel : tamponner depuis iPhone, le pass se met à jour côté client en < 5s
- [ ] Test charge basique (10 tampons concurrents → 1 seul ajouté)

**Critères deploy :** MVP complet, prêt pour les 10 premiers commerçants pilotes.

### Recommandations transversales

1. **Démarrer Sprint 0 EN PARALLÈLE de la Phase 0 interviews terrain.** Le compte Apple Developer prend 24-48h, profite de ce délai pour valider le pricing.
2. **Pas de production avant Sprint 5 fini.** Avant ça, déploiements preview Vercel uniquement, beta-testeurs invités à la main.
3. **Documenter au fur et à mesure** dans `docs/decisions/` (ADR — Architecture Decision Records). Chaque arbitrage non-trivial = 1 fichier MD. Future-Solal te remerciera.
4. **Démo bi-hebdomadaire à un mentor / pair** pendant les 4 mois. Force à montrer du concret, détecte les dérives tôt.
5. **Buffer 20% sur le total** si phase imprévus → cible **20 semaines (5 mois) de zéro à MVP livrable**.

---

## Validation attendue de Solal (paquet 3)

Avant que Bob commence à coder le Sprint 0, valider :

1. **Flow commerçant** : la séquence Phase 1-4 correspond à ta vision UX ?
2. **Stratégie tests** : OK avec 30% de couverture auto focus sur les 3 zones critiques ?
3. **Estimation 16 semaines vs 13 du brief initial** : tu es prêt à étaler ? Ou tu veux garder 13 semaines et accepter le risque d'overrun ?
4. **Risques** : il y en a un que je n'ai pas vu ?
5. **Plan sprints** : OK avec l'ajout du Sprint 0 et l'extension Sprint 3 (Apple) ?

Une fois ces 5 points validés → **fin des livrables architecte**. Prochaine étape : Arch écrit le brief pour Bob de la Step 1 (= Sprint 0).
