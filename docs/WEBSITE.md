# The website

The website lives in `site/` and GitHub Pages serves it. It is hand-written HTML, CSS and a little JavaScript. There is no build step and no dependency. The workflow in `.github/workflows/pages.yml` uploads the folder as it is on every push to `main` that changes `site/`.

Until the domain is attached, the site is at https://shawntz.github.io/slick/. Its home is https://slick.computer, which works once steps 2, 5, 6 and 7 under "Put it live" are done. Those steps need the owner's GitHub account and the domain's DNS.

## What is in `site/`

| Path | What it is |
|---|---|
| `index.html` | The landing page. It reads well with JavaScript off. |
| `styles.css` | Every style. Dark is the base look, and light has its own palette under `prefers-color-scheme`. |
| `main.js` | Small enhancements: the download switch, the feature list, the clip slots, the hero's appearance switch and the copy button. |
| `404.html` | The page GitHub Pages serves for a missing address. It uses root paths such as `/styles.css`, because it can be served at any depth. Under `shawntz.github.io/slick/` those paths miss, so the page shows without its styles until the domain is attached. |
| `data/features.json` | The website's own form of `support/features.json`, which `scripts/sync-features.py` writes. It holds each group's title and each feature's id, title and summary, and nothing else. The feature list on the page is drawn from it. |
| `data/release.json` | The download switch. It is on for 0.1.1. |
| `media/` | Recordings of the assembled app with their posters, stills of its settings window, and `manifest.json`, which holds their sizes, captions and alt text. The folder also keeps older stills from the interface code, which the page does not use. |
| `assets/icon/`, `favicon.ico` | The app icon at several sizes. |
| `assets/og.png` | The 1200 by 630 picture that link previews show. `assets/og-card.html` is its source. |
| `CNAME`, `robots.txt`, `sitemap.xml`, `.nojekyll` | Domain record, crawler rules, the one-page sitemap, and a marker that turns Jekyll off for branch publishing. |

The page makes no request to any other server. A Content Security Policy in each page's `<meta>` tag enforces that: scripts, styles, images, media and fetches must come from the site itself. There are no web fonts, no analytics and no cookies. HTML, CSS and JavaScript together must stay under 120 KB. On 16 November 2026 `index.html`, `404.html`, `styles.css` and `main.js` came to 104,200 bytes.

Recordings do not count toward that limit, but they are the heaviest part of the page. A visitor downloads only the posters of the clips they scroll near and only the recordings that play. The posters are 0.3 to 0.8 MB each and the recordings 0.7 to 2.9 MB.

## Put it live

Do these once, in this order. GitHub asks for the domain to be added to the repository before the DNS records exist, so nobody else can claim it in between.

Steps 1, 3 and 4 were done on 15 November 2026: the workflow is on `main`, the publishing source is GitHub Actions, and the site deploys to https://shawntz.github.io/slick/. They stay here for a fork or a new repository. Steps 2, 5, 6 and 7 are left.

### 1. Push the workflow file

`.github/workflows/pages.yml` must be on `main` before anything below can deploy. A push that adds it fails while the token that pushes has no `workflow` scope. Give the token that scope, then push:

- With the GitHub CLI as the credential helper, run `gh auth refresh -h github.com -s workflow`, then push again.
- A classic personal access token needs the `workflow` scope. A fine-grained one needs the Workflows permission set to read and write.
- Without changing the token, the file can also be added through the GitHub web editor, as a commit made in the browser.

### 2. Verify the domain on your account

Verification stops any other GitHub account from using `slick.computer` and its immediate subdomains.

1. Click your profile picture, then **Settings**. This is your account's settings, not the repository's.
2. In the sidebar, under **Code, planning, and automation**, click **Pages**.
3. Click **Add a domain**, enter `slick.computer` and click **Add domain**.
4. GitHub shows a TXT record. Its name is `_github-pages-challenge-shawntz.slick.computer`, and GitHub gives you the value. Add it at your DNS provider.
5. When the record is live, click **Verify**. To check it first:

       dig _github-pages-challenge-shawntz.slick.computer +nostats +nocomments +nocmd TXT

6. Leave the TXT record in place. The domain stays verified only while it exists.

### 3. Choose GitHub Actions as the publishing source

1. Open the repository, then **Settings**, then **Pages** in the **Code, planning, and automation** section.
2. Under **Build and deployment**, set **Source** to **GitHub Actions**. Skip the workflow templates GitHub suggests. `pages.yml` is the workflow to use, once step 1 has put it on `main`.

