# Build Log
*Owned by Architect. Updated by Builder after each step.*

---

## Current Status

**Active step:** Pré-Step 0 — Production des 12 livrables architecte (section 9 de ARCHITECTURE_BRIEF.md)
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
