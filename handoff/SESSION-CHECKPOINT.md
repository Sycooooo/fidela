# Session Checkpoint — 2026-05-11

*Read this before reading anything else. If it covers current state, skip BUILD-LOG.*

---

## Où on s'est arrêté

Arch a livré le **paquet 1 ET le paquet 2** des livrables architecte.

- Paquet 1 (livrables 1-3) : schéma DDL, RLS, diagramme archi → validé tacitement ("ça va, continue")
- Paquet 2 (livrables 4-7) : routes API, server actions vs API, certifs Apple, flow client → **en attente validation Solal**

**Tout dans `handoff/ARCHITECT-DELIVERABLES.md`** + SQL exécutable dans `db/schema.sql` et `db/rls.sql`.

**Prochaine action attendue :** validation du paquet 2 par Solal, puis paquet 3 (livrables 8-12 : flow commerçant, tests, estimation complexité, risques, plan sprints).

---

## Décisions prises cette session

### Méta
- Format mixte (MD + SQL extrait)
- Livraison par paquets (1-3, 4-7, 8-12)
- Fondations exhaustives, exécution focus Sprint 1

### Paquet 1
- Pas de table users séparée des merchants (multi-user hors scope MVP)
- Soft-delete hybride : `deleted_at` sur merchants/passes, anonymisation customers, immutable stamps/rewards
- Index posés sur serial_number, slug, customers (merchant_id, email/phone), stamps (pass_id, created_at DESC)
- Ajout `merchant_id` direct sur `customers` (manque dans le schéma initial)
- Ajout `auth_token` sur `customer_passes` (exigé Apple PassKit Web Service)
- Ajout table `apple_devices` (callbacks PassKit registration)
- Anti-fraude tampon en fonction Postgres `add_stamp()` (atomique, security definer)
- Email en `citext`
- Pas de couche service/repository entre routes et Supabase

### Paquet 2
- Routes Apple PassKit Web Service : 5 endpoints aux paths imposés par Apple
- /api/stamps en route API (anticipation intégrations caisse futures)
- Server actions pour mutations dashboard simples ; routes API pour binaires/webhooks/anon/externes
- Certifs Apple : OpenSSL via Git Bash sur Windows, /certificates en local, base64 env vars sur Vercel
- Pass Type ID : `pass.fr.fidela.loyalty` (à fixer définitivement)
- Rotation cert Apple : alerte 30j avant expiration

---

## Encore ouvert

Validation Solal sur le paquet 2 :
1. Liste des routes API complète ?
2. Critères server action / route API OK ?
3. Process certifs Apple compris ? Besoin de détailler un point ?
4. Flow client iOS/Android cohérent ?

Note annexe : la vérif version Three Man Team contre GitHub a timeout — comparaison `VERSION` local (v1.2.3) vs remote impossible. Pas bloquant.

---

## Resume prompt

Copier/coller pour reprendre :

---

Tu es Arch sur Fidela.
Lis `handoff/SESSION-CHECKPOINT.md`, puis `ARCHITECT.md`.
Confirme où on s'est arrêté et la prochaine action. Puis attends.

---
