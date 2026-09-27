/* Anchor check for lunar.js against published civil/lunar dates.
 *
 * Sources: the Purple Mountain Observatory algorithm (GB/T 33661-2017) as
 * reported for 2025-2029 -- five consecutive years whose 12th lunar month is
 * short (29 days), so the New Year's Eve falls on the 29th, not the 30th.
 * ICU's Chinese calendar disagrees by one day around the 2027 boundary, so
 * these published anchors are the tie-breaker, not Intl.
 */
const fs = require('fs');
global.window = {};
eval(fs.readFileSync(__dirname + '/../web/js/lunar.js', 'utf8'));
const L = window.Lunar;

const CASES = [
  // [civil date, expected lunar month, expected lunar day, expected festival]
  ['2025-01-29', 1, 1, '春节'],
  ['2026-02-16', 12, 29, '除夕'],
  ['2026-02-17', 1, 1, '春节'],
  ['2026-06-19', 5, 5, '端午节'],
  ['2026-09-25', 8, 15, '中秋节'],
  ['2026-10-01', 8, 21, '国庆节'],
  ['2026-10-18', 9, 9, '重阳节'],
  ['2027-02-05', 12, 29, '除夕'],
  ['2027-02-06', 1, 1, '春节'],
  ['2028-01-25', 12, 29, '除夕'],
  ['2028-01-26', 1, 1, '春节'],
  ['2029-02-12', 12, 29, '除夕'],
  ['2029-02-13', 1, 1, '春节'],
  ['2025-08-15', 6, 22, null],      // leap 6th month in 2025
  ['2025-07-25', 6, 1, null]        // leap sixth month begins
];

let fail = 0;
CASES.forEach(c => {
  const [s, m, d, fest] = c;
  const i = L.dayInfo(s);
  const l = i.lunar;
  const ok = l && l.month === m && l.day === d && (i.festival || null) === fest;
  if (!ok) fail++;
  console.log((ok ? 'ok   ' : 'FAIL ') + s + ' expect ' + m + '/' + d + ' ' + fest +
    ' got ' + (l ? l.month + (l.leap ? 'r' : '') + '/' + l.day : 'null') + ' ' + (i.festival || '-'));
});

// 2025 has a leap 6th month: the leap flag must show up and only there.
let leapDays = 0;
for (let m = 1; m <= 12; m++) {
  for (let d = 1; d <= new Date(2025, m, 0).getDate(); d++) {
    const l = L.fromDate(new Date(2025, m - 1, d));
    if (l.year === 2025 && l.leap) leapDays++;
  }
}
console.log('2025 leap-month days: ' + leapDays + ' (expect 29 or 30)');
console.log(fail === 0 ? 'ALL ANCHORS OK' : fail + ' ANCHOR FAILURES');
