//! The synthetic user generator: personas with toolsets, latent daily modes, follower chains,
//! frontmost-app and device-state associations, drift on day 28 and a new favourite app on day 35.

use crate::catalog::{Cat, Item, Kind};
use crate::rng::Rng;
use slick_predict::context::{Ctx, NONE};
use std::collections::HashMap;

pub const DAY: f64 = 1440.0;
pub const N_DAYS: u32 = 56;
pub const DRIFT_DAY: u32 = 28;
pub const NEWAPP_DAY: u32 = 35;
type Dist = Vec<(u32, f64)>;

pub fn genp(name: &str, default: f64) -> f64 {
    std::env::var(format!("SIM_{name}"))
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

fn norm(d: &mut Dist) {
    let s: f64 = d.iter().map(|x| x.1).sum();
    if s > 0.0 {
        for x in d.iter_mut() {
            x.1 /= s;
        }
    }
}

pub struct Persona {
    pub base: Dist,
    pub modes: Vec<Dist>, // 0 startup 1 work-am 2 work-pm 3 meeting 4 evening 5 weekend 6 lunch
    pub followers: HashMap<u32, Dist>,
    pub front_assoc: HashMap<u32, Dist>,
    pub dev_head: Dist,
    pub dev_display: Dist,
    pub dev_battery: Dist,
    pub dev_focus: Dist,
    pub mix: [f64; 6], // repeat, seq, front, mode, device, base
    pub lam_work: f64,
    pub lam_weekend: f64,
    pub desk_p: f64,
    pub meet_p: f64,
    pub hour_w_work: [f64; 24],
    pub hour_w_weekend: [f64; 24],
    pub doc_app: u32,
    pub browser: u32,
    pub swaps: Vec<(u32, u32)>,
    pub new_app: u32,
    pub file_pool: Vec<u32>,
    pub active_files: Vec<u32>,
}

fn by_cat(cat: &[Item], c: Cat) -> Vec<u32> {
    cat.iter().filter(|i| i.cat == c).map(|i| i.id).collect()
}
fn by_name(cat: &[Item], n: &str) -> u32 {
    cat.iter()
        .find(|i| i.name == n)
        .map(|i| i.id)
        .unwrap_or_else(|| panic!("missing {n}"))
}
fn pick(rng: &mut Rng, v: &[u32]) -> u32 {
    v[rng.below(v.len())]
}
fn pick_n(rng: &mut Rng, v: &[u32], n: usize) -> Vec<u32> {
    let mut w = v.to_vec();
    rng.shuffle(&mut w);
    w.truncate(n.min(v.len()));
    w
}
fn pick_r(rng: &mut Rng, v: &[u32], lo: usize, extra: usize) -> Vec<u32> {
    let n = lo + rng.below(extra);
    pick_n(rng, v, n)
}
fn dir_dist(rng: &mut Rng, items: &[u32], alpha: f64) -> Dist {
    let mut it: Vec<u32> = items.to_vec();
    it.sort();
    it.dedup();
    let w = rng.dirichlet(it.len(), alpha);
    it.into_iter().zip(w).collect()
}

pub fn build_persona(cat: &[Item], rng: &mut Rng) -> Persona {
    let dev = rng.chance(0.6);
    let designer = rng.chance(0.35);
    let browser = pick(rng, &by_cat(cat, Cat::Browser));
    let mut chats = vec![pick(rng, &by_cat(cat, Cat::Chat))];
    if rng.chance(0.6) {
        chats.push(by_name(cat, "Messages"));
    }
    let mail = pick(rng, &by_cat(cat, Cat::Mail));
    let calendar = pick(rng, &by_cat(cat, Cat::Calendar));
    let video = pick(rng, &by_cat(cat, Cat::Video));
    let notes = pick_n(rng, &by_cat(cat, Cat::Notes), 2);
    let music = pick(rng, &by_cat(cat, Cat::Music));
    let office = pick_r(rng, &by_cat(cat, Cat::Office), 2, 2);
    let utils = pick_r(rng, &by_cat(cat, Cat::Util), 4, 3);
    let leisure = pick_r(rng, &by_cat(cat, Cat::Leisure), 3, 3);
    let ide: Vec<u32> = if dev {
        vec![pick(rng, &by_cat(cat, Cat::Ide))]
    } else {
        vec![]
    };
    let term: Vec<u32> = if dev {
        vec![pick(rng, &by_cat(cat, Cat::Terminal))]
    } else {
        vec![]
    };
    let devtools: Vec<u32> = if dev {
        pick_r(rng, &by_cat(cat, Cat::Dev), 2, 3)
    } else {
        vec![]
    };
    let design: Vec<u32> = if designer {
        pick_n(rng, &by_cat(cat, Cat::Design), 2)
    } else {
        vec![by_name(cat, "Preview")]
    };
    let cmd_win = pick_r(rng, &by_cat(cat, Cat::CmdWindow), 3, 4);
    let cmd_sys = pick_r(rng, &by_cat(cat, Cat::CmdSystem), 2, 3);
    let cmd_search = pick_r(rng, &by_cat(cat, Cat::CmdSearch), 2, 4);
    let cmd_util = pick_r(rng, &by_cat(cat, Cat::CmdUtil), 3, 4);
    let cmd_meet = pick_r(rng, &by_cat(cat, Cat::CmdMeeting), 1, 2);
    let cmd_music = pick_r(rng, &by_cat(cat, Cat::CmdMusic), 1, 2);
    let cmd_power = pick_n(rng, &by_cat(cat, Cat::CmdPower), 1);
    let files_all = by_cat(cat, Cat::File);
    let mut file_pool = files_all.clone();
    rng.shuffle(&mut file_pool);
    let active_files: Vec<u32> = file_pool.drain(..6 + rng.below(6)).collect();
    let doc_app = office[0];

    let cat_c = |v: &[Vec<u32>]| -> Vec<u32> { v.iter().flatten().copied().collect() };
    let work: Vec<u32> = cat_c(&[
        ide.clone(),
        term.clone(),
        vec![browser],
        notes.clone(),
        chats[..1].to_vec(),
        office.clone(),
        design.clone(),
        devtools.clone(),
        cmd_win.clone(),
        cmd_search.clone(),
        cmd_util.clone(),
        active_files.clone(),
        vec![mail],
    ]);
    let am = genp("ALPHA_MULT", 0.2);
    let modes = vec![
        dir_dist(
            rng,
            &cat_c(&[vec![mail, calendar, browser], chats.clone(), cmd_meet.clone()]),
            0.8 * am,
        ),
        dir_dist(rng, &work, 0.5 * am),
        dir_dist(rng, &work, 0.5 * am),
        dir_dist(
            rng,
            &cat_c(&[vec![video, calendar], notes[..1].to_vec(), cmd_meet.clone()]),
            0.8 * am,
        ),
        dir_dist(
            rng,
            &cat_c(&[vec![music, browser], chats.clone(), leisure.clone(), cmd_music.clone()]),
            0.6 * am,
        ),
        dir_dist(
            rng,
            &cat_c(&[vec![music, browser], chats.clone(), leisure.clone(), notes.clone()]),
            0.6 * am,
        ),
        dir_dist(
            rng,
            &cat_c(&[vec![browser], chats.clone(), leisure[..1].to_vec(), vec![music]]),
            0.7 * am,
        ),
    ];
    let mut active: Vec<u32> = cat_c(&[
        vec![browser, mail, calendar, video, music],
        chats.clone(),
        notes.clone(),
        office.clone(),
        utils.clone(),
        leisure.clone(),
        ide.clone(),
        term.clone(),
        devtools.clone(),
        design.clone(),
        cmd_win.clone(),
        cmd_sys.clone(),
        cmd_search.clone(),
        cmd_util.clone(),
        cmd_meet.clone(),
        cmd_music.clone(),
        cmd_power.clone(),
        active_files.clone(),
    ]);
    active.sort();
    active.dedup();
    // base: half Zipf over a random order, half "background" (utils + system commands)
    let mut order = active.clone();
    rng.shuffle(&mut order);
    let mut base: Dist = order
        .iter()
        .enumerate()
        .map(|(k, &i)| (i, 1.0 / (k as f64 + 1.0).powf(genp("ZIPF", 2.0))))
        .collect();
    norm(&mut base);
    for &u in utils.iter().chain(cmd_sys.iter()) {
        base.push((u, genp("BG", 0.005)));
    }
    norm(&mut base);
    // sequential followers (semantic pairs + random)
    let mut followers: HashMap<u32, Dist> = HashMap::new();
    let bw: Vec<f64> = base.iter().map(|x| x.1).collect();
    for &a in &active {
        if rng.chance(genp("FOLLOW_P", 0.6)) {
            let n = 1 + rng.below(2);
            let mut fs = Vec::new();
            for _ in 0..n {
                let j = base[rng.weighted(&bw)].0;
                if j != a {
                    fs.push(j);
                }
            }
            if !fs.is_empty() {
                followers.insert(a, dir_dist(rng, &fs, genp("FOLLOW_ALPHA", 0.3)));
            }
        }
    }
    let sem = |a: u32, b: u32, p: f64, followers: &mut HashMap<u32, Dist>| {
        let e = followers.entry(a).or_default();
        for x in e.iter_mut() {
            x.1 *= 1.0 - p;
        }
        e.push((b, p));
    };
    sem(calendar, video, 0.5, &mut followers);
    sem(mail, calendar, 0.4, &mut followers);
    if dev {
        sem(ide[0], term[0], 0.5, &mut followers);
        sem(term[0], browser, 0.3, &mut followers);
    }
    // frontmost-app associations
    let mut front_assoc: HashMap<u32, Dist> = HashMap::new();
    let apps: Vec<u32> = active
        .iter()
        .copied()
        .filter(|&i| cat[i as usize].kind == Kind::App)
        .collect();
    for &a in &apps {
        let n = 2 + rng.below(3);
        let mut v = Vec::new();
        for _ in 0..n {
            v.push(base[rng.weighted(&bw)].0);
        }
        v.retain(|&x| x != a);
        if dev && a == ide[0] {
            v.push(term[0]);
            v.extend(devtools.iter().take(1));
        }
        if a == browser {
            v.extend(cmd_search.iter().take(1));
        }
        if !v.is_empty() {
            front_assoc.insert(a, dir_dist(rng, &v, genp("FRONT_ALPHA", 0.3)));
        }
    }
    let pp = by_name(cat, "Play Pause");
    let sao = by_name(cat, "Switch Audio Output");
    let wlc = by_name(cat, "Window Layout: Coding");
    let lh = by_name(cat, "Left Half");
    let bat = by_name(cat, "Battery Status");
    let lpm = by_name(cat, "Low Power Mode");
    let dnd = by_name(cat, "Toggle Do Not Disturb");
    for x in [pp, sao, wlc, lh, bat, lpm, dnd] {
        if !active.contains(&x) {
            active.push(x);
        }
    }
    let dev_head = dir_dist(rng, &[music, pp, sao], 1.0);
    let mut dl = vec![wlc, lh];
    dl.extend(ide.iter());
    let dev_display = dir_dist(rng, &dl, 1.0);
    let dev_battery = dir_dist(rng, &[bat, lpm], 1.0);
    let mut fl = vec![dnd, notes[0]];
    fl.extend(ide.iter());
    let dev_focus = dir_dist(rng, &fl, 1.0);

    // drift: 3 swaps of high-usage items to an unused item of the same category
    let mut swaps = Vec::new();
    let mut top: Vec<(u32, f64)> = base.clone();
    top.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap());
    let mut used_b: Vec<u32> = Vec::new();
    for &(a, _) in top.iter() {
        if swaps.len() >= 3 {
            break;
        }
        let it = &cat[a as usize];
        if it.kind == Kind::File {
            continue;
        }
        let same: Vec<u32> = cat
            .iter()
            .filter(|x| x.cat == it.cat && !active.contains(&x.id) && !used_b.contains(&x.id))
            .map(|x| x.id)
            .collect();
        if same.is_empty() {
            continue;
        }
        let b = pick(rng, &same);
        used_b.push(b);
        swaps.push((a, b));
    }
    // new favourite app: an unused app
    let unused_apps: Vec<u32> = cat
        .iter()
        .filter(|x| x.kind == Kind::App && !active.contains(&x.id) && !used_b.contains(&x.id))
        .map(|x| x.id)
        .collect();
    let new_app = pick(rng, &unused_apps);

    let shift = rng.range(-1.0, 2.0);
    let mut hw = [0.0; 24];
    let wk = [
        0., 0., 0., 0., 0., 0., 0.2, 0.6, 1.2, 1.5, 1.5, 1.3, 0.8, 1.2, 1.4, 1.4, 1.3, 1.0, 0.6, 0.5, 0.6, 0.6, 0.4,
        0.2,
    ];
    for (h, w) in hw.iter_mut().enumerate() {
        let src = ((h as f64 - shift).round() as i32).rem_euclid(24) as usize;
        *w = wk[src] * (0.3 * rng.normal()).exp();
    }
    let mut hwe = [0.0; 24];
    for (h, w) in hwe.iter_mut().enumerate() {
        *w = match h {
            0..=7 => 0.05,
            8..=11 => 0.7,
            12..=18 => 0.8,
            19..=22 => 1.0,
            _ => 0.3,
        } * (0.3 * rng.normal()).exp();
    }
    let mut mix = [
        rng.range(0.1, 0.3) * genp("W_REP", 3.0),
        rng.range(0.15, 0.45) * genp("W_SEQ", 1.3),
        rng.range(0.1, 0.35) * genp("W_FRONT", 1.0),
        rng.range(0.35, 0.7) * genp("W_MODE", 1.0),
        rng.range(0.1, 0.3) * genp("W_DEV", 1.0),
        rng.range(0.1, 0.3) * genp("W_BASE", 3.0),
    ];
    let s: f64 = mix.iter().sum();
    for m in mix.iter_mut() {
        *m /= s;
    }
    Persona {
        base,
        modes,
        followers,
        front_assoc,
        dev_head,
        dev_display,
        dev_battery,
        dev_focus,
        mix,
        lam_work: rng.range(25.0, 60.0),
        lam_weekend: rng.range(6.0, 20.0),
        desk_p: rng.range(0.5, 0.9),
        meet_p: rng.range(0.15, 0.4),
        hour_w_work: hw,
        hour_w_weekend: hwe,
        doc_app,
        browser,
        swaps,
        new_app,
        file_pool,
        active_files,
    }
}

