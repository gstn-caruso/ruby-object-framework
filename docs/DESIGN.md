# Guides design and editorial brief

Readers are Ruby developers building applications from collaborating objects.
The site works as a course and as a reference book. Each guide connects a
runnable example to the responsibility, invariant, and tradeoff behind it.

The user requested the visual style of
[the Rails Guides index](https://guides.rubyonrails.org/index.html), as well as
its progressive teaching and explicit examples. The reference was inspected
on October 23, 2026. The stylesheet implements that appearance for the
ObjectFramework content and navigation.

## Visual treatment

Use a white page, a white header, red `#c81418` headings and links, near-black
`#222222` body text, warm gray `#faf9f8` secondary surfaces, muted `#5c5c5c`
descriptions, and fine gray `#d8d4d1` rules between guide descriptions. The
desktop grid keeps the reading column and chapter navigation in separate
columns. The right column stays sticky while reading and collapses into the
page flow on smaller screens.
The header contains a circular project symbol, the guide title and version,
a Guides Index disclosure, API reference, source, and contribution links.

Body text uses Inter at 17 pixels with a 1.7 line height in a reading column
up to 704 pixels wide. Page titles use Calibre at 40–56 pixels, weight 700,
and a 1.1 line height; article section headings use Calibre at 34 pixels,
weight 700, and a 1.2 line height. Introductions use Inter at 20 pixels with
a 1.6 line height. Keep normal letter spacing. Load Calibre through explicit
font-face rules using the Rails-hosted font URLs; naming a locally installed
font alone does not ensure readers see it. Body Inter uses the same static
font files served by Rails Guides, with regular, semibold, bold, and italic faces.
Code uses IBM Plex Mono on dark warm-gray blocks with pale syntax colors.
Inter and IBM Plex Mono are self-hosted with their SIL Open Font Licenses.
Calibre requires a network request to rubyonrails.org and falls back to the
browser's sans serif font if unavailable. `assets/fonts.css` supplies these
faces to both the guides and the generated RDoc pages through shared family
tokens. Match Rails Guides' font families and weights: Calibre Bold for page
and section titles, Inter for reading and smaller subheadings, and IBM Plex
Mono for code. Reading text uses common ligatures and oldstyle numerals;
headings and ordered lists use lining numerals, as in the reference.

The API uses the same 17-pixel reading text and bold titles. Its method
group headings use 28-pixel Calibre with light rules, above 16-pixel method
signatures. On narrow screens, titles scale to 22–32 pixels to accommodate
qualified Ruby class names and group headings use 20–24 pixels.

The index uses 30-pixel section headings and ruled definition lists. Guide
links use 20-pixel bold Inter; their 16-pixel muted descriptions sit
directly underneath. Space between sections exceeds space between entries,
and space within an entry is the smallest. The 28-pixel header brand and
small, separate version leave the page title as the primary heading.
Soft cyan and pale yellow notes explain the reading path and executable
examples in the right margin. Notes and the numbered chapter index use
14-pixel text with regular-weight links so they stay secondary to the article.
An API reference section below the guide catalog embeds the generated RDoc
in a titled, lazy-loaded iframe. Direct reference and class links remain
available outside the frame; print styles retain those links and hide the frame.

```text
Project symbol / Guides / Version          Guides Index / Contribute

Guide title and introduction               Chapters
                                            1. First concept
1. First concept                            2. Next concept
Working example and explanation
```

Below 1025 pixels, the header stacks, the article stays within the reading
width, and a native disclosure places chapter navigation before the article.
The Guides Index remains keyboard accessible at every width. A dark color scheme
follows the reference's dark surfaces and softer red links. Print styles
remove navigation while preserving the article.
Below 480 pixels, 36–44-pixel titles, 18-pixel introductions, and two-column
project navigation keep the header compact. Project navigation and copy
buttons are at least 44 pixels high. The guide menu is centered within the
header's width and scrolls within the viewport.

ObjectFramework retains its own name, symbol, original explanations, and
executable examples. The stylesheet is maintained with the repository rather
than loading the Rails site's stylesheet at runtime. Validate generated links,
review desktop and mobile screenshots, exercise the disclosure and search with
a keyboard, and audit the rendered guide after visual changes.
