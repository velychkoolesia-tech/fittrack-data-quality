import type { Check } from '../src/lib/types';

// ── Business-rule checks (negative) ──────────────────────────────────────
import { check as br01 } from './br01_membership_invalid_transitions';
import { check as br02 } from './br02_membership_snapshot_stale';
import { check as br02b } from './br02b_tier_snapshot_stale';
import { check as br03 } from './br03_active_members_have_crm_events';
import { check as br04 } from './br04_device_kind_matches_event';
import { check as br05 } from './br05_event_branch_matches_device';
import { check as br06 } from './br06_friend_visit_within_open_visit';
import { check as br07 } from './br07_friend_allowance_not_exceeded';
import { check as br08 } from './br08_access_events_in_local_year';
import { check as br09 } from './br09_active_members_every_month';

// ── Generic schema/contract checks (negative) ─────────────────────────────
// These assume nothing about this dataset's content; they protect the schema
// contract so the suite is meaningful on any database with the same schema.
import { check as gen01 } from './gen01_required_fields_not_null';
import { check as gen02 } from './gen02_email_format';
import { check as gen03 } from './gen03_email_uniqueness';
import { check as gen04 } from './gen04_home_branch_fk';
import { check as gen05 } from './gen05_status_enum';
import { check as gen06 } from './gen06_tier_enum';

// ── Regression guards for the documented root causes (negative) ───────────
import { check as rc01 } from './rc01_sequence_gaps';
import { check as rc02 } from './rc02_clock_shift_detection';
import { check as rc03 } from './rc03_late_crm_ingestion';
import { check as rc04 } from './rc04_crm_no_duplicates';

// ── Positive sanity + end-to-end checks ───────────────────────────────────
import { check as pos01 } from './pos01_clean_pair_rate';
import { check as pos02 } from './pos02_all_branches_have_checkins';
import { check as e2e01 } from './e2e01_report_total_in_range';
import { check as e2e02 } from './e2e02_lifecycle_event_ordering';

// ── Edge-case checks ──────────────────────────────────────────────────────
import { check as ec01 } from './ec01_opening_time_within_hours';
import { check as ec02 } from './ec02_visits_crossing_midnight';
import { check as ec03 } from './ec03_members_with_only_checkouts';
import { check as ec04 } from './ec04_negative_duration_visits';
import { check as ec05 } from './ec05_closing_time_within_hours';

// ── Exploratory checks (always display stats, never block) ────────────────
import { check as exp01 } from './exp01_visit_duration_stats';
import { check as exp02 } from './exp02_high_frequency_visitors';
import { check as exp03 } from './exp03_branch_monthly_anomaly';

export const checks: Check[] = [
  // business-rule
  br01, br02, br02b, br03, br04, br05, br06, br07, br08, br09,
  // generic schema/contract
  gen01, gen02, gen03, gen04, gen05, gen06,
  // regression guards
  rc01, rc02, rc03, rc04,
  // positive + e2e
  pos01, pos02, e2e01, e2e02,
  // edge-case
  ec01, ec02, ec03, ec04, ec05,
  // exploratory
  exp01, exp02, exp03,
];
