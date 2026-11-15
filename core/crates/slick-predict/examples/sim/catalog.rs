//! The simulator's synthetic catalog: generic product and command names and synthetic file
//! names, plus QWERTY neighbours for synthetic typos. Matching uses slick-match.

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Kind {
    App,
    Command,
    File,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Cat {
    Browser,
    Chat,
    Mail,
    Calendar,
    Video,
    Ide,
    Terminal,
    Notes,
    Music,
    Design,
    Office,
    Util,
    Leisure,
    Dev,
    CmdWindow,
    CmdSystem,
    CmdSearch,
    CmdUtil,
    CmdMeeting,
    CmdMusic,
    CmdPower,
    File,
}

#[derive(Clone, Debug)]
pub struct Item {
    pub id: u32,
    pub name: String,
    pub lower: String,
    pub words: Vec<String>,
    pub initials: String,
    pub kind: Kind,
    pub cat: Cat,
}

const APPS: &[(&str, Cat)] = &[
    ("Safari", Cat::Browser),
    ("Google Chrome", Cat::Browser),
    ("Firefox", Cat::Browser),
    ("Arc", Cat::Browser),
    ("Microsoft Edge", Cat::Browser),
    ("Brave Browser", Cat::Browser),
    ("Slack", Cat::Chat),
    ("Messages", Cat::Chat),
    ("Discord", Cat::Chat),
    ("Microsoft Teams", Cat::Chat),
    ("Telegram", Cat::Chat),
    ("WhatsApp", Cat::Chat),
    ("Signal", Cat::Chat),
    ("Mail", Cat::Mail),
    ("Microsoft Outlook", Cat::Mail),
    ("Spark", Cat::Mail),
    ("Mimestream", Cat::Mail),
    ("Calendar", Cat::Calendar),
    ("Fantastical", Cat::Calendar),
    ("Notion Calendar", Cat::Calendar),
    ("Zoom", Cat::Video),
    ("FaceTime", Cat::Video),
    ("Webex", Cat::Video),
    ("Xcode", Cat::Ide),
    ("Visual Studio Code", Cat::Ide),
    ("Zed", Cat::Ide),
    ("IntelliJ IDEA", Cat::Ide),
    ("Cursor", Cat::Ide),
    ("Sublime Text", Cat::Ide),
    ("PyCharm", Cat::Ide),
    ("Nova", Cat::Ide),
    ("Terminal", Cat::Terminal),
    ("iTerm", Cat::Terminal),
    ("Ghostty", Cat::Terminal),
    ("Warp", Cat::Terminal),
    ("Notes", Cat::Notes),
    ("Obsidian", Cat::Notes),
    ("Notion", Cat::Notes),
    ("Bear", Cat::Notes),
    ("Craft", Cat::Notes),
    ("Reminders", Cat::Notes),
    ("Things", Cat::Notes),
    ("Stickies", Cat::Notes),
    ("Music", Cat::Music),
    ("Spotify", Cat::Music),
    ("Podcasts", Cat::Music),
    ("Overcast", Cat::Music),
    ("Figma", Cat::Design),
    ("Sketch", Cat::Design),
    ("Pixelmator Pro", Cat::Design),
    ("Affinity Designer", Cat::Design),
    ("Preview", Cat::Design),
    ("Photos", Cat::Design),
    ("Pages", Cat::Office),
    ("Numbers", Cat::Office),
    ("Keynote", Cat::Office),
    ("Microsoft Word", Cat::Office),
    ("Microsoft Excel", Cat::Office),
    ("Microsoft PowerPoint", Cat::Office),
    ("System Settings", Cat::Util),
    ("Activity Monitor", Cat::Util),
    ("Finder", Cat::Util),
    ("App Store", Cat::Util),
    ("Calculator", Cat::Util),
    ("Maps", Cat::Leisure),
    ("Weather", Cat::Leisure),
    ("Stocks", Cat::Leisure),
    ("News", Cat::Leisure),
    ("Books", Cat::Leisure),
    ("TV", Cat::Leisure),
    ("QuickTime Player", Cat::Leisure),
    ("Screenshot", Cat::Util),
    ("Console", Cat::Dev),
    ("Disk Utility", Cat::Util),
    ("Font Book", Cat::Util),
    ("Keychain Access", Cat::Util),
    ("Script Editor", Cat::Dev),
    ("Shortcuts", Cat::Util),
    ("Automator", Cat::Util),
    ("Simulator", Cat::Dev),
    ("Instruments", Cat::Dev),
    ("Docker", Cat::Dev),
    ("Postman", Cat::Dev),
    ("TablePlus", Cat::Dev),
    ("GitHub Desktop", Cat::Dev),
    ("Tower", Cat::Dev),
    ("1Password", Cat::Util),
    ("Bitwarden", Cat::Util),
    ("Home", Cat::Leisure),
    ("Freeform", Cat::Notes),
    ("Image Playground", Cat::Design),
    ("Passwords", Cat::Util),
    ("Photo Booth", Cat::Leisure),
    ("Voice Memos", Cat::Notes),
    ("Clock", Cat::Util),
    ("Contacts", Cat::Util),
    ("Find My", Cat::Util),
    ("Dictionary", Cat::Util),
    ("TextEdit", Cat::Notes),
    ("Transmit", Cat::Dev),
    ("VLC", Cat::Leisure),
    ("IINA", Cat::Leisure),
    ("Steam", Cat::Leisure),
    ("Chess", Cat::Leisure),
    ("Tips", Cat::Util),
    ("Journal", Cat::Notes),
    ("Games", Cat::Leisure),
    ("Sequel Ace", Cat::Dev),
    ("Proxyman", Cat::Dev),
    ("Raindrop", Cat::Util),
    ("Linear", Cat::Dev),
    ("Superhuman", Cat::Mail),
    ("Loom", Cat::Video),
    ("CleanShot", Cat::Util),
    ("Lightroom", Cat::Design),
];

const COMMANDS: &[(&str, Cat)] = &[
    ("Clipboard History", Cat::CmdUtil),
    ("Search Snippets", Cat::CmdUtil),
    ("Search Emoji & Symbols", Cat::CmdUtil),
    ("Search Files", Cat::CmdSearch),
    ("Search Screenshots", Cat::CmdSearch),
    ("Toggle Dark Mode", Cat::CmdSystem),
    ("Lock Screen", Cat::CmdSystem),
    ("Sleep", Cat::CmdSystem),
    ("Restart", Cat::CmdSystem),
    ("Shut Down", Cat::CmdSystem),
    ("Empty Trash", Cat::CmdSystem),
    ("Eject All Disks", Cat::CmdSystem),
    ("Toggle Wi-Fi", Cat::CmdSystem),
    ("Toggle Bluetooth", Cat::CmdSystem),
    ("Toggle Do Not Disturb", Cat::CmdSystem),
    ("Quit All Apps", Cat::CmdSystem),
    ("Hide All Apps", Cat::CmdSystem),
    ("Left Half", Cat::CmdWindow),
    ("Right Half", Cat::CmdWindow),
    ("Maximize", Cat::CmdWindow),
    ("Center Window", Cat::CmdWindow),
    ("Next Display", Cat::CmdWindow),
    ("Reasonable Size", Cat::CmdWindow),
    ("Top Half", Cat::CmdWindow),
    ("Bottom Half", Cat::CmdWindow),
    ("First Third", Cat::CmdWindow),
    ("Last Two Thirds", Cat::CmdWindow),
    ("Restore Window", Cat::CmdWindow),
    ("Toggle Fullscreen", Cat::CmdWindow),
    ("Window Layout: Coding", Cat::CmdWindow),
    ("Window Layout: Meeting", Cat::CmdWindow),
    ("Start Timer", Cat::CmdUtil),
    ("Stop Timer", Cat::CmdUtil),
    ("Pomodoro", Cat::CmdUtil),
    ("Convert Currency", Cat::CmdUtil),
    ("Convert Units", Cat::CmdUtil),
    ("Define Word", Cat::CmdSearch),
    ("Translate", Cat::CmdUtil),
    ("Search Google", Cat::CmdSearch),
    ("Search GitHub", Cat::CmdSearch),
    ("Search Stack Overflow", Cat::CmdSearch),
    ("Search YouTube", Cat::CmdSearch),
    ("Search Wikipedia", Cat::CmdSearch),
    ("Search Maps", Cat::CmdSearch),
    ("Open Downloads", Cat::CmdSearch),
    ("Open Desktop", Cat::CmdSearch),
    ("Open Documents", Cat::CmdSearch),
    ("Create Quicklink", Cat::CmdUtil),
    ("Create Snippet", Cat::CmdUtil),
    ("Search Bookmarks", Cat::CmdSearch),
    ("Search Browser Tabs", Cat::CmdSearch),
    ("Search Menu Items", Cat::CmdSearch),
    ("Switch Windows", Cat::CmdWindow),
    ("System Information", Cat::CmdSystem),
    ("Battery Status", Cat::CmdPower),
    ("Show Desktop", Cat::CmdWindow),
    ("Kill Process", Cat::CmdSystem),
    ("Flush DNS", Cat::CmdSystem),
    ("IP Address", Cat::CmdSystem),
    ("Generate Password", Cat::CmdUtil),
    ("Generate UUID", Cat::CmdUtil),
    ("Color Picker", Cat::CmdUtil),
    ("Join Next Meeting", Cat::CmdMeeting),
    ("My Schedule", Cat::CmdMeeting),
    ("Create Reminder", Cat::CmdUtil),
    ("Search Notes", Cat::CmdSearch),
    ("Search Contacts", Cat::CmdSearch),
    ("Copy Last Screenshot", Cat::CmdUtil),
    ("Toggle Hidden Files", Cat::CmdSystem),
    ("Toggle Menu Bar", Cat::CmdSystem),
    ("Volume Up", Cat::CmdMusic),
    ("Volume Mute", Cat::CmdMusic),
    ("Switch Audio Output", Cat::CmdMusic),
    ("Toggle Microphone", Cat::CmdMeeting),
    ("Caffeinate", Cat::CmdPower),
    ("Decaffeinate", Cat::CmdPower),
    ("Run Script: Deploy", Cat::CmdUtil),
    ("Run Script: Backup", Cat::CmdUtil),
    ("Open Project", Cat::CmdSearch),
    ("Search Issues", Cat::CmdSearch),
    ("Search Pull Requests", Cat::CmdSearch),
    ("Paste as Plain Text", Cat::CmdUtil),
    ("Format JSON", Cat::CmdUtil),
    ("Encode URL", Cat::CmdUtil),
    ("Base64 Encode", Cat::CmdUtil),
    ("Word Count", Cat::CmdUtil),
    ("Lorem Ipsum", Cat::CmdUtil),
    ("Speed Test", Cat::CmdSystem),
    ("World Clock", Cat::CmdUtil),
    ("Search Calendar", Cat::CmdMeeting),
    ("Play Pause", Cat::CmdMusic),
    ("Next Track", Cat::CmdMusic),
    ("Low Power Mode", Cat::CmdPower),
    ("Energy Usage", Cat::CmdPower),
    ("Search Downloads", Cat::CmdSearch),
    ("Recent Documents", Cat::CmdSearch),
];

const FILE_STEMS: &[&str] = &[
    "Quarterly Report",
    "Budget",
    "Roadmap",
    "Invoice",
    "Design Spec",
    "Meeting Notes",
    "Thesis Draft",
    "Resume",
    "Travel Plan",
    "Project Plan",
    "README",
    "Contract Draft",
    "Lecture Slides",
    "Dataset Summary",
    "Analysis Notebook",
    "Brand Guidelines",
    "Onboarding Checklist",
    "Interview Notes",
    "Sprint Retro",
    "Expense Report",
    "Weekly Update",
    "Product Brief",
    "Launch Checklist",
    "Research Proposal",
    "Board Deck",
    "Hiring Plan",
    "Style Guide",
    "Release Notes",
    "Architecture Overview",
    "Grant Application",
];
const FILE_EXT: &[&str] = &[
    ".pdf", ".docx", ".xlsx", ".key", ".md", ".pages", ".numbers", ".csv", ".fig",
];

pub fn split_words(lower: &str) -> Vec<String> {
    lower
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty())
        .map(|w| w.to_string())
        .collect()
}

