import type { Check } from '../lib/types';
import { check as br01 } from './br01_membership_invalid_transitions';
import { check as br02 } from './br02_membership_snapshot_stale';
import { check as br03 } from './br03_active_members_have_crm_events';
import { check as br04 } from './br04_device_kind_matches_event';
import { check as br05 } from './br05_event_branch_matches_device';
import { check as br06 } from './br06_friend_visit_within_open_visit';
import { check as br07 } from './br07_friend_allowance_not_exceeded';
import { check as br08 } from './br08_access_events_in_local_year';

export const checks: Check[] = [
  br01, br02, br03, br04, br05, br06, br07, br08,
];
