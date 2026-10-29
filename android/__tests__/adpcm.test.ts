// Port of app/test/board/adpcm_test.dart. Cases: shared/fixtures/adpcm.json
// (see shared/fixtures/README.md).
import {ADPCMDecoder, adpcmIndexTable, adpcmStepTable} from '../src/board/adpcm';
import {bytesOf, casesOf, loadFixture} from './fixtures';

const fixture = loadFixture('adpcm');

test('tables and gap limit', () => {
  expect(adpcmStepTable).toEqual(fixture.stepTable);
  expect(adpcmIndexTable).toEqual(fixture.indexTable);
  expect(ADPCMDecoder.maxGapPackets).toBe(fixture.maxGapPackets);
});

test('the fixture has every sequence', () => {
  expect(casesOf(fixture, 'sequences')).toHaveLength(9);
});

describe('sequences', () => {
  for (const c of casesOf(fixture, 'sequences')) {
    test(c.name as string, () => {
      const d = new ADPCMDecoder();
      const steps = casesOf(c, 'steps');
      expect(steps.length).toBeGreaterThan(0);
      steps.forEach((step, i) => {
        if (step.reset === true) {
          d.reset();
          return;
        }
        const out = d.decode(bytesOf(step.packet as string));
        expect(out).toBeInstanceOf(Int16Array);
        expect({step: i, samples: Array.from(out)}).toEqual({step: i, samples: step.expected});
      });
    });
  }
});
