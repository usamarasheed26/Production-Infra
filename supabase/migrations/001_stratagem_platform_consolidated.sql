-- ============================================================================
-- Stratagem Platform — Consolidated Schema
-- ============================================================================
-- Generated 2026-08-16 as a LIVE-STATE snapshot of the "Stratagem Platform"
-- Supabase project (ref: qpivtgvygebuuszbnijb), extracted directly from the
-- running database via introspection (pg_catalog / information_schema / the
-- Supabase MCP server), per explicit request to consolidate the migration
-- history into a single file.
--
-- This file supersedes 001_initial_schema.sql through 033_sim_webhooks.sql
-- (plus the four partial "combined*.sql" files) that previously lived in
-- this directory. Those 37 files are preserved, unmodified, under
-- supabase/migrations/archive/ — nothing was deleted, only superseded.
-- scripts/run-migrations.ts has been updated to run only this file against
-- a fresh database.
--
-- IMPORTANT — reflects live state, not necessarily the intent of the
-- original numbered migrations:
--   * Migration 013_retire_legacy_di_engine.sql was deliberately excluded
--     from the auto-run list in scripts/run-migrations.ts (run manually,
--     separately) — its effects (dropped di_profiles, rationale_category,
--     archetype* columns) ARE reflected here because they are gone from the
--     live schema.
--   * Migration 027_north_star_crd.sql was originally omitted from that
--     same list and silently never ran for a period — its effects (cohorts
--     .crd_delivered_at/.temperature_check_at, platform_metrics) ARE present
--     here because they are live now.
--   * In short: trust this file over re-deriving state from the archived
--     numbered files or from run-migrations.ts's own history.
--
-- KNOWN ISSUES CAPTURED AS-IS (not corrected by this dump — flagging only):
--   1. RLS policy auth pattern is INCONSISTENT across tables. Most tables'
--      policies call the platform's own public.org_id()/public.app_role()/
--      public.uid() helper functions (thin wrappers reading the same custom
--      JWT claims). A subset — coach_notes, friction_alerts, session_commands,
--      uldp_decision_events, uldp_info_access_events, uldp_overrides,
--      uldp_profiles, uldp_axis_scores, uldp_coaching_events,
--      uldp_archetype_profiles — instead inline
--      `(auth.jwt() ->> 'org_id')::uuid` / `auth.jwt() ->> 'app_role'`
--      directly. Functionally equivalent today (same JWT, same claims), but
--      two authoring patterns for the same access rule is a maintenance
--      trap if one path is ever changed without the other. Not unified here
--      — that's a behavior change, not a schema snapshot, and needs its own
--      decision/PR.
--   2. Row Level Security is DISABLED on 12 partition child tables:
--      decision_events_{p20260701..p20261201,default} and
--      uldp_decision_events_{p20260801..p20261201} (uldp_decision_events_default
--      has RLS enabled; the others don't). This dump reproduces that exact
--      live state (RLS enabled only where it actually is live) rather than
--      silently "fixing" it — enabling RLS without matching policies would
--      block all access. See chat history / raise with the team for the
--      policy design needed before flipping these on.
--   3. decision_events and uldp_decision_events (and their partitions) have
--      no primary key — append-only event log tables, live schema has none.
--
-- Constraints are applied in two passes after all tables exist: PRIMARY
-- KEY/UNIQUE/CHECK first (Pass A, depends only on the table itself), then
-- FOREIGN KEY (Pass B, may depend on another table's PK/UNIQUE existing).
-- Constraints declared on decision_events / uldp_decision_events (the
-- partitioned parents) automatically propagate to all their partitions —
-- they are NOT redeclared per partition.
-- ============================================================================


-- ============================================================================
-- 1. EXTENSIONS
-- ============================================================================
-- uuid-ossp/pgcrypto: gen_random_uuid() and friends (installed in `extensions`
-- schema, Supabase default). pg_cron: nightly/scheduled jobs (North Star
-- rollup, cron archive/cleanup). pg_partman: manages the monthly range
-- partitions on decision_events / uldp_decision_events.
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA extensions;
-- pg_cron: verified live via pg_extension that its own catalog record's
-- extnamespace reports pg_catalog, but its actual objects (cron.schedule(),
-- cron.job) are reachable in a schema literally named `cron` — do NOT pass
-- WITH SCHEMA pg_catalog here, that targets Postgres's reserved system
-- catalog schema and is rejected for non-superusers. Supabase's own
-- provisioning is what puts the extension's catalog entry under pg_catalog;
-- a plain CREATE EXTENSION is how it's actually enabled.
CREATE EXTENSION IF NOT EXISTS "pg_cron";
CREATE EXTENSION IF NOT EXISTS "pg_partman" WITH SCHEMA partman;


-- ============================================================================
-- 2. ENUM TYPES
-- ============================================================================
CREATE TYPE public.sim_status_enum AS ENUM ('scheduled', 'open', 'closed', 'paused', 'archived');
CREATE TYPE public.debrief_job_status AS ENUM ('queued', 'processing', 'aggregating', 'completed', 'failed');


-- ============================================================================
-- 3. TABLES — CORE (orgs, users, sim catalog, licensing, modules)
-- ============================================================================

CREATE TABLE public.orgs (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  name text NOT NULL,
  slug text NOT NULL,
  org_type text NOT NULL DEFAULT 'institutional'::text,
  billing_tier text NOT NULL DEFAULT 'free'::text,
  stripe_customer_id text,
  stripe_sub_id text,
  billing_period_end timestamp with time zone,
  cohorts_used_total integer NOT NULL DEFAULT 0,
  max_learners_override integer,
  brand_name text,
  brand_logo_url text,
  brand_primary_color text DEFAULT '#534AB7'::text,
  certificate_signatory_name text,
  certificate_signatory_title text,
  brand_email_from_name text,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  facilitator_type text
);

CREATE TABLE public.users (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  clerk_user_id text NOT NULL,
  email text NOT NULL,
  full_name text,
  org_id uuid,
  role text NOT NULL DEFAULT 'cohort_learner'::text,
  last_active_at timestamp with time zone,
  email_preferences jsonb NOT NULL DEFAULT '{"archive_warnings": true, "deadline_reminders": true, "intervention_alerts": true, "completion_confirmations": true}'::jsonb,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE public.sim_registry (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  name text NOT NULL,
  slug text NOT NULL,
  description text,
  round_count integer NOT NULL DEFAULT 7,
  is_public boolean NOT NULL DEFAULT false,
  calibration_status text NOT NULL DEFAULT 'seeded'::text,
  subdomain text,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  control_schema jsonb NOT NULL DEFAULT '[]'::jsonb,
  control_schema_version text NOT NULL DEFAULT 'v1'::text,
  owner_org_id uuid,
  supplies_evaluations boolean NOT NULL DEFAULT false
);

CREATE TABLE public.licence_pools (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL,
  sim_id uuid NOT NULL,
  total_seats integer NOT NULL,
  used_seats integer NOT NULL DEFAULT 0,
  price_per_seat numeric(10,2) NOT NULL DEFAULT 0,
  currency text NOT NULL DEFAULT 'USD'::text,
  expires_at timestamp with time zone,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE public.modules (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  org_id uuid,
  name text NOT NULL,
  description text,
  sim_ids uuid[] NOT NULL DEFAULT '{}'::uuid[],
  created_by uuid,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);


-- ============================================================================
-- 4. TABLES — COHORT & SESSION
-- ============================================================================

CREATE TABLE public.cohorts (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL,
  sim_id uuid,
  created_by uuid,
  name text NOT NULL,
  slug text,
  sim_status sim_status_enum NOT NULL DEFAULT 'scheduled'::sim_status_enum,
  is_demo boolean NOT NULL DEFAULT false,
  deadline timestamp with time zone,
  timezone text NOT NULL DEFAULT 'UTC'::text,
  round_override integer,
  max_attempts integer,
  learning_objectives text[] NOT NULL DEFAULT '{}'::text[],
  broadcast_token text,
  archive_scheduled_at timestamp with time zone,
  archive_delay_count integer NOT NULL DEFAULT 0,
  pptx_status text NOT NULL DEFAULT 'none'::text,
  pptx_requested_at timestamp with time zone,
  pptx_generated_at timestamp with time zone,
  pptx_file_url text,
  pptx_student_url text,
  current_debrief_job_id uuid,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  crd_delivered_at timestamp with time zone,
  temperature_check_at timestamp with time zone
);

CREATE TABLE public.cohort_members (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  cohort_id uuid NOT NULL,
  user_id uuid,
  email text,
  score integer,
  role text NOT NULL DEFAULT 'cohort_learner'::text,
  joined_at timestamp with time zone,
  expires_at timestamp with time zone,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE public.cohort_gates (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  cohort_id uuid NOT NULL,
  round_number integer NOT NULL,
  is_open boolean NOT NULL DEFAULT false,
  opened_at timestamp with time zone,
  opened_by uuid,
  closed_at timestamp with time zone,
  closed_by uuid,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE public.cohort_messages (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  cohort_id uuid NOT NULL,
  sent_by uuid NOT NULL,
  target text NOT NULL,
  subject text NOT NULL,
  body text NOT NULL,
  recipient_count integer NOT NULL DEFAULT 0,
  sent_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE public.org_invites (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL,
  cohort_id uuid,
  invited_by uuid,
  email text NOT NULL,
  role text NOT NULL DEFAULT 'cohort_learner'::text,
  token text NOT NULL,
  status text NOT NULL DEFAULT 'pending'::text,
  expires_at timestamp with time zone NOT NULL,
  accepted_at timestamp with time zone,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE public.sim_sessions (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  session_token text NOT NULL,
  cohort_id uuid NOT NULL,
  user_id uuid,
  sim_id uuid,
  completion_status text NOT NULL DEFAULT 'in_progress'::text,
  final_score integer,
  meaningful_score integer,
  is_meaningful boolean,
  current_round integer NOT NULL DEFAULT 0,
  rounds_completed integer NOT NULL DEFAULT 0,
  decision_count integer NOT NULL DEFAULT 0,
  duration_mins integer,
  credential_id text,
  referrer_user_id uuid,
  is_repeat_play boolean NOT NULL DEFAULT false,
  consent_di_profiling boolean NOT NULL DEFAULT true,
  debrief_status text NOT NULL DEFAULT 'none'::text,
  debrief_summary jsonb,
  debrief_retry_count integer NOT NULL DEFAULT 0,
  debrief_next_retry_at timestamp with time zone,
  lti_context_id uuid,
  lti_grade_synced_at timestamp with time zone,
  first_interaction_at timestamp with time zone,
  started_at timestamp with time zone NOT NULL DEFAULT now(),
  completed_at timestamp with time zone,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  percentile_rank integer
);

CREATE TABLE public.badge_awards (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  session_id uuid,
  slug text NOT NULL,
  name text NOT NULL,
  description text,
  awarded_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE public.event_dedup (
  event_id uuid NOT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE public.session_commands (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  cohort_id uuid NOT NULL,
  command_type text NOT NULL,
  target_scope text NOT NULL,
  target_round integer,
  target_session_id uuid,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  issued_by uuid NOT NULL,
  issued_at timestamp with time zone NOT NULL DEFAULT now(),
  released_at timestamp with time zone,
  released_by uuid
);

CREATE TABLE public.coach_notes (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  session_id uuid NOT NULL,
  round_number integer NOT NULL,
  learner_id uuid NOT NULL,
  cohort_id uuid NOT NULL,
  note text NOT NULL,
  created_by uuid NOT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE public.debrief_jobs (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  cohort_id uuid NOT NULL,
  status debrief_job_status NOT NULL DEFAULT 'queued'::debrief_job_status,
  total_tasks integer NOT NULL DEFAULT 0,
  completed_tasks integer NOT NULL DEFAULT 0,
  failed_tasks integer NOT NULL DEFAULT 0,
  error_details jsonb,
  inngest_event_id text,
  pptx_file_url text,
  pptx_student_url text,
  user_feedback_score integer,
  user_feedback_notes text,
  started_at timestamp with time zone,
  completed_at timestamp with time zone,
  created_by uuid,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  first_downloaded_at timestamp with time zone,
  first_downloaded_by uuid,
  download_count integer NOT NULL DEFAULT 0
);

-- decision_events: legacy per-session event log (pre-ULDP), partitioned
-- monthly on created_at, managed by pg_partman. No primary key (append-only
-- log) — matches live state.
CREATE TABLE public.decision_events (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  session_id uuid NOT NULL,
  event_type text NOT NULL,
  round_number integer,
  payload jsonb,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  event_id uuid
) PARTITION BY RANGE (created_at);

CREATE TABLE public.decision_events_p20260701 PARTITION OF public.decision_events
  FOR VALUES FROM ('2026-07-01 00:00:00+00') TO ('2026-08-01 00:00:00+00');
CREATE TABLE public.decision_events_p20260801 PARTITION OF public.decision_events
  FOR VALUES FROM ('2026-08-01 00:00:00+00') TO ('2026-09-01 00:00:00+00');
CREATE TABLE public.decision_events_p20260901 PARTITION OF public.decision_events
  FOR VALUES FROM ('2026-09-01 00:00:00+00') TO ('2026-10-01 00:00:00+00');
CREATE TABLE public.decision_events_p20261001 PARTITION OF public.decision_events
  FOR VALUES FROM ('2026-10-01 00:00:00+00') TO ('2026-11-01 00:00:00+00');
CREATE TABLE public.decision_events_p20261101 PARTITION OF public.decision_events
  FOR VALUES FROM ('2026-11-01 00:00:00+00') TO ('2026-12-01 00:00:00+00');
CREATE TABLE public.decision_events_p20261201 PARTITION OF public.decision_events
  FOR VALUES FROM ('2026-12-01 00:00:00+00') TO ('2027-01-01 00:00:00+00');
CREATE TABLE public.decision_events_default PARTITION OF public.decision_events DEFAULT;


-- ============================================================================
-- 5. TABLES — LMS / LTI (Phase 3 / Epic 8b schema, Week-1 addition)
-- ============================================================================

CREATE TABLE public.lms_installations (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL,
  platform_name text NOT NULL,
  platform_url text NOT NULL,
  client_id text NOT NULL,
  auth_login_url text NOT NULL,
  auth_token_url text NOT NULL,
  key_set_url text NOT NULL,
  deployment_ids text[] NOT NULL DEFAULT '{}'::text[],
  grade_scale text NOT NULL DEFAULT 'proportion'::text,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE public.lms_context_cohorts (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  installation_id uuid NOT NULL,
  context_id text NOT NULL,
  context_label text,
  cohort_id uuid,
  sim_id uuid,
  lineitem_url text,
  lineitems_url text,
  nrps_url text,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE public.lti_identities (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  installation_id uuid NOT NULL,
  lti_sub text NOT NULL,
  user_id uuid NOT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);


-- ============================================================================
-- 6. TABLES — ENGAGEMENT EVALUATION CONTRACT & SIM-FACING AUTH
-- ============================================================================

CREATE TABLE public.session_engagement_evaluations (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  session_id uuid NOT NULL,
  schema_version text NOT NULL,
  evaluation_id uuid NOT NULL,
  simulation_version text NOT NULL,
  evaluated_at timestamp with time zone NOT NULL,
  is_meaningful boolean NOT NULL,
  meaningful_score integer NOT NULL,
  confidence numeric(4,3) NOT NULL,
  threshold integer NOT NULL,
  threshold_type text NOT NULL,
  arc text NOT NULL,
  breakdown jsonb NOT NULL DEFAULT '{}'::jsonb,
  flags jsonb NOT NULL DEFAULT '[]'::jsonb,
  anti_gaming_triggered boolean NOT NULL DEFAULT false,
  anti_gaming_violations jsonb NOT NULL DEFAULT '[]'::jsonb,
  session_metadata jsonb,
  raw_payload jsonb NOT NULL,
  is_current boolean NOT NULL DEFAULT true,
  superseded_at timestamp with time zone,
  superseded_by_evaluation_id uuid,
  source_api_key_id uuid,
  received_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE public.engagement_evaluation_overrides (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  session_id uuid NOT NULL,
  evaluation_id uuid NOT NULL,
  is_meaningful boolean,
  reason text NOT NULL,
  created_by uuid NOT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  revoked_at timestamp with time zone,
  revoked_by uuid
);

CREATE TABLE public.sim_api_keys (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  key_hash text NOT NULL,
  key_prefix text NOT NULL,
  external_sim_id text NOT NULL,
  environment text NOT NULL,
  label text,
  created_by uuid,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  expires_at timestamp with time zone,
  revoked_at timestamp with time zone,
  last_used_at timestamp with time zone
);

CREATE TABLE public.sim_webhooks (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  external_sim_id text NOT NULL,
  environment text NOT NULL,
  url text NOT NULL,
  signing_secret text NOT NULL,
  active boolean NOT NULL DEFAULT true,
  created_by uuid,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  last_success_at timestamp with time zone,
  last_failure_at timestamp with time zone,
  last_error text
);


-- ============================================================================
-- 7. TABLES — ULDP (Unified Learner Decision Profile)
-- ============================================================================

CREATE TABLE public.uldp_priors (
  axis text NOT NULL,
  prior_mean numeric NOT NULL,
  min_observations integer NOT NULL,
  prior_version text NOT NULL DEFAULT 'v0-provisional'::text,
  notes text,
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  half_life_days integer NOT NULL DEFAULT 90
);

CREATE TABLE public.uldp_archetypes (
  slug text NOT NULL,
  name text NOT NULL,
  description text,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE public.uldp_simulations (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  external_sim_id text NOT NULL,
  version text NOT NULL,
  domain text NOT NULL,
  archetypes text[] NOT NULL DEFAULT '{}'::text[],
  complexity_index smallint NOT NULL,
  info_sources jsonb NOT NULL DEFAULT '[]'::jsonb,
  options jsonb NOT NULL DEFAULT '[]'::jsonb,
  adaptation_triggers jsonb NOT NULL DEFAULT '[]'::jsonb,
  registered_by uuid,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  decision_families text[] NOT NULL DEFAULT '{}'::text[],
  strategy_vector_map jsonb NOT NULL DEFAULT '{}'::jsonb,
  difficulty_baseline numeric(4,2) NOT NULL DEFAULT 1.0
);

CREATE TABLE public.uldp_simulation_axis_validity (
  uldp_simulation_id uuid NOT NULL,
  axis text NOT NULL,
  validity numeric(3,2) NOT NULL DEFAULT 0.6,
  difficulty numeric(3,2),
  reviewed_by uuid,
  updated_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE public.uldp_validity_changelog (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  uldp_simulation_id uuid NOT NULL,
  axis text NOT NULL,
  previous_validity numeric(3,2),
  new_validity numeric(3,2) NOT NULL,
  previous_difficulty numeric(3,2),
  new_difficulty numeric(3,2),
  rationale text NOT NULL,
  changed_by uuid NOT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE public.uldp_simulation_grants (
  org_id uuid NOT NULL,
  external_sim_id text NOT NULL,
  granted_by uuid,
  granted_at timestamp with time zone NOT NULL DEFAULT now()
);

-- uldp_decision_events: primary ULDP telemetry event, partitioned monthly on
-- created_at, managed by pg_partman. No primary key (append-only log) —
-- matches live state.
CREATE TABLE public.uldp_decision_events (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  event_id uuid NOT NULL,
  event_version text NOT NULL,
  learner_id uuid NOT NULL,
  session_id uuid NOT NULL,
  cohort_id uuid NOT NULL,
  uldp_simulation_id uuid NOT NULL,
  round_number integer NOT NULL,
  total_rounds integer,
  option_id text,
  option_risk_exposure numeric(4,3),
  confidence numeric(4,3),
  latency_ms integer NOT NULL,
  domain_score numeric(6,4) NOT NULL,
  outcome_success boolean,
  decision_context jsonb,
  information_behavior jsonb,
  rationale_text text,
  strategic_vector jsonb,
  decision_changed_after_info boolean,
  revision_count integer,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  decision_type text,
  peer_consultation_events integer,
  context_tag text[] NOT NULL DEFAULT '{}'::text[],
  context_hash text,
  context_stability_flag text,
  submission_trigger text NOT NULL DEFAULT 'learner'::text,
  selection_state text NOT NULL DEFAULT 'complete'::text
) PARTITION BY RANGE (created_at);

CREATE TABLE public.uldp_decision_events_p20260801 PARTITION OF public.uldp_decision_events
  FOR VALUES FROM ('2026-08-01 00:00:00+00') TO ('2026-09-01 00:00:00+00');
CREATE TABLE public.uldp_decision_events_p20260901 PARTITION OF public.uldp_decision_events
  FOR VALUES FROM ('2026-09-01 00:00:00+00') TO ('2026-10-01 00:00:00+00');
CREATE TABLE public.uldp_decision_events_p20261001 PARTITION OF public.uldp_decision_events
  FOR VALUES FROM ('2026-10-01 00:00:00+00') TO ('2026-11-01 00:00:00+00');
CREATE TABLE public.uldp_decision_events_p20261101 PARTITION OF public.uldp_decision_events
  FOR VALUES FROM ('2026-11-01 00:00:00+00') TO ('2026-12-01 00:00:00+00');
CREATE TABLE public.uldp_decision_events_p20261201 PARTITION OF public.uldp_decision_events
  FOR VALUES FROM ('2026-12-01 00:00:00+00') TO ('2027-01-01 00:00:00+00');
CREATE TABLE public.uldp_decision_events_default PARTITION OF public.uldp_decision_events DEFAULT;

CREATE TABLE public.uldp_event_dedup (
  event_id uuid NOT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE public.uldp_info_access_events (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  session_id uuid NOT NULL,
  learner_id uuid NOT NULL,
  uldp_simulation_id uuid NOT NULL,
  source_id text NOT NULL,
  category text,
  time_ms integer,
  interactions integer,
  access_order integer,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE public.uldp_axis_scores (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  decision_event_id uuid NOT NULL,
  learner_id uuid NOT NULL,
  axis text NOT NULL,
  raw_value numeric NOT NULL,
  weight_at_computation numeric NOT NULL,
  formula_version text NOT NULL,
  computed_at timestamp with time zone NOT NULL DEFAULT now(),
  normalized_value numeric
);

CREATE TABLE public.uldp_profiles (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  learner_id uuid NOT NULL,
  org_id uuid,
  axis_scores jsonb NOT NULL DEFAULT '{}'::jsonb,
  composite_indices jsonb,
  profile_confidence_score numeric,
  sessions_counted integer NOT NULL DEFAULT 0,
  last_realtime_update_at timestamp with time zone,
  last_batch_update_at timestamp with time zone,
  last_nightly_recalc_at timestamp with time zone,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE public.uldp_archetype_profiles (
  learner_id uuid NOT NULL,
  archetype_slug text NOT NULL,
  axis_scores jsonb NOT NULL DEFAULT '{}'::jsonb,
  observation_count integer NOT NULL DEFAULT 0,
  last_updated_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE public.uldp_overrides (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  learner_id uuid NOT NULL,
  axis text NOT NULL,
  original_value numeric NOT NULL,
  override_value numeric NOT NULL,
  reason text NOT NULL,
  overridden_by uuid NOT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE public.uldp_coaching_events (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  learner_id uuid NOT NULL,
  session_id uuid,
  trigger_type text,
  trigger_payload jsonb,
  narrative text,
  recommendation jsonb,
  delivery_channel text,
  delivered_at timestamp with time zone,
  facilitator_ack_at timestamp with time zone,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE public.uldp_composite_recalc_jobs (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  job_type text NOT NULL,
  status text NOT NULL DEFAULT 'queued'::text,
  scope jsonb,
  total_tasks integer NOT NULL DEFAULT 0,
  completed_tasks integer NOT NULL DEFAULT 0,
  failed_tasks integer NOT NULL DEFAULT 0,
  started_at timestamp with time zone,
  completed_at timestamp with time zone,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);


-- ============================================================================
-- 8. TABLES — PLATFORM / AUDIT / DETECTION
-- ============================================================================

CREATE TABLE public.audit_logs (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  actor_id uuid,
  actor_role text NOT NULL,
  action text NOT NULL,
  resource_type text NOT NULL,
  resource_id uuid,
  before_state jsonb,
  after_state jsonb,
  ip_address inet,
  user_agent text,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE public.llm_usage_logs (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  org_id uuid,
  cohort_id uuid,
  session_id uuid,
  purpose text NOT NULL,
  model text NOT NULL,
  input_tokens integer NOT NULL DEFAULT 0,
  output_tokens integer NOT NULL DEFAULT 0,
  cost_usd numeric(10,6) NOT NULL DEFAULT 0,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE public.platform_metrics (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  period_start date NOT NULL,
  period_end date NOT NULL,
  metric_key text NOT NULL,
  metric_value numeric(14,4) NOT NULL,
  numerator integer,
  denominator integer,
  breakdown jsonb NOT NULL DEFAULT '{}'::jsonb,
  computed_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE public.friction_alerts (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  cohort_id uuid NOT NULL,
  alert_type text NOT NULL,
  affected_learner_ids uuid[] NOT NULL DEFAULT '{}'::uuid[],
  round_number integer,
  triggering_stats jsonb NOT NULL DEFAULT '{}'::jsonb,
  status text NOT NULL DEFAULT 'active'::text,
  feedback text,
  feedback_by uuid,
  acknowledged_at timestamp with time zone,
  acknowledged_by uuid,
  resolved_at timestamp with time zone,
  responding_command_id uuid,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);


-- ============================================================================
-- 9. pg_partman CONFIGURATION
-- ============================================================================
-- Monthly range partitions on created_at, premake=4, 24-month retention,
-- infinite time partitions. run_maintenance() runs daily at 2 AM UTC via
-- pg_cron (see cron section below).
SELECT partman.create_parent(
  p_parent_table => 'public.decision_events',
  p_control => 'created_at',
  p_type => 'range',
  p_interval => '1 mon',
  p_premake => 4
);
UPDATE partman.part_config
SET retention = '24 months', retention_keep_table = true, infinite_time_partitions = true
WHERE parent_table = 'public.decision_events';

SELECT partman.create_parent(
  p_parent_table => 'public.uldp_decision_events',
  p_control => 'created_at',
  p_type => 'range',
  p_interval => '1 mon',
  p_premake => 4
);
UPDATE partman.part_config
SET retention = '24 months', retention_keep_table = true, infinite_time_partitions = true
WHERE parent_table = 'public.uldp_decision_events';

SELECT cron.schedule('partman-maintenance', '0 2 * * *', $$SELECT partman.run_maintenance(p_analyze := FALSE)$$);


-- ============================================================================
-- 10. CONSTRAINTS — PASS A: PRIMARY KEY / UNIQUE / CHECK
-- ============================================================================
-- Depends only on the table itself existing. Constraints on decision_events
-- and uldp_decision_events (partitioned parents) auto-propagate to all
-- partitions — not redeclared per partition.

-- orgs
ALTER TABLE public.orgs ADD CONSTRAINT orgs_pkey PRIMARY KEY (id);
ALTER TABLE public.orgs ADD CONSTRAINT orgs_slug_key UNIQUE (slug);
ALTER TABLE public.orgs ADD CONSTRAINT orgs_stripe_customer_id_key UNIQUE (stripe_customer_id);
ALTER TABLE public.orgs ADD CONSTRAINT orgs_stripe_sub_id_key UNIQUE (stripe_sub_id);
ALTER TABLE public.orgs ADD CONSTRAINT orgs_billing_tier_check CHECK (billing_tier = ANY (ARRAY['free'::text, 'pro'::text, 'enterprise'::text]));
ALTER TABLE public.orgs ADD CONSTRAINT orgs_org_type_check CHECK (org_type = ANY (ARRAY['b2pro'::text, 'institutional'::text, 'enterprise'::text]));

-- users
ALTER TABLE public.users ADD CONSTRAINT users_pkey PRIMARY KEY (id);
ALTER TABLE public.users ADD CONSTRAINT users_clerk_user_id_key UNIQUE (clerk_user_id);
ALTER TABLE public.users ADD CONSTRAINT users_email_key UNIQUE (email);
ALTER TABLE public.users ADD CONSTRAINT users_role_check CHECK (role = ANY (ARRAY['b2pro_facilitator'::text, 'cohort_learner'::text, 'org_facilitator'::text, 'org_admin'::text, 'super_admin'::text]));

-- sim_registry
ALTER TABLE public.sim_registry ADD CONSTRAINT sim_registry_pkey PRIMARY KEY (id);
ALTER TABLE public.sim_registry ADD CONSTRAINT sim_registry_slug_key UNIQUE (slug);
ALTER TABLE public.sim_registry ADD CONSTRAINT sim_registry_calibration_status_check CHECK (calibration_status = ANY (ARRAY['seeded'::text, 'calibrating'::text, 'calibrated'::text]));

-- licence_pools
ALTER TABLE public.licence_pools ADD CONSTRAINT licence_pools_pkey PRIMARY KEY (id);
ALTER TABLE public.licence_pools ADD CONSTRAINT licence_pools_org_id_sim_id_key UNIQUE (org_id, sim_id);

-- modules
ALTER TABLE public.modules ADD CONSTRAINT modules_pkey PRIMARY KEY (id);

-- cohorts
ALTER TABLE public.cohorts ADD CONSTRAINT cohorts_pkey PRIMARY KEY (id);
ALTER TABLE public.cohorts ADD CONSTRAINT cohorts_pptx_status_check CHECK (pptx_status = ANY (ARRAY['none'::text, 'generating'::text, 'completed'::text, 'failed'::text]));

-- cohort_members
ALTER TABLE public.cohort_members ADD CONSTRAINT cohort_members_pkey PRIMARY KEY (id);

-- cohort_gates
ALTER TABLE public.cohort_gates ADD CONSTRAINT cohort_gates_pkey PRIMARY KEY (id);
ALTER TABLE public.cohort_gates ADD CONSTRAINT cohort_gates_cohort_id_round_number_key UNIQUE (cohort_id, round_number);

-- cohort_messages
ALTER TABLE public.cohort_messages ADD CONSTRAINT cohort_messages_pkey PRIMARY KEY (id);
ALTER TABLE public.cohort_messages ADD CONSTRAINT cohort_messages_target_check CHECK (target = ANY (ARRAY['all'::text, 'not_started'::text, 'not_completed'::text, 'completed'::text]));

-- org_invites
ALTER TABLE public.org_invites ADD CONSTRAINT org_invites_pkey PRIMARY KEY (id);
ALTER TABLE public.org_invites ADD CONSTRAINT org_invites_token_key UNIQUE (token);
ALTER TABLE public.org_invites ADD CONSTRAINT org_invites_status_check CHECK (status = ANY (ARRAY['pending'::text, 'accepted'::text, 'cancelled'::text, 'superseded'::text]));

-- sim_sessions
ALTER TABLE public.sim_sessions ADD CONSTRAINT sim_sessions_pkey PRIMARY KEY (id);
ALTER TABLE public.sim_sessions ADD CONSTRAINT sim_sessions_credential_id_key UNIQUE (credential_id);
ALTER TABLE public.sim_sessions ADD CONSTRAINT sim_sessions_completion_status_check CHECK (completion_status = ANY (ARRAY['in_progress'::text, 'completed'::text, 'abandoned'::text]));
ALTER TABLE public.sim_sessions ADD CONSTRAINT sim_sessions_debrief_status_check CHECK (debrief_status = ANY (ARRAY['none'::text, 'queued'::text, 'generating'::text, 'completed'::text, 'failed'::text]));
ALTER TABLE public.sim_sessions ADD CONSTRAINT sim_sessions_final_score_check CHECK (final_score >= 0 AND final_score <= 100);
ALTER TABLE public.sim_sessions ADD CONSTRAINT sim_sessions_meaningful_score_check CHECK (meaningful_score >= 0 AND meaningful_score <= 100);
ALTER TABLE public.sim_sessions ADD CONSTRAINT sim_sessions_percentile_rank_check CHECK (percentile_rank >= 0 AND percentile_rank <= 100);

-- badge_awards
ALTER TABLE public.badge_awards ADD CONSTRAINT badge_awards_pkey PRIMARY KEY (id);

-- event_dedup
ALTER TABLE public.event_dedup ADD CONSTRAINT event_dedup_pkey PRIMARY KEY (event_id);

-- session_commands
ALTER TABLE public.session_commands ADD CONSTRAINT session_commands_pkey PRIMARY KEY (id);
ALTER TABLE public.session_commands ADD CONSTRAINT session_commands_command_type_check CHECK (command_type = ANY (ARRAY['end_round'::text, 'force_submit'::text, 'end_simulation'::text, 'emergency_stop'::text, 'emergency_release'::text, 'inject'::text, 'set_parameter'::text]));
ALTER TABLE public.session_commands ADD CONSTRAINT session_commands_target_scope_check CHECK (target_scope = ANY (ARRAY['cohort'::text, 'round'::text, 'session'::text]));
ALTER TABLE public.session_commands ADD CONSTRAINT session_commands_check CHECK (target_scope <> 'round'::text OR target_round IS NOT NULL);
ALTER TABLE public.session_commands ADD CONSTRAINT session_commands_check1 CHECK (target_scope <> 'session'::text OR target_session_id IS NOT NULL);

-- coach_notes
ALTER TABLE public.coach_notes ADD CONSTRAINT coach_notes_pkey PRIMARY KEY (id);

-- debrief_jobs
ALTER TABLE public.debrief_jobs ADD CONSTRAINT debrief_jobs_pkey PRIMARY KEY (id);
ALTER TABLE public.debrief_jobs ADD CONSTRAINT debrief_jobs_user_feedback_score_check CHECK (user_feedback_score = ANY (ARRAY[1, -1]));

-- decision_events (partitioned parent — propagates to all partitions)
ALTER TABLE public.decision_events ADD CONSTRAINT decision_events_event_type_check CHECK (event_type = ANY (ARRAY['decision_made'::text, 'asset_consumed'::text, 'decision_outcome'::text, 'first_interaction'::text]));

-- lms_installations
ALTER TABLE public.lms_installations ADD CONSTRAINT lms_installations_pkey PRIMARY KEY (id);
ALTER TABLE public.lms_installations ADD CONSTRAINT lms_installations_client_id_key UNIQUE (client_id);
ALTER TABLE public.lms_installations ADD CONSTRAINT lms_installations_grade_scale_check CHECK (grade_scale = ANY (ARRAY['proportion'::text, 'percent'::text]));
ALTER TABLE public.lms_installations ADD CONSTRAINT lms_installations_platform_name_check CHECK (platform_name = ANY (ARRAY['canvas'::text, 'blackboard'::text, 'moodle'::text, 'd2l'::text, 'other'::text]));

-- lms_context_cohorts
ALTER TABLE public.lms_context_cohorts ADD CONSTRAINT lms_context_cohorts_pkey PRIMARY KEY (id);
ALTER TABLE public.lms_context_cohorts ADD CONSTRAINT lms_context_cohorts_installation_id_context_id_key UNIQUE (installation_id, context_id);

-- lti_identities
ALTER TABLE public.lti_identities ADD CONSTRAINT lti_identities_pkey PRIMARY KEY (id);
ALTER TABLE public.lti_identities ADD CONSTRAINT lti_identities_installation_id_lti_sub_key UNIQUE (installation_id, lti_sub);

-- session_engagement_evaluations
ALTER TABLE public.session_engagement_evaluations ADD CONSTRAINT session_engagement_evaluations_pkey PRIMARY KEY (id);
ALTER TABLE public.session_engagement_evaluations ADD CONSTRAINT session_engagement_evaluations_evaluation_id_key UNIQUE (evaluation_id);
ALTER TABLE public.session_engagement_evaluations ADD CONSTRAINT session_engagement_evaluations_confidence_check CHECK (confidence >= 0::numeric AND confidence <= 1::numeric);
ALTER TABLE public.session_engagement_evaluations ADD CONSTRAINT session_engagement_evaluations_meaningful_score_check CHECK (meaningful_score >= 0 AND meaningful_score <= 100);
ALTER TABLE public.session_engagement_evaluations ADD CONSTRAINT session_engagement_evaluations_threshold_check CHECK (threshold >= 0 AND threshold <= 100);
ALTER TABLE public.session_engagement_evaluations ADD CONSTRAINT session_engagement_evaluations_threshold_type_check CHECK (threshold_type = ANY (ARRAY['global'::text, 'cohort_adjusted'::text]));

-- engagement_evaluation_overrides
ALTER TABLE public.engagement_evaluation_overrides ADD CONSTRAINT engagement_evaluation_overrides_pkey PRIMARY KEY (id);
ALTER TABLE public.engagement_evaluation_overrides ADD CONSTRAINT engagement_evaluation_overrides_reason_check CHECK (length(TRIM(BOTH FROM reason)) >= 10);

-- sim_api_keys
ALTER TABLE public.sim_api_keys ADD CONSTRAINT sim_api_keys_pkey PRIMARY KEY (id);
ALTER TABLE public.sim_api_keys ADD CONSTRAINT sim_api_keys_key_hash_key UNIQUE (key_hash);
ALTER TABLE public.sim_api_keys ADD CONSTRAINT sim_api_keys_environment_check CHECK (environment = ANY (ARRAY['staging'::text, 'production'::text]));

-- sim_webhooks
ALTER TABLE public.sim_webhooks ADD CONSTRAINT sim_webhooks_pkey PRIMARY KEY (id);
ALTER TABLE public.sim_webhooks ADD CONSTRAINT sim_webhooks_environment_check CHECK (environment = ANY (ARRAY['staging'::text, 'production'::text]));
ALTER TABLE public.sim_webhooks ADD CONSTRAINT sim_webhooks_url_check CHECK (url ~ '^https://'::text);

-- uldp_priors
ALTER TABLE public.uldp_priors ADD CONSTRAINT uldp_priors_pkey PRIMARY KEY (axis);
ALTER TABLE public.uldp_priors ADD CONSTRAINT uldp_priors_axis_check CHECK (axis = ANY (ARRAY['RISK'::text, 'SPEED'::text, 'CONSIST'::text, 'COMP'::text, 'ADAPT'::text, 'INFO'::text, 'CALIB'::text]));

-- uldp_archetypes
ALTER TABLE public.uldp_archetypes ADD CONSTRAINT uldp_archetypes_pkey PRIMARY KEY (slug);

-- uldp_simulations
ALTER TABLE public.uldp_simulations ADD CONSTRAINT uldp_simulations_pkey PRIMARY KEY (id);
ALTER TABLE public.uldp_simulations ADD CONSTRAINT uldp_simulations_external_sim_id_version_key UNIQUE (external_sim_id, version);
ALTER TABLE public.uldp_simulations ADD CONSTRAINT uldp_simulations_complexity_index_check CHECK (complexity_index >= 1 AND complexity_index <= 5);
ALTER TABLE public.uldp_simulations ADD CONSTRAINT uldp_simulations_domain_check CHECK (domain = ANY (ARRAY['financial'::text, 'leadership'::text, 'product'::text, 'digital_transformation'::text, 'macroeconomic'::text]));

-- uldp_simulation_axis_validity
ALTER TABLE public.uldp_simulation_axis_validity ADD CONSTRAINT uldp_simulation_axis_validity_pkey PRIMARY KEY (uldp_simulation_id, axis);
ALTER TABLE public.uldp_simulation_axis_validity ADD CONSTRAINT uldp_simulation_axis_validity_axis_check CHECK (axis = ANY (ARRAY['RISK'::text, 'SPEED'::text, 'CONSIST'::text, 'COMP'::text, 'ADAPT'::text, 'INFO'::text, 'CALIB'::text]));
ALTER TABLE public.uldp_simulation_axis_validity ADD CONSTRAINT uldp_simulation_axis_validity_difficulty_check CHECK (difficulty IS NULL OR (difficulty >= 0::numeric AND difficulty <= 1::numeric));
ALTER TABLE public.uldp_simulation_axis_validity ADD CONSTRAINT uldp_simulation_axis_validity_validity_check CHECK (validity >= 0::numeric AND validity <= 1::numeric);

-- uldp_validity_changelog
ALTER TABLE public.uldp_validity_changelog ADD CONSTRAINT uldp_validity_changelog_pkey PRIMARY KEY (id);
ALTER TABLE public.uldp_validity_changelog ADD CONSTRAINT uldp_validity_changelog_axis_check CHECK (axis = ANY (ARRAY['RISK'::text, 'SPEED'::text, 'CONSIST'::text, 'COMP'::text, 'ADAPT'::text, 'INFO'::text, 'CALIB'::text]));

-- uldp_simulation_grants
ALTER TABLE public.uldp_simulation_grants ADD CONSTRAINT uldp_simulation_grants_pkey PRIMARY KEY (org_id, external_sim_id);

-- uldp_decision_events (partitioned parent — propagates to all partitions)
ALTER TABLE public.uldp_decision_events ADD CONSTRAINT uldp_decision_events_confidence_check CHECK (confidence IS NULL OR (confidence >= 0::numeric AND confidence <= 1::numeric));
ALTER TABLE public.uldp_decision_events ADD CONSTRAINT uldp_decision_events_context_stability_flag_check CHECK (context_stability_flag IS NULL OR context_stability_flag = ANY (ARRAY['stable'::text, 'transition'::text, 'disrupted'::text]));
ALTER TABLE public.uldp_decision_events ADD CONSTRAINT uldp_decision_events_decision_type_check CHECK (decision_type IS NULL OR decision_type = ANY (ARRAY['algorithmic'::text, 'judgmental'::text, 'negotiated'::text]));
ALTER TABLE public.uldp_decision_events ADD CONSTRAINT uldp_decision_events_null_choice_chk CHECK ((submission_trigger = 'facilitator_forced'::text AND selection_state <> 'complete'::text) OR (option_id IS NOT NULL AND option_risk_exposure IS NOT NULL));
ALTER TABLE public.uldp_decision_events ADD CONSTRAINT uldp_decision_events_option_risk_exposure_check CHECK (option_risk_exposure >= 0::numeric AND option_risk_exposure <= 1::numeric);
ALTER TABLE public.uldp_decision_events ADD CONSTRAINT uldp_decision_events_selection_state_chk CHECK (selection_state = ANY (ARRAY['none'::text, 'partial'::text, 'complete'::text]));
ALTER TABLE public.uldp_decision_events ADD CONSTRAINT uldp_decision_events_submission_trigger_chk CHECK (submission_trigger = ANY (ARRAY['learner'::text, 'facilitator_forced'::text]));

-- uldp_event_dedup
ALTER TABLE public.uldp_event_dedup ADD CONSTRAINT uldp_event_dedup_pkey PRIMARY KEY (event_id);

-- uldp_info_access_events
ALTER TABLE public.uldp_info_access_events ADD CONSTRAINT uldp_info_access_events_pkey PRIMARY KEY (id);

-- uldp_axis_scores
ALTER TABLE public.uldp_axis_scores ADD CONSTRAINT uldp_axis_scores_pkey PRIMARY KEY (id);
ALTER TABLE public.uldp_axis_scores ADD CONSTRAINT uldp_axis_scores_axis_check CHECK (axis = ANY (ARRAY['RISK'::text, 'SPEED'::text, 'CONSIST'::text, 'COMP'::text, 'ADAPT'::text, 'INFO'::text, 'CALIB'::text]));

-- uldp_profiles
ALTER TABLE public.uldp_profiles ADD CONSTRAINT uldp_profiles_pkey PRIMARY KEY (id);
ALTER TABLE public.uldp_profiles ADD CONSTRAINT uldp_profiles_learner_id_key UNIQUE (learner_id);

-- uldp_archetype_profiles
ALTER TABLE public.uldp_archetype_profiles ADD CONSTRAINT uldp_archetype_profiles_pkey PRIMARY KEY (learner_id, archetype_slug);

-- uldp_overrides
ALTER TABLE public.uldp_overrides ADD CONSTRAINT uldp_overrides_pkey PRIMARY KEY (id);
ALTER TABLE public.uldp_overrides ADD CONSTRAINT uldp_overrides_axis_check CHECK (axis = ANY (ARRAY['RISK'::text, 'SPEED'::text, 'CONSIST'::text, 'COMP'::text, 'ADAPT'::text, 'INFO'::text, 'CALIB'::text]));
ALTER TABLE public.uldp_overrides ADD CONSTRAINT uldp_overrides_override_value_check CHECK (override_value >= 0::numeric AND override_value <= 100::numeric);

-- uldp_coaching_events
ALTER TABLE public.uldp_coaching_events ADD CONSTRAINT uldp_coaching_events_pkey PRIMARY KEY (id);

-- uldp_composite_recalc_jobs
ALTER TABLE public.uldp_composite_recalc_jobs ADD CONSTRAINT uldp_composite_recalc_jobs_pkey PRIMARY KEY (id);
ALTER TABLE public.uldp_composite_recalc_jobs ADD CONSTRAINT uldp_composite_recalc_jobs_job_type_check CHECK (job_type = ANY (ARRAY['batch_4h'::text, 'nightly_full'::text]));
ALTER TABLE public.uldp_composite_recalc_jobs ADD CONSTRAINT uldp_composite_recalc_jobs_status_check CHECK (status = ANY (ARRAY['queued'::text, 'processing'::text, 'completed'::text, 'failed'::text]));

-- audit_logs
ALTER TABLE public.audit_logs ADD CONSTRAINT audit_logs_pkey PRIMARY KEY (id);

-- llm_usage_logs
ALTER TABLE public.llm_usage_logs ADD CONSTRAINT llm_usage_logs_pkey PRIMARY KEY (id);
ALTER TABLE public.llm_usage_logs ADD CONSTRAINT llm_usage_logs_purpose_check CHECK (purpose = ANY (ARRAY['student_debrief'::text, 'class_debrief'::text, 'share_card'::text, 'discussion_questions'::text, 'batch_consolidation'::text]));

-- platform_metrics
ALTER TABLE public.platform_metrics ADD CONSTRAINT platform_metrics_pkey PRIMARY KEY (id);

-- friction_alerts
ALTER TABLE public.friction_alerts ADD CONSTRAINT friction_alerts_pkey PRIMARY KEY (id);
ALTER TABLE public.friction_alerts ADD CONSTRAINT friction_alerts_alert_type_check CHECK (alert_type = ANY (ARRAY['analysis_paralysis'::text, 'reckless_drift'::text, 'groupthink'::text, 'disengagement'::text]));
ALTER TABLE public.friction_alerts ADD CONSTRAINT friction_alerts_feedback_check CHECK (feedback IS NULL OR feedback = ANY (ARRAY['valid'::text, 'false_positive'::text]));
ALTER TABLE public.friction_alerts ADD CONSTRAINT friction_alerts_status_check CHECK (status = ANY (ARRAY['active'::text, 'acknowledged'::text, 'resolved'::text]));


-- ============================================================================
-- 11. CONSTRAINTS — PASS B: FOREIGN KEY
-- ============================================================================
-- Run after Pass A so referenced PK/UNIQUE constraints already exist.

ALTER TABLE public.users ADD CONSTRAINT users_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.orgs(id) ON DELETE SET NULL;
ALTER TABLE public.sim_registry ADD CONSTRAINT sim_registry_owner_org_id_fkey FOREIGN KEY (owner_org_id) REFERENCES public.orgs(id);
ALTER TABLE public.licence_pools ADD CONSTRAINT licence_pools_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.orgs(id) ON DELETE CASCADE;
ALTER TABLE public.licence_pools ADD CONSTRAINT licence_pools_sim_id_fkey FOREIGN KEY (sim_id) REFERENCES public.sim_registry(id);
ALTER TABLE public.modules ADD CONSTRAINT modules_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.orgs(id) ON DELETE CASCADE;
ALTER TABLE public.modules ADD CONSTRAINT modules_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id) ON DELETE SET NULL;

ALTER TABLE public.cohorts ADD CONSTRAINT cohorts_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.orgs(id) ON DELETE CASCADE;
ALTER TABLE public.cohorts ADD CONSTRAINT cohorts_sim_id_fkey FOREIGN KEY (sim_id) REFERENCES public.sim_registry(id);
ALTER TABLE public.cohorts ADD CONSTRAINT cohorts_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id) ON DELETE SET NULL;
ALTER TABLE public.cohort_members ADD CONSTRAINT cohort_members_cohort_id_fkey FOREIGN KEY (cohort_id) REFERENCES public.cohorts(id) ON DELETE CASCADE;
ALTER TABLE public.cohort_members ADD CONSTRAINT cohort_members_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE SET NULL;
ALTER TABLE public.cohort_gates ADD CONSTRAINT cohort_gates_cohort_id_fkey FOREIGN KEY (cohort_id) REFERENCES public.cohorts(id) ON DELETE CASCADE;
ALTER TABLE public.cohort_gates ADD CONSTRAINT cohort_gates_opened_by_fkey FOREIGN KEY (opened_by) REFERENCES public.users(id);
ALTER TABLE public.cohort_gates ADD CONSTRAINT cohort_gates_closed_by_fkey FOREIGN KEY (closed_by) REFERENCES public.users(id);
ALTER TABLE public.cohort_messages ADD CONSTRAINT cohort_messages_cohort_id_fkey FOREIGN KEY (cohort_id) REFERENCES public.cohorts(id) ON DELETE CASCADE;
ALTER TABLE public.cohort_messages ADD CONSTRAINT cohort_messages_sent_by_fkey FOREIGN KEY (sent_by) REFERENCES public.users(id);
ALTER TABLE public.org_invites ADD CONSTRAINT org_invites_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.orgs(id) ON DELETE CASCADE;
ALTER TABLE public.org_invites ADD CONSTRAINT org_invites_cohort_id_fkey FOREIGN KEY (cohort_id) REFERENCES public.cohorts(id);
ALTER TABLE public.org_invites ADD CONSTRAINT org_invites_invited_by_fkey FOREIGN KEY (invited_by) REFERENCES public.users(id);

ALTER TABLE public.sim_sessions ADD CONSTRAINT sim_sessions_cohort_id_fkey FOREIGN KEY (cohort_id) REFERENCES public.cohorts(id) ON DELETE CASCADE;
ALTER TABLE public.sim_sessions ADD CONSTRAINT sim_sessions_sim_id_fkey FOREIGN KEY (sim_id) REFERENCES public.sim_registry(id);
ALTER TABLE public.sim_sessions ADD CONSTRAINT sim_sessions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE SET NULL;
ALTER TABLE public.sim_sessions ADD CONSTRAINT sim_sessions_referrer_user_id_fkey FOREIGN KEY (referrer_user_id) REFERENCES public.users(id);
-- lti_context_id FK added after lms_context_cohorts exists (see below).

ALTER TABLE public.badge_awards ADD CONSTRAINT badge_awards_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;
ALTER TABLE public.badge_awards ADD CONSTRAINT badge_awards_session_id_fkey FOREIGN KEY (session_id) REFERENCES public.sim_sessions(id) ON DELETE SET NULL;

ALTER TABLE public.session_commands ADD CONSTRAINT session_commands_cohort_id_fkey FOREIGN KEY (cohort_id) REFERENCES public.cohorts(id) ON DELETE CASCADE;
ALTER TABLE public.session_commands ADD CONSTRAINT session_commands_issued_by_fkey FOREIGN KEY (issued_by) REFERENCES public.users(id);
ALTER TABLE public.session_commands ADD CONSTRAINT session_commands_released_by_fkey FOREIGN KEY (released_by) REFERENCES public.users(id);
ALTER TABLE public.session_commands ADD CONSTRAINT session_commands_target_session_id_fkey FOREIGN KEY (target_session_id) REFERENCES public.sim_sessions(id) ON DELETE SET NULL;

ALTER TABLE public.coach_notes ADD CONSTRAINT coach_notes_cohort_id_fkey FOREIGN KEY (cohort_id) REFERENCES public.cohorts(id) ON DELETE CASCADE;
ALTER TABLE public.coach_notes ADD CONSTRAINT coach_notes_session_id_fkey FOREIGN KEY (session_id) REFERENCES public.sim_sessions(id) ON DELETE CASCADE;
ALTER TABLE public.coach_notes ADD CONSTRAINT coach_notes_learner_id_fkey FOREIGN KEY (learner_id) REFERENCES public.users(id);
ALTER TABLE public.coach_notes ADD CONSTRAINT coach_notes_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);

ALTER TABLE public.debrief_jobs ADD CONSTRAINT debrief_jobs_cohort_id_fkey FOREIGN KEY (cohort_id) REFERENCES public.cohorts(id) ON DELETE CASCADE;
ALTER TABLE public.debrief_jobs ADD CONSTRAINT debrief_jobs_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);
ALTER TABLE public.debrief_jobs ADD CONSTRAINT debrief_jobs_first_downloaded_by_fkey FOREIGN KEY (first_downloaded_by) REFERENCES public.users(id) ON DELETE SET NULL;
ALTER TABLE public.cohorts ADD CONSTRAINT cohorts_current_debrief_job_fk FOREIGN KEY (current_debrief_job_id) REFERENCES public.debrief_jobs(id);

ALTER TABLE public.decision_events ADD CONSTRAINT decision_events_session_fk FOREIGN KEY (session_id) REFERENCES public.sim_sessions(id);

ALTER TABLE public.lms_installations ADD CONSTRAINT lms_installations_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.orgs(id) ON DELETE CASCADE;
ALTER TABLE public.lms_context_cohorts ADD CONSTRAINT lms_context_cohorts_installation_id_fkey FOREIGN KEY (installation_id) REFERENCES public.lms_installations(id) ON DELETE CASCADE;
ALTER TABLE public.lms_context_cohorts ADD CONSTRAINT lms_context_cohorts_cohort_id_fkey FOREIGN KEY (cohort_id) REFERENCES public.cohorts(id);
ALTER TABLE public.lms_context_cohorts ADD CONSTRAINT lms_context_cohorts_sim_id_fkey FOREIGN KEY (sim_id) REFERENCES public.sim_registry(id);
ALTER TABLE public.lti_identities ADD CONSTRAINT lti_identities_installation_id_fkey FOREIGN KEY (installation_id) REFERENCES public.lms_installations(id) ON DELETE CASCADE;
ALTER TABLE public.lti_identities ADD CONSTRAINT lti_identities_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);
ALTER TABLE public.sim_sessions ADD CONSTRAINT sim_sessions_lti_context_id_fkey FOREIGN KEY (lti_context_id) REFERENCES public.lms_context_cohorts(id);

ALTER TABLE public.session_engagement_evaluations ADD CONSTRAINT session_engagement_evaluations_session_id_fkey FOREIGN KEY (session_id) REFERENCES public.sim_sessions(id) ON DELETE CASCADE;
ALTER TABLE public.engagement_evaluation_overrides ADD CONSTRAINT engagement_evaluation_overrides_session_id_fkey FOREIGN KEY (session_id) REFERENCES public.sim_sessions(id) ON DELETE CASCADE;
ALTER TABLE public.engagement_evaluation_overrides ADD CONSTRAINT engagement_evaluation_overrides_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);
ALTER TABLE public.engagement_evaluation_overrides ADD CONSTRAINT engagement_evaluation_overrides_revoked_by_fkey FOREIGN KEY (revoked_by) REFERENCES public.users(id);
ALTER TABLE public.sim_api_keys ADD CONSTRAINT sim_api_keys_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id) ON DELETE SET NULL;
ALTER TABLE public.session_engagement_evaluations ADD CONSTRAINT session_engagement_evaluations_source_api_key_id_fkey FOREIGN KEY (source_api_key_id) REFERENCES public.sim_api_keys(id) ON DELETE SET NULL;
ALTER TABLE public.sim_webhooks ADD CONSTRAINT sim_webhooks_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id) ON DELETE SET NULL;

ALTER TABLE public.uldp_archetype_profiles ADD CONSTRAINT uldp_archetype_profiles_archetype_slug_fkey FOREIGN KEY (archetype_slug) REFERENCES public.uldp_archetypes(slug);
ALTER TABLE public.uldp_archetype_profiles ADD CONSTRAINT uldp_archetype_profiles_learner_id_fkey FOREIGN KEY (learner_id) REFERENCES public.users(id);
ALTER TABLE public.uldp_simulations ADD CONSTRAINT uldp_simulations_registered_by_fkey FOREIGN KEY (registered_by) REFERENCES public.users(id);
ALTER TABLE public.uldp_simulation_axis_validity ADD CONSTRAINT uldp_simulation_axis_validity_uldp_simulation_id_fkey FOREIGN KEY (uldp_simulation_id) REFERENCES public.uldp_simulations(id) ON DELETE CASCADE;
ALTER TABLE public.uldp_simulation_axis_validity ADD CONSTRAINT uldp_simulation_axis_validity_reviewed_by_fkey FOREIGN KEY (reviewed_by) REFERENCES public.users(id);
ALTER TABLE public.uldp_validity_changelog ADD CONSTRAINT uldp_validity_changelog_uldp_simulation_id_fkey FOREIGN KEY (uldp_simulation_id) REFERENCES public.uldp_simulations(id) ON DELETE CASCADE;
ALTER TABLE public.uldp_validity_changelog ADD CONSTRAINT uldp_validity_changelog_changed_by_fkey FOREIGN KEY (changed_by) REFERENCES public.users(id);
ALTER TABLE public.uldp_simulation_grants ADD CONSTRAINT uldp_simulation_grants_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.orgs(id) ON DELETE CASCADE;
ALTER TABLE public.uldp_simulation_grants ADD CONSTRAINT uldp_simulation_grants_granted_by_fkey FOREIGN KEY (granted_by) REFERENCES public.users(id);

ALTER TABLE public.uldp_decision_events ADD CONSTRAINT uldp_decision_events_cohort_fk FOREIGN KEY (cohort_id) REFERENCES public.cohorts(id);
ALTER TABLE public.uldp_decision_events ADD CONSTRAINT uldp_decision_events_learner_fk FOREIGN KEY (learner_id) REFERENCES public.users(id);
ALTER TABLE public.uldp_decision_events ADD CONSTRAINT uldp_decision_events_session_fk FOREIGN KEY (session_id) REFERENCES public.sim_sessions(id);
ALTER TABLE public.uldp_decision_events ADD CONSTRAINT uldp_decision_events_uldp_simulation_id_fkey FOREIGN KEY (uldp_simulation_id) REFERENCES public.uldp_simulations(id);

ALTER TABLE public.uldp_info_access_events ADD CONSTRAINT uldp_info_access_events_session_id_fkey FOREIGN KEY (session_id) REFERENCES public.sim_sessions(id);
ALTER TABLE public.uldp_info_access_events ADD CONSTRAINT uldp_info_access_events_learner_id_fkey FOREIGN KEY (learner_id) REFERENCES public.users(id);
ALTER TABLE public.uldp_info_access_events ADD CONSTRAINT uldp_info_access_events_uldp_simulation_id_fkey FOREIGN KEY (uldp_simulation_id) REFERENCES public.uldp_simulations(id);

ALTER TABLE public.uldp_axis_scores ADD CONSTRAINT uldp_axis_scores_learner_id_fkey FOREIGN KEY (learner_id) REFERENCES public.users(id);

ALTER TABLE public.uldp_profiles ADD CONSTRAINT uldp_profiles_learner_id_fkey FOREIGN KEY (learner_id) REFERENCES public.users(id);
ALTER TABLE public.uldp_profiles ADD CONSTRAINT uldp_profiles_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.orgs(id);

ALTER TABLE public.uldp_overrides ADD CONSTRAINT uldp_overrides_learner_id_fkey FOREIGN KEY (learner_id) REFERENCES public.users(id);
ALTER TABLE public.uldp_overrides ADD CONSTRAINT uldp_overrides_overridden_by_fkey FOREIGN KEY (overridden_by) REFERENCES public.users(id);

ALTER TABLE public.uldp_coaching_events ADD CONSTRAINT uldp_coaching_events_learner_id_fkey FOREIGN KEY (learner_id) REFERENCES public.users(id);
ALTER TABLE public.uldp_coaching_events ADD CONSTRAINT uldp_coaching_events_session_id_fkey FOREIGN KEY (session_id) REFERENCES public.sim_sessions(id);

ALTER TABLE public.audit_logs ADD CONSTRAINT audit_logs_actor_id_fkey FOREIGN KEY (actor_id) REFERENCES public.users(id) ON DELETE SET NULL;

ALTER TABLE public.llm_usage_logs ADD CONSTRAINT llm_usage_logs_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.orgs(id) ON DELETE SET NULL;
ALTER TABLE public.llm_usage_logs ADD CONSTRAINT llm_usage_logs_cohort_id_fkey FOREIGN KEY (cohort_id) REFERENCES public.cohorts(id) ON DELETE SET NULL;
ALTER TABLE public.llm_usage_logs ADD CONSTRAINT llm_usage_logs_session_id_fkey FOREIGN KEY (session_id) REFERENCES public.sim_sessions(id) ON DELETE SET NULL;

ALTER TABLE public.friction_alerts ADD CONSTRAINT friction_alerts_cohort_id_fkey FOREIGN KEY (cohort_id) REFERENCES public.cohorts(id) ON DELETE CASCADE;
ALTER TABLE public.friction_alerts ADD CONSTRAINT friction_alerts_acknowledged_by_fkey FOREIGN KEY (acknowledged_by) REFERENCES public.users(id);
ALTER TABLE public.friction_alerts ADD CONSTRAINT friction_alerts_feedback_by_fkey FOREIGN KEY (feedback_by) REFERENCES public.users(id);
ALTER TABLE public.friction_alerts ADD CONSTRAINT friction_alerts_responding_command_id_fkey FOREIGN KEY (responding_command_id) REFERENCES public.session_commands(id);


-- ============================================================================
-- 12. INDEXES
-- ============================================================================
-- (PK/UNIQUE constraints above already created their backing indexes;
-- these are the additional, hand-authored ones.)

CREATE INDEX idx_audit_logs_actor ON public.audit_logs USING btree (actor_id);
CREATE INDEX idx_audit_logs_created ON public.audit_logs USING btree (created_at);
CREATE INDEX idx_audit_logs_resource ON public.audit_logs USING btree (resource_type, resource_id);

CREATE INDEX idx_badge_awards_session ON public.badge_awards USING btree (session_id);
CREATE INDEX idx_badge_awards_user ON public.badge_awards USING btree (user_id);

CREATE INDEX idx_coach_notes_cohort ON public.coach_notes USING btree (cohort_id, created_at DESC);
CREATE INDEX idx_coach_notes_session ON public.coach_notes USING btree (session_id, round_number);

CREATE INDEX idx_cohort_gates_cohort ON public.cohort_gates USING btree (cohort_id);

CREATE UNIQUE INDEX idx_cohort_members_email ON public.cohort_members USING btree (cohort_id, email) WHERE (user_id IS NULL AND email IS NOT NULL);
CREATE UNIQUE INDEX idx_cohort_members_user ON public.cohort_members USING btree (cohort_id, user_id) WHERE (user_id IS NOT NULL);

CREATE INDEX idx_cohort_messages_cohort ON public.cohort_messages USING btree (cohort_id);

CREATE INDEX idx_cohorts_crd_delivered ON public.cohorts USING btree (crd_delivered_at) WHERE (crd_delivered_at IS NOT NULL AND is_demo = false);
CREATE INDEX idx_cohorts_created_by ON public.cohorts USING btree (created_by);
CREATE INDEX idx_cohorts_org_id ON public.cohorts USING btree (org_id);
CREATE INDEX idx_cohorts_sim_status ON public.cohorts USING btree (sim_status);
CREATE INDEX idx_cohorts_temperature_check ON public.cohorts USING btree (temperature_check_at) WHERE (temperature_check_at IS NOT NULL);

CREATE INDEX idx_debrief_jobs_cohort ON public.debrief_jobs USING btree (cohort_id);
CREATE INDEX idx_debrief_jobs_feedback ON public.debrief_jobs USING btree (user_feedback_score) WHERE (user_feedback_score IS NOT NULL);
CREATE INDEX idx_debrief_jobs_status ON public.debrief_jobs USING btree (status) WHERE (status = ANY (ARRAY['queued'::debrief_job_status, 'processing'::debrief_job_status, 'aggregating'::debrief_job_status]));

CREATE UNIQUE INDEX idx_engagement_override_active_session ON public.engagement_evaluation_overrides USING btree (session_id) WHERE (revoked_at IS NULL);
CREATE INDEX idx_engagement_override_session_history ON public.engagement_evaluation_overrides USING btree (session_id, created_at DESC);

CREATE INDEX event_dedup_created_at_idx ON public.event_dedup USING btree (created_at);

CREATE INDEX idx_friction_alerts_cohort_active ON public.friction_alerts USING btree (cohort_id, alert_type, created_at DESC) WHERE (status <> 'resolved'::text);

CREATE INDEX idx_licence_pools_org ON public.licence_pools USING btree (org_id);
CREATE INDEX idx_licence_pools_sim ON public.licence_pools USING btree (sim_id);

CREATE INDEX idx_llm_usage_cohort ON public.llm_usage_logs USING btree (cohort_id);
CREATE INDEX idx_llm_usage_org ON public.llm_usage_logs USING btree (org_id, created_at);

CREATE INDEX idx_lms_installations_client ON public.lms_installations USING btree (client_id);
CREATE INDEX idx_lms_installations_org ON public.lms_installations USING btree (org_id);

CREATE INDEX idx_lti_identities_user ON public.lti_identities USING btree (user_id);

CREATE INDEX idx_org_invites_email ON public.org_invites USING btree (email);
CREATE INDEX idx_org_invites_org ON public.org_invites USING btree (org_id);
CREATE INDEX idx_org_invites_status ON public.org_invites USING btree (status) WHERE (status = 'pending'::text);
CREATE INDEX idx_org_invites_token ON public.org_invites USING btree (token);

CREATE INDEX idx_orgs_billing_tier ON public.orgs USING btree (billing_tier);
CREATE INDEX idx_orgs_org_type ON public.orgs USING btree (org_type);

CREATE UNIQUE INDEX idx_platform_metrics_period_key ON public.platform_metrics USING btree (period_start, metric_key);
CREATE INDEX idx_platform_metrics_key_period ON public.platform_metrics USING btree (metric_key, period_start DESC);

CREATE INDEX idx_session_commands_cohort_type_time ON public.session_commands USING btree (cohort_id, command_type, issued_at DESC);
CREATE INDEX idx_session_commands_target_session ON public.session_commands USING btree (target_session_id, issued_at DESC) WHERE (target_session_id IS NOT NULL);
CREATE INDEX idx_session_commands_unreleased_emergency ON public.session_commands USING btree (cohort_id, issued_at DESC) WHERE (command_type = 'emergency_stop'::text AND released_at IS NULL);

CREATE UNIQUE INDEX idx_engagement_eval_current_session ON public.session_engagement_evaluations USING btree (session_id) WHERE is_current;
CREATE INDEX idx_engagement_eval_received ON public.session_engagement_evaluations USING btree (received_at DESC) WHERE is_current;
CREATE INDEX idx_engagement_eval_session_history ON public.session_engagement_evaluations USING btree (session_id, received_at DESC);

CREATE INDEX idx_sim_api_keys_scope ON public.sim_api_keys USING btree (external_sim_id, environment) WHERE (revoked_at IS NULL);

CREATE INDEX idx_sim_sessions_cohort ON public.sim_sessions USING btree (cohort_id);
CREATE INDEX idx_sim_sessions_completed ON public.sim_sessions USING btree (completed_at) WHERE (completed_at IS NOT NULL);
CREATE INDEX idx_sim_sessions_credential ON public.sim_sessions USING btree (credential_id) WHERE (credential_id IS NOT NULL);
CREATE INDEX idx_sim_sessions_lti_context ON public.sim_sessions USING btree (lti_context_id) WHERE (lti_context_id IS NOT NULL);
CREATE UNIQUE INDEX idx_sim_sessions_session_token ON public.sim_sessions USING btree (session_token);
CREATE INDEX idx_sim_sessions_status ON public.sim_sessions USING btree (completion_status);
CREATE INDEX idx_sim_sessions_user ON public.sim_sessions USING btree (user_id);

CREATE UNIQUE INDEX idx_sim_webhooks_active_scope ON public.sim_webhooks USING btree (external_sim_id, environment) WHERE active;

-- uldp_decision_events: declared once on the partitioned parent; Postgres
-- auto-creates matching indexes on every existing + future partition.
CREATE INDEX idx_uldp_decision_events_cohort_round ON public.uldp_decision_events USING btree (cohort_id, round_number);
CREATE INDEX idx_uldp_decision_events_context_hash ON public.uldp_decision_events USING btree (learner_id, context_hash) WHERE (context_hash IS NOT NULL);
CREATE INDEX idx_uldp_decision_events_learner ON public.uldp_decision_events USING btree (learner_id, created_at);
CREATE INDEX idx_uldp_decision_events_session ON public.uldp_decision_events USING btree (session_id);

CREATE INDEX idx_uldp_event_dedup_created_at ON public.uldp_event_dedup USING btree (created_at);

CREATE INDEX idx_uldp_info_access_learner ON public.uldp_info_access_events USING btree (learner_id, created_at);
CREATE INDEX idx_uldp_info_access_session ON public.uldp_info_access_events USING btree (session_id);

CREATE INDEX idx_uldp_axis_scores_event ON public.uldp_axis_scores USING btree (decision_event_id);
CREATE INDEX idx_uldp_axis_scores_learner ON public.uldp_axis_scores USING btree (learner_id, axis, computed_at);

CREATE INDEX idx_uldp_overrides_learner_axis ON public.uldp_overrides USING btree (learner_id, axis, created_at DESC);

CREATE INDEX idx_uldp_coaching_events_learner ON public.uldp_coaching_events USING btree (learner_id, created_at);

CREATE INDEX idx_uldp_composite_recalc_jobs_status ON public.uldp_composite_recalc_jobs USING btree (status) WHERE (status = ANY (ARRAY['queued'::text, 'processing'::text]));

CREATE INDEX idx_uldp_validity_changelog_sim ON public.uldp_validity_changelog USING btree (uldp_simulation_id, created_at DESC);

CREATE INDEX idx_users_clerk_user_id ON public.users USING btree (clerk_user_id);
CREATE INDEX idx_users_email ON public.users USING btree (email);
CREATE INDEX idx_users_org_id ON public.users USING btree (org_id);


-- ============================================================================
-- 13. FUNCTIONS
-- ============================================================================

-- JWT claim helpers. NOTE: despite CLAUDE.md referring to these conceptually
-- as "auth.org_id()"/"auth.app_role()", they live in the `public` schema on
-- the actual database (this is a snapshot of live reality, not a rename).
CREATE OR REPLACE FUNCTION public.org_id()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
  SELECT (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'org_id')::uuid
$function$;

CREATE OR REPLACE FUNCTION public.app_role()
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
  SELECT nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'app_role'
$function$;

-- Distinct from Supabase's built-in auth.uid() (reads the 'sub' claim) — this
-- platform mints its own HS256 JWT (fast-jwt + SUPABASE_JWT_SECRET, not a
-- Clerk JWT template) with a 'supabase_id' claim instead.
CREATE OR REPLACE FUNCTION public.uid()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
  SELECT (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'supabase_id')::uuid
$function$;

CREATE OR REPLACE FUNCTION public.my_org_cohort_ids()
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
  SELECT id FROM cohorts WHERE org_id = org_id()
$function$;

CREATE OR REPLACE FUNCTION public.my_enrolled_cohort_ids()
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
  SELECT cohort_id FROM cohort_members WHERE user_id = uid()
$function$;

CREATE OR REPLACE FUNCTION public.set_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.increment_cohorts_used(p_org_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  UPDATE orgs SET cohorts_used_total = cohorts_used_total + 1 WHERE id = p_org_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.increment_debrief_task(p_job_id uuid)
 RETURNS TABLE(completed_tasks integer, total_tasks integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  UPDATE debrief_jobs
  SET completed_tasks = completed_tasks + 1
  WHERE id = p_job_id;

  RETURN QUERY
    SELECT dj.completed_tasks, dj.total_tasks
    FROM debrief_jobs dj
    WHERE dj.id = p_job_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.increment_uldp_batch_task(p_job_id uuid, p_failed boolean DEFAULT false)
 RETURNS TABLE(completed_tasks integer, failed_tasks integer, total_tasks integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  IF p_failed THEN
    UPDATE uldp_composite_recalc_jobs
    SET failed_tasks = failed_tasks + 1
    WHERE id = p_job_id;
  ELSE
    UPDATE uldp_composite_recalc_jobs
    SET completed_tasks = completed_tasks + 1
    WHERE id = p_job_id;
  END IF;

  RETURN QUERY
    SELECT j.completed_tasks, j.failed_tasks, j.total_tasks
    FROM uldp_composite_recalc_jobs j
    WHERE j.id = p_job_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.anonymize_user(p_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  UPDATE users
  SET full_name     = NULL,
      email         = 'anon-' || p_user_id::text || '@deleted.invalid',
      clerk_user_id = NULL,
      updated_at    = NOW()
  WHERE id = p_user_id;

  DELETE FROM uldp_archetype_profiles WHERE learner_id = p_user_id;
  DELETE FROM uldp_profiles           WHERE learner_id = p_user_id;

  DELETE FROM engagement_evaluation_overrides
  WHERE session_id IN (SELECT id FROM sim_sessions WHERE user_id = p_user_id);

  DELETE FROM session_engagement_evaluations
  WHERE session_id IN (SELECT id FROM sim_sessions WHERE user_id = p_user_id);

  UPDATE sim_sessions
  SET is_meaningful = NULL, meaningful_score = NULL
  WHERE user_id = p_user_id;
END;
$function$;

-- write_completion(): called from lib/supabase.ts via createSupabaseAdmin()
-- (service role, RLS bypassed). credential_id is generated in TypeScript
-- (nanoid customAlphabet) BEFORE this call, passed in as a parameter — never
-- generated inside the RPC.
CREATE OR REPLACE FUNCTION public.write_completion(
  p_session_token text, p_credential_id text, p_final_score integer,
  p_meaningful_score integer, p_is_meaningful boolean, p_rounds_completed integer,
  p_decision_count integer, p_duration_mins integer, p_is_repeat_play boolean,
  p_consent_di_profiling boolean, p_badge_slugs text[], p_badge_names text[],
  p_badge_descriptions text[]
)
 RETURNS TABLE(credential_id text, session_id uuid, already_existed boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_session         sim_sessions%ROWTYPE;
  v_credential_id   TEXT;
  v_i               INTEGER;
BEGIN
  -- 1. Idempotency: resolve the session row.
  SELECT * INTO v_session
  FROM sim_sessions
  WHERE session_token = p_session_token
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'session_not_found' USING ERRCODE = 'P0001';
  END IF;

  IF v_session.credential_id IS NOT NULL THEN
    RETURN QUERY SELECT v_session.credential_id, v_session.id, TRUE;
    RETURN;
  END IF;

  -- 2. Reject incomplete sessions (rounds_completed < 1).
  IF p_rounds_completed < 1 THEN
    RAISE EXCEPTION 'insufficient_completion' USING ERRCODE = 'P0002';
  END IF;

  v_credential_id := p_credential_id;

  -- 3. UPDATE sim_sessions. archetype/archetype_slug/signal_breakdown columns
  -- removed (legacy DI engine retired) — this UPDATE no longer sets them.
  UPDATE sim_sessions SET
    completion_status   = 'completed',
    final_score          = p_final_score,
    meaningful_score      = p_meaningful_score,
    is_meaningful         = p_is_meaningful,
    rounds_completed      = p_rounds_completed,
    decision_count        = p_decision_count,
    duration_mins         = p_duration_mins,
    is_repeat_play        = p_is_repeat_play,
    credential_id         = v_credential_id,
    consent_di_profiling  = p_consent_di_profiling,
    completed_at          = NOW()
  WHERE id = v_session.id;

  -- 4. INSERT badge_awards (di_profiles UPSERT step removed).
  IF array_length(p_badge_slugs, 1) > 0 THEN
    FOR v_i IN 1 .. array_length(p_badge_slugs, 1) LOOP
      INSERT INTO badge_awards (user_id, session_id, slug, name, description)
      VALUES (
        v_session.user_id,
        v_session.id,
        p_badge_slugs[v_i],
        p_badge_names[v_i],
        COALESCE(p_badge_descriptions[v_i], '')
      )
      ON CONFLICT DO NOTHING;
    END LOOP;
  END IF;

  -- 5. Return.
  RETURN QUERY SELECT v_credential_id, v_session.id, FALSE;
END;
$function$;

-- uldp_ingest_decision(): the ULDP write path. Runs BEFORE the incremental
-- Bayesian update mirrored in lib/uldp/scoring/incremental.ts — keep the
-- PRIOR_WEIGHT=3 shrinkage formula in sync between the two if either changes.
CREATE OR REPLACE FUNCTION public.uldp_ingest_decision(
  p_event_id uuid, p_event_version text, p_learner_id uuid, p_session_id uuid,
  p_cohort_id uuid, p_org_id uuid, p_uldp_simulation_id uuid, p_round_number integer,
  p_total_rounds integer, p_option_id text, p_option_risk_exposure numeric,
  p_confidence numeric, p_latency_ms integer, p_domain_score numeric,
  p_outcome_success boolean, p_decision_context jsonb, p_information_behavior jsonb,
  p_rationale_text text, p_strategic_vector jsonb, p_decision_changed_after_info boolean,
  p_revision_count integer, p_axis_results jsonb, p_consent_di_profiling boolean,
  p_decision_type text DEFAULT NULL::text, p_peer_consultation_events integer DEFAULT NULL::integer,
  p_context_hash text DEFAULT NULL::text, p_submission_trigger text DEFAULT 'learner'::text,
  p_selection_state text DEFAULT 'complete'::text
)
 RETURNS TABLE(decision_event_id uuid, already_existed boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_decision_event_id UUID := gen_random_uuid();
  v_axis_result       JSONB;
  v_axis               TEXT;
  v_raw_value          NUMERIC;
  v_formula_version    TEXT;
  v_prior_mean         NUMERIC;
  v_min_observations   INTEGER;
  v_current_entry      JSONB;
  v_current_value      NUMERIC;
  v_current_n          INTEGER;
  v_new_n              INTEGER;
  v_new_value          NUMERIC;
  v_ci_half_width      NUMERIC;
  v_new_entry          JSONB;
  v_context_tag        TEXT[];
  v_context_stability_flag TEXT;
BEGIN
  -- 1. Idempotency.
  INSERT INTO uldp_event_dedup (event_id) VALUES (p_event_id) ON CONFLICT DO NOTHING;
  IF NOT FOUND THEN
    RETURN QUERY SELECT NULL::UUID, TRUE;
    RETURN;
  END IF;

  -- 1b. Context tagging (plan U6/F1) — platform-owned, computed here from
  -- session_commands, never client-supplied. Pragmatic MVP interpretation of
  -- spec §5.4's "next 3 decisions or round end" injection window: any
  -- inject/emergency_stop/end_round command for this cohort (matching scope),
  -- issued in the last 15 minutes and before this decision's timestamp. This
  -- is a time-window approximation, not a literal decision-count tracker —
  -- tune the interval/command-type set here if it proves too wide/narrow.
  SELECT COALESCE(array_agg(DISTINCT command_type), '{}')
  INTO v_context_tag
  FROM session_commands
  WHERE cohort_id = p_cohort_id
    AND command_type IN ('inject', 'emergency_stop', 'end_round')
    AND issued_at <= NOW()
    AND issued_at >= NOW() - INTERVAL '15 minutes'
    AND (
      target_scope = 'cohort'
      OR (target_scope = 'round'   AND target_round = p_round_number)
      OR (target_scope = 'session' AND target_session_id = p_session_id)
    );

  v_context_stability_flag := CASE WHEN array_length(v_context_tag, 1) > 0 THEN 'disrupted' ELSE 'stable' END;

  -- 2. INSERT uldp_decision_events.
  INSERT INTO uldp_decision_events (
    id, event_id, event_version, learner_id, session_id, cohort_id,
    uldp_simulation_id, round_number, total_rounds, option_id,
    option_risk_exposure, confidence, latency_ms, domain_score, outcome_success,
    decision_context, information_behavior, rationale_text, strategic_vector,
    decision_changed_after_info, revision_count,
    decision_type, peer_consultation_events, context_tag, context_hash, context_stability_flag,
    submission_trigger, selection_state
  ) VALUES (
    v_decision_event_id, p_event_id, p_event_version, p_learner_id, p_session_id, p_cohort_id,
    p_uldp_simulation_id, p_round_number, p_total_rounds, p_option_id,
    p_option_risk_exposure, p_confidence, p_latency_ms, p_domain_score, p_outcome_success,
    p_decision_context, p_information_behavior, p_rationale_text, p_strategic_vector,
    p_decision_changed_after_info, p_revision_count,
    p_decision_type, p_peer_consultation_events, v_context_tag, p_context_hash, v_context_stability_flag,
    p_submission_trigger, p_selection_state
  );

  -- 3. INSERT uldp_axis_scores (audit trail — one row per computed axis).
  FOR v_axis_result IN SELECT * FROM jsonb_array_elements(p_axis_results)
  LOOP
    INSERT INTO uldp_axis_scores (
      decision_event_id, learner_id, axis, raw_value, weight_at_computation, formula_version
    ) VALUES (
      v_decision_event_id,
      p_learner_id,
      v_axis_result ->> 'axis',
      (v_axis_result ->> 'raw_value')::NUMERIC,
      (v_axis_result ->> 'weight_at_computation')::NUMERIC,
      v_axis_result ->> 'formula_version'
    );
  END LOOP;

  -- 4. Incremental update of uldp_profiles.axis_scores.
  -- GDPR: skip entirely if consent not given — same rule the legacy
  -- di_profiles write enforced.
  IF p_consent_di_profiling THEN
    INSERT INTO uldp_profiles (learner_id, org_id)
    VALUES (p_learner_id, p_org_id)
    ON CONFLICT (learner_id) DO NOTHING;

    FOR v_axis_result IN SELECT * FROM jsonb_array_elements(p_axis_results)
    LOOP
      v_axis := v_axis_result ->> 'axis';
      v_raw_value := (v_axis_result ->> 'raw_value')::NUMERIC;
      v_formula_version := v_axis_result ->> 'formula_version';

      SELECT prior_mean, min_observations INTO v_prior_mean, v_min_observations
      FROM uldp_priors WHERE axis = v_axis;

      SELECT axis_scores -> v_axis INTO v_current_entry
      FROM uldp_profiles WHERE learner_id = p_learner_id;

      v_current_n := COALESCE((v_current_entry ->> 'n')::INTEGER, 0);
      v_current_value := COALESCE((v_current_entry ->> 'value')::NUMERIC, v_prior_mean);

      -- Same PRIOR_WEIGHT=3 shrinkage formula as lib/uldp/scoring/incremental.ts.
      v_new_n := v_current_n + 1;
      v_new_value := (
        (CASE WHEN v_current_n = 0 THEN v_prior_mean * 3 ELSE v_current_value * (3 + v_current_n) END)
        + v_raw_value
      ) / (3 + v_new_n);

      v_ci_half_width := 25 / sqrt(GREATEST(v_new_n, 1));

      v_new_entry := jsonb_build_object(
        'value', v_new_value,
        'ci_low', GREATEST(0, v_new_value - v_ci_half_width),
        'ci_high', LEAST(100, v_new_value + v_ci_half_width),
        'n', v_new_n,
        'updated_at', NOW(),
        'formula_version', v_formula_version,
        'displayable', v_new_n >= v_min_observations
      );

      -- sessions_counted is incremented by the completion flow, not here —
      -- one session can produce many decision events.
      UPDATE uldp_profiles
      SET axis_scores = jsonb_set(axis_scores, ARRAY[v_axis], v_new_entry),
          last_realtime_update_at = NOW()
      WHERE learner_id = p_learner_id;
    END LOOP;
  END IF;

  RETURN QUERY SELECT v_decision_event_id, FALSE;
END;
$function$;


-- ============================================================================
-- 14. TRIGGERS
-- ============================================================================

CREATE TRIGGER cohorts_updated_at BEFORE UPDATE ON public.cohorts FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER orgs_updated_at BEFORE UPDATE ON public.orgs FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER uldp_priors_updated_at BEFORE UPDATE ON public.uldp_priors FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER uldp_profiles_updated_at BEFORE UPDATE ON public.uldp_profiles FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER uldp_simulation_axis_validity_updated_at BEFORE UPDATE ON public.uldp_simulation_axis_validity FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER uldp_simulations_updated_at BEFORE UPDATE ON public.uldp_simulations FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER users_updated_at BEFORE UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ============================================================================
-- 15. ROW LEVEL SECURITY
-- ============================================================================
-- Enabled exactly where it is live today. decision_events_{p20260701..
-- p20261201,default} and uldp_decision_events_{p20260801..p20261201} are
-- intentionally NOT enabled here — see the header comment (KNOWN ISSUES #2).
-- Their parents (decision_events, uldp_decision_events) and
-- uldp_decision_events_default DO have RLS enabled.

ALTER TABLE public.orgs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sim_registry ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.licence_pools ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.modules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cohorts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cohort_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cohort_gates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cohort_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.org_invites ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sim_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.badge_awards ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.event_dedup ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.session_commands ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.coach_notes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.debrief_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.decision_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lms_installations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lms_context_cohorts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lti_identities ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.session_engagement_evaluations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.engagement_evaluation_overrides ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sim_api_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sim_webhooks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.uldp_priors ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.uldp_archetypes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.uldp_simulations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.uldp_simulation_axis_validity ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.uldp_validity_changelog ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.uldp_simulation_grants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.uldp_decision_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.uldp_decision_events_default ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.uldp_event_dedup ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.uldp_info_access_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.uldp_axis_scores ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.uldp_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.uldp_archetype_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.uldp_overrides ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.uldp_coaching_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.uldp_composite_recalc_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.llm_usage_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.platform_metrics ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.friction_alerts ENABLE ROW LEVEL SECURITY;

-- --- Policies (verbatim from live pg_policies; two auth styles coexist —
-- see header comment KNOWN ISSUES #1) ---

CREATE POLICY org_admin_read_org_audit_log ON public.audit_logs FOR SELECT TO public
  USING ((actor_id IN (SELECT users.id FROM users WHERE users.org_id = org_id())) AND (app_role() = 'org_admin'::text));

CREATE POLICY facilitator_read_cohort_badges ON public.badge_awards FOR SELECT TO public
  USING ((session_id IN (SELECT s.id FROM sim_sessions s JOIN cohorts c ON c.id = s.cohort_id WHERE c.org_id = org_id())) AND (app_role() = ANY (ARRAY['b2pro_facilitator'::text, 'org_facilitator'::text, 'org_admin'::text])));
CREATE POLICY learner_read_own_badges ON public.badge_awards FOR SELECT TO public
  USING (user_id = uid());

CREATE POLICY facilitator_read_cohort_coach_notes ON public.coach_notes FOR SELECT TO public
  USING ((cohort_id IN (SELECT cohorts.id FROM cohorts WHERE cohorts.org_id = ((auth.jwt() ->> 'org_id'::text))::uuid)) AND ((auth.jwt() ->> 'app_role'::text) = ANY (ARRAY['b2pro_facilitator'::text, 'org_facilitator'::text, 'org_admin'::text])));

CREATE POLICY facilitator_read_cohort_gates ON public.cohort_gates FOR SELECT TO public
  USING ((cohort_id IN (SELECT cohorts.id FROM cohorts WHERE cohorts.org_id = org_id())) AND (app_role() = ANY (ARRAY['b2pro_facilitator'::text, 'org_facilitator'::text, 'org_admin'::text])));
CREATE POLICY learner_read_enrolled_gates ON public.cohort_gates FOR SELECT TO public
  USING (cohort_id IN (SELECT cohort_members.cohort_id FROM cohort_members WHERE cohort_members.user_id = uid()));
CREATE POLICY facilitator_update_gates ON public.cohort_gates FOR UPDATE TO public
  USING ((cohort_id IN (SELECT cohorts.id FROM cohorts WHERE cohorts.org_id = org_id())) AND (app_role() = ANY (ARRAY['b2pro_facilitator'::text, 'org_facilitator'::text, 'org_admin'::text])));

CREATE POLICY facilitator_insert_cohort_members ON public.cohort_members FOR INSERT TO public
  WITH CHECK ((cohort_id IN (SELECT my_org_cohort_ids() AS my_org_cohort_ids)) AND (app_role() = ANY (ARRAY['b2pro_facilitator'::text, 'org_facilitator'::text, 'org_admin'::text])));
CREATE POLICY learner_read_own_membership ON public.cohort_members FOR SELECT TO public
  USING (user_id = uid());
CREATE POLICY facilitator_read_cohort_members ON public.cohort_members FOR SELECT TO public
  USING ((cohort_id IN (SELECT my_org_cohort_ids() AS my_org_cohort_ids)) AND (app_role() = ANY (ARRAY['b2pro_facilitator'::text, 'org_facilitator'::text, 'org_admin'::text])));
CREATE POLICY facilitator_manage_cohort_members ON public.cohort_members FOR UPDATE TO public
  USING ((cohort_id IN (SELECT my_org_cohort_ids() AS my_org_cohort_ids)) AND (app_role() = ANY (ARRAY['b2pro_facilitator'::text, 'org_facilitator'::text, 'org_admin'::text])));
CREATE POLICY facilitator_delete_cohort_members ON public.cohort_members FOR DELETE TO public
  USING ((cohort_id IN (SELECT my_org_cohort_ids() AS my_org_cohort_ids)) AND (app_role() = ANY (ARRAY['b2pro_facilitator'::text, 'org_facilitator'::text, 'org_admin'::text])));

CREATE POLICY facilitator_read_cohort_messages ON public.cohort_messages FOR SELECT TO public
  USING ((cohort_id IN (SELECT cohorts.id FROM cohorts WHERE cohorts.org_id = org_id())) AND (app_role() = ANY (ARRAY['b2pro_facilitator'::text, 'org_facilitator'::text, 'org_admin'::text])));

CREATE POLICY facilitator_insert_cohort ON public.cohorts FOR INSERT TO public
  WITH CHECK ((org_id = org_id()) AND (app_role() = ANY (ARRAY['b2pro_facilitator'::text, 'org_facilitator'::text, 'org_admin'::text])));
CREATE POLICY learner_read_enrolled_cohort ON public.cohorts FOR SELECT TO public
  USING (id IN (SELECT my_enrolled_cohort_ids() AS my_enrolled_cohort_ids));
CREATE POLICY facilitator_update_cohort ON public.cohorts FOR UPDATE TO public
  USING ((org_id = org_id()) AND ((app_role() = 'org_admin'::text) OR ((app_role() = ANY (ARRAY['b2pro_facilitator'::text, 'org_facilitator'::text])) AND (created_by = uid()))));
CREATE POLICY facilitator_read_cohorts ON public.cohorts FOR SELECT TO public
  USING ((org_id = org_id()) AND (app_role() = ANY (ARRAY['b2pro_facilitator'::text, 'org_facilitator'::text, 'org_admin'::text])));
CREATE POLICY super_admin_read_cohorts ON public.cohorts FOR ALL TO public
  USING (app_role() = 'super_admin'::text);

CREATE POLICY facilitator_read_debrief_jobs ON public.debrief_jobs FOR SELECT TO public
  USING ((cohort_id IN (SELECT cohorts.id FROM cohorts WHERE cohorts.org_id = org_id())) AND (app_role() = ANY (ARRAY['b2pro_facilitator'::text, 'org_facilitator'::text, 'org_admin'::text])));

CREATE POLICY facilitator_read_cohort_events ON public.decision_events FOR SELECT TO public
  USING ((session_id IN (SELECT s.id FROM sim_sessions s JOIN cohorts c ON c.id = s.cohort_id WHERE c.org_id = org_id())) AND (app_role() = ANY (ARRAY['b2pro_facilitator'::text, 'org_facilitator'::text, 'org_admin'::text])));
CREATE POLICY learner_read_own_events ON public.decision_events FOR SELECT TO public
  USING (session_id IN (SELECT sim_sessions.id FROM sim_sessions WHERE sim_sessions.user_id = uid()));

CREATE POLICY facilitator_read_engagement_overrides ON public.engagement_evaluation_overrides FOR SELECT TO public
  USING ((session_id IN (SELECT s.id FROM sim_sessions s JOIN cohorts c ON c.id = s.cohort_id WHERE c.org_id = org_id())) AND (app_role() = ANY (ARRAY['b2pro_facilitator'::text, 'org_facilitator'::text, 'org_admin'::text, 'super_admin'::text])));

CREATE POLICY facilitator_read_cohort_friction_alerts ON public.friction_alerts FOR SELECT TO public
  USING ((cohort_id IN (SELECT cohorts.id FROM cohorts WHERE cohorts.org_id = ((auth.jwt() ->> 'org_id'::text))::uuid)) AND ((auth.jwt() ->> 'app_role'::text) = ANY (ARRAY['b2pro_facilitator'::text, 'org_facilitator'::text, 'org_admin'::text])));

CREATE POLICY org_admin_read_own_pools ON public.licence_pools FOR SELECT TO public
  USING ((org_id = org_id()) AND (app_role() = 'org_admin'::text));
CREATE POLICY org_admin_manage_pools ON public.licence_pools FOR ALL TO public
  USING ((org_id = org_id()) AND (app_role() = 'org_admin'::text));

CREATE POLICY org_admin_read_own_llm_costs ON public.llm_usage_logs FOR SELECT TO public
  USING ((org_id = org_id()) AND (app_role() = 'org_admin'::text));

CREATE POLICY org_admin_manage_lms_contexts ON public.lms_context_cohorts FOR ALL TO public
  USING ((installation_id IN (SELECT lms_installations.id FROM lms_installations WHERE lms_installations.org_id = org_id())) AND (app_role() = 'org_admin'::text));

CREATE POLICY org_admin_manage_lms_installations ON public.lms_installations FOR ALL TO public
  USING ((org_id = org_id()) AND (app_role() = 'org_admin'::text));

CREATE POLICY org_admin_read_lti_identities ON public.lti_identities FOR SELECT TO public
  USING ((installation_id IN (SELECT lms_installations.id FROM lms_installations WHERE lms_installations.org_id = org_id())) AND (app_role() = 'org_admin'::text));
CREATE POLICY users_read_own_lti_identities ON public.lti_identities FOR SELECT TO public
  USING (user_id = uid());

CREATE POLICY org_admin_manage_modules ON public.modules FOR ALL TO public
  USING ((org_id = org_id()) AND (app_role() = 'org_admin'::text));
CREATE POLICY org_members_read_modules ON public.modules FOR SELECT TO public
  USING (org_id = org_id());

CREATE POLICY invited_user_read_own_invite ON public.org_invites FOR SELECT TO public
  USING (email = ((NULLIF(current_setting('request.jwt.claims'::text, true), ''::text))::jsonb ->> 'email'::text));
CREATE POLICY facilitator_manage_invites ON public.org_invites FOR ALL TO public
  USING ((org_id = org_id()) AND (app_role() = ANY (ARRAY['b2pro_facilitator'::text, 'org_facilitator'::text, 'org_admin'::text])));

CREATE POLICY org_members_read_own_org ON public.orgs FOR SELECT TO public
  USING (id = org_id());
CREATE POLICY org_admin_update_own_org ON public.orgs FOR UPDATE TO public
  USING ((id = org_id()) AND (app_role() = ANY (ARRAY['org_admin'::text, 'b2pro_facilitator'::text])))
  WITH CHECK (id = org_id());

CREATE POLICY facilitator_read_cohort_session_commands ON public.session_commands FOR SELECT TO public
  USING ((cohort_id IN (SELECT cohorts.id FROM cohorts WHERE cohorts.org_id = ((auth.jwt() ->> 'org_id'::text))::uuid)) AND ((auth.jwt() ->> 'app_role'::text) = ANY (ARRAY['b2pro_facilitator'::text, 'org_facilitator'::text, 'org_admin'::text])));

CREATE POLICY facilitator_read_engagement_evaluations ON public.session_engagement_evaluations FOR SELECT TO public
  USING ((session_id IN (SELECT s.id FROM sim_sessions s JOIN cohorts c ON c.id = s.cohort_id WHERE c.org_id = org_id())) AND (app_role() = ANY (ARRAY['b2pro_facilitator'::text, 'org_facilitator'::text, 'org_admin'::text, 'super_admin'::text])));

CREATE POLICY authenticated_read_sim_catalogue ON public.sim_registry FOR SELECT TO public
  USING (uid() IS NOT NULL);

CREATE POLICY facilitator_read_cohort_sessions ON public.sim_sessions FOR SELECT TO public
  USING ((cohort_id IN (SELECT cohorts.id FROM cohorts WHERE cohorts.org_id = org_id())) AND (app_role() = ANY (ARRAY['b2pro_facilitator'::text, 'org_facilitator'::text, 'org_admin'::text])));
CREATE POLICY learner_read_own_sessions ON public.sim_sessions FOR SELECT TO public
  USING (user_id = uid());

CREATE POLICY learner_read_own_uldp_archetype_profiles ON public.uldp_archetype_profiles FOR SELECT TO public
  USING (learner_id = uid());
CREATE POLICY facilitator_read_org_uldp_archetype_profiles ON public.uldp_archetype_profiles FOR SELECT TO public
  USING ((learner_id IN (SELECT users.id FROM users WHERE users.org_id = ((auth.jwt() ->> 'org_id'::text))::uuid)) AND ((auth.jwt() ->> 'app_role'::text) = ANY (ARRAY['b2pro_facilitator'::text, 'org_facilitator'::text, 'org_admin'::text])));

CREATE POLICY authenticated_read_uldp_archetypes ON public.uldp_archetypes FOR SELECT TO public
  USING (uid() IS NOT NULL);

CREATE POLICY learner_read_own_uldp_axis_scores ON public.uldp_axis_scores FOR SELECT TO public
  USING (learner_id = uid());
CREATE POLICY facilitator_read_org_uldp_axis_scores ON public.uldp_axis_scores FOR SELECT TO public
  USING ((learner_id IN (SELECT users.id FROM users WHERE users.org_id = ((auth.jwt() ->> 'org_id'::text))::uuid)) AND ((auth.jwt() ->> 'app_role'::text) = ANY (ARRAY['b2pro_facilitator'::text, 'org_facilitator'::text, 'org_admin'::text])));

CREATE POLICY facilitator_read_org_uldp_coaching_events ON public.uldp_coaching_events FOR SELECT TO public
  USING ((learner_id IN (SELECT users.id FROM users WHERE users.org_id = ((auth.jwt() ->> 'org_id'::text))::uuid)) AND ((auth.jwt() ->> 'app_role'::text) = ANY (ARRAY['b2pro_facilitator'::text, 'org_facilitator'::text, 'org_admin'::text])));
CREATE POLICY learner_read_own_uldp_coaching_events ON public.uldp_coaching_events FOR SELECT TO public
  USING (learner_id = uid());

CREATE POLICY learner_read_own_uldp_events ON public.uldp_decision_events FOR SELECT TO public
  USING (learner_id = uid());
CREATE POLICY facilitator_read_cohort_uldp_events ON public.uldp_decision_events FOR SELECT TO public
  USING ((cohort_id IN (SELECT cohorts.id FROM cohorts WHERE cohorts.org_id = ((auth.jwt() ->> 'org_id'::text))::uuid)) AND ((auth.jwt() ->> 'app_role'::text) = ANY (ARRAY['b2pro_facilitator'::text, 'org_facilitator'::text, 'org_admin'::text])));

CREATE POLICY facilitator_read_cohort_uldp_info_access ON public.uldp_info_access_events FOR SELECT TO public
  USING ((session_id IN (SELECT s.id FROM sim_sessions s JOIN cohorts c ON c.id = s.cohort_id WHERE c.org_id = ((auth.jwt() ->> 'org_id'::text))::uuid)) AND ((auth.jwt() ->> 'app_role'::text) = ANY (ARRAY['b2pro_facilitator'::text, 'org_facilitator'::text, 'org_admin'::text])));
CREATE POLICY learner_read_own_uldp_info_access ON public.uldp_info_access_events FOR SELECT TO public
  USING (learner_id = uid());

CREATE POLICY learner_read_own_uldp_overrides ON public.uldp_overrides FOR SELECT TO public
  USING (learner_id = uid());
CREATE POLICY facilitator_read_org_uldp_overrides ON public.uldp_overrides FOR SELECT TO public
  USING ((learner_id IN (SELECT users.id FROM users WHERE users.org_id = ((auth.jwt() ->> 'org_id'::text))::uuid)) AND ((auth.jwt() ->> 'app_role'::text) = ANY (ARRAY['b2pro_facilitator'::text, 'org_facilitator'::text, 'org_admin'::text])));

CREATE POLICY learner_read_own_uldp_profile ON public.uldp_profiles FOR SELECT TO public
  USING (learner_id = uid());
CREATE POLICY facilitator_read_org_uldp_profiles ON public.uldp_profiles FOR SELECT TO public
  USING ((org_id = ((auth.jwt() ->> 'org_id'::text))::uuid) AND ((auth.jwt() ->> 'app_role'::text) = ANY (ARRAY['b2pro_facilitator'::text, 'org_facilitator'::text, 'org_admin'::text])));

CREATE POLICY authenticated_read_uldp_simulation_axis_validity ON public.uldp_simulation_axis_validity FOR SELECT TO public
  USING (uid() IS NOT NULL);

CREATE POLICY authenticated_read_uldp_simulations ON public.uldp_simulations FOR SELECT TO public
  USING (uid() IS NOT NULL);

CREATE POLICY authenticated_read_uldp_validity_changelog ON public.uldp_validity_changelog FOR SELECT TO public
  USING (uid() IS NOT NULL);

CREATE POLICY users_update_self ON public.users FOR UPDATE TO public
  USING (id = uid())
  WITH CHECK (id = uid());
CREATE POLICY facilitator_read_org_users ON public.users FOR SELECT TO public
  USING ((org_id = org_id()) AND (app_role() = ANY (ARRAY['b2pro_facilitator'::text, 'org_facilitator'::text, 'org_admin'::text])));
CREATE POLICY users_read_self ON public.users FOR SELECT TO public
  USING (id = uid());


-- ============================================================================
-- 16. SEED DATA
-- ============================================================================
-- Reference/config tables only. Live transactional data (users, orgs,
-- cohorts, sessions, etc.) is intentionally NOT included in a schema
-- migration — 7 seeded Bayesian priors and 8 frozen ULDP archetypes are.

INSERT INTO public.uldp_priors (axis, prior_mean, min_observations, prior_version, notes, half_life_days) VALUES
  ('RISK',    50, 5,  'v0-provisional', 'Neutral center', 90),
  ('SPEED',   55, 5,  'v0-provisional', 'Slight bias toward "reasonable speed"', 90),
  ('CONSIST', 60, 8,  'v0-provisional', 'Needs more data to be meaningful', 90),
  ('COMP',    50, 5,  'v0-provisional', NULL, 90),
  ('ADAPT',   50, 6,  'v0-provisional', 'Trigger events are rarer', 90),
  ('INFO',    55, 5,  'v0-provisional', NULL, 90),
  ('CALIB',   50, 10, 'v0-provisional', 'Needs confidence + outcome pairs', 90);

INSERT INTO public.uldp_archetypes (slug, name, description) VALUES
  ('resource_allocation',   'Resource Allocation',      'Scarce resource distribution, budget allocation, time prioritization'),
  ('risk_management',       'Risk Management',          'Hedging, insurance/self-insurance, contingency planning'),
  ('strategic_positioning', 'Strategic Positioning',    'Market entry timing, competitive response, differentiation vs. cost leadership'),
  ('stakeholder_management','Stakeholder Management',   'Conflict resolution, coalition building, authority vs. influence'),
  ('information_economics', 'Information Economics',    'Costly information acquisition, signal vs. noise, evidence weighting'),
  ('adaptation_pivoting',   'Adaptation & Pivoting',     'Strategy revision, sunk cost handling, opportunity cost assessment'),
  ('ethical_values',        'Ethical & Values',         'Trade-off decisions, principle vs. pragmatism, transparency vs. discretion'),
  ('innovation_growth',     'Innovation & Growth',      'R&D investment, product feature prioritization, scaling decisions');

-- ============================================================================
-- End of consolidated schema.
-- ============================================================================
