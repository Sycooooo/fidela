-- ============================================================================
-- FIDELA — Schéma de base de données Supabase (PostgreSQL)
-- Région : Frankfurt (EU Central) — imposé par RGPD
-- Version : 1.0 — 2026-05-11
-- À exécuter dans Supabase Studio → SQL Editor en une fois.
-- RLS policies dans rls.sql (à exécuter APRÈS ce fichier).
-- ============================================================================

-- Extensions nécessaires
create extension if not exists "pgcrypto";       -- gen_random_uuid()
create extension if not exists "citext";         -- emails case-insensitive

-- ============================================================================
-- TYPES ENUM
-- ============================================================================

create type subscription_status as enum (
  'trial',
  'active',
  'past_due',
  'canceled'
);

create type business_type as enum (
  'boulangerie',
  'restaurant',
  'cafe',
  'coiffeur',
  'institut_beaute',
  'fleuriste',
  'autre'
);

-- ============================================================================
-- TRIGGER GÉNÉRIQUE updated_at
-- ============================================================================

create or replace function set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ============================================================================
-- TABLE : merchants
-- 1:1 avec auth.users (multi-user hors scope MVP).
-- soft-delete via deleted_at (RGPD : commerçant peut quitter, on garde
-- l'historique agrégé mais on coupe l'accès).
-- ============================================================================

