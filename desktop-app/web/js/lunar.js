/* Chinese lunar calendar + festival lookup.
 *
 * Why a hand-rolled conversion table instead of Intl.DateTimeFormat with
 * calendar:'chinese': the Intl output is a *localised string* ("九月十五"
 * vs "9月15日" depending on engine/version), so using it means parsing prose
 * that differs per browser. The arithmetic here returns structured numbers,
 * which is what the views actually need (lunar month/day for the cell label,
 * and a month/day pair to look festivals up by).
 *
 * LUNAR_INFO covers 1900-2100: 16 bits per year -- low 4 bits are the leap
 * month (0 = none), the next 12 bits flag 30-day months (1) vs 29 (0), and
 * bit 16 is the leap month's own length. Outside that range every function
 * returns null rather than a wrong date.
 */
(function () {
  'use strict';

  var START = 1900, END = 2100;

  var LUNAR_INFO = [
    0x04bd8, 0x04ae0, 0x0a570, 0x054d5, 0x0d260, 0x0d950, 0x16554, 0x056a0, 0x09ad0, 0x055d2, // 1900-1909
    0x04ae0, 0x0a5b6, 0x0a4d0, 0x0d250, 0x1d255, 0x0b540, 0x0d6a0, 0x0ada2, 0x095b0, 0x14977, // 1910-1919
    0x04970, 0x0a4b0, 0x0b4b5, 0x06a50, 0x06d40, 0x1ab54, 0x02b60, 0x09570, 0x052f2, 0x04970, // 1920-1929
    0x06566, 0x0d4a0, 0x0ea50, 0x06e95, 0x05ad0, 0x02b60, 0x186e3, 0x092e0, 0x1c8d7, 0x0c950, // 1930-1939
    0x0d4a0, 0x1d8a6, 0x0b550, 0x056a0, 0x1a5b4, 0x025d0, 0x092d0, 0x0d2b2, 0x0a950, 0x0b557, // 1940-1949
    0x06ca0, 0x0b550, 0x15355, 0x04da0, 0x0a5b0, 0x14573, 0x052b0, 0x0a9a8, 0x0e950, 0x06aa0, // 1950-1959
    0x0aea6, 0x0ab50, 0x04b60, 0x0aae4, 0x0a570, 0x05260, 0x0f263, 0x0d950, 0x05b57, 0x056a0, // 1960-1969
    0x096d0, 0x04dd5, 0x04ad0, 0x0a4d0, 0x0d4d4, 0x0d250, 0x0d558, 0x0b540, 0x0b6a0, 0x195a6, // 1970-1979
    0x095b0, 0x049b0, 0x0a974, 0x0a4b0, 0x0b27a, 0x06a50, 0x06d40, 0x0af46, 0x0ab60, 0x09570, // 1980-1989
    0x04af5, 0x04970, 0x064b0, 0x074a3, 0x0ea50, 0x06b58, 0x055c0, 0x0ab60, 0x096d5, 0x092e0, // 1990-1999
    0x0c960, 0x0d954, 0x0d4a0, 0x0da50, 0x07552, 0x056a0, 0x0abb7, 0x025d0, 0x092d0, 0x0cab5, // 2000-2009
    0x0a950, 0x0b4a0, 0x0baa4, 0x0ad50, 0x055d9, 0x04ba0, 0x0a5b0, 0x15176, 0x052b0, 0x0a930, // 2010-2019
    0x07954, 0x06aa0, 0x0ad50, 0x05b52, 0x04b60, 0x0a6e6, 0x0a4e0, 0x0d260, 0x0ea65, 0x0d530, // 2020-2029
    0x05aa0, 0x076a3, 0x096d0, 0x04afb, 0x04ad0, 0x0a4d0, 0x1d0b6, 0x0d250, 0x0d520, 0x0dd45, // 2030-2039
    0x0b5a0, 0x056d0, 0x055b2, 0x049b0, 0x0a577, 0x0a4b0, 0x0aa50, 0x1b255, 0x06d20, 0x0ada0, // 2040-2049
    0x14b63, 0x09370, 0x049f8, 0x04970, 0x064b0, 0x168a6, 0x0ea50, 0x06b20, 0x1a6c4, 0x0aae0, // 2050-2059
    0x0a2e0, 0x0d2e3, 0x0c960, 0x0d557, 0x0d4a0, 0x0da50, 0x05d55, 0x056a0, 0x0a6d0, 0x055d4, // 2060-2069
    0x052d0, 0x0a9b8, 0x0a950, 0x0b4a0, 0x0b6a6, 0x0ad50, 0x055a0, 0x0aba4, 0x0a5b0, 0x052b0, // 2070-2079
    0x0b273, 0x06930, 0x07337, 0x06aa0, 0x0ad50, 0x14b55, 0x04b60, 0x0a570, 0x054e4, 0x0d160, // 2080-2089
    0x0e968, 0x0d520, 0x0daa0, 0x16aa6, 0x056d0, 0x04ae0, 0x0a9d4, 0x0a2d0, 0x0d150, 0x0f252, // 2090-2099
    0x0d520                                                                                     // 2100
  ];

  var MONTH_ZH = ['正', '二', '三', '四', '五', '六', '七', '八', '九', '十', '冬', '腊'];
  var DAY_ZH_1 = ['初一', '初二', '初三', '初四', '初五', '初六', '初七', '初八', '初九', '初十'];
  var TENS = ['初', '十', '廿', '三'];
  var NUM_ZH = ['零', '一', '二', '三', '四', '五', '六', '七', '八', '九', '十'];
  var ZODIAC_ZH = ['鼠', '牛', '虎', '兔', '龙', '蛇', '马', '羊', '猴', '鸡', '狗', '猪'];
  var ZODIAC_EN = ['Rat', 'Ox', 'Tiger', 'Rabbit', 'Dragon', 'Snake', 'Horse', 'Goat', 'Monkey',
    'Rooster', 'Dog', 'Pig'];
  var GAN_ZH = ['甲', '乙', '丙', '丁', '戊', '己', '庚', '辛', '壬', '癸'];
  var ZHI_ZH = ['子', '丑', '寅', '卯', '辰', '巳', '午', '未', '申', '酉', '戌', '亥'];

  function info(y) { return LUNAR_INFO[y - START]; }
  function inRange(y) { return y >= START && y <= END; }

  function leapMonth(y) { return inRange(y) ? (info(y) & 0xf) : 0; }
  function leapDays(y) {
    if (!leapMonth(y)) return 0;
    return (info(y) & 0x10000) ? 30 : 29;
  }
  function monthDays(y, m) {
    if (!inRange(y) || m < 1 || m > 12) return 0;
    return (info(y) & (0x10000 >> m)) ? 30 : 29;
  }
  function yearDays(y) {
    var n = 0;
    for (var m = 1; m <= 12; m++) n += monthDays(y, m);
    return n + leapDays(y);
  }

  /* Days from 1900-01-31 (== lunar 1900-01-01) to the given civil date.
     UTC arithmetic: local time would add or drop an hour across a DST switch
     and could land the offset on the wrong day. */
  function offsetDays(y, m, d) {
    return Math.floor((Date.UTC(y, m - 1, d) - Date.UTC(1900, 0, 31)) / 86400000);
  }

  function fromDate(date) {
    if (!date || !(date instanceof Date) || isNaN(date.getTime())) return null;
    var y = date.getFullYear(), m = date.getMonth() + 1, d = date.getDate();
    var off = offsetDays(y, m, d);
    if (off < 0) return null;

    var ly = START;
    while (ly <= END) {
      var yd = yearDays(ly);
      if (off < yd) break;
      off -= yd;
      ly++;
    }
    if (ly > END) return null;

    var leap = leapMonth(ly);
    var months = [];
    for (var mm = 1; mm <= 12; mm++) {
      months.push({ month: mm, leap: false, days: monthDays(ly, mm) });
      if (leap > 0 && mm === leap) months.push({ month: mm, leap: true, days: leapDays(ly) });
    }
    var i = 0;
    while (i < months.length && off >= months[i].days) { off -= months[i].days; i++; }
    if (i >= months.length) return null;

    return {
      year: ly,
      month: months[i].month,
      day: off + 1,
      leap: months[i].leap,
      zodiac: ZODIAC_ZH[(ly - 4) % 12],
      ganzhi: GAN_ZH[(ly - 4) % 10] + ZHI_ZH[(ly - 4) % 12]
    };
  }

  function dayName(d) {
    if (d <= 10) return DAY_ZH_1[d - 1];
    if (d < 20) return '十' + NUM_ZH[d - 10];
    if (d === 20) return '二十';
    if (d < 30) return TENS[2] + NUM_ZH[d - 20];
    if (d === 30) return '三十';
    return String(d);
  }

  function monthName(m, leap) {
    return (leap ? '闰' : '') + MONTH_ZH[m - 1] + '月';
  }

  /* ---- festivals ------------------------------------------------------ */
  /* Two families: fixed civil dates, and dates anchored to the lunar month.
     Names are {zh,en} because the whole app is bilingual. */
  var SOLAR_FEST = {
    '01-01': { zh: '元旦', en: "New Year's Day" },
    '02-14': { zh: '情人节', en: "Valentine's Day" },
    '03-08': { zh: '妇女节', en: "Women's Day" },
    '03-12': { zh: '植树节', en: 'Arbor Day' },
    '04-01': { zh: '愚人节', en: 'April Fools' },
    '05-01': { zh: '劳动节', en: 'Labour Day' },
    '05-04': { zh: '青年节', en: 'Youth Day' },
    '06-01': { zh: '儿童节', en: "Children's Day" },
    '07-01': { zh: '建党节', en: 'Party Day' },
    '08-01': { zh: '建军节', en: 'Army Day' },
    '09-10': { zh: '教师节', en: "Teachers' Day" },
    '10-01': { zh: '国庆节', en: 'National Day' },
    '11-11': { zh: '双十一', en: 'Singles Day' },
    '12-24': { zh: '平安夜', en: 'Christmas Eve' },
    '12-25': { zh: '圣诞节', en: 'Christmas' }
  };

  var LUNAR_FEST = {
    '1-1': { zh: '春节', en: 'Spring Festival' },
    '1-15': { zh: '元宵节', en: 'Lantern Festival' },
    '2-2': { zh: '龙抬头', en: 'Dragon Head' },
    '5-5': { zh: '端午节', en: 'Dragon Boat' },
    '7-7': { zh: '七夕', en: 'Qixi' },
    '7-15': { zh: '中元节', en: 'Zhongyuan' },
    '8-15': { zh: '中秋节', en: 'Mid-Autumn' },
    '9-9': { zh: '重阳节', en: 'Chongyang' },
    '12-8': { zh: '腊八节', en: 'Laba' }
  };

  function pad2(n) { return (n < 10 ? '0' : '') + n; }

  /* Everything the UI needs about one civil day, in one call: the view
     renders the lunar label and, when there is one, the festival ribbon. */
  function dayInfo(dateStr) {
    var d = parseISODate(dateStr);
    if (!d) return { lunar: null, festival: null, text: '', short: '' };
    var l = fromDate(d);
    if (!l) return { lunar: null, festival: null, text: '', short: '' };

    var zh = window.lang ? window.lang() : 'zh';
    var text = zh === 'zh'
      ? (l.day === 1 ? monthName(l.month, l.leap) : dayName(l.day))
      : ('L' + l.month + '-' + l.day);
    var short = zh === 'zh' ? dayName(l.day) : (l.month + '/' + l.day);

    var fest = null;
    var key = l.month + '-' + l.day;
    /* Chuxi is the last day of the 12th lunar month, whose length varies. */
    if (l.month === 12 && !l.leap && l.day === monthDays(l.year, 12)) {
      fest = { zh: '除夕', en: 'New Year Eve' };
    }
    if (!fest && LUNAR_FEST[key]) fest = LUNAR_FEST[key];
    if (!fest) {
      var s = SOLAR_FEST[pad2(d.getMonth() + 1) + '-' + pad2(d.getDate())];
      if (s) fest = s;
    }
    /* A user-entered date always wins: it is their calendar, not ours. */
    var custom = customFestival(dateStr);
    if (custom) fest = { zh: custom, en: custom };

    return {
      lunar: l,
      festival: fest ? (zh === 'zh' ? fest.zh : fest.en) : null,
      text: text,
      short: short,
      full: zh === 'zh' ? monthName(l.month, l.leap) + dayName(l.day) : ('L' + l.month + '/' + l.day)
    };
  }

  function customFestival(dateStr) {
    try {
      var h = (window.Store && Store.settings && Store.settings.holidays) || {};
      return h[dateStr] || null;
    } catch (e) { return null; }
  }

  function parseISODate(s) {
    if (!s) return null;
    var p = String(s).split('-');
    if (p.length !== 3) return null;
    var y = parseInt(p[0], 10), m = parseInt(p[1], 10), d = parseInt(p[2], 10);
    if (!y || !m || !d) return null;
    return new Date(y, m - 1, d);
  }

  /* Festivals inside a month, used by the month view's summary line. */
  function festivalsIn(year, month) {
    var out = [];
    var days = new Date(year, month + 1, 0).getDate();
    for (var d = 1; d <= days; d++) {
      var s = year + '-' + pad2(month + 1) + '-' + pad2(d);
      var info = dayInfo(s);
      if (info.festival) out.push({ date: s, day: d, name: info.festival });
    }
    return out;
  }

  window.Lunar = {
    fromDate: fromDate,
    dayInfo: dayInfo,
    festivalsIn: festivalsIn,
    dayName: dayName,
    monthName: monthName,
    zodiac: function (y) { return { zh: ZODIAC_ZH[(y - 4) % 12], en: ZODIAC_EN[(y - 4) % 12] }; }
  };
})();
