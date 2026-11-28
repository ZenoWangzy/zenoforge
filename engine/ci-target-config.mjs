import { zfEnv } from './pack-dir.mjs';

const CI_RUNNER_USER_DEFAULT = 'vecta-ci';
const CI_SUITES_LANE_DEFAULT = 'vecta-suites';

export function ciTargetConfig(environment = process.env) {
  return {
    runnerUser: zfEnv('CI_RUNNER_USER', CI_RUNNER_USER_DEFAULT, environment),
    suitesLane: zfEnv('CI_SUITES_LANE', CI_SUITES_LANE_DEFAULT, environment),
  };
}
