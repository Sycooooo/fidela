-- ============================================================================
-- FIDELA — Row Level Security policies
-- À exécuter APRÈS schema.sql.
-- Règle imposée : RLS activé sur 100% des tables, sans exception.
-- ============================================================================
--
-- PRINCIPE GÉNÉRAL
--   - Le rôle anon (visiteur non connecté) : accès en lecture sur très peu de
--     choses (loyalty_programs actifs + merchants non supprimés via slug).
--   - Le rôle authenticated (commerçant connecté) : accès à SES données via
--     auth.uid() == merchants.user_id.
--   - Le rôle service_role (routes API serveur) bypasse RLS par construction
--     Supabase. Toute opération sensible (génération pass, webhooks, add_stamp)
--     passe par service_role côté serveur.
--
-- Pas de policy permissive pour anon sur customers, customer_passes, stamps :
-- ces opérations passent toutes par les routes API serveur en service_role.
-- ============================================================================

-- ============================================================================
-- merchants
-- ============================================================================

alter table merchants enable row level security;

-- Lecture publique limitée : la landing client /c/[slug] doit pouvoir résoudre
-- un merchant par slug pour afficher le branding. Pas de PII exposée.
-- En pratique on filtrera les colonnes côté API, mais RLS autorise la ligne.
create policy "merchants: public can read non-deleted by slug"
  on merchants for select
  to anon
  using (deleted_at is null);

-- Le merchant connecté voit son propre profil
create policy "merchants: owner can read own row"
  on merchants for select
  to authenticated
  using (user_id = auth.uid() and deleted_at is null);

-- Le merchant connecté peut modifier son propre profil
create policy "merchants: owner can update own row"
  on merchants for update
  to authenticated
  using (user_id = auth.uid() and deleted_at is null)
  with check (user_id = auth.uid());

-- INSERT : réservé au flow d'onboarding via route API serveur (service_role).
-- Pas de policy authenticated en INSERT — empêche un user de créer un merchant
-- en bypassant le paiement Stripe.

-- DELETE : interdit (soft-delete via update deleted_at en service_role).

-- ============================================================================
-- loyalty_programs
-- ============================================================================

alter table loyalty_programs enable row level security;

-- Lecture publique des programmes actifs (pour la landing client)
create policy "loyalty_programs: public can read active"
  on loyalty_programs for select
  to anon
  using (is_active = true);

-- Le merchant gère ses programmes
create policy "loyalty_programs: merchant can read own"
  on loyalty_programs for select
  to authenticated
  using (
    exists (
      select 1 from merchants
      where merchants.id = loyalty_programs.merchant_id
        and merchants.user_id = auth.uid()
        and merchants.deleted_at is null
    )
  );

create policy "loyalty_programs: merchant can insert own"
  on loyalty_programs for insert
  to authenticated
  with check (
    exists (
      select 1 from merchants
      where merchants.id = loyalty_programs.merchant_id
        and merchants.user_id = auth.uid()
        and merchants.deleted_at is null
    )
  );

create policy "loyalty_programs: merchant can update own"
  on loyalty_programs for update
  to authenticated
  using (
    exists (
      select 1 from merchants
      where merchants.id = loyalty_programs.merchant_id
        and merchants.user_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1 from merchants
      where merchants.id = loyalty_programs.merchant_id
        and merchants.user_id = auth.uid()
    )
  );

-- DELETE interdit (is_active = false suffit)

-- ============================================================================
-- customers
-- ============================================================================

alter table customers enable row level security;

-- Aucune lecture publique. Aucune écriture publique.
-- L'inscription client passe par route API serveur en service_role.

-- Le merchant voit ses clients
create policy "customers: merchant can read own"
  on customers for select
  to authenticated
  using (
    exists (
      select 1 from merchants
      where merchants.id = customers.merchant_id
        and merchants.user_id = auth.uid()
    )
  );

-- Le merchant peut update (corriger un email/phone) mais pas créer ni delete
create policy "customers: merchant can update own"
  on customers for update
  to authenticated
  using (
    exists (
      select 1 from merchants
      where merchants.id = customers.merchant_id
        and merchants.user_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1 from merchants
      where merchants.id = customers.merchant_id
        and merchants.user_id = auth.uid()
    )
  );

-- INSERT et DELETE : service_role uniquement (voir flow client section 4)

-- ============================================================================
-- customer_passes
-- ============================================================================

alter table customer_passes enable row level security;

create policy "customer_passes: merchant can read own"
  on customer_passes for select
  to authenticated
  using (
    exists (
      select 1 from merchants
      where merchants.id = customer_passes.merchant_id
        and merchants.user_id = auth.uid()
    )
  );

-- INSERT, UPDATE (incrément stamps), DELETE : passent par service_role
-- via la fonction add_stamp() et les routes API de génération.

-- ============================================================================
-- apple_devices
-- ============================================================================

alter table apple_devices enable row level security;

-- Aucune policy : toutes les opérations PassKit Web Service passent par
-- les routes API serveur en service_role (callbacks d'enregistrement
-- de device Apple).

-- ============================================================================
-- stamps
-- ============================================================================

alter table stamps enable row level security;

create policy "stamps: merchant can read own"
  on stamps for select
  to authenticated
  using (
    exists (
      select 1 from merchants
      where merchants.id = stamps.merchant_id
        and merchants.user_id = auth.uid()
    )
  );

-- INSERT : passe exclusivement par la fonction add_stamp() (security definer).
-- Pas de policy INSERT directe pour éviter de bypasser l'anti-fraude 30 min.
-- DELETE / UPDATE : interdits (historique immutable).

-- ============================================================================
-- rewards_claimed
-- ============================================================================

alter table rewards_claimed enable row level security;

create policy "rewards_claimed: merchant can read own"
  on rewards_claimed for select
  to authenticated
  using (
    exists (
      select 1 from merchants
      where merchants.id = rewards_claimed.merchant_id
        and merchants.user_id = auth.uid()
    )
  );

create policy "rewards_claimed: merchant can insert own"
  on rewards_claimed for insert
  to authenticated
  with check (
    exists (
      select 1 from merchants
      where merchants.id = rewards_claimed.merchant_id
        and merchants.user_id = auth.uid()
        and claimed_by = auth.uid()
    )
  );

-- DELETE / UPDATE : interdits (historique immutable).

-- ============================================================================
-- waitlist
-- ============================================================================

alter table waitlist enable row level security;

-- N'importe qui peut s'inscrire à la waitlist (formulaire landing publique)
create policy "waitlist: anyone can insert"
  on waitlist for insert
  to anon, authenticated
  with check (true);

-- Lecture : service_role uniquement (admin dashboard côté serveur)
-- DELETE / UPDATE : service_role uniquement

-- ============================================================================
-- GRANTS sur les fonctions
-- ============================================================================

-- add_stamp : appelée par le merchant connecté depuis l'API route
grant execute on function add_stamp(uuid) to authenticated;

-- anonymize_customer : appelée par le merchant connecté depuis l'API route
grant execute on function anonymize_customer(uuid) to authenticated;

-- ============================================================================
-- FIN
-- ============================================================================
