// Field stamps and the device's stamp clock (docs/cloudkit-schema-design.md §3.2 rule 3, §6.3, D9):
// the twin of Swift's Stamp.swift and StampClock.swift. A stamp is its text,
// `L1759400000123.0001.k3f7ab2q`: the policy letter, 13-digit epoch milliseconds (server-corrected),
// a 4-digit counter and the 8-character device id. Vectors: schema/vectors/envelope.json
// (stampValid, stampCompare) and schema/vectors/stamp-clock.json.

import { LIMITS, POLICIES } from "./schema.generated.js";

export const MAX_STAMP_MILLISECONDS = 9_999_999_999_999;
export const MAX_STAMP_COUNTER = 9_999;

const STAMP = /^[LSXNT][0-9]{13}\.[0-9]{4}\.[a-z2-7]{8}$/;

/**
 * Whether `text` is a stamp: `^[LSXNT][0-9]{13}\.[0-9]{4}\.[a-z2-7]{8}$`.
 * @param {unknown} text
 * @returns {text is string}
 */
export function isStamp(text) {
  return typeof text === "string" && STAMP.test(text);
}

/**
 * A stamp's parts, or null for anything that is not a stamp.
 * @param {unknown} text
 */
export function parseStamp(text) {
  if (!isStamp(text)) return null;
  return {
    policy: /** @type {import("./schema.generated.js").PolicyLetter} */ (text[0]),
    milliseconds: Number(text.slice(1, 14)),
    counter: Number(text.slice(15, 19)),
    deviceID: text.slice(20),
  };
}

/**
 * The stamp of those parts. The milliseconds, counter and device id must be in range.
 * @param {string} policy
 * @param {number} milliseconds
 * @param {number} counter
 * @param {string} deviceID
 */
export function formatStamp(policy, milliseconds, counter, deviceID) {
  if (!POLICIES.includes(/** @type {any} */ (policy))) throw new RangeError(`${policy} is not a policy letter`);
  if (!Number.isInteger(milliseconds) || milliseconds < 0 || milliseconds > MAX_STAMP_MILLISECONDS) {
    throw new RangeError("stamp milliseconds out of range");
  }
  if (!Number.isInteger(counter) || counter < 0 || counter > MAX_STAMP_COUNTER) throw new RangeError("stamp counter out of range");
  if (!isDeviceID(deviceID)) throw new RangeError("stamp device id is not 8 base32 characters");
  return `${policy}${String(milliseconds).padStart(13, "0")}.${String(counter).padStart(4, "0")}.${deviceID}`;
}

/**
 * 8 characters of RFC 4648 lowercase base32 (`a-z`, `2-7`).
 * @param {unknown} value
 */
export function isDeviceID(value) {
  return typeof value === "string" && /^[a-z2-7]{8}$/.test(value);
}

/**
 * -1, 0 or 1 by the 27 characters after the letter, as plain strings: (milliseconds, counter, device
 * id). The letter never takes part, and nothing is clamped: a clamp to now + 1 day whose ties are
 * broken by those characters is this same order (§6.3 as corrected by WP2), so a merge gives the
 * same result on every device whatever its clock.
 * @param {string} a
 * @param {string} b
 */
export function compareStamps(a, b) {
  const left = a.slice(1);
  const right = b.slice(1);
  return left < right ? -1 : left > right ? 1 : 0;
}

/**
 * Whether stamp `a` is later than stamp `b`.
 * @param {string} a
 * @param {string} b
 */
export function stampIsLater(a, b) {
  return compareStamps(a, b) > 0;
}

/**
 * A skeletal import's stamp (§3.5.4): millisecond 1, so any real write beats it.
 * @param {string} policy
 * @param {string} deviceID
 */
export function provisionalStamp(policy, deviceID) {
  return formatStamp(policy, LIMITS.provisionalStampMs, 0, deviceID);
}

const OFFSET_SAMPLE_COUNT = 20;
const EARLIER_MILLISECOND_COUNT = 64;
const LARGE_OFFSET_MILLISECONDS = 120_000;

