# The website

The website lives in `site/` and is served by GitHub Pages at https://slick.computer. It is hand-written HTML, CSS and a little JavaScript. There is no build step and no dependency. The workflow in `.github/workflows/pages.yml` uploads the folder as it is.

## What is in `site/`

| Path | What it is |
|---|---|
| `index.html` | The landing page. It reads well with JavaScript off. |
| `styles.css` | Every style. Dark is the base look, and light has its own palette under `prefers-color-scheme`. |
| `main.js` | Small enhancements: the download switch, the feature list, video slots, the hero appearance switch and the copy button. |
| `404.html` | The page GitHub Pages serves for a missing address. It uses root paths such as `/styles.css`, because it can be served at any depth. |
| `data/features.json` | A copy of `support/features.json`. The feature list on the page is drawn from it. |
| `data/release.json` | The download switch. Off today. |
| `media/` | The screenshots and `manifest.json`, which holds their sizes, captions and alt text. |
| `assets/icon/`, `favicon.ico` | The app icon at several sizes. |
| `assets/og.png` | The 1200 by 630 picture that link previews show. `assets/og-card.html` is its source. |
| `CNAME`, `robots.txt`, `sitemap.xml`, `.nojekyll` | Domain record, crawler rules, the one-page sitemap, and a marker that turns Jekyll off for branch publishing. |

The page makes no request to any other server. A Content Security Policy in each page's `<meta>` tag enforces that: scripts, styles, images, media and fetches must come from the site itself. There are no web fonts, no analytics and no cookies. HTML, CSS and JavaScript together must stay under 120 KB.

## Put it live

Do these once, in this order. GitHub asks for the domain to be added to the repository before the DNS records exist, so nobody else can claim it in between.

### 1. Verify the domain on your account

Verification stops any other GitHub account from using `slick.computer` and its immediate subdomains.

1. Click your profile picture, then **Settings**. This is your account's settings, not the repository's.
2. In the sidebar, under **Code, planning, and automation**, click **Pages**.
3. Click **Add a domain**, enter `slick.computer` and click **Add domain**.
4. GitHub shows a TXT record. Its name is `_github-pages-challenge-shawntz.slick.computer`, and GitHub gives you the value. Add it at your DNS provider.
5. When the record is live, click **Verify**. To check it first:

       dig _github-pages-challenge-shawntz.slick.computer +nostats +nocomments +nocmd TXT

6. Leave the TXT record in place. The domain stays verified only while it exists.

### 2. Choose GitHub Actions as the publishing source

1. Open the repository, then **Settings**, then **Pages** in the **Code, planning, and automation** section.
2. Under **Build and deployment**, set **Source** to **GitHub Actions**. Skip the workflow templates GitHub suggests. `pages.yml` is already in the repository.

GitHub creates an environment called `github-pages` when the repository does not have one. GitHub recommends a deployment protection rule on it so only `main` can deploy. Set that under **Settings**, **Environments**, **github-pages**.

If the workflow ran before this step, for example because you pushed the repository first, that run failed in its `configure-pages` step, because Pages was not set up yet. Run it again from **Actions** once this step is done.

### 3. Deploy

Push a change under `site/` to `main`, or run the workflow by hand from **Actions**, **Pages**, **Run workflow**. The run's summary links to the live address.

### 4. Set the custom domain

1. In **Settings**, **Pages**, type `slick.computer` under **Custom domain** and click **Save**.
2. GitHub then runs a DNS check, which fails until step 5 is done.

With an Actions deployment, the custom domain lives in this setting. GitHub ignores the `CNAME` file in `site/` for this kind of deployment. The file stays in the folder as a record of the domain and for branch publishing.

### 5. Add the DNS records

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

### 6. Turn on HTTPS

Once the DNS check in **Settings**, **Pages** passes, GitHub requests a certificate from Let's Encrypt. The **Enforce HTTPS** option can take up to 24 hours to become available. Select it when it does. If HTTPS is still not active after a while, remove the custom domain, enter it again and save. That restarts the certificate request.

Every address in the site is relative or HTTPS, so there is no mixed content to fix.

## Preview locally

`main.js` fetches the JSON files, so preview through a local server, not from a `file://` address:

    python3 -m http.server 8000 --bind 127.0.0.1 --directory site

Then open http://127.0.0.1:8000. Press Control-C in that terminal to stop the server.

To check a layout without a browser, `scripts/site-snapshot.swift` loads a page in an offscreen WebKit view at any width and appearance and writes a PNG. No window opens. With the server running:

    swift scripts/site-snapshot.swift http://127.0.0.1:8000/ /tmp/home-390-dark.png --width 390 --appearance dark --full
    swift scripts/site-snapshot.swift http://127.0.0.1:8000/ /tmp/home-1440-light.png --width 1440 --appearance light --full

`--full` captures the whole page, and `--scale 2` doubles the pixels. Compiling once makes repeat runs faster:

    swiftc -O scripts/site-snapshot.swift -o build/site-snapshot

## Common changes

### The feature list

`support/features.json` is the only source for what the site may call available. Run `scripts/sync-features.py` after every change to it. With `--check` it changes nothing and exits 1 when the copy is stale.

The script writes three things: the tables in `README.md`, the copy in `site/data/features.json`, and the static list in `index.html` between the `<!-- features:start` and `<!-- features:end -->` comments. `main.js` draws the list from `data/features.json` on every visit. The static list is there for readers without JavaScript and for search engines, and it uses the same markup as `main.js`, so the redraw moves nothing:

- One `<section class="feature-group">` per status, in the order available, in progress, planned. A status with no features gets no section.
- Each section has a heading with the status name, the number of features, the status definition and one line per feature:

      <li class="feature"><h4>Title</h4><p>Summary</p></li>

