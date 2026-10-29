// Port of app/test/core/conversation_activity_test.dart. Cases:
// shared/fixtures/conversation_activity.json (see shared/fixtures/README.md).
import {
  ActivityEvent,
  ConversationActivity,
  activityEvents,
} from '../src/core/conversationActivity';
import {JsonObject, casesOf, loadFixture} from './fixtures';

const fixture = loadFixture('conversation_activity');
const defaults = fixture.defaults as JsonObject;
const t0 = 1_000_000 * 1000;

test('defaults and event names', () => {
  const a = new ConversationActivity();
  expect(a.idleTimeoutMs).toBe(defaults.idleTimeoutMs);
  expect(a.retryDelayMs).toBe(defaults.retryDelayMs);
  expect([...activityEvents].sort()).toEqual([...(fixture.events as string[])].sort());
});

describe('scenarios', () => {
  for (const c of casesOf(fixture, 'scenarios')) {
    test(c.name as string, () => {
      const config = {...defaults, ...((c.config as JsonObject | undefined) ?? {})};
      const activity = new ConversationActivity({
        idleTimeoutMs: config.idleTimeoutMs as number,
        retryDelayMs: config.retryDelayMs as number,
      });
      expect(activity.state).toBe('idle');
      casesOf(c, 'steps').forEach((step, i) => {
        const now = t0 + (step.atMs as number);
        if (step.startFailed === true) {
          activity.startFailed(now);
        } else {
          const got = activity.handle(step.event as ActivityEvent, now);
          expect({step: i, transition: got}).toEqual({step: i, transition: step.expect});
        }
        if (step.state != null) {
          expect({step: i, state: activity.state}).toEqual({step: i, state: step.state});
          expect(activity.isActive).toBe(step.state === 'active');
        }
      });
    });
  }
});