GitHub creates an environment called `github-pages` when the repository does not have one. GitHub recommends a deployment protection rule on it so only `main` can deploy. Set that under **Settings**, **Environments**, **github-pages**.

If the workflow ran before this step, for example because step 1 pushed it first, that run failed in its `configure-pages` step, because Pages was not set up yet. Run it again from **Actions** once this step is done.

### 4. Deploy

Push a change under `site/` to `main`, or run the workflow by hand from **Actions**, **Pages**, **Run workflow**. Both need the workflow file on `main`, so neither works before step 1. The run's summary links to the live address.

### 5. Set the custom domain

1. In **Settings**, **Pages**, type `slick.computer` under **Custom domain** and click **Save**.
2. GitHub then runs a DNS check, which fails until step 6 is done.

With an Actions deployment, the custom domain lives in this setting. GitHub ignores the `CNAME` file in `site/` for this kind of deployment. The file stays in the folder as a record of the domain and for branch publishing.

### 6. Add the DNS records

At the DNS provider for `slick.computer`:

| Name | Type | Value |
|---|---|---|
| `@`, the apex | A | `185.199.108.153` |
| `@` | A | `185.199.109.153` |
| `@` | A | `185.199.110.153` |
| `@` | A | `185.199.111.153` |
| `@` | AAAA | `2606:50c0:8000::153` |
| `@` | AAAA | `2606:50c0:8001::153` |
| `@` | AAAA | `2606:50c0:8002::153` |
| `@` | AAAA | `2606:50c0:8003::153` |
| `www` | CNAME | `shawntz.github.io` |

- Point `www` at `shawntz.github.io`, without the repository name.
- Delete any other A, AAAA, ALIAS or ANAME record on the apex, such as a registrar's parking page. Extra records can stop GitHub from issuing the certificate.
- Do not add a wildcard record such as `*.slick.computer`. GitHub warns that wildcards put the domain at risk of takeover.
- If the DNS host has CAA records, one of them must allow `letsencrypt.org`, which issues the Pages certificate. GitHub's troubleshooting page, listed under Sources, states this rule.

With both the apex and `www` set up, GitHub redirects `www.slick.computer` to `slick.computer`.

To check the records from a terminal:

    dig slick.computer +noall +answer -t A
    dig slick.computer +noall +answer -t AAAA
    dig www.slick.computer +noall +answer -t CNAME

DNS changes can take up to 24 hours to spread.

### 7. Turn on HTTPS

Once the DNS check in **Settings**, **Pages** passes, GitHub requests a certificate from Let's Encrypt. The **Enforce HTTPS** option can take up to 24 hours to become available. Select it when it does. If HTTPS is still not active after a while, remove the custom domain, enter it again and save. That restarts the certificate request.

Every address in the site is relative or HTTPS, so there is no mixed content to fix.

## Preview locally

`main.js` fetches the JSON files, so preview through a local server, not from a `file://` address:

    python3 -m http.server 8000 --bind 127.0.0.1 --directory site

Then open http://127.0.0.1:8000. Press Control-C in that terminal to stop the server.

To check a layout without a browser, `scripts/site-snapshot.swift` loads a page in an offscreen WebKit view at any width and appearance and writes a PNG. No window opens. An offscreen view never starts a video, so the tool captures each `<video>` as its poster. With the server running:

    swift scripts/site-snapshot.swift http://127.0.0.1:8000/ /tmp/home-390-dark.png --width 390 --appearance dark --full
    swift scripts/site-snapshot.swift http://127.0.0.1:8000/ /tmp/home-1440-light.png --width 1440 --appearance light --full

`--full` captures the whole page, and `--scale 2` doubles the pixels. Use `--settle 2` so the page has its feature list and clip slots in place before the capture. Compiling once makes repeat runs faster:

    swiftc -O scripts/site-snapshot.swift -o build/site-snapshot

Before a change goes live, look at full-page captures at 390, 834 and 1440 pixels wide in dark and in light, and check these by hand or in a test page: no sideways scroll from 320 to 1920 pixels, the section links at every width, the same feature list, item for item and laid out the same inside its section, with JavaScript on and off, the clip picker on each of its clips, the hero's Dark and Light switch, Pause and Play, and no request to another server. Stop the local server afterwards.

## Common changes

### The feature list

The All features section lists what Slick does. It does not say how far along a feature is. That lives in `support/features.json`, and the README shows it.

In `support/features.json`, each feature's `summary` says what the feature does. Its `standing`, where it has one, says how far along it is, and its `status` is available, in-progress or planned. Leave `standing` out when there is nothing to say. The script refuses an empty one. Run `scripts/sync-features.py` after every change to the file. With `--check` it changes nothing and exits 1 when an output is stale. `make lint`, and so CI, runs it with `--check`.