/**
 * The device's stamp source (§6.3). It keeps the server offset (the median of the last 20
 * `server time - local send time` deltas from acknowledged saves, or from a response's own
 * timestamps on the web and in the hosted MCP) and the last stamp it issued. A stamp's milliseconds
 * are `max(eventTime + serverOffset, clamp(seen) + 1)`, where `seen` is the replica's stamp for the
 * field, clamped to now + 1 day. The counter tells apart stamps this device issues within one
 * millisecond, including a millisecond below the last stamp: the clock remembers the last counter
 * of the 64 latest such milliseconds.
 *
 * The stamp a caller pins is minted against `seen`, and the caller keeps `seen` beside it: the merge
 * lets the change win against that exact server version (merge.js, `mintedAgainst`). The web keeps
 * its clock in IndexedDB and the hosted MCP in its Durable Object, as `toJSON()` writes it.
 */
export class StampClock {
  /**
   * @param {string} deviceID
   * @param {{offsetSamples?: number[], lastMilliseconds?: number, lastCounter?: number,
   *          earlierCounters?: Map<number, number> | Record<string, number>}} [saved]
   */
  constructor(deviceID, saved = {}) {
    if (!isDeviceID(deviceID)) throw new RangeError("a stamp clock needs an 8-character base32 device id");
    this.deviceID = deviceID;
    /** `server - local` in milliseconds, oldest first. @type {number[]} */
    this.offsetSamples = (saved.offsetSamples ?? []).slice(-OFFSET_SAMPLE_COUNT);
    this.lastMilliseconds = saved.lastMilliseconds ?? -1;
    this.lastCounter = saved.lastCounter ?? 0;
    /** @type {Map<number, number>} */
    this.earlierCounters = saved.earlierCounters instanceof Map
      ? new Map(saved.earlierCounters)
      : new Map(Object.entries(saved.earlierCounters ?? {}).map(([key, counter]) => [Number(key), counter]));
    this.forgetOldestEarlierCounters();
  }

  /**
   * A saved clock, refused (RangeError) when it could not mint a valid stamp: a device id outside
   * base32, a counter or milliseconds out of range, or earlier counters at or above the last stamp.
   * @param {any} saved
   */
  static fromJSON(saved) {
    const deviceID = saved?.deviceID;
    const lastMilliseconds = saved?.lastMilliseconds ?? -1;
    const lastCounter = saved?.lastCounter ?? 0;
    const samples = saved?.offsetSamples ?? [];
    const earlier = saved?.earlierCounters ?? {};
    if (!isDeviceID(deviceID)) throw new RangeError("deviceID: not 8 base32 characters");
    if (!Array.isArray(samples) || !samples.every(Number.isInteger)) throw new RangeError("offsetSamples: not integers");
    if (!Number.isInteger(lastMilliseconds) || lastMilliseconds < -1 || lastMilliseconds > MAX_STAMP_MILLISECONDS) {
      throw new RangeError("lastMilliseconds: outside the stamp range");
    }
    if (!Number.isInteger(lastCounter) || lastCounter < 0 || lastCounter > MAX_STAMP_COUNTER) {
      throw new RangeError("lastCounter: outside the counter range");
    }
    /** @type {Map<number, number>} */
    const earlierCounters = new Map();
    for (const [key, counter] of Object.entries(earlier)) {
      const milliseconds = /^-?[0-9]+$/.test(key) ? Number(key) : NaN;
      if (!Number.isSafeInteger(milliseconds) || milliseconds < 0 || milliseconds >= Math.max(lastMilliseconds, 0)
        || !Number.isInteger(counter) || counter < 0 || counter > MAX_STAMP_COUNTER) {
        throw new RangeError(`earlierCounters: ${key}: ${counter}`);
      }
      earlierCounters.set(milliseconds, counter);
    }
    return new StampClock(deviceID, { offsetSamples: samples, lastMilliseconds, lastCounter, earlierCounters });
  }

  toJSON() {
    return {
      deviceID: this.deviceID,
      offsetSamples: [...this.offsetSamples],
      lastMilliseconds: this.lastMilliseconds,
      lastCounter: this.lastCounter,
      earlierCounters: Object.fromEntries([...this.earlierCounters.entries()]
        .sort((a, b) => a[0] - b[0])
        .map(([milliseconds, counter]) => [String(milliseconds), counter])),
    };
  }

