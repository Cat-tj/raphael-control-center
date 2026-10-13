//! Five-field cron expressions (plus @macros), evaluated in a fixed UTC offset (the device's).
//! Same rules as Jobs.swift / core.py.

use chrono::{DateTime, Datelike, Duration, FixedOffset, TimeZone, Timelike};
use std::collections::BTreeSet;

const MONTHS: [&str; 12] = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
const DAYS: [&str; 7] = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];
const DAY_NAMES: [&str; 7] = ["Minggu", "Senin", "Selasa", "Rabu", "Kamis", "Jumat", "Sabtu"];

#[derive(Debug, Clone)]
pub struct CronExpr {
    minutes: BTreeSet<u32>,
    hours: BTreeSet<u32>,
    days: BTreeSet<u32>,
    months: BTreeSet<u32>,
    weekdays: BTreeSet<u32>,
    any_day: bool,
    any_weekday: bool,
    source: String,
}

fn field(f: &str, lo: u32, hi: u32, names: &[&str]) -> Option<BTreeSet<u32>> {
    let mut out = BTreeSet::new();
    for part in f.to_lowercase().split(',') {
        let sp: Vec<&str> = part.split('/').collect();
        let step: u32 = if sp.len() > 1 { sp[1].parse().ok()? } else { 1 };
        if step == 0 {
            return None;
        }
        let num = |t: &str| -> Option<u32> {
            if !t.is_empty() && t.chars().all(|c| c.is_ascii_digit()) {
                return t.parse().ok();
            }
            names.iter().position(|n| *n == t).map(|i| i as u32 + if lo == 1 { 1 } else { 0 })
        };
        let (mut a, mut b) = (lo, hi);
        if sp[0] != "*" {
            let ends: Vec<&str> = sp[0].split('-').collect();
            let x = num(ends[0])?;
            a = x;
            b = if ends.len() > 1 { num(ends[1]).unwrap_or(x) } else if sp.len() > 1 { hi } else { x };
        }
        if a < lo || b > hi || a > b {
            return None;
        }
        let mut v = a;
        while v <= b {
            out.insert(v);
            v += step;
        }
    }
    Some(out)
}

impl CronExpr {
    pub fn parse(raw: &str) -> Option<CronExpr> {
        let s = raw.trim();
        let s = match s {
            "@yearly" | "@annually" => "0 0 1 1 *",
            "@monthly" => "0 0 1 * *",
            "@weekly" => "0 0 * * 0",
            "@daily" | "@midnight" => "0 0 * * *",
            "@hourly" => "0 * * * *",
            x => x,
        };
        let f: Vec<&str> = s.split_whitespace().collect();
        if f.len() != 5 {
            return None;
        }
        let w = field(f[4], 0, 7, &DAYS)?;
        Some(CronExpr {
            minutes: field(f[0], 0, 59, &[])?,
            hours: field(f[1], 0, 23, &[])?,
            days: field(f[2], 1, 31, &[])?,
            months: field(f[3], 1, 12, &MONTHS)?,
            weekdays: w.into_iter().map(|x| if x == 7 { 0 } else { x }).collect(),
            any_day: f[2] == "*",
            any_weekday: f[4] == "*",
            source: raw.to_string(),
        })
    }

    fn day_ok(&self, t: &DateTime<FixedOffset>) -> bool {
        let dom = self.days.contains(&t.day());
        let dow = self.weekdays.contains(&t.weekday().num_days_from_sunday());
        match (self.any_day, self.any_weekday) {
            (true, true) => true,
            (true, false) => dow,
            (false, true) => dom,
            _ => dom || dow,
        }
    }

    fn at(ts: i64, tz: i32) -> DateTime<FixedOffset> {
        let zone = FixedOffset::east_opt(tz).unwrap_or(FixedOffset::east_opt(0).unwrap());
        zone.timestamp_opt(ts, 0).single().unwrap()
    }

    /// First matching minute strictly after `after` (unix seconds).
    pub fn next(&self, after: f64, tz: i32) -> Option<f64> {
        let mut t = Self::at((after as i64).div_euclid(60) * 60 + 60, tz);
        for _ in 0..(366 * 24 * 60) {
            if !self.months.contains(&t.month()) || !self.day_ok(&t) {
                t = (t + Duration::days(1)).with_hour(0)?.with_minute(0)?;
                continue;
            }
            if !self.hours.contains(&t.hour()) {
                t = t.with_minute(0)? + Duration::hours(1);
                continue;
            }
            if self.minutes.contains(&t.minute()) {
                return Some(t.timestamp() as f64);
            }
            t += Duration::minutes(1);
        }
        None
    }