The script writes three things. It writes the tables in `README.md`, with each feature's status and its summary followed by its standing. It writes `site/data/features.json`, which holds only what the page shows: the groups in order, each with its title, and each feature's id, title and summary. And it writes the static list in `index.html` between the `<!-- features:start` and `<!-- features:end -->` comments. `main.js` draws the list from `data/features.json` on every visit. If that file is missing or has any other shape, such as an older copy with more fields, `main.js` leaves the static list as it is. The static list is there for readers without JavaScript and for search engines, and it uses the same markup as `main.js`, so the redraw moves nothing:

- One `<section class="feature-group">` per group, in the order of the file: Core, then Built-in tools.
- Each section has the group's title as its heading, then the group's features in the order of the file, one line each:

      <section class="feature-group" aria-labelledby="feature-group-1">
      <h3 class="feature-group-title" id="feature-group-1">Core</h3>
      <ul class="feature-list">
      <li class="feature"><h4>Title</h4><p>Summary</p></li>

- The heading ids number the groups from 1 in the order of the file. The script and `main.js` number them the same way.

The list shows one feature per row on a phone, two from 640 pixels and three from 1024 pixels. The features in a row share one height, so the lines between rows run straight across.

To change that markup, change `renderFeatures` in `main.js` and `render_page_block` in the script together. The script stops with an error instead of writing over a list whose tags or classes it does not write.

The page shows no status. The script fails, with or without `--check`, when `index.html` has a `data-status` attribute or when `main.js` reads or writes one.

### Turning on the download button

Edit `site/data/release.json`:

    {
      "download": {
        "enabled": true,
        "url": "https://github.com/shawntz/slick/releases/latest",
        "label": "Download for Mac",
        "version": "0.1.1"
      }
    }

With the switch on, `main.js` adds the download button first in the hero and makes the GitHub button the second one. It also sets the line above the name to the version. The URL must be HTTPS or on this site. Both need JavaScript.

Everything else about a release is plain HTML, so readers without JavaScript see it too. For each release, edit these by hand in `index.html`: the version line above the name and the Install section with its download link and Homebrew command. In the README, edit the line under the hero and the Install section. They were last edited for 0.1.1 on 16 November 2026.

### Clip slots

Every moving picture on the page is a slot for a recording in `site/media/`. The page holds the recording's poster as a plain image, which is what readers without JavaScript see, and names the recording on the frame:

    <div class="frame" data-crop="panel" data-clip="clip-narrow-dark.mp4">
      <img data-media="clip-narrow-dark-poster.png" src="media/clip-narrow-dark-poster.png" width="1880" height="1480" alt="…" loading="lazy" decoding="async">
    </div>

A slot recorded in both appearances names both, `data-clip-dark` and `data-clip-light`, and holds both posters, one with `class="look-dark"` and one with `class="look-light"`. The CSS shows the one for the reader's appearance. The hero holds its posters in a `<picture>` instead, so only one of them downloads, and its Dark and Light switch picks the recording.

Once a slot is shown and comes within 600 pixels of the screen, `main.js` puts a `<video>` in place of the poster. The video is muted, loops, plays inline, has no controls and no `autoplay` attribute, and loads nothing until it plays. It takes its poster and its alt text, as `aria-label`, from the recording's entry in `manifest.json`. It plays while a fifth of it is on screen. For readers who ask for reduced motion it stays on its poster until they press Play. One Pause and Play button per figure sits in the caption bar, so it covers nothing in the recording. A video in a hidden tab of the clip picker pauses. None of today's recordings has a sound track.

To add a clip, record it with `make media`, which publishes the MP4, the GIF, the poster and the manifest entry. Then add a slot. Copy the poster's alt text and the recording's caption from the manifest into `index.html`. `main.js` also copies the alt text at load time, so the manifest wins if the two differ.

Use only captures of the assembled app: entries in the manifest with a `clip` or a `still` field. The older stills without either field come from the interface code drawing a made-up catalog, and their alt text says they are not the app.

The two pictures of the General pane, `settings-general-dark.png` and `settings-general-light.png`, show the hotkey advice from before Slick could turn off Spotlight's shortcut. The page and the README leave them out until `make media` records them again.

### Crops

Each recording is 1880 by 1480 pixels, and the launcher's panel covers about half of it, at x 178 to 1700 and y 247 to 1208. The page shows only the panel plus a margin. Each frame names a crop with `data-crop`, and `styles.css` holds the numbers under "Screenshot frames": `--cx` and `--cy` are the top-left corner, `--cw` and `--ch` the size, in the picture's pixels. A figure narrower than 600 px, as on a phone, switches to a closer crop.

