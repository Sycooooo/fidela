@.claude/skills/token-optimization.md

## Project

**Fidela** — SaaS B2B de cartes de fidélité digitales intégrées dans Apple Wallet et Google Wallet pour petits commerçants français. Zéro app consommateur, inscription en 30 secondes via QR code.

Stade : pré-MVP, équipe solo claude-powered (Solal, CEO + référent tech, niveau junior).

Référence technique exhaustive : `ARCHITECTURE_BRIEF.md` à la racine. À lire en début de session par tout agent qui travaille sur l'architecture ou le code.

Stack imposée (non négociable) : Next.js 15 App Router + TypeScript strict, Supabase (PostgreSQL + Auth + Storage, région Frankfurt), Tailwind + shadcn/ui, Vercel, Stripe, `passkit-generator` (Apple Wallet), Google Wallet REST API, Sentry, Resend/Postmark.

## Three Man Team

Available agents: Arch (Architect), Bob (Builder), Richard (Reviewer).

Project Owner : Solal. Toutes les sessions démarrent par charger le rôle adéquat depuis `ARCHITECT.md`, `BUILDER.md`, ou `REVIEWER.md`, puis lire `handoff/SESSION-CHECKPOINT.md` ou `handoff/BUILD-LOG.md`.
