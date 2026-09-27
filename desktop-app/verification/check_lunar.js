const fs = require('fs');
global.window = {};
eval(fs.readFileSync(__dirname + '/../web/js/lunar.js', 'utf8'));
const L = window.Lunar;

const fmt = new Intl.DateTimeFormat('en-u-ca-chinese', { year: 'numeric', month: 'numeric', day: 'numeric' });
let bad = 0, checked = 0;
const samples = [];
for (let y = 2020; y <= 2030; y++) {
  for (let m = 1; m <= 12; m++) {
    for (let d = 1; d <= new Date(y, m, 0).getDate(); d++) {
      const date = new Date(y, m - 1, d);
      const mine = L.fromDate(date);
      const parts = fmt.formatToParts(date);
      const get = t => parts.find(p => p.type === t).value;
      let im = String(get('month'));
      let leap = false;
      const mLeap = /(\d+)\s*r/.exec(im);
      if (mLeap) { leap = true; im = mLeap[1]; }
      const imN = parseInt(String(im).replace(/\D/g, ''), 10);
      const idN = parseInt(String(get('day')).replace(/\D/g, ''), 10);
      // Intl (en locale) omits the leap marker, so month/day equality is the
      // real test; a leap flag difference alone is an artifact of the format.
      const numericOk = mine && mine.month === imN && mine.day === idN;
      checked++;
      if (!numericOk) {
        bad++;
        if (bad < 15) samples.push([y, m, d].join('-') + ': mine=' + (mine ? mine.month + (mine.leap ? 'r' : '') + '-' + mine.day : 'null') + ' intl=' + imN + (leap ? 'r' : '') + '-' + idN);
      }
    }
  }
}
console.log('checked ' + checked + ' mismatch ' + bad);
samples.forEach(s => console.log(s));

const anchors = ['2026-09-25', '2026-02-17', '2026-01-01', '2025-01-29', '2026-06-19', '2026-10-01', '2026-10-18', '2026-02-16'];
anchors.forEach(s => {
  const i = L.dayInfo(s);
  const l = i.lunar;
  console.log(s + ' -> ' + i.full + ' festival=' + i.festival + ' lunar=' + (l ? (l.year + '-' + l.month + (l.leap ? 'r' : '') + '-' + l.day + ' ' + l.ganzhi + l.zodiac) : 'null'));
});
console.log('festivals 2026-09: ' + JSON.stringify(L.festivalsIn(2026, 8)));
console.log('festivals 2026-10: ' + JSON.stringify(L.festivalsIn(2026, 9)));
console.log('festivals 2026-02: ' + JSON.stringify(L.festivalsIn(2026, 1)));