| Crop | Used by | Full crop | Narrow crop |
|---|---|---|---|
| `panel` | hero, speed, learning, calculator | 114, 195, 1650 by 1064 | 114, 195, 960 by 642 |
| `panel-whole` | themes, Glass, the Standard and Glass stills, keys, clipboard, emoji, files | 114, 195, 1650 by 1064 | 154, 223, 1570 by 1010 |
| `spotlight` | Spotlight | 114, 320, 1650 by 1160 | 200, 350, 1480 by 1130 |
| `settings` | the Learning pane's still | 0, 0, 1880 by 1360 | 440, 40, 1400 by 1280 |

`panel` on a phone shows the query field and the first four rows, which is where its clips happen. `panel-whole` keeps the whole panel, for clips whose action happens on the right or low in the panel. The Spotlight theme's two pieces of glass sit lower than the other panels, at x 260 to 1620 from y 438, and its results container grows down to y 1452 while the action panel is open, so `spotlight` runs to the bottom of the clip. The settings stills are 1880 by 1360, with the window at x 40 to 1840 and y 40 to 1320 and its sidebar up to x 440. On a phone only the pane beside the sidebar shows. When a recording is made again, check that the panel still sits where these crops expect.

### The clip picker

The Built in section shows one frame at a time and a row of radio buttons, so it switches without JavaScript. Each frame and each caption carries `data-view`, and the CSS rules under "A figure that shows one of several clips" show the one whose radio button is checked. To add a clip, add its frame, its caption, its radio button and its line in each of the two `:has()` rules.

### Spotlight and Glass

Under the themes clip, the Themes section shows two built-in themes on their own. Each has a heading, its text and its clip, which follows the reader's appearance. The comparison stills remain in `media/` for the README.

- The Spotlight theme's text is the only place on the page that says what it is modeled on. Say it once, as "Spotlight is modeled on Spotlight in macOS 27." The footer says that Spotlight is a trademark of Apple Inc. and that Slick is not affiliated with Apple. Keep that line while a theme carries the name.
- The Glass theme’s text notes that it can be harder to read over bright or busy windows. Contrast measurements belong in the project reports.
- The recorder's wallpaper has no detail, so clear and frosted glass would look alike over it. The Glass clips show the panel over the settings window’s About page instead.

### The social image

Edit `site/assets/og-card.html`, then render it with the server running:

    swift scripts/site-snapshot.swift http://127.0.0.1:8000/assets/og-card.html site/assets/og.png --width 1200 --height 630 --scale 1

The card shows a crop of `media/hero-dark-poster.png`, the poster of the hero recording, so render it again after that poster changes, and update the `og:image:alt` and `twitter:image:alt` text in `index.html` to match. The project's rule for text set in the card is Avenir Next, with Helvetica Neue as the fallback, never the system font.

### Words on the page

Every claim on the site must be backed by `support/features.json` or the project reports. Keep the landing page focused on what Slick does. Link to benchmark methods, build instructions and setup details in the repository instead of repeating them on the page. Alt text and captions come from `media/manifest.json`. Update the source storyboard in `scenarios/media/` and the manifest together, then copy the text into `index.html`.

The owner's rules for words apply to every sentence on the page. Say what happens, in the order it happens, in the words a person would use out loud. Write short sentences with one idea each, in the active voice, and name who does it. Use no colon in the middle of a sentence, no semicolon, no dash as punctuation, no parentheses and no "and more". Praise nothing. Say what the thing does and give the number. Headings on the page use sentence case.

## Sources

- GitHub Docs, Managing a custom domain for your GitHub Pages site: https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/managing-a-custom-domain-for-your-github-pages-site
- GitHub Docs, Verifying your custom domain for GitHub Pages: https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/verifying-your-custom-domain-for-github-pages
- GitHub Docs, Troubleshooting custom domains and GitHub Pages: https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/troubleshooting-custom-domains-and-github-pages
- GitHub Docs, Configuring a publishing source for your GitHub Pages site: https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site
- GitHub Docs, Securing your GitHub Pages site with HTTPS: https://docs.github.com/en/pages/getting-started-with-github-pages/securing-your-github-pages-site-with-https
- GitHub Docs, Using custom workflows with GitHub Pages: https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages

The Pages steps were checked against these on 15 November 2026. The note on the `workflow` scope was not checked against GitHub's pages again in this round.
