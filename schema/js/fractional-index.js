// Order keys for `Entry.orderKey`, `Lesson.orderKey` and every other fractional position: the twin of
// Swift's FractionalIndex.swift. These are rocicorp/fractional-indexing's base-62 keys (an integer
// part whose head letter gives its length, then a fraction with no trailing zero), so the Mac, the
// iPhone, the website and the gateway mint the same keys. Keys sort as plain byte strings, never by a
// locale collation; SQL compares them with BINARY. A reorder writes one key between its neighbours.
// A key holding a character outside base 62 is refused, which rocicorp's code does not check.
// Vectors: schema/vectors/fractional-index.json.

const DIGITS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
const SMALLEST_INTEGER = `A${"0".repeat(26)}`;

export class InvalidOrderKey extends Error {
  /** @param {string} reason */
  constructor(reason) {
    super(reason);
    this.name = "InvalidOrderKey";
  }
}

/**
 * A key between `a` and `b` (null is an open end); `a < b` when both are given.
 * @param {string | null | undefined} a
 * @param {string | null | undefined} b
 * @returns {string}
 */
export function keyBetween(a, b) {
  if (a != null) validate(a);
  if (b != null) validate(b);
  if (a != null && b != null && !(a < b)) throw new InvalidOrderKey(`${a} is not before ${b}`);
  return between(a ?? null, b ?? null);
}

/**
 * `count` keys in order between `a` and `b`: consecutive integers at an open end, short keys
 * between two keys.
 * @param {string | null | undefined} a
 * @param {string | null | undefined} b
 * @param {number} count
 * @returns {string[]}
 */
export function keysBetween(a, b, count) {
  if (count <= 0) return [];
  if (count === 1) return [keyBetween(a, b)];
  if (b == null) {
    let key = keyBetween(a, null);
    const result = [key];
    for (let index = 1; index < count; index += 1) {
      key = keyBetween(key, null);
      result.push(key);
    }
    return result;
  }
  if (a == null) {
    let key = keyBetween(null, b);
    const result = [key];
    for (let index = 1; index < count; index += 1) {
      key = keyBetween(null, key);
      result.push(key);
    }
    return result.reverse();
  }
  const middleIndex = Math.floor(count / 2);
  const middle = keyBetween(a, b);
  return [...keysBetween(a, middle, middleIndex), middle, ...keysBetween(middle, b, count - middleIndex - 1)];
}

/** @param {string} key */
export function isValidOrderKey(key) {
  try {
    validate(key);
    return true;
  } catch {
    return false;
  }
}

/**
 * @param {string | null} a
 * @param {string | null} b
 * @returns {string}
 */
function between(a, b) {
  if (a === null) {
    if (b === null) return "a0";
    const integerB = integerPart(b);
    const fractionB = b.slice(integerB.length);
    if (integerB === SMALLEST_INTEGER) return integerB + midpoint("", fractionB);
    if (integerB.length < b.length) return integerB;
    const decremented = decrement(integerB);
    if (decremented === null) throw new InvalidOrderKey("cannot decrement any more");
    return decremented;
  }
  if (b === null) {
    const integerA = integerPart(a);
    const fractionA = a.slice(integerA.length);
    const incremented = increment(integerA);
    return incremented ?? integerA + midpoint(fractionA, null);
  }
  const integerA = integerPart(a);
  const fractionA = a.slice(integerA.length);
  const integerB = integerPart(b);
  const fractionB = b.slice(integerB.length);
  if (integerA === integerB) return integerA + midpoint(fractionA, fractionB);
  const incremented = increment(integerA);
  if (incremented === null) throw new InvalidOrderKey("cannot increment any more");
  if (incremented < b) return incremented;
  return integerA + midpoint(fractionA, null);
}

/**
 * A fraction between `a` and `b` (null is the end); neither has a trailing zero.
 * @param {string} a
 * @param {string | null} b
 * @returns {string}
 */
function midpoint(a, b) {
  if (b !== null) {
    // Drop the common prefix, reading a missing digit of `a` as zero.
    let shared = 0;
    while (shared < b.length && (shared < a.length ? a[shared] : "0") === b[shared]) shared += 1;
    if (shared > 0) return b.slice(0, shared) + midpoint(shared < a.length ? a.slice(shared) : "", b.slice(shared));
  }
  const digitA = a.length > 0 ? digitValue(a[0]) : 0;
  const digitB = b !== null && b.length > 0 ? digitValue(b[0]) : DIGITS.length;
  if (digitB - digitA > 1) return DIGITS[Math.floor((digitA + digitB + 1) / 2)];
  if (b !== null && b.length > 1) return b[0];
  return DIGITS[digitA] + midpoint(a.length > 0 ? a.slice(1) : "", null);
}

/** @param {string} head */
function integerLength(head) {
  if (head >= "a" && head <= "z") return head.charCodeAt(0) - 97 + 2;
  if (head >= "A" && head <= "Z") return 90 - head.charCodeAt(0) + 2;
  throw new InvalidOrderKey("invalid order key head");
}

/** @param {string} key */
function integerPart(key) {
  if (key.length === 0) throw new InvalidOrderKey("empty order key");
  const length = integerLength(key[0]);
  if (length > key.length) throw new InvalidOrderKey("order key shorter than its integer part");
  return key.slice(0, length);
}

/** @param {string} key */
function validate(key) {
  for (let index = 1; index < key.length; index += 1) {
    if (!DIGITS.includes(key[index])) throw new InvalidOrderKey("order key holds a character outside base 62");
  }
  if (key === SMALLEST_INTEGER) throw new InvalidOrderKey("the smallest integer is not a key");
  const integer = integerPart(key);
  if (key.length > integer.length && key.endsWith("0")) throw new InvalidOrderKey("order key ends in a zero");
}

/** @param {string} integer @returns {string | null} */
function increment(integer) {
  const head = integer[0];
  const tail = integer.slice(1).split("");
  let carry = true;
  for (let index = tail.length - 1; carry && index >= 0; index -= 1) {
    const next = digitValue(tail[index]) + 1;
    if (next === DIGITS.length) {
      tail[index] = "0";
    } else {
      tail[index] = DIGITS[next];
      carry = false;
    }
  }
  if (!carry) return head + tail.join("");
  if (head === "Z") return "a0";
  if (head === "z") return null;
  const newHead = String.fromCharCode(head.charCodeAt(0) + 1);
  if (newHead > "a") tail.push("0");
  else tail.pop();
  return newHead + tail.join("");
}

/** @param {string} integer @returns {string | null} */
function decrement(integer) {
  const head = integer[0];
  const tail = integer.slice(1).split("");
  let borrow = true;
  for (let index = tail.length - 1; borrow && index >= 0; index -= 1) {
    const next = digitValue(tail[index]) - 1;
    if (next === -1) {
      tail[index] = DIGITS[DIGITS.length - 1];
    } else {
      tail[index] = DIGITS[next];
      borrow = false;
    }
  }
  if (!borrow) return head + tail.join("");
  if (head === "a") return `Z${DIGITS[DIGITS.length - 1]}`;
  if (head === "A") return null;
  const newHead = String.fromCharCode(head.charCodeAt(0) - 1);
  if (newHead < "Z") tail.push(DIGITS[DIGITS.length - 1]);
  else tail.pop();
  return newHead + tail.join("");
}

/** @param {string} character */
function digitValue(character) {
  const value = DIGITS.indexOf(character);
  return value < 0 ? 0 : value;
}