pub fn make_item(id: u32, name: &str, kind: Kind, cat: Cat) -> Item {
    let lower = name.to_lowercase();
    let words = split_words(&lower);
    let initials: String = words.iter().filter_map(|w| w.chars().next()).collect();
    Item {
        id,
        name: name.to_string(),
        lower,
        words,
        initials,
        kind,
        cat,
    }
}

/// Builds the catalog: apps, commands, then `n_files` synthetic documents (stem + number + ext).
pub fn build_catalog(n_files: usize) -> Vec<Item> {
    let mut v = Vec::new();
    for (n, c) in APPS {
        let id = v.len() as u32;
        v.push(make_item(id, n, Kind::App, *c));
    }
    for (n, c) in COMMANDS {
        let id = v.len() as u32;
        v.push(make_item(id, n, Kind::Command, *c));
    }
    for k in 0..n_files {
        let stem = FILE_STEMS[k % FILE_STEMS.len()];
        let ext = FILE_EXT[(k * 7 + k / FILE_STEMS.len()) % FILE_EXT.len()];
        let num = k / FILE_STEMS.len();
        let name = if num == 0 {
            format!("{stem}{ext}")
        } else {
            format!("{stem} {:02}{ext}", num + 1)
        };
        let id = v.len() as u32;
        v.push(make_item(id, &name, Kind::File, Cat::File));
    }
    v
}

/// QWERTY neighbours for synthetic typos.
pub fn qwerty_neighbor(c: u8, r: u64) -> u8 {
    const ROWS: [&[u8]; 3] = [b"qwertyuiop", b"asdfghjkl", b"zxcvbnm"];
    for (ri, row) in ROWS.iter().enumerate() {
        if let Some(ci) = row.iter().position(|&x| x == c) {
            let mut opts: Vec<u8> = Vec::new();
            if ci > 0 {
                opts.push(row[ci - 1]);
            }
            if ci + 1 < row.len() {
                opts.push(row[ci + 1]);
            }
            if ri > 0 && ci < ROWS[ri - 1].len() {
                opts.push(ROWS[ri - 1][ci]);
            }
            if ri < 2 && ci < ROWS[ri + 1].len() {
                opts.push(ROWS[ri + 1][ci]);
            }
            return opts[(r as usize) % opts.len()];
        }
    }
    c
}