  /**
   * The median offset: the lower middle sample for an even count. Null until the device has seen a
   * server time, and a device without one sends nothing (§2.4 step 4).
   * @returns {number | null}
   */
  get serverOffset() {
    if (this.offsetSamples.length === 0) return null;
    const sorted = [...this.offsetSamples].sort((a, b) => a - b);
    return sorted[Math.floor((sorted.length - 1) / 2)];
  }

  /** Above two minutes the device logs that its clock is off; it stamps in server time either way. */
  get offsetIsLarge() {
    const offset = this.serverOffset;
    return offset !== null && Math.abs(offset) > LARGE_OFFSET_MILLISECONDS;
  }

  /**
   * Records one acknowledged save or response: the server's time and the local time it was sent.
   * @param {number} serverMilliseconds
   * @param {number} localMilliseconds
   */
  recordServerTime(serverMilliseconds, localMilliseconds) {
    this.offsetSamples.push(serverMilliseconds - localMilliseconds);
    if (this.offsetSamples.length > OFFSET_SAMPLE_COUNT) this.offsetSamples.splice(0, this.offsetSamples.length - OFFSET_SAMPLE_COUNT);
  }

  /** @param {number} localMilliseconds */
  serverTime(localMilliseconds) {
    const offset = this.serverOffset;
    return offset === null ? null : localMilliseconds + offset;
  }

  /**
   * The stamp of a change made at local time `eventTime` to a field whose replica stamp is `seen`
   * (or null), minted at local time `now`. Null before the first server time: the caller keeps the
   * change unstamped, and anything that would name its stamp waits, until then.
   * @param {string} policy
   * @param {number} eventTime
   * @param {string | null | undefined} seen
   * @param {number} now
   * @returns {string | null}
   */
  mint(policy, eventTime, seen, now) {
    const offset = this.serverOffset;
    if (offset === null) return null;
    let milliseconds = eventTime + offset;
    const seenStamp = parseStamp(seen);
    if (seenStamp) {
      const ceiling = now + offset + LIMITS.receivedStampFutureClampMs;
      milliseconds = Math.max(milliseconds, Math.min(seenStamp.milliseconds, ceiling) + 1);
    }
    milliseconds = Math.min(Math.max(milliseconds, 0), MAX_STAMP_MILLISECONDS);
    let counter = this.nextCounter(milliseconds);
    // A full millisecond moves to the next one, which may itself have counters already.
    while (counter > MAX_STAMP_COUNTER && milliseconds < MAX_STAMP_MILLISECONDS) {
      milliseconds += 1;
      counter = this.nextCounter(milliseconds);
    }
    counter = Math.min(counter, MAX_STAMP_COUNTER);
    // An older event time (a column changed before the last stamp was issued) keeps its own
    // milliseconds and does not move the clock's high-water mark; its counter is remembered.
    if (milliseconds > this.lastMilliseconds) {
      if (this.lastMilliseconds >= 0) this.earlierCounters.set(this.lastMilliseconds, this.lastCounter);
      this.lastMilliseconds = milliseconds;
      this.lastCounter = counter;
    } else if (milliseconds === this.lastMilliseconds) {
      this.lastCounter = counter;
    } else {
      this.earlierCounters.set(milliseconds, counter);
    }
    this.forgetOldestEarlierCounters();
    return formatStamp(policy, milliseconds, counter, this.deviceID);
  }

  /** @param {number} milliseconds */
  nextCounter(milliseconds) {
    if (milliseconds === this.lastMilliseconds) return this.lastCounter + 1;
    const earlier = this.earlierCounters.get(milliseconds);
    return earlier === undefined ? 0 : earlier + 1;
  }

  forgetOldestEarlierCounters() {
    for (const milliseconds of [...this.earlierCounters.keys()]) {
      if (!(milliseconds < this.lastMilliseconds && milliseconds >= 0)) this.earlierCounters.delete(milliseconds);
    }
    if (this.earlierCounters.size <= EARLIER_MILLISECOND_COUNT) return;
    const sorted = [...this.earlierCounters.keys()].sort((a, b) => a - b);
    for (const milliseconds of sorted.slice(0, sorted.length - EARLIER_MILLISECOND_COUNT)) this.earlierCounters.delete(milliseconds);
  }
}
