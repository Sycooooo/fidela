# Build Log
*Owned by Architect. Updated by Builder after each step.*

---

## Current Status

**Active step:** Pré-Step 0 — Production des 12 livrables architecte (section 9 de ARCHITECTURE_BRIEF.md)
**Paquet en cours :** Paquet 2 (livrables 4-7) — LIVRÉ, attente validation Solal
**Paquets livrés :** 1 (validation tacite "ça va, continue"), 2 (à valider)
**Last cleared:** —
**Pending deploy:** NO

---

## Step History

### Setup — Three Man Team initialisé sur le projet Fidela — COMPLETE
*Date: 2026-05-11*

Files in place:
- `ARCHITECTURE_BRIEF.md` — brief complet du projet (v1.0)
- `CLAUDE.md` — racine, point d'entrée session
- `ARCHITECT.md`, `BUILDER.md`, `REVIEWER.md` — rôles (Arch / Bob / Richard, noms par défaut conservés)
- `handoff/` — fichiers de communication entre rôles
- `.claude/skills/token-optimization.md` — règles tokens
- `.claude/skills/three-man-team/` — skill source

Decisions made:
- Noms d'équipe : Arch, Bob, Richard (défauts conservés)
- RTK : skip (Solal est sur Windows, RTK = macOS/Linux)
- Modèles par agent : pas de préférence — par défaut tout tourne sur le modèle actif de la session
- Le brief Fidela est la source de vérité long terme ; le BUILD-LOG suit l'exécution

Reviewer findings: —
Deploy: N/A (setup environnement, pas de code)

---

### Pré-Step 0 Paquet 1 — Livrables 1-3 (schéma DDL, RLS, diagramme archi) — LIVRÉ, en attente validation
*Date: 2026-05-11*

Files produced:
- `db/schema.sql` — DDL Supabase exécutable (tables, ENUMs, triggers updated_at, fonctions `add_stamp` et `anonymize_customer`)
- `db/rls.sql` — Policies RLS pour les 8 tables, modèle 3-rôles anon/authenticated/service_role
- `handoff/ARCHITECT-DELIVERABLES.md` — Document de synthèse : critique du schéma, diagramme archi ASCII, décisions

Decisions made (paquet 1) :
- Q1 brief sec.6 : pas de table users séparée (multi-user hors scope MVP)
- Q2 brief sec.6 : soft-delete (merchants, customer_passes) + anonymisation (customers) + historique immutable (stamps, rewards_claimed)
- Q3 brief sec.6 : index sur serial_number UNIQUE, slug merchant UNIQUE, customers (merchant_id, email/phone), stamps (pass_id, created_at DESC)
- Ajout `merchant_id` direct sur `customers` (le brief disait dedup par (email, phone, merchant_id) mais la table n'avait pas le FK)
- Ajout `auth_token` sur `customer_passes` (exigé par Apple PassKit Web Service)
- Ajout table `apple_devices` (callbacks d'enregistrement device PassKit)
- Anti-fraude 30 min : fonction SQL `add_stamp(pass_id)` security definer, atomique, à appeler depuis les routes API
- `email` en `citext` (case-insensitive), pas `text`
- Couleurs hex et slug merchant validés par CHECK regex
- Pas de table `merchants_settings` séparée, pas de couche repository/service entre routes API et Supabase

Reviewer findings: — (revue par Richard prévue après validation Solal)
Deploy: N/A (production des livrables architecte, pas encore de code applicatif)

---

### Pré-Step 0 Paquet 2 — Livrables 4-7 (routes API, server actions, certifs Apple, flow client) — LIVRÉ, en attente validation
*Date: 2026-05-11*

Files produced:
- `handoff/ARCHITECT-DELIVERABLES.md` — section "Paquet 2" ajoutée

Decisions made (paquet 2) :
- Liste complète des routes API : publiques (anon), authenticated merchant, callbacks Apple PassKit Web Service (5 endpoints imposés par spec Apple), webhook Stripe
- Critères server action vs route API : server action pour mutations dashboard auth simples, route API pour binaires/webhooks/anon/externes/Apple PassKit
- /api/stamps en route API plutôt que server action (anticipation intégrations caisse externes futures)
- Stratégie certifs Apple : OpenSSL Git Bash sur Windows (pas de Keychain Mac), stockage local en /certificates + .env.local, prod Vercel en base64 dans env vars
- Rotation certificat Apple : 1 an, alerte 30j avant expiration
- Pass Type ID retenu : `pass.fr.fidela.loyalty` (à fixer définitivement)
- Flow client iOS/Android documenté avec séquence d'appels API et cas limites

Cas limites identifiés pour Bob :
- Dedup email/phone à l'inscription
- Email de bienvenue contenant pass_url pour récupération ultérieure
- UPSERT (pas INSERT) sur apple_devices pour gérer réinstallation pass
- Cleanup automatique des push_token Apple expirés (delete sur échec APNs)

Reviewer findings: — (revue Richard prévue après validation Solal)
Deploy: N/A

---

## Known Gaps
*Logged here instead of fixed. Addressed in a future step.*

— (aucun pour l'instant)

---

## Architecture Decisions
*Locked decisions that cannot be changed without breaking the system.*

- **2026-05-11** — Stack verrouillée par le Project Owner : Next.js 15 App Router + TS strict, Supabase Frankfurt, Vercel, Stripe, `passkit-generator` Apple Wallet, Google Wallet REST. Pas d'alternative à proposer.
- **2026-05-11** — Hébergement DB en UE (Frankfurt) imposé par RGPD. Non négociable.
- **2026-05-11** — RLS Supabase activé sur 100% des tables, sans exception.
- **2026-05-11** — `service_role_key` côté serveur uniquement.
- **2026-05-11** — Anti-fraude tampon : max 1 tampon par client/commerçant / 30 min, à enforcer côté serveur.
- **2026-05-11** — Vérification signature webhooks Stripe obligatoire.
