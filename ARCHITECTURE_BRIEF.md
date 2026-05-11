# Brief Architecte — Projet Fidela

> **Document de référence** à transmettre à toute session Claude (ou consultant technique) chargée de définir l'architecture du projet Fidela avant le démarrage du développement.
>
> **Dernière mise à jour** : 2026-05-11
> **Auteur** : Solal (CEO & référent technique)
> **Stade projet** : pré-MVP, démarrage Phase 0

---

## 1. Identité du projet

**Nom du projet** : Fidela

**One-liner** : SaaS B2B qui permet à des petits commerçants français de créer des cartes de fidélité digitales intégrées nativement dans Apple Wallet et Google Wallet, sans aucune app à télécharger côté client final.

**Stade actuel** : pré-MVP, équipe de 2-3 fondateurs, budget initial <5 000€, lancement prévu Q4 2026.

**Positionnement** : « zéro friction » — installation commerçant en 10 minutes, inscription client en 30 secondes via scan QR, aucune app consommateur.

---

## 2. Contexte business

### Cible utilisateur primaire (commerçant payant)

Petits commerçants indépendants français — boulangeries, coiffeurs, restaurants, fleuristes, cafés, instituts de beauté. 1-3 points de vente, gérés directement par le propriétaire. Faible appétence techno, mobile-first (utilisent leur smartphone perso pour tout).

### Cible utilisateur secondaire (client final, non payant)

Le client du commerçant. Tout adulte avec un smartphone iOS ou Android. Zéro effort attendu : doit pouvoir s'inscrire et utiliser sa carte de fidélité sans télécharger d'app, sans créer de compte, sans mot de passe.

### Modèle économique

- **Setup fee** : 99€ one-shot à l'installation
- **Abonnement mensuel** : 19€/mois par commerçant (SaaS via Stripe Subscriptions)
- À valider lors des interviews terrain Phase 0

### Marché géographique

France uniquement en V1. Démarrage Seine-et-Marne, Île-de-France, puis national. Tout doit être français par défaut, RGPD-natif, hébergé en UE.

### Volumétrie attendue

| Période | Commerçants payants | Clients finaux cumulés |
|---|---|---|
| Année 1 | 40-60 | ~3 000 - 5 000 |
| Année 2 | 100-200 | ~15 000 - 30 000 |

Trafic prévu : faible volume mais cohérent (chaque commerçant fait quelques scans/jour), pas de pics violents sauf événements ponctuels.

---

## 3. Stack technique imposée