fn replace_in(d: &mut Dist, a: u32, b: u32) {
    for x in d.iter_mut() {
        if x.0 == a {
            x.0 = b;
        }
    }
}
fn replace_item(p: &mut Persona, a: u32, b: u32) {
    replace_in(&mut p.base, a, b);
    for m in p.modes.iter_mut() {
        replace_in(m, a, b);
    }
    for d in p.followers.values_mut() {
        replace_in(d, a, b);
    }
    if let Some(d) = p.followers.remove(&a) {
        p.followers.insert(b, d);
    }
    for d in p.front_assoc.values_mut() {
        replace_in(d, a, b);
    }
    if let Some(d) = p.front_assoc.remove(&a) {
        p.front_assoc.insert(b, d);
    }
    for d in [
        &mut p.dev_head,
        &mut p.dev_display,
        &mut p.dev_battery,
        &mut p.dev_focus,
    ] {
        replace_in(d, a, b);
    }
    if p.browser == a {
        p.browser = b;
    }
    if p.doc_app == a {
        p.doc_app = b;
    }
}

#[derive(Clone, Copy)]
pub struct Ev {
    pub ctx: Ctx,
    pub y: u32,
    pub oracle: [u32; 5],
    pub day: u32,
}

pub fn generate(cat: &[Item], p: &mut Persona, rng: &mut Rng) -> Vec<Ev> {
    let n = cat.len();
    let mut out = Vec::new();
    let mut front = p.browser;
    let mut prev = NONE;
    let mut t_prev = f64::NEG_INFINITY;
    let mut pbuf = vec![0.0f64; n];
    for day in 0..N_DAYS {
        if day == DRIFT_DAY {
            let sw = p.swaps.clone();
            for (a, b) in sw {
                replace_item(p, a, b);
            }
        }
        if day == NEWAPP_DAY {
            let na = p.new_app;
            for m in [1usize, 2] {
                for x in p.modes[m].iter_mut() {
                    x.1 *= 0.75;
                }
                p.modes[m].push((na, 0.25));
            }
            for x in p.base.iter_mut() {
                x.1 *= 0.85;
            }
            p.base.push((na, 0.15));
            let assoc = p.modes[1].iter().take(3).map(|x| (x.0, 1.0 / 3.0)).collect();
            p.front_assoc.insert(na, assoc);
        }
        if day > 0 && day % 7 == 0 && !p.file_pool.is_empty() {
            // file churn: ~30% of active files replaced by new documents
            let k = (p.active_files.len() as f64 * 0.3).ceil() as usize;
            for _ in 0..k {
                if p.file_pool.is_empty() {
                    break;
                }
                let idx = rng.below(p.active_files.len());
                let old = p.active_files[idx];
                let new = p.file_pool.pop().unwrap();
                p.active_files[idx] = new;
                replace_item(p, old, new);
            }
        }
        let weekday = (day % 7) as u8; // day 0 = Monday
        let weekend = weekday >= 5;
        if weekend && rng.chance(0.15) {
            continue;
        }
        let lam = if weekend { p.lam_weekend } else { p.lam_work };
        let hw = if weekend { p.hour_w_weekend } else { p.hour_w_work };
        let at_desk = !weekend && rng.chance(p.desk_p);
        let ext_weekend = weekend && rng.chance(0.1);
        let mut meeting = [None::<f64>; 24];
        let mut head = [false; 24];
        let mut batt = [false; 24];
        let mut focus = [false; 24];
        for h in 0..24 {
            let display = (at_desk && (9..18).contains(&h)) || ext_weekend;
            if !weekend && (9..18).contains(&h) && rng.chance(p.meet_p) {
                meeting[h] = Some(if rng.chance(0.3) { 30.0 } else { 0.0 });
            }
            let ph = if meeting[h].is_some() {
                0.7
            } else if weekend {
                0.35
            } else if (9..18).contains(&h) {
                0.3
            } else {
                0.45
            };
            head[h] = rng.chance(ph);
            batt[h] = !display && rng.chance(0.65);
            focus[h] = !weekend && (9..18).contains(&h) && rng.chance(0.3);
        }
        // summon times: clustered episodes + meeting joins
        let mut times: Vec<f64> = Vec::new();
        let n_ep = rng.poisson(lam / 2.0);
        for _ in 0..n_ep {
            let h = rng.weighted(&hw);
            let mut t = day as f64 * DAY + h as f64 * 60.0 + rng.range(0.0, 60.0);
            times.push(t);
            while rng.chance(0.5) {
                t += 0.2 + rng.exp(1.5);
                times.push(t);
            }
        }
        for (h, slot) in meeting.iter().enumerate() {
            if let Some(m) = *slot
                && rng.chance(0.6)
            {
                times.push(day as f64 * DAY + h as f64 * 60.0 + m - rng.range(0.0, 4.0));
            }
        }
        times.sort_by(|a, b| a.partial_cmp(b).unwrap());
        for &t in &times {
            if t >= (day + 1) as f64 * DAY {
                continue;
            }
            let mins_in_day = t - day as f64 * DAY;
            let h = (mins_in_day / 60.0) as usize % 24;
            let since = t - t_prev;
            let session_start = since > 120.0;
            // meeting now: within 5 min before / 5 after a start in this or next hour
            let mut meet_now = false;
            for hh in [h, (h + 1) % 24] {
                if let Some(m) = meeting[hh] {
                    let start = (hh as f64) * 60.0 + m + if hh < h { 1440.0 } else { 0.0 };
                    let d = mins_in_day - start;
                    if (-5.0..=5.0).contains(&d) {
                        meet_now = true;
                    }
                }
            }
            let mut mode: u8 = if weekend {
                if h >= 19 && rng.chance(0.5) { 4 } else { 5 }
            } else {
                match h {
                    0..=8 => {
                        if rng.chance(0.5) {
                            0
                        } else {
                            4
                        }
                    }
                    9..=11 => 1,
                    12 => 6,
                    13..=17 => 2,
                    _ => 4,
                }
            };
            if session_start && rng.chance(0.6) {
                mode = 0;
            }
            if meet_now && rng.chance(0.8) {
                mode = 3;
            }
            if rng.chance(genp("MODE_NOISE", 0.06)) {
                mode = [1u8, 2, 4, 5, 6][rng.below(5)];
            }
            // frontmost may have changed outside the launcher
            if since > 2.0 && rng.chance(genp("FRONT_SWITCH", 0.35)) {
                let md = &p.modes[mode as usize];
                let apps: Vec<(u32, f64)> = md
                    .iter()
                    .copied()
                    .filter(|x| cat[x.0 as usize].kind == Kind::App)
                    .collect();
                if !apps.is_empty() {
                    let w: Vec<f64> = apps.iter().map(|x| x.1).collect();
                    front = apps[rng.weighted(&w)].0;
                }
            }
            let display = (at_desk && (9..18).contains(&h)) || ext_weekend;
            let ctx = Ctx {
                t,
                hour: h as u8,
                weekday,
                front,
                prev,
                since_prev: since,
                session_start,
                ext_display: display,
                headphones: head[h],
                on_battery: batt[h],
                focus: focus[h],
            };
            // true choice distribution
            for x in pbuf.iter_mut() {
                *x = 0.0;
            }
            let m = &p.mix;
            if since < 3.0 && prev != front && prev != NONE {
                pbuf[prev as usize] += m[0];
            }
            if since < 15.0
                && let Some(f) = p.followers.get(&prev)
            {
                for &(j, q) in f {
                    pbuf[j as usize] += m[1] * q;
                }
            }
            if let Some(f) = p.front_assoc.get(&front) {
                for &(j, q) in f {
                    pbuf[j as usize] += m[2] * q;
                }
            }
            for &(j, q) in &p.modes[mode as usize] {
                pbuf[j as usize] += m[3] * q;
            }
            let mut devs: Vec<&Dist> = Vec::new();
            if ctx.headphones {
                devs.push(&p.dev_head);
            }
            if ctx.ext_display {
                devs.push(&p.dev_display);
            }
            if ctx.on_battery && rng.chance(0.3) {
                devs.push(&p.dev_battery);
            }
            if ctx.focus {
                devs.push(&p.dev_focus);
            }
            let nd = devs.len().max(1) as f64;
            for d in devs {
                for &(j, q) in d {
                    pbuf[j as usize] += m[4] * q / nd;
                }
            }
            for &(j, q) in &p.base {
                pbuf[j as usize] += m[5] * q;
            }
            if front != NONE {
                pbuf[front as usize] = 0.0;
            }
            if day < NEWAPP_DAY {
                pbuf[p.new_app as usize] = 0.0;
            }
            let y = rng.weighted(&pbuf) as u32;
            // oracle top-5 under the true distribution
            let mut o = [(0.0, NONE); 5];
            for (j, &q) in pbuf.iter().enumerate() {
                if q > o[4].0 {
                    o[4] = (q, j as u32);
                    let mut k = 4;
                    while k > 0 && o[k].0 > o[k - 1].0 {
                        o.swap(k, k - 1);
                        k -= 1;
                    }
                }
            }
            out.push(Ev {
                ctx,
                y,
                oracle: [o[0].1, o[1].1, o[2].1, o[3].1, o[4].1],
                day,
            });
            prev = y;
            t_prev = t;
            match cat[y as usize].kind {
                Kind::App => front = y,
                Kind::File => front = p.doc_app,
                Kind::Command => {}
            }
        }
    }
    out
}
