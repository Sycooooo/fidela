# Session Checkpoint — 2026-05-11

*Read this before reading anything else. If it covers current state, skip BUILD-LOG.*

---

## Où on s'est arrêté

**Arch a livré les 12 livrables architecte (section 9 du brief)** — phase architecture complète.

- Paquet 1 (livrables 1-3) : schéma DDL, RLS, diagramme archi → validé
- Paquet 2 (livrables 4-7) : routes API, server actions vs API, certifs Apple, flow client → validé + commit + push (commit `424f4db`)
- Paquet 3 (livrables 8-12) : flow commerçant, stratégie tests, estimation complexité, risques, plan sprints → **en attente validation Solal**

**Tout dans `handoff/ARCHITECT-DELIVERABLES.md`** (~1100 lignes au total) + SQL exécutable dans `db/schema.sql` et `db/rls.sql`.

**Prochaine étape une fois paquet 3 validé :** Arch écrit le brief Bob pour la **Step 1 = Sprint 0 (setup environnement)**.

---

## Décisions prises cette session

### Méta
- Format mixte (MD + SQL extrait)
- Livraison par paquets (1-3, 4-7, 8-12)

### Paquet 1 (schéma, RLS, archi)
- Pas de table users séparée des merchants (multi-user hors scope MVP)
- Soft-delete hybride : `deleted_at` (merchants, passes), anonymisation (customers), immutable (stamps, rewards)
- Ajout `merchant_id` sur `customers`, `auth_token` sur `customer_passes`, table `apple_devices`
- Anti-fraude tampon en fonction Postgres atomique `add_stamp()`
- Email `citext`
- Pas de couche service/repository

### Paquet 2 (routes API, certifs, flow client)
- Routes Apple PassKit Web Service : 5 endpoints aux paths imposés Apple
- /api/stamps en route API (anticipation intégrations externes)
- Server actions pour mutations dashboard, routes API pour binaires/webhooks/anon/externes
- Certifs Apple : OpenSSL Git Bash sur Windows, /certificates local, base64 env vars sur Vercel
- Pass Type ID : `pass.fr.fidela.loyalty`
- Rotation cert Apple : alerte 30j avant expiration

### Paquet 3 (commerçant, tests, planning, risques)
- Création merchant via webhook Stripe (idempotence) + cron reconcile-stripe quotidien
- Table `onboarding_drafts` à ajouter au schéma plus tard (Sprint 2)
- Stratégie tests : Vitest + Playwright, 30% couverture auto, focus 3 briques critiques
- Estimation amendée : **16 semaines** (vs 13 brief) avec ajout Sprint 0 + extension Sprint 3 Apple (+5j) + Sprint 6 tampon (+5j)
- 12 risques identifiés, top 3 : certif Apple expiré / webhook Stripe manqué / bug gen pkpass
- Plan final 7 sprints (Sprint 0 à 6) avec critères Done

---

## Encore ouvert

Validation Solal sur le paquet 3 :
1. Flow commerçant (Phase 1-4) cohérent ?
2. Stratégie tests OK (30% couverture auto, focus 3 briques critiques) ?
3. Estimation 16 semaines OK (vs 13 du brief original) ?
4. Risques : tu en vois un que j'ai manqué ?
5. Plan sprints OK avec Sprint 0 + Sprint 3 étendu ?

Une fois validé → fin des livrables architecte → Arch attaque le brief Step 1 (Sprint 0).

Note annexe : la vérif version Three Man Team contre GitHub a timeout — comparaison `VERSION` local (v1.2.3) vs remote impossible. Pas bloquant.

---

## Resume prompt

Copier/coller pour reprendre :

---

Tu es Arch sur Fidela.
Lis `handoff/SESSION-CHECKPOINT.md`, puis `ARCHITECT.md`.
Confirme où on s'est arrêté et la prochaine action. Puis attends.

---