    /// Last matching minute at or before `before`.
    pub fn previous(&self, before: f64, tz: i32) -> Option<f64> {
        let mut t = Self::at((before as i64).div_euclid(60) * 60, tz);
        for _ in 0..(400 * 24 * 60) {
            if !self.months.contains(&t.month()) || !self.day_ok(&t) {
                t = t.with_hour(0)?.with_minute(0)? - Duration::minutes(1);
                continue;
            }
            if !self.hours.contains(&t.hour()) {
                t = t.with_minute(0)? - Duration::minutes(1);
                continue;
            }
            if self.minutes.contains(&t.minute()) {
                return Some(t.timestamp() as f64);
            }
            t -= Duration::minutes(1);
        }
        None
    }

    pub fn describe(&self) -> String {
        if self.source.split_whitespace().count() != 5 {
            return self.source.clone();
        }
        let first = |s: &BTreeSet<u32>| *s.iter().next().unwrap_or(&0);
        if self.minutes.len() == 60 && self.hours.len() == 24 {
            return "tiap menit".into();
        }
        if self.hours.len() == 24 && self.any_day && self.any_weekday && self.months.len() == 12 {
            return if self.minutes.len() == 1 {
                format!("tiap jam, menit {}", first(&self.minutes))
            } else {
                format!("tiap {} menit", 60 / self.minutes.len().max(1))
            };
        }
        let time = if self.hours.len() == 1 && self.minutes.len() == 1 {
            Some(format!("{:02}:{:02}", first(&self.hours), first(&self.minutes)))
        } else {
            None
        };
        if let Some(time) = time {
            if self.any_day && self.any_weekday && self.months.len() == 12 {
                return format!("tiap hari {time}");
            }
            if self.any_day && !self.any_weekday && self.weekdays.len() == 1 {
                return format!("tiap {} {time}", DAY_NAMES[first(&self.weekdays) as usize]);
            }
            if !self.any_day && self.any_weekday && self.days.len() == 1 {
                return format!("tiap tanggal {} {time}", first(&self.days));
            }
        }
        self.source.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const TZ: i32 = 8 * 3600;

    fn base() -> f64 {
        FixedOffset::east_opt(TZ).unwrap().with_ymd_and_hms(2026, 10, 11, 19, 7, 0).unwrap().timestamp() as f64 // a Sunday
    }
    fn hm(t: Option<f64>) -> String {
        match t {
            None => "nil".into(),
            Some(t) => {
                let d = CronExpr::at(t as i64, TZ);
                format!("{} {}:{} w{}", d.day(), d.hour(), d.minute(), d.weekday().num_days_from_sunday() + 1)
            }
        }
    }
    fn c(s: &str) -> CronExpr {
        CronExpr::parse(s).unwrap()
    }

    #[test]
    fn same_cases_as_swift() {
        assert_eq!(hm(c("30 2 * * *").next(base(), TZ)), "12 2:30 w2");
        assert_eq!(hm(c("30 2 * * *").previous(base(), TZ)), "11 2:30 w1");
        assert_eq!(hm(c("5-55/10 * * * *").next(base(), TZ)), "11 19:15 w1");
        assert_eq!(hm(c("0 8 * * 1").next(base(), TZ)), "12 8:0 w2");
        assert_eq!(hm(c("@hourly").next(base(), TZ)), "11 20:0 w1");
        assert!(hm(c("0 0 1 * *").next(base(), TZ)).starts_with("1 0:0"));
        assert!(CronExpr::parse("bad expr").is_none());
        assert!(CronExpr::parse("61 * * * *").is_none());
        assert_eq!(c("30 2 * * *").describe(), "tiap hari 02:30");
    }

    #[test]
    fn more_shapes() {
        assert_eq!(hm(c("*/15 * * * *").next(base(), TZ)), "11 19:15 w1");
        assert_eq!(hm(c("0 9 * * mon-fri").next(base(), TZ)), "12 9:0 w2");
        assert_eq!(hm(c("0 0 * * 7").next(base(), TZ)), "18 0:0 w1");
        assert_eq!(hm(c("0 12 15 * 1").next(base(), TZ)), "12 12:0 w2");
        assert_eq!(c("0 8 * * 1").describe(), "tiap Senin 08:00");
        assert_eq!(c("*/5 * * * *").describe(), "tiap 5 menit");
        assert_eq!(hm(c("59 23 31 12 *").previous(base(), TZ)), "31 23:59 w4");
        assert!(CronExpr::parse("* * * *").is_none());
        assert!(CronExpr::parse("*/0 * * * *").is_none());
    }
}
