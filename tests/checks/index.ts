import type { Check } from '../lib/types';

// ── Business-rule checks (negative) ──────────────────────────────────────
import { check as br01 } from './br01_membership_invalid_transitions';
import { check as br02 } from './br02_membership_snapshot_stale';
import { check as br03 } from './br03_active_members_have_crm_events';
import { check as br04 } from './br04_device_kind_matches_event';
import { check as br05 } from './br05_event_branch_matches_device';
import { check as br06 } from './br06_friend_visit_within_open_visit';
import { check as br07 } from './br07_friend_allowance_not_exceeded';
import { check as br08 } from './br08_access_events_in_local_year';

// ── Positive sanity checks ────────────────────────────────────────────────
import { check as pos01 } from './pos01_clean_pair_rate';
import { check as pos02 } from './pos02_all_branches_have_checkins';

// ── Edge-case checks ──────────────────────────────────────────────────────
import { check as ec01 } from './ec01_opening_time_within_hours';
import { check as ec02 } from './ec02_visits_crossing_midnight';
import { check as ec03 } from './ec03_members_with_only_checkouts';

// ── Exploratory checks (always display stats, never block) ────────────────
import { check as exp01 } from './exp01_visit_duration_stats';
import { check as exp02 } from './exp02_high_frequency_visitors';

export const checks: Check[] = [
  // negative
  br01, br02, br03, br04, br05, br06, br07, br08,
  // positive
  pos01, pos02,
  // edge-case
  ec01, ec02, ec03,
  // exploratory
  exp01, exp02,
];