create table merchants (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null unique references auth.users(id) on delete cascade,
  business_name   text not null check (length(business_name) between 1 and 120),
  business_type   business_type not null,
  address         text,
  phone           text,
  logo_url        text,
  slug            text not null unique check (slug ~ '^[a-z0-9-]{3,60}$'),

  -- Stripe
  subscription_status subscription_status not null default 'trial',
  stripe_customer_id     text unique,
  stripe_subscription_id text unique,

  -- Soft-delete RGPD
  deleted_at      timestamptz,

  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index merchants_user_id_idx on merchants(user_id) where deleted_at is null;
create index merchants_slug_idx    on merchants(slug)    where deleted_at is null;

create trigger merchants_updated_at
  before update on merchants
  for each row execute function set_updated_at();

-- ============================================================================
-- TABLE : loyalty_programs
-- 1 programme par merchant en MVP (contrainte applicative, pas DB,
-- pour pouvoir évoluer sans migration).
-- ============================================================================

create table loyalty_programs (
  id                  uuid primary key default gen_random_uuid(),
  merchant_id         uuid not null references merchants(id) on delete cascade,
  name                text not null check (length(name) between 1 and 80),
  description         text,
  stamps_required     int  not null check (stamps_required between 1 and 50),
  reward_description  text not null check (length(reward_description) between 1 and 200),
  primary_color       text not null check (primary_color   ~ '^#[0-9A-Fa-f]{6}$'),
  secondary_color     text not null check (secondary_color ~ '^#[0-9A-Fa-f]{6}$'),
  is_active           boolean not null default true,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create index loyalty_programs_merchant_id_idx
  on loyalty_programs(merchant_id) where is_active = true;

create trigger loyalty_programs_updated_at
  before update on loyalty_programs
  for each row execute function set_updated_at();

-- ============================================================================
-- TABLE : customers
-- Un customer existe DANS LE CONTEXTE d'un merchant (pas de notion globale
-- de "client Fidela"). Un même email chez 2 merchants = 2 lignes.
-- Simplifie la dedup ET les RLS.
-- ============================================================================

create table customers (
  id              uuid primary key default gen_random_uuid(),
  merchant_id     uuid not null references merchants(id) on delete cascade,

  -- Au moins l'un des deux requis (vérifié au niveau applicatif)
  email           citext,
  phone           text,

  -- Consentement RGPD
  consent_at      timestamptz not null default now(),

  -- Anonymisation RGPD (droit à l'effacement)
  anonymized_at   timestamptz,

  created_at      timestamptz not null default now(),

  constraint customers_email_or_phone_required
    check (email is not null or phone is not null)
);

-- Dedup par merchant : un email ou phone ne peut exister qu'une fois par merchant
-- (en ignorant les anonymisés)
create unique index customers_merchant_email_unique
  on customers(merchant_id, email)
  where email is not null and anonymized_at is null;

create unique index customers_merchant_phone_unique
  on customers(merchant_id, phone)
  where phone is not null and anonymized_at is null;

-- ============================================================================
-- TABLE : customer_passes
-- Un pass = la matérialisation d'un customer dans un programme de fidélité.
-- serial_number doit être UNIQUE globalement (exigence Apple PassKit).
-- auth_token : exigé par Apple PassKit Web Service pour les callbacks device→server.
-- ============================================================================

create table customer_passes (
  id                      uuid primary key default gen_random_uuid(),
  customer_id             uuid not null references customers(id) on delete cascade,
  loyalty_program_id      uuid not null references loyalty_programs(id) on delete restrict,
  merchant_id             uuid not null references merchants(id) on delete cascade,

  -- Identifiants pass wallet
  serial_number           text not null unique check (length(serial_number) between 16 and 64),
  auth_token              text not null check (length(auth_token) >= 32),

  -- URLs de récupération (si tu pré-génères les passes en storage)
  apple_pass_url          text,
  google_pass_url         text,

  -- Compteurs
  current_stamps          int  not null default 0 check (current_stamps >= 0),
  total_rewards_claimed   int  not null default 0 check (total_rewards_claimed >= 0),

  -- Soft-delete
  deleted_at              timestamptz,

  created_at              timestamptz not null default now(),
  last_visit_at           timestamptz,
  updated_at              timestamptz not null default now(),

  -- Un customer ne peut avoir qu'un seul pass actif par programme
  constraint customer_passes_one_per_program
    unique (customer_id, loyalty_program_id)
);

create index customer_passes_merchant_id_idx
  on customer_passes(merchant_id) where deleted_at is null;

create index customer_passes_customer_id_idx
  on customer_passes(customer_id) where deleted_at is null;

create trigger customer_passes_updated_at
  before update on customer_passes
  for each row execute function set_updated_at();

-- ============================================================================
-- TABLE : apple_devices
-- Requis par Apple PassKit Web Service Protocol.
-- Chaque iPhone qui ajoute un pass à son Wallet appelle :
--   POST /v1/devices/{deviceLibraryIdentifier}/registrations/{passTypeId}/{serial}
-- On stocke le push_token pour pousser des mises à jour.
-- Réf : https://developer.apple.com/documentation/walletpasses/registering-a-pass-on-a-device
-- ============================================================================

create table apple_devices (
  id                          uuid primary key default gen_random_uuid(),
  device_library_identifier   text not null,
  customer_pass_id            uuid not null references customer_passes(id) on delete cascade,
  push_token                  text not null,
  created_at                  timestamptz not null default now(),

  constraint apple_devices_unique_registration
    unique (device_library_identifier, customer_pass_id)
);

create index apple_devices_customer_pass_id_idx
  on apple_devices(customer_pass_id);

-- ============================================================================
-- TABLE : stamps (historique immutable)
-- Pas de DELETE applicatif (immutable). RGPD géré par anonymisation du customer.
-- ============================================================================

create table stamps (
  id                  uuid primary key default gen_random_uuid(),
  customer_pass_id    uuid not null references customer_passes(id) on delete cascade,
  merchant_id         uuid not null references merchants(id)       on delete cascade,
  created_by          uuid not null references auth.users(id),    -- l'user merchant qui a tamponné
  created_at          timestamptz not null default now()
);

-- Anti-fraude : lookup rapide du dernier tampon pour un pass
create index stamps_pass_created_at_idx
  on stamps(customer_pass_id, created_at desc);

-- Stats merchant
create index stamps_merchant_created_at_idx
  on stamps(merchant_id, created_at desc);

-- ============================================================================
-- TABLE : rewards_claimed (historique immutable)
-- ============================================================================

create table rewards_claimed (
  id                  uuid primary key default gen_random_uuid(),
  customer_pass_id    uuid not null references customer_passes(id) on delete cascade,
  merchant_id         uuid not null references merchants(id)       on delete cascade,
  claimed_by          uuid not null references auth.users(id),
  created_at          timestamptz not null default now()
);

create index rewards_claimed_merchant_created_at_idx
  on rewards_claimed(merchant_id, created_at desc);

-- ============================================================================
-- TABLE : waitlist
-- Inscription publique pré-lancement.
-- ============================================================================

create table waitlist (
  id          uuid primary key default gen_random_uuid(),
  email       citext not null unique,
  source      text,
  created_at  timestamptz not null default now()
);

-- ============================================================================
-- FONCTION : add_stamp (atomique + anti-fraude 30 min)
-- À appeler depuis les routes API serveur (jamais côté client).
-- Vérifie :
--  - le pass appartient bien au merchant de l'utilisateur appelant
--  - aucun tampon n'a été ajouté dans les 30 dernières minutes
--  - le pass n'est pas soft-deleted
-- Insère le stamp, incrémente current_stamps, update last_visit_at.
-- Retourne le nouveau compteur de tampons.
-- ============================================================================

create or replace function add_stamp(p_customer_pass_id uuid)
returns int
language plpgsql
security definer  -- bypass RLS car on fait les checks nous-mêmes
set search_path = public
as $$
declare
  v_merchant_id   uuid;
  v_caller_user   uuid := auth.uid();
  v_last_stamp_at timestamptz;
  v_new_count     int;
begin
  -- 1) Vérifier que le pass existe et n'est pas supprimé
  select merchant_id into v_merchant_id
  from customer_passes
  where id = p_customer_pass_id and deleted_at is null;

  if v_merchant_id is null then
    raise exception 'Pass introuvable ou supprimé' using errcode = 'P0002';
  end if;

  -- 2) Vérifier que l'appelant possède le merchant
  if not exists (
    select 1 from merchants
    where id = v_merchant_id
      and user_id = v_caller_user
      and deleted_at is null
  ) then
    raise exception 'Non autorisé' using errcode = '42501';
  end if;

  -- 3) Anti-fraude : pas plus d'1 tampon / 30 min sur ce pass
  select max(created_at) into v_last_stamp_at
  from stamps
  where customer_pass_id = p_customer_pass_id;

  if v_last_stamp_at is not null and v_last_stamp_at > now() - interval '30 minutes' then
    raise exception 'Un tampon a déjà été ajouté il y a moins de 30 minutes'
      using errcode = 'P0001';
  end if;

  -- 4) Insérer le tampon
  insert into stamps (customer_pass_id, merchant_id, created_by)
  values (p_customer_pass_id, v_merchant_id, v_caller_user);

  -- 5) Incrémenter le compteur et mettre à jour la dernière visite
  update customer_passes
  set current_stamps = current_stamps + 1,
      last_visit_at  = now()
  where id = p_customer_pass_id
  returning current_stamps into v_new_count;

  return v_new_count;
end;
$$;

-- ============================================================================
-- FONCTION : anonymize_customer (RGPD droit à l'effacement)
-- Conserve la ligne pour intégrité des stats, mais efface les PII.
-- ============================================================================

create or replace function anonymize_customer(p_customer_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_user uuid := auth.uid();
  v_merchant_id uuid;
begin
  select merchant_id into v_merchant_id
  from customers where id = p_customer_id;

  if v_merchant_id is null then
    raise exception 'Customer introuvable';
  end if;

  if not exists (
    select 1 from merchants
    where id = v_merchant_id and user_id = v_caller_user
  ) then
    raise exception 'Non autorisé' using errcode = '42501';
  end if;

  update customers
  set email = null,
      phone = null,
      anonymized_at = now()
  where id = p_customer_id;
end;
$$;

-- ============================================================================
-- FIN — exécuter rls.sql ensuite pour activer la sécurité.
-- ============================================================================