**Choix déjà faits, à respecter** (ne pas proposer d'alternatives) :

| Composant | Choix |
|---|---|
| Framework | Next.js 15 (App Router) + TypeScript strict, pas de `any` |
| Base de données + auth + storage | Supabase (PostgreSQL managé), région **Frankfurt (EU Central)** obligatoire |
| UI | Tailwind CSS + shadcn/ui |
| Hébergement applicatif | Vercel |
| Paiements | Stripe Checkout + Subscriptions + Webhooks |
| Apple Wallet | librairie `passkit-generator` (npm), Apple Developer Program + Pass Type ID |
| Google Wallet | API REST Google Wallet, service account avec JWT |
| Emails transactionnels | Resend ou Postmark (à arbitrer) |
| Monitoring erreurs | Sentry (free tier) |
| QR codes | `qrcode` (génération), `html5-qrcode` ou `@yudiel/react-qr-scanner` (lecture) |
| Repo | GitHub privé, branches `main` protégée + `dev` |

### Workflow dev

Développement **100% en local** pendant la phase MVP, puis déploiement Vercel preview privé, puis production. **Pas d'auto-hébergement.**

### Niveau technique de l'équipe

Solal (CEO + référent tech) : niveau débutant, HTML/CSS/JS bases, apprend en parallèle. Code écrit en grande partie avec Claude (Claude Code / Cursor) en mode "claude-powered".

**L'architecture doit donc être simple, conventionnelle, well-documented**, sans trucs exotiques que le dev ne comprendra pas.

---

## 4. Fonctionnalités MVP — Scope exhaustif

> Si quelque chose manque ici, c'est hors scope.

### Côté commerçant

1. Inscription via email + mot de passe (Supabase Auth)
2. Connexion / déconnexion
3. Configuration de son enseigne : nom, type d'activité, adresse, téléphone, logo (upload image)
4. Création d'UN programme de fidélité simple : nom du programme, nombre de tampons requis (ex: 10), description de la récompense (ex: "1 café offert"), couleur primaire, couleur secondaire
5. Preview en temps réel du rendu du pass (Apple + Google) dans le dashboard
6. Génération automatique d'un QR code unique de la boutique (à imprimer/afficher physiquement)
7. Interface « tamponner un client » : scan du pass via caméra du smartphone OU saisie manuelle d'un code court
8. Liste des clients fidélisés avec leur compteur de tampons
9. Statistiques basiques : nombre de clients inscrits, nombre de tampons distribués, nombre de récompenses utilisées

### Côté client final

1. Arrivée sur une page publique via scan du QR code en boutique (URL type `fidela.fr/c/[slug-boutique]`)
2. Inscription : email OU téléphone (pas de mot de passe, pas de compte à créer)
3. Génération immédiate et téléchargement du wallet pass (auto-détection iOS/Android → Apple Wallet ou Google Wallet)
4. Le pass affiche : logo commerçant, nom du programme, X/Y tampons, couleurs personnalisées
5. Mise à jour du pass quand un nouveau tampon est ajouté (Apple Push Notification Service pour iOS, refresh Google Wallet pour Android)

### Côté admin Fidela (super-admin)

1. Vue d'ensemble des commerçants inscrits
2. Possibilité de désactiver un compte
3. Logs basiques

### Hors scope MVP

**À ne PAS développer** :

- Multi-utilisateurs par compte commerçant
- Multi-établissements (plusieurs points de vente sous un même compte)
- Plusieurs programmes de fidélité par commerçant
- Notifications SMS
- Intégration caisse (Sumup, Square, etc.)
- Programme de parrainage
- Gamification (niveaux, badges)
- App mobile native
- Multi-langue
- Analytics avancées

---

## 5. Contraintes techniques et règles non négociables

### Sécurité

- Row Level Security (RLS) Supabase activé sur **100% des tables**, sans exception
- Aucun secret committé sur Git, tout en variables d'environnement
- `service_role_key` Supabase utilisée **UNIQUEMENT côté serveur** (routes API), jamais côté client
- Validation des inputs côté serveur systématique (Zod recommandé)
- Vérification de signature des webhooks Stripe obligatoire
- Anti-fraude tampon : max 1 tampon par client/commerçant toutes les 30 minutes
- Toutes les routes API authentifiées vérifient l'identité du commerçant avant action

### Conformité RGPD

- Hébergement Supabase Frankfurt confirmé
- Consentement explicite avant collecte email/téléphone côté client final
- Politique de confidentialité accessible
- Droit à l'effacement implémenté (endpoint qui supprime un customer et ses passes)
- Droit d'accès aux données (export JSON)
- Registre des traitements maintenu hors code

### Performance

- Pages doivent charger en moins de **2 secondes** sur 4G
- Génération d'un pass wallet : moins de **3 secondes** après inscription client
- Tampon ajouté → pass mis à jour : moins de **5 secondes** côté serveur

### Mobile-first

- 100% des interfaces doivent être utilisables sur smartphone (le commerçant tamponne depuis son téléphone)
- Testé sur iPhone récent ET Android récent
- Pas de besoin desktop, mais doit rester fonctionnel

### Langue & accessibilité

- **Langue** : français par défaut, internationalisation préparée mais pas implémentée
- **Accessibilité** : niveau RGAA basique (attributs alt, contrastes, navigation clavier sur dashboard)

---

## 6. Schéma de données souhaité (à valider / améliorer)

Voici le schéma initial réfléchi. L'architecte peut le challenger.

### Tables principales

#### `merchants`

```
id, user_id (FK auth.users), business_name, business_type,
address, phone, logo_url, subscription_status (enum: trial/active/past_due/canceled),
stripe_customer_id, stripe_subscription_id, slug (URL unique),
created_at, updated_at
```

#### `loyalty_programs`

```
id, merchant_id (FK), name, description, stamps_required (int),
reward_description, primary_color (hex), secondary_color (hex),
is_active (bool), created_at, updated_at
```

#### `customers`

```
id, email (nullable), phone (nullable), created_at
```

Déduplication par couple `(email, phone, merchant_id)`.

#### `customer_passes`

```
id, customer_id (FK), loyalty_program_id (FK), merchant_id (FK),
serial_number (unique, identifiant pass dans le wallet),
apple_pass_url, google_pass_url,
current_stamps (int), total_rewards_claimed (int),
created_at, last_visit_at, updated_at
```

#### `stamps` (historique)

```
id, customer_pass_id (FK), merchant_id (FK),
created_at, created_by (FK auth.users)
```

#### `rewards_claimed` (historique)

```
id, customer_pass_id (FK), merchant_id (FK),
created_at, claimed_by (FK auth.users)
```

#### `waitlist` (early access landing)

```
id, email, created_at, source
```

### Points à arbitrer par l'architecte

1. Faut-il une table `users` séparée des `merchants` pour anticiper le multi-user ?
2. Comment gérer les soft-deletes pour la conformité RGPD vs intégrité des stats ?
3. Stratégie d'indexation sur les requêtes fréquentes (lookup par `serial_number`, par `slug` merchant) ?

---

## 7. Architecture applicative attendue

### Structure du repo envisagée

```
fidela/
├── app/
│   ├── (auth)/              # signup, login, reset-password
│   ├── (dashboard)/         # interface commerçant connecté
│   ├── (public)/            # landing, inscription client /c/[slug]
│   ├── api/
│   │   ├── passes/apple/[serial]/    # génération .pkpass dynamique
│   │   ├── passes/google/[serial]/   # génération Google Wallet pass
│   │   ├── stamps/                   # ajout/retrait de tampons
│   │   ├── webhooks/
│   │   │   ├── stripe/
│   │   │   └── apple-wallet/         # callbacks PassKit
│   │   └── admin/
│   └── layout.tsx
├── components/
├── lib/
│   ├── supabase/
│   ├── stripe/
│   ├── wallets/
│   │   ├── apple.ts
│   │   └── google.ts
│   └── utils/
├── types/
├── public/
├── certificates/  # certificats Apple (PAS committés)
└── ...
```

### Questions architecturales à trancher

1. Comment versionner les certificats Apple Pass Type ID en production sans les exposer ?
2. Quelle stratégie pour les callbacks Apple Push Notification Service (web service URL) en dev local (ngrok) vs prod ?
3. Faut-il une couche de service entre les routes API et Supabase ? (Pattern Repository / Service Layer)
4. Comment structurer les server actions vs API routes dans Next.js 15 App Router ?
5. Cron jobs : nécessaires pour nettoyer les sessions expirées, relancer les abandonnés ? Si oui, comment (Vercel Cron, Supabase Edge Functions) ?
6. Gestion des images uploadées (logos commerçants) : Supabase Storage avec quel bucket / quelles policies ?

---

## 8. Workflow dev et environnements

### Environnements

| Environnement | Usage | Base de données |
|---|---|---|
| Local | Développement quotidien | Supabase « fidela-dev » (Frankfurt, free tier) |
| Preview Vercel | Déploiements auto sur PR | Mêmes credentials Supabase dev |
| Production | Plus tard, post-pilote | Supabase « fidela-prod » séparée |

### Outils externes en dev local

- **ngrok** ou **Cloudflare Tunnel** : exposer localhost pour callbacks Apple/Google/Stripe
- **Stripe CLI** : forwarder les webhooks
- **Supabase Studio** : gérer la base

### CI/CD

Vercel auto-deploy sur push `main`. Pas de tests automatisés en MVP (à mettre en place plus tard).

---

## 9. Livrables attendus de l'architecte

L'architecte (ou la session Claude dédiée) doit produire :

1. **Validation ou critique du schéma de données proposé**, avec proposition améliorée si besoin (en SQL DDL Supabase prêt à exécuter)
2. **Liste exhaustive des policies RLS** à écrire pour chaque table (en SQL)
3. **Diagramme d'architecture applicative** : qui parle à qui, où sont les frontières (client, server, API externes, DB)
4. **Liste exhaustive des routes API** à coder, avec méthode HTTP, params, retours, niveau d'auth requis
5. **Liste des server actions Next.js** vs routes API, avec justification du choix pour chaque
6. **Stratégie de gestion des certificats Apple** (où, comment, sécurité)
7. **Flow détaillé du parcours client** (du scan QR à la mise à jour du pass après tampon), avec séquence d'appels API
8. **Flow détaillé du parcours commerçant** (inscription → config programme → tamponner un client)
9. **Stratégie de tests** minimale recommandée pour les briques critiques (génération pass, webhook Stripe, anti-fraude tampon)
10. **Estimation de complexité** par sprint MVP (1 à 6) en jours-homme pour un dev junior assisté par Claude
11. **Risques techniques identifiés** et stratégies de mitigation
12. **Plan de découpage en sprints** validé ou amendé

---

## 10. Sprints MVP envisagés (à valider/amender)

| Sprint | Durée | Contenu |
|---|---|---|
| Sprint 1 | 2 semaines | Landing publique + auth commerçant + waitlist |
| Sprint 2 | 2 semaines | Configuration programme de fidélité côté dashboard |
| Sprint 3 | 3 semaines | Génération Apple Wallet `.pkpass` dynamique signé |
| Sprint 4 | 2 semaines | Génération Google Wallet |
| Sprint 5 | 2 semaines | Parcours d'inscription client + landing `/c/[slug]` |
| Sprint 6 | 2 semaines | Système de tampon (scan + incrément + mise à jour pass) |

**Total estimé** : 13 semaines de dev, pour un dev junior claude-powered. À challenger.

---

## 11. Hors scope architecture

**Tu n'as PAS à proposer** :

- Une stack alternative (les choix sont faits)
- Une infrastructure complexe (Kubernetes, microservices, message queues, etc. — overkill pour le volume)
- Du native mobile (pas d'app mobile en MVP)
- De l'IA / ML
- Une intégration caisse (hors scope MVP)

---

## 12. Posture attendue

Sois **direct et pragmatique**. Tu parles à un fondateur étudiant qui apprend en construisant. Évite le jargon inutile, mais ne sois pas condescendant. Si un choix dans ce brief te paraît mauvais, dis-le clairement avec ta justification. Tes recommandations doivent être **actionnables** : du code SQL prêt à exécuter, des arborescences de fichiers concrètes, des noms de fonctions exacts.

Quand tu rends ton plan, **structure-le par sprint** pour qu'il soit directement consommable comme roadmap d'exécution.

---

## Comment utiliser ce brief

### Première fois

Ouvrir une nouvelle session Claude dédiée. Coller ce brief en entier. Conclure avec :

> Tu es senior software architect. Voici le brief complet du projet Fidela. Produis-moi les 12 livrables attendus en section 9, dans cet ordre. Sois pragmatique, je code en claude-powered avec un niveau junior.

Si Claude sort 5 000 lignes d'un coup, demander de découper :

> Commence par les livrables 1-3, on enchaînera ensuite.

### Sessions suivantes

Toujours recoller ce brief en début de session pour recontextualiser. Mettre à jour ce document quand les décisions évoluent (nouvelle stack, scope ajusté, etc.).

### Stockage

Conserver ce fichier à deux endroits :

1. **Notion → Wiki Fidela → Documentation technique → ARCHITECTURE_BRIEF**
2. **Repo GitHub** : `/ARCHITECTURE_BRIEF.md` à la racine du projet `fidela`

---

*Document vivant. Version 1.0 — 2026-05-11.*