- The definitions are in `DEFINITION` in `main.js` and `DEFINITIONS` in the script: available "Works in the app today.", in progress "Code exists or is being written. Not usable in the app yet.", planned "On the list. Not usable in the app yet."

To change that markup, change `renderFeatures` in `main.js` and `render_page_block` in the script together. The script stops with an error instead of writing over a list whose tags or classes it does not write.

Above the list, the three-step track headed Done, Now and Not yet is hand-written. It follows where the whole project stands, not the JSON file. When a step is reached, move the `data-stage` values along: `done`, `now`, `next`. The step marked `now` also carries `aria-current="step"`.

### Turning on the download button

Edit `site/data/release.json`:

    {
      "download": {
        "enabled": true,
        "url": "https://github.com/shawntz/slick/releases/latest",
        "label": "Download for Mac",
        "version": "0.1.0"
      }
    }

The published HTML says nothing about a download. With the switch on, `main.js` adds the download button first in the hero and makes the GitHub button the second one. It also changes the pre-release line to the version, and replaces the "Can I download it?" answer with "Where do I download it?". The URL must be HTTPS or on this site. All of this needs JavaScript, so readers without it still see the pre-release line. On release day, also edit that line, the "Can I download it?" answer and the Status track in `index.html` by hand.

### Screenshot crops

Each still is 1880 by 1480 pixels, and the launcher's panel covers about half of it. The page shows only the panel plus a 64 pixel margin. Each frame names a crop with `data-crop`, and `styles.css` holds the numbers under "Screenshot frames": `--cx` and `--cy` are the top-left corner, `--cw` and `--ch` the size, in the still's pixels. A figure narrower than 600 px, as on a phone, switches to a closer crop of the same still so the text stays readable.

| Crop | Used by | Full crop | Narrow crop |
|---|---|---|---|
| `panel` | hero | 114, 195, 1650 by 1064 | 114, 195, 960 by 642 |
| `rows` | themes | 114, 195, 1650 by 560 | 114, 195, 960 by 560 |
| `suggestions` | learning | 114, 95, 1650 by 1264 | 114, 95, 960 by 1264 |
| `actions` | keys | 114, 173, 1650 by 1106 | 941, 311, 823 by 968 |
| `grid` | glass | 114, 263, 1650 by 928 | 114, 263, 1000 by 928 |

When a still is captured again, check that its panel still sits where the crop expects. In the current stills the panel's left edge is at x 178 and its right edge at x 1700. Its top and bottom depend on the view: 259 to 1195 for the hero and themes, 159 to 1295 for suggestions, 237 to 1215 for actions and 327 to 1127 for the grid.

### The theme picker

The Themes section shows one frame and a row of radio buttons, so it switches without JavaScript. Each still and each caption carries `data-view`, and the CSS rules under "A figure that shows one of several stills" show the one whose radio button is checked. To add a theme, add its `<img>`, its caption, its radio button and its line in each of the three rules.

### Replacing a screenshot with a recording

Every picture on the page is a slot named after its file, such as `hero-dark`. To play a recording in a slot, put the video in `site/media/` and add an entry to `site/media/manifest.json` with the same base name:

    {
      "file": "hero-dark.mp4",
      "poster": "hero-dark.png",
      "width": 1880,
      "height": 1480,
      "appearance": "dark",
      "caption": "…",
      "alt": "Describe what the recording shows, and say if it is sample data."
    }

Keep the PNG. It is the poster frame and what readers without JavaScript see. The page then swaps in a muted, looping, inline video when the slot comes near the screen. It plays while at least a fifth of it is visible, stays paused for readers who ask for reduced motion, and shows a Pause and Play button. MP4 with H.264 video plays in every current browser. Keep the same 1880 by 1480 frame, so the crop still fits.

The hero is a `<picture>` whose light source follows the reader's appearance, so only one hero image downloads. When either hero slot gets a video, `main.js` first splits the picture into one image per appearance.

### The social image

Edit `site/assets/og-card.html`, then render it with the server running:

    swift scripts/site-snapshot.swift http://127.0.0.1:8000/assets/og-card.html site/assets/og.png --width 1200 --height 630 --scale 1

The card shows a crop of `media/hero-dark.png`, so render it again after that still changes. The project's rule for text set in the card is Avenir Next, with Helvetica Neue as the fallback, never the system font. The screenshot in it is the launcher's own interface.

### Words on the page

Every claim on the site must be backed by `support/features.json` or a measurement in the project's reports. Numbers are quoted as measurements on one Apple M5 with macOS 27.2, a 120 Hz display and release builds, in November 2026. Do not say the app is faster than another launcher, and do not call a feature available before the data does. Alt text for screenshots comes from `media/manifest.json` and says that the pictures show sample data. `main.js` replaces the alt text in `index.html` with the manifest's, so change the manifest first, then copy the text into `index.html`.

## Sources

- GitHub Docs, Managing a custom domain for your GitHub Pages site: https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/managing-a-custom-domain-for-your-github-pages-site
- GitHub Docs, Verifying your custom domain for GitHub Pages: https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/verifying-your-custom-domain-for-github-pages
- GitHub Docs, Troubleshooting custom domains and GitHub Pages: https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/troubleshooting-custom-domains-and-github-pages
- GitHub Docs, Configuring a publishing source for your GitHub Pages site: https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site
- GitHub Docs, Securing your GitHub Pages site with HTTPS: https://docs.github.com/en/pages/getting-started-with-github-pages/securing-your-github-pages-site-with-https
- GitHub Docs, Using custom workflows with GitHub Pages: https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages

Checked on 15 November 2026.
